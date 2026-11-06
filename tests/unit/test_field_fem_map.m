function tests = test_field_fem_map
%TEST_FIELD_FEM_MAP 2-D 轴对称静电场图 (FEM) 求解器、网格收敛与 field.mode 分派。
%   覆盖五件事:
%     (1) 解析缺省路径逐位不变: fieldOf 在 mode='analytic' 下必须与 fieldModel
%         完全同一对象, 且仍复现改动前记录的基线快照 tests/golden/baseline_pre_r17.json
%         (K、E(a)、intE(a,r0)、G_mean) —— 接线不允许动物理。
%     (2) solveElectrostatic 真跑 PDE 并给出有限场图 (节点量 + 采样路径 + 积分量)。
%     (3) 三级网格收敛: 只对积分量判 (阳极通量、径向场线积分、权重势差);
%         逐点阳极面 E 只报告不判据 —— 它在丝状阳极面上按 1/r 发散, 无网格无关极限。
%     (4) 同轴极限下与闭式 E=V/(r ln(b/a)) 的偏差落在预注册阈值内 (r>=2a 子域)。
%     (5) fem_map 消费方在场图缺失 / 几何不符 / 指纹过期时必须炸, 不静默退回解析场。
%   指纹负对照: test_tampered_fingerprint_is_rejected 把 map.fingerprint 改一个字符,
%   要求 tepc:field:MapStaleFingerprint; 同一份场图未改时必须可用 (否则该断言会因为
%   "任何输入都报错"而平凡通过)。
%   阈值不写在代码里: 由 tepc.detector.fieldConvergence 从 docs/constants.json 读,
%   本文件也走同一条读取路径, 因此改注册表即改门禁。
tests = functiontests(localfunctions);
end

% ==================== 基线常量 ====================

function B = baseline()
% 改动前录下的解析场数值快照 (由另一个批次写入, 本文件只读不改)。
p = fullfile(tepc.io.projectRoot(), 'tests', 'golden', 'baseline_pre_r17.json');
assert(isfile(p), '缺基线快照 %s —— 无法核对解析路径是否逐位不变', p);
B = jsondecode(fileread(p));
assert(isfield(B, 'field') && isfield(B.field, 'cylinder'), '基线缺 field.cylinder 段');
assert(isfield(B, 'radii') && isfield(B, 'resolve'), '基线缺 radii/resolve 段');
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function C = coaxConv()
% 三级收敛研究只做一次, 结果在本文件的多个用例间共享 (PDE 求解是秒级开销)。
persistent cache
if isempty(cache)
    cache = tepc.detector.fieldConvergence(50e-6, 25.4e-3, 700, struct('geometry', 'coax'));
end
C = cache;
end

% ==================== (1) 解析缺省路径逐位不变 ====================

function test_fieldOf_analytic_is_the_same_object_as_fieldModel(tc)
B = baseline();
a = double(B.radii.a_m); b = double(B.radii.b_m); V = double(B.radii.hv_V);
field = struct('a', a, 'b', b, 'hv_V', V, 'kind', 'cylinder');
fA = tepc.detector.fieldModel(a, b, V, 'cylinder');
fB = tepc.detector.fieldOf(field, a, b, V, 'cylinder');
tc.verifyEqual(fieldnames(fB), fieldnames(fA), ...
    '解析模式不得给场模型增删字段 (下游按字段名取值的代码会跟着变)');
r = geomspace(1.001*a, b*0.999, 37);
qty = {'E', 'phiw'};
for i = 1:numel(qty)
    h = qty{i};
    tc.verifyEqual(fB.(h)(r), fA.(h)(r), 'RelTol', 0, ...
        sprintf('解析模式 %s(r) 与 fieldModel 不逐位相同', h));
end
tc.verifyEqual(fB.intE(a*1.001, b*0.5), fA.intE(a*1.001, b*0.5), 'RelTol', 0);
tc.verifyEqual(fB.rOfT(b*0.5, 2e-4, -1, linspace(0, 1e-3, 9)), ...
    fA.rOfT(b*0.5, 2e-4, -1, linspace(0, 1e-3, 9)), 'RelTol', 0);
