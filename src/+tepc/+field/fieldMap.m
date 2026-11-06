function [V, E, info] = fieldMap(F, xyz, args)
%FIELDMAP  静电场图容器的逐点插值入口与失效判定。
%
%   [V, E] = tepc.field.fieldMap(F, xyz)
%       xyz 是 Nx2 (二维) 或 Nx3 (三维) 的米坐标, 行 = 点。输出
%       V 为 Nx1 电位 [V], E 为 Nx2/Nx3 电场 [V/m] (E = -grad V)。
%   [V, E] = tepc.field.fieldMap(F, xyz, quantity="weighting")
%       取权重电位 (无量纲, 内边界=1、外边界=0) 与权重场 [1/m] —— Ramo 感应电流要的是
%       这个场, 不是电位场; 两者来自 tepc.field.solveElectrostatic 的两次独立求解。
%   [V, E] = tepc.field.fieldMap(F, xyz, geometry_sha256=hash)
%       把场图绑到几何清单的哈希上。与 F.geometry_sha256 不一致即 error(tepc:field:StaleFieldMap):
%       改了尺寸还拿旧场图算增益/漂移, 是这类"缓存 vs 真相源"问题里唯一会静默出数的形态。
%   [V, E, info] = ...  info 带 method/quantity/n_outside 等诊断字段。
%   info.is_analytic 指"这次求值用的是闭式还是场图", info.container_is_analytic 才是容器
%   本身的性质: 对 FEM 容器显式要 method="analytic" 时, 前者为 true 而后者为 false。
%
%   容器 F 由 tepc.field.solveElectrostatic 产出, 必须含字段
%     dim, nodes, potential, ex, ey (dim=3 时还要 ez), weighting_potential, a_m, b_m,
%     V0_V, mode, isAnalytic, field_mode, geometry_sha256
%   (解析降级容器没有 weighting 以外的额外要求, 字段集相同。)
%
%   isAnalytic / field_mode 的语义 (上层按这个区分, 不要靠猜):
%     isAnalytic=false, field_mode="fem_map"  -> 真 FEM 场图, 插值走 pde 结果对象
%     isAnalytic=true,  field_mode="analytic" -> 理想闭式采样, 逐点按解析式重算
%   与配置里的 field.mode 对应: field.mode="analytic" 配 isAnalytic=true,
%   field.mode="fem_map" 配 isAnalytic=false。两条铁律:
%   (1) 求值轨道由**容器的来源**决定, method 只在轨道内部选实现 —— 在 fem_map 容器上请求
%       method="analytic" 直接 error(tepc:field:AnalyticOverrideRejected), 否则一次
%       field.mode=fem_map 的运行会产出解析场的数, 而这正是场图唯一能表达的东西 (丝面高斯面
%       非均匀性) 被静默抹掉的路径;
%   (2) 容器带 usable_for_production=false (求解时精度门禁未过, 或 PDE 失败后降级的解析采样)
%       时 error(tepc:field:MapGateFailed), 不返回任何数: 半对的场图与错的场图在下游
%       看不出区别, 而"缓存 vs 真相源"里唯一会静默出数的形态就是让容器带着假声明继续走。
%   哈希绑定 (geometry_sha256) 不匹配时 error(tepc:field:StaleFieldMap), 不退回解析。
%
%   数值/接口注意事项:
%   * interpolateSolution 与 evaluateGradient 是 pde.StationaryResults 的结果对象方法
%     (不是顶层函数), 查询点用 dim x N 的矩阵或坐标向量形式传入; 早期/其它结果类上
%     对应的名字是 interpolate, 这里两条都试, 都失败再退到 scatteredInterpolant。
%   * scatteredInterpolant 用的是**节点散值线性插值**, 凸包包含内导体挖掉的区域, 所以
%     域外判定不能靠 FillBehavior, 一律用同心半径区间显式判 (见 inDomain)。
%   * 域外的点给 NaN (可用 outside_value 换成别的填充值), 并在 info.n_outside 里计数:
%     NaN 会顺着增益/漂移链传下去变成可诊断的缺失, 而不是被 0 冒充。
%   * 丝面附近 E 正比 1/r, 插值/散值重构在 r 接近 a 时最不可靠: 那里的结果要连同
%     F.convergence、F.gate 与 F.analytic_window 一起用, 不能单独取峰值。
%     求解侧的逐点判据本身就只在 r >= F.analytic_window.r_min_m 上评估
%     (F.analytic_field_max_rel_dev 是窗内值, F.analytic_field_max_rel_err 是全域值)。

