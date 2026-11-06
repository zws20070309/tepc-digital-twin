function tests = test_source_direction_identity
%TEST_SOURCE_DIRECTION_IDENTITY 源方向/锥角必须"配置 -> 校验 -> 网格"一条链可核对.
%
% 这条链要钉三段, 每段单独可失败:
%   1) 身份: spec.source.directionUnit 必须是配置向量归一的结果, 锥轴/底半径必须由它推出
%      (改配置就改网格顶点分布, 不是只在结构体里挂一个好看的名字)。
%   2) 兜底: 配置缺字段时退回历史常量 [0 0 -1]/15 deg, 且**必须**把退回这件事记进
%      spec.assumed 并把 status 降回 ASSUMED —— 否则清单里少了一条本该欠着的假定。
%   3) 边界: 零向量/非有限/半角越界既被 config.validate 拒, 也被 meshSpec 自己拒
%      (meshSpec 可被测试与脚本直接调用, 不能只依赖上游校验)。
%
% 还要钉一句口径: 解析输运的入射角分布仍是各向同性 (sampleChord), 而球腔平均弦长 4V/S
% 与角分布无关, 所以"方向进配置"绝不等于"源方向已建模进输运"。这条披露由测试守住,
% 否则以后有人拿它当"壁效应/方向效应已实现"的证据。
%
% 第 6 节把那句话核到**事件生成**这一层: 前面的数值控制只比弦长与 V/S/lbar, 那都在输运
% 之前; 方向若被接到通道选择或诞生点抽样上, 只有穿过 AnalyticAdapter 比逐事件列才看得见。
% 同一条用例里带两条不空转的腿 (显示侧必须真的动过、换初级能量必须真的动列), 否则
% "逐位相同"可以靠两边都没算而恒绿。
tests = functiontests(localfunctions);
end

%% ==================== 夹具 ====================

function [cfg, R] = srcFixture()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
R = tepc.config.resolve(cfg);
end

function p = conePart(spec)
i = find(strcmp({spec.parts.part_id}, 'source_cone'), 1);
assert(~isempty(i), '零件表里没有 source_cone');
p = spec.parts(i);
end

function ext = bboxExtent(V)
ext = max(V, [], 1) - min(V, [], 1);
end

%% ==================== 1. 身份链 ====================

function test_unit_direction_is_config_normalised(tc)
[cfg, R] = srcFixture();
cfg.source.direction = [2 0 0];              % 故意不给单位向量
cfg.geometry.deviceManifest = manifestWithDir([2 0 0]);
spec = tepc.geometry.meshSpec(cfg, R, "");
tc.verifyEqual(spec.source.directionUnit, [1 0 0], 'AbsTol', 1e-12, ...
    'directionUnit 不是配置向量归一的结果');
tc.verifyEqual(spec.source.directionRaw, [2 0 0], 'AbsTol', 0, ...
    '原始配置向量没随 spec 交出去: 读者无法核对归一前是什么');
p = conePart(spec);
ax = p.shape.apex_m - p.shape.base_m;
tc.verifyEqual(ax/norm(ax), -[1 0 0], 'AbsTol', 1e-12, ...
    '锥轴不等于入射方向的反向: 源不在上游, 网格与方向声明脱节');
end

function test_cone_geometry_follows_the_configured_angle(tc)
[cfg, R] = srcFixture();
half = [15 30];
rr = zeros(1, 2);
hh = zeros(1, 2);
for k = 1:2
    cfg.source.coneHalfAngle_deg = half(k);
    % 清单也声明同一个角: 否则先撞上配置/清单对账 (那是另一条用例要钉的事)。
    cfg.geometry.deviceManifest = manifestWithAngle(half(k));
    spec = tepc.geometry.meshSpec(cfg, R, "");
    p = conePart(spec);
    rr(k) = p.shape.radius_m;
    hh(k) = p.shape.height_m;
    % 从**网格顶点**量出底半径 (离锥轴最远的顶点距离), 不读 shape.radius_m:
    % 只比 shape 字段的话, buildMeshAt 忽略 radius_m 也能全绿。
    u = (p.shape.apex_m - p.shape.base_m);
    u = u / norm(u);
    rel = p.V - repmat(p.shape.base_m, size(p.V, 1), 1);
    axc = rel * u.';                       % 各顶点到锥心的轴向投影 [nV x 1]
    perp = rel - axc * u;                  % 去掉轴向分量后才是径向矢量
    rad = sqrt(sum(perp.^2, 2));
    tc.verifyEqual(max(rad), p.shape.height_m * tand(half(k)), 'RelTol', 1e-6, sprintf('网格实测底半径 %.4e != 配置角张出的 %.4e: 半角没进网格', max(rad), ...
        p.shape.height_m * tand(half(k))));
