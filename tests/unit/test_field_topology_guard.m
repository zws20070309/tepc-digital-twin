function tests = test_field_topology_guard
%TEST_FIELD_TOPOLOGY_GUARD 电极拓扑唯一真相源的回归锁。
%   历史缺陷: resolve.m 里有一份局部 fieldKindOf, 其 centerSphere 分支是**空操作**
%   (两支都返回 'cylinder'), 于是"中心球阳极 + 圆柱场"能通过全部校验并静默给出
%   错误的 E(r)/增益/Ramo 波形; 同参数下两种场的 G 相差 ~1182 倍 (700 V 实测
%   136.013 vs 1.6073e5)。现在拓扑->(阳极形状, 场类型) 只有 tepc.geometry.electrode 一份。
%   数值基准取自改动前的基线快照 tests/golden/baseline_pre_r17.json: axialWire 默认
%   必须与现网逐位一致。
tests = functiontests(localfunctions);
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function test_axialwire_default_is_bit_identical_to_ship(tc)
% 发货默认改成显式 axialWire 后, 场类型与增益必须与改动前**完全一致** (回归基线)。
R = tepc.config.resolve(demoCfg());
tc.verifyEqual(R.field.kind, 'cylinder');
tc.verifyEqual(R.electrode.topology, 'axialwire');
tc.verifyEqual(R.electrode.anodeType, 'axialWire');
tc.verifyEqual(R.G_mean, 136.01301895613094, 'RelTol', 1e-12, ...
    'axialWire 默认必须复现基线增益 (改动前实测值)');
end

function test_topology_drives_both_anode_shape_and_field(tc)
% 单一映射: 拓扑同时决定 anode.type 与场类型, 二者不得各说各话。
cfg = demoCfg();  cfg.geometry.electrodeTopology = "centerSphere";
R = tepc.config.resolve(cfg);
tc.verifyEqual(R.field.kind, 'sphere');
tc.verifyEqual(R.geom.anode.type, 'centerSphere');
tc.verifyEqual(R.G_mean, 160734.2559187904, 'RelTol', 1e-9, ...
    '球壳场增益必须按同心球 K=1/(1/a-1/b) 计算, 不得再退回圆柱式');
end

function test_field_kinds_match_hand_closed_forms(tc)
% 手算基准 (不是与实现互调的同义反复): K_cyl=1/ln(b/a), K_sph=1/(1/a-1/b)。
a = 50e-6; b = 25.4e-3; V = 700;
Kc = 1/log(b/a);  Ks = 1/(1/a - 1/b);
fc = tepc.detector.fieldModel(a, b, V, 'cylinder');
fs = tepc.detector.fieldModel(a, b, V, 'sphere');
tc.verifyEqual(fc.K, Kc, 'RelTol', 1e-12);
tc.verifyEqual(fs.K, Ks, 'RelTol', 1e-12);
tc.verifyEqual(fc.p, 2);  tc.verifyEqual(fs.p, 3);
% 手算比值: E_cyl(a)=700*0.16549/5e-5=2.317e6; E_sph(a)=700*5.0102e-5/(5e-5)^2=1.403e7
%          E_cyl(b)=4560 V/m; E_sph(b)=54.3 V/m
% => 阳极表面球壳场强 ~6.06 倍, 阴极侧反而弱约 84 倍 (两种场的形状完全不同)。
tc.verifyGreaterThan(fs.E(a*1.000001)/fc.E(a*1.000001), 5.9);
tc.verifyLessThan(fs.E(b*0.999)/fc.E(b*0.999), 0.02);
end

function test_center_sphere_on_cylinder_volume_rejected(tc)
cfg = demoCfg();
cfg.geometry.type = "cylinder_finite";
cfg.geometry.cylinderLength_mm = 40.0;
cfg.geometry.electrodeTopology = "centerSphere";
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("TOPOLOGYMISMATCH", upper(codes)), ...
    sprintf('centerSphere 与非球敏感体积组合必须被校验拒绝 (实得 %s)', strjoin(codes, ',')));
