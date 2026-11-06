function F = solveElectrostatic(opts, args)
%SOLVEELECTROSTATIC  与几何清单同源的静电场 FEM 求解 (general-form 拉普拉斯)。
%
%   F = tepc.field.solveElectrostatic(opts)
%       opts 是 1x1 结构体, 字段见下表 (可直接由几何清单/已解析配置派生)。
%   F = tepc.field.solveElectrostatic(a_m=12.5e-6, b_m=12.7e-3, V0_V=700)
%       同一批字段也能作为命名参数给出; 命名参数优先于 opts 里的同名字段。
%
%   字段 (单位写在名字里, 全部 SI):
%     必填
%       a_m      double  内导体 (丝/阳极) 半径 [m]。仓库来源 geometry.anodeRadius_um*1e-6
%       b_m      double  外导体 (阴极/气腔壁) 半径 [m], 需 b_m > a_m。
%                        仓库来源 geometry.gasRadius_mm*1e-3
%     可选
%       V0_V                double  内导体电位 [V], 必须 > 0。V=0 时所有积分量为 0,
%                                   Richardson 比与 GCI 的分母都为 0 (无定义)。默认 700
%       mode                string  "planar" | "axisymmetric" | "spherical_check"。默认 "planar"
%       hmax                double  网格最大特征尺寸 [m]。默认 b_m/25
%       hmin                double  网格最小特征尺寸 [m]。默认 a_m (丝半径)
%       hgrad               double  网格渐变率 [-]。默认 1.2
%       refineLevels        double  加密序列层数, 整数且 >= 3 才能估收敛阶。默认 3
%       geometry_sha256     string  几何清单 (manifest) 的 64 位十六进制哈希。给了就把场图
%                                   绑到该清单上; 不给则场图只带参数自哈希 (见下)。默认 ""
%       zlength_m           double  axisymmetric 解释用的柱长 [m], 把"每单位长度"化成总量。
%                                   默认 a_m + b_m
%       eps0_F_per_m        double  介电常数 [F/m]。默认 8.8541878128e-12 (CODATA 2018 真空值;
%                                   气体相对介电常数 ~1.0005 量级, 低于本文件的离散误差量级,
%                                   故不默认引入, 需要时由调用方覆盖)
%       gain_start_factor   double  雪崩积分下限 = gain_start_factor*a_m。默认 1.5
%       gain_outer_factor   double  雪崩积分上限 = a_m + gain_outer_factor*(b_m - a_m)。默认 0.5
%       refineRatio         double  相邻加密层的尺寸比 (Hmax 除以此值)。默认 2 (>= 1.3)
%       hedge_factor        double  丝边界的网格尺寸 = hmin/hedge_factor。generateMesh 的
%                                   'Hedge' 只把**边界**上的单元尺寸钉住, 域内仍由 Hmax/Hgrad
%                                   支配; 缺了它整个对数式电位降被塞进 r=a 外的第一个单元里
%                                   (实测 Hmin=a 时离丝最近的节点环在 r=1.40a) -> 丝面径向
%                                   导数被低估 47%。默认 8
%       r_eval_factor       double  与闭式逐点对比的窗口下限 = r_eval_factor*a_m。默认 1.5
%                                   (与 gain_start_factor 同一物理窗口, 两者独立可调)
%       gate                string  "error" (默认) | "report"。精度门禁的行为, 见下。
%       strict_pde          double  非 0 => PDE 求解失败直接抛错, 不降级为解析采样。默认 0
%       force_analytic      double  非 0 => 完全不调 PDE, 直接返回理想闭式采样容器
%                                   (isAnalytic=true, field_mode="analytic")。这是
%                                   field.mode="analytic" 的生产路径。默认 0
%
%   求解配方 (本机 R2025a + PDE Toolbox 实测通过):
%       m = createpde();
%       geometryFromEdges(m, decsg([1 1; 0 0; 0 0; b a], '(A-B)', {'A', 'B'}));
%       m.specifyCoefficients('m',0,'d',0,'c',1,'a',0,'f',0); % 五项必须给全
%       m.applyBoundaryCondition('dirichlet','Edge',1:4,'u',0);            % 外导体
%       m.applyBoundaryCondition('dirichlet','Edge',5:8,'u',V0);           % 丝 (真边界)
%       m.generateMesh('Hmax', b/25, 'Hmin', a, 'Hgrad', 1.2, 'Hedge', {5:8, a/8});
%       res = m.solvepde();   % u=res.NodalSolution, grad u=[res.XGradients res.YGradients]
%   要点与陷阱 (逐条实测):
%   * decsg 不写集公式时默认是**两个圆盘的并** ('A+B'), 于是 r<a 的导体内部也进了求解域,
%     丝圆成了 internalEdge。这种写法的两个后果: (1) 网格里有 r<a 的节点 (实测 9~2015 个),
%     在其上套闭式基准 V0*ln(r/b)/ln(a/b) 与 E=V0/(r*ln(b/a)) 会算出 1e8 V/m 量级的假参考值
%     (r=0.03a 处的解析 E 是表面值的 34 倍), 逐点误差被它顶到 57.5 -> 报出来的 1414%;
%     (2) internalEdge 两侧各有一套单元, 结果对象的**节点梯度是两侧的平均**, 丝面上的
%     du/dr 被导体内的零场稀释约一半 (实测 -47.6%)。'(A-B)' 把内圆减掉后 r<a 无节点无单元,
%     丝上的条件是真边界条件, 不需要也不应该再给 'InternalBC'; 同一套网格参数下丝面电荷
%     从 0.524*C_闭式 恢复到 0.926*C_闭式, 再加 'Hedge' 到 0.998。
%   * 'Hedge' 是 generateMesh 的合法选项 (值 = {边号数组, 尺寸}); 'Shape'/'ElementShape'/
%     'Gradients'/'MaxNumCells' 在本机不是。加密只用 Hmax/Hmin/Hgrad/Hedge。
%   * 本机默认给**二次**三角形: 连接表 6xNe (前 3 行顶点, 后 3 行边中点), mesh.Nodes 的列
%     同时含顶点与边中点, res.NodalSolution 与 res.XGradients 按同一列序索引 —— 实测
%     11633 节点的网格上 numel(XGradients)=11633 (不是 6*Ne=34428), 且同一节点上
%     XGradients 与 evaluateGradient 逐位相同。所以节点量与节点坐标天然同序,
%     p1Energy2D 取前 3 行按顶点积分不会错位 (那只是基函数降阶, 不是索引错误)。
%   * Dirichlet 的值名是 u, g 属于 Neumann。pde.FEMesh 没有 NumNodes/NumCells 属性, 也没有
%     boundary 方法; 节点归属用 mesh.findNodes('region','Edge',k) 逐边取。
%   * MATLAB 里 `*` 与 `.*` 同优先级且左结合: `a.*0.5*b` 解析成 `(a.*0.5)*b` -> 两个同长
%     列向量的矩阵乘法, 报 MATLAB:innerdim。逐点乘积必须逐项加括号。
%
%   收敛判据 (本文件最重要的数值决定): 丝面 E 正比 1/r, 是近奇异边界 -> 加密时峰值场持续上涨,
%   所以"峰值场相对变化 < 1%"不可能是收敛判据。只对**积分泛函**做加密序列 + Richardson/GCI:
%     W = int |grad V|^2 dA (二维) 或 dV (三维)  能量泛函, P1 元上按单元精确积分, 不用高斯求积
%     Q = -eps0 * int_wire (dV/dr) a dth  内导体上的线/面积分电荷
%     A = 逐射线平均的 int |E| dr         雪崩指数里被积分的那个量 (只在已解析区间上定义)
%   取最细三层 I1(细) I2 I3(粗), 尺寸比 r = refineRatio:
%     d21 = I1 - I2,  d32 = I2 - I3,  p_obs = ln|d32/d21| / ln(r)
%     I_ex = I1 + d21/(r^p - 1),  GCI_fine = 100*|d21|/|I1| / (r^p - 1)
%   p 取 p_obs, 但 p_obs 落在 [0.5, 4] 之外 (或非单调, d21*d32 <= 0) 时不假装估出来了:
%   退回理论阶 (能量泛函对 P1 元是 O(h^2)) 并把 status 写进返回值。阈值 1%。
%   注意每层是**重新生网**而非嵌套加密, 故单调性无保证, 这正是把 status 一起返回的原因。
%   A 的求积用几何级数径向网格: A = int |E| dr = int (|E|*r) d(ln r)。对 1/r 型场被积量
%   |E|*r 是常数, 所以按 ln r 做梯形求积是**精确**的; 按 r 均匀取样的同一 64 点网格实测把 A
%   高估 22.6% (凸函数在大步长区间上被高估), 那部分是求积偏差而不是离散误差, 加密不消失。
%
%   精度门禁 (本文件的交付约定): 六条预注册判据, 阈值都在 docs/constants.json 里, 代码不留
%   字面量 (改注册表即改门禁):
%     field.fem.maxRelDevCharge        Q = -eps0*int_wire (dV/dr) dl 对 2*pi*eps0/ln(b/a)*V0
%                                      的相对残差上界 (丝面周向积分, 每单位长度)
%     field.fem.maxRelDevEmagResolved  逐点 |E| 在窗口 r in [r_eval_factor*a_m, b_m] 上的
%                                      max |E_num-E_ana|/|E_ana| 上界
%     field.fem.maxRelDevPotentialResolved  同一窗口上电位与权重电位两路的逐点相对偏差上界
%                                      (两者都是 |V_num-V_ana|/V0 口径, 权重解的 V0=1)
%     field.fem.maxRelDeltaIntegral    积分泛函相邻层相对变化上界 (与上面三条 Richardson/GCI
%                                      的相对不确定度上界一起报, 判据用前者)
%     两次独立求解的电容量互差 |C_w/C_lap-1| 用 field.fem.maxRelDevCharge 作阈值: 它不
%     含闭式基准, 与 charge 那条互补 (闭式或节点序只污染一次求解时它仍然报警)。
%   gate="error" (默认): 任一条不过 -> error("tepc:field:AccuracyGateFailed", ...), 不返回
%   场图。理由: 半对的场图和错的场图在下游看不出区别 (只把残差记进返回值 = 把判断推给一个
%   通常不会去读的字段), 所以这里让它炸而不是让它带着病历出门。
%   gate="report": 照常返回但 usable_for_production=false 且 claim 改成禁用文案;
%   tepc.field.fieldMap 见到 usable_for_production=false 直接 error(tepc:field:MapGateFailed),
%   所以 "report" 打不开任何消费路径, 只用于诊断与负对照测试。
%   窗口的物理依据: 丝面 E 正比 1/r, 逐点相对偏差在 r->a 时由**第一层单元**决定, 实测
%   r=1.0002a 上恒有百分之几到 8% 的偏差且加密不消失 (那里没有可分辨的场, 只有边界条件),
%   所以逐点判据只在 r >= r_eval_factor*a_m 上取。电荷判据取的是整周积分, 一阶量, 近丝
%   未分辨层的误差在积分里被远端补偿, 故可以钉在丝面上 (实测三级序列 <2e-4)。
%
%   两种 2-D 模式的关系: 平面二维环域的面积分 int dA 与无限长同轴柱的轴对称周向积分
%   int 2*pi*r dr 数值同一 (平面里的极角就是柱对称的方位角), 所以 planar 与 axisymmetric
%   的电位/场分布完全相同, 区别只在把积分量化成物理量: planar 只给"每单位轴向长度",
%   axisymmetric 另乘 zlength_m 给总量, 且电容量基准随之缩放。真正的子午面几何 (球腔、
%   端部效应) 走 pde.ElectromagneticModel 的 electrostatic-axisymmetric 路线, 其
%   electromagneticBC 与内边界接口在本机未实测 -> 本函数不实现该路线, 见 F.needs_verification。
%
%   spherical_check: 三维同心球壳 (multisphere + Void 挖掉内球) 对闭式解
%     V(r) = V0*(a*b/(b-a))*(1/r - 1/b),   C = 4*pi*eps0*a*b/(b-a)
%   做校验。该模式的返回值 claim 字段固定为"仅校验, 不作产品几何": 真实丝-球三维构型需要
%   importGeometry (single 精度且按 FeatureAngle 重划分), 25 um 级特征在 mm 尺度下会被改形,
%   不在承诺范围内。
%
%   返回 F (tepc.field.fieldMap 的容器):
%     nodes [Nx2 或 Nx3], potential [Nx1], ex/ey(/ez) [Nx1],
%     weighting_potential [Nx1] 与 wx/wy(/wz) —— 第二次独立求解 (内边界=1, 外边界=0),
%     mesh_dof (= 电位解的自由度 = 节点数, 标位场), mesh_dof_two_solves (电位解+权重解之和),
%     mesh_nodes, mesh_elements, convergence (结构体: 逐层网格与泛函值、
%     Richardson 外推、GCI、相邻层相对变化、是否 <1%), charge_check (三条独立读数对
%     解析电容量: 丝面电荷线积分 / 能量泛函 / 权重电位解的围道积分),
%     analytic_potential_max_rel_dev 与 analytic_field_max_rel_dev (窗口内逐点相对偏差,
%     门禁量), analytic_field_max_rel_err (全域绝对偏差/表面场, 只作诊断),
%     analytic_window (窗口边界与节点数), gate (门禁: 阈值、逐条读数、passed/failed/policy),
%     usable_for_production, mesh_recipe,
%     geometry_sha256, geometry_sha256_source, parameter_sha256, mode, dim,
%     isAnalytic, field_mode, claim, needs_verification, elapsed_s, solver_recipe。
%     F.fem / F.fem_w 保留 pde 结果句柄供插值用; 要把 F 存进 .mat 请先删这两个字段
%     (句柄不可序列化, 删掉后 fieldMap 自动走 scatteredInterpolant 路径)。
%
%   失败模式:
%     tepc:field:BadOptions          参数非法 (含 gate 取值不在 error/report 里)
%     tepc:field:PdeResultShape      网格/结果形状不认识, 含"求解域不是环域 (r<a 有节点)"
%                                    与"边界钉值断言不成立"两条主动检查
%     tepc:field:PdeSolveFailed      strict_pde 非 0 时的求解异常
%     tepc:field:AccuracyGateFailed  gate=error 且精度门禁未通过 (不返回场图)
%   非 strict 时求解异常会降级为解析采样容器 (isAnalytic=true, usable_for_production=false,
%   校核量按构造成立 -> 无判别力, 且发一条 warning); force_analytic 非 0 是主动选择,
%   不发 warning 也不降级标记 (它是 field.mode="analytic" 的正常产物), 只在
%   F.fallback_reason / F.status / F.gate.status 里记账。