end
tc.verifyGreaterThan(rr(2), rr(1) * 1.5, ...
    sprintf('半角 15->30 deg 底半径只从 %.3e 变到 %.3e: 锥角参数是装饰', rr(1), rr(2)));
tc.verifyEqual(hh(2), hh(1), 'RelTol', 1e-12, '半角不该改锥高 (高由世界体半宽定)');
end

function test_rotated_axis_changes_the_mesh_not_just_the_record(tc)
[cfg, R] = srcFixture();
cfg.source.direction = [0 0 -1];
pz = conePart(tepc.geometry.meshSpec(cfg, R, ""));
eZ = bboxExtent(pz.V);
cfg.source.direction = [1 0 0];
cfg.geometry.deviceManifest = manifestWithDir([1 0 0]);
px = conePart(tepc.geometry.meshSpec(cfg, R, ""));
eX = bboxExtent(px.V);
% z 向锥长边在 z; x 向锥长边必须换到 x。若建锥仍写死 z 轴 (只读 apex(3)/base(3)),
% 第二条断言必红 —— 那正是"结构体改了、网格没改"的形态。
tc.verifyGreaterThan(eZ(3), eZ(1) * 1.5, '默认工况的锥长边不在 z 上');
tc.verifyGreaterThan(eX(1), eX(3) * 1.5, sprintf('direction=[1 0 0] 后锥长边仍在 z (dx=%.3e dz=%.3e): 网格没跟着方向转', eX(1), eX(3)));
tc.verifyEqual(eX(2), eX(3), 'RelTol', 1e-9, '垂直于锥轴的两个展幅应相等 (= 底径)');
tc.verifyEqual(eZ(1), eZ(2), 'RelTol', 1e-9, '默认工况垂直展幅应相等 (= 底径)');
end

function test_default_config_reproduces_historical_geometry(tc)
[cfg, R] = srcFixture();
spec = tepc.geometry.meshSpec(cfg, R, "");
p = conePart(spec);
apex = p.shape.apex_m;
base = p.shape.base_m;
tc.verifyEqual(apex(1:2), [0 0], 'AbsTol', 0, '默认方向的顶点应仍在 z 轴上');
tc.verifyGreaterThan(apex(3), 0, '默认顶点应在 +z (源在上游)');
tc.verifyEqual(base, 0.4 * apex, 'RelTol', 1e-12, '底心应是顶点到腔心的 0.4 处 (历史口径)');
% 锥高对着**世界体半宽**核: 0.6*envHalf 是声明式的构造规则, 复述 norm(apex-base) 恒真。
tc.verifyEqual(p.shape.height_m, 0.6 * spec.worldEnvelopeHalf_m, 'RelTol', 1e-12, sprintf('锥高 %.4e != 0.6 x 世界体半宽 %.4e', p.shape.height_m, spec.worldEnvelopeHalf_m));
% 长轴必须在 z 上, 且长度就是锥高 (网格侧的证据, 不读 shape)
e = bboxExtent(p.V);
[~, iLong] = max(e);
tc.verifyEqual(iLong, 3, sprintf('默认工况的网格长轴在第 %d 轴, 不在 z', iLong));
tc.verifyEqual(e(3), p.shape.height_m, 'RelTol', 1e-9, 'z 向包围盒长度 != 锥高');
end

%% ==================== 2. 兜底与状态标注 ====================

function test_stripping_the_fields_conflicts_with_the_manifest(tc)
% 清单现在声明 source_cone 的 value_status = MEASURED_CONFIG 并抄着同一对值。所以
% "把配置字段摘掉"不再是无害操作: 构建侧会退回兜底常量并报 ASSUMED, 与清单身份列分叉,
% meshSpec 必须拒 (而不是悄悄按兜底画出来)。这条把"配置/清单/网格三方同一"钉成契约。
[cfg, R] = srcFixture();
f = fieldnames(cfg.source);
drop = f(startsWith(f, {'direction', 'coneHalfAngle'}));
tc.verifyEqual(numel(drop), 2, sprintf('夹具应正好摘到 2 个字段, 实摘 %d 个', numel(drop)));
cfg.source = rmfield(cfg.source, drop);
tc.verifyError(@() tepc.geometry.meshSpec(cfg, R, ""), 'tepc:geometry:ManifestMismatch');
end

