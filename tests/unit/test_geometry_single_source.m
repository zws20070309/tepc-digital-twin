function tests = test_geometry_single_source
%TEST_GEOMETRY_SINGLE_SOURCE 装置清单 (geometry/device_v2.json) 必须是三维零件表的供数处。
%
% 三件事各自有锁, 缺一条就退回"两份描述各活一次":
%   (a) 逐字段对账: 清单声明的长度与身份列必须与 meshSpec 建出来的零件表同值;
%   (b) 审计量锁死到最后一位: V/S/lbar/4V/S 与逐零件的顶点数、面数、网格内容哈希都钉在
%       改造前实测的 17 位数值上 (AbsTol 0 / 逐位比较), 并给出一条"改动一个输入就会红"的
%       负对照 —— 否则这种锁只是装饰;
%   (c) 清单在调用路径上: 换一份改过的清单副本必须让构建结果**可见地**变化, 越出声明
%       带宽时 meshSpec 必须以 tepc:geometry:ManifestMismatch 拒住并点名零件、字段、两侧值。
%
% 单位与精度口径: 清单内部长度以米书写, 配置以 mm/um 书写, 两者的十进制字面量与
% mm/um*10^k 的换算结果可差 1 ulp (0.00005 对 50*1e-6, 0.0284 对 0.0254+0.003)。这类
% 书写漂移不是物理差, 故承重长度容 2 ulp; 展示长度 (丝长、世界体半宽) 容相对 1e-9 并
% 直接取清单值 —— 那是清单真正供数的两列, 也就是 (c) 里"可见地变化"的落点。
tests = functiontests(localfunctions);
end

%% ==================== 夹具 (名字不得以 test 开头, 首参不得叫 tc) ====================

function root = repoRoot()
root = tepc.io.projectRoot();
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(repoRoot(), 'config', 'defaults', 'demo_only.json'));
end

function [c, R, spec, dev] = fixture()
c = demoCfg();
R = tepc.config.resolve(c);
spec = tepc.geometry.meshSpec(c, R);
dev = tepc.geometry.deviceSpec();
end

function p = partOf(spec, id)
k = find(strcmpi({spec.parts.part_id}, id), 1);
assert(~isempty(k), sprintf('零件表缺少 %s', id));
p = spec.parts(k);
end

function g = geomOf(dev, id)
k = find(string(dev.part_ids) == string(id), 1);
assert(~isempty(k), sprintf('清单缺少 %s', id));
g = dev.geometry(k);
end

function q = numOf(dev, id, nm)
% 清单侧数值: 归一化几何行里 null 一律 NaN (未声明)。
g = geomOf(dev, id);
assert(isfield(g, char(nm)), '清单 %s 没有归一化字段 %s', id, nm);
q = double(g.(char(nm)));
end