% ---------------- 参数校验 ----------------
arguments
    opts struct = struct()
    args.a_m (1,1) double = NaN
    args.b_m (1,1) double = NaN
    args.V0_V (1,1) double = NaN
    args.hmax (1,1) double = NaN
    args.hmin (1,1) double = NaN
    args.hgrad (1,1) double = NaN
    args.refineLevels (1,1) double = NaN
    args.zlength_m (1,1) double = NaN
    args.eps0_F_per_m (1,1) double = NaN
    args.gain_start_factor (1,1) double = NaN
    args.gain_outer_factor (1,1) double = NaN
    args.refineRatio (1,1) double = NaN
    args.hedge_factor (1,1) double = NaN
    args.r_eval_factor (1,1) double = NaN
    args.gate (1,1) string = ""
    args.strict_pde (1,1) double = NaN
    args.force_analytic (1,1) double = NaN
    args.mode (1,1) string = ""
    args.geometry_sha256 (1,1) string = ""
end

p = collectOptions(opts, args);
[ok, why] = checkParams(p);
if ~ok
    error("tepc:field:BadOptions", "%s", why);
end

tTotal = tic;
if p.mode == "spherical_check"
    F = solveSphericalCheck(p);
    F.elapsed_s = toc(tTotal);
    return;
end

if p.force_analytic
    % field.mode = analytic 的生产路径: 不调 PDE, 直接给理想同轴闭式采样容器。
    F = analyticFallbackMap(p, "force_analytic: 按解析语义出容器, 未调用 PDE", true);
    F.elapsed_s = toc(tTotal);
    return;
end
try
    S = solveCoaxSequence(p);
catch ME
    if p.strict_pde
        error("tepc:field:PdeSolveFailed", "PDE 求解失败 (strict_pde 非 0): %s", ME.message);
    end
    warning("tepc:field:PdeUnavailableAnalyticFallback", "%s", ...
        ["静电场 PDE 求解失败, 已降级为理想同轴解析采样 (isAnalytic=true): " ME.message]);
    F = analyticFallbackMap(p, ME.message, false);
    F.elapsed_s = toc(tTotal);
    return;
end
F = assembleCoaxMap(p, S);
F.elapsed_s = toc(tTotal);
end

% ==================================================================== 参数
function p = collectOptions(opts, args)
%COLLECTOPTIONS 统一 opts 结构体与命名参数两条入口, 并补默认值。
%   优先级: 命名参数 > opts 字段 > 文档写明的默认值。哨兵 NaN / "" 表示"命名参数没给",
%   因为 arguments 块里的默认值无法区分"用户显式传了默认值"与"没传"。
p = struct();
if ~isstruct(opts) || numel(opts) ~= 1
    % 结构体数组会被逐字段静默取第一个元素, 那不是任何人想要的行为。
    error("tepc:field:BadOptions", "opts 必须是 1x1 结构体 (实得 %s, %dx%d)", ...
        class(opts), size(opts, 1), size(opts, 2));
end
p.a_m = pickNumber(args.a_m, opts, "a_m");
p.b_m = pickNumber(args.b_m, opts, "b_m");
p.V0_V = pickOrDefault(args.V0_V, opts, "V0_V", 700);
p.hmax = pickOrDefault(args.hmax, opts, "hmax", NaN);
p.hmin = pickOrDefault(args.hmin, opts, "hmin", NaN);
p.hgrad = pickOrDefault(args.hgrad, opts, "hgrad", 1.2);
p.refineLevels = pickOrDefault(args.refineLevels, opts, "refineLevels", 3);
p.zlength_m = pickOrDefault(args.zlength_m, opts, "zlength_m", NaN);
p.eps0_F_per_m = pickOrDefault(args.eps0_F_per_m, opts, "eps0_F_per_m", 8.8541878128e-12);
p.gain_start_factor = pickOrDefault(args.gain_start_factor, opts, "gain_start_factor", 1.5);
p.gain_outer_factor = pickOrDefault(args.gain_outer_factor, opts, "gain_outer_factor", 0.5);
p.refineRatio = pickOrDefault(args.refineRatio, opts, "refineRatio", 2);
p.hedge_factor = pickOrDefault(args.hedge_factor, opts, "hedge_factor", 8);
p.r_eval_factor = pickOrDefault(args.r_eval_factor, opts, "r_eval_factor", 1.5);
p.gate = lower(pickText(args.gate, opts, "gate", "error"));
p.strict_pde = pickOrDefault(args.strict_pde, opts, "strict_pde", 0) ~= 0;
p.force_analytic = pickOrDefault(args.force_analytic, opts, "force_analytic", 0) ~= 0;
p.mode = lower(pickText(args.mode, opts, "mode", "planar"));
p.geometry_sha256 = lower(pickText(args.geometry_sha256, opts, "geometry_sha256", ""));

% 网格默认值依赖半径, 只能在取完 a/b 之后再补。
ab = [p.a_m, p.b_m];
if isnan(p.hmax), p.hmax = max(ab)/25; end
if isnan(p.hmin), p.hmin = min(ab); end
if isnan(p.zlength_m), p.zlength_m = p.a_m + p.b_m; end

unknown = checkUnknownFields(opts);
if ~isempty(unknown)
    error("tepc:field:BadOptions", ...
        "opts 里有未知字段 (%s), 拼错的字段会被无声忽略, 故直接拒绝。可用字段: a_m b_m V0_V mode hmax hmin hgrad refineLevels geometry_sha256 zlength_m eps0_F_per_m gain_start_factor gain_outer_factor refineRatio hedge_factor r_eval_factor gate strict_pde force_analytic", strjoin(unknown, ", "));
end
end

function v = pickNumber(dflt, opts, name)
% 必填数值字段: 命名参数给了就用, 否则必须能在 opts 里找到标量数值。
v = pickOrDefault(dflt, opts, name, NaN);
if isnan(v)
    error("tepc:field:BadOptions", ...
        "缺少必填字段 %s (命名参数与 opts 结构体里都没有): 半径没有默认值, 不从配置里猜", name);
end
end

function v = pickOrDefault(dflt, opts, name, dfltValue)
if ~isnan(dflt)
    v = dflt;
    return;
end
if isfield(opts, name) && ~isempty(opts.(name))
    raw = opts.(name);
    if ~(isnumeric(raw) || islogical(raw)) || ~isscalar(raw)
        error("tepc:field:BadOptions", "字段 %s 必须是标量数值, 实得 %s", name, class(raw));
    end
    v = double(raw);
else
    v = dfltValue;
end
end

function v = pickText(dflt, opts, name, dfltValue)
if strlength(string(dflt)) > 0
    v = string(dflt);
    return;
end
if isfield(opts, name) && ~isempty(opts.(name))
    v = string(opts.(name));
    if numel(v) ~= 1
        error("tepc:field:BadOptions", "字段 %s 必须是标量文本", name);
    end
else
    v = string(dfltValue);
end
end

function bad = checkUnknownFields(opts)
allowed = ["a_m", "b_m", "V0_V", "mode", "hmax", "hmin", "hgrad", "refineLevels", ...
    "geometry_sha256", "zlength_m", "eps0_F_per_m", "gain_start_factor", ...
    "gain_outer_factor", "refineRatio", "strict_pde", "force_analytic", ...
    "hedge_factor", "r_eval_factor", "gate"];
bad = strings(0, 1);
names = string(fieldnames(opts));
for i = 1:numel(names)
    if ~any(names(i) == allowed)
        bad(end+1) = names(i); %#ok<AGROW,SAGROW>
    end
end
end

function [ok, why] = checkParams(p)
ok = true;
why = "";
if ~(p.a_m > 0)
    ok = false; why = "a_m 必须为正 (丝/阳极半径, 单位米)"; return;
end
if ~(p.b_m > p.a_m)
    ok = false; why = sprintf("需要 b_m (%.6e) > a_m (%.6e)", p.b_m, p.a_m); return;
end
if ~(p.V0_V > 0)
    ok = false; why = sprintf("V0_V 必须 > 0 (实得 %.6g): 零电位下 GCI 的分母为 0", p.V0_V); return;
end
if ~any(p.mode == ["planar", "axisymmetric", "spherical_check"])
    ok = false; why = sprintf("mode 只能是 planar / axisymmetric / spherical_check, 实得 %s", p.mode); return;
end
if ~(p.hmax > 0) || ~(p.hmin > 0) || ~(p.hmax > p.hmin)
    ok = false; why = sprintf("需要 0 < hmin (%.6e) < hmax (%.6e)", p.hmin, p.hmax); return;
end
% 丝圆周上的节点数下限: Hmin 大于 2*pi*a/3 时圆被不到 3 个单元覆盖, 电荷线积分无意义。
if p.hmin > 2*pi*p.a_m/3
    ok = false;
    why = sprintf("hmin (%.6e) 太粗: 丝圆周 2*pi*a = %.6e 铺不满 3 个单元", p.hmin, 2*pi*p.a_m);
    return;
end
if ~(p.hgrad > 1)
    ok = false; why = "hgrad 必须 > 1"; return;
end
if ~(p.refineRatio >= 1.3)
    ok = false;
    why = sprintf("refineRatio 必须 >= 1.3 (实得 %.3g), 否则 Richardson 差分被舍入噪声吃掉", p.refineRatio);
    return;
end
if ~(p.refineLevels >= 3) || abs(p.refineLevels - round(p.refineLevels)) > 0
    ok = false; why = sprintf("refineLevels 必须是 >= 3 的整数 (实得 %.6g)", p.refineLevels); return;
end
if ~(p.hedge_factor >= 1)
    ok = false;
    why = sprintf("hedge_factor 必须 >= 1 (实得 %.6g): 丝边界尺寸 = hmin/hedge_factor", p.hedge_factor);
    return;