% ---------------- 入参 ----------------
arguments
    F (1,1) struct
    xyz (:,:) double
    args.quantity (1,1) string = "potential"
    args.geometry_sha256 (1,1) string = ""
    args.method (1,1) string = ""
    args.outside_value (1,1) double = NaN
    args.radius_tol (1,1) double = NaN
end

quantity = lower(string(args.quantity));
if numel(quantity) ~= 1
    error("tepc:field:BadFieldMap", "quantity 必须是标量文本");
end
if ~any(quantity == ["potential", "weighting"])
    error("tepc:field:BadFieldMap", ...
        "quantity 只能是 potential 或 weighting, 实得 %s", quantity);
end
method = lower(string(args.method));
if numel(method) ~= 1
    error("tepc:field:BadFieldMap", "method 必须是标量文本");
end
if strlength(method) == 0
    method = "auto";
end
if ~any(method == ["auto", "fem", "scattered", "analytic"])
    error("tepc:field:BadFieldMap", ...
        "method 只能是 auto / fem / scattered / analytic, 实得 %s", method);
end
tol = args.radius_tol;
if isnan(tol)
    tol = 1e-9;
end
if ~(tol >= 0)
    error("tepc:field:BadFieldMap", "radius_tol 必须非负");
end

requireFields(F);
[isAnalyticMap, fieldMode] = checkModeContract(F);
if quantity == "weighting" && ~isfield(F, 'weighting_potential')
    error("tepc:field:BadFieldMap", ...
        "场图容器没有 weighting_potential 字段 (只做了一次求解), 取不了权重场");
end
checkStaleness(F, string(args.geometry_sha256));

dim = double(F.dim);
if ~(dim == 2 || dim == 3)
    error("tepc:field:BadFieldMap", "F.dim 只能是 2 或 3, 实得 %.6g", dim);
end
pts = double(xyz);
n = size(pts, 1);
if ~isempty(pts) && size(pts, 2) ~= dim
    error("tepc:field:DimMismatch", ...
        "场图是 %d 维的, 查询点却有 %d 列 (应为 Nx%d)", dim, size(pts, 2), dim);
end
if any(~isfinite(pts(:)))
    error("tepc:field:BadQueryPoints", "查询点里有 NaN/Inf");
end

% 求值轨道由**容器的来源**唯一决定: fem_map 容器只能读离散解, analytic 容器只能读闭式。
% method 只在这两条轨道内部选插值实现, 不允许把 FEM 场图换成闭式来算 (那会让
% field.mode=fem_map 的运行悄悄产出解析场所需的数)。
if isAnalyticMap
    if method == "fem"
        error("tepc:field:BadFieldMap", ...
            "method=fem 要求 pde 结果句柄, 但容器是解析采样 (field_mode=analytic): 请重新求解或改用 method=scattered/analytic");
    end
    [V, E] = analyticAt(F, pts, dim, quantity);
    usedMethod = "analytic_closed_form";
else
    if method == "analytic"
        error("tepc:field:AnalyticOverrideRejected", ...
            "FEM 场图容器 (field_mode=fem_map) 上不接受 method=analytic: 那等于把已解出的离散场换成理想同轴闭式, 场图里的高斯面非均匀性与任何几何整形都会凭空消失。要闭式结果请显式用 field_mode=analytic 的容器");
    end
    if method == "scattered"
        [V, E, usedMethod] = scatteredAt(F, pts, dim, quantity);
    else
        [V, E, usedMethod] = femAt(F, pts, dim, quantity, method);
    end
end

% 域外点: 同心几何用半径区间显式判定, 一律填 outside_value (默认 NaN)。
[inside, rr] = inDomain(F, pts, tol);
if ~all(inside)
    bad = ~inside;
    V(bad) = args.outside_value;
    E(bad, :) = args.outside_value;
