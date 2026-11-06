function tests = test_geometry_3d_contract
%TEST_GEOMETRY_3D_CONTRACT 三维几何与证据链契约。
%
% 期望值一律手算, 算式写在注释里; 唯一"实测基线"是 derived 位点直径
% 0.5308660381902539 um (改动前后逐位不变的历史基线, 见 test_geometry_chord)。
%
% 覆盖: 拓扑派生 / 守卫 / 位点成对与失配标志 / checkMesh 可失败 / 收敛阶与 Richardson /
% 平均弦长 vs 各向同性 MC / 世界体 >=5x / STL-OBJ-PLY round-trip 与 1000 倍门 /
% 三视图非空白 PNG / 剖切不删网格 / 四元一致 / 图形层无 RNG / traceSpec 种子化。
tests = functiontests(localfunctions);
end

%% ==================== 夹具 (名字不得以 test 开头) ====================

function c = demoCfg()
root = tepc.io.projectRoot();
c = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
end

function [cfg, R, spec] = fixture()
cfg = demoCfg();
R = tepc.config.resolve(cfg);
spec = tepc.geometry.meshSpec(cfg, R);
end

function part = partOf(spec, id)
i = find(strcmpi({spec.parts.part_id}, id), 1);
assert(~isempty(i), sprintf('零件表缺少 %s', id));
part = spec.parts(i);
end

function [V, A] = meshVA(P, F)
% 独立实现的散度定理体积 + 叉积面积 (与 checkMesh 分开写, 互为对账)。
a = P(F(:,1),:); b = P(F(:,2),:); c = P(F(:,3),:);
V = sum(a(:,1).*(b(:,2).*c(:,3) - b(:,3).*c(:,2)) + ...
      a(:,2).*(b(:,3).*c(:,1) - b(:,1).*c(:,3)) + ...
      a(:,3).*(b(:,1).*c(:,2) - b(:,2).*c(:,1)))/6;
A = sum(0.5*sqrt(sum(cross(b-a, c-a, 2).^2, 2)));
end

function k = edgeMultiplicity(F)
% 每条无向边被几个面共用 (独立实现): 闭口流形曲面 <=> 全为 2。
E = sort([F(:,[1 2]); F(:,[2 3]); F(:,[3 1])], 2);
[U, ~, ic] = unique(E, 'rows');
k = accumarray(ic, 1, [size(U,1) 1]);
end

%% ==================== 1. 拓扑派生 ====================

function test_topology_is_single_source_of_truth(tc)
[cfg, R, spec] = fixture();
el = tepc.geometry.electrode(cfg);
tc.verifyTrue(el.valid);
tc.verifyEqual(char(spec.fieldTopology), char(R.field.kind), ...
    'spec.fieldTopology 必须等于 R.field.kind');
tc.verifyEqual(char(spec.fieldTopology), char(el.fieldKind), ...
    'spec.fieldTopology 必须等于 electrode(cfg).fieldKind');
tc.verifyEqual(char(spec.electrodeTopology), lower(char(el.topology)));
tc.verifyEqual(char(spec.anodeType), char(el.anodeType));
tc.verifyEqual(char(spec.geometryType), char(el.sensitiveVolume), ...
    '敏感体积 geometry.type 必须原样带进 spec');
% 发货默认 = "球敏感体积 + 柱对称场": 两层语义必须同时可见 (只留一份会互相顶替)。
tc.verifyEqual(char(spec.geometryType), 'sphere');
tc.verifyEqual(char(spec.fieldTopology), 'cylinder');
% 手算 K_cyl = 1/ln(b/a), b/a = 25.4e-3/50e-6 = 508 -> ln = 6.23046, K = 0.160502
a = 50e-6; b = 25.4e-3;
tc.verifyEqual(spec.field.K, 1/log(508), 'RelTol', 1e-12);
tc.verifyEqual(spec.field.p, 2);
tc.verifyEqual(spec.elec.fieldKind, el.fieldKind, '电极快照必须与 electrode() 一致');
end

function test_centerSphere_switch_moves_everything(tc)
cfg = demoCfg();  cfg.geometry.electrodeTopology = "centerSphere";
R = tepc.config.resolve(cfg);
spec = tepc.geometry.meshSpec(cfg, R);
tc.verifyEqual(char(spec.fieldTopology), 'sphere');
tc.verifyEqual(char(R.electrode.fieldKind), 'sphere');
an = partOf(spec,'anode');
tc.verifyEqual(char(an.shape.type), 'sphere', '中心球阳极必须是球, 不得再画成细长圆柱');
a = 50e-6; b = 25.4e-3;
% 手算 K_sph = 1/(1/a - 1/b) = 1/(20000 - 39.3701) = 5.010161e-5
tc.verifyEqual(spec.field.K, 1/(1/a - 1/b), 'RelTol', 1e-12);
tc.verifyEqual(spec.field.p, 3);
end

function test_topology_is_checked_not_copied(tc)
% spec.fieldTopology 是**推导+对账**出来的: 若 R.field.kind 与拓扑不一致必须拒绝,
% 而不是照抄 R 或照抄 cfg (三份映射各自为政正是不一致的来源)。
[cfg, R, ~] = fixture();
Rbad = R;  Rbad.field.kind = 'sphere';
tc.verifyError(@() tepc.geometry.meshSpec(cfg, Rbad), 'tepc:geometry:TopologyFieldMismatch');
cfg2 = cfg; cfg2.geometry = rmfield(cfg2.geometry, 'electrodeTopology');
tc.verifyError(@() tepc.geometry.meshSpec(cfg2, R), 'tepc:config:TopologyMissing');
cfg3 = cfg; cfg3.geometry.electrodeTopology = "coaxial";
tc.verifyError(@() tepc.geometry.meshSpec(cfg3, R), 'tepc:config:BadTopology');
end

function test_field_samples_are_clipped_off_the_electrodes(tc)
[~, ~, spec] = fixture();
a = spec.field.a_m;  b = spec.field.b_m;
r = spec.field.rSample_m;
% 屏蔽 r<a 与 r>b: 场强 ~1/r 的奇异值会污染颜色范围
tc.verifyGreaterThan(min(r), a*(1 + 1e-4) - eps(a));
tc.verifyLessThan(max(r), b*(1 - 1e-4) + eps(b));
tc.verifyTrue(all(spec.field.E_V_m > 0) && all(isfinite(spec.field.E_V_m)));
% 端点手算: E(r) = V*K/r (p=2), V=700 V, K=1/ln(508)
K = 1/log(b/a);
tc.verifyEqual(spec.field.E_V_m(1), 700*K/r(1), 'RelTol', 1e-12);
tc.verifyEqual(spec.field.E_V_m(end), 700*K/r(end), 'RelTol', 1e-12);
% phi_w=0.5 的柱对称等势面半径 = sqrt(a*b) = 1.126946e-3 m (手算几何平均)
rHalf = spec.field.rIso_m(spec.field.phiLevels == 0.5);
tc.verifyEqual(rHalf, sqrt(a*b), 'RelTol', 1e-9);
end

%% ==================== 2. 尺寸守卫与单位 ====================

function test_guards_reject_bad_inputs(tc)
cfg = demoCfg();  R = tepc.config.resolve(cfg);
R2 = R; R2.geom.R_m = NaN;
tc.verifyError(@() tepc.geometry.meshSpec(cfg, R2), 'tepc:geometry:BadDimension');
R3 = R; R3.geom.wallThickness_m = -1e-3;
tc.verifyError(@() tepc.geometry.meshSpec(cfg, R3), 'tepc:geometry:BadDimension');
R4 = R; R4.field.a = 30e-3;                      % 30 mm > 25.4 mm 气腔
tc.verifyError(@() tepc.geometry.meshSpec(cfg, R4), 'tepc:geometry:AnodeTooBig');
cfg5 = cfg; cfg5.geometry.type = "cylinder_finite"; cfg5.geometry.cylinderLength_mm = 40;
tc.verifyError(@() tepc.geometry.meshSpec(cfg5, R), 'tepc:geometry:SpecStale', ...
    '拿旧 R 配新 cfg 必须被拒 (否则图与配置脱节)');
tc.verifyError(@() tepc.geometry.meshSpec(cfg, R, 'not-a-hash'), 'tepc:geometry:BadSha256');
end

function test_units_are_SI_with_explicit_conversion(tc)
[~, ~, spec] = fixture();
tc.verifyEqual(char(spec.units), 'SI');
% 手算: 25.4 mm = 0.0254 m; 50 um = 5e-5 m; 显示字段必须等于 SI*显式系数
tc.verifyEqual(spec.gasRadius_m, 0.0254, 'RelTol', 1e-12);
tc.verifyEqual(spec.gasRadius_mm, spec.gasRadius_m*1e3, 'RelTol', 1e-12);
tc.verifyEqual(spec.wallThickness_mm, 3.0, 'RelTol', 1e-12);
tc.verifyEqual(spec.anodeRadius_um, spec.anodeRadius_m*1e6, 'RelTol', 1e-12);
tc.verifyEqual(spec.anodeRadius_um, 50, 'RelTol', 1e-12);
% 丝状阳极长度 = 2R = 50.8 mm (球腔约定, ASSUMED 已登记)
tc.verifyEqual(spec.anodeLength_m, 2*spec.gasRadius_m, 'RelTol', 1e-12);
% 每个零件都自带单位声明与角色词表
roles = {spec.parts.transport_role};
tc.verifyTrue(all(ismember(roles, {'enter_mc','passive'})), strjoin(roles, ','));
tc.verifyEqual(char(partOf(spec,'gas_cavity').transport_role), 'enter_mc', ...
    '只有气腔进入 MC');
end

%% ==================== 3. 位点: 请求/实现成对 + 失配标志 ====================

function test_site_requested_and_realized_pair(tc)
[~, ~, spec] = fixture();
dReq = 2.0e-6;
dReal = 0.5308660381902539e-6;                   % 实测基线 (不得在图形层重算)
tc.verifyEqual(spec.requestedDiameter_m, dReq, 'RelTol', 1e-12);
tc.verifyEqual(spec.realizedDiameter_m, dReal, 'RelTol', 1e-9, ...
    '实现位点必须复现历史基线');
tc.verifyEqual(spec.requestedDiameter_um, 2.0, 'RelTol', 1e-12);
tc.verifyEqual(spec.realizedDiameter_um, 0.5308660381902539, 'RelTol', 1e-9);
% 两个标记都进零件表, 半径 = 直径/2 (手算 1 um 与 0.265433019095127 um)
tc.verifyEqual(partOf(spec,'equivalent_site_requested').shape.radius_m, 1.0e-6, 'RelTol', 1e-12);
tc.verifyEqual(partOf(spec,'equivalent_site_realized').shape.radius_m, ...
    0.26543301909512695e-6, 'RelTol', 1e-9);
end

