function tests = test_config_validate
%TEST_CONFIG_VALIDATE 配置校验红线守卫 (validate.m) 的直接单元测试。
%   动机: validate 里有 5 类守卫 (数值域/增益-量程/伽马统计量/
%   空间电荷未实现/有限几何缺尺寸), 而 validate 此前只被 GUI 控制器间接跑到,
%   守卫本身没有锁 —— "看起来有门禁, 实际无人验证门禁会响"。
tests = functiontests(localfunctions);
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(),'config','defaults','demo_only.json'));
end

function codes = codesOf(iss)
codes = strings(0,1);
for i = 1:numel(iss)
    codes(end+1) = string(iss{i}.code); %#ok<AGROW>
end
end

function n = nError(iss)
n = 0;
for i = 1:numel(iss)
    if string(iss{i}.level) == "error"
        n = n + 1;
    end
end
end

function test_demo_config_is_clean(tc)
iss = tepc.config.validate(demoCfg());
tc.verifyEqual(nError(iss), 0, sprintf('发货配置不得有 error 级问题: %s', strjoin(codesOf(iss), ',')));
end

function test_schema_documents_every_shipped_section(tc)
% config/schema/tepc-config-v1.json 是**文档模板**, 全仓没有任何代码读它 (实测 grep
% 'tepc-config-v1' 在 src/tests/tools/app 里零命中); 真正的必填与取值域判据在 validate.m。
% 所以它能被锁住的只有"按节能不能找到说明"这一件事: 本轮新增 waveform 块时模板就漏登记,
% 靠人眼发现不可靠。反向不锁 —— 模板允许留尚未进默认值的键位。
root = tepc.io.projectRoot();
df = shippedSections(fullfile(root, 'config', 'defaults', 'demo_only.json'));
sc = shippedSections(fullfile(root, 'config', 'schema', 'tepc-config-v1.json'));
missing = setdiff(df, sc, 'stable');
tc.verifyEmpty(missing, sprintf( ...
    '发货配置里有 %d 个节没在 config/schema/tepc-config-v1.json 里登记: %s (模板缺节 = 读者按图找不到键)', ...
    numel(missing), strjoin(missing, ', ')));
% 模板必须自述"不是校验器", 否则它看起来像生效的 schema (它连发货配置的部分键都没有)。
txt = readTextUtf8(fullfile(root, 'config', 'schema', 'tepc-config-v1.json'));
tc.verifyTrue(contains(txt, "不是校验器"), ...
    '模板没声明自己不被任何代码消费: 读者会以为写进模板的键都被强制检查');
end

function s = shippedSections(p)
% 顶层节名集合。jsondecode 会把不能当字段名的键改名 (下划线开头的 _doc/_banner 变成
% x_doc/x_banner, $schema_name 同理), 两个文件走同一变换, 所以按前缀一并滤掉即可。
raw = readTextUtf8(p);
C = jsondecode(raw);
tc_pre(isstruct(C), sprintf('%s 的顶层不是 JSON 对象', p));
s = string(fieldnames(C))';
s = s(~startsWith(s, "_") & ~startsWith(s, "x_") & ~startsWith(s, "$") & s ~= "schemaVersion");
s = sort(s, 'ascend');
end

function txt = readTextUtf8(p)
% 显式按 UTF-8 取字节: fileread 走本机码页 (中文 Windows 是 GBK), 会把非 ASCII 读成乱码。
tc_pre(isfile(p), sprintf('缺文件 %s', p));
fid = fopen(p, 'r', 'n', 'UTF-8');
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = string(b(:)');
end

function tc_pre(cond, msg)
if ~cond
    error("tepc:tests:ConfigPrecond", "%s", char(string(msg)));
end
end

function test_nonpositive_hv_is_rejected(tc)
% hv_V<=0 曾一路通过校验: fieldModel 仍返回"合法"的场, 但漂移方向反转/停止,
% ramoWaveform 的 dq 被 max(dq,0) 归零 -> 整条仪器链静默输出全零波形。
for V = [0, -700]
    cfg = demoCfg(); cfg.field.hv_V = V;
    codes = codesOf(tepc.config.validate(cfg));
    tc.verifyTrue(ismember("NUM_REQUIRED", codes), ...
        sprintf('hv_V=%g 必须被数值域检查拒绝 (实得 %s)', V, strjoin(codes, ',')));
end
end

function test_sphere_thin_anode_gain_mismatch_blocked(tc)
cfg = demoCfg();
cfg.geometry.electrodeTopology = "centerSphere";     % 中心球阳极 => 同心球壳场
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("FIELD_GAIN_RANGE_MISMATCH", codes), ...
    sprintf('球壳场 + 50 um 阳极 @700 V 时 G~1.6e5 必须拒绝 (实得 %s)', strjoin(codes, ',')));