else
    bad = false(n, 1);
end

info = struct();
info.method = char(usedMethod);
info.quantity = char(quantity);
info.n_points = n;
info.n_outside = nnz(bad);
info.is_analytic = usedMethod == "analytic_closed_form";
info.container_is_analytic = isAnalyticMap;
info.field_mode = char(fieldMode);
info.field_mode_inferred = isfield(F, 'field_mode_inferred') && logical(F.field_mode_inferred);
if isAnalyticMap
    info.map_source = "analytic_closed_form";
else
    info.map_source = "fem_map:" + char(string(getFieldOr(F, 'geometry_sha256_source', "unknown")));
end
info.usable_for_production = ~(isfield(F, 'usable_for_production') ...
    && ~isempty(F.usable_for_production) && ~logical(F.usable_for_production));
info.gate_passed = false;
gv = getFieldOr(F, 'gate', struct());
if isstruct(gv) && isfield(gv, 'passed') && ~isempty(gv.passed)
    info.gate_passed = logical(gv.passed);
end
info.container_mode = char(string(getFieldOr(F, 'mode', "unknown")));
info.geometry_sha256 = char(string(getFieldOr(F, 'geometry_sha256', "")));
info.geometry_hash_checked = strlength(lower(string(args.geometry_sha256))) > 0;
info.r_min_m = NaN;
info.r_max_m = NaN;
if n > 0
    info.r_min_m = min(rr);
    info.r_max_m = max(rr);
end
if quantity == "weighting"
    info.units = struct('V', 'dimensionless', 'E', '1/m');
else
    info.units = struct('V', 'V', 'E', 'V/m');
end
info.note = "域外点填 outside_value 且计入 n_outside; 近丝区的可信度要看 F.gate、F.convergence 与 F.analytic_window";
end

% ==================================================================== 容器与失效判定
function requireFields(F)
need = ["dim", "nodes", "potential", "a_m", "b_m"];
missing = strings(0, 1);
for i = 1:numel(need)
    if ~isfield(F, need(i))
        missing(end+1) = need(i); %#ok<AGROW>
    end
end
if ~isempty(missing)
    error("tepc:field:BadFieldMap", ...
        "场图容器缺少字段 (%s): 它不是 tepc.field.solveElectrostatic 的返回值", strjoin(missing, ", "));
end
if ~isfield(F, 'isAnalytic')
    error("tepc:field:BadFieldMap", ...
        "场图容器缺字段 isAnalytic: 无法区分 field.mode 的 analytic 与 fem_map 语义, 拒绝插值");
end
end

function checkStaleness(F, want)
%CHECKSTALENESS 场图与几何清单哈希不一致时 error —— 防"改了尺寸还用旧场图"。
want = lower(string(want));
have = lower(string(getFieldOr(F, 'geometry_sha256', "")));
if strlength(want) == 0
    return;                                     % 调用方没给清单哈希 = 不做绑定检查
end
if strlength(have) == 0
    error("tepc:field:StaleFieldMap", ...
        "场图没有绑定任何几何哈希 (求解时未传 geometry_sha256), 无法证明它对应这份清单: 请带 geometry_sha256 重新求解");
end
if want ~= have
    error("tepc:field:StaleFieldMap", ...
        "场图与几何清单不同源: 清单哈希 %s, 场图哈希 %s (场图按 a_m=%.6e, b_m=%.6e 算出)。尺寸改过后必须重解, 不能沿用旧场图", ...
        want, have, double(F.a_m), double(F.b_m));
end
end