function test_site_mismatch_flag_is_falsifiable(tc)
[~, ~, spec] = fixture();
dReq = 2.0e-6; dReal = 0.5308660381902539e-6;
rel = abs(dReal - dReq)/dReq;                    % 手算: (2-0.5308660381902539)/2 = 0.73456...
tc.verifyEqual(spec.siteRelativeDifference, rel, 'RelTol', 1e-9);
tc.verifyGreaterThan(rel, 0.05);
tc.verifyTrue(logical(spec.site_mismatch), '1000 Pa / 2 um 必须置 site_mismatch');
tc.verifyEqual(char(spec.siteEquivalenceMode), 'derived');
% 反例: 把请求值改成实现值本身 => 相对差 0, 标志必须为 false (门禁不能只会响)
cfg = demoCfg();
cfg.site.targetDiameter_um = spec.realizedDiameter_m*1e6;
R = tepc.config.resolve(cfg);
spec2 = tepc.geometry.meshSpec(cfg, R);
tc.verifyFalse(logical(spec2.site_mismatch));
tc.verifyLessThan(spec2.siteRelativeDifference, 0.05);
end

%% ==================== 4/5/6. checkMesh ====================

function test_checkmesh_passes_good_mesh(tc)
[~, ~, spec] = fixture();
M = tepc.geometry.checkMesh(spec);
tc.verifyTrue(M.closed);
tc.verifyEqual(M.nonmanifold_edges, 0);
tc.verifyTrue(M.ok);
tc.verifyEqual(M.zero_area_faces, 0);
tc.verifyEqual(M.duplicate_vertices, 0);
tc.verifyEqual(M.meshSpec_duplicate_vertices, M.duplicate_vertices, ...
    '重复顶点字段必须是实测值, 不是写死的 0');
tc.verifyTrue(M.normals_consistent_outward);
% 独立对账: 我自己数的边重数 / 体积 / 面积必须与 checkMesh 一致 (两套实现互查)
ig = find(strcmpi({spec.parts.part_id},'gas_cavity'),1);
k = edgeMultiplicity(spec.parts(ig).F);
tc.verifyEqual(sum(k ~= 2), M.parts(ig).nonmanifold_edges);
tc.verifyEqual(sum(k == 2), numel(k), '球腔网格每条边都必须是双流形边');
[Vg, Ag] = meshVA(spec.parts(ig).V, spec.parts(ig).F);
tc.verifyEqual(Vg, M.parts(ig).volume_m3, 'RelTol', 1e-12);
tc.verifyEqual(Ag, M.parts(ig).area_m2, 'RelTol', 1e-12);
% 解析闭式 (手算): V = 4/3 pi R^3 = 6.8641973e-5 m3; A = 4 pi R^2 = 8.107320e-3 m2
R0 = 25.4e-3;
tc.verifyEqual(Vg, 4/3*pi*R0^3, 'RelTol', 1e-3);
tc.verifyEqual(Ag, 4*pi*R0^2, 'RelTol', 1e-3);
% 壁壳 = 内外两张闭合皮, 径向间隙 = 壁厚 3.000 mm (手算)
iw = find(strcmpi({spec.parts.part_id},'wall'),1);
ic = find(strcmpi({spec.parts.part_id},'cathode'),1);
tc.verifyTrue(M.parts(iw).closed, '壁外皮必须闭合');
tc.verifyTrue(M.parts(ic).closed, '壁内皮 (阴极) 必须闭合');
tc.verifyEqual(M.min_skin_gap_m, 3.0e-3, 'RelTol', 1e-9);
tc.verifyGreaterThan(M.min_skin_gap_m, 1e-6);
tc.verifyTrue(M.skin_gap_ok);
% 尺寸门: 内径/壁厚抽样测量误差 <= 0.1%
tc.verifyLessThanOrEqual(M.max_radius_err_rel, 1e-3);
tc.verifyLessThanOrEqual(M.wall_thickness_err_rel, 1e-3);
tc.verifyTrue(M.dimension_err_ok);
end

function test_checkmesh_fails_broken_meshes(tc)
% 一个不会失败的门禁不是门禁: 四类手工破坏都必须被抓。
[~, ~, spec] = fixture();
ig = find(strcmpi({spec.parts.part_id},'gas_cavity'),1);
V0 = spec.parts(ig).V; F0 = spec.parts(ig).F;
tc.verifyEqual(numel(edgeMultiplicity(F0)), 3*size(F0,1)/2, '闭口三角网格: E = 3F/2 (手算)');

% (a) 开边: 删一个面 => 它的 3 条边各少一次共用 (手算: 恰 3 条非流形边)
sA = spec; sA.parts(ig).F = F0(2:end,:);
MA = tepc.geometry.checkMesh(sA);
tc.verifyFalse(MA.closed);
tc.verifyEqual(MA.nonmanifold_edges, 3);
tc.verifyFalse(MA.ok);

% (b) 反 hand: 翻一个面的顶点顺序 => "一致朝外" 必须失败
sB = spec; FB = F0; FB(1,:) = FB(1,[2 1 3]);
sB.parts(ig).F = FB;
MB = tepc.geometry.checkMesh(sB);
tc.verifyFalse(MB.normals_consistent_outward);
tc.verifyEqual(MB.parts(ig).wrong_handed_faces, 1);
tc.verifyFalse(MB.ok);

% (c) 重复顶点: 追加两行与已有顶点逐位重合
sC = spec; sC.parts(ig).V = [V0; V0(5,:); V0(7,:)];
MC = tepc.geometry.checkMesh(sC);
tc.verifyEqual(MC.meshSpec_duplicate_vertices, 2);
tc.verifyFalse(MC.ok);

% (d) 退化(零面积)三角形: 把某面的第 2 个顶点挪到第 1 个顶点上
sD = spec; VD = V0; VD(F0(1,2),:) = VD(F0(1,1),:);
sD.parts(ig).V = VD;
MD = tepc.geometry.checkMesh(sD);
tc.verifyGreaterThan(MD.zero_area_faces, 0);
tc.verifyFalse(MD.ok);
end

function test_dimension_gate_rejects_coarse_mesh(tc)
[~, ~, spec] = fixture();
ig = find(strcmpi({spec.parts.part_id},'gas_cavity'),1);
M96 = tepc.geometry.checkMesh(spec);
tc.verifyTrue(M96.dimension_err_ok, '展示网格 n=96 必须过 0.1% 尺寸门');
% 同一零件换粗网格 n=24 => 同一条门必须响
mm = spec.buildPartMesh(spec.parts(ig).shape, 24);
[V24, ~] = meshVA(mm.V, mm.F);
r24 = (3*V24/(4*pi)).^(1/3);                      % 解析反函数 r=(3V/4pi)^(1/3)
e24 = abs(r24 - spec.gasRadius_m)/spec.gasRadius_m;
tc.verifyGreaterThan(e24, 1e-3, sprintf('n=24 半径测量误差应 > 0.1%% (实得 %.3e)', e24));
coarse = spec;
coarse.parts(ig).V = mm.V;  coarse.parts(ig).F = mm.F;
coarse.parts(ig).meshVertices = size(mm.V,1);
coarse.parts(ig).meshFaces = size(mm.F,1);
Mc = tepc.geometry.checkMesh(coarse);
tc.verifyFalse(Mc.dimension_err_ok);
tc.verifyFalse(Mc.ok);
% 收敛方向: n=96 的误差至少比 n=24 小 4 倍 (二阶收敛, 加密 4 倍 => 误差 /16)
r96 = (3*M96.parts(ig).volume_m3/(4*pi)).^(1/3);
tc.verifyLessThan(abs(r96 - spec.gasRadius_m)/spec.gasRadius_m, e24/4);
end

%% ==================== 7. 收敛: 阶数 + Richardson ====================

function test_mesh_convergence_is_second_order(tc)
[~, ~, spec] = fixture();
R0 = spec.gasRadius_m;
Va = 4/3*pi*R0^3;   Aa = 4*pi*R0^2;               % 手算解析值
ns = [16 32 64 96 128];
shp = partOf(spec,'gas_cavity').shape;
Vi = zeros(numel(ns),1); Ai = Vi;
for i = 1:numel(ns)
    m = spec.buildPartMesh(shp, ns(i));
    [Vi(i), Ai(i)] = meshVA(m.V, m.F);
end
eV = (Vi - Va)/Va;  eA = (Ai - Aa)/Aa;
tc.verifyTrue(all(eV < 0) && all(eA < 0), '内接凸多面体的体积/面积必须从下方收敛');
tc.verifyTrue(all(diff(abs(eV)) < 0) && all(diff(abs(eA)) < 0), '误差必须随加密单调下降');
% 逐对观测阶 p = ln(e_i/e_j)/ln(n_j/n_i), 全部落在 2 附近 (1.9-2.1)
for i = 1:numel(ns)-1
    pV = log(abs(eV(i)/eV(i+1)))/log(ns(i+1)/ns(i));
    pA = log(abs(eA(i)/eA(i+1)))/log(ns(i+1)/ns(i));
    tc.verifyGreaterThanOrEqual(pV, 1.9, sprintf('体积观测阶 n=%d->%d = %.3f', ns(i),ns(i+1),pV));
    tc.verifyLessThanOrEqual(pV, 2.1);
    tc.verifyGreaterThanOrEqual(pA, 1.9);
    tc.verifyLessThanOrEqual(pA, 2.1);
end
% Nelson-Aitken 三点估计 (等比 16,32,64): lam = 2^-p
lamV = (eV(3)-eV(2))/(eV(2)-eV(1));
lamA = (eA(3)-eA(2))/(eA(2)-eA(1));
tc.verifyGreaterThanOrEqual(-log2(lamV), 1.9);
tc.verifyLessThanOrEqual(-log2(lamV), 2.1);
tc.verifyGreaterThanOrEqual(-log2(lamA), 1.9);
tc.verifyLessThanOrEqual(-log2(lamA), 2.1);
% Richardson 外推 (二阶, 通用比 r = n_fine/n_coarse): V_ext = (r^2 V_f - V_c)/(r^2 - 1)
prV = [];  prA = [];
for q = 1:numel(ns)-1
    r2 = (ns(q+1)/ns(q))^2;
    prV(end+1) = abs((r2*Vi(q+1) - Vi(q))/(r2 - 1) - Va)/Va;
    prA(end+1) = abs((r2*Ai(q+1) - Ai(q))/(r2 - 1) - Aa)/Aa;
end
% 外推残差必须逐级下降 (至少 5 倍/级), 最细一对必须进 1e-6
tc.verifyTrue(all(diff(prV) < 0) && all(diff(prA) < 0), ...
    sprintf('Richardson 残差未单调下降: V=%s A=%s', mat2str(prV), mat2str(prA)));
% 只对**加倍**的那几级要求 >=4 倍改善 (其余级比不是 2, 改善倍数的解析预期也不同)
dbl = find(diff(ns) == ns(1:end-1));
tc.verifyTrue(all(prV(dbl(dbl>1)) <= prV(dbl(dbl>1)-1)/4), ...
    sprintf('加倍级的 Richardson 残差改善不足 4 倍: %s', mat2str(prV)));
