function out = ramoWaveform(q_C, r0_m, field, mob, cfg)
%RAMOWAVEFORM 柱形/球形 TEPC 的 Shockley-Ramo 感应: 逐样本"收集电荷" (ZOH 一致)。
%   场与权重场一律取自 tepc.detector.fieldModel (单一真相源; 曾在此硬编码圆柱式,
%   与 buildGeometry 对 sphere 声明的 centerSphere 阳极自相矛盾):
%     E(r) = V*K/r^(p-1),  phi_w(a)=1, phi_w(b)=0     (p=2 圆柱, p=3 球壳)
%     常数迁移率: r^p(t) = r0^p -/+ p*mu*V*K*t
%   阳极累计感应电荷用权重势差**直接**给出 (精确, 无形状近似):
%     电子 (r0->a): Qe(t) = q*(phi_w(r(t)) - phi_w(r0))   -> 终值 q*(1-phi_w(r0))
%     离子 (r0->b): Qi(t) = q*(phi_w(r0) - phi_w(r(t)))   -> 终值 q*phi_w(r0)
%   逐样本 dq[n] = Qcum(t_{n+1}) - Qcum(t_n) 正是 filters.m 中
%   CSA 离散式 v[n] = a v[n-1] + q[n]/Cf 所需的"该采样区间注入电荷" —— 对收集
%   时间短于 Ts 的快成分严格正确; 按 i(t_n)*Ts 采样会丢尖峰面积 (实测少 20%)。
%   窗口 waveWindow_s 之外未收集的份额 = 弹道亏损, 由同一正向模型的电荷注入刻度吸收。
%   守恒: sum(dq) = q*(phi_w 变化之和) <= |q|, 电子+离子份额 = q (单测锁定)。
%   符号约定: 本函数按**幅值**工作 (q_C>0 表示感应电荷大小); 而 ramoCurrent 按
%   **物理符号**工作 (同一正 q_C 给出电子支 -q)。两者各自自洽, 但不可混用。

if nargin < 5, error("tepc:ramo:Args","需要 q_C, r0, field, mob, cfg"); end
fm = tepc.detector.fieldOf(field, field.a, field.b, field.hv_V, tepc.detector.fieldKindOf(field));
a = fm.a; b = fm.b; p = fm.p;   % fem_map 模式下幂律指数 p 无闭式对应 -> NaN (仅作记录, 轨道走 fm.rOfT)
if ~(r0_m > a) || ~(r0_m < b)
    error("tepc:ramo:BadStart","起点 r0=%.3e 必须在 (%.3e,%.3e) 内", r0_m, a, b);
end
mu_e = mob.mu_e_m2_Vs; mu_i = mob.mu_i_m2_Vs;
if ~(mu_e > 0) || ~(mu_i > 0)
    error("tepc:ramo:BadMobility","迁移率必须为正");
end
Ts = cfg.electronics.sampleTime_s;
if ~(Ts > 0), error("tepc:ramo:BadTs","sampleTime_s 必须为正"); end
tEnd = waveWindow_s(cfg);
N = max(2, round(tEnd/Ts) + 1);
tb = (0:N)*Ts;                                  % 采样区间端点

phi0 = fm.phiw(r0_m);
% r^p(t) = r0^p -/+ p*mu*V*K*t, 到达电极后冻结。
% 轨道取自 fieldModel.rOfT —— 全项目只留一份 r^p(t) 解, 且它按方向钳在 a / b
% (这里曾另写一份并钳到 0, 会让 phi_w(0)=Inf; 钳位也必须在取 p 次根之前,
%  否则负数 .^(1/p) 返回复数并经 phi_w 污染 dq, 实测 sum(dq)/q 变成 -0.44)。
re = fm.rOfT(r0_m, mu_e, -1, tb);                % 电子向阳极
ri = fm.rOfT(r0_m, mu_i, +1, tb);                % 离子向阴极
Qe_cum = q_C*(fm.phiw(re) - phi0);              % 单调升到 q(1-phi0)
Qi_cum = q_C*(phi0 - fm.phiw(ri));              % 单调升到 q*phi0
Qcum = Qe_cum + Qi_cum;
dq = diff(Qcum);
dq = max(dq, 0);                                % 两支各自单调, 数值兜底

tau_e = fm.tCollect(r0_m, mu_e, a);
tau_i = fm.tCollect(r0_m, mu_i, b);
out = struct('t', tb(1:N).', 'dq', dq(:), 'i', dq/Ts, ...
    'Q_e_C', q_C*(1 - phi0), 'Q_i_C', q_C*phi0, ...
    'phi_w', phi0, 'tau_e_s', tau_e, 'tau_i_s', tau_i, 'r0_m', r0_m, ...
    'Q_collected_in_window_C', sum(dq), 'q_C', q_C, 'Ts', Ts, ...
    'field_kind', fm.kind, 'field_p', p);
end

function te = waveWindow_s(cfg)
te = tepc.electronics.waveTailTau()*cfg.electronics.shaping_s;
if isfield(cfg.electronics,'waveWindow_s') && ~isempty(cfg.electronics.waveWindow_s)
    te = cfg.electronics.waveWindow_s;
end
end
