function tests = test_geometry_chord
%TEST_GEOMETRY_CHORD 弦长抽样解析极限 + resolve/statusScan 语义。
tests = functiontests(localfunctions);
end

function test_sphere_external_causchy(tc)
cfg = demoCfg();
g = tepc.geometry.buildGeometry(cfg);
rs = RandStream('Threefry','Seed',42);
L = tepc.geometry.sampleChord(g, 2e5, "isotropic_external", rs);
m = mean(L); se = std(L)/sqrt(numel(L));
tc.verifyLessThan(abs(m - 4*g.R_m/3)/se, 3.0, '均值应在 4R/3 的 3u_stat 内');
end

function test_sphere_internal_pdf(tc)
cfg = demoCfg(); g = tepc.geometry.buildGeometry(cfg); R = g.R_m;
rs = RandStream('Threefry','Seed',7);
L = tepc.geometry.sampleChord(g, 2e5, "internal_isotropic", rs);
edgesL = linspace(0, 2*R, 21);
h = histcounts(L, edgesL); h = h(:);
V = 4/3*pi*R^3;
Fc = @(x) (pi/V).*(x.*(R^2 - x.^2/4) + x.^3/6);
pexp = (Fc(edgesL(2:end)) - Fc(edgesL(1:end-1))).' * numel(L); pexp = pexp(:);
chi2 = sum((h-pexp).^2 ./ max(pexp,1));
tc.verifyLessThan(chi2, 40, '内源弦长 pdf 应匹配精确倒抛物线 (chi2/df<2)');
tc.verifyLessThan(abs(mean(L) - 0.75*R)/R, 0.01);
end

function test_chord_endpoints_lie_on_surface(tc)
% 进出点必须真落在球面上。内源模式曾把**反向**自由程 (half + dotx) 配到 +Omega 上, 于是
% dotx>0 的那一半样本出射点在球外; L 的边缘分布当时是对的, 所以均值与卡方都看不见这个
% "方向-出射点"配对错误 —— 只有把端点半径钉住才拦得住。
cfg = demoCfg(); g = tepc.geometry.buildGeometry(cfg); R = g.R_m;
for mode = ["isotropic_external", "internal_isotropic"]
    [L, Pi, Po] = tepc.geometry.sampleChord(g, 5000, mode, RandStream('Threefry', 'Seed', 21));
    nOut = sqrt(sum(Po.^2, 1));
    tc.verifyLessThanOrEqual(max(abs(nOut - R)), 1e-12, sprintf('%s: 出射点不在球面上', mode));
    if mode == "isotropic_external"
        % 外源: 直线穿过凸体, 两个端点都在球面上。
        nIn = sqrt(sum(Pi.^2, 1));
        tc.verifyLessThanOrEqual(max(abs(nIn - R)), 1e-12, '外源入射点不在球面上');
    else
        % 内源: P_in 是**体内的诞生点**, 不该在球面上 (把它也按球面核是本用例的错)。
        tc.verifyLessThanOrEqual(max(sqrt(sum(Pi.^2, 1))), R, '内源起点必须在球内');
    end
    tc.verifyTrue(all(L(:) >= 0), sprintf('%s: 出现负弦长', mode));
    tc.verifyLessThanOrEqual(max(L(:)), 2*R + 1e-12, sprintf('%s: 弦长超过直径', mode));
end
end

function test_finite_cylinder_causchy(tc)
cfg = demoCfg(); cfg.geometry.type = 'cylinder_finite'; cfg.geometry.cylinderLength_mm = 100;
g = tepc.geometry.buildGeometry(cfg);
lc = tepc.geometry.meanChordLength(g);
[Lc,~,~] = tepc.geometry.sampleChord(g, 1e5, "isotropic_external", RandStream('Threefry','Seed',9));
mc = mean(Lc); sec = std(Lc)/sqrt(numel(Lc));
tc.verifyLessThan(abs(mc-lc)/sec, 4.0);
end

function test_cylinder_endless_limit(tc)
cfg = demoCfg(); cfg.geometry.type = 'cylinder_endless';
g = tepc.geometry.buildGeometry(cfg);
tc.verifyEqual(tepc.geometry.meanChordLength(g), 2*g.R_m);
tc.verifyTrue(isnan(g.lbar_gas_m), '无限圆柱 buildGeometry 无有限 lbar (位点映射不可用)');
end