end

function test_cylinder_excess_hv_gain_mismatch_blocked(tc)
% 旧门禁只在 sphere 且 a<100um 时评估 -> cylinder 场把 HV 抬到 G 远超正比区也无人管。
cfg = demoCfg();
cfg.geometry.electrodeTopology = "axialWire";        % 丝状阳极 => 同轴圆柱场
cfg.field.hv_V = 4000;
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("FIELD_GAIN_RANGE_MISMATCH", codes), ...
    sprintf('cylinder 场 HV=4000 V 时 G 超出正比计数区上界, 同样必须拒绝 (实得 %s)', strjoin(codes, ',')));
end

function test_gain_gate_warns_when_not_evaluable(tc)
% 旧实现整段包在裸 catch 里, 任何构造错误都变成"门禁通过"。现在必须显式 WARN。
cfg = demoCfg();
cfg.detector = rmfield(cfg.detector, 'diethorn_deltaV_V');
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("FIELD_GAIN_GATE_NOT_EVALUATED", codes), ...
    sprintf('增益门禁评估不了时必须显式 WARN (实得 %s)', strjoin(codes, ',')));
end

function test_avalanche_gain_matches_hand_formula(tc)
% 两种几何各对一条手算闭式: G = exp((ln2/dV) * int_a^rStart E dr), 且 rStart 夹在
% (a, 0.999b) 内。这条同时锁住"越过阴极不再积分电场"的新钳位。
dV = 36.5; V = 700; a = 50e-6; b = 25.4e-3;
rs = RandStream('Threefry','Seed',7);
kinds = ["cylinder","sphere"];
Ks = [1/log(b/a), 1/(1/a - 1/b)];
for i = 1:2
    rStart = min(10*a, 0.999*b);
    if kinds(i) == "cylinder"
        intE = V*Ks(i)*log(rStart/a);
    else
        intE = V*Ks(i)*(1/a - 1/rStart);
    end
    Ghand = exp((log(2)/dV)*intE);
    o = tepc.detector.avalanche(struct('a',a,'b',b,'hv_V',V,'kind',kinds(i)), ...
        struct('deltaV_V',dV,'rStart_m',10*a), rs);
    tc.verifyEqual(o.G_mean, Ghand, 'RelTol', 1e-12, sprintf('%s: 增益须等于手算闭式', kinds(i)));
end
% 10a 越过阴极时 (薄球壳) 必须被夹住, 而不是把电极外不存在的电场积分进去
a2 = 5e-3; b2 = 8e-3;
o2 = tepc.detector.avalanche(struct('a',a2,'b',b2,'hv_V',V,'kind',"sphere"), ...
    struct('deltaV_V',dV,'rStart_m',10*a2), rs);
G2 = exp((log(2)/dV)*V*(1/(1/a2 - 1/b2))*(1/a2 - 1/(0.999*b2)));
tc.verifyEqual(o2.G_mean, G2, 'RelTol', 1e-12, 'rStart 必须夹在 0.999b');
end

function test_avalanche_errors_when_no_room(tc)
% a 与 b 几乎重合 -> 夹位后 rStart<=a, 必须显式报错而不是静默给 G=1
opts = struct('deltaV_V',36.5,'rStart_m',[]);
tc.verifyError(@() tepc.detector.avalanche( ...
    struct('a',1.0,'b',1.0004,'hv_V',700,'kind',"sphere"), opts, ...
    RandStream('Threefry','Seed',1)), 'tepc:detector:NoAvalancheRoom');
end