function test_shipped_values_equal_the_historical_constants(tc)
% 兜底常量与发货配置同值: 这样"缺字段"最多是丢一次来源标注, 不会把默认几何改掉。
% 兜底分支本身被上一条的清单对账挡住 (发货装置不允许静默降级), 所以这里钉等值性。
[cfg, ~] = srcFixture();
tc.verifyEqual(double(cfg.source.direction(:)).', [0 0 -1], 'AbsTol', 0, ...
    '发货源方向已不等于兜底值: 缺字段时的几何会随之改变, 等值性前提不再成立');
tc.verifyEqual(double(cfg.source.coneHalfAngle_deg), 15, 'AbsTol', 0, ...
    '发货锥角已不等于兜底值: 同上');
end

function test_present_fields_are_marked_config_and_leave_the_assumed_list(tc)
[cfg, R] = srcFixture();
spec = tepc.geometry.meshSpec(cfg, R, "");
tc.verifyEqual(char(spec.source.status), 'MEASURED_CONFIG', ...
    '发货配置给了这两个字段, status 却没升到 MEASURED_CONFIG');
txt = strjoin(spec.assumed, ' | ');
tc.verifyFalse(contains(txt, 'source.direction'), ...
    '字段已在配置里却仍挂 ASSUMED: 清单会越攒越长, 读者分不清哪条还欠着');
tc.verifyFalse(contains(txt, 'source.coneHalfAngle_deg'), '同上 (锥角)');
tc.verifyTrue(numel(spec.assumed) >= 5, sprintf('ASSUMED 清单只剩 %d 条: 其余假定被顺手删了', numel(spec.assumed)));
end

function test_manifest_and_config_declare_the_same_pair(tc)
[cfg, R] = srcFixture();
man = jsondecode(fileread(fullfile(tepc.io.projectRoot(), 'geometry', 'device_v2.json')));
i = find(strcmp({man.parts.part_id}, 'source_cone'), 1);
tc.verifyFalse(isempty(i), '清单里没有 source_cone 零件');
if isempty(i), return; end
q = man.parts(i);
tc.verifyEqual(double(q.primitive.half_angle_deg), double(cfg.source.coneHalfAngle_deg), ...
    'RelTol', 1e-12, '清单声明的锥角与配置不同: 两份真相');
tc.verifyEqual(double(q.transform.direction(:)).', double(cfg.source.direction(:)).', ...
    'RelTol', 1e-12, '清单声明的源方向与配置不同: 两份真相');
spec = tepc.geometry.meshSpec(cfg, R, "");
tc.verifyEqual(string(q.value_status), string(spec.source.status), ...
    '清单的 value_status 与构建侧状态不同: 身份列与代码实际用法分叉');
end

%% ==================== 3. 边界与拒绝 ====================

function test_validate_rejects_bad_direction_and_angle(tc)
[cfg, R] = srcFixture();
badVal = {[0 0 0], [NaN 0 0], 95, -1};
badFld = {'direction', 'direction', 'coneHalfAngle_deg', 'coneHalfAngle_deg'};
want = ["SOURCE_DIR", "SOURCE_DIR", "SOURCE_CONE", "SOURCE_CONE"];
for k = 1:numel(badVal)
    c = cfg;
    c.source.(badFld{k}) = badVal{k};
    iss = tepc.config.validate(c);
    codes = string(cellfun(@(s) string(s.code), iss, 'UniformOutput', false));
    tc.verifyTrue(any(codes == want(k)), sprintf('%s=%s 没被 validate 拒 (实得 codes: %s)', badFld{k}, mat2str(badVal{k}), ...
        strjoin(codes, ',')));
end
end

function test_meshSpec_rejects_even_when_validate_is_bypassed(tc)
[cfg, R] = srcFixture();
c2 = cfg;
c2.source.direction = [0 0 0];
tc.verifyError(@() tepc.geometry.meshSpec(c2, R, ""), 'tepc:geometry:BadSourceDirection');
c3 = cfg;
c3.source.coneHalfAngle_deg = 120;
tc.verifyError(@() tepc.geometry.meshSpec(c3, R, ""), 'tepc:geometry:BadSourceCone');
end

%% ==================== 4. 口径披露不得被读成"方向已建模" ====================