function test_site_consistency(tc)
% demo 配置自相矛盾: 1000 Pa 无法对应 2 um 位点 (由 siteConsistency 检查捕获)
cfg = demoCfg();
g = tepc.geometry.buildGeometry(cfg);
[rho, meta] = tepc.geometry.gasDensity(1000, 293.15, cfg.gas.composition_molfrac, 1.0);
out = tepc.geometry.siteConsistency(g, rho, meta);
tc.verifyTrue(~isempty(out.issues), '1000Pa vs 2um 应触发不一致警告');
tc.verifyLessThan(out.pressure_for_target_Pa, 2e4, '目标位点所需压强应在模型域内');
tc.verifyGreaterThan(out.relative_mismatch, 0.3, 'demo 参数偏离应是显著量而非噪声');
% 质量厚度映射的定义式: rho_g*lbar_g = rho_t*lbar_t, lbar_t = 2 d_t/3
tc.verifyLessThan(abs(out.lbar_t_eq_m - out.mass_thickness_gas_kg_m2/g.site.rho_tissue)/ ...
    out.lbar_t_eq_m, 1e-12, 'lbar_t_eq 必须等于 rho_g*lbar_g/rho_t');
tc.verifyLessThan(abs(out.d_t_eq_m - 1.5*out.lbar_t_eq_m)/out.d_t_eq_m, 1e-12, ...
    '球形位点 d_t = 1.5*lbar_t');
end

function test_resolve_derived_mode_overwrites_site_pair(tc)
% 发货默认 equivalenceMode="derived": d_t 与 lbar_t 必须"成对原子覆写"为温压导出值
cfg = demoCfg();
tc.verifyEqual(string(cfg.site.equivalenceMode), "derived");
R = tepc.config.resolve(cfg);
dReq = cfg.site.targetDiameter_um*1e-6;
tc.verifyEqual(char(R.siteMode), 'derived');
tc.verifyEqual(R.site_requested_d_tissue_m, dReq, 'RelTol', 1e-12);
tc.verifyEqual(R.geom.site.d_tissue_m, R.siteConsistency.d_t_eq_m, 'RelTol', 1e-12);
% verifyNotEqual 不接受 'AbsTol' 名值参 (实测抛 MATLAB:narginchk:tooManyInputs)
% -> 写成显式差值判据, 顺带把"差多少"钉住 (发货配置: 0.5309 um vs 请求 2 um)。
tc.verifyGreaterThan(abs(R.geom.site.d_tissue_m - dReq), 1e-9, ...
    sprintf('derived 必须覆写请求位点: 实现 %.4f um vs 请求 %.4f um', ...
    R.geom.site.d_tissue_m*1e6, dReq*1e6));
% 成对性: 只改其一会让 doseChain 的定义核对式失效 (它是几何定义的恒等式)
tc.verifyEqual(R.geom.site.lbar_tissue_m, 2/3*R.geom.site.d_tissue_m, 'RelTol', 1e-12);
tc.verifyEqual(R.lbar_tissue_um, R.geom.site.lbar_tissue_m*1e6, 'RelTol', 1e-12);
tc.verifyGreaterThan(abs(R.lbar_tissue_um - 2/3*cfg.site.targetDiameter_um), 1e-9, ...
    sprintf('derived 也必须覆写 lbar_t: %.4f um vs 请求位点的 %.4f um', ...
    R.lbar_tissue_um, 2/3*cfg.site.targetDiameter_um));
% 物理: derived 模式下气体/组织质量厚度必须精确相等
mtG = R.rho_g*R.geom.lbar_gas_m;
mtT = R.geom.site.rho_tissue*R.geom.site.lbar_tissue_m;
tc.verifyLessThan(abs(mtG/mtT - 1), 1e-9, 'derived 模式须使 rho_g*lbar_g = rho_t*lbar_t');
end

function test_resolve_requested_mode_keeps_requested_site(tc)
cfg = demoCfg();
cfg.site.equivalenceMode = "requested";
R = tepc.config.resolve(cfg);
tc.verifyEqual(char(R.siteMode), 'requested');
tc.verifyEqual(R.geom.site.d_tissue_m, cfg.site.targetDiameter_um*1e-6, 'RelTol', 1e-12);
tc.verifyEqual(R.lbar_tissue_um, 2/3*cfg.site.targetDiameter_um, 'RelTol', 1e-9);
mtG = R.rho_g*R.geom.lbar_gas_m;
mtT = R.geom.site.rho_tissue*R.geom.site.lbar_tissue_m;
tc.verifyGreaterThan(abs(mtG/mtT - 1), 0.3, 'requested 模式必然不自洽 (由门禁降级捕获)');
tc.verifyEqual(R.site_requested_d_tissue_m, R.geom.site.d_tissue_m, 'RelTol', 1e-12);
end