tc.verifyEqual(fB.tCollect(b*0.5, 2e-4, a), fA.tCollect(b*0.5, 2e-4, a), 'RelTol', 0);
tc.verifyEqual(fB.gainExponent(10*a, 36.5), fA.gainExponent(10*a, 36.5), 'RelTol', 0);
tc.verifyEqual(fB.p, fA.p);  tc.verifyEqual(fB.K, fA.K);  tc.verifyEqual(fB.kind, fA.kind);
end

function test_fieldOf_defaults_to_analytic_and_matches_prechange_baseline(tc)
B = baseline();
fc = B.field.cylinder;
a = double(B.radii.a_m); b = double(B.radii.b_m); V = double(B.radii.hv_V);
% field 里没有 mode 字段 -> 缺省必须是解析场 (历史行为)。
f = tepc.detector.fieldOf(struct('a', a, 'b', b, 'hv_V', V, 'kind', 'cylinder'));
r0 = double(B.resolve(1).r0_m);
tc.verifyEqual(f.K, double(fc.K), 'RelTol', 0, 'K 与改动前基线不逐位相同');
tc.verifyEqual(f.p, 2);
% 基线里的 E(a)/E(b) 是在开区间内偏移 1e-6 相对量处取的 (阳极面解析场发散,
% 逐点取 a 本身没有意义), 这里必须按同一口径比, 否则比的就不再是同一个数。
tc.verifyEqual(f.E(a*(1 + 1e-6)), double(fc.E_at_a), 'RelTol', 0, ...
    'E 在阳极侧 1+1e-6 处的值与改动前基线不逐位相同');
tc.verifyEqual(f.E(b*(1 - 1e-6)), double(fc.E_at_b), 'RelTol', 0, ...
    'E 在阴极侧 1-1e-6 处的值与改动前基线不逐位相同');
tc.verifyEqual(f.intE(a, r0), double(fc.intE_a_rStart), 'RelTol', 0, ...
    'intE(a,r0) 与改动前基线不逐位相同 (Diethorn 增益用的那个积分)');
tc.verifyEqual(f.phiw(a), 1, 'RelTol', 0);
tc.verifyEqual(f.phiw(b), 0, 'AbsTol', 0);
G = exp(log(2)/36.5 * f.intE(a, r0));
tc.verifyEqual(G, double(fc.G_analytic), 'RelTol', 0, ...
    '由解析场复算的 G_mean 与改动前基线不逐位相同');
% 球壳分支同样要逐位复现 (接线只换了入口函数, 两种拓扑都不许动)。
fs = tepc.detector.fieldOf(struct('a', a, 'b', b, 'hv_V', V, 'kind', 'sphere'));
tcd = tepc.detector.fieldModel(a, b, V, 'cylinder');
tc.verifyEqual(fs.K, double(B.field.sphere.K), 'RelTol', 0, '球壳 K 与改动前基线不逐位相同');
tc.verifyEqual(fs.intE(a, r0), double(B.field.sphere.intE_a_rStart), 'RelTol', 0);
tc.verifyEqual(fs.p, 3);
tc.verifyNotEqual(fs.E(2*a), tcd.E(2*a), '两种拓扑在同一点的场必须不同 (防止 kind 被静默忽略)');
end

function test_resolve_still_reproduces_shipped_gain(tc)
R = tepc.config.resolve(demoCfg());
tc.verifyEqual(R.field.kind, 'cylinder', ...
    'field.kind 仍只表达电极拓扑 (axialWire=>cylinder), 不得被场来源开关顶替');
tc.verifyEqual(R.field.mode, 'analytic', 'demo 配置的 field.mode 缺省必须是 analytic');
tc.verifyEqual(R.G_mean, 136.01301895613094, 'RelTol', 1e-12, ...
    '接线后解析缺省路径的 G_mean 必须逐位复现改动前记录值');
end

% ==================== (2) 求解器产出合法场图 ====================