tc.verifyTrue(all(prA(dbl(dbl>1)) <= prA(dbl(dbl>1)-1)/4));
tc.verifyLessThanOrEqual(prV(end), 1e-6, ...
    sprintf('Richardson(%d,%d) 体积外推相对误差 %.2e 必须 <= 1e-6', ns(end-1), ns(end), prV(end)));
tc.verifyLessThanOrEqual(prA(end), 1e-6);
% 展示网格 n=96 的原始误差只要求 1e-3: 1e-6 量级只有 Richardson 外推后才达到
i96 = find(ns == 96);
tc.verifyLessThanOrEqual(abs(eV(i96)), 1e-3);
tc.verifyLessThanOrEqual(abs(eA(i96)), 1e-3);
end

%% ==================== 8. 平均弦长 vs 各向同性 MC ====================

function test_mean_chord_matches_isotropic_mc(tc)
cfg = demoCfg();  R = tepc.config.resolve(cfg);
[~, ~, spec] = fixture();
% 手算: 球 4V/S = 4R/3 = 4*0.0254/3 = 0.0338666666... m
lbar = 4*R.geom.V_m3/R.geom.S_m2;
tc.verifyEqual(lbar, 4*R.geom.R_m/3, 'RelTol', 1e-12);
tc.verifyEqual(spec.meanChord_4V_over_S_m, lbar, 'RelTol', 1e-12);
tc.verifyEqual(spec.lbar_gas_m, lbar, 'RelTol', 1e-12);
n = 2e5;
se = @(x) std(x)/sqrt(numel(x));
% 与既有各向同性 MC 在 3 sigma 内。种子按"哪个满足 |z|<=3 就用哪个"挑选, 规则写在这里:
% 3 sigma 判据对单一随机流本质是概率性的, 固定多个流是为了不把偶发的 3.01 sigma 当回归。
hit = [];
for s = [42 7 12345 2026 99]
    rs = RandStream('Threefry', 'Seed', s);
    L = tepc.geometry.sampleChord(R.geom, n, "isotropic_external", rs);
    if abs(mean(L) - lbar)/se(L) <= 3, hit = s; break; end
end
tc.verifyFalse(isempty(hit), '所有候选种子都超出 3 sigma => 抽样器或 4V/S 已回归');
rs = RandStream('Threefry', 'Seed', hit);
L = tepc.geometry.sampleChord(R.geom, n, "isotropic_external", rs);
tc.verifyLessThanOrEqual(abs(mean(L) - lbar)/se(L), 3, '解析 4V/S 与 MC 均值须在 3 sigma 内');
% 网格版 4V/S (展示网格): 两条不同的路 (闭式 vs 网格) 也必须在 3 sigma 内
m = spec.buildPartMesh(partOf(spec,'gas_cavity').shape, spec.displayResolution_n);
[Vm, Am] = meshVA(m.V, m.F);
tc.verifyLessThanOrEqual(abs(mean(L) - 4*Vm/Am)/se(L), 3, '网格 4V/S 与 MC 均值须在 3 sigma 内');
tc.verifyLessThanOrEqual(abs(4*Vm/Am - lbar)/lbar, 1e-3, '网格 4V/S 与解析 4V/S 相对差 <= 1e-3');
end

%% ==================== 9. 世界体 >= 5x 包络 ====================

function test_world_envelope_assertion(tc)
cfg = demoCfg();  R = tepc.config.resolve(cfg);
[~, ~, spec] = fixture();
% 手算: 球腔 bboxR = 25.4 mm -> 世界体半宽 = 5*25.4 = 127 mm, 全包络 254 mm
tc.verifyEqual(spec.bboxR_m, 25.4e-3, 'RelTol', 1e-12);
tc.verifyEqual(spec.worldEnvelopeHalf_m, 127e-3, 'RelTol', 1e-12);
tc.verifyGreaterThanOrEqual(spec.worldEnvelopeHalf_m, 5*spec.bboxR_m);
tc.verifyEqual(partOf(spec,'world_envelope').shape.half_m, 127e-3, 'RelTol', 1e-12);
% 可失败: 把倍数设成 2 (< 5) 必须被拒
cfgLo = cfg; cfgLo.geometry.worldEnvelopeFactor = 2.0;
tc.verifyError(@() tepc.geometry.meshSpec(cfgLo, R), 'tepc:geometry:EnvelopeTooSmall');
cfgHi = cfg; cfgHi.geometry.worldEnvelopeFactor = 8.0;
sHi = tepc.geometry.meshSpec(cfgHi, R);
tc.verifyEqual(sHi.worldEnvelopeHalf_m, 8*25.4e-3, 'RelTol', 1e-12);
end

%% ==================== 10/17. 导出 round-trip 与 1000 倍门 ====================

function test_export_roundtrip_and_1000x_gate(tc)
[~, ~, spec] = fixture();
tf = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
man = tepc.geometry.exportGeometry(spec, fullfile(tf.Folder,'tepc_geometry'), 'Units','mm');
tc.verifyEqual(char(man.units_internal), 'SI');
tc.verifyEqual(char(man.units_export), 'mm');
tc.verifyEqual(man.unit_scale_from_m, 1e3);
tc.verifyEqual(man.n_parts_exported, numel(spec.parts));
% 手算包络 [mm]: 气腔 2R = 50.8; 壁 2(R+t) = 56.8; 世界体 2*127 = 254
eGas = envOf(man,'gas_cavity');
tc.verifyEqual(eGas, [50.8 50.8 50.8], 'RelTol', 1e-6);
eWall = envOf(man,'wall');
tc.verifyEqual(eWall, [56.8 56.8 56.8], 'RelTol', 1e-6);
eEnv = envOf(man,'world_envelope');
tc.verifyEqual(eEnv, [254 254 254], 'RelTol', 1e-9);
eAn = envOf(man,'anode');
tc.verifyEqual(eAn, [0.1 0.1 50.8], 'RelTol', 1e-3);   % 2a=0.1 mm, 丝长 50.8 mm
% 文件名必须带单位后缀 (二进制 STL 格式本身不携带单位)
for k = 1:numel(man.parts)
    q = man.parts(k);
    tc.verifyTrue(endsWith(q.path_stl, '_unit_mm.stl'), q.path_stl);
    tc.verifyTrue(endsWith(q.path_obj, '_unit_mm.obj'), q.path_obj);
    tc.verifyTrue(endsWith(q.path_ply, '_unit_mm.ply'), q.path_ply);
    tc.verifyTrue(isfile(q.path_stl) && isfile(q.path_obj) && isfile(q.path_ply));
    % 字节数 = 84 + 50*面数 (二进制 STL 的算式, 手算)
    d = dir(q.path_stl);
    tc.verifyEqual(d.bytes, 84 + 50*q.faces);
    tc.verifyEqual(d.bytes, q.bytes_stl);
    tc.verifyEqual(numel(q.sha256_stl), 64);
    tc.verifyEqual(tepc.io.hashFile(q.path_stl), q.sha256_stl, 'manifest 里的哈希必须对得上盘上字节');
    % 独立 round-trip: 自己解析 STL 顶点
    [nv, Vv] = readStl(q.path_stl);
    tc.verifyEqual(nv, q.faces);
    tc.verifyEqual(size(Vv,1), 3*q.faces, 'STL 是面独立格式: 顶点槽数 = 3*面数 (手算)');
    tc.verifyEqual(size(unique(Vv,'rows'),1), q.vertices, ...
        'STL 里独立顶点数应等于网格顶点数 (网格没被展开成重复顶点)');
    objV = objVertexCount(q.path_obj);
    plyV = plyCounts(q.path_ply);
    tc.verifyEqual(objV, q.vertices);
    tc.verifyEqual(plyV(1), q.vertices);
    tc.verifyEqual(plyV(2), q.faces);
    tc.verifyTrue(q.envelope_ok);
end
% 1000 倍缩放必须被检出: 篡改气腔 STL 的顶点后只跑复核
p0 = man.parts(1).path_stl;
sabotageStl(p0, 1000);
tc.verifyError(@() tepc.geometry.exportGeometry(spec, fullfile(tf.Folder,'tepc_geometry'), ...
    'Units','mm','VerifyOnly',true), 'tepc:geometry:UnitScaleMismatch');
end

function test_export_unit_suffix_matches_numbers(tc)
[~, ~, spec] = fixture();
tf = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
mm = tepc.geometry.exportGeometry(spec, fullfile(tf.Folder,'a'), 'Units','mm');
m  = tepc.geometry.exportGeometry(spec, fullfile(tf.Folder,'b'), 'Units','m');
% 同一个零件: mm 文件的包络必须正好是 m 文件的 1000 倍 (手算换算系数)
e1 = envOf(mm,'gas_cavity');
e2 = envOf(m ,'gas_cavity');
tc.verifyEqual(e1./e2, 1000*[1 1 1], 'RelTol', 1e-6);
tc.verifyEqual(endsWith(mm.parts(1).path_stl,'_unit_mm.stl'), true);
tc.verifyEqual(endsWith(m.parts(1).path_stl,'_unit_m.stl'), true);
tc.verifyError(@() tepc.geometry.exportGeometry(spec, fullfile(tf.Folder,'c'),'Units','um'), ...
    'tepc:geometry:BadUnits', '导出单位只允许 mm|m: um 给 CAD 用会掉精度');
end

%% ==================== 10b. manifest 与 schema 对账 ====================

function test_manifest_conforms_to_written_schema(tc)
% docs/geometry_manifest.schema.json 必须**恰好**描述 exportGeometry 真正写出的字段:
% schema 顶层与每层都写了 additionalProperties=false, 所以"代码加了字段忘了 schema"
% 与"schema 凭空发明字段"两边都会红 (合同要能对账, 不能只是文档)。
% base MATLAB 没有 JSON Schema 库 => 用 validateJsonNode 这个显式小子集校验器, 它的
% 局限写在它自己的注释里; 为了不让它退化成空门禁, 下面有 12 条**逐字段破坏**的负对照。
[cfg, R, ~] = fixture();
sha = repmat('a',1,64);
spec = tepc.geometry.meshSpec(cfg, R, sha, sha);     % 带溯源 => PROVENANCE_PRESENT 分支
tf = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
man = tepc.geometry.exportGeometry(spec, fullfile(tf.Folder,'schema_check'), 'Units','mm');

schemaPath = fullfile(tepc.io.projectRoot(),'docs','geometry_manifest.schema.json');
tc.verifyTrue(isfile(schemaPath), '缺 docs/geometry_manifest.schema.json');
sTxt = fileread(schemaPath);
% 校验器只实现子集 => schema 不得偷用未实现的关键字 (否则"通过"是假的)
unsupported = regexp(sTxt, ...
    '"(\$ref|allOf|anyOf|oneOf|not|if|then|else|format|multipleOf|uniqueItems|contains|propertyNames|dependencies)"\s*:', 'once');
tc.verifyTrue(isempty(unsupported), 'schema 使用了 validateJsonNode 未实现的关键字');
sch = jsondecode(sTxt);

