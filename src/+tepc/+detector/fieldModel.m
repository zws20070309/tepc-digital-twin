function f = fieldModel(a_m, b_m, V_V, kind)
%FIELDMODEL 圆柱/球壳电极结构的**单一**场与权重场模型 (全项目唯一实现)。
%   历史缺陷: avalanche / ramoWaveform / driftCollect / ramoCurrent 各自硬编码
%   同轴圆柱公式, 而 GUI 的 E(a) 显示用球壳公式 -> 同一台仪器在代码里存在两种
%   互相矛盾的场, 且无法整体切换。现统一由此函数产出。
%
%   两种几何都是静电学精确解, 写成同一指数形式 (E(r) = V*K/r^(p-1)):
%     kind 'cylinder' (同轴圆柱, p=2):  K = 1/ln(b/a)
%     kind 'sphere'   (同心球壳,   p=3): K = 1/(1/a - 1/b)
%   权重场 (Ramo):  phi_w(r) = K * int_r^b s^(1-p) ds, 满足 phi_w(a)=1, phi_w(b)=0
%     p=2: phi_w = ln(b/r)/ln(b/a);  p=3: phi_w = (1/r - 1/b)/(1/a - 1/b)
%   恒电场积分:  int_r1^r2 E dr = V*K * (p==2 ? ln(r2/r1) : (r1^(2-p)-r2^(2-p))/(p-2))
%   常数迁移率下的径向运动 dr/dt = mu*V*K/r^(p-1) 的精确解:
%     r(t)^p = r0^p +/- p*mu*V*K*t   (+ 离子向外, - 电子向阳极)
%   收集时间: 离子 r0->b, 电子 r0->a。
%
%   返回 f: a b hv_V p K kind note, 及函数句柄 (仅此六个):
%     E(r) [V/m]、phiw(r) [-]、intE(r1,r2) [V]、
%     rOfT(r0,mu,sgn,t) [m] (sgn=-1 向阳极、钳在 a; +1 向阴极、钳在 b)、
%     tCollect(r0,mu,rEnd) [s]、gainExponent(rStart,deltaV) [-]

if nargin < 3 || isempty(V_V), V_V = 0; end
if nargin < 4 || isempty(kind), kind = "cylinder"; end
a = double(a_m); b = double(b_m); V = double(V_V);
if ~(a > 0) || ~(b > a)
    error("tepc:field:BadRadii","需要 0 < a (%.3e) < b (%.3e)", a, b);
end
kk = lower(string(kind));
switch kk
    case "cylinder", p = 2; K = 1/log(b/a);
    case "sphere",   p = 3; K = 1/(1/a - 1/b);
    otherwise
        % 单条消息必须是**一个**字符串: 用 [ "a" "b" ] 拼相邻字面量会得到 1x2 string 数组,
        % error() 随即抛 MATLAB:error:badMessageArgument, 真正的标识符 tepc:field:BadKind
        % 就丢了 (实测: test_electronics:624 因此红灯)。跨行拼接只能用 + 或 []。
        error("tepc:field:BadKind", ...
            "场类型 kind 只能来自电极拓扑 (tepc.geometry.electrode 给出 'cylinder' " + ...
            "或 'sphere'), 实得 '%s'。被废除的 fieldGeometry 字段不再被读取。", kind);
end
f = struct();
f.kind = char(kk); f.p = p; f.K = K; f.a = a; f.b = b; f.hv_V = V;
f.E      = @(r) V*K./r.^(p-1);
f.phiw   = @(r) K.*phiwIntegral(r, b, p);
f.intE   = @(r1, r2) V*K.*intPow(r1, r2, p);
f.rOfT   = @(r0, mu, sgn, t) powerDrift(r0, p, K, V, mu, sgn, t, a, b);
f.tCollect = @(r0, mu, rEnd) collectTime(r0, p, K, V, mu, rEnd);
f.gainExponent = @(rStart, deltaV) (log(2)/deltaV) * V * K * intPow(a, rStart, p);
f.note = "E(r)=V*K/r^(p-1); K_cyl=1/ln(b/a), K_sph=1/(1/a-1/b); phi_w(a)=1, phi_w(b)=0";
end

function v = intPow(r1, r2, p)
% INTPOW int_{r1}^{r2} s^(1-p) ds  (p=2 -> 对数; 一般幂律)
if p == 2
    v = log(r2./r1);
else
    v = (r1.^(2-p) - r2.^(2-p)) / (p - 2);
end
end

function v = phiwIntegral(r, b, p)
% int_r^b s^(1-p) ds
if p == 2
    v = log(b./r);
else
    v = (r.^(2-p) - b^(2-p)) / (p - 2);
end
end

function r = powerDrift(r0, p, K, V, mu, sgn, t, a, b)
% r(t)^p = r0^p + sgn*p*mu*V*K*t   (sgn=+1 向外, -1 向阳极)
% 钳位必须在取 p 次根**之前**: 负数的 .^(1/p) 在 MATLAB 里返回复数。
arg = r0.^p + sgn*p*mu*V*K*t;
% 钳到"它要去的那块电极"而不是 0: 钳到 0 会让 phi_w(0)=Inf、E(0)=Inf。
if sgn < 0, arg = max(arg, a^p); else, arg = min(arg, b^p); end
r = arg.^(1/p);
end

function te = collectTime(r0, p, K, V, mu, rEnd)
% 从 r0 单调漂移到 rEnd 所需时间 (常数迁移率 + 本模型电场)
if ~(mu > 0) || ~(V > 0) || ~(abs(rEnd - r0) > 0)
    te = Inf; return;
end
sgn = sign(rEnd - r0);
d = abs(rEnd.^p - r0.^p);
te = d / (p*mu*V*K);
end