function test_unsupported_geometry_types_rejected(tc)
% cylinder_endless 的 lbar=NaN、slab 的 anode.radius_m=NaN 过去只在 GUI 校验页的
% catch-all 里变成一句没信息量的"校验异常", 而这类配置根本跑不起来。
for ty = ["cylinder_endless","slab"]
    cfg = demoCfg(); cfg.geometry.type = ty;
    if ty == "slab", cfg.geometry.cylinderLength_mm = 2; end
    codes = codesOf(tepc.config.validate(cfg));
    tc.verifyTrue(ismember("GEOM_TYPE_UNSUPPORTED", codes), ...
        sprintf('%s 必须被 GEOM_TYPE_UNSUPPORTED 拒绝 (实得 %s)', ty, strjoin(codes, ',')));
end
cfg = demoCfg(); cfg.geometry.type = "cylinder_finite"; cfg.geometry.cylinderLength_mm = 20;
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("TRANSPORT_GEOM_SPHERE_ONLY", codes), ...
    'cylinder_finite 能过几何/场校验, 但输运作用点抽样只实现 sphere -> 必须给 WARN');
tc.verifyFalse(ismember("GEOM_TYPE_UNSUPPORTED", codes), 'cylinder_finite 不该被硬拒');
end

function test_gain_mode_without_implementation_rejected(tc)
% schema 允许 detector.gainMode="fixed", 但 src/ 里没有任何代码读该字段
% (GUI "增益模式"文本框是假开关) -> 与空间电荷同一纪律: 未实现就显式拒绝。
cfg = demoCfg(); cfg.detector.gainMode = "fixed";
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("GAIN_MODE_UNIMPLEMENTED", codes), ...
    'gainMode=fixed 无实现, 必须拒绝而不是静默忽略');
end

function test_range2_gain_below_one_rejected(tc)
% extCode = code*(1+(r-1)*(g2-1)); g2<1 会让量程2 的等效码低于同幅值的量程1 码,
% 跨量程非单调 -> 刻度直线拟合失效。GUI 的 el_g2 框可以随便填, 必须在校验层拦住。
cfg = demoCfg(); cfg.electronics.adc.range2Gain = 0.5;
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("NUM_REQUIRED", codes), 'range2Gain<1 必须被数值域检查拒绝');
end

function test_waveform_switch_guard(tc)
% waveform.enabled/nSub 只在事件循环之后被读, 拼成字符串或负数会晚到一个 run 的
% 最后一步才炸, 或者被当成"假开关"静默忽略 —— 与 spaceCharge/gainMode 同一纪律。
cfg = demoCfg(); cfg.waveform.enabled = "yes";
tc.verifyTrue(ismember("WAVEFORM_BAD_ENABLED", codesOf(tepc.config.validate(cfg))), ...
    '字符串 enabled 必须拒绝 (char 与 0 比较会给非标量逻辑值, 不能放行)');
cfg = demoCfg(); cfg.waveform.enabled = [0 1];
tc.verifyTrue(ismember("WAVEFORM_BAD_ENABLED", codesOf(tepc.config.validate(cfg))), ...
    '非标量 enabled 必须拒绝');
cfg = demoCfg(); cfg.waveform.nSub = -3;
tc.verifyTrue(ismember("WAVEFORM_BAD_NSUB", codesOf(tepc.config.validate(cfg))), ...
    'nSub<1 必须拒绝');
cfg = demoCfg(); cfg.waveform.nSub = 2.5;
tc.verifyTrue(ismember("WAVEFORM_BAD_NSUB", codesOf(tepc.config.validate(cfg))), ...
    '非整数 nSub 必须拒绝 (实现会 round, 说明写的人意图不明)');
cfg = demoCfg(); cfg.waveform = 3;
tc.verifyTrue(ismember("WAVEFORM_BAD_BLOCK", codesOf(tepc.config.validate(cfg))), ...
    'waveform 不是 struct 必须拒绝');
% JSON 的 null 经 jsondecode 是 0x0 double。它比"字符串"更危险: 实测 `if ~([])` 走假
% 分支, 所以"关掉开关"的空值既不报错也不关闭, 反而进入写盘路径 —— 必须判错。
cfg = demoCfg(); cfg.waveform.enabled = [];
tc.verifyTrue(ismember("WAVEFORM_BAD_ENABLED", codesOf(tepc.config.validate(cfg))), ...
    '空值 enabled 必须拒绝 (放行会让 if ~([]) 走假分支, 反而进入开启路径)');