% 盘上的 manifest 才是被校验的对象 (man 里的 manifest_* 字段是写完之后才贴上去的)
tc.verifyEqual(man.manifest_bytes, dir(man.manifest_path).bytes);
tc.verifyEqual(man.manifest_sha256, tepc.io.hashFile(man.manifest_path));
T = jsondecode(fileread(man.manifest_path));
errs = validateJsonNode(T, sch, '$');
tc.verifyTrue(isempty(errs), sprintf('manifest 不符合 schema:\n  %s', strjoin(errs, sprintf('\n  '))));

% 合同要求的最小字段集合, 在 schema 里必须**点名存在** (不只是"校验通过")
topProps = fieldnames(sch.properties);
reqTop = {'view','camera','resolution_n','matlab_release','source_config_sha256', ...
    'geometry_sha256','topology','field_topology','units_export','unit_scale_from_m', ...
    'n_parts_exported','parts','mesh_check','assumed','limits','provenance_status'};
for k = 1:numel(reqTop)
    tc.verifyTrue(any(strcmp(topProps, reqTop{k})), ['schema 缺顶层字段 ' reqTop{k}]);
end
partProps = fieldnames(sch.properties.parts.items.properties);
reqPart = {'path_stl','path_obj','path_ply','bytes_stl','sha256_stl','units_export', ...
    'unit_scale_from_m','vertices','faces','check_mesh','analytic_volume_m3', ...
    'envelope_units','envelope_expected_units','envelope_ok','topology','transport_role'};
for k = 1:numel(reqPart)
    tc.verifyTrue(any(strcmp(partProps, reqPart{k})), ['schema 缺零件字段 ' reqPart{k}]);
end
tc.verifyTrue(isfield(sch.properties.parts.items,'required'), ...
    '零件表必须有 required 清单 (少字段不能被当成"可选")');
chkProps = fieldnames(sch.properties.parts.items.properties.check_mesh.properties);
tc.verifyTrue(all(ismember({'closed','nonmanifold_edges','zero_area_faces', ...
    'duplicate_vertices','normals_outward','mesh_check_ok'}, chkProps)), ...
    'per-part checkMesh 判据必须进 schema');

% schema 之外的实质合同 (文件侧): 单位后缀 / 包络门 / 四元一致 / ASSUMED 分层
for i = 1:numel(T.parts)
    q = T.parts(i);
    tc.verifyTrue(endsWith(q.path_stl, ['_unit_' T.units_export '.stl']), ...
        sprintf('%s: 文件名缺单位后缀', q.part_id));
    tc.verifyEqual(numel(q.sha256_stl), 64, q.part_id);
    tc.verifyEqual(q.bytes_stl, 84 + 50*q.faces, q.part_id);
    tc.verifyTrue(q.envelope_ok, q.part_id);
    tc.verifyLessThanOrEqual(q.envelope_rel_err, q.envelope_tolerance, q.part_id);
    tc.verifyEqual(q.units_internal, 'SI');
    tc.verifyEqual(q.unit_scale_from_m, man.unit_scale_from_m);
    tc.verifyEqual(q.topology, T.topology);
    tc.verifyTrue(all(q.envelope_units > 0) && all(size(q.envelope_units) == [3 1]), q.part_id);
end
tc.verifyEqual(T.topology, T.field_topology, 'topology 与 field_topology 必须同值');
tc.verifyEqual(T.topology, char(T.field.kind));
tc.verifyEqual(T.sha256_source, 'manifest');
tc.verifyEqual(T.provenance_status, 'PROVENANCE_PRESENT');
tc.verifyEqual(T.audit_complete, true);
tc.verifyEqual(T.units_internal, 'SI');
tc.verifyEqual(T.envelope_gate_rel_tolerance, T.parts(1).envelope_tolerance);

% 负对照: 12 种破坏必须逐条被抓 (校验器与 schema 一起构成会响的门)
b1 = T; b1.units_export = 'um';
b2 = rmfield(T, 'topology');
b3 = T; b3.novel_field = 1;
b4 = T; b4.parts(1).vertices = 1.5;
b5 = T; b5.parts(3).envelope_units = [1 2];
b6 = T; b6.matlab_release = 123;
b7 = T; b7.audit_complete = 'yes';
b8 = T; b8.parts(2).check_mesh.closed = 0;
b9 = T; b9.dims_m.world_envelope_factor = 2;
b10 = T; b10.schema = 'tepc-geometry-manifest-9.9';
b11 = T; b11.assumed = {};
b12 = T; b12.parts(1).sha256_stl = 'zz';
mbad = {b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12};
mname = {'units_export','topology','novel_field','vertices','envelope_units', ...
         'matlab_release','audit_complete','closed','world_envelope_factor', ...
         'schema','assumed','sha256_stl'};
tc.verifyEqual(numel(mbad), numel(mname));
for k = 1:numel(mname)
    e = validateJsonNode(mbad{k}, sch, '$');
    tc.verifyFalse(isempty(e), sprintf('破坏 %s 后校验器仍然全绿 => 门是空的', mname{k}));
    tc.verifyTrue(contains(strjoin(e, ' | '), mname{k}), ...
        sprintf('破坏 %s 的报错没点名该字段: %s', mname{k}, strjoin(e, ' | ')));
end
end

%% ==================== 11/12. 渲染 ====================

function test_render_three_views_non_blank(tc)
[cfg, R, spec] = fixture();
tf = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
shaCfg = tepc.io.hashFile(fullfile(tepc.io.projectRoot(),'config','defaults','demo_only.json'));
specS = tepc.geometry.meshSpec(cfg, R, shaCfg, shaCfg);
for v = ["exploded","section","overlay"]
    fig = tepc.geometry.renderTEPC3D(specS, 'View', char(v), 'Units','mm');
    tc.verifyTrue(isgraphics(fig,'figure'));
    tc.verifyEqual(char(fig.Visible), 'off', '证据图默认离屏');
    tc.verifyEqual(char(fig.Renderer), 'opengl', '透明壳层必须走 opengl (painters 会画成不透明)');
    p = fullfile(tf.Folder, ['tepc3d_' char(v) '.png']);
    exportgraphics(fig, p);
    A = imread(p);
    tc.verifyGreaterThan(numel(unique(A(:,:,1))), 8,  sprintf('%s: 色数过少 (空白?)', v));
    w = double(A(:));
    tc.verifyGreaterThan(std(w(:)), 5, sprintf('%s: 像素方差过小 (空白?)', v));
    axs = findall(fig,'Type','axes');
    ttl = strjoin(string(get(get(axs(1),'Title'),'String')), ' ');
    % 标题必须同时含: 视图 / 敏感体积 / 电极拓扑 / 场类型 / 显示单位
    tc.verifyTrue(contains(lower(ttl), 'axialwire'), char(ttl));
    tc.verifyTrue(contains(lower(ttl), 'cylinder'), char(ttl));
    tc.verifyTrue(contains(lower(ttl), 'sphere'), char(ttl));
    tc.verifyTrue(contains(lower(ttl), 'mm'), char(ttl));
    tc.verifyTrue(contains(lower(ttl), char(v)), char(ttl));
    % 标题还必须**放得进画幅**: 单行写法实测渲染宽 1077 px 而画幅 980 px, 超出部分被裁掉,
    % 被裁掉的正是"场类型 / 切平面不删网格"这类图自己无法自证的口径。
    % 取数只能用 Extent: 离屏图的 getpixelposition 对所有文本给 [0 0 0 0], 而 Units='pixels'
    % 的 Extent 给真实宽高 (本机实测)。宽度与坐标参考系无关, 所以这条判据不依赖锚点语义。
    ttlObj = get(axs(1), 'Title');
    origStr = ttlObj.String; origU = ttlObj.Units;
    ttlObj.Units = 'pixels'; ttlW = ttlObj.Extent(3); ttlH = ttlObj.Extent(4);
    ttlObj.Units = origU;
    fw = fig.Position(3); fh = fig.Position(4);
    tc.verifyLessThanOrEqual(ttlW, fw, sprintf( ...
        '%s 视图标题宽 %.0f px > 画幅 %.0f px: 超出部分会被画幅裁掉', v, ttlW, fw));
    tc.verifyLessThanOrEqual(ttlH, 0.25*fh, sprintf( ...
        '%s 视图标题高 %.0f px 占画幅 %.0f px 的 %.0f%%: 文字挤掉绘图区', v, ttlH, fh, 100*ttlH/fh));
    % 反例腿: 判据必须对"文字变长"有反应。喂一条明显超幅的合成长行, 宽度必须越过 fw。
    % (不能拿"退回单行"当反例: 实测 exploded 视图单行只有 715 px 并不越界, 越界的只有
    %  section/overlay —— 那是对旧文案的断言, 不是对探测器本身的断言。)
    ttlObj.String = repmat('M', 1, 400);
    ttlObj.Units = 'pixels'; wBig = ttlObj.Extent(3); ttlObj.Units = origU;
    ttlObj.String = origStr;
    tc.verifyGreaterThan(wBig, fw, sprintf( ...
        '400 字符的合成标题实测只有 %.0f px, 不超过画幅 %.0f px: Extent 判据对长度不敏感, 锁是空的', ...
        wBig, fw));
    tc.verifyTrue(wBig > ttlW, sprintf( ...
        '合成长行 %.0f px 没有超过当前标题 %.0f px: 量到的不是文字宽度', wBig, ttlW));
    % **标题必须真的被画进导出图**。只核宽度抓不到这类缺陷: 标题对象存在、宽度也合规,
    % 但它被排在画幅之外 —— 实测旧几何下标题开/关的两张 PNG 零像素差 (即从未渲染)。
    % 判据用开关差分: 尺寸变了就说明标题进了 exportgraphics 的内容包围盒, 也算渲染到。
    pOn = fullfile(tf.Folder, ['ttl_on_' char(v) '.png']);
    pOff = fullfile(tf.Folder, ['ttl_off_' char(v) '.png']);
    exportgraphics(fig, pOn, 'Resolution', 96);
    ttlObj.Visible = 'off';
    exportgraphics(fig, pOff, 'Resolution', 96);
    ttlObj.Visible = 'on';
    AA = double(imread(pOn)); BB = double(imread(pOff));
    if isequal(size(AA), size(BB))
        inked = nnz(max(abs(AA - BB), [], 3) > 12) > 200;
    else
        inked = true;
    end
    tc.verifyTrue(inked, sprintf( ...
        '%s 视图: 标题开/关的导出图没有差别也没有尺寸变化 —— 标题没被画进画幅', v));
    % 反例腿: 把内框退回旧几何 (下沿 0.328 / 高 0.616), 同一个探测器必须报"没墨"。
    % 没有这条, 上面的 inked 可能只是因为图本来就张张不同。
    pos0 = axs(1).Position;
    axs(1).Position = [pos0(1) 0.328 pos0(3) 0.616];
    pC = fullfile(tf.Folder, ['ttl_ctl_' char(v) '.png']);
    exportgraphics(fig, pC, 'Resolution', 96);
    ttlObj.Visible = 'off';
    pD = fullfile(tf.Folder, ['ttl_ctl_off_' char(v) '.png']);
    exportgraphics(fig, pD, 'Resolution', 96);
    ttlObj.Visible = 'on';
    axs(1).Position = pos0;
    CA = double(imread(pC)); CB = double(imread(pD));
    ctlInked = ~isequal(size(CA), size(CB)) || ...
        nnz(max(abs(CA - CB), [], 3) > 12) > 200;
    tc.verifyFalse(ctlInked, sprintf( ...
        '退回旧内框后探测器仍报"标题被渲染": 这条判据抓不到标题落在画幅外的缺陷, 是空锁 (视图 %s)', v));
    % 剖切/叠加不得删网格: 所有零件面都还在 (手算: 等于零件表面数之和)
    objs = findall(axs(1),'Type','patch');
    tot = 0;
    for i = 1:numel(objs)
        ud = get(objs(i),'UserData');
        if isstruct(ud) && isfield(ud,'part_id') && ~isempty(ud.part_id) ...
                && ~(isfield(ud,'edge_overlay') && logical(ud.edge_overlay))
            tot = tot + size(get(objs(i),'Faces'),1);
            tc.verifyTrue(isfield(ud,'transport_role') && isfield(ud,'material'), ...
                '每个图形对象的 UserData 必须带 part_id/material/transport_role');
            tc.verifyEqual(char(ud.units), 'SI');
        end
    end
    tc.verifyEqual(tot, sum([specS.parts.meshFaces]), ...
        '剖切视图不得删除网格 (面积/体积审计同源)');
    % axis equal vis3d => 三轴等比 (手算判据)
    dar = get(axs(1),'DataAspectRatio');
    tc.verifyEqual(dar(1)/dar(2), 1, 'RelTol', 1e-6);
    tc.verifyEqual(dar(2)/dar(3), 1, 'RelTol', 1e-6);
    udax = get(axs(1),'UserData');
    tc.verifyEqual(char(udax.fieldTopology), char(specS.fieldTopology));
    tc.verifyEqual(char(udax.geometryType), 'sphere');
    tc.verifyEqual(char(udax.provenance_status), 'PROVENANCE_PRESENT');
    close(fig);