function test_solve_returns_finite_field_map(tc)
mp = tepc.detector.solveElectrostatic(50e-6, 25.4e-3, 700, struct('gridLevel', 1));
tc.verifyEqual(mp.schema, 'tepc-fieldmap-v1');
tc.verifyEqual(mp.a_m, 50e-6);  tc.verifyEqual(mp.b_m, 25.4e-3);
tc.verifyEqual(mp.hv_V, 700);   tc.verifyEqual(mp.gridLevel, 1);
tc.verifyGreaterThan(mp.nCells, 200);
tc.verifyGreaterThan(mp.nDof, 200);
tc.verifyEqual(mp.nDof, mp.nNodes, '轴对称静电只有电位一个场变量 -> DOF = 节点数');
tc.verifyTrue(all(isfinite(mp.V)) && all(isfinite(mp.Er)) && all(isfinite(mp.Ez)), ...
    '节点量必须有限');
tc.verifyTrue(all(isfinite(mp.path.r_m)) && all(mp.path.r_m > 0) && ...
    all(diff(mp.path.r_m) > 0), '采样半径必须有限且严格递增');
tc.verifyTrue(all(isfinite(mp.path.V)) && all(isfinite(mp.path.Emag)) && ...
    all(mp.path.Emag > 0), '路径电位与场强必须有限为正');
tc.verifyTrue(abs(mp.path.phiw(1) - 1) < 1e-9, ...
    '阳极面 Dirichlet 值必须被满足: phi_w(a)=1');
tc.verifyGreaterThan(mp.path.r_m(1), 0.999*mp.a_m);
tc.verifyLessThan(mp.path.r_m(end), mp.b_m);
% 积分量必须为正且量级合理: int|E|dr = 电位降 = 接近 hv_V。
tc.verifyGreaterThan(mp.integral.lineIntEmag, 0.9*mp.hv_V);
tc.verifyLessThan(mp.integral.lineIntEmag, 1.1*mp.hv_V);
tc.verifyGreaterThan(mp.integral.phiwDiff, 0);
tc.verifyGreaterThan(mp.integral.fluxAnode, 0);
tc.verifyGreaterThan(mp.evidence.solve_time_s, 0);
fprintf('[tepc_wp2] level1 cells=%d nodes=%d dof=%d mesh=%.2fs solve=%.2fs flux=%.8g\n', ...
    mp.nCells, mp.nNodes, mp.nDof, mp.evidence.mesh_time_s, mp.evidence.solve_time_s, ...
    mp.integral.fluxAnode);
end

function test_solver_evidence_records_versions_and_value_status(tc)
mp = tepc.detector.solveElectrostatic(50e-6, 25.4e-3, 700, struct( ...
    'gridLevel', 1, 'valueStatus', struct('a_m', 'MEASURED', 'b_m', 'MEASURED'), ...
    'valueSource', struct('a_m', '图纸名义值 (测试注入)')));
e = mp.evidence;
tc.verifyEqual(e.analysis_type, 'electrostatic-axisymmetric');
tc.verifyEqual(e.license_feature, 'PDE_Toolbox');
tc.verifyTrue(isscalar(e.license_available) && islogical(e.license_available), ...
    "license('test','PDE_Toolbox') 的检查结果必须是逻辑标量");
tc.verifyEqual(e.license_available, true, '本机没有 PDE 许可时其余用例也无意义, 直接红灯');
tc.verifyFalse(isempty(e.matlab_version) || isempty(e.matlab_release));
tc.verifyFalse(isempty(e.pde_product), 'ver 里找不到 PDE 产品条目: 溯源信息不完整');
ps = e.parameter_status;
tc.verifyGreaterThan(numel(ps), 4);
names = {ps.name};
for i = 1:numel(names)
    tc.verifyTrue(any(strcmp(ps(i).value_status, {'MEASURED', 'REFERENCE', 'ASSUMED'})), ...
        sprintf('参数 %s 的 value_status=%s 不在词表内', names{i}, ps(i).value_status));
