function out = ramoCurrent(q_C, r0_m, field, opts)
%RAMOCURRENT Shockley-Ramo 感应 (L3, i = q v·E_w)。
%   场与权重场一律取自 tepc.detector.fieldModel (全项目唯一实现; 曾在此硬编码
%   同轴圆柱 phi_w=ln(r/b)/ln(a/b), 与配置声明的 sphere 几何自相矛盾):
%     phi_w(a)=1, phi_w(b)=0
%   逐步推进载流子 (电子->阳极, 离子->阴极), 感应电荷用
%   dQ = q * (phi_w(r_new) - phi_w(r_old)) 累积 —— 该式是 i=qvE_w 的精确积分,
%   守恒性(测试锁定): Q_electron + Q_ion = -q (Shockley-Ramo 定理)。
%   opts: mu_e/mu_i [m2/(V s)] (低气压 ASSUMED), tEnd_s, Nt。
%   返回 t, i_e, i_i, Q_e/Q_i 波形与端点感应电荷。

if nargin < 4, opts = struct(); end
if ~isfield(opts,'mu_e'), opts.mu_e = 0.05; end   % m2/(V s) 低气压量级 ASSUMED
if ~isfield(opts,'mu_i'), opts.mu_i = 0.05; end  % 低压按 1/p 缩放后量级 (ASSUMED)
if ~isfield(opts,'tEnd_s'), opts.tEnd_s = 2e-4; end
if ~isfield(opts,'Nt'), opts.Nt = 4000; end
fm = tepc.detector.fieldOf(field, field.a, field.b, field.hv_V, tepc.detector.fieldKindOf(field));
a = fm.a; b = fm.b;
phiw = fm.phiw;
if r0_m <= a || r0_m >= b
    error("tepc:ramo:BadStart","载流子起点必须在 (a,b) 内");
end
t = linspace(0, opts.tEnd_s, opts.Nt);
dt = t(2) - t(1);
Qe = zeros(1, opts.Nt); Qi = zeros(1, opts.Nt);
re = r0_m; ri = r0_m;
for k = 2:opts.Nt
    if re > a
        ve = opts.mu_e * fm.E(re);              % |v| = mu*E
        rn = max(re - ve*dt, a);
        Qe(k) = Qe(k-1) + (-q_C)*(phiw(rn) - phiw(re));  % 电子电荷 -q
        re = rn;
    else, Qe(k) = Qe(k-1); end
    if ri < b
        vi = opts.mu_i * fm.E(ri);
        rn = min(ri + vi*dt, b);
        Qi(k) = Qi(k-1) + (+q_C)*(phiw(rn) - phiw(ri));  % 离子电荷 +q
        ri = rn;
    else, Qi(k) = Qi(k-1); end
end
i_e = gradient(Qe, t); i_i = gradient(Qi, t);
out = struct('t', t, 'i_e', i_e, 'i_i', i_i, 'Q_e_wave', Qe, 'Q_i_wave', Qi, ...
    'Q_electron_C', Qe(end), 'Q_ion_C', Qi(end), ...
    'Q_expected_e', -q_C*(1 - phiw(r0_m)), 'Q_expected_i', -q_C*phiw(r0_m), ...
    'q_C', q_C, 'field_kind', fm.kind, ...
    'mu_e', opts.mu_e, 'mu_i', opts.mu_i, ...
    'note', "解析权重场+线性迁移率(低场); 未含扩散与雪崩时序, 演示级");
end