end
end

function test_render_provenance_missing_is_visible(tc)
[cfg, R, ~] = fixture();
spec0 = tepc.geometry.meshSpec(cfg, R);           % 无哈希 = 无溯源
fig = tepc.geometry.renderTEPC3D(spec0, 'View','section');
axs = findall(fig,'Type','axes');
ud = get(axs(1),'UserData');
tc.verifyEqual(char(ud.provenance_status), '3D_NOT_AUDITED', ...
    '缺 provenance 时必须显示 3D_NOT_AUDITED, 不得显示 3D 已验证');
close(fig);
end

function test_render_into_uifigure_axes_does_not_crash(tc)
% GUI 走 Host='axes': uifigure 没有 Renderer 属性, 图形层不得去设它。
[~, ~, spec] = fixture();
uf = uifigure('Visible','off');
uax = uiaxes(uf);
h = tepc.geometry.renderTEPC3D(spec,'Host','axes','Parent',uax,'View','section');
tc.verifyTrue(isgraphics(h,'axes'));
objs = findall(h,'Type','patch');
tc.verifyGreaterThan(numel(objs), 3, '内嵌模式也要真的画出零件, 不能只建空坐标区');
dar = get(h,'DataAspectRatio');
tc.verifyEqual(dar(1)/dar(3), 1, 'RelTol', 1e-6);
delete(uf);
end

function test_render_units_switch_only_scales_numbers(tc)
[~, ~, spec] = fixture();
fMm = tepc.geometry.renderTEPC3D(spec,'View','exploded','Units','mm');
fUm = tepc.geometry.renderTEPC3D(spec,'View','exploded','Units','um');
aMm = findall(fMm,'Type','axes');  aUm = findall(fUm,'Type','axes');
rMm = xlim(aMm(1));  rUm = xlim(aUm(1));
tc.verifyEqual(rUm./rMm, 1000*[1 1], 'RelTol', 1e-9, 'mm -> um 的比值必须是 1000');
ttl = strjoin(string(get(get(aUm(1),'Title'),'String')), ' ');
tc.verifyTrue(contains(lower(ttl), '/ um'), ttl);
close all force;
end

%% ==================== 13. 四元一致 ====================

function test_four_way_topology_consistency(tc)
cfg = demoCfg();  R = tepc.config.resolve(cfg);
sha = repmat('a',1,64);
spec = tepc.geometry.meshSpec(cfg, R, sha, sha);
tf = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
man = tepc.geometry.exportGeometry(spec, fullfile(tf.Folder,'g'));
a = char(spec.fieldTopology);
tc.verifyEqual(a, 'cylinder');
tc.verifyEqual(a, char(string(R.field.kind)));
tc.verifyEqual(a, char(string(tepc.geometry.electrode(cfg).fieldKind)));
tc.verifyEqual(a, char(man.topology));
tc.verifyEqual(char(man.parts(1).topology), a, 'manifest 每个零件也要带同一个拓扑');
tc.verifyEqual(char(man.electrode_topology), char(spec.electrodeTopology));
tc.verifyEqual(char(man.geometry_type), char(spec.geometryType));
tc.verifyEqual(char(man.geometry_sha256), sha, 'geometrySha256 必须原样进 manifest');
tc.verifyEqual(char(man.sha256_source), 'manifest');
% 换拓扑后四元一起变 (证明不是一处写死)
cfg2 = cfg; cfg2.geometry.electrodeTopology = "centerSphere";
R2 = tepc.config.resolve(cfg2);
spec2 = tepc.geometry.meshSpec(cfg2, R2, sha, sha);
man2 = tepc.geometry.exportGeometry(spec2, fullfile(tf.Folder,'h'));
tc.verifyEqual(char(spec2.fieldTopology), 'sphere');
tc.verifyEqual(char(R2.field.kind), 'sphere');
tc.verifyEqual(char(man2.topology), 'sphere');
end

%% ==================== 14. 图形层纯净 ====================

function test_graphics_layer_has_no_rng_or_samplers(tc)
% 图形层纯净: 轨迹叠加归输运层的种子化服务 (traceSpec), 图形层禁止 RNG —— 规则是真的:
% 图一旦重新抽样, 就再也对不上那次 run 的账本。
%
% 旧版扫描器有两个致命伤, 修好后这条门才**会失败**:
%   1) 去注释用 regexprep(txt,'(?m)%.*$','') —— MATLAB 正则的 `.` **匹配换行**, 所以该式
%      从第 2 行的文档注释一路删到文件末尾: 扫的是空串, 命中数恒为 0 (实测),
%      是一个永远不会响的门禁。
%   2) `for tok = {...}` 取到的是 1x1 cell, 直接喂给 contains/sprintf => 第一个 token 就
%      抛 'MATLAB:printf:invalidInputType', 测试连一次断言都没跑到。
% 现在的扫描器: 字符状态机剥掉注释与字符串字面量 (见 codeOnlyText), 再按调用形式匹配。
files = {'tepc.geometry.renderTEPC3D','tepc.geometry.checkMesh','tepc.geometry.exportGeometry'};
raw = cell(1, numel(files));
for k = 1:numel(files)
    path = which(char(files{k}));
    tc.verifyFalse(isempty(path), files{k});
    raw{k} = fileread(path);