end
kA = find(strcmp(names, 'a_m'));
tc.verifyEqual(ps(kA).value_status, 'MEASURED', '调用方覆写的取值状态必须落到证据里');
tc.verifyEqual(ps(kA).source, '图纸名义值 (测试注入)');
end

function test_solver_input_validation(tc)
tc.verifyError(@() tepc.detector.solveElectrostatic(0, 25.4e-3, 700), 'tepc:field:BadRadii');
tc.verifyError(@() tepc.detector.solveElectrostatic(30e-3, 25.4e-3, 700), 'tepc:field:BadRadii');
tc.verifyError(@() tepc.detector.solveElectrostatic(50e-6, 25.4e-3, 700, struct('gridLevel', 9)), ...
    'tepc:field:BadGridLevel');
tc.verifyError(@() tepc.detector.solveElectrostatic(50e-6, 25.4e-3, 700, struct('geometry', 'slab')), ...
    'tepc:field:BadGeometry');
tc.verifyError(@() tepc.detector.solveElectrostatic(50e-6, 25.4e-3, 700, ...
    struct('gridLevel', 1, 'valueStatus', struct('a_m', 'GUESSED'))), 'tepc:field:BadValueStatus');
end

% ==================== (3)+(4) 网格收敛与同轴极限验证 ====================

function test_three_level_convergence_of_integral_quantities(tc)
C = coaxConv();
tc.verifyEqual(numel(C.levels), 3);
tol = tepc.config.constants('field.fem.convergenceMaxRelDelta');
q = {'fluxAnode', 'lineIntEmag', 'phiwDiff'};
worst = 0;
for i = 1:numel(q)
    v = [C.levels.(q{i})];
    fprintf('[tepc_wp2] %s 三级 = %.9g  %.9g  %.9g\n', q{i}, v(1), v(2), v(3));
    d = [C.delta.(q{i})];
    fprintf('[tepc_wp2] %s 相邻层级相对变化 = %.4e  %.4e\n', q{i}, d(1), d(2));
    tc.verifyTrue(all(isfinite(v)) && all(v ~= 0), sprintf('%s 必须是有限非零', q{i}));
    tc.verifyTrue(all(d <= tol), sprintf('%s 的层级间相对变化超过门禁 %.0e', q{i}, tol));
    worst = max(worst, max(d));
end
tc.verifyEqual(C.gate.maxObservedRelDelta, worst, 'RelTol', 0, ...
    '门禁里的最大相对变化必须等于逐级实测的最大值');
tc.verifyTrue(C.gate.convergencePassed, ...
    sprintf('收敛门禁未通过: 实测最大相对变化 %.3e > 阈值 %.3e', worst, tol));
% 逐点阳极面峰值只在积分量收敛的同时单调上移 -> 只报告, 不进判据。
pk = [C.levels.anodePeakEmag];
fprintf('[tepc_wp2] anodePeakEmag 三级 = %.6g %.6g %.6g (发散量, 不作判据)\n', pk(1), pk(2), pk(3));
fprintf('[tepc_wp2] cells/dof/各级 = %d/%d %.2fs, %d/%d %.2fs, %d/%d %.2fs\n', ...
    C.levels(1).nCells, C.levels(1).nDof, C.levels(1).solveTime_s, ...
    C.levels(2).nCells, C.levels(2).nDof, C.levels(2).solveTime_s, ...
    C.levels(3).nCells, C.levels(3).nDof, C.levels(3).solveTime_s);
end

function test_coax_deviation_vs_analytic_below_gate(tc)
C = coaxConv();
tol = tepc.config.constants('field.fem.maxRelDevEmagAwayOfAnode');
fin = C.levels(end);
fprintf('[tepc_wp2] 最细层 r>=2a 子域: maxRelDev|E|=%.4e  maxRelDevV=%.4e (门禁 %.0e)\n', ...
    fin.maxRelDevEr, fin.maxRelDevV, tol);
tc.verifyTrue(C.gate.deviationApplied, '同轴极限几何必须启用闭式偏差门禁');
tc.verifyLessThanOrEqual(fin.maxRelDevEr, tol, ...
    sprintf('|E| 对闭式解的最大相对偏差 %.3e 超过预注册阈值 %.3e', fin.maxRelDevEr, tol));
