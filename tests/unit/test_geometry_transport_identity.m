function tests = test_geometry_transport_identity
%TEST_GEOMETRY_TRANSPORT_IDENTITY 几何零件表声明的输运身份必须与能量账本的实际消费一致。
%
% 判据写成负例而不是"字段存在":
%   * 被声明为进输运的零件, 把它从输运里摘掉之后账本必须变 (壁: 它那一侧的分配消失);
%   * 被声明为不进输运的零件, 把它的几何改大一倍, 账本必须逐位不动。
% 两个方向同时成立, 零件表里的 transport_role / transport_mode 才是输运链的自述,
% 而不是一张随渲染层手写的装饰性表格。
%
% 另外锁住"退化"这一种坏法: transport_mode 一列今天有四种取值, 整表同值 (全 not_used
% 或全 mc_chord_and_csda) 说明按 part_id 分支的映射被写死或传错了参数 —— 那种表格看
% 起来更整齐, 但已经不描述任何东西。
%
% 输运链只读 geom.R_m / V_m3 / S_m2 / lbar_gas_m / wallThickness_m (见 csdaTransport.m 与
% sampleChord.m), 零件表那一份身份列 (transport_role / transport_mode / materialStatus)
% 今天已由 meshSpec 从 geometry/device_v2.json 取用 (见 tests/unit/test_geometry_single_source),
% 但"进哪条链"仍是输运侧代码的事实, 不是开关读出来的结果, 所以"摘掉某个零件"仍用等价物实现:
%   摘掉被消费的零件 -> geom.wallThickness_m = 0   (壁退出账本的壁/逸出分配)
%   改不动输运的零件 -> cfg.geometry.anodeRadius_um 翻倍 (账本逐位不动)
tests = functiontests(localfunctions);
end

%% ==================== 夹具 (名字不得以 test 开头, 首参不得叫 tc) ====================

function root = repoRoot()
root = tepc.io.projectRoot();
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(repoRoot(), 'config', 'defaults', 'demo_only.json'));
end

function want = stageMapOf()
% 逐条抄自 meshSpec 内按 part_id 分支的局部函数 transportModeOf, 不改语义。
want = struct('gas_cavity', 'mc_chord_and_csda', 'wall', 'energy_loss_table', ...
    'cathode', 'not_used', 'anode', 'field_model_only', ...
    'world_envelope', 'not_used', 'equivalent_site_realized', 'not_used', ...
    'equivalent_site_requested', 'not_used', 'source_cone', 'not_used');
end

function idx = partIndex(spec, id)
idx = find(strcmpi({spec.parts.part_id}, id), 1);
assert(~isempty(idx), sprintf('零件表缺少 %s', id));
end

function [cfg, R, E] = ledger(nEv, wall_m, anode_um)
% LEDGER 解析链的一批事件与其能量账本。
%   wall_m  : NaN = 按配置原样; 否则覆写 geom.wallThickness_m (把壁摘出输运的等价开关)
%   anode_um: NaN = 按配置原样; 否则覆写 cfg.geometry.anodeRadius_um 后重新解析
% 抽样锚在 cfg.provenance.seed 的每-事件子流上, 与 geom 的这两个字段无关 (抽样只读
% R_m/bboxR_m), 所以两条账本之间唯一的差别只能是"这两个字段是否被输运消费", 不是涨落。
cfg = demoCfg();
if ~isnan(anode_um)
    cfg.geometry.anodeRadius_um = anode_um;
end
R = tepc.config.resolve(cfg);
geom = R.geom;
if ~isnan(wall_m)
    geom.wallThickness_m = wall_m;
end
tables = struct('proton', tepc.transport.stoppingPower(cfg, "proton"), ...
    'electron', tepc.transport.stoppingPower(cfg, "electron"), ...
    'heavy_C', tepc.transport.stoppingPower(cfg, "heavy_C"), ...
    'heavy_O', tepc.transport.stoppingPower(cfg, "heavy_O"));
rs = RandStream('Threefry', 'Seed', cfg.provenance.seed);
[E, ~] = tepc.transport.AnalyticAdapter(cfg, geom, tables, rs, nEv, 1, struct('tNext', 0));
end

