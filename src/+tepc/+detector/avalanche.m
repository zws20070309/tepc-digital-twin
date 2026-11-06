function out = avalanche(field, opts, rs)
%AVALANCHE Townsend 雪崩与增益涨落 (L2)。
%   alpha(E) = (ln2/deltaV)*E [1/m] (Diethorn, deltaV ASSUMED);
%   G_mean = exp( int_a^{rStart} alpha dr ), rStart 缺省 = 10a (有效电离半径, ASSUMED)。
%   单事件涨落: Polya(theta) = Gamma(theta, mean/theta) (Marsaglia-Tsang 自实现)。
%   空间电荷: G_eff = G0/(1 + k_sc*Q_ion_C) (opts.spaceCharge)。

if nargin < 3, rs = RandStream('Threefry'); end
if nargin < 2, opts = struct(); end
if ~isfield(opts,'deltaV_V')
    opts.deltaV_V = tepc.config.constants('detector.diethorn.deltaV_V');
end   % 值与来源在 docs/constants.json 登记
if ~isfield(opts,'theta')
    opts.theta = tepc.config.constants('detector.polya.theta');
end   % 同上: 注册表是唯一来源, 代码里不留镜像
if ~isfield(opts,'spaceCharge'),opts.spaceCharge = false; end
if ~isfield(opts,'Q_ion_C'),    opts.Q_ion_C = 0; end
if ~isfield(opts,'k_sc'),       opts.k_sc = 0; end
if ~isfield(opts,'rStart_m'),   opts.rStart_m = []; end

a = field.a; b = field.b; V = field.hv_V;
rStart = opts.rStart_m;
if isempty(rStart) || rStart <= a
    rStart = tepc.config.constants('detector.avalanche.rStartFactor') * a;   % ASSUMED 有效电离半径
end
% 必须夹在 (a,b) 内: 越过阴极后真实场为 0, 而 intE 仍按电极场积分 => 增益无界虚高。
% (resolve 与 validate 的增益门禁都做了这个钳位, 唯独真正算增益的 avalanche 没做,
%  三者对同一几何会给出不同的 G。)
rStart = min(rStart, b*tepc.config.constants('detector.avalanche.rStartClampUpperFracOfB'));
if ~(rStart > a)
    error("tepc:detector:NoAvalancheRoom", ...
        "a=%.3e 与 b=%.3e 之间放不下雪崩区 (rStart=%.3e)", a, b, rStart);
end
% 场经 fieldOf 统一取 (mode=analytic 即 fieldModel; 曾在此硬编码同轴圆柱式)
fm = tepc.detector.fieldOf(field, a, b, V, tepc.detector.fieldKindOf(field));
G0 = exp( (log(2)/opts.deltaV_V) * fm.intE(a, rStart) );
if opts.spaceCharge && opts.Q_ion_C > 0
    G0 = G0 / (1 + opts.k_sc*opts.Q_ion_C);
end
% Polya 增益涨落: Gamma(theta, G0/theta) 的均值 = G0
Gevent = gammaSample(opts.theta, G0/opts.theta, rs);
out = struct('G_mean', G0, 'G_event', Gevent, 'theta', opts.theta, ...
    'spaceChargeApplied', opts.spaceCharge && opts.Q_ion_C > 0);
end

function x = gammaSample(shape, scale, rs)
% GAMMASAMPLE Marsaglia-Tsang (2000), shape>0, 无工具箱依赖。
if shape < 1
    u = rand(rs);
    x = gammaSample(shape+1, scale, rs) * u^(1/shape);
    return;
end
d = shape - 1/3; c = 1/sqrt(9*d);
while true
    xx = randn(rs); v = (1+c*xx)^3;
    if v <= 0, continue; end
    u = rand(rs);
    if u < 1 - 0.0331*xx^4, x = d*v*scale; return; end
    if log(u) < 0.5*xx^2 + d*(1 - v + log(v)), x = d*v*scale; return; end
end
end