function [isAnalyticMap, fieldMode] = checkModeContract(F)
%CHECKMODECONTRACT 容器的来源声明必须自洽, 且必须带着可用的精度状态进来。
%   isAnalytic <-> field_mode=="analytic" 是同一个事实的两种写法 (老存盘文件只有前者);
%   两者不一致时不猜, 直接拒。
%   usable_for_production=false 的容器 (精度门禁未过, 或求解失败后降级的解析采样)
%   在这里就挡住: 半对的场图和错的场图在下游看不出区别, 而"缓存 vs 真相源"这一类
%   问题里唯一会静默出数的形态就是让容器自己带着假声明继续走。
isAnalyticMap = isfield(F, 'isAnalytic') && logical(F.isAnalytic);
if isfield(F, 'field_mode') && ~isempty(F.field_mode)
    fieldMode = lower(string(F.field_mode));
    if numel(fieldMode) ~= 1
        error("tepc:field:BadFieldMap", "field_mode 必须是标量文本");
    end
    if ~any(fieldMode == ["analytic", "fem_map"])
        error("tepc:field:BadFieldMap", ...
            "field_mode=%s 不在词表 {{analytic, fem_map}} 内: 未知来源的场图无法判断可信度, 拒绝插值", fieldMode);
    end
else
    % 老容器没有 field_mode: 按 isAnalytic 推断并在返回的 info 里记账为"推断"。
    if isAnalyticMap
        fieldMode = "analytic";
    else
        fieldMode = "fem_map";
    end
end
if isAnalyticMap ~= (fieldMode == "analytic")
    error("tepc:field:BadFieldMap", ...
        "场图自相矛盾: isAnalytic=%d 而 field_mode=%s (true<->analytic, false<->fem_map)", ...
        isAnalyticMap, fieldMode);
end
if isfield(F, 'usable_for_production') && ~isempty(F.usable_for_production) ...
        && ~logical(F.usable_for_production)
    g = getFieldOr(F, 'gate', struct());
    why = "";
    if isstruct(g) && isfield(g, 'failed') && ~isempty(g.failed)
        why = "; 未通过的判据: " + string(g.failed);
    end
    if isstruct(g) && isfield(g, 'note') && ~isempty(g.note)
        why = why + "; " + string(g.note);
    end
    % 中括号里相邻的两个双引号标量是两个数组元素 (1x2 string), error 的第二实参必须是
    % 字符向量或字符串标量 -> 这里用 strcat 显式拼接, 否则抛 MATLAB:error:badMessageArgument。
    msgTxt = strcat("场图被标记为不可用于生产 (usable_for_production=false)", why, ...
        "。要拿这些数值做诊断请显式改容器 (F.usable_for_production=true), 本函数不提供绕过开关");
    error("tepc:field:MapGateFailed", "%s", msgTxt);
end
end

function v = getFieldOr(F, name, dflt)
if isfield(F, name) && ~isempty(F.(name))
    v = F.(name);
else
    v = dflt;
end
end

function [inside, rr] = inDomain(F, pts, tol)
% 两种受支持几何 (同轴环、同心球壳) 都是同心圆/球, 域判据就是半径区间。
% 凸包判据 (scatteredInterpolant 的 FillBehavior) 会漏掉内导体挖掉的芯, 故不用它。
rr = sqrt(sum(pts.^2, 2));
a = double(F.a_m);
b = double(F.b_m);
pad = tol*max(a, b) + realmin;
inside = rr >= a - pad & rr <= b + pad;
end

% ==================================================================== 求值路径
function [V, E, usedMethod] = femAt(F, pts, dim, quantity, method)
% FEM 场图: 优先用结果对象在单元上精确插值 (本机二次元, 句柄在容器里), 拿不到句柄时
% 退节点散值的线性插值 —— 注意那是**降阶**读数 (二次元的曲率信息丢掉), usedMethod 会写清楚。
res = [];
if quantity == "weighting"
    if isfield(F, 'fem_w') && ~isempty(F.fem_w)
        res = F.fem_w;
    end
elseif isfield(F, 'fem') && ~isempty(F.fem)
    res = F.fem;
end
if isempty(res)
    if method == "fem"
        error("tepc:field:BadFieldMap", ...
            "要求 method=fem 但容器里没有结果句柄 (存盘前删过 F.fem/F.fem_w): 改用 method=scattered 或重新求解");
    end
    [V, E, usedMethod] = scatteredAt(F, pts, dim, quantity);
    return;
end
usedMethod = "pde_results_interpolate";
qp = pts.';                                     % dim x N
V = nan(size(pts, 1), 1);
E = nan(size(pts, 1), dim);
if isempty(qp)
    return;
end
try
    V = evalNodal(res, qp);