tc.verifyError(@() tepc.config.resolve(cfg), 'tepc:config:TopologyMismatch');
end

function test_missing_topology_rejected_no_silent_default(tc)
% 旧行为: 缺省时猜 'cylinder' (静默)。新行为: 必填, 缺失即拒绝 —— 猜默认值会造成
% 这类无人察觉的静默失效。
cfg = demoCfg();
cfg.geometry = rmfield(cfg.geometry, 'electrodeTopology');
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("ENUM_INVALID", codes), '缺失拓扑必须进枚举错误');
tc.verifyTrue(ismember("TOPOLOGYMISSING", upper(codes)), ...
    sprintf('必须给出可行动的拓扑缺失错误 (实得 %s)', strjoin(codes, ',')));
tc.verifyError(@() tepc.config.resolve(cfg), 'tepc:config:TopologyMissing');
end

function test_bogus_topology_rejected(tc)
cfg = demoCfg();  cfg.geometry.electrodeTopology = "coaxial";
tc.verifyError(@() tepc.config.resolve(cfg), 'tepc:config:BadTopology');
end

function test_legacy_fieldgeometry_key_rejected(tc)
% 两个可互相矛盾的开关不允许并存: 旧 fieldGeometry 曾优先于阳极类型被读取。
cfg = demoCfg();  cfg.geometry.fieldGeometry = "sphere";
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("FIELD_GEOMETRY_FIELD_REMOVED", codes), ...
    sprintf('保留 fieldGeometry 必须报错而不是被忽略 (实得 %s)', strjoin(codes, ',')));
end

function test_anode_too_big_now_geometry_independent(tc)
% 旧判据只对 sphere 生效; cylinder_finite 配超大阳极要等到 fieldModel 抛错才暴露。
cfg = demoCfg();
cfg.geometry.type = "cylinder_finite";  cfg.geometry.cylinderLength_mm = 40.0;
cfg.geometry.anodeRadius_um = 30000;     % 30 mm > 25.4 mm 气腔
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("ANODE_TOO_BIG", codes), ...
    sprintf('圆柱几何下阳极>=气腔半径同样必须在校验层被拒 (实得 %s)', strjoin(codes, ',')));
end

function test_gain_message_is_actionable(tc)
% 旧文案只说"降低 hv_V"却不给数值 —— 报错必须给出可行动的数值上限。
cfg = demoCfg();  cfg.geometry.electrodeTopology = "centerSphere";
iss = filterCode(tepc.config.validate(cfg), "FIELD_GAIN_RANGE_MISMATCH");
tc.verifyFalse(isempty(iss));
msg = char(iss(1).message);
tc.verifyTrue(contains(msg, "hv_V 降到"), ...
    sprintf('增益错误必须给出可行动上限, 实得: %s', msg));
end

function test_unsupported_volume_topology_rejected(tc)
for t = ["cylinder_endless", "slab"]
    cfg = demoCfg();
    cfg.geometry.type = t;  cfg.geometry.cylinderLength_mm = 10.0;
    codes = codesOf(tepc.config.validate(cfg));
    tc.verifyTrue(ismember("TOPOLOGYUNSUPPORTED", upper(codes)) || ...
        ismember("GEOM_TYPE_UNSUPPORTED", codes), ...
        sprintf('%s 必须被拒 (实得 %s)', t, strjoin(codes, ',')));
end
end

%% ---------------- helpers (不得以 test 开头) ----------------
% validate 返回的是 **cell of struct** (issues{end+1} = struct(...)), 不是结构数组。
function codes = codesOf(issues)
codes = cellfun(@(s) char(s.code), issues, 'UniformOutput', false);
end

function out = filterCode(issues, want)
keep = cellfun(@(s) strcmp(char(s.code), char(want)), issues);
out = [issues{keep}];
end
