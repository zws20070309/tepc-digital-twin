function tests = test_slx_config_identity
%TEST_SLX_CONFIG_IDENTITY 电子学模型与 config 的"一份参数、两个消费方"门禁。
%
% 核的是四段链路, 每段单独可失败:
%   config 字面量 --(modelParams)--> 符号名 --(spec 表)--> 块对话框 --(inject)-->
%   工作区数值 --(sim)--> 求解器真实步长。
% 三条判据 (checkParamIdentity):
%   nameOk   对话框里的符号名与 spec 期望一致   (吃的是配置里哪一条)
%   bakedOk  对话框存符号而不是数值字面量        (参数没被烘进 .slx 字节)
%   valueOk  符号在工作区里解析出的实际数值 == 由 cfg 现算的期望值
% 外加覆盖性 (带 SampleTime 的块必须都在 spec 里) 与文件身份 (文件级 sha256 只在
% 有意发布时改变; 结构指纹只在结构改变时改变)。
%
% 反例控制 (每条都会真的让断言变红, 见对应 *_red_* 用例): 烘入字面量、注入值与
% 配置不符、对话框指向别的符号、模型里出现未被 spec 覆盖的块。
% 第四条链之外还核求解器类型 (test_shipped_solver_is_fixed_step...): 4 行 inherited 的
% "-1" 意思是"跟着求解器走", 所以这一环才是"与配置同源"的传递前提; 反例在内存副本上
% 把模型改成变步长, 必须让 solverOk 与整体 ok 一起变红并点名 FixedStep 被忽略。
%
% 同进程内符号是共享的 (参数环境 = base 工作区): 核哪个模型, 就先注入哪个 config。
tests = functiontests(localfunctions);
end

%% ==================== 用例 ====================

function test_simulink_available(tc)
tc.assumeTrue(license('test', 'Simulink') == 1, '本机无 Simulink 许可, 模型核对不适用');
end

function test_shipped_model_has_no_baked_rate_parameters(tc)
cfg = demoCfg();
ident = tepc.simulink.checkParamIdentity(cfg, shippedSlx());
r = ident.rows;
tc.verifyTrue(all([r.bakedOk]), sprintf('被烘成字面量的对话框: %s', listBad(r)));
tc.verifyTrue(isempty(ident.unusedSymbols), ...
    sprintf('config 提供了却没被任何对话框引用的参数: %s', strjoin(ident.unusedSymbols, ', ')));
tc.verifyTrue(isempty(ident.uncovered), ...
    sprintf('带 SampleTime 却不在 spec 表里的块: %s', strjoin(ident.uncovered, ', ')));
end

function test_shipped_dialogs_equal_resolved_config_values(tc)
% 逐对话框用 config 的字面量重算一遍期望值 (不经 modelParams), 与模型现值比对:
% modelParams 里写错公式 (阈值用了迟滞、LSB 用了 bits-1 之类) 会在这里露出来。
cfg = demoCfg();
e = cfg.electronics;
applyParamsOf(cfg);
ident = tepc.simulink.checkParamIdentity(cfg, shippedSlx());
r = ident.rows;
tc.verifyEqual(numel(r), ident.nRows, 'spec 行数与核对行数一致');
want = struct('SampleTime', e.sampleTime_s, 'FixedStep', e.sampleTime_s, ...
    'OnSwitchValue', e.trigger.threshold_V, ...
    'OffSwitchValue', e.trigger.threshold_V - e.trigger.hysteresis_V, ...
    'QuantizationInterval', e.adc.fullScale_V/2^e.adc.bits);