function test_transport_angular_model_stays_isotropic_and_says_so(tc)
[cfg, R] = srcFixture();
cfg.source.direction = [1 0 0];
cfg.geometry.deviceManifest = manifestWithDir([1 0 0]);
spec = tepc.geometry.meshSpec(cfg, R, "");
tc.verifyTrue(contains(string(spec.source.angularModel), "isotropic"), sprintf(['angularModel = "%s": 方向进配置后这句披露被改掉, 读者会以为输运也变成定向束了'], ...
    string(spec.source.angularModel)));
p = conePart(spec);
tc.verifyEqual(string(p.transport_role), "passive", ...
    '源锥进了输运链? 它仍应只是显示零件');
end

%% ==================== 5. 退化值、清单冲突与兜底分支 ====================

function test_direction_display_only_numeric_control(tc)
% 上一条锁的是"文字写着各向同性"; 这条锁数字: 换源方向后, 弦长抽样与承重几何必须逐位不变。
% 只有文字判据的话, 谁把 srcDir 顺手接进 sampleChord 也照样全绿。
% 反方向也要核: 如果显示几何同样没变, 那"逐位不变"只是因为方向根本没被消费, 控制是假绿。
[cfgA, R] = srcFixture();
cfgB = cfgA;
cfgB.source.direction = [1 1 -1]/sqrt(3);
cfgB.geometry.deviceManifest = manifestWithDir([1 1 -1]/sqrt(3));
gA = tepc.geometry.buildGeometry(cfgA);
gB = tepc.geometry.buildGeometry(cfgB);
L1 = tepc.geometry.sampleChord(gA, 3000, "isotropic_external", RandStream('Threefry', 'Seed', 31));
L2 = tepc.geometry.sampleChord(gB, 3000, "isotropic_external", RandStream('Threefry', 'Seed', 31));
tc.verifyEqual(L1, L2, 'AbsTol', 0, '换源方向改变了弦长抽样: 方向已经漏进输运侧');
sA = tepc.geometry.meshSpec(cfgA, R, "");
sB = tepc.geometry.meshSpec(cfgB, R, "");
tc.verifyEqual(sB.V_m3, sA.V_m3, 'AbsTol', 0, '源方向改变了气腔体积');
tc.verifyEqual(sB.S_m2, sA.S_m2, 'AbsTol', 0, '源方向改变了表面积');
tc.verifyEqual(sB.lbar_gas_m, sA.lbar_gas_m, 'AbsTol', 0, '源方向改变了平均弦长');
tc.verifyFalse(isequal(double(conePart(sA).V), double(conePart(sB).V)), ...
    '方向改了但源锥网格也没改: 上面的"逐位不变"是空转, 不是显示与输运分离');
end

function test_zero_half_angle_is_rejected_before_it_degenerates_the_mesh(tc)
% 半角 0 会让底半径 = h*tan(0) = 0: 环上顶点全部重合 -> checkMesh 数出 n-1 个重复顶点
% 与 2n 个零面积面, 整次运行被降级成 3D_NOT_AUDITED。必须在入口拒, 不能靠下游发现。
[cfg, R] = srcFixture();
c = cfg;
c.source.coneHalfAngle_deg = 0;
tc.verifyError(@() tepc.geometry.meshSpec(c, R, ""), 'tepc:geometry:BadSourceCone');
iss = tepc.config.validate(c);
codes = strings(0, 1);
if ~isempty(iss)
    codes = string(cellfun(@(s) string(s.code), iss, 'UniformOutput', false));
end
tc.verifyTrue(any(codes == "SOURCE_CONE"), 'validate 没拦住半角 0');
end

function test_manifest_and_config_conflict_is_rejected(tc)
% 清单声明 15 deg / [0 0 -1]。只改配置就会让两份声明各说各话 —— 对账必须红,
% 否则清单那一栏只是装饰 (本仓库的纪律不允许"其中一份只在测试里被读")。
[cfg, R] = srcFixture();
c = cfg;
c.source.coneHalfAngle_deg = 30;
tc.verifyError(@() tepc.geometry.meshSpec(c, R, ""), 'tepc:geometry:ManifestMismatch');
c2 = cfg;
c2.source.direction = [1 0 0];
tc.verifyError(@() tepc.geometry.meshSpec(c2, R, ""), 'tepc:geometry:ManifestMismatch');
end

