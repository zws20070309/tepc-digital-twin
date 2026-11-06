function f = fieldOf(field, a_m, b_m, V_V, kind)
%FIELDOF 场模型统一入口: 按 field.mode 在解析闭式与 FEM 场图之间分派。
%   f = fieldOf(field)                       用 field.a/b/hv_V 与 fieldKindOf(field)
%   f = fieldOf(field, a_m, b_m, V_V, kind)  显式给出几何 (调用方的阳极半径可能
%                                            与 field.a 不同, 例如逐事件等效半径)
%   出参契约 (两种模式同一套函数句柄, 单位一致):
%     E(r) [V/m]、phiw(r) [-]、intE(r1,r2) [V]、
%     rOfT(r0,mu,sgn,t) [m]、tCollect(r0,mu,rEnd) [s]、gainExponent(rStart,dV) [-]
%   mode 由 tepc.detector.fieldModeOf 解析, 缺省 'analytic':
%     analytic -> 原样返回 tepc.detector.fieldModel(a,b,V,kind) 的输出: 不增字段、
%                 不改数值, 历史行为逐位不变 (金基线 G_mean=136.01301895613094)。
%     fem_map  -> 用有限元场图构造同名句柄。场图缺失/几何不符/指纹过期一律抛错,
%                 绝不静默退回解析场 —— 静默退回会让"这一版结果用的是实测场"这件
%                 事在产物里彻底查不出来。
%   fem_map 模式的插值口径 (全部是分段线性, 自变量 = 对数间隔的径向采样路径):
%     E(r)      = 采样路径上 |E| = hypot(E_r, E_z) 的插值; r 超界时钳在路径端点值
%                 (不外推: 1/r 外推会把网格伪差放大成无界的场)。
%     phi_w(r)  = V(r)/hv_V 的插值, 末端补 (b, 0) —— V(b)=0 是 Dirichlet 边界值本身,
%                 精确已知, 不是外推; 起点 r=a 的采样点即阳极面上的节点, V=hv_V。
%                 于是严格 phi_w(a)=1, phi_w(b)=0, 与 fieldModel 的端点条件同构。
%     intE(r1,r2) = V(r1) - V(r2): 沿电力线的场强积分就是电位差 (静电学的定义式),
%                 用插值电位而不是 |E| 的梯形积分 —— 后者在粗网格上系统性低估
%                 (实测 400 点路径的梯形积分比电位差低 ~3e-3 相对量)。
%     rOfT / tCollect: 常数迁移率 dr/dt = sgn*mu*E(r) 的解写成
%                 G(r) = int^r ds/E(s) (在采样路径上 cumtrapz 预积), 则
%                 t = |G(r)-G(r0)|/mu, r(t) = G^-1(G(r0) + sgn*mu*t), 并按 sgn
%                 钳在 a / b (与 fieldModel.powerDrift 同一钳位方向)。
%     p / K     = NaN: 幂律指数与 K=1/ln(b/a) 是闭式解的属性, 一般场图没有对应物。
%                 任何"读 fm.K 走闭式"的代码在 fem_map 下会得到 NaN 而显式失败,
%                 比静默给出一个假 K 安全。
%
%   场图来源: field.map (solveElectrostatic 的返回值, 内存 struct) 优先;
%   否则 field.mapFile (.mat, 由 opts.savePath 落盘) —— 按 (路径, mtime, 字节数)
%   做进程内缓存, 与 tepc.config.constants 同一失效判据, 所以逐事件调用不会
%   反复读盘, 而文件被换掉后一定读到新内容。
%
%   错误标识符
%     tepc:field:BadMode              mode 值域外 (由 fieldModeOf 抛)
%     tepc:field:MapMissing           fem_map 模式但没有场图, 也没有 mapFile
%     tepc:field:MapFileMissing       mapFile 指向的文件不存在
%     tepc:field:MapSchema            场图缺字段 / schema 不是 tepc-fieldmap-v1
%     tepc:field:MapGeometry          场图几何/高压与请求值不符 (相对容差 1e-9)
%     tepc:field:MapStaleFingerprint  场图存的指纹与按自身身份重算的指纹不一致
%     tepc:field:MapNotFinite         场图采样路径含非有限值
%     tepc:field:MapPath              采样路径点不足或非严格递增

if nargin < 1 || ~isstruct(field)
    error("tepc:field:BadArgs", "fieldOf 需要 field 结构体作为第一个入参");
end
mode = tepc.detector.fieldModeOf(field);
if nargin < 5 || isempty(kind), kind = tepc.detector.fieldKindOf(field); end
if nargin < 4 || isempty(V_V), V_V = fieldHv(field); end
if nargin < 3 || isempty(b_m), b_m = fieldRequired(field, 'b'); end
if nargin < 2 || isempty(a_m), a_m = fieldRequired(field, 'a'); end
if strcmp(lower(char(string(mode))), 'analytic')
    f = tepc.detector.fieldModel(a_m, b_m, V_V, kind);
    return;
end
f = fieldFromMap(field, double(a_m), double(b_m), double(V_V), kind);
end