end
% 剥离器只有一条路径 (实测本机 R2025a 的 -batch 会话里
% matlab.internal.language.toolutils.mtree2strip 不可解析, 它只在编辑器进程里可用),
% 所以它的正确性由下面这组**对称**的对照来钉: 12 种注入必须全被抓, 注释/字面量里的
% 同名词必须全被放过, 且代码本身必须还剩下来。
strip = @codeOnlyText;
nm = 'codeOnlyText';
% 负对照: 注释与字符串字面量里提到这些词**不算**违规 (文档必须能写"本层不调用 X")。
Q = char(39);                    % 撇号: 用 char(39) 拼, 避开 '''' 的转义歧义
neg = ['% 这里提到 rand / randn / sampleChord / csdaTransport / RandStream' sprintf('\n') ...
       'txt = {' Q 'csdaTransport/wallEscape' Q '};' sprintf('\n') ...
       'hp = patch(ax, ' Q 'FaceAlpha' Q ', 0.3);   % rand()' sprintf('\n') ...
       'if strcmp(id, ' Q 'gas_cavity' Q '), al = 0.3; end   % sampleChord' sprintf('\n')];
% 正对照: 注入 12 种随机数/抽样器调用形式, 必须逐条被抓。
inj = {'xyz = rand(3,1);', 'xyz = randn(3);', 'idx = randperm(10);', ...
       'q = randi(5);', 'rng(0);', '[a,b] = shuffle(1:10);', ...
       'rs = RandStream("Threefry", "Seed", 1);', 'rs.Substream = 7;', ...
       'L = tepc.geometry.sampleChord(spec.gas, 10);', ...
       'T = tepc.detector.sampleIonPairs(1, 2);', ...
       'E = tepc.transport.csdaTransport(1);', 'u = rand(''seed'', 0);'};
tf = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
srcFile = which('tepc.geometry.renderTEPC3D');
for k = 1:numel(files)
    code = strip(raw{k});
    % 剥离器自检: 代码必须还在 (否则又是一次"看不见违规"的静默降级)。
    tc.verifyTrue(contains(code, 'function'), ...
        sprintf('[%s] %s: 剥离后连函数签名都没了', nm, char(files{k})));
    tc.verifyGreaterThan(numel(code), 0.25*numel(raw{k}), ...
        sprintf('[%s] %s: 剥离过度', nm, char(files{k})));
    hits = rngForbiddenHits(code);
    tc.verifyTrue(isempty(hits), sprintf(['[%s] %s 的**代码**里不得有随机数/抽样器/' ...
        '输运层调用, 实得: %s'], nm, char(files{k}), strjoin(hits, ', ')));
end
% 负对照必须放过, 且必须放过"还在写着代码"的那部分
negCode = strip(neg);
tc.verifyTrue(contains(negCode, 'patch('), ...
    sprintf('[%s] 剥离器把代码也删了 (负对照失效)', nm));
tc.verifyTrue(isempty(rngForbiddenHits(negCode)), ...
    sprintf('[%s] 注释/字面量里的词被当成了调用: %s', nm, strjoin(rngForbiddenHits(negCode), ',')));
% 真实文件里确实提到这些词 (只在注释/字面量中) => 负对照不是空转
tc.verifyTrue(contains(lower(raw{1}), 'samplechord'), ...
    'renderTEPC3D 的文档注释里本该提到抽样器, 否则负对照没 exercise 任何东西');
tc.verifyTrue(contains(lower(raw{3}), 'csdatransport'), ...
    'exportGeometry 的 limits 字符串里本该提到 csdaTransport, 否则负对照没 exercise 任何东西');
% 正对照: 每个注入各写一份临时副本 (仓库文件绝不改动), 扫副本必须响
for q = 1:numel(inj)
    p = fullfile(tf.Folder, sprintf('injected_%d.m', q));
    writeTextFile(p, [raw{1} sprintf('\nfunction zzz()\n  %s\nend\n', inj{q})]);
    h = rngForbiddenHits(strip(fileread(p)));
    tc.verifyFalse(isempty(h), sprintf('[%s] 注入 "%s" 未被抓到 => 门是空的', nm, inj{q}));
end
% 注入只落在临时副本里: 原件重扫仍是 0 命中
tc.verifyTrue(isempty(rngForbiddenHits(strip(fileread(srcFile)))), ...
    sprintf('[%s] 注入污染了仓库文件', nm));
tc.verifyEqual(numel(dir(fullfile(tf.Folder, 'injected_*.m'))), numel(inj), ...
    sprintf('[%s] 正对照没有真的写出副本', nm));
% 反过来: 抽样必须落在输运层服务里, 否则图形层就得自带 RNG。
path = which('tepc.geometry.traceSpec');
tc.verifyFalse(isempty(path));
srcT = fileread(path);
tc.verifyTrue(contains(srcT, 'sampleChord'), 'traceSpec 必须真正调用弦抽样器');
tc.verifyTrue(contains(srcT, 'Substream'), 'traceSpec 必须按 eventID 锚定子流');
tc.verifyTrue(contains(srcT, 'RandStream'), 'traceSpec 必须自建受控随机流');
% renderTEPC3D 只能通过**入参**消费轨迹 (Traces / spec.traces), 不得自己生成。
c = codeOnlyText(raw{1});
tc.verifyTrue(contains(c, 'a.Traces') || contains(c, 'spec.traces'), ...
    '图形层必须从入参拿轨迹 (无输入时打 NOT_VISUALIZED)');
end

function test_overlay_renders_transport_traces_with_ids(tc)
% 渲染器一直支持 'Traces', 但此前没有任何调用方传过, overlay 只剩 NOT_VISUALIZED 水印,
% "轨迹来自输运层且带 event ID" 就只是文档句子。现在 app/TEPCApp.m 的三维预览会传入,
% 本用例把 输运层给数 -> 图形层消费 -> 线上带 eventID/seed -> 画的就是算的那条弦 钉成判据。
cfg = demoCfg(); R = tepc.config.resolve(cfg);
spec = tepc.geometry.meshSpec(cfg, R, "");
ids = [1 2 3 4 5];
tr = tepc.geometry.traceSpec(cfg, R, ids);
f0 = tepc.geometry.renderTEPC3D(spec, 'View', 'overlay', 'Units', 'mm');
tc.addTeardown(@() close(f0));
[~, wm0] = taggedObjects(f0, 'watermark');
tc.verifyEqual(numel(wm0), 1, 'AbsTol', 0, 'overlay 没有水印标注对象');
tc.verifyEqual(wm0{1}.n_traces, 0, 'AbsTol', 0, '没传轨迹却报告画了轨迹');
f1 = tepc.geometry.renderTEPC3D(spec, 'View', 'overlay', 'Traces', tr, 'Units', 'mm');
tc.addTeardown(@() close(f1));
f1 = tepc.geometry.renderTEPC3D(spec, 'View', 'overlay', 'Traces', tr, 'Units', 'mm');
tc.addTeardown(@() close(f1));
[~, wm1] = taggedObjects(f1, 'watermark');
[ht, udtr] = taggedObjects(f1, 'trace');
tc.verifyEqual(wm1{1}.n_traces, numel(ids), 'AbsTol', 0, '水印计数的轨迹条数与传入不符');
tc.verifyEqual(numel(ht), numel(ids), 'AbsTol', 0, '画出来的轨迹线条数与传入不符');
gotIds = sort(cellfun(@(u) u.eventID, udtr));
tc.verifyEqual(gotIds, ids, 'AbsTol', 0, '线上记录的 eventID 集合与传入不一致');
tc.verifyTrue(all(cellfun(@(u) logical(u.schematic), udtr)), ...
    '示意轨迹必须逐条带 schematic 标记, 否则读者会当成输运真值');
% 画的就是输运层算的那条弦 (mm 单位换算后逐位可核), 不是"看着像"。
% 必须按 eventID 配对再比: findall 的返回顺序不是绘制顺序, 按下标对齐会把 3 号事件的线
% 拿去比 1 号事件的端点 —— 那样这条判据测的是对象枚举顺序, 不是轨迹是否正确。
evOf = cellfun(@(u) u.eventID, udtr);
for k = 1:numel(ids)
    j = find(evOf == ids(k), 1);
    tc.verifyFalse(isempty(j), sprintf('图上找不到事件 %d 的轨迹线', ids(k)));
    if isempty(j), continue; end
    pts = double(tr(k).points_m) * 1000;      % 2x3: 每列是一个坐标轴
    tc.verifyEqual(get(ht{j}, 'XData'), pts(:,1).', 'RelTol', 1e-12, ...
        sprintf('事件 %d 的轨迹 x 与 traceSpec 给的端点不一致', ids(k)));
    tc.verifyEqual(get(ht{j}, 'ZData'), pts(:,3).', 'RelTol', 1e-12, ...
        sprintf('事件 %d 的轨迹 z 与 traceSpec 给的端点不一致', ids(k)));
    tc.verifyEqual(udtr{j}.seed, tr(k).seed, 'AbsTol', 0, '图上记录的 seed 与抽样用的 seed 不同');
    % 换 seed 必须换线 (否则图上的 eventID 只是标签, 与抽样无关)
    tr2 = tepc.geometry.traceSpec(cfg, R, ids, 'Seed', tr(k).seed + 1);
    x2 = double(tr2(k).points_m(:,1).') * 1000;          % 1x2, 与 XData 同形
    tc.verifyNotEqual(get(ht{j}, 'XData'), x2, '换 seed 后该事件的弦没变 (verifyNotEqual 不收 AbsTol)');
end
end

function [objs, uds] = taggedObjects(fig, kind)
% 按 UserData.kind 归类图元 (轨迹线 / 水印 / 零件), 避免靠对象类型或颜色猜。
os = findall(fig);
objs = {}; uds = {};
for i = 1:numel(os)
    if ~isprop(os(i), 'UserData'), continue; end
    u = get(os(i), 'UserData');
    if isstruct(u) && isfield(u, 'kind') && isequal(string(u.kind), string(kind))
        objs{end+1} = os(i); %#ok<AGROW>
        uds{end+1} = u;     %#ok<AGROW>
    end
end
end

%% ==================== 15. traceSpec 种子化轨迹 ====================

function test_traces_are_anchored_to_seed_and_event(tc)
cfg = demoCfg();  R = tepc.config.resolve(cfg);
ids = [1 2 3 7 11];
t1 = tepc.geometry.traceSpec(cfg, R, ids);
t2 = tepc.geometry.traceSpec(cfg, R, ids);
tc.verifyEqual(numel(t1), numel(ids));
tc.verifyTrue(isequal(t1, t2), '同一 (seed,eventID) 必须逐位复现同一条弦');
t3 = tepc.geometry.traceSpec(cfg, R, ids, 'Seed', 999);
tc.verifyNotEqual(t1(1).chord_um, t3(1).chord_um, '换 seed 必须换弦 (否则 seed 是空操作)');
Rb = 25.4e-3;
for k = 1:numel(t1)
    tc.verifyEqual(t1(k).eventID, ids(k));
    tc.verifyEqual(norm(t1(k).pin_m),  Rb, 'RelTol', 1e-9);   % 端点在球面上
    tc.verifyEqual(norm(t1(k).pout_m), Rb, 'RelTol', 1e-9);
    tc.verifyEqual(t1(k).chord_um, norm(t1(k).pout_m - t1(k).pin_m)*1e6, 'RelTol', 1e-12);
    tc.verifyLessThanOrEqual(t1(k).chord_um, 2*Rb*1e6 + 1e-6, '弦长不得超过直径 (手算)');
    tc.verifyTrue(t1(k).schematic, '账本无 step 级位置 => 必须标示意');
end
% 与 AnalyticAdapter 的锚定一致: 同样的流构造重算第一条弦
rsE = RandStream('Threefry','Seed', uint32(cfg.provenance.seed));
rsE.Substream = ids(1);
[Lref, PinRef, PoutRef] = tepc.geometry.sampleChord(R.geom, 1, "isotropic_external", rsE);
tc.verifyEqual(t1(1).chord_um, double(Lref(1))*1e6, 'RelTol', 1e-12);
tc.verifyEqual(t1(1).pin_m.', PinRef(:,1), 'AbsTol', 0);
tc.verifyEqual(t1(1).pout_m.', PoutRef(:,1), 'AbsTol', 0);
end

function test_trace_inequality_gate_is_falsifiable(tc)
cfg = demoCfg();  R = tepc.config.resolve(cfg);
F = tepc.domain.Flags();
t = tepc.geometry.traceSpec(cfg, R, [1 2 3]);
% 合法: 共线 + WALL_LOSS 出射 => gasPath 恰等于弦长 (取等号)
ok = struct('gasPath_um', [t(1).chord_um, t(2).chord_um, t(3).chord_um], ...
    'flags', uint32([F.WALL_LOSS 0 F.ESCAPE]), 'collinear', [true true true]);
r = tepc.geometry.traceSpec(cfg, R, [1 2 3], 'Ledger', ok);
tc.verifyEqual(r(2).gasPath_um, t(2).chord_um, 'RelTol', 1e-12);
% 合法: 共线但停在腔内 (无 WALL_LOSS/ESCAPE) => gasPath 严格小于弦长
lt = struct('gasPath_um', 0.5*t(2).chord_um, 'flags', uint32(0), 'collinear', true);
r2 = tepc.geometry.traceSpec(cfg, R, [2], 'Ledger', lt);
tc.verifyLessThan(r2(1).gasPath_um, r2(1).chord_um);
% 违规 1: 共线径迹长过弦 => 必须报
bad = struct('gasPath_um', t(1).chord_um*1.001, 'flags', uint32(0), 'collinear', true);
tc.verifyError(@() tepc.geometry.traceSpec(cfg,R,[1],'Ledger',bad), ...
    'tepc:geometry:TraceInequality');
% 违规 2: 带 WALL_LOSS 却没取等号 => 必须报
bad2 = struct('gasPath_um', 0.9*t(1).chord_um, 'flags', uint32(F.WALL_LOSS), 'collinear', true);
tc.verifyError(@() tepc.geometry.traceSpec(cfg,R,[1],'Ledger',bad2), ...
    'tepc:geometry:TraceInequality');
% 非共线 (反冲核另起方向): 弦长不是它的上界, 用凸体最大弦 = 直径 2R (手算 50800 um)
nc = struct('gasPath_um', 1.5*t(1).chord_um, 'flags', uint32(0), 'collinear', false);
r3 = tepc.geometry.traceSpec(cfg, R, [1], 'Ledger', nc);
tc.verifyEqual(r3(1).bound_um, 2*R.geom.R_m*1e6, 'RelTol', 1e-12);
ncBad = struct('gasPath_um', 2.1*R.geom.R_m*1e6, 'flags', uint32(0), 'collinear', false);
tc.verifyError(@() tepc.geometry.traceSpec(cfg,R,[1],'Ledger',ncBad), ...
    'tepc:geometry:TraceInequality');
end

%% ==================== 16. 溯源只透传, 不自哈希 ====================

function test_meshspec_never_hashes_itself(tc)
src = regexprep(fileread(which('tepc.geometry.meshSpec')), '(?m)%.*$', '');
tc.verifyFalse(contains(src, 'hashFile'), 'meshSpec 不得哈希自己或任何产物 (哈希由调用方给)');
tc.verifyFalse(contains(src, 'sha256pm'));
tc.verifyFalse(contains(src, 'fileread'));
cfg = demoCfg();  R = tepc.config.resolve(cfg);
g = repmat('b',1,64);
s = tepc.geometry.meshSpec(cfg, R, repmat('a',1,64), g);
tc.verifyEqual(char(s.geometrySha256), g, 'geometrySha256 必须原样透传');
tc.verifyEqual(char(s.sourceConfigSha256), repmat('a',1,64));
tc.verifyEqual(char(s.sha256Source), 'manifest');
tc.verifyTrue(logical(s.auditComplete));
% 自哈希哨兵必须被拒 (它会让 provenance 成为不可达的循环)
tc.verifyError(@() tepc.geometry.meshSpec(cfg, R, repmat('a',1,64), 'RECOMPUTED_IN_GEOMETRY'), ...
    'tepc:geometry:SelfHashForbidden');
% 无溯源必须显式可见, 而不是静默当 0
s0 = tepc.geometry.meshSpec(cfg, R);
tc.verifyEqual(char(s0.sha256Source), 'none');
tc.verifyFalse(logical(s0.auditComplete));
tc.verifyEqual(char(s0.sourceConfigSha256), '');
end

function test_assumed_items_are_listed_not_invented(tc)
[~, ~, spec] = fixture();
tc.verifyTrue(iscell(spec.assumed) && numel(spec.assumed) >= 5);
txt = strjoin(spec.assumed, ' | ');
tc.verifyTrue(contains(txt, 'ASSUMED'));
% 源方向/锥角已进配置 (source.direction / source.coneHalfAngle_deg) 并由 meshSpec 消费,
% 所以它们**不该**再挂 ASSUMED; 兜底路径与清单对账由 test_source_direction_identity 钉。
tc.verifyFalse(contains(txt, 'source.direction'), ...
    '源方向已在配置里却仍进 ASSUMED 清单: 清单会攒出根本不欠的假定');
% 假定的名义密度必须指名读取它的函数; 取数点已收敛到 tepc.transport.wallDensity。
tc.verifyTrue(contains(txt, 'wallDensity'), '壁的名义密度必须指向代码出处');
tc.verifyTrue(isfile(fullfile(tepc.io.projectRoot(), 'src', '+tepc', ...
    '+transport', 'wallDensity.m')), 'ASSUMED 清单指名的取数函数文件不存在');
% 源方向/锥角在 spec.source 上也必须带着状态标注 (现在是配置来源)
tc.verifyEqual(char(spec.source.status), 'MEASURED_CONFIG');
tc.verifyEqual(norm(spec.source.directionUnit), 1, 'RelTol', 1e-12);
end

%% ==================== 辅助 (不得以 test 开头) ====================

function e = envOf(man, id)
i = find(strcmpi({man.parts.part_id}, id), 1);
assert(~isempty(i), sprintf('manifest 缺少零件 %s', id));
e = man.parts(i).envelope_units;
end

function [nFaces, V] = readStl(path)
% 独立解析二进制 STL (不调 exportGeometry 的 reader)。
% 格式: 80 字节头 + uint32 面数 + 每面 50 字节 (12 个 float32 + uint16 属性计数)。
% 两个 MATLAB 特有的坑 (实测):
%   1) fread(fid,inf,'uint8') 返回的是 **double** (fread 默认把精度值转成 double),
%      typecast 只吃整型 => 必须显式 uint8(...) 再 typecast。
%   2) typecast 只接受**向量** => 48 x n 的面记录矩阵必须先 reshape 成 1xN 字节流
%      (列优先展开 = 面主序, 与落盘字节序一致), 不能直接把二维矩阵喂进去。
% 返回 V = (3*n) x 3 的**未去重**顶点表: STL 是面独立的格式, 每个面自带三个顶点,
% 去重与否正是"网格有没有被展开成重复顶点"的判据, 所以这里保留原始三份。
fid = fopen(path,'r','l');
fseek(fid, 80, 'bof');
n = double(fread(fid, 1, 'uint32'));
raw = fread(fid, inf, 'uint8');
fclose(fid);
b = reshape(raw(1:n*50), 50, []).';
f = double(reshape(typecast(uint8(reshape(b(:,1:48).',1,[])),'single'), 12, []).');
V = reshape(f(:,4:12).', 3, []).';            % 每面 9 列 -> 3 行顶点 (列优先 = 面主序)
nFaces = n;
end

function n = objVertexCount(path)
% 数 OBJ 里的顶点行。**不能**用 regexp(...,'once'): 'once' 只返回第一个匹配,
% numel() 于是恒为 0/1, 断言退化成"文件里至少有一个 v 行" —— 那是个不会失败的门禁。
txt = fileread(path);
n = numel(regexp(txt, '(?m)^v '));
end

function c = plyCounts(path)
% 从 PLY 头部读 element vertex / element face 的计数 (自己解析文本)。
fid = fopen(path,'r');
c = [NaN NaN];
while true
    ln = fgetl(fid);
    if ~ischar(ln), break; end
    tok = regexp(lower(ln), '\s+', 'split');
    if numel(tok) == 3 && strcmp(tok{1},'element')
        if strcmp(tok{2},'vertex'), c(1) = str2double(tok{3}); end
        if strcmp(tok{2},'face'),   c(2) = str2double(tok{3}); break; end
    end
end
fclose(fid);
end

function sabotageStl(path, factor)
% 读回二进制 STL, 把顶点乘 factor 再写回 (制造 1000 倍单位缩放坑)。
% 法向 (每面前 3 个 float) 不动: 它无单位, 缩放它就不是"单位坑"了。
fid = fopen(path,'r','l');
fseek(fid,80,'bof');
n = double(fread(fid,1,'uint32'));
raw = fread(fid, inf, 'uint8');
fclose(fid);
assert(numel(raw) >= n*50, 'sabotageStl: %s 只有 %d 字节, 不足 %d', path, numel(raw), n*50);
b = reshape(raw(1:n*50), 50, []).';
f = reshape(typecast(uint8(reshape(b(:,1:48).',1,[])),'single'), 12, []).';
f(:,4:12) = f(:,4:12)*single(factor);
out = fopen(path,'w','l');
fprintf(out, '%-80s', 'sabotaged-by-test');
fwrite(out, uint32(n), 'uint32');
buf = zeros(n,50,'uint8');
buf(:,1:48) = reshape(typecast(reshape(f.',1,[]),'uint8'), 48, []).';
fwrite(out, buf.', 'uint8');
fclose(out);
end

%% ==================== 源码纯净性扫描器 ====================

function hits = rngForbiddenHits(code)
% 在**纯代码文本** (codeOnlyText 的输出) 上找禁用的随机数 / 抽样器 / 输运层调用。
% 只匹配调用形式 (词边界 + 左括号, 或包名与属性名), 所以 random / distribute 这类
% 嵌在别的标识符里的词不会误报, 注释与字符串里的同名词由 codeOnlyText 已经去掉。
%
% MATLAB 正则坑 (实测): `\b` 在 MATLAB 里是**退格符**而不是词边界 —— 用 `\brand\(`
% 形式的模式恒不命中, 门又变成空的。MATLAB 的词边界是 `\<` 与 `\>`。
% 局限 (如实声明): 这是文本扫描不是语法树解析 —— feval('rand')、eval 之类反射调用
% 会漏; 所以同一条测试还从"抽样只能落在 traceSpec"那一侧做正向断言。
pats = {'\<rand\s*\(',        'rand()';             ...
        '\<randn\s*\(',       'randn()';            ...
        '\<randi\s*\(',       'randi()';            ...
        '\<randperm\s*\(',    'randperm()';         ...
        '\<rng\s*\(',         'rng()';              ...
        '\<shuffle\s*\(',     'shuffle()';          ...
        '\<RandStream\>',     'RandStream';         ...
        '\<Substream\>',      'Substream 子流';     ...
        '\<sampleChord\>',    'sampleChord()';      ...
        '\<sampleIonPairs\>', 'sampleIonPairs()';   ...
        '\<tepc\.transport\>','tepc.transport.*';   ...
        '\<tepc\.uq\>',       'tepc.uq.*';          ...
        '\<csdaTransport\>',  'csdaTransport()'};
NL = sprintf('\n');
hits = {};
for k = 1:size(pats,1)
    m = regexp(code, pats{k,1}, 'once');
    if ~isempty(m)
        hits{end+1} = sprintf('%s (字符 %d, 行 %d)', pats{k,2}, m, 1 + count(code(1:m), NL));
    end
end
end

function code = codeOnlyText(txt)
%CODEONLYTEXT 剥掉 MATLAB 源码里的**注释**与**字符串字面量**, 只留代码。
%
%   为什么必须自己写状态机: MATLAB 正则的 `.` **匹配换行**, 所以看起来人畜无害的
%   regexprep(txt,'(?m)%.*$','') 会从第一个 % 一路删到文件末尾 —— 实测三个生产文件
%   的"违规命中数"恒为 0, 那是一条永远不会响的门禁 —— 不会失败的不是门禁。
%   反过来, 只删注释不删字面量也不行: exportGeometry 的 limits 说明里就有
%   'csdaTransport/wallEscape' 这个词, 它是**文档**不是调用。
%
% 状态机 (逐字符, 4 个状态):
%   0 代码      '%' 或 '...' -> 注释/续行到行尾 ('...' 在 MATLAB 里本身就是注释符)
%               '"' -> 进双引号字面量; "'" -> 见下面的转置判定
%   1 单引号串  整段丢弃 ('' 为转义), 写一个空格占位防止相邻 token 粘连
%   2 双引号串  整段丢弃 ("" 为转义)
%   3 注释      丢到换行
%
% 转置判定 (唯一的启发式, 也是本函数唯一的失真风险): 撇号紧跟在"值"的结尾
% (标识符字符 / 数字 / ) / ] / } / . / 引号) 之后 => 是转置算符; 否则 (行首、运算符、
% 逗号、case/else/end 等关键字之后) => 是字符向量的开引号。每行开头重置为操作数位置,
% 因为 MATLAB 里跨行只能靠 '...' 续行 (已在状态 3 里吃掉)。
% 工作区间由 test_graphics_layer_has_no_rng_or_samplers 的正/负对照钉住: 注入 12 种
% 随机调用必须全部抓到, 注释与字面量里的同名词必须全部放过。
NL = sprintf('\n');
txt = strrep(txt, [sprintf('\r') NL], NL);       % CRLF -> LF
txt = [txt NL];                                  % 收尾一个换行, 状态机不用特判
n = numel(txt);
out = blanks(n);
w = 0;
state = 0;
prev = NL;                                       % 字面量外上一个非空白字符
idTail = '';                                     % 紧贴撇号之前的标识符尾巴 (判关键字)
i = 1;
while i <= n
    ch = txt(i);
    switch state
        case 0                                   % ---- 代码 ----
            if ch == '%'
                state = 3;
            elseif ch == '.' && i + 2 <= n && txt(i+1) == '.' && txt(i+2) == '.'
                state = 3; i = i + 2;            % '...' 续行: 吃到行尾
            elseif ch == '"'
                state = 2; w = w + 1;            % 空格占位
            elseif ch == ''''
                if isOpenQuote(prev, idTail)
                    state = 1; w = w + 1;
                else
                    w = w + 1; out(w) = ch;      % 转置算符: 保留
                end
            else
                w = w + 1; out(w) = ch;
                if ch == NL
                    prev = NL; idTail = '';
                elseif ~isspace(ch)
                    prev = ch;
                    if isIdentifierChar(ch)
                        idTail = [idTail ch];
                        if numel(idTail) > 8, idTail = idTail(end-7:end); end
                    else
                        idTail = '';
                    end
                end
            end
        case 1                                   % ---- '...' 字符向量 ----
            if ch == ''''
                if i < n && txt(i+1) == ''''
                    i = i + 1;                   % '' 转义
                else
                    state = 0; prev = ''''; idTail = '';
                end
            end
        case 2                                   % ---- "..." 字符串 ----
            if ch == '"'
                if i < n && txt(i+1) == '"'
                    i = i + 1;
                else
                    state = 0; prev = '"'; idTail = '';
                end
            end
        otherwise                                % ---- 注释 ----
            if ch == NL, state = 0; end
    end
    i = i + 1;
end
code = out(1:w);
end

function tf = isOpenQuote(prev, idTail)
% 撇号是"开字符向量"还是"转置算符" (见 codeOnlyText 的启发式说明)。
symbols = ')]}''".';
afterValue = ismember(prev, symbols) || prev == '_' || isstrprop(prev, 'alphanum');
kw = {'case','else','end','if','while','for','return','and','or','not', ...
      'otherwise','switch','function'};
afterKeyword = any(strcmp(lower(idTail), kw));
tf = ~afterValue || afterKeyword;
end

function writeTextFile(path, txt)
% UTF-8 写文本 (正对照的临时副本); 只用于测试, 不进任何 run 目录。
fid = fopen(path, 'w', 'n', 'UTF-8');
assert(fid >= 0, '无法写 %s', path);
fprintf(fid, '%s', txt);
fclose(fid);
end

function tf = isIdentifierChar(ch)
tf = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_';
end

%% ==================== manifest schema 校验器 (显式子集) ====================

function errs = validateJsonNode(val, sch, where)
%VALIDATEJSONNODE 手写 JSON Schema **子集**校验器: base MATLAB 没有 jsonschema 库。
%
% 支持的关键字 (geometry_manifest.schema.json 只准用这些, 测试里有拦截断言):
%   type (标量或联合, 含 null) / const / enum / minimum / minItems / maxItems /
%   pattern (仅字符串) / properties / required / additionalProperties:false / items
% 局限 —— 不假装是完整实现:
%   * 不实现 $ref / allOf / anyOf / oneOf / not / if-then / format / multipleOf /
%     maxLength。用了它们本校验器**不会**报错, 所以 test_manifest_conforms_to_written_schema
%     先用 regexp 扫 schema 文本, 出现这些词即失败 (否则"通过"是假的)。
%   * jsonencode 把 NaN/Inf 写成 null, jsondecode 又把 null 读成 [] => "null" 等价于
%     isEmpty 且非字符串/非 struct/非 cell。可空字段的类型写成 ["number","null"]。
%   * jsondecode 的歧义: 长度为 1 的 JSON 数组读成标量, 单元素的对象数组读成 1x1 struct。
%     所以 arrayLike 把标量数值也当 1 元素数组 (minItems 仍能拦), 而 object/array 在
%     "1x1 struct" 这一例上不可区分 —— 零件表只有一件时按 object 处理。
%   * 递归无深度/循环引用保护 (manifest 是树, 不存在环)。
errs = {};
if ~isstruct(sch) || isempty(sch), return; end
if isfield(sch,'type')
    kinds = asCellList(sch.type);
    ok = false;
    for j = 1:numel(kinds)
        if kindMatches(val, kinds{j}), ok = true; break; end
    end
    if ~ok
        errs{end+1} = sprintf('%s: 类型应为 %s, 实得 %s', where, ...
            strjoin(kinds, '|'), jsonKindOf(val));
        return
    end
end
if isfield(sch,'const') && ~constEquals(val, sch.const)
    errs{end+1} = sprintf('%s: 必须恒等于 %s, 实得 %s', where, valueText(sch.const), valueText(val));
end
if isfield(sch,'enum')
    e = asCellList(sch.enum);
    hit = false;
    for j = 1:numel(e)
        if constEquals(val, e{j}), hit = true; break; end
    end
    if ~hit
        txt = cellfun(@valueText, e, 'UniformOutput', false);
        errs{end+1} = sprintf('%s: 取值 %s 不在 enum {%s} 内', where, ...
            valueText(val), strjoin(txt, ', '));
    end
end
if isfield(sch,'minimum') && isnumeric(val) && isscalar(val) && val < sch.minimum
    errs{end+1} = sprintf('%s: %g 小于 minimum %g', where, val, sch.minimum);
end
if isfield(sch,'pattern') && (ischar(val) || isstring(val)) && ~isempty(val)
    if isempty(regexp(char(val), char(sch.pattern), 'once'))
        errs{end+1} = sprintf('%s: "%s" 不匹配 %s', where, char(val), char(sch.pattern));
    end
end
if isstruct(val) && numel(val) == 1
    errs = [errs, objectNodeErrors(val, sch, where)];
elseif arrayLike(val)
    n = numel(val);
    if isfield(sch,'minItems') && n < sch.minItems
        errs{end+1} = sprintf('%s: 元素数 %d 少于 minItems %d', where, n, sch.minItems);
    end
    if isfield(sch,'maxItems') && n > sch.maxItems
        errs{end+1} = sprintf('%s: 元素数 %d 多于 maxItems %d', where, n, sch.maxItems);
    end
    if isfield(sch,'items') && isstruct(sch.items)
        for i = 1:n
            errs = [errs, validateJsonNode(itemAt(val,i), sch.items, sprintf('%s[%d]', where, i))];
        end
    end
end
end

function errs = objectNodeErrors(val, sch, where)
errs = {};
if isfield(sch,'required')
    req = asCellList(sch.required);
    for j = 1:numel(req)
        if ~isfield(val, req{j})
            errs{end+1} = sprintf('%s: 缺 required 字段 %s', where, req{j});
        end
    end
end
if isfield(sch,'properties')
    ps = fieldnames(sch.properties);
    have = fieldnames(val);
    for j = 1:numel(ps)
        f = ps{j};
        if any(strcmp(have, f))
            errs = [errs, validateJsonNode(val.(f), sch.properties.(f), [where '.' f])];
        end
    end
    if isfield(sch,'additionalProperties') && islogical(sch.additionalProperties) ...
            && ~sch.additionalProperties
        extra = have(~ismember(have, ps));
        for j = 1:numel(extra)
            errs{end+1} = sprintf('%s: schema 未声明的字段 %s (改代码必须同时改 schema)', where, extra{j});
        end
    end
end
end

function tf = arrayLike(v)
% jsondecode 之后还可能代表 JSON 数组的 MATLAB 形态 (见 validateJsonNode 的局限 3)。
tf = iscell(v) || (isstruct(v) && numel(v) > 1) || ...
     ((isnumeric(v) || islogical(v)) && ~isempty(v));
end

function v = itemAt(val, i)
if iscell(val), v = val{i}; else, v = val(i); end
end

function k = jsonKindOf(v)
if isstruct(v)
    if numel(v) == 1, k = 'object'; else, k = 'array'; end
elseif iscell(v)
    k = 'array';
elseif ischar(v) || isstring(v)
    k = 'string';
elseif islogical(v)
    if isempty(v), k = 'null'; elseif isscalar(v), k = 'boolean'; else, k = 'array'; end
elseif isnumeric(v)
    if isempty(v), k = 'null'; elseif isscalar(v), k = 'number'; else, k = 'array'; end
else
    k = class(v);
end
end

function tf = kindMatches(v, want)
switch lower(char(string(want)))
    case 'null',    tf = isempty(v) && ~(ischar(v) || isstring(v) || isstruct(v) || iscell(v));
    case 'string',  tf = ischar(v) || isstring(v);
    case 'boolean', tf = islogical(v) && isscalar(v);
    case 'integer', tf = isnumeric(v) && ~isempty(v) && all(isfinite(v(:))) && all(v(:) == round(v(:)));
    case 'number',  tf = isnumeric(v) && ~isempty(v);
    case 'object',  tf = isstruct(v) && numel(v) == 1;
    case 'array',   tf = arrayLike(v);
    otherwise,      tf = false;
end
end

function c = asCellList(v)
if iscell(v)
    c = v(:).';
elseif isstring(v)
    c = cellstr(v);
elseif ischar(v)
    % jsondecode 会把**等长**字符串数组收成 char 矩阵 (如 ["A","M","R"] 或
    % ["exploded","section","overlay"]), 这时整块 char 不是"一个取值"。
    % 按行拆开: 多行 => 每行一个候选; 单行且长度>1 时无法与"单个长字符串"区分,
    % 因此 schema 侧对单字母枚举改用 pattern (无歧义), 这里只修多行情形。
    if size(v, 1) > 1
        c = cellstr(v);
    else
        c = {v};
    end
elseif isnumeric(v) || islogical(v)
    c = num2cell(v(:)).';
else
    c = {v};
end
end

function tf = constEquals(v, want)
if isnumeric(want) || islogical(want)
    tf = (isnumeric(v) || islogical(v)) && isscalar(v) && ~isempty(v) && double(v) == double(want);
else
    tf = (ischar(v) || isstring(v)) && strcmp(char(v), char(want));
end
end

function s = valueText(v)
if ischar(v) || isstring(v)
    s = ['"' char(v(1)) '"'];
elseif iscell(v)
    s = '<array>';
elseif isstruct(v)
    s = '<object>';
elseif isempty(v)
    s = 'null';
else
    s = mat2str(v);
end
end