function test_fallback_branch_reachable_with_an_assumed_manifest(tc)
% 兜底分支 (配置缺字段 => 退回 [0 0 -1]/15 并记进 spec.assumed) 在发货装置上被清单钉死,
% 只有把**内存清单**的 value_status 改成 ASSUMED 才走得进去 —— 走进去之后必须看到:
% status=ASSUMED、两条假定回到 spec.assumed、且几何与发货配置逐位相同 (兜底值==发货值)。
[cfg, R] = srcFixture();
man = jsondecode(fileread(fullfile(tepc.io.projectRoot(), 'geometry', 'device_v2.json')));
k = find(strcmp({man.parts.part_id}, 'source_cone'), 1);
tc.verifyFalse(isempty(k), '清单里没有 source_cone');
if isempty(k), return; end
man.parts(k).value_status = 'ASSUMED';
c = cfg;
c.geometry.deviceManifest = man;
f = fieldnames(c.source);
c.source = rmfield(c.source, f(startsWith(f, {'direction', 'coneHalfAngle'})));
try
    spec = tepc.geometry.meshSpec(c, R, "");
catch e
    error("tepc:test:FallbackUnreachable", ...
        '内存清单 ASSUMED 走不进兜底分支: [%s] %s', e.identifier, e.message);
end
p = conePart(spec);
tc.verifyEqual(char(spec.source.status), 'ASSUMED', '兜底分支里 status 没降级');
txt = strjoin(spec.assumed, ' | ');
tc.verifyTrue(contains(txt, 'source.direction'), '兜底了却没记 ASSUMED: 等于把常量伪装成配置');
tc.verifyTrue(contains(txt, 'source.coneHalfAngle_deg'), '同上 (锥角)');
ref = conePart(tepc.geometry.meshSpec(cfg, R, ""));
tc.verifyEqual(p.V, ref.V, 'AbsTol', 0, '兜底几何与发货几何不同: 缺字段会悄悄改画面');
end

function man = manifestWithDir(dirVec)
% 内存清单副本: 只改 source_cone 的声明方向。清单与配置现在双向对账,
% 所以变方向的用例必须同时变清单 —— 这正是那条耦合的证明, 不是绕过它。
man = jsondecode(fileread(fullfile(tepc.io.projectRoot(), 'geometry', 'device_v2.json')));
k = find(strcmp({man.parts.part_id}, 'source_cone'), 1);
assert(~isempty(k), '清单里没有 source_cone');
man.parts(k).transform.direction = dirVec;
end

function man = manifestWithAngle(halfDeg)
% 内存清单副本: 只改 source_cone 的声明半角。deviceSpec 接受结构体入参, 所以变角度的
% 用例不需要动仓库里那份 JSON, 也不必伪造 null。
man = jsondecode(fileread(fullfile(tepc.io.projectRoot(), 'geometry', 'device_v2.json')));
k = find(strcmp({man.parts.part_id}, 'source_cone'), 1);
assert(~isempty(k), '清单里没有 source_cone');
man.parts(k).primitive.half_angle_deg = halfDeg;
end

function ev = adapterCols(cfg, geom, nEv)
% 穿过生产适配器跑一批事件 (与 execute 的调用式一致; 表构造同 execute.m:149-151)。
% 抽样锚在 cfg.provenance.seed 的每-事件子流上, 所以两条腿之间唯一的差别只能来自被改的
% 那个配置项 —— 这是"逐位相同"这个判据成立的前提。
tables = struct('proton', tepc.transport.stoppingPower(cfg, "proton"), ...
    'electron', tepc.transport.stoppingPower(cfg, "electron"), ...
    'heavy_C',  tepc.transport.stoppingPower(cfg, "heavy_C"), ...
    'heavy_O',  tepc.transport.stoppingPower(cfg, "heavy_O"));
rs = RandStream('Threefry', 'Seed', cfg.provenance.seed);
[E, ~] = tepc.transport.AnalyticAdapter(cfg, geom, tables, rs, nEv, 1, struct('tNext', 0));
ev = [E.ev.EdepGas_keV(:), E.ev.EdepWall_keV(:), E.ev.Eescape_keV(:), E.ev.gasPath_um(:)];
end

%% ==================== 6. 链级逐位判据: 方向不得进入事件生成 ====================