function fp = fingerprint(parts)
% 网格内容指纹: 顶点坐标 %.17g + 面索引整数, 逐零件哈希。任一坐标差 1 ulp 都会改哈希,
% 所以它锁住的是"最后一位", 不是"看起来差不多"。
fp = strings(numel(parts), 1);
for k = 1:numel(parts)
    V = double(parts(k).V);
    F = double(parts(k).F);
    t = sprintf('%.17g ', V(:).');
    t = [t '|' sprintf('%.0f ', F(:).')];
    fp(k) = string(tepc.io.hashText([char(parts(k).part_id) '|' t]));
end
end

%% ==================== (a) 逐字段对账 ====================

function test_declared_lengths_agree_with_the_built_table(tc)
[~, ~, spec, dev] = fixture();
b = spec.gasRadius_m;  t = spec.wallThickness_m;
% 承重长度: 逐位相同的必须就是清单那个数 (meshSpec 取用了它), 书写漂移的不得超 2 ulp
tc.verifyEqual(b, numOf(dev, 'gas_cavity', 'radius_m'), 'AbsTol', 0, ...
    '气腔半径不是清单值');
tc.verifyEqual(t, numOf(dev, 'wall', 'thickness_m'), 'AbsTol', 0, ...
    '壁厚不是清单值');
tc.verifyEqual(partOf(spec, 'cathode').shape.radius_m, numOf(dev, 'cathode', 'radius_m'), ...
    'AbsTol', 0, '阴极 (壁内膜) 半径不是清单值');
tc.verifyEqual(partOf(spec, 'anode').shape.radius_m, numOf(dev, 'anode', 'radius_m'), ...
    'AbsTol', 2*eps(numOf(dev, 'anode', 'radius_m')), ...
    '阳极半径越出十进制书写的 2 ulp 带宽');
tc.verifyEqual(spec.wallOuterRadius_m, numOf(dev, 'wall', 'outer_radius_m'), ...
    'AbsTol', 2*eps(numOf(dev, 'wall', 'outer_radius_m')), ...
    '外皮半径 (R+t 现算) 越出十进制书写的 2 ulp 带宽');
% 清单真正供数的展示列: 越带即错, 带内取清单值 -> 必须逐位相同
tc.verifyEqual(spec.anodeLength_m, numOf(dev, 'anode', 'height_m'), 'AbsTol', 0, ...
    '丝长不是清单声明值');
tc.verifyEqual(partOf(spec, 'world_envelope').shape.half_m, ...
    numOf(dev, 'world_envelope', 'half_m'), 'AbsTol', 0, '世界体半宽不是清单声明值');
% 清单刻意留 null 的量 (运行时派生): 不得被当成清单值来对账
tc.verifyTrue(isnan(numOf(dev, 'equivalent_site_realized', 'radius_m')), ...
    '实现位点半径不再是运行时派生量, 说明清单被预填了一个快照值');
tc.verifyGreaterThan(partOf(spec, 'equivalent_site_realized').shape.radius_m, 0);
end

function test_identity_columns_are_the_manifest_columns(tc)
[~, ~, spec, dev] = fixture();
ids = string(dev.part_ids);
bad = strings(0, 1);
for k = 1:numel(ids)
    p = partOf(spec, char(ids(k)));
    g = geomOf(dev, ids(k));
    if string(p.transport_mode) ~= g.transport_stage
        bad(end+1) = sprintf('%s: transport_mode=%s 清单 transport_stage=%s', ...
            ids(k), p.transport_mode, g.transport_stage); %#ok<AGROW>
    end
    if string(p.materialStatus) ~= g.value_status
        bad(end+1) = sprintf('%s: materialStatus=%s 清单 value_status=%s', ...
            ids(k), p.materialStatus, g.value_status); %#ok<AGROW>
    end
    pk = dev.parts(k);
    wantRole = "passive";
    if logical(pk.transport_enabled), wantRole = "enter_mc"; end
    if string(p.transport_role) ~= wantRole
        bad(end+1) = sprintf('%s: transport_role=%s 与 transport_enabled=%d 不符', ...
            ids(k), p.transport_role, logical(pk.transport_enabled)); %#ok<AGROW>
    end
end
tc.verifyEqual(bad, strings(0, 1), strjoin(cellstr(bad), newline));
end

function test_adopted_rows_are_recorded_and_free_of_conflicts(tc)
[~, ~, spec] = fixture();
tc.verifyEqual(char(string(spec.manifest.state)), 'applied', ...
    '清单没有被取用 (state 非 applied): 单一真相源没接线');
rows = spec.manifest.rows;
tc.verifyTrue(numel(rows) > 20, sprintf('取用记录只有 %d 行: 对账可能退化成只问一两个量', numel(rows)));  
v = string({rows.verdict});
tc.verifyEqual(nnz(v == "conflict"), 0, sprintf('出现身份列冲突: %s', ...
    strjoin(cellstr(string({rows(v == "conflict").part_id})), ',')));
tc.verifyTrue(any(v == "adopted_bit_identical"), ...
    '没有任何逐位相同的取用记录: 清单没有真正供数');
% 承重长度的判定词汇: 只允许"逐位相同后取用"或"<=2 ulp 的书写漂移"两种
bearing = v(startsWith(v, "adopted_bit") | startsWith(v, "spelling_drift"));
tc.verifyGreaterThan(numel(bearing), 3);
end

%% ==================== (b) 审计量锁到最后一位 ====================

function test_audit_quantities_match_the_locked_baseline(tc)
[~, ~, spec] = fixture();
% 改造前实测基线 (17 位, 逐位比较): 改源不改数
tc.verifyEqual(spec.V_m3,                   6.8641973168407684e-05, 'AbsTol', 0);
tc.verifyEqual(spec.S_m2,                   0.008107319665559963,   'AbsTol', 0);
tc.verifyEqual(spec.lbar_gas_m,             0.033866666666666663,   'AbsTol', 0);
tc.verifyEqual(spec.meanChord_4V_over_S_m,  0.033866666666666663,   'AbsTol', 0);
tc.verifyEqual(spec.gasRadius_m,            0.025399999999999999,   'AbsTol', 0);
tc.verifyEqual(spec.wallThickness_m,        0.0030000000000000001,  'AbsTol', 0);
tc.verifyEqual(spec.wallOuterRadius_m,      0.028399999999999998,   'AbsTol', 0);
tc.verifyEqual(spec.anodeRadius_m,          4.9999999999999996e-05, 'AbsTol', 0);
tc.verifyEqual(spec.anodeLength_m,          0.050799999999999998,   'AbsTol', 0);
tc.verifyEqual(spec.bboxR_m,                0.025399999999999999,   'AbsTol', 0);
tc.verifyEqual(spec.worldEnvelopeHalf_m,    0.127,                  'AbsTol', 0);
tc.verifyEqual(spec.requestedDiameter_m,    1.9999999999999999e-06, 'AbsTol', 0);
tc.verifyEqual(spec.realizedDiameter_m,     5.3086603819025389e-07, 'AbsTol', 0);
tc.verifyEqual(spec.siteRelativeDifference, 0.73456698090487305,    'AbsTol', 0);
tc.verifyEqual(spec.field.a_m,              4.9999999999999996e-05, 'AbsTol', 0);
tc.verifyEqual(spec.field.b_m,              0.025399999999999999,   'AbsTol', 0);
% 逐零件顶点/面数与闭式量 (n=96 展示网格)
cnt = [9122 18240; 9122 18240; 9122 18240; 194 384; 8 12; ...
       9122 18240; 9122 18240; 98 192];
got = [[spec.parts.meshVertices].' [spec.parts.meshFaces].'];
tc.verifyEqual(got, cnt, 'AbsTol', 0, '逐零件顶点数/面数与基线不符');
tc.verifyEqual(partOf(spec, 'gas_cavity').analyticVolume_m3, 6.8641973168407684e-05, 'AbsTol', 0);
tc.verifyEqual(partOf(spec, 'gas_cavity').analyticArea_m2,   0.008107319665559963,   'AbsTol', 0);
tc.verifyEqual(partOf(spec, 'world_envelope').analyticVolume_m3, 0.016387064, 'RelTol', 1e-12);
end

function test_mesh_fingerprints_match_the_locked_baseline(tc)
[~, ~, spec] = fixture();
want = ["d031a1e3762384b27ba326c56e5d21f32f13b2969da4ceb9085b67348795a470"
        "b6785e64ad474f069da87bc82c2476d040bf75e9ed20380087db1c9040e0cabe"
        "5a0c4cc8e9293c59fb1282b0901c69819081ea98bafcc8a50c863c4ec9f9ddba"
        "81522ef62871fbffd1afdbbd3318d4dc57bea9a015f4ffd208d76c3a00b35532"
        "b073759acff1a8cc9500dcecf88097e8662a0033655e76e06eac100c4c49de1a"
        "7f6bd2d780c57356e55ba4e8b9a6f81a13fd92e064f0a5500a13062ad7113f2d"
        "d93ec82d6755fa4f33e0dcabdc30969f6d341b5d78898f28f94823a48c2d484d"
        "55e3f20817a33b83ae216afa3b095d75f9c618c682fefb5a87040270da261601"];
got = fingerprint(spec.parts);
tc.verifyEqual(got, want, '网格内容哈希与基线逐位不符: 坐标动了最后一位');
end

function test_locked_baseline_is_falsifiable(tc)
% 两条锁各自配一条"动一下就红"的负对照, 否则锁只是装饰:
%   数值锁: 把 V_m3 挪动 1 ulp (改一个输入) 后, AbsTol 0 的比较必须分辨得出来;
%   哈希锁: 在清单的声明带宽内改世界体半宽, 只有那一件的网格哈希必须变, 其余七件不变。
[~, R, spec, dev] = fixture();
Rbad = R;
Rbad.geom.V_m3 = R.geom.V_m3 + eps(R.geom.V_m3);
specBad = tepc.geometry.meshSpec(demoCfg(), Rbad);
tc.verifyTrue(specBad.V_m3 ~= spec.V_m3, ...
    '扰动 1 ulp 后仍与基线相等: 数值锁根本分辨不出最后一位');
tc.verifyEqual(specBad.V_m3, spec.V_m3, 'RelTol', 1e-12, ...
    '扰动幅度应当只在最后一位 (否则这条负对照测的是别的东西)');
c = demoCfg();
c.geometry.deviceManifest = patched(dev, 'world_envelope', 'half_m', 0.127*(1 + 1e-12));
s2 = tepc.geometry.meshSpec(c, R);
g = fingerprint(s2.parts);
h = fingerprint(spec.parts);
tc.verifyEqual(g ~= h, [false; false; false; false; true; false; false; true], ...
    '只有世界体与挂在它边界上的源锥该动: 哈希锁的不是顶点坐标');
tc.verifyEqual(s2.V_m3, spec.V_m3, 'AbsTol', 0);
end

%% ==================== (c) 清单在调用路径上 ====================

function test_out_of_band_manifest_is_rejected(tc)
[c, R, ~, dev] = fixture();
cases = {'gas_cavity', 'radius_m', 0.0254*1.001; ...
         'wall',       'thickness_m', 0.006; ...
         'anode',      'radius_m', 1.0e-4; ...
         'world_envelope', 'half_m', 0.254; ...
         'anode',      'height_m', 0.0608};
for i = 1:size(cases, 1)
    c2 = c;
    c2.geometry.deviceManifest = patched(dev, cases{i,1}, cases{i,2}, cases{i,3});
    f = @() tepc.geometry.meshSpec(c2, R);
    tc.verifyError(f, 'tepc:geometry:ManifestMismatch', ...
        sprintf('清单 %s.%s 被改成 %.17g 仍然构建成功: 门禁没有牙齿', ...
        cases{i,1}, cases{i,2}, cases{i,3}));
end
end

function test_mismatch_message_names_part_field_and_both_values(tc)
[c, R, spec0, dev] = fixture();
mv = 0.0254*1.001;
c2 = c;
c2.geometry.deviceManifest = patched(dev, 'gas_cavity', 'radius_m', mv);
id = ''; msg = '';
try
    tepc.geometry.meshSpec(c2, R);
catch err
    id = err.identifier;
    msg = err.message;
end
tc.verifyEqual(id, 'tepc:geometry:ManifestMismatch');
m = string(msg);
tc.verifyTrue(contains(m, "gas_cavity"), sprintf('报错没点名零件: %s', m));
tc.verifyTrue(contains(m, "radius_m"), sprintf('报错没点名字段: %s', m));
tc.verifyTrue(contains(m, string(sprintf('%.17g', mv))), ...
    sprintf('报错没给清单侧的值: %s', m));
tc.verifyTrue(contains(m, string(sprintf('%.17g', spec0.gasRadius_m))), ...
    sprintf('报错没给构建侧的值: %s', m));
end

function test_in_band_manifest_change_is_visible_in_the_built_table(tc)
% 清单不是"读了不用": 带内改动世界体半宽与丝长必须真的改到零件表与网格,
% 同时 V/S/lbar 逐位不动 (它们只从已解析的 R 取数)。
[c, R, spec, dev] = fixture();
nudges = {'world_envelope', 'half_m', 0.127*(1 + 1e-12); ...
          'anode',          'height_m', 0.0508*(1 + 1e-10)};
for i = 1:size(nudges, 1)
    c2 = c;
    c2.geometry.deviceManifest = patched(dev, nudges{i,1}, nudges{i,2}, nudges{i,3});
    s2 = tepc.geometry.meshSpec(c2, R);
    tc.verifyEqual(s2.V_m3, spec.V_m3, 'AbsTol', 0);
    tc.verifyEqual(s2.S_m2, spec.S_m2, 'AbsTol', 0);
    tc.verifyEqual(s2.lbar_gas_m, spec.lbar_gas_m, 'AbsTol', 0);
    if i == 1
        a = partOf(s2, 'world_envelope').shape.half_m;
        b0 = partOf(spec, 'world_envelope').shape.half_m;
    else
        a = s2.anodeLength_m;
        b0 = spec.anodeLength_m;
    end
    tc.verifyTrue(a ~= b0, sprintf( ...
        '改了清单 %s.%s 而构建结果纹丝不动: 清单只是被读了一遍', ...
        nudges{i,1}, nudges{i,2}));
    g = fingerprint(s2.parts);
    h = fingerprint(spec.parts);
    tc.verifyTrue(nnz(g' ~= h') > 0, '网格内容没有任何变化');
end
end

function test_manifest_validator_is_on_the_call_path(tc)
% 清单还带着自己的校验器进了构建路径: 与代码实际用法矛盾的 transport_stage、把 mm 当米写的
% 半径, 都在 deviceSpec 那一道锁里就被拒 (不必等到 meshSpec 的带宽比较)。
[c, R, ~, dev] = fixture();
c2 = c;
c2.geometry.deviceManifest = patched(dev, 'anode', 'transport_stage', 'not_used');
tc.verifyError(@() tepc.geometry.meshSpec(c2, R), 'tepc:geometry:TransportStageMismatch', ...
    '身份列被改写却没被拒: 清单只是被读了一遍');
c3 = c;
c3.geometry.deviceManifest = patched(dev, 'gas_cavity', 'radius_m', 25.4);   % mm 当 m 写
tc.verifyError(@() tepc.geometry.meshSpec(c3, R), 'tepc:geometry:UnitScaleSuspect', ...
    '量级窗口不在构建路径上: 单位错会一路画到图上');
end

function test_shipped_manifest_passes_and_is_hashed(tc)
[~, ~, spec, dev] = fixture();
tc.verifyEqual(char(string(spec.manifest.state)), 'applied');
tc.verifyEqual(char(string(spec.manifest.sha256)), char(dev.sha256), ...
    '零件表记录的清单哈希与 deviceSpec 算得的不一致');
tc.verifyEqual(double(spec.manifest.n_parts), double(dev.n_parts));
tc.verifyTrue(strlength(string(spec.manifest.pair_sha256)) == 64, ...
    '清单与材料表的配对哈希没进零件表');
end

function test_other_devices_record_not_this_device(tc)
% 清单描述的是"球腔 + 轴向丝"这一台装置。换敏感体积或换阳极形状时不得拿它的数字供数,
% 但也不得因此拒画 —— 状态必须机器可读地写成 not_this_device。
c = demoCfg();
c2 = c; c2.geometry.electrodeTopology = 'centerSphere';
s2 = tepc.geometry.meshSpec(c2, tepc.config.resolve(c2));
tc.verifyEqual(char(string(s2.manifest.state)), 'not_this_device');
tc.verifyEqual(string(partOf(s2, 'anode').shape.type), "sphere");
c3 = c; c3.geometry.type = 'cylinder_finite'; c3.geometry.cylinderLength_mm = 40;
R3 = tepc.config.resolve(c3);
s3 = tepc.geometry.meshSpec(c3, R3);
tc.verifyEqual(char(string(s3.manifest.state)), 'not_this_device');
tc.verifyEqual(s3.V_m3, R3.geom.V_m3, 'AbsTol', 0, '审计量仍须逐字取自已解析的 R');
tc.verifyEqual(s3.anodeLength_m, 40e-3, 'RelTol', 1e-12, ...
    '圆柱腔的丝长仍按 cylinderLength_mm (清单未描述这台装置)');
end

%% ---------------- 负对照用的小工具 ----------------
function dm = patched(dev, pid, nm, val)
% 内存清单副本: deviceSpec 接受结构体入参, 所以数值负对照不需要动仓库里那份 JSON。
dm = dev;
k = find(string(dev.part_ids) == string(pid), 1);
assert(~isempty(k), '清单里没有零件 %s', pid);
top = {char("transport_stage"), char("value_status"), char("role"), char("label"), char("transport_enabled"), ...
    char("field_enabled"), char("display_enabled"), char("tolerance_m"), char("temperature_K"), ...
    char("surface_contact"), char("export_units"), char("parent_id"), char("material_id"), ...
    char("source_document"), char("drawing_revision")};
if any(ismember(string(top), string(nm)))
    dm.parts(k).(char(nm)) = val;
else
    dm.parts(k).primitive.(char(nm)) = val;
end
end