end
if ~(p.r_eval_factor > 1)
    ok = false;
    why = sprintf("r_eval_factor 必须 > 1 (实得 %.6g): 逐点对比窗口取 r >= r_eval_factor*a_m", p.r_eval_factor);
    return;
end
if ~any(p.gate == ["error", "report"])
    ok = false;
    why = sprintf("gate 只能是 error / report, 实得 %s", p.gate);
    return;
end
if ~(p.gain_start_factor > 1) || ~(p.gain_outer_factor > 1e-3) || (p.gain_outer_factor > 1)
    ok = false;
    why = "gain_start_factor 需 > 1 且 1e-3 < gain_outer_factor <= 1 (雪崩积分的已解析区间)";
    return;
end
if p.mode ~= "spherical_check" && p.gain_start_factor*p.a_m >= p.a_m + p.gain_outer_factor*(p.b_m - p.a_m)
    ok = false;
    why = "雪崩积分区间为空: gain_start_factor*a_m 必须小于 a_m + gain_outer_factor*(b_m - a_m)";
    return;
end
if ~(p.zlength_m > 0)
    ok = false; why = "zlength_m 必须为正"; return;
end
if ~(p.eps0_F_per_m > 0)
    ok = false; why = "eps0_F_per_m 必须为正"; return;
end
if strlength(p.geometry_sha256) > 0 && ~isHex64(p.geometry_sha256)
    ok = false;
    why = sprintf("geometry_sha256 必须是 64 位十六进制, 实得长度 %d", strlength(p.geometry_sha256));
    return;
end
end

function tf = isHex64(s)
c = char(string(s));
tf = numel(c) == 64 && all((c >= '0' & c <= '9') | (c >= 'a' & c <= 'f') | (c >= 'A' & c <= 'F'));
end

% ==================================================================== 解析基准
function ref = analyticReference(p, scale)
%ANALYTICREFERENCE 同轴闭式基准。scale 是内边界电位 (电位解=V0, 权重解=1)。
%   V(r) = scale*log(r/b)/log(a/b);  E_r = scale/(r*log(b/a));  C' = 2*pi*eps/log(b/a)。
%   适用域: 无限长同轴 (二维/轴对称), 不含端面与任何非圆对称的场整形结构。
s = double(scale);
L = log(p.b_m/p.a_m);
ref = struct();
ref.formula_potential = "V(r) = V0*log(r/b)/log(a/b)";
ref.formula_field = "E_r(r) = V0/(r*log(b/a))";
ref.formula_weighting = "phi_w(r) = log(b/r)/log(b/a)";
ref.capacitance_per_length = 2*pi*p.eps0_F_per_m/L;
ref.energy_per_V2 = 2*pi/L;                    % W = energy_per_V2*scale^2 (每单位长度)
ref.scale = s;
ref.log_ratio = L;
ref.domain_note = "无限长同轴近似: 只在离端面足够远、a<=r<=b 内成立; 端部效应与非圆对称场整形不覆盖";
end

% ==================================================================== 2-D 加密序列
function S = solveCoaxSequence(p)
% 每层: 重建成网 -> 解电位 (丝=V0) -> 解权重电位 (丝=1) -> 记录积分泛函。
nLv = round(p.refineLevels);
ref = analyticReference(p, p.V0_V);
rec = struct('level', 0, 'hmax_m', NaN, 'hmin_m', NaN, 'hgrad', NaN, 'dof', 0, ...
    'dof_two_solves', 0, ...
    'elements', 0, 'nodes', 0, 'energy_V2', NaN, 'charge_C_per_m', NaN, ...
    'avalanche_integral_V', NaN, 'peak_field_V_per_m', NaN, ...
    'peak_field_over_analytic_wire', NaN, 'max_rel_err_potential', NaN, ...
    'max_rel_err_field', NaN, 'weighting_max_rel_err_potential', NaN, 'elapsed_s', NaN, ...
    'max_rel_dev_potential', NaN, 'max_rel_dev_field', NaN, ...
    'weighting_max_rel_dev_potential', NaN, 'n_window_nodes', NaN, ...
    'flux_contour_nodes', NaN, 'flux_radius_m', NaN, 'max_rel_delta', NaN);
levels = repmat(rec, 1, nLv);
fine = [];                         % 最细层的结果包 (电位 + 权重电位)
peakHistory = nan(1, nLv);
for k = 1:nLv
    factor = p.refineRatio^(k - 1);
    hp = p.hmax/factor;
    hn = p.hmin/factor;
    Lp = solveCoaxLevel(p, hp, hn, p.V0_V, true);
    Lw = solveCoaxLevel(p, hp, hn, 1, false);
    lv = levels(k);
    lv.level = k; lv.hmax_m = hp; lv.hmin_m = hn; lv.hgrad = p.hgrad;
    lv.dof = Lp.dof;                              % 标位 2-D 静电: 1 自由度/节点
    lv.dof_two_solves = Lp.dof + Lw.dof;          % 电位解 + 权重电位解之和
    lv.elements = Lp.elements; lv.nodes = Lp.nodes;
    lv.energy_V2 = Lp.energy; lv.charge_C_per_m = Lp.charge;
    lv.avalanche_integral_V = Lp.avalanche;
    lv.peak_field_V_per_m = Lp.peakE;
    lv.peak_field_over_analytic_wire = Lp.peakE/(p.V0_V/(p.a_m*ref.log_ratio));
    lv.max_rel_err_potential = Lp.errV; lv.max_rel_err_field = Lp.errE;
    lv.weighting_max_rel_err_potential = Lw.errV;
    lv.max_rel_dev_potential = Lp.devV; lv.max_rel_dev_field = Lp.devE;
    lv.weighting_max_rel_dev_potential = Lw.devV;
    lv.n_window_nodes = Lp.nWindow;
    lv.flux_contour_nodes = Lp.nContour; lv.flux_radius_m = Lp.fluxRadius;
    lv.elapsed_s = Lp.elapsed + Lw.elapsed;
    levels(k) = lv;
    peakHistory(k) = Lp.peakE;
    if k == nLv
        fine = packFineLevel(p, Lp, Lw);
    end
end
S = struct();
S.levels = levels;
S.refineRatio = p.refineRatio;
S.fine = fine;
S.peak_history = peakHistory;                       % 层序: 1 最粗 -> nLv 最细
S.ref = ref;
end

function L = solveCoaxLevel(p, hmax, hmin, uWire, wantAvalanche)
% 一次求解 (一张重生的网 + 一个内边界电位)。度量都塞进 L, 结果句柄留在 L.res 供插值。
t0 = tic;
m = createpde();
geometryFromEdges(m, coaxGeometry2D(p.a_m, p.b_m));
m.specifyCoefficients('m', 0, 'd', 0, 'c', 1, 'a', 0, 'f', 0);
m.applyBoundaryCondition('dirichlet', 'Edge', 1:4, 'u', 0);
m.applyBoundaryCondition('dirichlet', 'Edge', 5:8, 'u', uWire);
hs = hmin/p.hedge_factor;
m.generateMesh('Hmax', hmax, 'Hmin', hmin, 'Hgrad', p.hgrad, 'Hedge', {5:8, hs});
mesh = m.Mesh;
res = m.solvepde();

nodes = double(mesh.Nodes).';
u = double(res.NodalSolution(:));
[gx, gy] = resultGradients2D(res);                 % grad(u), 场是它的负值
r = sqrt(sum(nodes.^2, 2));

L = struct();
L.res = res;
L.dof = numel(u);
L.nodes = size(nodes, 1);
L.elements = size(mesh.Elements, 2);
L.energy = p1Energy2D(nodes, mesh.Elements, u);
L.nodes_xy = nodes;
L.u = u;
L.gx = gx;
L.gy = gy;
L.hedge_size_m = hs;
% 求解域必须是环域。r < a 里只要有节点就说明内圆没从域里减掉, 那时丝面上的节点梯度是
% 内外两侧单元的平均值 (导体内侧 u 恒等于边界值 -> 梯度为零), 电荷线积分被稀释约一半
% (实测 -47.6%)。宁可乐在这里, 不拿半对的场图出去。
nIn = nnz(r < p.a_m*(1 - 1e-9));
if nIn > 0
    error("tepc:field:PdeResultShape", ...
        "%d 个网格节点落在导体内部 (r < a_m=%.6e): 求解域不是环域, 丝面梯度会被内侧零场稀释", ...
        nIn, p.a_m);
end
% 边界钉值断言: 边界条件被静默忽略时场会退化成常数 (或零), 所有积分量看起来仍然"有限",
% 只有这里能拦住。
innerIds = circleNodes(mesh, 5:8, nodes, p.a_m);
outerIds = circleNodes(mesh, 1:4, nodes, p.b_m);
L.innerIds = innerIds;
devIn = max(abs(u(innerIds) - uWire));
if devIn > 1e-6*max(1, abs(uWire))
    error("tepc:field:PdeResultShape", ...
        "内边界节点电位未钉在 %.6g (最大偏差 %.3e): InternalBC 未生效或被静默忽略", ...
        uWire, devIn);
end
devOut = max(abs(u(outerIds)));
if devOut > 1e-9*max(1, abs(uWire))
    error("tepc:field:PdeResultShape", "外边界节点电位非零 (最大 %.3e): 边界条件未生效", devOut);
end
% int (du/dr) dl 沿丝的闭合围道 (周向梯形, 权重取相邻节点的平均弧长)。
[qWire, L.fluxRadius, L.nContour, L.fluxRadSpread] = radialContour2D(nodes, innerIds, gx, gy);
L.charge = -p.eps0_F_per_m*qWire;
if wantAvalanche
    L.avalanche = avalancheIntegral(res, p);
else
    L.avalanche = NaN;
end
L.peakE = max(sqrt(gx.^2 + gy.^2));
% 与闭式比较。两件事必须显式: (1) 参考式只在 a <= r <= b 成立, r<a 的点上
% E_ana = V0/(r*ln(b/a)) 会大到 1e8 V/m 量级 (导体内部不是无源区, 那里 u 是常数),
% 把它算进"数值解对解析解的误差"是自伤; (2) 丝面第一层单元未分辨 (实测 r=1.0002a 上
% 恒有 8% 的偏差且与网格无关), 所以逐点判据取 r >= r_eval_factor*a_m 的窗口。
% 窗内用**逐点相对偏差** max|E_num-E_ana|/E_ana (分母逐点, 不会被某一点的绝对值主导);
% 电位同样在窗内取, 用 |uWire| 归一 (外边界处 V=0, 逐点相对误差在那里是 0/0)。
wWin = r >= p.r_eval_factor*p.a_m & r <= p.b_m*(1 + 1e-9);
wIn = r >= p.a_m*(1 - 1e-9) & r <= p.b_m*(1 + 1e-9);
if nnz(wWin) < 10
    error("tepc:field:PdeResultShape", ...
        "逐点对比窗口 r in [%.3e, %.3e] 内只有 %d 个节点, 误差判据没有意义", ...
        p.r_eval_factor*p.a_m, p.b_m, nnz(wWin));
end
uAn = uWire*log(max(r, realmin)/p.b_m)/log(p.a_m/p.b_m);
erAn = uWire./(max(r, realmin)*log(p.b_m/p.a_m));
emag = sqrt(gx.^2 + gy.^2);
L.nWindow = nnz(wWin);
L.errV = max(abs(u(wWin) - uAn(wWin)))/max(abs(uWire), realmin);
L.errE = max(abs(emag(wWin) - erAn(wWin))./erAn(wWin));
L.devV = L.errV;
L.devE = L.errE;
L.devEFull = max(abs(emag(wIn) - erAn(wIn))./erAn(wIn));
L.errVFull = max(abs(u(wIn) - uAn(wIn)))/max(abs(uWire), realmin);
L.errEFull = max(abs(emag(wIn) - erAn(wIn)))/(abs(uWire)/(p.a_m*log(p.b_m/p.a_m)));
L.rMinNode = min(r(wIn));
L.rMaxNode = max(r(wIn));
L.elapsed = toc(t0);
end