cfg = demoCfg(); cfg.waveform.nSub = [];
tc.verifyTrue(ismember("WAVEFORM_BAD_NSUB", codesOf(tepc.config.validate(cfg))), ...
    '空值 nSub 必须拒绝 (否则会静默取默认 100)');
% 绕过 +config/validate 直接构造 cfg 的调用方也要挡住 (波形阶段自己的第二层守卫)。
% 但 execute 的第一步就是 validate, 所以经 API 进来的空值在更早一处就被拦: 这里断言的
% 是"最早那道门真的关门", 而不是运行阶段那道 (它走的是同一条判据, 只是这层拦在前面)。
cfg = demoCfg(); cfg.waveform.enabled = []; cfg.uq.enabled = false;
rdNull = fullfile(tempdir, sprintf('tepc_wfnull_%d', randi(1e9)));
tc.verifyError(@() tepc.run.execute(cfg, 'N', 8, 'Seed', 5, 'RunDir', rdNull), ...
    'tepc:run:ConfigInvalid', '空值开关必须在校验阶段就拒, 不许走到写盘路径');
tc.verifyFalse(isfile(fullfile(rdNull, 'events', 'waveforms.h5')), ...
    '被拒的开关却留下了波形文件');
if isfolder(rdNull), rmdir(rdNull, 's'); end
% JSON 的 null 经 jsondecode 就是 []: 早先的守卫写成 "存在且非空才判", 于是空值直接
% 放行, 到 execute 里才由 && 拿到空值 —— 要么晚炸要么被当成关闭, 两种都不是作者写的。
cfg = demoCfg(); cfg.waveform.enabled = [];
tc.verifyTrue(ismember("WAVEFORM_BAD_ENABLED", codesOf(tepc.config.validate(cfg))), ...
    'enabled 为空值 (null) 必须拒绝, 不许当成"没写这个键"');
cfg = demoCfg(); cfg.waveform.nSub = [];
tc.verifyTrue(ismember("WAVEFORM_BAD_NSUB", codesOf(tepc.config.validate(cfg))), ...
    'nSub 为空值必须拒绝');
% 键名拼错 (enable) 时上面几条都碰不到, 而 waveformStage 会把"没有 enabled 字段"按
% 关闭处理 —— 开关被静默吃掉。未知键必须在这里就红。
cfg = demoCfg(); cfg.waveform.enable = true;
tc.verifyTrue(ismember("WAVEFORM_UNKNOWN_FIELD", codesOf(tepc.config.validate(cfg))), ...
    '拼错的开关名必须被未知字段守卫抓住, 否则它等于静默关闭');
% 负控: 发货值与显式打开都不许触发这几类码, 否则守卫是永真的摆设。
for v = [false, true]
    cfg = demoCfg(); cfg.waveform.enabled = v;
    codes = codesOf(tepc.config.validate(cfg));
    tc.verifyFalse(any(ismember(["WAVEFORM_BAD_ENABLED","WAVEFORM_BAD_NSUB", ...
        "WAVEFORM_BAD_BLOCK","WAVEFORM_UNKNOWN_FIELD"], codes)), ...
        sprintf('enabled=%d 是合法取值却触发了守卫: %s', v, strjoin(codes, ',')));
end
% 散文键 (下划线前缀) 不参与计算, 不能被未知字段守卫误伤 —— 发货配置里就带着三个。
cfg = demoCfg();
tc.verifyFalse(any(ismember("WAVEFORM_UNKNOWN_FIELD", codesOf(tepc.config.validate(cfg)))), ...
    'demo_only.json 的 _note/_cost_note/_honesty_note 被当成未知字段了');
end

function test_source_direction_discloses_transport_does_not_consume_it(tc)
% 配对判据。只锁"发货配置会出这条 WARN"是不够的: 发货方向被钉在 [0 0 -1],
% 一条无条件追加的 WARN 也会永远通过, 于是锁察觉不到"分支其实没在判字段"。
% 所以同时要求字段被摘掉时 WARN 一起消失。
code = "SOURCE_DIR_NOT_CONSUMED_BY_TRANSPORT";
tc.verifyTrue(any(ismember(code, codesOf(tepc.config.validate(demoCfg())))), ...
    'source.direction 存在时必须披露输运侧不消费它 (球对称腔 + 标量壁厚 + 常数 r0)');