function doc = jsonUtf8(f)
% 读带中文注释的 JSON 必须显式按 UTF-8: 本机默认字符集是 GBK, fileread 会把 UTF-8
% 中文按双字节解码并吞掉紧随其后的字节, 解析口径因此静默错位。
fid = fopen(f, 'r', 'n', 'UTF-8');
assert(fid >= 0, sprintf('打不开 %s', f));
b = fread(fid, inf, 'char=>char');
fclose(fid);
doc = jsondecode(char(b(:).'));
end

%% ==================== 1. 身份表格本身 ====================

function test_transport_identity_table_matches_the_mapping(tc)
% 逐零件核 transport_role/transport_mode 与映射表一致, 并要求角色词表不退化:
% enter_mc 只有一个且是气腔, 其余全 passive; 证据字段不得为空。
cfg = demoCfg();
R = tepc.config.resolve(cfg);
spec = tepc.geometry.meshSpec(cfg, R);
want = stageMapOf();
ids = fieldnames(want);
ig = partIndex(spec, 'gas_cavity');
tc.verifyEqual(numel(spec.parts), numel(ids), '零件表条数与映射表不一致');
roleBad = strings(0, 1);
modeBad = strings(0, 1);
for i = 1:numel(ids)
    k = partIndex(spec, ids{i});
    p = spec.parts(k);
    wantRole = "passive";
    if k == ig, wantRole = "enter_mc"; end
    if string(p.transport_role) ~= wantRole
        roleBad(end+1) = sprintf('%s: transport_role=%s 应为 %s', ...
            ids{i}, p.transport_role, wantRole); %#ok<AGROW>
    end
    if string(p.transport_mode) ~= string(want.(ids{i}))
        modeBad(end+1) = sprintf('%s: transport_mode=%s 应为 %s', ...
            ids{i}, p.transport_mode, want.(ids{i})); %#ok<AGROW>
    end
    tc.verifyFalse(isempty(strtrim(char(p.transport_evidence))), ...
        sprintf('%s 的 transport_evidence 为空: 没有依据的角色标注等于猜', ids{i}));
end
tc.verifyEqual(roleBad, strings(0, 1), strjoin(cellstr(roleBad), newline));
tc.verifyEqual(modeBad, strings(0, 1), strjoin(cellstr(modeBad), newline));
end

function test_transport_stage_column_is_not_all_one_value(tc)
cfg = demoCfg();
R = tepc.config.resolve(cfg);
spec = tepc.geometry.meshSpec(cfg, R);
stage = string({spec.parts.transport_mode});
vocab = ["energy_loss_table", "field_model_only", "mc_chord_and_csda", "not_used"];
tc.verifyTrue(numel(unique(stage)) > 1, ...
    sprintf('transport_mode 整表同值 (%s): 按 id 分支的映射已被写死或传错参数', ...
    strjoin(cellstr(unique(stage)), '/')));
tc.verifyEqual(unique(stage), vocab, 'transport_mode 的取值集合必须恰是四值词表');
tc.verifyGreaterThan(nnz(stage ~= "not_used"), 0, '全表 not_used: 没有任何零件进输运');
tc.verifyLessThan(nnz(stage == "not_used"), numel(stage), '全表都进输运同样不可能');
role = string({spec.parts.transport_role});
tc.verifyEqual(numel(unique(role)), 2, 'transport_role 退化成一个值即坏');
end

%% ==================== 2. device_v2 的同一张表 ====================

function test_device_v2_stage_column_matches_meshspec(tc)
% 这一条按 JSON 文本核 (不经过 deviceSpec/meshSpec 的派生层), 锁的是清单文件本身的那几列:
% 零件表今天已经从这份文本取数 (meshSpec 的 manifest.state = applied), 所以文件里写错一列
% 会同时红两处 —— 这里保住"文本级"那条独立证据, 派生级的锁在 test_geometry_single_source。
f = fullfile(repoRoot(), 'geometry', 'device_v2.json');
tc.verifyTrue(isfile(f), 'geometry/device_v2.json 不在盘上, 无法与 meshSpec 对账');
if ~isfile(f), return; end
doc = jsonUtf8(f);
tc.verifyTrue(isfield(doc, 'parts') && isfield(doc, 'schema'), 'device_v2 缺 parts 或 schema');
tc.verifyEqual(string(doc.schema), "tepc-device-v2");
dp = doc.parts;
% jsondecode 对"字段集不一致的对象数组"会退化 (结构体数组变 cell), 先确认形状再取列。
tc.verifyTrue(isstruct(dp) && ~isempty(dp), 'device_v2 的 parts 不是非空结构体数组');
if ~isstruct(dp) || isempty(dp), return; end
need = ["part_id", "transport_enabled", "transport_stage", "field_enabled", "display_enabled"];
have = string(fieldnames(dp(1)));
tc.verifyTrue(all(ismember(need, have)), ...
    sprintf('device_v2 零件条目缺字段: %s', strjoin(cellstr(setdiff(need, have)), ', ')));
if ~all(ismember(need, have)), return; end
cfg = demoCfg();
R = tepc.config.resolve(cfg);
spec = tepc.geometry.meshSpec(cfg, R);
tc.verifyEqual(char(string(spec.manifest.state)), 'applied', ...
    'meshSpec 没有取用装置清单: 这份文本与零件表仍是两份互不约束的描述');
stage = string({dp.transport_stage});
tc.verifyTrue(numel(unique(stage)) > 1, 'device_v2 的 transport_stage 整表同值');
bad = strings(0, 1);
for i = 1:numel(dp)
    id = string(dp(i).part_id);
    k = find(strcmpi({spec.parts.part_id}, char(id)), 1);
    if isempty(k)
        bad(end+1) = sprintf('%s 不在 meshSpec 零件表里', id); %#ok<AGROW>
        continue
    end
    if stage(i) ~= string(spec.parts(k).transport_mode)
        bad(end+1) = sprintf('%s: transport_stage=%s 与 meshSpec transport_mode=%s 不一致', ...
            id, stage(i), spec.parts(k).transport_mode); %#ok<AGROW>
    end
    % transport_enabled 的语义是"进不进 MC 世界", 只有弦抽样 + 腔内步进那一条满足它;
    % 壁的 energy_loss_table 与阳极的 field_model_only 都不进 MC 世界, 所以取 false。
    en = logical(dp(i).transport_enabled);
    if en ~= (stage(i) == "mc_chord_and_csda")
        bad(end+1) = sprintf('%s: transport_enabled=%d 与 stage=%s 不匹配', ...
            id, en, stage(i)); %#ok<AGROW>
    end
    if en ~= (string(spec.parts(k).transport_role) == "enter_mc")
        bad(end+1) = sprintf('%s: transport_enabled 与 meshSpec 的 transport_role=%s 不一致', ...
            id, spec.parts(k).transport_role); %#ok<AGROW>
    end
end
tc.verifyEqual(bad, strings(0, 1), strjoin(cellstr(bad), newline));
tc.verifyTrue(numel(unique([dp.field_enabled])) > 1, 'field_enabled 整表同值即退化');
end

%% ==================== 3. 负例: 摘掉被消费的零件 ====================

function test_turning_the_wall_out_of_transport_removes_its_ledger_term(tc)
% 壁的 transport_mode = energy_loss_table, 依据是 csdaTransport 出腔后按"壁内射程与壁厚
% 谁大"把剩余能量劈成 壁内沉积 / 逸出 两半 (wallEscape: v = Eres*(1 - t/Rm))。把壁厚取
% 0 = 把壁摘出输运, 该劈法必须退化: 壁内沉积逐事件为 0, 逸出恰好接住它, 而气腔沉积逐位
% 不变 (控制变量)。
nEv = 120;
[~, ~, base] = ledger(nEv, NaN, NaN);
[~, ~, off]  = ledger(nEv, 0,  NaN);
F = tepc.domain.Flags();
wBase = base.ev.EdepWall_keV;
tc.verifyGreaterThan(sum(wBase), 0, ...
    '基线账本里壁内沉积为 0: 壁根本没进输运, transport_mode=energy_loss_table 是假的');
tc.verifyEqual(off.ev.EdepWall_keV, zeros(size(wBase)), 'AbsTol', 0, ...
    '壁厚取 0 后壁内沉积必须逐事件精确归零');
resid = base.ev.EdepWall_keV + base.ev.Eescape_keV;
tc.verifyEqual(off.ev.Eescape_keV, resid, 'RelTol', 1e-12, ...
    '逸出侧必须恰好接住壁内沉积让出的那份能量 (逐事件)');
tc.verifyEqual(off.ev.EdepGas_keV, base.ev.EdepGas_keV, 'AbsTol', 0, ...
    '控制变量: 气腔沉积与壁厚无关, 差别只允许出现在壁与逸出的分配上');
nEscBase = nnz(bitand(base.ev.flags, F.ESCAPE) > 0);
nEscOff  = nnz(bitand(off.ev.flags,  F.ESCAPE) > 0);
tc.verifyEqual(nEscBase, 0, 'AbsTol', 0, '发货壁厚下不应有逸出事件 (出腔剩余能量全部停在壁内)');
tc.verifyGreaterThan(nEscOff, nEscBase, '摘掉壁之后 ESCAPE 标志数必须从 0 变多');
tc.verifyGreaterThan(nnz(off.ev.Eescape_keV > 0), 0, '逸出能量列必须真的带上事件');
end

%% ==================== 4. 负例: 不进输运的零件改了不该有反应 ====================

function test_parts_outside_transport_leave_the_ledger_bitwise_unchanged(tc)
% 阳极半径只进场模型与 Diethorn 增益 (field_model_only), 世界体包络只是给外部 MC 适配器
% 预留的合同位 (not_used)。判据是"两个不同零件被改时, 动的是不同的量":
%   阳极半径翻倍 -> 账本逐位不变, 但增益必须变 (说明 field_model_only 不等于 not_used)
%   包络倍数翻倍 -> 解析审计量与增益逐位不变 (说明 not_used 不是漏标)
cfg0 = demoCfg();
a0 = cfg0.geometry.anodeRadius_um;
[~, R1, E1] = ledger(80, NaN, NaN);
[~, R2, E2] = ledger(80, NaN, 2*a0);
tc.verifyEqual(E2.ev.EdepGas_keV, E1.ev.EdepGas_keV, 'AbsTol', 0, ...
    '阳极半径被输运消费了: 它的 transport_mode 应是 mc_chord_and_csda 而不是 field_model_only');
tc.verifyEqual(E2.ev.EdepWall_keV + E2.ev.Eescape_keV, ...
    E1.ev.EdepWall_keV + E1.ev.Eescape_keV, 'AbsTol', 0, ...
    '出腔剩余能量的总量也不该被阳极半径改变');
tc.verifyGreaterThan(R2.G_mean, R1.G_mean, ...
    sprintf('阳极半径 %.0f -> %.0f um 时增益必须变 (实得 %.6g -> %.6g)', ...
    a0, 2*a0, R1.G_mean, R2.G_mean));
% 世界体半宽只被 meshSpec 用来画包络 (display_only + transport_mode=not_used)。
% 若它同时动了 V/S/lbar 或增益, 说明"不进输运"这条标注与实现分叉了。
% 配置里没有 worldEnvelopeFactor 时 meshSpec 取区间下界 5; 这里显式写出来再翻倍,
% 让"包络倍数"成为一个真被改动的输入, 而不是两次同样的解析。
cfg = demoCfg();
cfg.geometry.worldEnvelopeFactor = 5;
cfg3 = cfg;
cfg3.geometry.worldEnvelopeFactor = 10;
R3 = tepc.config.resolve(cfg3);
s1 = tepc.geometry.meshSpec(cfg, R1);
s2 = tepc.geometry.meshSpec(cfg3, R3);
r1 = s1.parts(partIndex(s1, 'world_envelope')).nominal_radius_m;
r2 = s2.parts(partIndex(s2, 'world_envelope')).nominal_radius_m;
tc.verifyEqual(r2/r1, 2, 'RelTol', 1e-12, ...
    '世界体半宽必须由包络倍数导出, 否则这条负例什么都没测到');
tc.verifyEqual(s2.V_m3, s1.V_m3, 'AbsTol', 0);
tc.verifyEqual(s2.S_m2, s1.S_m2, 'AbsTol', 0);
tc.verifyEqual(s2.lbar_gas_m, s1.lbar_gas_m, 'AbsTol', 0);
tc.verifyEqual(R3.G_mean, R1.G_mean, 'AbsTol', 0);
% 输运的几何输入逐位不变 => 同一批事件必然逐位不变 (账本无需重跑即可判定)
tc.verifyEqual(R3.geom.R_m, R1.geom.R_m, 'AbsTol', 0);
tc.verifyEqual(R3.geom.wallThickness_m, R1.geom.wallThickness_m, 'AbsTol', 0);
tc.verifyEqual(R3.geom.lbar_gas_m, R1.geom.lbar_gas_m, 'AbsTol', 0);
end