function gd = coaxGeometry2D(a, b)
% 环域 GD: 两个同心圆 (A 半径 b 在外, B 半径 a 在内), 集公式 (A-B) 只留 a <= r <= b。
% decsg 不写集公式时的默认公式是并集 'A+B', 会把内圆盘一起带进求解域: 丝圆变成
% internalEdge, 两侧都有单元 (见文件头的两条实测后果)。
gd = decsg([1 1; 0 0; 0 0; b a], '(A-B)', {'A', 'B'});
end

function F = packFineLevel(p, Lp, Lw)
% 最细层的场图数据 + 绝对校核要的中间量。
% 权重电容量用 Lw **自己那次**求解的网格与节点编号算: 两次求解各自独立 generateMesh,
% 参数相同则网格相同, 但混用两层的节点编号是拿正确性去赌确定性, 不划算。
F = struct();
F.nodes = Lp.nodes_xy;
F.potential = Lp.u;
F.ex = -Lp.gx; F.ey = -Lp.gy;
F.weighting_potential = Lw.u;
F.wx = -Lw.gx; F.wy = -Lw.gy;
F.dof_potential = Lp.dof;
F.dof_weighting = Lw.dof;
F.elements = Lp.elements;
F.node_count = Lp.nodes;
F.res = Lp.res;
F.res_w = Lw.res;
F.energy = Lp.energy;
F.charge = Lp.charge;
F.capacitance_w = -p.eps0_F_per_m*radialContour2D(Lw.nodes_xy, Lw.innerIds, Lw.gx, Lw.gy);
F.errV = Lp.errV;
F.errE = Lp.errE;
F.errW = Lw.errV;
F.devV = Lp.devV;
F.devE = Lp.devE;
F.devW = Lw.devV;
F.devEFull = Lp.devEFull;
F.errVFull = Lp.errVFull;
F.errEFull = Lp.errEFull;
F.fluxRadius = Lp.fluxRadius;
F.nContour = Lp.nContour;
F.nWindow = Lp.nWindow;
F.rMinNode = Lp.rMinNode;
F.rMaxNode = Lp.rMaxNode;
F.hedge_size_m = Lp.hedge_size_m;
end

function F = assembleCoaxMap(p, S)
% 把 2-D 序列装成对外返回的场图容器。
fem = S.fine;
ref = S.ref;
F = struct();
F.producer = "tepc.field.solveElectrostatic";
F.mode = char(p.mode);
F.dim = 2;
F.isAnalytic = false;
F.field_mode = "fem_map";
% 多段文本必须用 strcat: 中括号里相邻的两个双引号标量是"两个数组元素"而不是拼接,
% ["A" "B"] 得到 1x2 string 数组, 下游 char()/fprintf()/error() 全会拿到错形状。
F.claim = strcat("模型几何静电场 (非装置实测): 与几何清单同源的 FEM 场图; ", ...
    "仅对积分量按 GCI 承诺 <1%, 峰值场因丝面 E 正比 1/r 近奇异而不作判据");

F.nodes = fem.nodes;
F.potential = fem.potential;
F.ex = fem.ex;
F.ey = fem.ey;
F.weighting_potential = fem.weighting_potential;
F.wx = fem.wx;
F.wy = fem.wy;
F.mesh_dof = fem.dof_potential;              % 标位 2-D 静电: 1 自由度/节点
F.mesh_dof_two_solves = fem.dof_potential + fem.dof_weighting;
F.dof_potential = fem.dof_potential;
F.dof_weighting = fem.dof_weighting;
F.dof_basis = "mesh_dof 只计电位解; 权重电位是第二次独立求解, 计入 mesh_dof_two_solves";
F.mesh_nodes = fem.node_count;
F.mesh_elements = fem.elements;
F.a_m = p.a_m; F.b_m = p.b_m; F.V0_V = p.V0_V; F.eps0_F_per_m = p.eps0_F_per_m;
F.zlength_m = p.zlength_m;

% ---- 绝对校核: 三条独立读数对同一个闭式电容量 ----
lenFactor = 1;
if p.mode == "axisymmetric"
    lenFactor = p.zlength_m;                       % 每单位长度 -> 总长
end
C_ref = ref.capacitance_per_length*lenFactor;
C_flux = fem.charge/p.V0_V*lenFactor;              % 丝面电荷线积分反推
C_energy = p.eps0_F_per_m*S.levels(end).energy_V2/p.V0_V^2*lenFactor;
% 权重电位解里围道积分在单位电位下直接给出电容量, 是另一次独立求解的读数。
C_wflux = fem.capacitance_w*lenFactor;
tolC = tepc.config.constants('field.fem.maxRelDevCharge');
tolE = tepc.config.constants('field.fem.maxRelDevEmagResolved');
tolV = tepc.config.constants('field.fem.maxRelDevPotentialResolved');
residQ = C_flux/C_ref - 1;
F.charge_check = struct();
F.charge_check.charge_wire_C = fem.charge*lenFactor;
F.charge_check.charge_expected_CV = C_ref*p.V0_V;
F.charge_check.rel_residual_flux = residQ;
F.charge_check.rel_residual_energy = C_energy/C_ref - 1;
F.charge_check.rel_residual_weighting_flux = C_wflux/C_ref - 1;
F.charge_check.capacitance_numeric_F = C_flux;
F.charge_check.capacitance_analytic_F = C_ref;
F.charge_check.capacitance_from_energy_F = C_energy;
F.charge_check.capacitance_from_weighting_flux_F = C_wflux;
F.charge_check.per_unit_length_basis = p.mode ~= "axisymmetric";
F.charge_check.basis = "planar: 每单位轴向长度; axisymmetric: 乘 zlength_m 的总量; 基准都是闭式电容量";
F.charge_check.charge_route_note = strcat( ...
    "电荷线积分取在丝面 (r=a) 的闭合围道上: 它是周向积分, ", ...
    "近丝未分辨层的偏差在积分里被远端补偿; 实测三级序列 (refineRatio=2, 12.5um/12.7mm) ", ...
    "由粗到细的相对残差 = -1.73e-3, -5.19e-4, -1.49e-4");
F.charge_check.contour = struct('radius_m', fem.fluxRadius, 'n_nodes', fem.nContour);
% 三条读数各自的分组 (字段集与解析容器路径逐项一致: 上层按字段名读时不会撞空)。
% gated=true 的那条才是门禁判据; 能量路只记录 (二次元上它按顶点子元积分, 见
% F.mesh_recipe.energy_subelement_note)。权重路是第二次独立求解的同一条围道积分:
% 它比较的对象是电位解自己的读数 (不是闭式), 因此闭式基准写错、节点序错位这类
% 只污染其中一次求解的故障无法同时骗过两条路 —— 判据取 |C_w/C_lap-1| <= tolC。
agreeTwoSolves = abs(C_wflux/C_flux - 1);
F.charge_check.two_solve_agreement = agreeTwoSolves;
F.charge_check.charge = struct('route', "wire_flux", 'value_F', C_flux, ...
    'reference_F', C_ref, 'rel_residual', residQ, ...
    'threshold_rel', tolC, 'ok', abs(residQ) <= tolC, 'gated', true);
F.charge_check.energy = struct('route', "field_energy", 'value_F', C_energy, ...
    'reference_F', C_ref, 'rel_residual', C_energy/C_ref - 1, ...
    'threshold_rel', NaN, 'ok', false, 'gated', false, ...
    'note', "能量泛函按顶点子元 (P1) 积分, 残差里混着基函数降阶偏差, 只记录不判门禁");
F.charge_check.weighting = struct('route', "weighting_flux", 'value_F', C_wflux, ...
    'reference_F', C_ref, 'rel_residual', C_wflux/C_ref - 1, ...
    'threshold_rel', tolC, 'ok', agreeTwoSolves <= tolC, 'gated', true, ...
    'compared_to', "capacitance_numeric_F: 同一条围道、两次独立求解", ...
    'two_solve_agreement', agreeTwoSolves, ...
    'note', "门禁判的是两次求解互差 (不共享闭式基准), 对闭式的残差见 charge_check.charge");

% ---- 收敛 / GCI ----
F.convergence = buildConvergence(S.levels, 'charge_C_per_m', S.refineRatio);
F.convergence.levels = S.levels;
F.convergence.peak_field_history_V_per_m = S.peak_history;   % 层序与 convergence.levels 一致
F.convergence.peak_field_used_as_criterion = false;
F.convergence.peak_field_note = strcat( ...
    "丝面 E 正比 1/r, 近奇异 -> 加密时峰值上升是预期行为, ", ...
    "把它当收敛判据会永远不收敛; 这里只记录不使用");

% ---- 与闭式解的偏差: *_max_rel_dev_* 是门禁量 (窗口内逐点相对偏差);
% *_max_rel_err_* 保留下来记全域值 (含未分辨层与 r<a), 只作诊断, 不判门禁。
F.analytic_max_rel_err = fem.errV;
F.analytic_potential_max_rel_err = fem.errVFull;
F.analytic_field_max_rel_err = fem.errEFull;
F.analytic_weighting_max_rel_err = fem.errW;
F.analytic_potential_max_rel_dev = fem.devV;
F.analytic_field_max_rel_dev = fem.devE;
F.analytic_weighting_max_rel_dev = fem.devW;
F.analytic_window = struct('r_min_m', p.r_eval_factor*p.a_m, 'r_max_m', p.b_m, ...
    'n_nodes', fem.nWindow, 'potential_threshold_rel', tolV, ...
    'field_threshold_rel', tolE, 'charge_threshold_rel', tolC, ...
    'node_r_min_m', fem.rMinNode, 'node_r_max_m', fem.rMaxNode);
F.analytic = ref;
F.analytic.per_level_max_rel_err_potential = [S.levels.max_rel_err_potential];
F.analytic.per_level_max_rel_err_field = [S.levels.max_rel_err_field];
F.analytic.per_level_max_rel_dev_potential = [S.levels.max_rel_dev_potential];
F.analytic.per_level_max_rel_dev_field = [S.levels.max_rel_dev_field];

% ---- 精度门禁 ----
% 加密序列的"相邻层相对变化"在这里补算: 三个积分泛函各自 coarse->fine 一阶差分,
% 每层取三者最大值。第 1 层没有更粗的参照, 留 NaN。
dE = adjacentRelDelta([S.levels.energy_V2]);
dQ = adjacentRelDelta([S.levels.charge_C_per_m]);
dA = adjacentRelDelta([S.levels.avalanche_integral_V]);
lvRec = F.convergence.levels;
for k = 1:numel(lvRec)
    lvRec(k).max_rel_delta = max([dE(k), dQ(k), dA(k)]);
end
F.convergence.levels = lvRec;
F.convergence.adjacent_rel_delta_percent = 100*[dE(2:end), dQ(2:end), dA(2:end)];
F.convergence.adjacent_basis = ...
    "相邻两层的相对变化 |I_k-I_(k-1)|/|I_k| (粗->细), 与 GCI 的区别见 F.gate.convergence_note";
F.gate = electrostaticGate(p, residQ, fem.devE, fem.devV, fem.devW, agreeTwoSolves, lvRec);
if ~F.gate.passed && strcmp(p.gate, "error")
    error("tepc:field:AccuracyGateFailed", "%s", strcat( ...
        "静电场精度门禁未通过, 场图不交付 (诊断数值请用 gate=report 显式索取, ", ...
        "那种容器会被 tepc.field.fieldMap 拒绝): ", string(F.gate.failed)));
end
F.usable_for_production = F.gate.passed;
if ~F.gate.passed
    F.claim = strcat("静电场 FEM 场图: 精度门禁未通过 (见 F.gate.failed), ", ...
        "不得用于任何增益、输运、权重场或电容量的定量结论; 仅供定位离散误差来源");
end

% ---- 哈希绑定 ----
F.parameter_sha256 = parameterHash(p);
if strlength(p.geometry_sha256) > 0
    F.geometry_sha256 = char(p.geometry_sha256);
    F.geometry_sha256_source = "manifest";
else
    F.geometry_sha256 = F.parameter_sha256;
    F.geometry_sha256_source = "derived_parameters";
end
F.solver_recipe = strcat("createpde + decsg([1 1; 0 0; 0 0; b a], '(A-B)', {'A','B'}) ", ...
    "+ specifyCoefficients(m=0,d=0,c=1,a=0,f=0) + dirichlet Edge 1:4 u=0 / Edge 5:8 u=V0 ", ...
    "+ generateMesh(Hmax,Hmin,Hgrad,Hedge={5:8,hmin/hedge_factor}) + solvepde");