tc.verifyLessThanOrEqual(fin.maxRelDevV, tol, '电位偏差比场强偏差更严, 不应超阈值');
% 偏差必须随网格加密单调下降, 否则"对上闭式解"可能只是巧合。
dv = [C.levels.maxRelDevEr];
tc.verifyTrue(dv(2) < dv(1) && dv(3) < dv(2), ...
    sprintf('maxRelDevEr 未随层级单调下降: %.3e %.3e %.3e', dv(1), dv(2), dv(3)));
% 增益真正用的积分 int_a^{10a} E dr 与闭式 V*K*ln(10) 的相对偏差 (场图口径)。
fprintf('[tepc_wp2] intE(a,10a) 相对偏差 三级 = %.3e %.3e %.3e\n', ...
    C.levels(1).intE_a_10a_rel, C.levels(2).intE_a_10a_rel, C.levels(3).intE_a_10a_rel);
tc.verifyLessThan(abs(C.levels(end).intE_a_10a_rel), 1e-3, ...
    '换成场图后增益区积分的相对偏差应在千分之一内');
end

function test_sphere_wire_geometry_runs_and_reports_physical_gap(tc)
C = tepc.detector.fieldConvergence(50e-6, 25.4e-3, 700, ...
    struct('geometry', 'sphereWire', 'levels', [1 2]));
fin = C.levels(end);
fprintf(['[tepc_wp2] sphereWire 层级2: cells=%d dof=%d solve=%.2fs maxRelDev|E|(r>=2a)=%.4e ' ...
    'flux=%.8g (理想同轴 %.8g) intE(a,10a) 相对偏差=%.4e\n'], ...
    fin.nCells, fin.nDof, fin.solveTime_s, fin.maxRelDevEr, fin.fluxAnode, ...
    C.map.integral.fluxAnodeIdealCoax, fin.intE_a_10a_rel);
tc.verifyTrue(isfinite(fin.fluxAnode) && fin.fluxAnode > 0);
tc.verifyEqual(C.gate.deviationApplied, false, ...
    '球-丝几何下与闭式的差是物理差, 不得当求解器误差判门禁');
% 积分量仍必须收敛 (两级之间的相对变化落在同一阈值内)。
tol = tepc.config.constants('field.fem.convergenceMaxRelDelta');
d = [C.delta.fluxAnode, C.delta.lineIntEmag, C.delta.phiwDiff];
fprintf('[tepc_wp2] sphereWire 层级1->2 相对变化 flux=%.4e lineInt=%.4e phiwDiff=%.4e\n', ...
    C.delta(1).fluxAnode, C.delta(1).lineIntEmag, C.delta(1).phiwDiff);
tc.verifyTrue(all(d <= tol), sprintf('球-丝几何积分量未收敛: 最大相对变化 %.3e > %.3e', max(d), tol));
% 理想同轴公式在这个真实边值问题下确实偏离 (这才是引入场图的理由):
% 物理差必须远大于同轴极限下的离散误差, 否则"用场图代替闭式"没有任何后果。
Cc = coaxConv();
tc.verifyGreaterThan(abs(fin.intE_a_10a_rel), 1e-3, ...
    '球-丝几何与理想同轴公式的增益区积分偏差过小, 说明真实几何没有生效');
tc.verifyGreaterThan(abs(fin.intE_a_10a_rel), ...
    20*abs(Cc.levels(end).intE_a_10a_rel), ...
    '真实边值问题与理想公式的物理差应当远大于求解器自身的离散误差');
end

% ==================== (5) 消费方: fem_map 分派与拒绝路径 ====================

function test_fem_map_consumer_matches_analytic_within_gate(tc)
C = coaxConv();
mp = C.map;
B = baseline();
a = mp.a_m; b = mp.b_m; V = mp.hv_V;
field = struct('a', a, 'b', b, 'hv_V', V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'map', mp);
fm = tepc.detector.fieldOf(field);
tc.verifyEqual(fm.mode, 'fem_map');
tc.verifyEqual(fm.kind, 'cylinder', 'field.kind 仍表达拓扑, 不得被 mode 改写');
tc.verifyTrue(isnan(fm.p) && isnan(fm.K), ...
    'p/K 是闭式属性: 场图模式下必须是 NaN, 让"读 K 走闭式"的代码显式失败而不是拿假 K');