catch ME
    if method == "fem"
        error("tepc:field:BadFieldMap", "结果对象插值失败: %s", ME.message);
    end
    [V, E, usedMethod] = scatteredAt(F, pts, dim, quantity);
    return;
end
% 电场: 优先用 evaluateGradient (逐单元梯度), 失败则退回节点梯度的散值插值。
try
    if dim == 2
        [gx, gy] = evaluateGradient(res, qp(1, :), qp(2, :));
        G = [gx(:), gy(:)];
    else
        [gx, gy, gz] = evaluateGradient(res, qp(1, :), qp(2, :), qp(3, :));
        G = [gx(:), gy(:), gz(:)];
    end
catch
    usedMethod = "pde_results_interpolate_plus_scattered_gradient";
    nodes = double(F.nodes);
    [gxn, gyn, gzn] = containerGradients(F, quantity, dim);
    G = nan(size(pts, 1), dim);
    if dim == 2
        ix = scatteredInterpolant(nodes(:, 1), nodes(:, 2), gxn, 'linear', 'none');
        iy = scatteredInterpolant(nodes(:, 1), nodes(:, 2), gyn, 'linear', 'none');
        G(:, 1) = ix(pts(:, 1), pts(:, 2));
        G(:, 2) = iy(pts(:, 1), pts(:, 2));
    else
        ix = scatteredInterpolant(nodes(:, 1), nodes(:, 2), nodes(:, 3), gxn, 'linear', 'none');
        iy = scatteredInterpolant(nodes(:, 1), nodes(:, 2), nodes(:, 3), gyn, 'linear', 'none');
        iz = scatteredInterpolant(nodes(:, 1), nodes(:, 2), nodes(:, 3), gzn, 'linear', 'none');
        G(:, 1) = ix(pts(:, 1), pts(:, 2), pts(:, 3));
        G(:, 2) = iy(pts(:, 1), pts(:, 2), pts(:, 3));
        G(:, 3) = iz(pts(:, 1), pts(:, 2), pts(:, 3));
    end
end
if numel(V) ~= size(pts, 1)
    error("tepc:field:BadFieldMap", ...
        "插值返回 %d 个值, 查询点有 %d 个: 形状对不上, 拒绝猜测", numel(V), size(pts, 1));
end
% 权重场与电位场都是 -grad(标量位); 区别只在标量位是哪一次求解。
E = -G;
V = V(:);
end

function v = evalNodal(res, qp)
% interpolateSolution 是 pde.StationaryResults 的方法; 早期/其它结果类上叫 interpolate。
% 两个名字都试, 因为本机类定义只找得到前者, 而实测记录里出现过后者。
try
    v = double(res.interpolateSolution(qp));
    return;
catch
    try
        v = double(res.interpolate(qp));
    catch
        v = double(pde.StationaryResults.interpolateSolution(res, qp));
    end
end
end

function [gxn, gyn, gzn] = containerGradients(F, quantity, dim)
% 容器里存好的节点梯度 (solveElectrostatic 已算过, 不必再问 pde)。
if quantity == "weighting"
    gxn = -double(F.wx(:));
    gyn = -double(F.wy(:));
    if dim == 3
        gzn = -double(F.wz(:));
    else
        gzn = [];
    end
else
    gxn = -double(F.ex(:));
    gyn = -double(F.ey(:));
    if dim == 3
        gzn = -double(F.ez(:));
    else
        gzn = [];
    end
end
end

function [V, E, usedMethod] = scatteredAt(F, pts, dim, quantity)
% 节点散值的线性插值。凸包含内导体芯, 所以域外判定在调用处按半径另做一次。
usedMethod = "scatteredInterpolant";
nodes = double(F.nodes);
if size(nodes, 2) ~= dim
    error("tepc:field:BadFieldMap", "F.nodes 是 Nx%d, 与 F.dim=%.6g 不一致", ...
        size(nodes, 2), dim);
end
if quantity == "weighting"
    fv = double(F.weighting_potential(:));
else
    fv = double(F.potential(:));
end
if numel(fv) ~= size(nodes, 1)
    error("tepc:field:BadFieldMap", "节点值 (%d) 与节点数 (%d) 不一致", ...
        numel(fv), size(nodes, 1));