F.mesh_recipe = struct('hmax_m', p.hmax, 'hmin_m', p.hmin, 'hgrad', p.hgrad, ...
    'hedge_factor', p.hedge_factor, 'hedge_size_m', p.hmin/p.hedge_factor, ...
    'refine_levels', round(p.refineLevels), 'refine_ratio', p.refineRatio, ...
    'element_order', 2, 'energy_subelement_order', 1, ...
    'energy_subelement_note', strcat( ...
    "能量泛函按二次元的顶点子元 (P1) 精确积分: ", ...
    "与闭式的残差里混着 O(h) 的基函数降阶偏差, 所以只作记录不进门禁; ", ...
    "电荷线积分与逐点偏差都是二次元的原生读数"));
F.needs_verification = strings(0, 1);
F.needs_verification(end+1) = "decsg(A-B) 环域上的 findNodes('region','Edge',5:8) 与半径分类是否总是给出同一组丝节点: 本几何实测一致, 换了边编号方案需复核"; %#ok<AGROW>
F.needs_verification(end+1) = "每层重新生网 (非嵌套加密), Richardson 的单调性前提不成立, 故 convergence.*.status 必须与 gate.max_rel_delta 一起看"; %#ok<AGROW>
F.needs_verification(end+1) = "子午面轴对称 (球腔/端部效应) 需走 createpde 的 electromagnetic/electrostatic-axisymmetric 模型, 其 electromagneticBC 与内边界接口未实测"; %#ok<AGROW>
if ~strcmp(p.mode, "axisymmetric")
    F.needs_verification(end+1) = "zlength_m 仅在 axisymmetric 下参与积分量缩放"; %#ok<AGROW>
end
F.fem = fem.res;
F.fem_w = fem.res_w;
F.units = struct('potential', 'V', 'field', 'V/m', 'geometry', 'm', ...
    'charge', 'C (planar 为每单位长度)', 'capacitance', 'F (planar 为每单位长度)');
F.matlab_version = version;
end

% ==================================================================== 精度门禁
function g = notEvaluatedGate(p, reason)
% 解析/降级容器的 gate: 字段集与 FEM 路径一致 (上层按字段名读不会撞空), 但判据是
% "未评估"而不是"通过" —— 按构造成立的残差不提供信息, 把它记成 passed=true 就是自我认证。
g = electrostaticGate(p, NaN, NaN, NaN, NaN, NaN, repmat(struct('max_rel_delta', NaN), 1, 0));
g.status = "not_evaluated";
g.note = char(strcat("解析采样容器: 无网格、无离散误差可评估; 校核量按构造成立, 无判别力。原因: ", ...
    string(reason)));
g.passed = false;
g.failed = "未评估 (解析容器)";
end

function d = adjacentRelDelta(vals)
% 相邻加密层之间的一阶相对差分 |I_k - I_(k-1)|/|I_k| (层序: 1 最粗 -> nLv 最细)。
% 第 1 层没有更粗的参照 -> NaN。分母为 0 时也给 NaN (不假装有 0% 的变化)。
v = vals(:).';
d = nan(1, numel(v));
for k = 2:numel(v)
    if abs(v(k)) > 0 && isfinite(v(k)) && isfinite(v(k-1))
        d(k) = abs(v(k) - v(k-1))/abs(v(k));
    end
end
end

function g = electrostaticGate(p, residCharge, devField, devPotential, devWeighting, ...
    agreeTwoSolves, levels)