wf = fieldnames(want);
for i = 1:numel(wf)
    sel = strcmp({r.dialog}, wf{i}) & strcmp({r.kind}, 'param');
    tc.verifyGreaterThan(sum(sel), 0, sprintf('spec 里没有 %s 这一类对话框', wf{i}));
    w = want.(wf{i});
    got = cell2mat(cellfun(@(v) v(1), {r(sel).resolved}', 'UniformOutput', false));
    cfgv = cell2mat(cellfun(@(v) v(1), {r(sel).cfgValue}', 'UniformOutput', false));
    tc.verifyEqual(got, w*ones(size(got)), 'AbsTol', 0, ...
        sprintf('%s: 模型/注入值与 config 字面量不符', wf{i}));
    tc.verifyEqual(cfgv, w*ones(size(cfgv)), 'AbsTol', 0, ...
        sprintf('%s: modelParams 的推导值与 config 字面量不符', wf{i}));
end
% 成形系数: 由同一份 filters() 算, 但按块逐个点名 (CR/RC 的极点必须等于 exp(-Ts/tau))
aD = exp(-e.sampleTime_s / e.shaping_s);
cr = r(strcmp({r.block},'CR') & strcmp({r.dialog},'Denominator'));
tc.verifyEqual(cr.resolved, [1 -aD], 'AbsTol', 0, 'CR 分母与 exp(-Ts/tau) 不符');
rc = r(strcmp({r.block},'RC') & strcmp({r.dialog},'Numerator'));
tc.verifyEqual(rc.resolved, [0 1-aD], 'AbsTol', 0, 'RC 分子与 (1-exp(-Ts/tau)) 不符');
end

function test_shipped_solver_is_fixed_step_and_a_variable_step_copy_is_caught(tc)
% 继承块的"与配置采样时间同源"是**经由求解器传递**的: spec 里 4 行 inherited 只保证对话框
% 存着 -1, 而 -1 的意思是"跟着求解器走"。这一环先前无人核 —— set_param 只发生在建模那一刻,
% 发货文件被换成变步长求解器时 FixedStep 会被忽略, 其余 13 条用例照样全绿 (本文件共 14 条,
% 只有这一条盯求解器那一环)。
% 反例只在内存副本上改设, close_system 不保存, 发货文件一个字节都不动。
cfg = demoCfg();
ident = tepc.simulink.checkParamIdentity(cfg, shippedSlx());
why = strjoin(ident.messages, ' | ');
tc.verifyTrue(ident.solverOk, sprintf('发货模型的求解器过不了定步长判据 (SolverType=[%s] Solver=[%s]): %s', ...
    ident.solverType, ident.solver, why));
tc.verifyEqual(ident.solverType, 'Fixed-step', '求解器类型不是 Fixed-step: 上面那条传递前提不成立');

slx = shippedSlx();
[~, nm, ~] = fileparts(slx);
load_system(slx);
cleanup = onCleanup(@() close_system(nm, 0));  %#ok<NASGU>
set_param(nm, 'SolverType', 'Variable-step', 'Solver', 'ode45');
id2 = tepc.simulink.checkParamIdentity(cfg, nm);
tc.verifyFalse(id2.solverOk, '改成变步长后 solverOk 仍为真: 这条判据是空的');
tc.verifyFalse(id2.ok, '改成变步长后整体 ok 仍为真: 求解器那一环没进门槛');
tc.verifyTrue(any(contains(id2.messages, 'FixedStep')), ...
    sprintf('变红的消息没点名"FixedStep 会被忽略", 这次红的是别处: %s', strjoin(id2.messages, ' | ')));
clear cleanup
end

function test_shipped_structure_fingerprint_matches_clean_rebuild(tc)
% 发货文件的结构指纹 == 用同一份 spec 干净重建出来的指纹。
% 这一步保证"指纹"这把尺子量的确实是模型结构本身, 不是某次构建的偶然字节。
fpShip = tepc.simulink.modelFingerprint(shippedSlx());
d = scratchDir('clean');
[mdl, ~] = tepc.simulink.buildElectronicsModel(demoCfg(), d, struct('modelName','TEPC_IdClean'));
close_system(mdl, 0);
fpNew = tepc.simulink.modelFingerprint(fullfile(d, [mdl, '.slx']));
tc.verifyEqual(fpNew.structure, fpShip.structure, ...
    sprintf('结构指纹与发货模型不符:\n  发货 %s\n  重建 %s', fpShip.structure, fpNew.structure));
end

function test_two_shaping_configs_share_the_file_and_track_their_own_values(tc)
% 两组不同的成形时间/步长: 同一份结构 (指纹逐位不变), 但解析出的参数各随其配置。
cfgA = demoCfg();
cfgB = demoCfg();
cfgB.electronics.shaping_s = 4.0e-6;
cfgB.electronics.sampleTime_s = 2.5e-8;
cfgB.electronics.trigger.threshold_V = 0.03125;
cfgB.electronics.adc.bits = 12;
pa = tepc.simulink.modelParams(cfgA);
pb = tepc.simulink.modelParams(cfgB);
% 反空话: 两份配置必须真的不同, 否则"指纹相同"是恒等式
tc.verifyTrue(pa.TEPC_Ts.value ~= pb.TEPC_Ts.value, '两条腿的 Ts 必须不同');
tc.verifyFalse(isequaln(pa.TEPC_denCR.value, pb.TEPC_denCR.value), '两条腿的成形极点必须不同');
tc.verifyFalse(isequaln(pa.TEPC_numRC.value, pb.TEPC_numRC.value), '两条腿的成形零点必须不同');
tc.verifyTrue(pa.TEPC_thrOn.value ~= pb.TEPC_thrOn.value, '两条腿的阈值必须不同');
tc.verifyTrue(pa.TEPC_lsb.value ~= pb.TEPC_lsb.value, '两条腿的 LSB 必须不同');
fpShip = tepc.simulink.modelFingerprint(shippedSlx());
d = scratchDir('twocfg');
legs = struct('cfg', {cfgA, cfgB}, 'nm', {'TEPC_IdA', 'TEPC_IdB'});
for i = 1:numel(legs)
    [mdl, ~] = tepc.simulink.buildElectronicsModel(legs(i).cfg, d, ...
        struct('modelName', legs(i).nm));
    ident = tepc.simulink.checkParamIdentity(legs(i).cfg, mdl);
    close_system(mdl, 0);
    tc.verifyTrue(ident.ok, sprintf('腿 %d (%s) 与自身 config 不同源: %s', i, legs(i).nm, ...
        strjoin(ident.messages, '; ')));
    tc.verifyTrue(all([ident.rows.bakedOk]), sprintf('腿 %d 有烘进文件的字面量', i));
    fp = tepc.simulink.modelFingerprint(fullfile(d, [mdl, '.slx']));
    tc.verifyEqual(fp.structure, fpShip.structure, ...
        sprintf('腿 %d: 换参数不该改结构指纹', i));
end
end

function test_shipped_file_bytes_untouched_by_a_run(tc)
% 跑一次对照 (参数还与发货配置不同) 不许改发货文件的一个字节。
h0 = tepc.io.hashFile(shippedSlx());
fp0 = tepc.simulink.modelFingerprint(shippedSlx());
cfg = demoCfg();
cfg.electronics.shaping_s = 2.0e-6;
cfg.electronics.sampleTime_s = 1.0e-9;      % 正是过去把发货模型改写成 1 ns 的那组参数
out = tepc.simulink.compareWithMatlab(cfg, 20);
h1 = tepc.io.hashFile(shippedSlx());
fp1 = tepc.simulink.modelFingerprint(shippedSlx());
tc.verifyEqual(h1, h0, sprintf('发货 .slx 被一次仿真重写了: %s -> %s', h0, h1));
tc.verifyEqual(fp1.structure, fp0.structure, '结构指纹被一次仿真改了');
tc.verifyTrue(out.gatePass, sprintf('对照门禁在注入参数下应通过: 峰差 %.3g 面差 %.3g 触发差 %g', ...
    out.maxRelPeak, out.maxRelArea, out.maxTrigSampleDiff));
tc.verifyTrue(out.stepOk, sprintf('采样点数 %d != 注入步长应有的 %d 点', ...
    out.nSamplesSim, out.nSamplesExpected));
end

function test_effective_step_and_lsb_come_from_the_config(tc)
% 从仿真结果反读生效步长与生效量化间隔 (不是再读一遍配置)。
cfg = demoCfg();
cfg.electronics.sampleTime_s = 2.0e-8;
cfg.electronics.adc.bits = 10;
out = tepc.simulink.compareWithMatlab(cfg, 8);
tc.verifyEqual(out.Ts, cfg.electronics.sampleTime_s, 'AbsTol', 0);
tc.verifyTrue(out.stepOk, sprintf('注入 Ts=%g 时模型给了 %d 个点 (应为 %d)', ...
    cfg.electronics.sampleTime_s, out.nSamplesSim, out.nSamplesExpected));
tc.verifyEqual(out.adcLevelStep_V, out.adcLsbCfg_V, 'RelTol', 2e-3, ...
    sprintf('仿真里量化电平间距 %.6g V != 配置 LSB %.6g V', out.adcLevelStep_V, out.adcLsbCfg_V));
end

function test_intentional_structure_change_moves_fingerprint(tc)
% 有意改结构 (多一块) 必须让指纹与文件哈希都动 —— 否则指纹是常量, 上一条"不变"没有意义。
d = scratchDir('struct');
[mdl, ~] = tepc.simulink.buildElectronicsModel(demoCfg(), d, struct('modelName','TEPC_IdStruct'));
sfp = fullfile(d, [mdl, '.slx']);
fp0 = tepc.simulink.modelFingerprint(sfp);
add_block('simulink/Sinks/To Workspace', [mdl '/extra_out'], ...
    'VariableName', 'simExtra', 'SaveFormat', 'Array', 'Position', [700 260 860 300]);
save_system(mdl, sfp);
close_system(mdl, 0);
fp1 = tepc.simulink.modelFingerprint(sfp);
tc.verifyNotEqual(fp1.structure, fp0.structure, '加了一个块而结构指纹没变: 指纹不覆盖结构');
tc.verifyNotEqual(fp1.file, fp0.file, '结构变了而文件 sha256 没变');
end

%% ==================== 反例控制 (每条都必须让门禁变红) ====================

function test_negative_control_baked_literal_goes_red(tc)
d = scratchDir('ncBake');
[mdl, ~] = tepc.simulink.buildElectronicsModel(demoCfg(), d, struct('modelName','TEPC_IdBake'));
cfg = demoCfg();
set_param([mdl '/ADC'], 'SampleTime', '1e-9');       % 把旧的 1 ns 直接写回对话框
ident = tepc.simulink.checkParamIdentity(cfg, mdl);
close_system(mdl, 0);
tc.verifyFalse(ident.ok, '烘入字面量后门禁仍然全绿');
tc.verifyFalse(ident.rows(strcmp({ident.rows.block},'ADC') & ...
    strcmp({ident.rows.dialog},'SampleTime')).bakedOk, 'ADC.SampleTime 的 bakedOk 应为假');
msg = grepMsg(ident.messages, 'ADC');
tc.verifyFalse(isempty(msg), '违规摘要没提到 ADC');
tc.verifySubstring(strjoin(ident.messages, ' | '), '烘进模型');
end

function test_negative_control_stale_injection_goes_red(tc)
cfg = demoCfg();
applyParamsOf(cfg);
ident0 = tepc.simulink.checkParamIdentity(cfg, shippedSlx());
tc.verifyTrue(ident0.ok, sprintf('基线就该绿, 实得: %s', strjoin(ident0.messages, '; ')));
assignin('base', 'TEPC_Ts', 1.0e-9);      % 工作区里留着上一次实验的步长
ident1 = tepc.simulink.checkParamIdentity(cfg, shippedSlx());
msg1 = strjoin(ident1.messages, ' | ');
tc.verifyFalse(ident1.ok, '注入值与配置不符而门禁仍绿');
tc.verifySubstring(msg1, 'TEPC_Ts');
applyParamsOf(cfg);                         % 重新注入 -> 恢复绿
ident2 = tepc.simulink.checkParamIdentity(cfg, shippedSlx());
tc.verifyTrue(ident2.ok, sprintf('恢复注入后仍红: %s', strjoin(ident2.messages, '; ')));
end

function test_negative_control_wrong_symbol_link_goes_red(tc)
d = scratchDir('ncLink');
[mdl, ~] = tepc.simulink.buildElectronicsModel(demoCfg(), d, struct('modelName','TEPC_IdLink'));
set_param([mdl '/CR'], 'SampleTime', 'TEPC_lsb');   % 让 CR 去吃 ADC 的 LSB
ident = tepc.simulink.checkParamIdentity(demoCfg(), mdl);
close_system(mdl, 0);
tc.verifyFalse(ident.ok, '对话框指错符号而门禁仍绿');
tc.verifySubstring(strjoin(ident.messages, ' | '), 'CR.SampleTime');
end

function test_negative_control_uncovered_block_goes_red(tc)
d = scratchDir('ncCover');
[mdl, ~] = tepc.simulink.buildElectronicsModel(demoCfg(), d, struct('modelName','TEPC_IdCover'));
add_block('simulink/Discrete/Unit Delay', [mdl '/ud'], 'Position', [700 160 860 200]);
set_param([mdl '/ud'], 'SampleTime', '1e-9');       % spec 表里没有这个块
ident = tepc.simulink.checkParamIdentity(demoCfg(), mdl);
close_system(mdl, 0);
tc.verifyFalse(ident.ok, '出现未被 spec 覆盖的块而门禁仍绿');
tc.verifyEqual(ident.uncovered, {'ud'}, 'uncovered 没抓到新增块');
end

function test_negative_control_config_drift_goes_red(tc)
% 模型按 A 注入、按 A 跑着, 另一侧 (MATLAB 链) 的成形常数被改成 B —— 拿 B 核 A 必须红。
% 这就是当年"两份真相源"的失效形状: 配置的成形常数与模型生效值不一致。注入设计把
% 不一致从文件字节搬到注入环节, 于是同一份模型服务任何 config 都是安全的, 前提是
% 核完立刻按新 config 重注入 (下面第二条就是这样恢复绿的)。
cfgA = demoCfg();
cfgB = cfgA;
cfgB.electronics.shaping_s = cfgB.electronics.shaping_s * 2;
d = scratchDir('ncDrift');
[mdl, ~] = tepc.simulink.buildElectronicsModel(cfgA, d, struct('modelName','TEPC_IdDrift'));
identA = tepc.simulink.checkParamIdentity(cfgA, mdl);
tc.verifyTrue(identA.ok, sprintf('按 A 注入后按 A 核应为绿, 实得: %s', strjoin(identA.messages, '; ')));
identB = tepc.simulink.checkParamIdentity(cfgB, mdl);
tc.verifyFalse(identB.ok, '配置漂移 (shaping x2) 没被门禁抓到');
msg = strjoin(identB.messages, ' | ');
tc.verifyTrue(contains(msg, 'TEPC_denCR') || contains(msg, 'TEPC_denCSAPZ'), ...
    sprintf('摘要应指向成形极点符号, 实得: %s', msg));
close_system(mdl, 0);
applyParamsOf(cfgB);
identB2 = tepc.simulink.checkParamIdentity(cfgB, fullfile(d, [mdl, '.slx']));
tc.verifyTrue(identB2.ok, sprintf('重注入 B 后按 B 核应绿, 实得: %s', strjoin(identB2.messages, '; ')));
% 阶数漂移: 同一份文件按 1 级核绿之后, 把 shaperOrder 改成 2 再核必须红。
% 这一条在参数侧只算单级 RC 的旧实现下必然绿 —— 两侧同盲, 阶数等于模型侧的第二真相源。
cfgC = demoCfg();
cfgC.electronics.shaperOrder = 2;
identC = tepc.simulink.checkParamIdentity(cfgC, fullfile(d, [mdl, '.slx']));
tc.verifyFalse(identC.ok, ...
    'shaperOrder 1->2 没被抓到: 成形阶数仍是模型侧的第二真相源');
end

%% ==================== 夹具与助手 (首参不是 tc) ====================

function setupOnce(testData) %#ok<INUSD>
% 开跑前把上一次崩溃留下的构建产物清掉 (见 teardownOnce 同一条理由)。
purgeArtifacts();
end

function teardownOnce(testData) %#ok<INUSD>
% Simulink 会在模型所在目录与当前目录落 slprj/ 与 *.slxc 编译缓存。它们是构建产物:
% 留在仓库里会让"仓库文件数"随是否跑过仿真而漂移, 所以收尾时清掉。
for nm = {'TEPC_Electronics', 'TEPC_IdClean', 'TEPC_IdA', 'TEPC_IdB', 'TEPC_IdBake', ...
          'TEPC_IdStruct', 'TEPC_IdLink', 'TEPC_IdCover', 'TEPC_IdDrift'}
    if bdIsLoaded(nm{1})
        close_system(nm{1}, 0);
    end
end
purgeArtifacts();
d = dir(fullfile(tempdir(), 'tepc_slx_ident_*'));
for i = 1:numel(d)
    rmdir(fullfile(d(i).folder, d(i).name), 's');
end
end

function purgeArtifacts()
root = tepc.io.projectRoot();
dirs = {fullfile(root, 'simulink'), fileparts(mfilename('fullpath')), root, pwd};
for i = 1:numel(dirs)
    d = dirs{i};
    if ~isfolder(d), continue; end
    sp = fullfile(d, 'slprj');
    if isfolder(sp), rmdir(sp, 's'); end
    c = dir(fullfile(d, '*.slxc'));
    for j = 1:numel(c)
        delete(fullfile(c(j).folder, c(j).name));
    end
end
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function p = applyParamsOf(cfg)
p = tepc.simulink.applyParams(cfg);
end

function s = shippedSlx()
s = fullfile(tepc.io.projectRoot(), 'simulink', 'TEPC_Electronics.slx');
end

function d = scratchDir(tag)
d = fullfile(tempdir(), ['tepc_slx_ident_' tag]);
if ~isfolder(d), mkdir(d); end
end

function s = listBad(r)
bad = ~[r.bakedOk];
if ~any(bad), s = ''; return; end
s = strjoin(cellfun(@(k) sprintf('%s.%s=[%s]', r(k).block, r(k).dialog, r(k).stored), ...
    find(bad)', 'UniformOutput', false)', ', ');
end

function m = grepMsg(msgs, key)
m = '';
for i = 1:numel(msgs)
    if contains(msgs{i}, key), m = msgs{i}; return; end
end
end