function test_direction_rotation_leaves_event_columns_bitwise_identical(tc)
% 第 5 节那条数值控制只比**弦长向量**与 V/S/lbar 三个标量。这两样都在输运之前, 所以
% 谁把方向接到"事件生成"这一层 (比如按方向筛通道、按方向定诞生点) 它抓不到。
% 这里穿过生产适配器本尊比逐事件列: 通道权重、反冲能、诞生点、输运全走 AnalyticAdapter,
% 不在测试里复刻任何抽样 (复刻就等于造第二份真相)。
% 三条腿各挡一种空转:
%   (i)  换方向后四列必须逐位相同        —— 方向漏进事件生成即红;
%   (ii) 显示侧源锥网格顶点必须确实变了  —— 否则 (i) 只是在比两份同样的输入;
%  (iii) 改一个输运真的消费的旋钮 (初级能量) 时同一批列必须变 —— 否则 (i) 的"逐位相同"
%        是因为这条比对根本没有功效 (例如适配器压根没跑)。
[cfgA, R] = srcFixture();
dirB = [1 1 -1]/sqrt(3);
cfgB = cfgA;
cfgB.source.direction = dirB;
cfgB.geometry.deviceManifest = manifestWithDir(dirB);   % 清单双向对账: 变方向要同时变声明

nEv = 400;
gA = tepc.geometry.buildGeometry(cfgA);
gB = tepc.geometry.buildGeometry(cfgB);
colsA = adapterCols(cfgA, gA, nEv);
colsB = adapterCols(cfgB, gB, nEv);
tc.verifyEqual(size(colsB), size(colsA), '两条腿的事件数或列数不同, 逐位比对无从谈起');
worstCell = max(abs(colsB(:) - colsA(:)));
why = sprintf(['source.direction 从 %s 换成 %s 后, 逐事件的 EdepGas/EdepWall/Eescape/gasPath ' ...
    '四列不是逐位相同 (最大单格变化 %.3e): 方向已经漏进事件生成了'], ...
    mat2str(double(cfgA.source.direction(:)).'), mat2str(dirB), worstCell);
tc.verifyEqual(colsB, colsA, 'AbsTol', 0, why);

% (ii) 显示侧必须真的动过: 这一条与上面同源不同层, 网格顶点是最直接的证据。
sA = tepc.geometry.meshSpec(cfgA, R, "");
sB = tepc.geometry.meshSpec(cfgB, R, "");
tc.verifyFalse(isequal(double(conePart(sA).V), double(conePart(sB).V)), ...
    '方向改了而源锥网格顶点没改: 上面那条"逐位相同"是空转, 不是显示与输运分离');

% (iii) 功效腿: 改一个输运真的消费的旋钮 (初级能量) 时同一批列必须变。适配器没跑、
% 列全零、抽样被短路, 都在这条露出来 —— 没有它, (i) 可以靠"两边都没算"恒绿。
cfgE = cfgA;
cfgE.source.energy_MeV = double(cfgA.source.energy_MeV)*0.6;
colsE = adapterCols(cfgE, tepc.geometry.buildGeometry(cfgE), nEv);
tc.verifyFalse(isequaln(colsE, colsA), ...
    '初级能量降 40% 而四列逐位不变: 这条比对没有功效, 判不出方向漏没漏进事件生成');
tc.verifyGreaterThan(sum(colsA(:, 1)), 0, '气腔沉积列整列为零: 适配器没有真正产出事件');
end

%% ==================== 7. 旋转锥必须还能导出 (包络期望值也随轴走) ====================

function test_rotated_cone_still_exports_and_the_gate_is_axis_aware(tc)
% exportGeometry 的解析包络原先写死"锥的长边在 z": 方向一进配置, 换轴的锥就会被
% 报成 UnitScaleMismatch (一个 1000 倍单位错的错名)。这条用例就是那个错名的回归锁,
% 同时要求期望包络的长边确实落在 x 上 (否则说明它又退回按 z 算了)。
[cfg, R] = srcFixture();
cfg.source.direction = [1 0 0];
cfg.geometry.deviceManifest = manifestWithDir([1 0 0]);
sha = repmat('a', 1, 64);
spec = tepc.geometry.meshSpec(cfg, R, sha, sha);
tf = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
man = tepc.geometry.exportGeometry(spec, fullfile(tf.Folder, 'rotated_cone'), 'Units', 'mm');
i = find(strcmp({man.parts.part_id}, 'source_cone'), 1);
tc.verifyFalse(isempty(i), '导出的零件表里没有 source_cone');
if isempty(i), return; end
row = man.parts(i);
tc.verifyTrue(row.envelope_ok, sprintf('旋转锥的包络复核没过 (相对误差 %.3e > %.1e): 期望值没有跟着锥轴走', ...
    row.envelope_rel_err, row.envelope_tolerance));
[~, iLong] = max(row.envelope_units);
tc.verifyEqual(iLong, 1, sprintf('导出包络的长边在第 %d 轴 (期望 x): 锥轴改了而期望值仍按 z 算', iLong));
end