%ELECTROSTATICGATE 六条预注册判据的合取; 阈值只在 docs/constants.json 里。
%   charge     |int_wire eps*dV/dr dl / (C'_ana*V0) - 1| <= maxRelDevCharge
%   field      max_{r in [r_eval*a, b]} |E_num-E_ana|/E_ana <= maxRelDevEmagResolved
%   potential  同一窗口上的 |V_num-V_ana|/V0 <= maxRelDevPotentialResolved
%   weighting  权重电位解在同一窗口上的 |phi_w,num-phi_w,ana|/1 <= maxRelDevPotentialResolved
%              (与 potential 同类量: 都是窗内逐点电位偏差、都用 V0 归一, 权重解的
%               边界值是 1/0, 所以它的归一化分母就是 1 —— 不另设阈值就是不复用口径)
%   two_solve  |C(权重解)/C(电位解) - 1| <= maxRelDevCharge: 两次独立求解对同一个
%              电容量必须一致; 该判据不含闭式基准, 与 charge 路互补
%   delta      最细三层里三个积分泛函的相邻层相对变化 <= maxRelDeltaIntegral
% 为什么 delta 用相邻层一阶差分而不是 GCI<1%: GCI 要 d21*d32>0 (单调) 才有定义,
% 而每层重新生网的序列本就不保证单调 (实测雪崩泛函三级 5e-5 量级抖动 -> GCI 无定义)。
% 一阶差分回答的是"再把网格减半, 这个量变多少", 与"离极限还有多远"是两个命题,
% 两者都返回: convergence.energy/charge/avalanche_integral 给 GCI 与 status, gate 给判据。
tC = tepc.config.constants('field.fem.maxRelDevCharge');
tE = tepc.config.constants('field.fem.maxRelDevEmagResolved');
tV = tepc.config.constants('field.fem.maxRelDevPotentialResolved');
tD = tepc.config.constants('field.fem.maxRelDeltaIntegral');
g = struct();
g.policy = char(p.gate);
g.n_criteria = 6;
g.charge_threshold_rel = tC;
g.field_threshold_rel = tE;
g.potential_threshold_rel = tV;
g.weighting_threshold_rel = tV;
g.two_solve_threshold_rel = tC;
g.delta_threshold_rel = tD;
g.charge_residual = residCharge;
g.field_max_rel_dev = devField;
g.potential_max_rel_dev = devPotential;
g.weighting_max_rel_dev = devWeighting;
g.two_solve_agreement = agreeTwoSolves;
dAll = [levels.max_rel_delta];
dUsable = dAll(2:numel(dAll));          % 第 1 层无参照
g.max_rel_delta = NaN;
if ~isempty(dUsable)
    g.max_rel_delta = max(dUsable);
end
g.charge_ok = isfinite(residCharge) && abs(residCharge) <= tC;
g.field_ok = isfinite(devField) && devField <= tE;
g.potential_ok = isfinite(devPotential) && devPotential <= tV;
g.weighting_ok = isfinite(devWeighting) && devWeighting <= tV;
g.two_solve_ok = isfinite(agreeTwoSolves) && agreeTwoSolves <= tC;
g.delta_ok = ~isempty(dUsable) && all(isfinite(dUsable)) && g.max_rel_delta <= tD;
g.passed = g.charge_ok && g.field_ok && g.potential_ok && g.weighting_ok && ...
    g.two_solve_ok && g.delta_ok;
bad = strings(0, 1);
if ~g.charge_ok
    bad(end+1) = sprintf("charge %.3e > %.3e", abs(residCharge), tC); %#ok<AGROW>
end
if ~g.field_ok
    bad(end+1) = sprintf("field %.3e > %.3e", devField, tE); %#ok<AGROW>
end
if ~g.potential_ok
    bad(end+1) = sprintf("potential %.3e > %.3e", devPotential, tV); %#ok<AGROW>
end
if ~g.weighting_ok
    bad(end+1) = sprintf("weighting %.3e > %.3e", devWeighting, tV); %#ok<AGROW>
end
if ~g.two_solve_ok
    bad(end+1) = sprintf("two_solve_agreement %.3e > %.3e", agreeTwoSolves, tC); %#ok<AGROW>
end
if ~g.delta_ok
    if isempty(dUsable) || ~all(isfinite(dUsable))
        bad(end+1) = "delta 非有限 (加密序列的积分量有 NaN)"; %#ok<AGROW>
    else
        bad(end+1) = sprintf("delta %.3e > %.3e", g.max_rel_delta, tD); %#ok<AGROW>
    end
end
g.failed = strjoin(bad, "; ");
if g.passed
    g.failed = "";
end
g.convergence_note = strcat( ...
    "gate 判相邻层相对变化 (无单调性前提); convergence.*.gci_percent ", ...
    "判 Richardson/GCI (需单调), 两者语义不同, 都要看");
g.bite = strcat( ...
    "gate=error 时任一条不过即 error(tepc:field:AccuracyGateFailed), 不返回场图; ", ...
    "gate=report 时 usable_for_production=false 且 claim 改为禁用文案, ", ...
    "tepc.field.fieldMap 拒绝该容器 (tepc:field:MapGateFailed)");
end

% ==================================================================== 泛函与几何工具
function [gx, gy] = resultGradients2D(res)
% 节点梯度。本机实测: 二次三角形网格 (6xNe, mesh.Nodes 同时含顶点与边中点) 上
% numel(XGradients) = 节点数 = size(mesh.Nodes,2), 与 NodalSolution / mesh.Nodes 同序;
% 同一节点上 XGradients 与 evaluateGradient 逐位相同 -> 这里不需要任何重排。
% 部分版本/记录里同一量叫 GradientSolution (dim x nnodes), 两条路径都试,
% 都拿不到时抛错而不是返回 0。
if isprop(res, 'XGradients') && ~isempty(res.XGradients)
    gx = double(res.XGradients(:));
    gy = double(res.YGradients(:));
    return;
end
if isprop(res, 'GradientSolution') && ~isempty(res.GradientSolution)
    g = double(res.GradientSolution);
    gx = g(1, :).';
    gy = g(2, :).';
    return;
end
error("tepc:field:PdeResultShape", ...
    "结果对象里找不到节点梯度 (试过 XGradients 与 GradientSolution), 场图无法组装");
end

function ids = circleNodes(mesh, edgeIds, nodes, targetR)
% 找落在半径 targetR 的圆上的网格节点。首选几何区域查询 findNodes('region','Edge',...);
% 拿不到时退回半径容差分类 (本几何的两个圆圆心都在原点, 半径就是精确判据)。
ids = [];
try
    found = mesh.findNodes('region', 'Edge', edgeIds);
    ids = double(found(:));
catch
    ids = [];
end
if isempty(ids)
    % 部分版本只吃标量边号: 逐边取再并起来。
    for k = 1:numel(edgeIds)
        try
            one = mesh.findNodes('region', 'Edge', edgeIds(k));
            ids = unique([ids; double(one(:))]); %#ok<AGROW>
        catch
            ids = [];
        end
    end
end
tol = min(1e-6*max(1, targetR), 0.05*targetR);
r = sqrt(sum(nodes.^2, 2));
near = find(abs(r - targetR) <= tol);
if isempty(ids)
    ids = near;
else
    ids = ids(ismember(ids, near));
end
if numel(ids) < 3
    error("tepc:field:PdeResultShape", ...
        "半径 %.3e 上只找到 %d 个网格节点, 无法做电荷线积分 (加密序列或网格参数需要复核)", ...
        targetR, numel(ids));
end
end

function [integral, rMean, nNodes, radSpread] = radialContour2D(nodes, ids, gx, gy)
% int (du/dr) dl 沿该圆的闭合围道, du/dr = grad(u) 点乘 +r_hat (即"离开圆心"方向)。
% 周向用节点极角的梯形权重 (非均匀角距, 末段跨 2*pi 封口), 弧长用节点自己的半径:
% dl_i = (r_i + r_{i+1})/2 * dtheta_i。MATLAB 里 * 与 .* 同优先级且左结合, 所以
% a.*0.5*b 会被解析成 (a.*0.5)*b -> 同长列向量的矩阵乘法 (MATLAB:innerdim);
% 下面每个逐点乘积都单独加括号。
th = atan2(nodes(ids, 2), nodes(ids, 1));
[th, ord] = sort(th(:));
nd = ids(ord(:));
rr = sqrt(sum(nodes(nd, :).^2, 2));
ct = nodes(nd, 1)./rr;
st = nodes(nd, 2)./rr;
dn = gx(nd).*ct + gy(nd).*st;
dth = [diff(th); 2*pi + th(1) - th(end)];
dl = 0.5*(rr + [rr(2:numel(rr)); rr(1)]).*dth;
avg = 0.5*(dn + [dn(2:numel(dn)); dn(1)]);
integral = sum(dl .* avg);
rMean = mean(rr);
nNodes = numel(nd);
radSpread = max(rr) - min(rr);
end

function W = p1Energy2D(nodes, elems, u)
% int |grad u|^2 dA, P1 三角形上精确: 每元梯度常量, 权重取面积绝对值。
% 本机 R2025a 实测: generateMesh 默认给**二次**三角形, 连接表是 6xNe (前 3 行是顶点,
% 后 3 行是边中点), 且 'Shape'/'ElementShape' 都不是 generateMesh 的合法选项。
% 因此这里取前 3 行按 P1 子元积分: 加密序列各层用同一约定, 收敛阶与 Richardson 比
% 仍自洽; 代价是能量泛函按顶点插值算, 比二次基低一阶精度 (在结果里以
% element_order_used=1 记录, 不假装是二次元的精确积分)。
if size(elems, 1) >= 6
    elems = elems(1:3, :);
elseif size(elems, 1) ~= 3
    error("tepc:field:PdeResultShape", "二维网格连接表既不是 3xNe 也不是 6xNe, 实得 %dx%d", ...
        size(elems, 1), size(elems, 2));
end
i1 = elems(1, :); i2 = elems(2, :); i3 = elems(3, :);
x1 = nodes(i1, 1); y1 = nodes(i1, 2);
j11 = nodes(i2, 1) - x1; j12 = nodes(i2, 2) - y1;
j21 = nodes(i3, 1) - x1; j22 = nodes(i3, 2) - y1;
jac = j11.*j22 - j12.*j21;                          % 带号 2 倍面积
if any(jac == 0)
    error("tepc:field:BadMesh", "网格里有退化单元 (面积为 0), 能量泛函不可算");
end
du2 = u(i2) - u(i1);
du3 = u(i3) - u(i1);
gradx = (j22.*du2 - j12.*du3)./jac;
grady = (-j21.*du2 + j11.*du3)./jac;
W = sum(0.5*abs(jac).*(gradx.^2 + grady.^2));
end

function A = avalancheIntegral(res, p)
% 雪崩指数里被积分的量: 逐射线平均的 int |E| dr, 积分区间 [gain_start_factor*a,
% a + gain_outer_factor*(b-a)] —— 刻意避开丝面附近未解析的奇性层, 否则加密必然发散,
% 这个泛函也就失去作为收敛判据的资格。射线上的求值用 evaluateGradient。
nTheta = 24;
nR = 64;
r0 = p.gain_start_factor*p.a_m;
r1 = p.a_m + p.gain_outer_factor*(p.b_m - p.a_m);
if ~(r1 > r0)
    error("tepc:field:BadOptions", "雪崩积分区间为空: r0 (%.3e) 需小于 r1 (%.3e)", r0, r1);
end
% 径向取几何级数网格并按 ln r 积分: int |E| dr = int (|E|*r) d(ln r)。对 1/r 型场
% 被积量 |E|*r 是常数, 梯形求积在任意点数下都精确; 等距 r 网格的同一 64 点实测把
% 这个泛函高估 22.6% (凸函数在大步长区间上被高估), 那是求积偏差而不是离散误差,
% 加密不会消失 —— 它会伪装成"收敛到错误的值"。
lv = linspace(log(r0), log(r1), nR).';
rv = exp(lv);
tv = (0.5 + (0:nTheta - 1)).'*2*pi/nTheta;
[RQ, TQ] = ndgrid(rv, tv);
xqTmp = RQ.*cos(TQ);
yqTmp = RQ.*sin(TQ);
xq = xqTmp(:);
yq = yqTmp(:);
[gxq, gyq] = evaluateGradient(res, xq, yq);
emag = reshape(sqrt(double(gxq(:)).^2 + double(gyq(:)).^2), nR, nTheta);
perRay = trapz(lv, emag.*rv, 1);
A = mean(perRay);
if ~isfinite(A)
    error("tepc:field:PdeResultShape", "雪崩积分非有限值: 射线求值点或网格有问题");
end
end

function C = richardsonGci(vals, ratio, pTheory, threshPct)
% Richardson 外推 + GCI。vals 顺序: 第 1 个最细, 最后最粗 (取最细三层)。
C = struct('value_fine', NaN, 'value_coarse', NaN, 'extrapolated', NaN, ...
    'observed_order', NaN, 'order_used', NaN, 'gci_percent', NaN, ...
    'below_threshold', false, 'status', "not_enough_levels", 'threshold_percent', threshPct);
v = vals(:);
if numel(v) < 3
    return;
end
I1 = v(1); I2 = v(2); I3 = v(3);
C.value_fine = I1;
C.value_coarse = I3;
d21 = I1 - I2;
d32 = I2 - I3;
if abs(I1) <= 0 || ~isfinite(I1)
    C.status = "degenerate_reference";
    return;
end
if d21*d32 <= 0 || abs(d32) <= 0
    C.status = "non_monotone_or_no_difference";
    % 差分不保号 -> 不在渐近区 (或每层重新生网造成的抖动), 不假装估出阶。
    C.gci_percent = 100*abs(d21)/abs(I1);
    C.order_used = pTheory;
    C.extrapolated = I1;
    C.below_threshold = false;
    return;
end
pObs = log(abs(d32/d21))/log(ratio);
C.observed_order = pObs;
if pObs >= 0.5 && pObs <= 4
    pUse = pObs;
    C.status = "ok";
else
    pUse = pTheory;
    C.status = "order_out_of_range_theory_used";
end
C.order_used = pUse;
den = ratio^pUse - 1;
C.extrapolated = I1 + d21/den;
C.gci_percent = 100*abs(d21)/abs(I1)/den;
C.below_threshold = C.gci_percent < threshPct;
end

function conv = buildConvergence(levels, qField, ratio)
% 三个积分泛函各算一份 GCI。理论阶: 能量泛函对 P1 元是 O(h^2); 电荷与射线积分泛函
% 同样以 O(h^2) 作理论阶 (被积函数是一阶梯度, 围道/射线上做梯形积分)。
% qField 是层记录里电荷量的字段名 (二维按每单位长度、三维按总量, 单位不同故不共用名字)。
nLv = numel(levels);
W = [levels.energy_V2];
W = W(end:-1:1);                                  % 最细在前
Q = [levels.(qField)];
Q = Q(end:-1:1);
A = [levels.avalanche_integral_V];
A = A(end:-1:1);
conv = struct();
conv.energy = richardsonGci(W, ratio, 2, 1);
conv.charge = richardsonGci(Q, ratio, 2, 1);
conv.avalanche_integral = richardsonGci(A, ratio, 2, 1);
conv.quantity_W = "int|grad V|^2 dA 每单位长度 [V^2]";
conv.quantity_Q = "内导体电荷 int eps*E*dS (二维为 C/m, 三维为 C, 见 charge_check.basis)";
conv.quantity_A = "逐射线平均 int|E| dr (已解析区间) [V]";
conv.refinement_ratio = ratio;
conv.theoretical_order = 2;
conv.threshold_percent = 1;
conv.n_levels = nLv;
% considered = 该泛函在这一路几何里真有有限值 (三维校验没有雪崩射线积分, 全 NaN 就不参与
% converged 的合取, 否则 spherical_check 永远报不收敛)。
conv.energy.considered = any(isfinite(W));
conv.charge.considered = any(isfinite(Q));
conv.avalanche_integral.considered = any(isfinite(A));
flagged = [conv.energy.considered, conv.charge.considered, conv.avalanche_integral.considered];
conv.n_considered = nnz(flagged);
below = [conv.energy.below_threshold, conv.charge.below_threshold, ...
    conv.avalanche_integral.below_threshold];
conv.converged = conv.n_considered > 0 && all(below(flagged));
conv.converged_integral_quantities = conv.converged;
end

function conv = emptyConvergence(p)
% 解析容器用的 convergence: 字段集与 FEM 路径逐项对齐 (上层按字段名读时不会撞空),
% 但所有判据都是"未评估"而不是"通过"。
conv = struct();
conv.energy = richardsonGci([NaN NaN NaN], p.refineRatio, 2, 1);
conv.charge = richardsonGci([NaN NaN NaN], p.refineRatio, 2, 1);
conv.avalanche_integral = richardsonGci([NaN NaN NaN], p.refineRatio, 2, 1);
conv.energy.considered = false;
conv.charge.considered = false;
conv.avalanche_integral.considered = false;
conv.quantity_W = "int|grad V|^2 dA 每单位长度 [V^2]";
conv.quantity_Q = "内导体电荷 int eps*E*dS (二维为 C/m, 三维为 C, 见 charge_check.basis)";
conv.quantity_A = "逐射线平均 int|E| dr (已解析区间) [V]";
conv.refinement_ratio = p.refineRatio;
conv.theoretical_order = 2;
conv.threshold_percent = 1;
conv.n_levels = 0;
conv.n_considered = 0;
conv.converged = false;
conv.converged_integral_quantities = false;
conv.peak_field_used_as_criterion = false;
conv.peak_field_note = "解析容器无网格序列";
conv.note = "未做加密收敛评估";
conv.levels = struct('level', {}, 'hmax_m', {}, 'hmin_m', {}, 'hgrad', {}, 'dof', {}, 'dof_two_solves', {}, ...
    'elements', {}, 'nodes', {}, 'energy_V2', {}, 'charge_C_per_m', {}, ...
    'avalanche_integral_V', {}, 'peak_field_V_per_m', {}, 'peak_field_over_analytic_wire', {}, ...
    'max_rel_err_potential', {}, 'max_rel_err_field', {}, ...
    'weighting_max_rel_err_potential', {}, 'elapsed_s', {}, ...
    'max_rel_dev_potential', {}, 'max_rel_dev_field', {}, ...
    'weighting_max_rel_dev_potential', {}, 'n_window_nodes', {}, ...
    'flux_contour_nodes', {}, 'flux_radius_m', {}, 'max_rel_delta', {});
end

function h = parameterHash(p)
% 求解输入参数的自哈希 (纯 MATLAB SHA-256, 与几何清单同一实现)。
% 它标识"这一张场图是照哪组尺寸/网格算出来的", 不是装置几何的真相源:
% 绑到清单上的字段是 geometry_sha256。
% 配方标识 v2: 环域 (decsg 减法) + 丝边界 Hedge + 窗口内逐点相对偏差判据。
% 任何一项改动都必须同时改变这张场图的身份哈希, 否则旧场图能冒充新配方的产物。
txt = sprintf('tepc-field-solve-v2|a_m=%.17g|b_m=%.17g|V0_V=%.17g|mode=%s|hmax=%.17g|hmin=%.17g|hgrad=%.17g|levels=%d|ratio=%.17g|hedge=%.17g|reval=%.17g|zlength=%.17g|eps0=%.17g|gstart=%.17g|gouter=%.17g', ...
    p.a_m, p.b_m, p.V0_V, char(p.mode), p.hmax, p.hmin, p.hgrad, ...
    round(p.refineLevels), p.refineRatio, p.hedge_factor, p.r_eval_factor, ...
    p.zlength_m, p.eps0_F_per_m, p.gain_start_factor, p.gain_outer_factor);
h = char(lower(string(tepc.io.hashText(txt))));
end

% ==================================================================== 解析降级容器
function F = analyticFallbackMap(p, reason, isForce)
% PDE 不可用、或显式 force_analytic 时的理想同轴采样容器。isAnalytic=true 让上层能区分
% field.mode 语义: 校核量 (对闭式的误差、电荷残差) 在这里按构造恒等于 0, **没有判别力**,
% 所以 converged/analytic_*_rel_err 一律给 NaN 而不是 0, 避免把"降级"读成"通过"。
% usable_for_production: 主动选择 (force_analytic) 才算产物; 求解失败后的降级不算,
% 它只能用来打通调用链, tepc.field.fieldMap 会拒 (tepc:field:MapGateFailed)。
F = struct();
F.producer = "tepc.field.solveElectrostatic";
F.mode = char(p.mode);
F.dim = 2;
F.isAnalytic = true;
F.field_mode = "analytic";
% status 与 fallback_reason 分开记: 前者说"这个容器是怎么来的" (主动选择 / PDE 不可用),
% 后者说为什么。文件头承诺 F.status 参与记账, 二维路必须真的写上。
if isForce
    F.status = "force_analytic_only";
else
    F.status = "pde_path_unavailable_analytic_only";
end
F.claim = "理想同轴解析采样 (未做 FEM): 不含几何细节, 不得当作模型几何电场";
nR = 200;
nTheta = 60;
rv = linspace(p.a_m, p.b_m, nR);
tv = (0:nTheta - 1)*2*pi/nTheta;
[RQ, TQ] = ndgrid(rv, tv);
x = RQ.*cos(TQ);
y = RQ.*sin(TQ);
r = max(RQ, realmin);
L = log(p.b_m/p.a_m);
V = p.V0_V*log(r/p.b_m)/(-L);                            % 注意 log(a/b) = -L
Er = p.V0_V./(r*L);
F.nodes = [x(:), y(:)];
F.potential = V(:);
F.ex = (Er(:).*cos(TQ(:)));
F.ey = (Er(:).*sin(TQ(:)));
F.weighting_potential = log(p.b_m./r(:))/L;
F.wx = Er(:).*cos(TQ(:))/p.V0_V;
F.wy = Er(:).*sin(TQ(:))/p.V0_V;
F.mesh_dof = numel(F.potential);
F.mesh_dof_two_solves = F.mesh_dof;   % 解析容器只有一次闭式采样
F.mesh_nodes = F.mesh_dof;
F.mesh_elements = NaN;
F.a_m = p.a_m; F.b_m = p.b_m; F.V0_V = p.V0_V; F.eps0_F_per_m = p.eps0_F_per_m;
F.zlength_m = p.zlength_m;
ref = analyticReference(p, p.V0_V);
lenFactor = 1;
if p.mode == "axisymmetric"
    lenFactor = p.zlength_m;
end
F.charge_check = struct('charge_wire_C', NaN, 'charge_expected_CV', ...
    ref.capacitance_per_length*lenFactor*p.V0_V, 'rel_residual_flux', NaN, ...
    'rel_residual_energy', NaN, 'rel_residual_weighting_flux', NaN, ...
    'capacitance_numeric_F', NaN, 'capacitance_analytic_F', ...
    ref.capacitance_per_length*lenFactor, 'capacitance_from_energy_F', NaN, ...
    'capacitance_from_weighting_flux_F', NaN, 'per_unit_length_basis', p.mode ~= "axisymmetric", ...
    'basis', "解析容器: 电荷校核按构造成立, 无判别力, 故全部给 NaN");
F.charge_check.charge = struct('route', "wire_flux", 'value_F', NaN, ...
    'reference_F', F.charge_check.capacitance_analytic_F, 'rel_residual', NaN, ...
    'threshold_rel', tepc.config.constants('field.fem.maxRelDevCharge'), 'ok', false);
F.charge_check.energy = struct('route', "field_energy", 'value_F', NaN, ...
    'reference_F', F.charge_check.capacitance_analytic_F, 'rel_residual', NaN, ...
    'threshold_rel', NaN, 'ok', false, 'gated', false, ...
    'note', "能量泛函对二次元是降阶读数, 只记录不判门禁");
F.charge_check.weighting = struct('route', "weighting_flux", 'value_F', NaN, ...
    'reference_F', F.charge_check.capacitance_analytic_F, 'rel_residual', NaN, ...
    'threshold_rel', NaN, 'ok', false, 'gated', false, ...
    'compared_to', "capacitance_numeric_F: 同一条围道、两次独立求解", ...
    'two_solve_agreement', NaN, ...
    'note', "解析容器只有一条闭式读数, 无第二次独立求解可比, 故记为未评估");
F.charge_check.two_solve_agreement = NaN;
F.convergence = emptyConvergence(p);
F.convergence.note = "解析采样, 未做加密收敛评估";
F.analytic_max_rel_err = NaN;
F.analytic_potential_max_rel_err = NaN;
F.analytic_field_max_rel_err = NaN;
F.analytic_weighting_max_rel_err = NaN;
F.analytic_potential_max_rel_dev = NaN;
F.analytic_field_max_rel_dev = NaN;
F.analytic_weighting_max_rel_dev = NaN;
F.analytic_window = struct('r_min_m', p.r_eval_factor*p.a_m, 'r_max_m', p.b_m, ...
    'n_nodes', NaN, 'potential_threshold_rel', tepc.config.constants('field.fem.maxRelDevPotentialResolved'), ...
    'field_threshold_rel', tepc.config.constants('field.fem.maxRelDevEmagResolved'), ...
    'charge_threshold_rel', tepc.config.constants('field.fem.maxRelDevCharge'), ...
    'node_r_min_m', NaN, 'node_r_max_m', NaN);
F.gate = notEvaluatedGate(p, reason);
F.usable_for_production = isForce;
F.mesh_recipe = struct('hmax_m', p.hmax, 'hmin_m', p.hmin, 'hgrad', p.hgrad, ...
    'hedge_factor', p.hedge_factor, 'hedge_size_m', p.hmin/p.hedge_factor, ...
    'refine_levels', round(p.refineLevels), 'refine_ratio', p.refineRatio, ...
    'element_order', NaN, 'energy_subelement_order', NaN, ...
    'energy_subelement_note', "解析容器无网格");
F.analytic = ref;
F.parameter_sha256 = parameterHash(p);
if strlength(p.geometry_sha256) > 0
    F.geometry_sha256 = char(p.geometry_sha256);
    F.geometry_sha256_source = "manifest";
else
    F.geometry_sha256 = F.parameter_sha256;
    F.geometry_sha256_source = "derived_parameters";
end
F.solver_recipe = "无 (PDE 路径失败, 解析闭式采样)";
F.fallback_reason = char(reason);
F.needs_verification = "解析降级容器: 只能用于打通调用链, 不能用于任何精度或收敛结论";
F.units = struct('potential', 'V', 'field', 'V/m', 'geometry', 'm');
F.matlab_version = version;
end

% ==================================================================== 3-D 同心球校验
function F = solveSphericalCheck(p)
% 三维同心球壳对 1/r 闭式解的校验入口。内球用 multisphere 的 Void 挖掉, 其表面成为
% 求解域的内边界; Void 的内边界能否吃 Dirichlet 在本机未实测 -> 全流程包在 try 里,
% 失败时返回标了状态的解析校验记录, 不抛错也不假装通过。
ref = struct();
ref.formula_potential = "V(r) = V0*(a*b/(b-a))*(1/r - 1/b)";
ref.formula_field = "E_r(r) = V0*a*b/((b-a)*r^2)";
ref.formula_weighting = "phi_w(r) = (1/r - 1/b)/(1/a - 1/b)";
ref.capacitance_F = 4*pi*p.eps0_F_per_m*p.a_m*p.b_m/(p.b_m - p.a_m);
ref.energy_per_V2 = 4*pi*p.a_m*p.b_m/(p.b_m - p.a_m);
ref.domain_note = "同心球壳闭式; 真实装置的丝状阳极不是等位面球, 故此模式仅校验";

ok = false;
msg = "";
S = [];
if p.force_analytic
    msg = "force_analytic: 按解析语义出容器, 未调用 PDE";
else
    try
        S = solveSphericalLevels(p);
        ok = ~isempty(S);
    catch ME2
        msg = ME2.message;
    end
end
F = struct();
F.producer = "tepc.field.solveElectrostatic";
F.mode = "spherical_check";
F.dim = 3;
F.claim = "仅校验, 不作产品几何";
F.field_mode = "fem_map";
F.a_m = p.a_m; F.b_m = p.b_m; F.V0_V = p.V0_V; F.eps0_F_per_m = p.eps0_F_per_m;
F.zlength_m = NaN;
F.analytic = ref;
F.parameter_sha256 = parameterHash(p);
if strlength(p.geometry_sha256) > 0
    F.geometry_sha256 = char(p.geometry_sha256);
    F.geometry_sha256_source = "manifest";
else
    F.geometry_sha256 = F.parameter_sha256;
    F.geometry_sha256_source = "derived_parameters";
end
F.solver_recipe = "createpde + multisphere([a b], Void=[true false]) + general-form laplace + dirichlet Face";
F.matlab_version = version;
F.units = struct('potential', 'V', 'field', 'V/m', 'geometry', 'm');
if ~ok
    F.isAnalytic = true;
    if p.force_analytic
        F.status = "force_analytic_only";
    else
        F.status = "pde_path_unavailable_analytic_only";
    end
    F.pde_error = char(msg);
    F = fillAnalyticSphereSample(F, p);
    F.needs_verification = "3-D 校验只做到解析采样比对: PDE 路径未通过, 需实测确认 multisphere/Void/面分类接口";
    F.charge_check = struct('rel_residual_flux', NaN, 'rel_residual_energy', NaN, ...
        'capacitance_analytic_F', ref.capacitance_F, ...
        'basis', "解析采样: 校核按构造成立, 无判别力");
    F.convergence = emptyConvergence(p);
    if p.force_analytic
        F.convergence.note = "force_analytic: 未做加密收敛评估";
    else
        F.convergence.note = "PDE 路径未通过, 无加密序列";
    end
    F.analytic_max_rel_err = NaN;
    F.analytic_potential_max_rel_dev = NaN;
    F.analytic_field_max_rel_dev = NaN;
    F.analytic_weighting_max_rel_dev = NaN;
    F.gate = notEvaluatedGate(p, "3-D 校验的 PDE 路径未通过, 无网格序列");
    F.usable_for_production = false;
    F.mesh_dof = numel(F.potential);
    F.mesh_dof_two_solves = F.mesh_dof;   % 解析容器只有一次闭式采样
    return;
end
F.isAnalytic = false;
F.status = "solved";
F.pde_error = "";
F.nodes = S.nodes;
F.potential = S.potential;
F.ex = S.ex; F.ey = S.ey; F.ez = S.ez;
F.weighting_potential = S.wpotential;
F.wx = S.wx; F.wy = S.wy; F.wz = S.wz;
F.mesh_dof = S.dof;                     % 标位 3-D 静电: 1 自由度/节点
F.mesh_dof_two_solves = S.dof_two_solves;
F.mesh_nodes = S.node_count;
F.mesh_elements = S.elements;
F.analytic_max_rel_err = S.errV;
F.analytic_potential_max_rel_err = S.errV;
F.analytic_field_max_rel_err = S.errE;
F.analytic_weighting_max_rel_err = S.errW;
C_num_energy = p.eps0_F_per_m*S.energy/p.V0_V^2;
C_num_flux = S.charge/p.V0_V;
F.charge_check = struct();
F.charge_check.charge_wire_C = S.charge;
F.charge_check.charge_expected_CV = ref.capacitance_F*p.V0_V;
F.charge_check.rel_residual_flux = C_num_flux/ref.capacitance_F - 1;
F.charge_check.rel_residual_energy = C_num_energy/ref.capacitance_F - 1;
F.charge_check.capacitance_numeric_F = C_num_flux;
F.charge_check.capacitance_analytic_F = ref.capacitance_F;
F.charge_check.capacitance_from_energy_F = C_num_energy;
F.charge_check.basis = "球壳闭式 C = 4*pi*eps0*a*b/(b-a); 电荷由内球面节点径向导数乘 4*pi*a^2 估 (粗); 能量泛函按 tet 精确积分";
F.charge_check.charge = struct('route', "inner_surface_flux", 'value_F', C_num_flux, ...
    'reference_F', ref.capacitance_F, 'rel_residual', F.charge_check.rel_residual_flux, ...
    'threshold_rel', tepc.config.constants('field.fem.maxRelDevCharge'), ...
    'ok', abs(F.charge_check.rel_residual_flux) <= tepc.config.constants('field.fem.maxRelDevCharge'), ...
    'gated', false, ...
    'note', "面元均法估的球面电荷只作量级校核: 阈值按二维那条路读出来的数比较, 但不进门禁");
F.charge_check.energy = struct('route', "field_energy", 'value_F', C_num_energy, ...
    'reference_F', ref.capacitance_F, 'rel_residual', F.charge_check.rel_residual_energy, ...
    'threshold_rel', NaN, 'ok', false, 'gated', false);
F.convergence = buildConvergence(S.levels, 'charge_C', p.refineRatio);
F.convergence.levels = S.levels;
F.convergence.peak_field_used_as_criterion = false;
F.needs_verification = ["multisphere 的 Void 语义与内边界 Dirichlet 是否生效未实测 (已加内边界钉值断言, 失败会退到解析记录)"; ...
    "3-D 电荷用面元均法估计, 只作量级校核不作精度承诺"; ...
    "hmax/hmin 的默认值沿用二维配方 (b/25 与 a), 对球壳偏粗: 需要更严的三维数字请显式传 hmax/hmin"];
% 3-D 校验路不做定量承诺 (内球面电荷是量级校核, 默认 hmax/hmin 对球壳偏粗), 所以
% 门禁按"未评估"记账而不是"通过": 按构造宽松地判过等于没有门禁。
F.gate = notEvaluatedGate(p, "spherical_check 仅作三维闭式校验, 判据未在此路预注册");
F.gate.policy = "not_applied";
F.usable_for_production = false;
F.analytic_potential_max_rel_dev = F.analytic_potential_max_rel_err;
F.analytic_field_max_rel_dev = F.analytic_field_max_rel_err;
F.analytic_weighting_max_rel_dev = F.analytic_weighting_max_rel_err;
F.fem = S.res;
F.fem_w = S.res_w;
end

function S = solveSphericalLevels(p)
% 加密序列 (每层两次求解), 只保留最细层的场图数据供校验。
nLv = round(p.refineLevels);
rec = struct('level', 0, 'hmax_m', NaN, 'hmin_m', NaN, 'dof', 0, 'dof_two_solves', 0, ...
    'nodes', 0, 'energy_V2', NaN, 'charge_C', NaN, 'avalanche_integral_V', NaN, ...
    'peak_field_V_per_m', NaN, 'max_rel_err_potential', NaN, 'max_rel_err_field', NaN, ...
    'weighting_max_rel_err_potential', NaN, 'elapsed_s', NaN);
levels = repmat(rec, 1, nLv);
S = [];
for k = 1:nLv
    factor = p.refineRatio^(k - 1);
    [Lp, meta] = solveSphericalLevel(p, p.hmax/factor, p.hmin/factor, p.V0_V);
    [Lw, ~] = solveSphericalLevel(p, p.hmax/factor, p.hmin/factor, 1);
    lv = levels(k);
    lv.level = k; lv.hmax_m = p.hmax/factor; lv.hmin_m = p.hmin/factor;
    lv.dof = Lp.dof; lv.dof_two_solves = Lp.dof + Lw.dof;
    lv.elements = meta.elements; lv.nodes = meta.node_count;
    lv.energy_V2 = Lp.energy; lv.charge_C = Lp.charge; lv.avalanche_integral_V = NaN;
    lv.peak_field_V_per_m = Lp.peakE;
    lv.max_rel_err_potential = Lp.errV; lv.max_rel_err_field = Lp.errE;
    lv.weighting_max_rel_err_potential = Lw.errV;
    lv.elapsed_s = Lp.elapsed + Lw.elapsed;
    levels(k) = lv;
    if k == nLv
        S = Lp;
        S.potential = Lp.u;
        S.wpotential = Lw.u;
        S.wx = -Lw.gx; S.wy = -Lw.gy; S.wz = -Lw.gz;
        S.errW = Lw.errV;
        S.res_w = Lw.res;
        S.dof = Lp.dof; S.dof_two_solves = lv.dof_two_solves;
        S.elements = meta.elements;
        S.node_count = meta.node_count;
    end
end
if isempty(S)
    error("tepc:field:BadOptions", "refineLevels 必须是正整数 (实得 %.6g)", p.refineLevels);
end
S.levels = levels;
end

function [L, meta] = solveSphericalLevel(p, hmax, hmin, uWire)
% 一层 3-D 求解: 同心球壳域 (内球挖 Void), 内球面 = uWire, 外球面 = 0。
t0 = tic;
gm = multisphere([p.a_m p.b_m], 'Void', [true false]);
m = createpde();
m.Geometry = gm;
m.specifyCoefficients('m', 0, 'd', 0, 'c', 1, 'a', 0, 'f', 0);
m.generateMesh('Hmax', hmax, 'Hmin', hmin, 'Hgrad', p.hgrad);
mesh = m.Mesh;
nodes = double(mesh.Nodes).';
if size(nodes, 2) ~= 3
    error("tepc:field:PdeResultShape", "三维几何的网格节点应为 Nx3, 实得 Nx%d", size(nodes, 2));
end
r = sqrt(sum(nodes.^2, 2));
% 面分类: 同心球的每个几何面半径恒定, 用节点半径把面分成内/外两组。
numFaces = m.Geometry.NumFaces;
inner = zeros(0, 1);
outer = zeros(0, 1);
tol = 1e-6*max(p.a_m, p.b_m);
for f = 1:numFaces
    ndRaw = mesh.findNodes('region', 'Face', f);
    nd = double(ndRaw(:));
    if isempty(nd)
        continue;
    end
    rr = r(nd);
    dr = max(abs(rr - p.a_m));
    if dr <= tol
        inner(end+1) = f; %#ok<AGROW>
    elseif max(abs(rr - p.b_m)) <= tol
        outer(end+1) = f; %#ok<AGROW>
    else
        error("tepc:field:PdeResultShape", ...
            "面 %d 上的节点半径不落在 a=%.3e 或 b=%.3e 上 (最大偏差 %.3e): 同心球假设破了", ...
            f, p.a_m, p.b_m, min(dr, max(abs(rr - p.b_m))));
    end
end
if isempty(inner) || isempty(outer)
    error("tepc:field:PdeResultShape", "内球面或外球面为空 (内 %d 个面, 外 %d 个面)", ...
        numel(inner), numel(outer));
end
m.applyBoundaryCondition('dirichlet', 'Face', outer, 'u', 0);
m.applyBoundaryCondition('dirichlet', 'Face', inner, 'u', uWire);
res = m.solvepde();
[gx, gy, gz] = resultGradients3D(res);
u = double(res.NodalSolution(:));
% 内边界钉值断言: Void 面吃不到 Dirichlet 时这里就会红, 不让后面拿假场去比对。
pin = u(r <= p.a_m + tol);
if numel(pin) < 3 || max(abs(pin - uWire)) > 1e-6*max(1, abs(uWire))
    error("tepc:field:PdeResultShape", ...
        "内球面电位未钉在 %.6g (偏差 %.3e): multisphere 的 Void 内边界条件未生效", ...
        uWire, max(abs(pin - uWire)));
end
energy = p1Energy3D(nodes, mesh.Elements, u);
% 电荷 (粗估): 内球面节点径向导数的均值乘 4*pi*a^2, 域外法向是 -r_hat。
mIn = r <= p.a_m + tol;
rIn = max(r(mIn), realmin);
dudr = (gx(mIn).*nodes(mIn, 1) + gy(mIn).*nodes(mIn, 2) + gz(mIn).*nodes(mIn, 3))./rIn;
charge = -p.eps0_F_per_m*4*pi*p.a_m^2*mean(dudr);
uAn = uWire*(p.a_m*p.b_m/(p.b_m - p.a_m))*(1./max(r, realmin) - 1/p.b_m);
L = struct();
L.res = res;
L.nodes = nodes;
L.u = u;
L.ex = -gx; L.ey = -gy; L.ez = -gz;
L.gx = gx; L.gy = gy; L.gz = gz;
L.dof = numel(u);
L.energy = energy;
L.charge = charge;
L.peakE = max(sqrt(gx.^2 + gy.^2 + gz.^2));
L.errV = maxRelErr(u, uAn, abs(uWire));
eAn = uWire*p.a_m*p.b_m/((p.b_m - p.a_m)*max(r, p.a_m).^2);
L.errE = maxRelErr(sqrt(gx.^2 + gy.^2 + gz.^2), eAn, max(eAn));
L.elapsed = toc(t0);
meta = struct('elements', size(mesh.Elements, 2), 'node_count', numel(u), ...
    'n_inner_faces', numel(inner), 'n_outer_faces', numel(outer));
end

function [gx, gy, gz] = resultGradients3D(res)
if isprop(res, 'XGradients') && ~isempty(res.XGradients)
    gx = double(res.XGradients(:));
    gy = double(res.YGradients(:));
    gz = double(res.ZGradients(:));
    return;
end
if isprop(res, 'GradientSolution') && ~isempty(res.GradientSolution)
    g = double(res.GradientSolution);
    gx = g(1, :).'; gy = g(2, :).'; gz = g(3, :).';
    return;
end
error("tepc:field:PdeResultShape", "三维结果对象里找不到节点梯度 (试过 XGradients 与 GradientSolution)");
end

function W = p1Energy3D(nodes, elems, u)
% int |grad u|^2 dV, P1 四面体上精确 (每元一次 3x3 线性求解, 循环实现: 校验用几何,
% 单元数远小于二维主路线, 不做向量化优化)。
if size(elems, 1) ~= 4
    error("tepc:field:PdeResultShape", "三维线性网格的连接表应为 4xNe, 实得 %dx%d", ...
        size(elems, 1), size(elems, 2));
end
ne = size(elems, 2);
W = 0;
for e = 1:ne
    idx = elems(:, e);
    pt = nodes(idx, :);
    v2 = pt(2, :) - pt(1, :);
    v3 = pt(3, :) - pt(1, :);
    v4 = pt(4, :) - pt(1, :);
    J = [v2; v3; v4];
    d = det(J);
    if d == 0
        error("tepc:field:BadMesh", "三维网格里有退化四面体 (单元 %d)", e);
    end
    du = [u(idx(2)) - u(idx(1)); u(idx(3)) - u(idx(1)); u(idx(4)) - u(idx(1))];
    g = J\du;
    W = W + abs(d)/6*(g.'*g);
end
end

function F = fillAnalyticSphereSample(F, p)
% 解析 1/r 闭式在球壳上的采样 (只用于打通调用链和展示闭式本身)。
% 极角取半整数余纬: 含 theta=0 或 pi 会让整圈经线塌到同一点, 产生重复节点,
% 上层若改用 scatteredInterpolant 就会因重复点报错。
nR = 60;
nTheta = 48;
nPhi = 48;
rv = linspace(p.a_m, p.b_m, nR);
tv = (0.5:(nTheta - 0.5))/nTheta*pi;
pv = (0:nPhi - 1)*2*pi/nPhi;
[RQ, TQ, PQ] = ndgrid(rv, tv, pv);
x = RQ.*sin(TQ).*cos(PQ);
y = RQ.*sin(TQ).*sin(PQ);
z = RQ.*cos(TQ);
r = max(RQ, realmin);
k = p.a_m*p.b_m/(p.b_m - p.a_m);
V = p.V0_V*k*(1./r - 1/p.b_m);
Er = p.V0_V*k./r.^2;
F.nodes = [x(:), y(:), z(:)];
F.potential = V(:);
F.ex = Er(:).*sin(TQ(:)).*cos(PQ(:));
F.ey = Er(:).*sin(TQ(:)).*sin(PQ(:));
F.ez = Er(:).*cos(TQ(:));
F.weighting_potential = (1./r(:) - 1/p.b_m)/(1/p.a_m - 1/p.b_m);
F.wx = F.ex(:)/p.V0_V;
F.wy = F.ey(:)/p.V0_V;
F.wz = F.ez(:)/p.V0_V;
F.mesh_dof = numel(F.potential);
F.mesh_dof_two_solves = F.mesh_dof;   % 解析容器只有一次闭式采样
F.mesh_nodes = F.mesh_dof;
F.mesh_elements = NaN;
F.analytic_max_rel_err = NaN;
F.analytic_potential_max_rel_err = NaN;
F.analytic_field_max_rel_err = NaN;
F.analytic_weighting_max_rel_err = NaN;
end

% ==================================================================== 通用小工具
function e = maxRelErr(num, den, normValue)
% 最大相对偏差。分子逐点差, 分母用给定的**非零**尺度 normValue (避免 0/0 与逐点近奇异)。
d = double(num(:)) - double(den(:));
if ~(normValue > 0) || ~isfinite(normValue)
    e = NaN;
    return;
end
e = max(abs(d))/normValue;
end