c2 = demoCfg();
c2.source = rmfield(c2.source, 'direction');
tc.verifyFalse(any(ismember(code, codesOf(tepc.config.validate(c2)))), ...
    '字段已摘掉却仍出 WARN, 说明这条是无条件追加而不是按字段判定');
end

function test_quality_factor_file_discloses_it_is_not_read(tc)
% 三条判定各自独立, 缺一条就会把"按分支判定"退化成"永远说话"或"永远沉默":
% ① 发货配置 (version=icrp60_let_on_y + 带着 file) 必须出声;
% ② 把 version 换成 table 后同一份 file 真的被 fopen, WARN 必须一起消失;
% ③ 把 file 摘掉 (只剩 version) 也必须消失 —— 否则判据没在看 file。
code = "QUALITY_FACTOR_FILE_IGNORED";
c0 = demoCfg();
tc.verifyTrue(any(ismember(code, codesOf(tepc.config.validate(c0)))), ...
    'qualityFactor.file 在 version≠table 时不被读取, 这条事实没有进配置校验输出');
c1 = c0; c1.analysis.qualityFactor.version = "table";
tc.verifyFalse(any(ismember(code, codesOf(tepc.config.validate(c1)))), ...
    'version=table 时表文件确实被读, WARN 应当不再出现');
c2 = c0; c2.analysis.qualityFactor = rmfield(c2.analysis.qualityFactor, 'file');
tc.verifyFalse(any(ismember(code, codesOf(tepc.config.validate(c2)))), ...
    '没有 file 字段却仍出 WARN: 判据没有看 file');
end

function test_pretrigger_declaration_discloses_the_missing_region(tc)
% 同一族判据: 字段在发货配置里、全仓零消费者。配对第二半是"换成别的字段名也不能让
% WARN 消失"以外的方向 —— 摘掉它 WARN 必须一起消失, 否则这条是在无条件说话。
code = "PRETRIGGER_NOT_IMPLEMENTED";
c0 = demoCfg();
tc.verifyTrue(any(ismember(code, codesOf(tepc.config.validate(c0)))), ...
    'trigger.preTrigSamples 无人读取、波形无前置段这条事实没有进配置校验输出');
c1 = c0; c1.electronics.trigger = rmfield(c1.electronics.trigger, 'preTrigSamples');
tc.verifyFalse(any(ismember(code, codesOf(tepc.config.validate(c1)))), ...
    '字段已摘掉却仍出 WARN');
end

function test_shaper_type_discloses_it_is_inert(tc)
% 配对判据 + 交叉判据。摘掉 shaperType 后 WARN 必须消失, 同时 ENUM_INVALID 必须出现 ——
% 后者证明这条 WARN 不是靠"字段反正都在"混过去的, 两个守卫各自独立。
code = "SHAPER_TYPE_NOT_CONSUMED";
c0 = demoCfg();
tc.verifyTrue(any(ismember(code, codesOf(tepc.config.validate(c0)))), ...
    'shaperType 的唯一消费者 tepc.electronics.shaper 零调用, 这条事实没有进配置校验输出');
c1 = c0; c1.electronics = rmfield(c1.electronics, 'shaperType');
iss = tepc.config.validate(c1);
tc.verifyFalse(any(ismember(code, codesOf(iss))), ...
    'shaperType 已摘掉却仍出 WARN');
tc.verifyTrue(any(ismember("ENUM_INVALID", codesOf(iss))), ...
    '摘掉 shaperType 后枚举守卫没响: 两个守卫可能被写成了同一条');
% 换成另一个合法枚举值不会让 WARN 消失 —— 它说的是"没人读", 与取哪个值无关。
c2 = c0; c2.electronics.shaperType = "trapezoid";
tc.verifyTrue(any(ismember(code, codesOf(tepc.config.validate(c2)))), ...
    'WARN 只对着 cr_rc 说话: 那说明实现按值判定, 与"零消费者"这条事实不符');
end