tc.verifyEqual(fm.fingerprint, char(string(mp.fingerprint)));
r = geomspace(2*a, b*0.9, 21);
Ea = V./(r*log(b/a));
tc.verifyTrue(all(isfinite(fm.E(r))) && all(fm.E(r) > 0), 'E(r) 必须有限为正');
tol = tepc.config.constants('field.fem.maxRelDevEmagAwayOfAnode');
tc.verifyTrue(max(abs(fm.E(r)./Ea - 1)) <= tol, ...
    sprintf('消费方插值出的 |E| 偏离闭式 %.3e > 阈值 %.3e', max(abs(fm.E(r)./Ea - 1)), tol));
% 端点条件必须与解析模型同构 (Ramo 权重场的定义)。
tc.verifyEqual(fm.phiw(a), 1, 'AbsTol', 1e-12);
tc.verifyEqual(fm.phiw(b), 0, 'AbsTol', 1e-12);
tc.verifyTrue(fm.phiw(2*a) > fm.phiw(b/2) && fm.phiw(b/2) > 0, '权重场必须单调');
% intE 的可加性与"积分=电位差"的定义式。
tc.verifyEqual(fm.intE(a, b/2) + fm.intE(b/2, b), fm.intE(a, b), 'RelTol', 1e-12, ...
    'intE 必须对分段可加 (它就是一个位势差)');
tc.verifyEqual(fm.intE(a, b), V, 'RelTol', 1e-9, '∫_a^b E dr 必须回到外加电压');
gi = fm.intE(a, 10*a);
tc.verifyEqual(gi, double(B.field.cylinder.intE_a_rStart), 'RelTol', 0.01, ...
    '场图口径的增益区积分与解析基线的偏差必须在百分点内');
% 漂移时序句柄: 电子向阳极单调缩短, 离子向阴极单调增长, 端点钳位。
tb = linspace(0, 1e-3, 15);
re = fm.rOfT(b*0.5, 2e-4, -1, tb);
ri = fm.rOfT(b*0.5, 2e-4, +1, tb);
tc.verifyTrue(all(diff(re) <= 1e-12) && all(re >= a - 1e-15) && all(re <= b*0.5 + 1e-15), ...
    '电子轨迹必须单调向内且不越过阳极');
tc.verifyTrue(all(diff(ri) >= -1e-12) && all(ri <= b + 1e-15), '离子轨迹必须单调向外且钳在阴极');
te = fm.tCollect(b*0.5, 2e-4, a);
ti = fm.tCollect(b*0.5, 2e-4, b);
tc.verifyTrue(isfinite(te) && te > 0 && isfinite(ti) && ti > 0);
ta = tepc.detector.fieldModel(a, b, V, 'cylinder');
fprintf('[tepc_wp2] 收集时间 解析/场图: 电子 %.6e/%.6e s, 离子 %.6e/%.6e s\n', ...
    ta.tCollect(b*0.5, 2e-4, a), te, ta.tCollect(b*0.5, 2e-4, b), ti);
tc.verifyEqual(te, ta.tCollect(b*0.5, 2e-4, a), 'RelTol', 0.02, ...
    '同一几何下两种模式的电子收集时间应在 2% 内 (低气压下漂移时标是 ASSUMED 量级)');
end

function test_fem_map_detects_geometry_mismatch(tc)
mp = coaxConv().map;
bad = struct('a', mp.a_m*1.01, 'b', mp.b_m, 'hv_V', mp.hv_V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'map', mp);
tc.verifyError(@() tepc.detector.fieldOf(bad), 'tepc:field:MapGeometry');
badV = struct('a', mp.a_m, 'b', mp.b_m, 'hv_V', mp.hv_V + 1, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'map', mp);
tc.verifyError(@() tepc.detector.fieldOf(badV), 'tepc:field:MapGeometry');
end