end
V = nan(size(pts, 1), 1);
E = nan(size(pts, 1), dim);
if isempty(pts)
    return;
end
[gxn, gyn, gzn] = containerGradients(F, quantity, dim);
if dim == 2
    iv = scatteredInterpolant(nodes(:, 1), nodes(:, 2), fv, 'linear', 'none');
    ix = scatteredInterpolant(nodes(:, 1), nodes(:, 2), gxn, 'linear', 'none');
    iy = scatteredInterpolant(nodes(:, 1), nodes(:, 2), gyn, 'linear', 'none');
    V = iv(pts(:, 1), pts(:, 2));
    G = [ix(pts(:, 1), pts(:, 2)), iy(pts(:, 1), pts(:, 2))];
else
    iv = scatteredInterpolant(nodes(:, 1), nodes(:, 2), nodes(:, 3), fv, 'linear', 'none');
    ix = scatteredInterpolant(nodes(:, 1), nodes(:, 2), nodes(:, 3), gxn, 'linear', 'none');
    iy = scatteredInterpolant(nodes(:, 1), nodes(:, 2), nodes(:, 3), gyn, 'linear', 'none');
    iz = scatteredInterpolant(nodes(:, 1), nodes(:, 2), nodes(:, 3), gzn, 'linear', 'none');
    V = iv(pts(:, 1), pts(:, 2), pts(:, 3));
    G = [ix(pts(:, 1), pts(:, 2), pts(:, 3)), iy(pts(:, 1), pts(:, 2), pts(:, 3)), ...
        iz(pts(:, 1), pts(:, 2), pts(:, 3))];
end
E = -G;
V = V(:);
end

function [V, E] = analyticAt(F, pts, dim, quantity)
% 解析容器按闭式重算 (没有插值误差, 也没有网格噪声)。
% 与 solveElectrostatic 里的闭式是同一组公式:
%   同轴   V(r) = V0*log(r/b)/log(a/b),  E_r = V0/(r*log(b/a))
%   权重   phi_w(r) = log(b/r)/log(b/a), E_w,r = 1/(r*log(b/a))
%   球壳   V(r) = V0*(a*b/(b-a))*(1/r - 1/b), E_r = V0*a*b/((b-a)*r^2)
a = double(F.a_m);
b = double(F.b_m);
V0 = double(F.V0_V);
if ~(a > 0) || ~(b > a) || ~(V0 > 0)
    error("tepc:field:BadFieldMap", "解析容器需要 0 < a_m < b_m 且 V0_V > 0");
end
n = size(pts, 1);
V = nan(n, 1);
E = nan(n, dim);
if n == 0
    return;
end
r = sqrt(sum(pts.^2, 2));
L = log(b/a);
mode = lower(string(getFieldOr(F, 'mode', "planar")));
w = quantity == "weighting";
scale = V0;
if w
    scale = 1;
end
if dim == 3
    if mode ~= "spherical_check"
        error("tepc:field:BadFieldMap", "三维解析容器只支持 spherical_check 闭式, 实得 mode=%s", mode);
    end
    k = a*b/(b - a);
    if w
        V = (1./max(r, realmin) - 1/b)/(1/a - 1/b);
        Er = k./(max(r, realmin).^2)/(k*(1/a - 1/b))*(1/a - 1/b);   % = 1/(r^2*(1/a-1/b))
        Er = 1./(max(r, realmin).^2*(1/a - 1/b));
    else
        V = scale*k*(1./max(r, realmin) - 1/b);
        Er = scale*k./max(r, realmin).^2;
    end
else
    if ~any(mode == ["planar", "axisymmetric"])
        error("tepc:field:BadFieldMap", ...
            "二维解析容器只支持 planar 或 axisymmetric 闭式, 实得 mode=%s", mode);
    end
    rr = max(r, realmin);
    if w
        V = log(b./rr)/L;
        Er = 1./(rr*L);
    else
        V = scale*log(rr/b)/(-L);
        Er = scale./(rr*L);
    end
end
% E = Er * r_hat (只有径向分量; 丝/球心的奇点在域外判定里已被挡掉)。
E = Er.*pts./max(r, realmin);
end