function test_resolve_new_fields_and_notes(tc)
cfg = demoCfg();
R = tepc.config.resolve(cfg);
% r0_m: 雪崩起始半径 = 10a (与增益模型同一 ASSUMED 半径), 且必须落在 (a,b) 内
tc.verifyTrue(isfield(R,'r0_m'), 'resolve 必须返回 r0_m');
tc.verifyEqual(R.r0_m, 10*R.field.a, 'RelTol', 1e-12);
tc.verifyGreaterThan(R.r0_m, R.field.a);
tc.verifyLessThan(R.r0_m, R.field.b);
% mob: 电子/离子迁移率均须为正且量级分离
tc.verifyTrue(isfield(R,'mob'));
tc.verifyGreaterThan(R.mob.mu_e_m2_Vs, 0);
tc.verifyGreaterThan(R.mob.mu_i_m2_Vs, 0);
tc.verifyGreaterThan(R.mob.mu_e_m2_Vs/R.mob.mu_i_m2_Vs, 10, '电子迁移率应远高于离子');
% 物理: 低气压下迁移率 ~ 1/p (双极扩散近似), 压强加倍应使 mu 减半
cfg2 = cfg; cfg2.gas.pressure_Pa = 2000;
R2 = tepc.config.resolve(cfg2);
tc.verifyLessThan(abs(R2.mob.mu_e_m2_Vs/R.mob.mu_e_m2_Vs - 0.5), 1e-9, 'mu_e ∝ 1/p');
tc.verifyLessThan(abs(R2.mob.mu_i_m2_Vs/R.mob.mu_i_m2_Vs - 0.5), 1e-9, 'mu_i ∝ 1/p');
% 字段/说明条目数 (现应为 4 条, 且每条非空)
tc.verifyEqual(numel(R.notes), 4, 'resolve.notes 现应含迁移率一条 => 4 条');
for i = 1:numel(R.notes)
    tc.verifyFalse(isempty(strtrim(R.notes{i})), sprintf('notes{%d} 不得为空', i));
end
tc.verifyTrue(contains(R.notes{1}, 'kg/m3') || contains(R.notes{1}, 'kg/m'), ...
    '第 1 条应为密度/弦长说明');
tc.verifyTrue(contains(R.notes{4}, 'mu_e'), '新增的第 4 条应为迁移率说明');
end

function test_statusScan_rows_are_clean(tc)
% 原实现带前导点并产生大量空白垃圾行 (实测 25 行中 20 行空白)
cfg = demoCfg();
T = tepc.config.statusScan(cfg);
tc.verifyTrue(istable(T));
tc.verifyEqual(T.Properties.VariableNames, {'name','status','value','source'});
tc.verifyEqual(height(T), 8, '发货配置应扫出 8 个带 status 的参数 (无多余空行)');
% 点名而不是只比数量: 只写数字的话, 新增一个带 status 的参数会得到 "9 不等于 8" 这种
% 看不出是谁的失败, 而被删掉一个又新增另一个时数量不变会静默放过。
% 两侧都排成 8x1 列: 表列取出来是 8x1, 行字面量会让 verifyEqual 报"大小不匹配"。
want = ["gas.W_eV"; "gas.fano"; "gas.transport.vd_max_m_s"; "gas.transport.vd_half_Ed_Vm2"; ...
    "gas.transport.eta_attach_per_m"; "source.gamma_massatt_cm2_g"; ...
    "source.gamma_photoelectric_frac"; "detector.diethorn_deltaV_V"];
tc.verifyEqual(sort(string(T.name)), sort(want), ...
    '带 status 的参数集合与预期不一致 (新增/删除/改名都要在这里显式承认)');
cells = table2cell(T);
for i = 1:height(T)
    nm = cells{i,1}; st = cells{i,2};
    if isempty(nm) || isempty(strtrim(nm))
        tc.verifyEqual('NONBLANK', char(string(nm)), ...
            sprintf('第 %d 行 name 为空白 (垃圾行)', i));
        continue;
    end
    tc.verifyFalse(nm(1) == '.', sprintf('第 %d 行 name 含前导点: %s', i, nm));
    tc.verifyFalse(contains(nm, '..'), sprintf('第 %d 行 name 有连续点: %s', i, nm));
    if isempty(st) || isempty(strtrim(string(st)))
        tc.verifyEqual('NONBLANK', char(string(st)), sprintf('第 %d 行 status 为空白', i));
        continue;
    end
end
nms = cell(1, height(T));
for i = 1:height(T), nms{i} = cells{i,1}; end
tc.verifyEqual(any(strcmp(nms, 'gas.W_eV')), true, 'W_eV 必须被登记为带状态参数');
tc.verifyEqual(any(strcmp(nms, 'detector.diethorn_deltaV_V')), true);
tc.verifyEqual(sum(strcmp(T.status, 'ASSUMED')), 7, 'demo 配置应有 7 个 ASSUMED');
tc.verifyEqual(sum(strcmp(T.status, 'REFERENCE')), 1);
end

function test_statusScan_empty_gives_zero_rows(tc)
cfg = demoCfg();
c2 = cfg;
c2.gas = rmfield(c2.gas, {'W_eV','fano','transport'});
c2.detector = rmfield(c2.detector, 'diethorn_deltaV_V');
c2.source = rmfield(c2.source, {'gamma_massatt_cm2_g','gamma_photoelectric_frac'});
T = tepc.config.statusScan(c2);
tc.verifyEqual(height(T), 0, '无带状态参数时应返回 0 行表');
tc.verifyEqual(width(T), 4);
end

function cfg = demoCfg()
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
end