function test_tampered_fingerprint_is_rejected(tc)
mp = coaxConv().map;
% 正对照: 未改动的场图必须能用, 否则下面的红灯可能只是"什么都拒绝"。
ok = struct('a', mp.a_m, 'b', mp.b_m, 'hv_V', mp.hv_V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'map', mp);
fOk = tepc.detector.fieldOf(ok);
tc.verifyEqual(fOk.mode, 'fem_map');
tc.verifyTrue(all(isfinite(fOk.E(geomspace(2*mp.a_m, mp.b_m*0.9, 5)))));
% 负对照: 只把指纹改一个字符 (几何/网格字段原样) -> 必须当场炸。
brk = mp;
fp = char(string(brk.fingerprint));
i = 1;
if fp(i) == '0', fp(i) = '1'; else, fp(i) = '0'; end
brk.fingerprint = fp;
bad = struct('a', mp.a_m, 'b', mp.b_m, 'hv_V', mp.hv_V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'map', brk);
tc.verifyError(@() tepc.detector.fieldOf(bad), 'tepc:field:MapStaleFingerprint');
% 反过来: 改了半径却留着原指纹 (旧场图冒充新几何) 也必须炸。
swap = mp;
swap.a_m = mp.a_m*(1 + 1e-6);        % 指纹按自身身份重算后与原值不符
bad2 = struct('a', swap.a_m, 'b', swap.b_m, 'hv_V', swap.hv_V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'map', swap);
tc.verifyError(@() tepc.detector.fieldOf(bad2), 'tepc:field:MapStaleFingerprint');
% 指纹确实对每个身份量敏感 (含 1 ulp 级别的半径改动)。
f1 = tepc.detector.fieldMapFingerprint(mp.a_m, mp.b_m, mp.hv_V, mp.gridLevel, mp.geometry);
f2 = tepc.detector.fieldMapFingerprint(mp.a_m*(1 + eps), mp.b_m, mp.hv_V, mp.gridLevel, mp.geometry);
f3 = tepc.detector.fieldMapFingerprint(mp.a_m, mp.b_m, mp.hv_V, mp.gridLevel, 'sphereWire');
tc.verifyFalse(strcmp(f1, f2), '半径变 1 ulp 指纹不变: 指纹没有判别力');
tc.verifyFalse(strcmp(f1, f3), 'geometry 不进指纹: coax 与 sphereWire 场图可互相冒充');
tc.verifyEqual(numel(f1), 64);
end

function test_missing_map_and_missing_mode_are_rejected(tc)
mp = coaxConv().map;
noMap = struct('a', mp.a_m, 'b', mp.b_m, 'hv_V', mp.hv_V, 'kind', 'cylinder', 'mode', 'fem_map');
tc.verifyError(@() tepc.detector.fieldOf(noMap), 'tepc:field:MapMissing');
noFile = noMap;  noFile.mapFile = 'Z:/definitely/not/here/tepc_field_map.mat';
tc.verifyError(@() tepc.detector.fieldOf(noFile), 'tepc:field:MapFileMissing');
schema = mp;  schema.schema = 'tepc-fieldmap-v0';
badSch = struct('a', mp.a_m, 'b', mp.b_m, 'hv_V', mp.hv_V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'map', schema);
tc.verifyError(@() tepc.detector.fieldOf(badSch), 'tepc:field:MapSchema');
trunc = mp;  trunc.path = rmfield(trunc.path, 'Emag');
badPath = struct('a', mp.a_m, 'b', mp.b_m, 'hv_V', mp.hv_V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'map', trunc);
tc.verifyError(@() tepc.detector.fieldOf(badPath), 'tepc:field:MapSchema');
% 未知模式与旧 schema 值 'map' 都必须被词表拒绝 (接受但不实现的开关是假开关)。
tc.verifyError(@() tepc.detector.fieldOf(struct('a', mp.a_m, 'b', mp.b_m, ...
    'hv_V', mp.hv_V, 'mode', 'map')), 'tepc:field:BadMode');