% ==================== 局部实现 ====================

function f = fieldFromMap(field, a, b, V, kind)
%FIELDFROMMAP fem_map 模式: 校验场图并包装成与 fieldModel 同名的句柄集。
mp = acquireMap(field, a, b, V);
rp = double(mp.path.r_m(:));
Em = double(mp.path.Emag(:));
Vp = double(mp.path.V(:));
pw = Vp/V;
% Dirichlet 阴极面值是精确数据, 作为插值表的末端控制点补进去。
if rp(end) < b*(1 - 1e-6)
    rp = [rp; b];
    Vp = [Vp; 0];
    pw = [pw; 0];
    Em = [Em; Em(end)];          % 末端 |E| 取路径上最后一点的实测值 (不外推)
end
if numel(rp) < 3 || ~all(diff(rp) > 0)
    error("tepc:field:MapPath", ...
        "场图采样路径必须是 >=3 点严格递增 (实得 %d 点, 范围 %.6e..%.6e)", ...
        numel(rp), rp(1), rp(end));
end
if ~all(isfinite(rp)) || ~all(isfinite(Em)) || ~all(isfinite(Vp)) || ~all(Em > 0)
    error("tepc:field:MapNotFinite", ...
        "场图采样路径必须有限、E 必须为正 (非有限 %d 个, E<=0 %d 个)", ...
        sum(~isfinite(Em)) + sum(~isfinite(Vp)), sum(Em <= 0));
end
% 电位降的累积积分 G(r) = int_a^r ds/E(s) [s*V/m ... 单位 m/(V/m)=m^2/V]:
% 1/E 在阳极面按 r->0 发散, 但路径起点是 a 而不是 0, 所以有限。
invE = 1./Em;
G = cumtrapz(rp, invE);
f = struct();
f.kind = char(string(kind));
f.p = NaN; f.K = NaN;
f.a = a; f.b = b; f.hv_V = V;
f.mode = 'fem_map';
f.gridLevel = double(mp.gridLevel);
f.geometry = char(string(mp.geometry));
f.fingerprint = char(string(mp.fingerprint));
f.nCells = double(mp.nCells);
f.nDof = double(mp.nDof);
f.hmax_m = double(mp.hmax_m);
f.mapEvidence = mp.evidence;
f.mapAnalytic = mp.analytic;
f.mapIntegral = mp.integral;
f.note = char("E(r)/phi_w(r)/intE 来自 2-D 轴对称有限元场图插值 " ...
    + "(tepc.detector.solveElectrostatic); p 与 K 无闭式对应 -> NaN");
f.E      = @(r) interpClamped(rp, Em, r);
f.V      = @(r) interpClamped(rp, Vp, r);
f.phiw   = @(r) interpClamped(rp, pw, r);
f.intE   = @(r1, r2) interpClamped(rp, Vp, r1) - interpClamped(rp, Vp, r2);
f.rOfT   = @(r0, mu, sgn, t) rOfTMap(rp, G, r0, mu, sgn, t, a, b);
f.tCollect = @(r0, mu, rEnd) collectTimeMap(G, rp, r0, mu, rEnd);
f.gainExponent = @(rStart, dV) (log(2)/dV) * (interpClamped(rp, Vp, a) - interpClamped(rp, Vp, rStart));
end

function y = interpClamped(xs, ys, x)
%INTERPCLAMPED 分段线性插值, 自变量钳在 [xs(1), xs(end)] (禁外推)。
q = min(max(double(x(:)), xs(1)), xs(end));
y = interp1(xs, ys, q, 'linear');
y = reshape(y, size(x));
end

function r = rOfTMap(rp, G, r0, mu, sgn, t, a, b)
% 半径轨迹 r(t): G(r) = G(r0) + sgn*mu*t, 再反查单调的 G 表。
% 钳位方向与 fieldModel.powerDrift 一致: sgn<0 钳在阳极 a, sgn>0 钳在阴极 b;
% 钳在"它要去的那块电极"而不是 0, 否则 phi_w(0)=Inf、E(0)=Inf。
g0 = interpClamped(rp, G, r0);
gt = g0 + double(sgn).*double(mu).*double(t);
if sgn < 0
    gt = max(gt, G(1));
else
    gt = min(gt, G(end));
end
r = interp1(G, rp, gt, 'linear');
r = reshape(r, size(t));
end

function te = collectTimeMap(G, rp, r0, mu, rEnd)
% 从 r0 单调漂移到 rEnd 所需时间: |G(rEnd)-G(r0)|/mu。
% 与 fieldModel.collectTime 同一退化契约: 迁移率非正或根本不动 -> Inf。
if ~(isnumeric(mu) && isscalar(mu) && isfinite(mu) && mu > 0) ...
        || ~(abs(double(rEnd) - double(r0)) > 0)
    te = Inf; return;
end
g0 = interpClamped(rp, G, r0);
g1 = interpClamped(rp, G, rEnd);
te = abs(g1 - g0)/mu;
end

