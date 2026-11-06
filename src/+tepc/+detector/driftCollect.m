function out = driftCollect(cluster, field, gasTbl, rs, opts)
%DRIFTLEVEL 一维漂移-收集 (L1)。
%   cluster: struct(r0 [m], N0 簇内电子数, t0)
%   field:   struct(a, b, hv_V, 可选 kind) — 场一律取自 tepc.detector.fieldModel
%            (曾硬编码同轴圆柱 E=V/(r ln(b/a)), 与 sphere 几何自相矛盾)。
%   gasTbl:  struct(vd_max [m/s], vd_half_Ed [V m] — v_d=E/N 饱和曲线参数, ASSUMED;
%                   eta_attach [1/m])
%   步进: 自适应 dt=dr/v_d; 纵向扩散 sigma=sqrt(2*D*t), D=v_d*kT/(eE) (Einstein)。
%   附着: 每步 P_surv = exp(-eta*ds)。
%   输出: 收集时间/电子存活份额/到达时间展宽。演示级模型, 输运表 ASSUMED。

if nargin < 5, opts = struct(); end
if ~isfield(opts,'nStepsMax'), opts.nStepsMax = 20000; end
kB = 1.380649e-23; eC = 1.602176634e-19;
% 温度必须显式传入 (旧实现在这里硬编码 293.15 K, 于是 cfg.gas.temperature_K 改到
% 250 K 或 350 K 时扩散量一毫米不动 —— 静默用错温度是物理错误, 不是默认值问题)。
% 注意: 本模块不在事件计算链上 (运行链不调它), 它的行为由 tests/unit/test_drift_collect.m
% 锁住 —— 温度是否真被消费、场类型是否入参、附着单调性、以及不消耗传入的随机流。
if ~isfield(opts,'temperature_K') || isempty(opts.temperature_K)
    error("tepc:drift:MissingTemperature", ...
        "opts.temperature_K 必填 (不得再用硬编码 293.15 K 冒充配置温度)");
end
T = opts.temperature_K;
if ~(T > 200 && T < 400)
    error("tepc:drift:BadTemperature","温度 %.1f K 超出气体模型适用域 [200,400] K", T);
end
a = field.a; b = field.b;
fm = tepc.detector.fieldOf(field, a, b, field.hv_V, tepc.detector.fieldKindOf(field));
r = cluster.r0; t = cluster.t0; w = 1.0;   % 存活权重
path = 0; tArrive = NaN;
for it = 1:opts.nStepsMax
    E = fm.E(r);                           % V/m (与雪崩/Ramo 同一场模型)
    EN = E/(gasTbl.N_density);             % V m^2
    vd = gasTbl.vd_max * EN/(EN + gasTbl.vd_half_Ed);   % 饱和曲线 (ASSUMED)
    vd = max(vd, 1);
    dr = max(min(0.02*r, (b-a)/1000), 1e-7);
    dt = dr/vd;
    t = t + dt;
    path = path + dr;
    D = vd * kB*T/eC / E;                  % Einstein 关系
    sigma = sqrt(2*D*t);
    w = w * exp(-gasTbl.eta_attach*dr);
    r = r - dr;                            % 向阳极漂移
    if r <= a || w < 1e-6
        tArrive = t; break;
    end
end
if isnan(tArrive)
    error("tepc:drift:NoConvergence","漂移未在 %d 步内到达阳极", opts.nStepsMax);
end
out = struct('t_collect_s', tArrive, 'survival', w, 'sigma_long_m', sigma, ...
    'path_m', path, 'N0', cluster.N0, ...
    'note', "ASSUMED 输运参数(无 Magboltz 表); 扩散仅报告量级");
end