tc.verifyError(@() tepc.detector.fieldOf(struct('a', mp.a_m, 'b', mp.b_m, ...
    'hv_V', mp.hv_V, 'mode', 'finite_difference')), 'tepc:field:BadMode');
tc.verifyEqual(tepc.detector.fieldModeOf(struct('a', 1)), 'analytic');
tc.verifyEqual(tepc.detector.fieldModeOf(struct('a', 1, 'mode', ' FEM_MAP ')), 'fem_map');
end

function test_map_file_round_trip_is_accepted_and_stale_file_rejected(tc)
mp = coaxConv().map;
d = fullfile(tempdir, sprintf('tepc_wp2_map_%d.mat', feature('getpid')));
cleanup = onCleanup(@() deleteIfAny(d));
w = tepc.detector.solveElectrostatic(mp.a_m, mp.b_m, mp.hv_V, ...
    struct('gridLevel', 1, 'savePath', d));
tc.verifyTrue(isfile(d), 'opts.savePath 没有落盘场图');
tc.verifyEqual(w.evidence.saved_sha256, tepc.io.hashFile(d), '落盘后哈希与文件不一致');
field = struct('a', w.a_m, 'b', w.b_m, 'hv_V', w.hv_V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'mapFile', d);
fm = tepc.detector.fieldOf(field);
tc.verifyEqual(fm.fingerprint, char(string(w.fingerprint)), ...
    '经 .mat 读回的场图指纹必须不变 (指纹只由身份元组决定, 不落进序列化差异)');
tc.verifyTrue(all(isfinite(fm.E(geomspace(2*w.a_m, w.b_m*0.9, 9)))));
% 换掉文件内容 (几何字段被改, 指纹仍是旧的) 后必须重新判别, 不能吃缓存。
s0 = load(d);
mp2 = s0.map;
mp2.a_m = mp2.a_m*(1 + 1e-5);
save(d, 'mp2');
pause(1.2);                        % mtime 分辨率保护: 同一秒内改写也要被看到
field2 = struct('a', mp2.a_m, 'b', mp2.b_m, 'hv_V', mp2.hv_V, 'kind', 'cylinder', ...
    'mode', 'fem_map', 'mapFile', d);
tc.verifyError(@() tepc.detector.fieldOf(field2), 'tepc:field:MapStaleFingerprint');
end

function test_config_layer_rejects_bad_mode_and_missing_map(tc)
codes = codesOf(tepc.config.validate(demoCfg()));
tc.verifyFalse(any(startsWith(upper(string(codes)), "FIELD_MODE")), ...
    sprintf('解析缺省配置不该报任何 field.mode 问题 (实得 %s)', strjoin(codes, ',')));
cfg = demoCfg();
cfg.field.mode = "map";                       % 旧 schema 里存在、但无人实现的值
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("FIELD_MODE_UNSUPPORTED", upper(string(codes))), ...
    sprintf('field.mode=map 必须被校验层拒绝 (实得 %s)', strjoin(codes, ',')));
cfg.field.mode = "fem_map";
cfg.field.mapFile = "Z:/no/such/map.mat";
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("FIELD_MAP_MISSING", upper(string(codes))), ...
    sprintf('fem_map 而无可用场图文件必须报错 (实得 %s)', strjoin(codes, ',')));
tc.verifyTrue(ismember("FIELD_MAP_GAIN_GATE_ANALYTIC", upper(string(codes))), ...
    '增益门禁按解析场评估这一事实必须用 WARN 明示, 不许悄悄冒充');
end

% ==================== 辅助 (名字不以 test 开头, 不被收集为用例) ====================

function codes = codesOf(issues)
if isempty(issues)
    codes = strings(0, 1);
    return;
end
codes = string(cellfun(@(s) string(s.code), issues, 'UniformOutput', false));
end

function r = geomspace(lo, hi, n)
r = lo*(hi/lo).^((0:n-1)/(n - 1));
end

function deleteIfAny(f)
if isfile(f), delete(f); end
end