function mp = acquireMap(field, a, b, V)
%ACQUIREMAP 取场图: 内存优先, 否则读 .mat 并按 (路径,mtime,字节数) 缓存。
mp = [];
if isfield(field, 'map') && ~isempty(field.map)
    mp = field.map;
    src = 'field.map (内存)';
elseif isfield(field, 'mapFile') && ~isempty(field.mapFile)
    fp = char(string(field.mapFile));
    if ~isfile(fp)
        error("tepc:field:MapFileMissing", ...
            "field.mode='fem_map' 要求场图文件, 但 %s 不存在 (先用 tepc.detector.solveElectrostatic 的 opts.savePath 落盘)", fp);
    end
    mp = cachedLoad(fp);
    src = fp;
else
    error("tepc:field:MapMissing", ...
        "field.mode='fem_map' 但没有场图: 需要 field.map (tepc.detector.solveElectrostatic 的返回结构) 或 field.mapFile (.mat 路径)。此处不静默退回解析场。");
end
validateMap(mp, a, b, V, src);
end

function validateMap(mp, a, b, V, src)
%VALIDATEMAP 场图合法性: schema -> 必要字段 -> 几何 -> 指纹 -> 有限性。
need = {'schema', 'a_m', 'b_m', 'hv_V', 'gridLevel', 'geometry', 'fingerprint', ...
    'path', 'nCells', 'nDof', 'hmax_m', 'evidence'};
if ~isstruct(mp)
    error("tepc:field:MapSchema", "场图必须是 struct (实得 %s, 来源 %s)", class(mp), src);
end
miss = need(~isfield(mp, need));
if ~isempty(miss)
    error("tepc:field:MapSchema", "场图缺字段: %s (来源 %s)", strjoin(miss, ','), src);
end
pf = {'r_m', 'V', 'Emag'};
sub = pf(~isfield(mp.path, pf));
if ~isempty(sub)
    error("tepc:field:MapSchema", "场图 path 缺字段: %s (来源 %s)", strjoin(sub, ','), src);
end
if ~strcmp(char(string(mp.schema)), 'tepc-fieldmap-v1')
    error("tepc:field:MapSchema", "场图 schema='%s' 不被支持 (需要 'tepc-fieldmap-v1', 来源 %s)", ...
        char(string(mp.schema)), src);
end
tol = 1e-9;
da = abs(double(mp.a_m) - a)/max(abs(a), eps);
db = abs(double(mp.b_m) - b)/max(abs(b), eps);
dV = abs(double(mp.hv_V) - V)/max(abs(V), 1);
if da > tol || db > tol || dV > tol
    error("tepc:field:MapGeometry", ...
        "场图几何与请求不符: 场图 (a=%.9e, b=%.9e, V=%.9g) vs 请求 (a=%.9e, b=%.9e, V=%.9g), 相对偏差 a=%.2e b=%.2e V=%.2e, 超过容差 %.0e。", ...
        mp.a_m, mp.b_m, mp.hv_V, a, b, V, da, db, dV, tol);
end
want = tepc.detector.fieldMapFingerprint(double(mp.a_m), double(mp.b_m), ...
    double(mp.hv_V), double(mp.gridLevel), char(string(mp.geometry)));
if ~strcmp(char(string(mp.fingerprint)), want)
    error("tepc:field:MapStaleFingerprint", ...
        "场图指纹过期或被改写: 文件里记 %s, 按场图自身身份 (a,b,hv,gridLevel=%s,geometry=%s) 重算得 %s。", ...
        char(string(mp.fingerprint)), mat2str(mp.gridLevel), char(string(mp.geometry)), want);
end
if ~all(isfinite(double(mp.path.r_m(:)))) || ~all(isfinite(double(mp.path.V(:))))
    error("tepc:field:MapNotFinite", "场图路径量含非有限值 (来源 %s)", src);
end
end

function mp = cachedLoad(fp)
persistent key obj
d = dir(fp);
k = sprintf('%s|%s|%d', fp, d.date, d.bytes);
if isempty(key) || ~strcmp(key, k)
    s = load(fp);
    if isfield(s, 'map')
        obj = s.map;
    elseif isfield(s, 'tepcFieldMap')
        obj = s.tepcFieldMap;
    else
        nm = fieldnames(s);
        if numel(nm) ~= 1
            error("tepc:field:MapSchema", ...
                "场图 .mat 里必须有单个变量 map (或 tepcFieldMap), 实得 %d 个变量: %s", ...
                numel(nm), strjoin(nm', ','));
        end
        obj = s.(nm{1});
    end
    key = k;
end
mp = obj;
end

function v = fieldHv(field)
if isfield(field, 'hv_V') && ~isempty(field.hv_V)
    v = field.hv_V;
else
    error("tepc:field:BadArgs", "field 缺 hv_V 且调用方未显式传 V_V");
end
end

function v = fieldRequired(field, nm)
if isfield(field, nm) && ~isempty(field.(nm))
    v = field.(nm);
else
    error("tepc:field:BadArgs", "field 缺 %s 且调用方未显式传该几何量", nm);
end
end
