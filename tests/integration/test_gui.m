function tests = test_gui
%TEST_GUI GUI 自动化测试: 状态机/校验拦截/取消/非法输入/配置收集。
%   除 test_gui_run_completes (长跑) 外全部为纯界面/纯控制器测试, 不启后台作业。
tests = functiontests(localfunctions);
end

function setup(~)
root = tepc.io.projectRoot();
addpath(fullfile(root,'app'));
end

function test_state_machine_transitions(tc)
c = AppController();
tc.verifyEqual(char(c.state()), 'Empty');
tc.verifyTrue(c.canTransition("Configured"));
tc.verifyFalse(c.canTransition("Running"), 'Empty 不能直接 Running');
c.transition("Configured");
tc.verifyEqual(char(c.state()), 'Configured');
c.transition("Validated");
tc.verifyEqual(char(c.state()), 'Validated');
tc.verifyError(@() c.transition("Released"), 'tepc:gui:BadTransition', ...
    'Validated 不能直接 Released');
c.transition("Running");
tc.verifyEqual(char(c.state()), 'Running');
c.transition("Completed");
tc.verifyEqual(char(c.state()), 'Completed');
% 终态必须可回流: 否则一次运行后 [校验配置]/[运行] 永久抛状态机错误 (原缺陷)
tc.verifyTrue(c.canTransition("Configured"), 'Completed 必须能回到 Configured');
tc.verifyTrue(c.canTransition("Validated"), 'Completed 必须能回到 Validated (再次运行)');
tc.verifyTrue(c.canTransition("Running"), 'Completed 必须能直接再 Running');
c.transition("Reviewed");
tc.verifyEqual(char(c.state()), 'Reviewed');
c.transition("Released");
tc.verifyEqual(char(c.state()), 'Released');
tc.verifyTrue(c.canTransition("Configured"), 'Released 不得是死端');
end

function test_paused_can_complete_and_reopen(tc)
% Paused -> Completed 必须在允许表内: 暂停中作业完成是合法路径 (原实现缺失)
c = AppController();
c.transition("Configured"); c.transition("Validated"); c.transition("Running");
c.transition("Paused");
tc.verifyTrue(c.canTransition("Completed"), 'Paused 必须可以 Completed');
c.transition("Completed");
tc.verifyEqual(char(c.state()), 'Completed');
end

function test_pause_reaches_paused_state(tc)
% 暂停必须真的进入/退出 Paused 并同步标志文件 (原实现只写文件 -> 死代码)
c = AppController();
c.transition("Configured"); c.transition("Validated"); c.transition("Running");
tc.verifyFalse(isfile(c.PauseFlagPath), '运行前不得有暂停标志');
c.requestPause(true);
tc.verifyEqual(char(c.state()), 'Paused', 'requestPause(true) 必须进入 Paused');
tc.verifyTrue(isfile(c.PauseFlagPath), '暂停标志文件必须存在 (后台据此挂起)');
c.requestPause(false);
tc.verifyEqual(char(c.state()), 'Running', 'requestPause(false) 必须回到 Running');
tc.verifyFalse(isfile(c.PauseFlagPath), '继续后暂停标志文件必须删除');
c.stopAll();
end

function test_cancel_is_not_reported_as_failure(tc)
% execute 抛的是 tepc:run:CancelRequested; 原实现比对不存在的 'tepc:run:Cancelled'
% -> 每次取消都被判成 Failed。控制器必须按真实标识符分流。
root = tepc.io.projectRoot();
src = fileread(fullfile(root,'app','AppController.m'));
tc.verifyTrue(contains(src, 'tepc:run:CancelRequested'), ...
    'AppController 必须匹配 execute 的真实取消标识符');
c = AppController();
tc.verifyEqual(c.classifyRunError('tepc:run:CancelRequested'), "cancelled");
tc.verifyEqual(c.classifyRunError('tepc:run:ConfigInvalid'), "failed");
tc.verifyEqual(c.classifyRunError(''), "failed");
end

function test_rerun_after_terminal_state_not_blocked(tc)
% 一次运行进入终态后重新校验: 必须回到 Validated 而不是抛 BadTransition
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
c = AppController();
iss = c.readAndValidate(cfg, 'demo_only.json');
% 干净配置的 issues 是空 cell: [{}{:}] 会塌成 0x0 double, 与 string 比较直接抛
% MATLAB:string:ComparisonNotDefined (实测)。cellfun 对空 cell 返回空 logical, 安全。
tc.verifyTrue(iscell(iss), 'readAndValidate 必须返回 cell 问题列表');
nErr = nnz(cellfun(@(s) string(s.level) == "error", iss));
tc.verifyEqual(nErr, 0, '演示配置必须无 error 级问题');
tc.verifyEqual(char(c.state()), 'Validated');
c.transition("Running"); c.transition("Failed");
c.readAndValidate(cfg, 'demo_only.json');
tc.verifyEqual(char(c.state()), 'Validated', 'Failed 后重新校验必须可达 Validated');
c.transition("Running"); c.transition("Cancelled");
c.readAndValidate(cfg, 'demo_only.json');
tc.verifyEqual(char(c.state()), 'Validated', 'Cancelled 后重新校验必须可达 Validated');
c.stopAll();
end

function test_invalidate_blocks_stale_run(tc)
% 校验失败必须作废可用配置, 否则 [运行] 会用旧 cfg 起跑
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
c = AppController();
c.readAndValidate(cfg, 'demo_only.json');
tc.verifyEqual(char(c.state()), 'Validated');
c.invalidate();
tc.verifyEqual(char(c.state()), 'Configured');
tc.verifyError(@() c.startRun(10, []), 'tepc:gui:NotValidated', ...
    '作废后不允许启动运行');
end

function test_validate_blocks_bad_composition(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.Fields.gas_ch4.Value = '0.90';       % 组分和 = 1.26
app.onValidate();
tc.verifyTrue(contains(char(app.Banner.Text), '校验失败'), '非法组分必须被拦截');
tc.verifyNotEqual(char(app.Controller.state()), 'Validated');
end

function test_validate_blocks_non_finite_field(tc)
% 界面数值非法必须明确报错, 不得静默回落到配置文件值 (混合配置缺陷)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.Fields.gas_p.Value = 'abc';
app.Fields.el_tau.Value = 'nan';
app.onValidate();
tc.verifyTrue(contains(char(app.Banner.Text), '校验失败'), '非有限输入必须被拦截');
tc.verifyTrue(contains(char(app.Banner.Text), 'gas_p'), '必须点名出错的界面项');
tc.verifyNotEqual(char(app.Controller.state()), 'Validated');
end

function test_ui_overrides_reach_config(tc)
% 界面 -> 配置 必须真正生效 (原缺陷: run_mode 控件重复且 gatherConfig 从不读取)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.Fields.run_mode.Value = 'VALIDATED';
app.Fields.run_nEvents.Value = '1234';
app.Fields.el_fs.Value = '1.5';
app.Fields.geo_len.Value = '77';
cfg = app.gatherConfig();
tc.verifyEqual(char(string(cfg.run.mode)), 'VALIDATED', 'cfg.run.mode 必须来自界面下拉');
tc.verifyEqual(cfg.run.nEvents, 1234);
tc.verifyEqual(cfg.electronics.adc.fullScale_V, 1.5);
tc.verifyEqual(cfg.geometry.cylinderLength_mm, 77, '有限几何长度必须写入配置');
% VALIDATED + ASSUMED 参数 = 红线; 从界面出发必须能触发
iss = app.Controller.readAndValidate(cfg, 'demo_only.json');
tc.verifyEqual(char(app.Controller.state()), 'Configured', ...
    'VALIDATED 模式含 ASSUMED 必须被拦截');
% {iss.code} 是"装着 string 的 cell", strcmp 对它恒为 false (与 runGate 同一坑),
% 必须用 cellfun + == 才能真的抓到这一码。
tc.verifyTrue(any(cellfun(@(s) string(s.code) == "ASSUMED_IN_VALIDATED", iss)), ...
    '必须报 ASSUMED_IN_VALIDATED (门禁 12 由此可达)');
end

function test_geometry_cylinder_finite_is_usable(tc)
% cylinder_finite 需要 cylinderLength_mm: 界面补该字段后不得再抛 MissingLength
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.Fields.geo_type.Value = 'cylinder_finite';
app.Fields.geo_len.Value = '120';
cfg = app.gatherConfig();
tc.verifyEqual(char(string(cfg.geometry.type)), 'cylinder_finite');
g = tepc.geometry.buildGeometry(cfg);                        % 原来在此抛 MissingLength
tc.verifyEqual(cfg.geometry.cylinderLength_mm, 120);
R = tepc.config.resolve(cfg);
tc.verifyTrue(isfinite(R.geom.lbar_gas_m) && R.geom.lbar_gas_m > 0, '有限圆柱应有有限 lbar');
end

function test_gather_config_uses_selected_file(tc)
% gatherConfig 必须按界面选中的配置文件加载 (原实现硬编码 demo_only.json)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
cfg.analysis.nBins = 37;                 % 界面无此控件 -> 只能来自所选文件
cfg.gas.pressure_Pa = 5000;              % 界面有该控件 -> 界面值必须胜出
p = fullfile(tempdir, sprintf('tepc_gui_cfg_%d.json', randi(1e9)));
tepc.io.writeJson(p, cfg);
cleanupObj = onCleanup(@() delete(p));
app = TEPCApp(false);
cleanupApp = onCleanup(@() delete(app));
app.Fields.cfg_path.Value = p;
got = app.gatherConfig();
tc.verifyEqual(got.analysis.nBins, 37, '必须读取选中的配置文件 (而非 nBins=120 的 demo 文件)');
tc.verifyEqual(got.gas.pressure_Pa, 1000, '界面值必须覆写选中文件中的 5000 Pa');
% 配置文件不存在 -> 明确报错并作废配置, 不得回落到默认文件
app.Fields.cfg_path.Value = fullfile(tempdir, 'tepc_definitely_missing_xyz.json');
tc.verifyError(@() app.gatherConfig(), 'tepc:gui:NoConfigFile');
app.onValidate();
tc.verifyTrue(contains(char(app.Banner.Text), '校验失败'));
end

function test_empty_numeric_field_rules(tc)
% 空数值格的两条口径必须同时成立: 配置文件本来没有这一项 (球形无柱长) 时不注入、不报错;
% 配置里有值而格被用户清空时必须报错。只留一条就会把另一种情况一起放过。
root = tepc.io.projectRoot();
app = TEPCApp(false);
cleanupApp = onCleanup(@() delete(app));

cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
tc.verifyEqual(char(string(cfg.geometry.type)), 'sphere', '本用例的前提: demo 配置是球形');
tc.verifyFalse(isfield(cfg.geometry, 'cylinderLength_mm'), '前提: 球形配置里没有柱长');
p = fullfile(tempdir, sprintf('tepc_gui_cfg_emptyrule_%d.json', randi(1e9)));
tepc.io.writeJson(p, cfg);
cleanupObj = onCleanup(@() delete(p));
app.Fields.cfg_path.Value = p;
app.onLoadConfig();
tc.verifyTrue(isempty(strtrim(char(string(app.Fields.geo_len.Value)))), ...
    '配置无柱长项时卡片应停在空值 (不伪造数字)');
got = app.gatherConfig();                       % 不得因为"空"而抛 BadField
tc.verifyFalse(isfield(got.geometry, 'cylinderLength_mm'), ...
    '收集后的配置仍不得出现柱长键 —— 跳过不等于造一个值');

% 负控 1: 配置里确实有该项 (gasRadius_mm), 把格清空 -> 非法输入, 必须点名报错
app.Fields.geo_R.Value = '';
tc.verifyError(@() app.gatherConfig(), 'tepc:gui:BadField');
app.Fields.geo_R.Value = '25.4';

% 负控 2: 换成带柱长的柱形配置, 控件却是空的 -> 同样必须报错
cfg2 = cfg;
cfg2.geometry.type = 'cylinder_finite';
cfg2.geometry.cylinderLength_mm = 120;
p2 = fullfile(tempdir, sprintf('tepc_gui_cfg_cyl_%d.json', randi(1e9)));
tepc.io.writeJson(p2, cfg2);
cleanupObj2 = onCleanup(@() delete(p2));
app.Fields.cfg_path.Value = p2;
app.onLoadConfig();
tc.verifyEqual(strtrim(char(string(app.Fields.geo_len.Value))), '120', ...
    '柱形配置应把柱长回填进卡片');
app.Fields.geo_len.Value = '';
tc.verifyError(@() app.gatherConfig(), 'tepc:gui:BadField');
app.Fields.geo_len.Value = 'abc';
tc.verifyError(@() app.gatherConfig(), 'tepc:gui:BadField');
end

function test_on_load_config_backfills_all_fields(tc)
% [载入配置] 必须回填全部可编辑字段 (原实现只回填 7 个 -> 混合配置)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
cfg.gas.temperature_K = 288.5;
cfg.electronics.adc.bits = 16;
cfg.electronics.trigger.pileUpReject_s = 4.5e-6;
cfg.electronics.waveWindow_s = 3.25e-5;
cfg.source.arrivalModel = "fixed";
cfg.site.equivalenceMode = "requested";
p = fullfile(tempdir, sprintf('tepc_gui_cfg2_%d.json', randi(1e9)));
tepc.io.writeJson(p, cfg);
cleanupObj = onCleanup(@() delete(p));
app = TEPCApp(false);
cleanupApp = onCleanup(@() delete(app));
app.Fields.cfg_path.Value = p;
app.onLoadConfig();
tc.verifyEqual(app.Fields.gas_T.Value, '288.5');
tc.verifyEqual(app.Fields.el_bits.Value, '16');
tc.verifyEqual(app.Fields.el_pu.Value, '4.5e-06');
tc.verifyEqual(app.Fields.el_wwin.Value, '3.25e-05');
tc.verifyEqual(app.Fields.src_arr.Value, 'fixed');
tc.verifyEqual(app.Fields.site_mode.Value, 'requested');
% 回填后收集的值必须与文件一致 (加载/收集往返闭合)
got = app.gatherConfig();
tc.verifyEqual(got.gas.temperature_K, 288.5);
tc.verifyEqual(got.electronics.adc.bits, 16);
tc.verifyEqual(got.electronics.trigger.pileUpReject_s, 4.5e-6);
tc.verifyEqual(got.electronics.waveWindow_s, 3.25e-5);
tc.verifyEqual(char(string(got.source.arrivalModel)), 'fixed');
tc.verifyEqual(char(string(got.site.equivalenceMode)), 'requested');
end

function test_gui_launcher_works_from_foreign_folder(tc)
% tepc_gui 是 GUI 的唯一入口: 它必须自己建 src/+app 路径并切到仓库根目录
% (默认配置文件是**相对**路径 config/defaults/demo_only.json)。
% 只按 README 旧写法 addpath('app') 会在点 [校验配置] 时报"无法识别的名称 'tepc'"。
root = tepc.io.projectRoot();
old = pwd;
cleanup = onCleanup(@() cd(old));
addpath(root);
cd(tempdir);                            % 故意从无关目录启动
app = tepc_gui(false);
cleanupApp = onCleanup(@() delete(app));
tc.verifyEqual(pwd, root, '启动后当前目录必须是仓库根 (配置框是相对路径)');
app.onValidate();
tc.verifyEqual(char(app.Controller.state()), 'Validated', ...
    sprintf('从外部目录启动后校验必须能通过, 横幅=%s', char(app.Banner.Text)));
tc.verifyEqual(char(app.Fields.cfg_path.Value), 'config/defaults/demo_only.json');
end

function test_validate_passes_demo(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.onValidate();
% 代码缺陷不得伪装成"配置校验失败": 曾有不存在的函数 capitalize() 在绘图段抛错,
% 被外层 catch 吞成红色横幅, 状态机停在 Configured, 根因在测试输出里完全看不见。
btxt = string(app.Banner.Text);
tc.verifyFalse(contains(btxt, "校验异常") || contains(btxt, "配置校验失败"), ...
    sprintf('onValidate 不得有未捕获错误, 横幅=%s', char(btxt)));
tc.verifyEqual(char(app.Controller.state()), 'Validated');
end

function test_site_mismatch_warning_banner(tc)
% 只有 requested 模式才存在"请求位点与温压不自洽"的矛盾;
% 发货默认 derived 模式下位点由温压导出 -> 自洽, 不得再报矛盾。
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.Fields.site_mode.Value = 'requested';
app.Fields.cfg_path.Value = fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json');
app.onValidate();   % demo 参数: 1000 Pa vs 2 um -> 橙色横幅
txt = strjoin(string(app.Fields.geom_out.Value), ' ');
tc.verifyTrue(contains(char(app.Banner.Text), '演示参数矛盾'), 'requested 下位点矛盾须橙色警报');
tc.verifyTrue(contains(txt, '位点模式 = requested'), '派生量面板须标明位点模式');
end

function test_derived_site_mode_is_not_flagged_as_contradiction(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.onValidate();
txt = strjoin(string(app.Fields.geom_out.Value), ' ');
tc.verifyFalse(contains(char(app.Banner.Text), '演示参数矛盾'), 'derived 模式不应报参数矛盾');
tc.verifyTrue(contains(txt, 'derived'), '派生量面板应显示 derived 模式与实现位点');
tc.verifyTrue(contains(txt, '实现位点'), '派生量面板应给出实现位点直径');
end

function test_spectrum_mode_redraws_from_last_result(tc)
% 谱模式下拉必须真正重绘 (原实现 nargin<2 直接 return -> 死控件)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.redrawSpectrum();                       % 无结果: 不得抛错, 只给提示
tc.verifyTrue(contains(strjoin(string(app.Fields.spec_out.Value), ' '), '尚无结果'));
edges = logspace(log10(0.05), log10(200), 41);
S = tepc.analysis.buildSpectrum(2 + 30*rand(5000,1), 6.6667, ones(5000,1), edges);
R = struct();
R.analysis = struct('spectrum', S);
R.summary = struct('runID','fake','config_sha256',repmat('0',1,64), 'seed',1, ...
    'nEvents',5000, 'resumed_from',0, 'yF_keV_um',5.2, 'yD_keV_um',7.9, 'Qbar',"NA", ...
    'D_gas_Gy',5e-6, 'D_gas_per_event_Gy',1e-9, ...
    'D_tissue_Gy',1.2e-9, 'D_tissue_per_event_Gy',2.4e-13, ...
    'nEff',4800, 'liveFrac',0.98, 'zeroDep_fraction',0.31, ...
    'threshold_lost_count',120, 'threshold_lost_fraction',120/5000, ...
    'published_moment_population',"过阈且测量有效的事件 (阈下事件按零权重排除)", ...
    'n_published_moments',3400, ...
    'instrument_chain',true, 'n_meas_valid',3400, 'yF_truth_keV_um',5.1, ...
    'instr_bias_yF',0.02, 'site_realized_d_tissue_um',2.4, ...
    'site_requested_d_tissue_um',2.0, 'site_equivalence_mode',"derived");
R.runDir = struct('results', tempdir);
R.gates = struct('items', struct('name','示例门禁','status',"PASS",'value',1e-6, ...
    'detail','ok'), 'nFail',0, 'nWarn',0, 'nNotEvaluated',1, ...
    'computational_gates_passed',true, 'release_eligible',false, 'watermark',"VALID(FOR DEMO)");
app.showResult(R);
tc.verifyEqual(app.AxSpectrum.YScale, 'log', '默认模式为对数 y d(y)');
nLine = countLineObjs(app);
tc.verifyGreaterThan(nLine, 0, 'showResult 必须画出谱线');
tc.verifyTrue(any(contains(string(app.Fields.spec_out.Value), '反演有效事件 3400/5000')), ...
    '应显示仪器链启用与有效事件数');
% 过阈份额必须**同屏**披露: 阈下事件按零权重排除, 只看 n_eff/liveFrac 看不出有多少事件
% 根本没进矩。三个数(总体口径 / 过阈份额 / 被剔数)都要在文本里, 缺一个就还原成含糊披露。
txtSpec = strjoin(string(app.Fields.spec_out.Value), ' | ');
tc.verifyTrue(contains(txtSpec, '矩的总体'), '谱页没写矩建在哪个事件群上');
tc.verifyTrue(contains(txtSpec, '过阈 97.6000%'), ...
    sprintf('过阈份额没按 1-threshold_lost_fraction 印出来 (屏上文本: %s)', txtSpec));
tc.verifyTrue(contains(txtSpec, '阈下剔 120/5000'), '被剔事件数与总数没同时给');
tc.verifyTrue(contains(txtSpec, '进矩 3400'), '进矩事件数没发布到屏上');
% "同屏"的另一半: 预留高度必须装得下实际行数。uitextarea 溢出时静默转滚动,
% 屏幕上少一行就等于少一项披露 —— 只核文字内容的那几条判据看不见这件事。
nSpecLine = numel(app.Fields.spec_out.Value);
tc.verifyGreaterThan(nSpecLine, 4, ...
    sprintf('满负荷应有 8 行, 实得 %d 行: 前面的 isfield 分支没进, 高度判据会空转', nSpecLine));
rowH = app.Fields.spec_out.Parent.RowHeight{1};
tc.verifyGreaterThan(double(rowH), 14*nSpecLine, sprintf( ...
    '谱页文本框预留 %.0f px < %d 行 × 14 px: 多出的行只进滚动区, 该披露在屏幕上看不见', ...
    double(rowH), nSpecLine));
app.Fields.spec_mode.Value = '线性 y f(y)';
app.redrawSpectrum();                       % 无参调用: 必须用 LastResult 重绘
tc.verifyEqual(app.AxSpectrum.YScale, 'linear', '切换模式必须重绘 (不得直接返回)');
tc.verifyGreaterThan(countLineObjs(app), 1, '线性模式应画出数据与误差棒');
end

function test_visible_text_fits_its_cell(tc)
% 只有可见窗口才排版: 'Visible',false 时 MATLAB 不做布局, 控件停在默认 [100 100 31 22],
% 拿那种状态量宽度会得到恒绿的"0 违规" (本机实测)。
app = TEPCApp(true);
cleanupObj = onCleanup(@() delete(app));
drawnow; pause(1.0); drawnow;
fig = app.UIFigure;

% --- 探针自检: 同一串重复量必须逐位一致, 加长必须变宽 (否则下面全部判据失去意义) ---
fs = app.Chips{1}.Label.FontSize;
fn = app.Chips{1}.Label.FontName;
ia = app.Chips{1}.Label.Interpreter;
wA = natWidth(fig, '短文字 abc', fs, fn, ia);
wA2 = natWidth(fig, '短文字 abc', fs, fn, ia);
wLong = natWidth(fig, '短文字 abc 长得多得多得多', fs, fn, ia);
tc.verifyEqual(wA2, wA, 'AbsTol', 0, '自然宽探针不可复现');
tc.verifyGreaterThan(wLong, wA + 15, sprintf( '自然宽探针不随文本变长 (%.2f -> %.2f): 这条锁是恒绿装饰', wA, wLong));

% --- 状态带: 六席自然宽之和 (含列间距) 必须留在带内 ---
sp = app.Strip.ColumnSpacing;
if numel(sp) >= 2, sp = double(sp(2)); else, sp = 4; end
sumW = 0;
for i = 1:numel(app.Chips)
    lb = app.Chips{i}.Label;
    if i > 1, sumW = sumW + sp; end
    sumW = sumW + natWidth(fig, string(lb.Text), lb.FontSize, lb.FontName, lb.Interpreter, lb.FontWeight);
end
tc.verifyLessThanOrEqual(sumW, app.Strip.Position(3), sprintf('六席自然宽 %.1f px > 带内可用 %.1f px: 整排出窗', sumW, app.Strip.Position(3)));

% --- 反例腿: 判据必须抓得到已知的出窗态 (实测压力态右边界 1810.9 > 1224) ---
keep = cell(1, numel(app.Chips));
padWord = repmat('字', 1, 12);
for i = 1:numel(app.Chips)
    keep{i} = app.Chips{i}.Label.Text;
    txtK = char(keep{i});
    app.Chips{i}.Label.Text = [padWord txtK];
end
drawnow; pause(0.8); drawnow;
sumS = 0;
for i = 1:numel(app.Chips)
    lb = app.Chips{i}.Label;
    if i > 1, sumS = sumS + sp; end
    sumS = sumS + natWidth(fig, string(lb.Text), lb.FontSize, lb.FontName, lb.Interpreter, lb.FontWeight);
end
tc.verifyGreaterThan(sumS, app.Strip.Position(3), sprintf('压力态仍不报越界 (%.1f <= %.1f): 正判据抓不到出窗', sumS, app.Strip.Position(3)));
for i = 1:numel(app.Chips), app.Chips{i}.Label.Text = keep{i}; end
drawnow; pause(0.5); drawnow;

% --- 每页可见非空标签: 单行自然宽 <= 所在格宽 ---
tabs = app.Tabs.Children;
% 覆盖下限取自实测分布 (10-05 12:28, _工作底稿/z635_textfit.log:4-13):
%   页 1..9 的可见非空未折行标签数 = 6 / 50 / 3 / 5 / 13 / 0 / 0 / 2 / 1, 合计 80。
% 逐页给下限而不是只给一个全局阈值: 上一版 `nChk > 40` 是全局计数, 整页标签消失也照样绿。
minPerTab = [1 10 1 1 5 0 0 1 1];
layKeys = {};
laySum = [];
tabChk = zeros(1, numel(tabs));
tabBad = zeros(1, numel(tabs));
wrapExcl = 0;
for t = 1:numel(tabs)
    app.Tabs.SelectedTab = tabs(t);
    drawnow; pause(0.5); drawnow;
    ob = findall(tabs(t), 'Type', 'uilabel');
    for i = 1:numel(ob)
        lb = ob(i);
        if ~lb.Visible, continue; end
        s0 = strrep(string(lb.Text), newline, ' ');
        if strlength(strtrim(s0)) == 0, continue; end
        if strcmpi(char(lb.WordWrap), 'on')
            wrapExcl = wrapExcl + 1;
            continue;
        end
        tabChk(t) = tabChk(t) + 1;
        natW = natWidth(fig, s0, lb.FontSize, lb.FontName, lb.Interpreter, lb.FontWeight);
        if natW > lb.Position(3) + 1.0
            tabBad(t) = tabBad(t) + 1;
        end
        % 'fit' 列会把列宽给到文字刚好要求的宽度, 于是"自然宽 <= 所在格宽"在那些标签上
        % 是恒等式 (实测 79 个里有 49 个如此)。真正的溢出形态是 fit 列合计超过网格本身,
        % 所以这里只按网格累计落在 'fit' 列上的自然宽。
        if isFitColumn(lb, lb.Layout.Column)
            [layKeys, laySum] = addFit(layKeys, laySum, lb.Parent, natW);
        end
    end
    msg = sprintf('页 %d 只有 %d 个标签被测到 (实测下限 %d): 覆盖面在静默缩水, "0 溢出"就成了空集上的真', t, tabChk(t), minPerTab(t));
    tc.verifyGreaterThanOrEqual(tabChk(t), minPerTab(t), msg);
end
% --- fit 列行合计: 合计超过网格宽就是整排挤出面板 (逐格比较抓不到这一形态) ---
nFitGrid = 0;
fitBad = strings(0, 1);
for g = 1:numel(layKeys)
    lay = layKeys{g};
    if ~isvalid(lay), continue; end
    if laySum(g) <= 0, continue; end
    nFitGrid = nFitGrid + 1;
    if laySum(g) > lay.Position(3) + 2.0
        fitBad(end+1) = sprintf('网格 %d 的 fit 列自然宽合计 %.0f px > 网格宽 %.0f px', ...
            g, laySum(g), lay.Position(3)); %#ok<AGROW>
    end
end
tc.verifyGreaterThanOrEqual(nFitGrid, 1, ...
    '一个含 fit 列标签的网格都没扫到: 行合计判据落在空集上');
tc.verifyEmpty(fitBad, sprintf('fit 列合计越界 (%s): 文字排到面板外', strjoin(fitBad, '; ')));
% 反例腿: 200 px 的面板里塞两个各需 ~250 px 的 fit 列标签, 行合计判据必须报;
% 同一面板换成一个短标签必须不报。
hostFit = uipanel(fig, 'Position', [10 10 200 40]);
gFit = uigridlayout(hostFit, [1 2], 'ColumnWidth', {'fit', 'fit'});
lbF1 = uilabel(gFit, 'Text', repmat('宽', 1, 18), 'WordWrap', 'off', 'Interpreter', 'none');
lbF2 = uilabel(gFit, 'Text', repmat('宽', 1, 18), 'WordWrap', 'off', 'Interpreter', 'none');
drawnow; pause(0.6); drawnow;
sumF = natWidth(fig, string(lbF1.Text), lbF1.FontSize, lbF1.FontName, lbF1.Interpreter, lbF1.FontWeight) + ...
       natWidth(fig, string(lbF2.Text), lbF2.FontSize, lbF2.FontName, lbF2.Interpreter, lbF2.FontWeight);
tc.verifyGreaterThan(sumF, gFit.Position(3) + 2.0, sprintf(...
    '注入没造出越界 (合计 %.0f px vs 网格 %.0f px): 反例腿空转', sumF, gFit.Position(3)));
delete(gFit); delete(lbF1); delete(lbF2);
hostFit2 = uipanel(fig, 'Position', [10 10 200 40]);
gFit2 = uigridlayout(hostFit2, [1 1], 'ColumnWidth', {'fit'});
lbF3 = uilabel(gFit2, 'Text', '短标签', 'WordWrap', 'off', 'Interpreter', 'none');
drawnow; pause(0.6); drawnow;
sumC = natWidth(fig, string(lbF3.Text), lbF3.FontSize, lbF3.FontName, lbF3.Interpreter, lbF3.FontWeight);
tc.verifyLessThanOrEqual(sumC, gFit2.Position(3) + 2.0, ...
    sprintf('健康对照 (合计 %.0f px) 也被判越界: 判据过严', sumC));
delete(gFit2); delete(lbF3); delete(hostFit2); delete(hostFit);
drawnow;

tc.verifyEqual(sum(tabBad), 0, sprintf(...
    '逐页溢出计数 %s: 有标签的单行自然宽超出所在格, 文字会压到邻居', mat2str(tabBad)));
% 逃逸口要显式报数: 一旦有人给标签开折行, 本判据就不再覆盖它, 必须让人看见这件事。
if wrapExcl > 0
    tc.verifyTrue(false, sprintf(...
        '%d 个标签开了折行而被本判据排除: 竖向撑高需要另一条判据, 不许静默通过', wrapExcl));
end

% --- 反例腿: 同一个检测器必须能报出注入出来的溢出, 且正常输入不误报 ---
hostInj = uipanel(fig);
gInj = uigridlayout(hostInj, [2 1], 'ColumnWidth', {60}, 'RowHeight', {20 20});
lbInj = uilabel(gInj, 'Text', repmat('宽', 1, 30), 'WordWrap', 'off', 'Interpreter', 'none');
lbOk = uilabel(gInj, 'Text', '短', 'WordWrap', 'off', 'Interpreter', 'none');
lbInj.Layout.Row = 1;
lbOk.Layout.Row = 2;
drawnow; pause(0.6); drawnow;
lbArr = [lbInj, lbOk];
badInj = 0;
injWid = zeros(1, 2);
for k = 1:numel(lbArr)
    lbk = lbArr(k);
    natK = natWidth(fig, string(lbk.Text), lbk.FontSize, lbk.FontName, lbk.Interpreter, lbk.FontWeight);
    injWid(k) = natK;
    if natK > lbk.Position(3) + 1.0
        badInj = badInj + 1;
    end
end
msgInj = sprintf('注入应恰好造出 1 个溢出, 实得 %d (自然宽 %s vs 格宽 %.1f): 检测器或注入本身失效, 正判据无从信任', badInj, mat2str(injWid), lbInj.Position(3));
tc.verifyEqual(badInj, 1, msgInj);
delete(gInj); delete(hostInj); drawnow;

% --- 根级文本面: Banner 与 StatusLabel 在 tabs 之外, findall(tabs(...)) 永远到不了 ---
% 折行的控件不能一跳了事: 它的失败形态从"横向出窗"变成"竖向被裁", 必须换成折行高度神谕判。
rootLb = [app.Banner, app.StatusLabel];
nRoot = 0;
for k = 1:numel(rootLb)
    lbR = rootLb(k);
    sTxt = strrep(string(lbR.Text), newline, ' ');
    if strlength(strtrim(sTxt)) == 0 || ~lbR.Visible, continue; end
    nRoot = nRoot + 1;
    if strcmpi(char(lbR.WordWrap), 'on')
        need = wrapHeight(fig, sTxt, lbR.FontSize, lbR.FontName, lbR.Interpreter, ...
            lbR.FontWeight, lbR.Position(3));
        tc.verifyGreaterThanOrEqual(lbR.Position(4), need - 1.0, sprintf( ...
            '根级文本控件 %d 折行后需要 %.1f px 高, 实得 %.1f px: 后半句被竖向裁掉', ...
            k, need, lbR.Position(4)));
    else
        natR = natWidth(fig, sTxt, lbR.FontSize, lbR.FontName, lbR.Interpreter, lbR.FontWeight);
        tc.verifyLessThanOrEqual(natR, lbR.Position(3) + 1.0, sprintf( ...
            '根级文本控件 %d 的单行自然宽 %.1f px 超出所在格 %.1f px: 告警文字会压出去', ...
            k, natR, lbR.Position(3)));
    end
end
tc.verifyGreaterThanOrEqual(nRoot, 1, '根级一个非空文本控件都没量到: 这条腿落在空集上');

% --- 长告警实弹: 横幅是红线披露的唯一出口, 必须按"能装下最长那条"判 ---
msgLong = "配置校验失败: " + strjoin(repmat({char("gas.transport.mu_e 超出域 [0.1, 20] m^2/(V·s)")}, 1, 5), " | ") + ...
    " | source.coneHalfAngle_deg 必须是 (0, 90] 内的数 | field.hv_V 与 driftCollect 不自洽";
app.setBanner('red', msgLong);
drawnow; pause(0.8); drawnow;
txtB = strrep(string(app.Banner.Text), newline, ' ');
natB = natWidth(fig, txtB, app.Banner.FontSize, app.Banner.FontName, app.Banner.Interpreter, app.Banner.FontWeight);
% 先证明这一发确实是"单行装不下"的压力态, 否则下面那条断言是空跑
tc.verifyGreaterThan(natB, app.Banner.Position(3) + 1.0, sprintf( ...
    '长告警的自然宽 %.1f px 没超过横幅控件宽 %.1f px: 压力态没造出来, 折行判据没被行使', ...
    natB, app.Banner.Position(3)));
needB = wrapHeight(fig, txtB, app.Banner.FontSize, app.Banner.FontName, app.Banner.Interpreter, ...
    app.Banner.FontWeight, app.Banner.Position(3));
tc.verifyGreaterThanOrEqual(app.Banner.Position(4), needB - 1.0, sprintf( ...
    '长告警下横幅需要 %.1f px 高才装得下, 实得 %.1f px: 后半句被裁掉, 红线披露静默丢失', ...
    needB, app.Banner.Position(4)));
tc.verifyFalse(isempty(strtrim(char(string(app.Banner.Tooltip)))), ...
    '横幅没有 Tooltip: 一旦文案被裁, 全文就没有第二个出口');
% 撑高横幅之后, 下面的页签区不许被压成零高或负高
tc.verifyGreaterThan(app.Tabs.Position(4), 200, sprintf( ...
    '长告警把页签区压到 %.1f px: 横幅的代价不许是别处看不见', app.Tabs.Position(4)));
app.setBanner('blue', '就绪。');
drawnow; pause(0.5); drawnow;

% --- Tooltip parity: 席宽受限后, 提示是全文的唯一出口 ---
miss = 0;
for i = 1:numel(app.Chips)
    tip = strtrim(char(string(app.Chips{i}.Label.Tooltip)));
    if isempty(tip), miss = miss + 1; end
end
tc.verifyEqual(miss, 0, sprintf('%d 个席位没有 Tooltip: 文案被限制后全文无处可取', miss));
natReset();
end

function w = natWidth(fig, txt, fs, fname, interp, fweight)
% 单个复用探针 (字重必须一起复制: 粗体的自然宽比常规体宽, 漏掉它会把出窗量成不出窗): 一个 'fit' 列里的 uilabel, 其宽度就是 MATLAB 认定的单行自然宽。
% 探针常驻是因为逐标签新建面板要 80 次布局, 在慢机上会把这条锁拖成十几分钟。
if nargin < 6, fweight = 'normal'; end
persistent hp g pb
if isempty(hp) || ~isvalid(hp)
    hp = uipanel(fig);
    g = uigridlayout(hp, [1 1], 'ColumnWidth', {'fit'});
    pb = uilabel(g);
end
pb.Text = txt;
pb.FontSize = fs;
pb.FontName = fname;
pb.Interpreter = interp;
pb.FontWeight = fweight;
% 'fit' 列要等布局跑完才给出自然宽: 控件刚建好时读到的是默认的 31 px, 换了文本后第一次读到的
% 又可能是**上一条文本**留下的旧宽 (本机实测: 31 vs 71.84; 以及短/长两串都读成 71.84)。
% 所以取"至少过 3 帧布局之后、且连续两帧不再变化"的那个宽度。
wq = pb.Position(3);
wprev = NaN;
for q = 1:12
    drawnow; pause(0.08); drawnow;
    wprev = wq;
    wq = pb.Position(3);
    if q >= 3 && wq == wprev, break; end
end
w = wq;
end

function h = wrapHeight(fig, txt, fs, fname, interp, fweight, widthPx)
% 折行高度神谕: 在与被测控件同宽的定值列 + 'fit' 行高里放一个同样字体的折行 uilabel,
% 它给出的高度就是 MATLAB 自己认定"这段文字在这个宽度下要多高"。控件比它矮即被裁。
% 'auto' 关键字本机 R2025a 被 uigridlayout 拒绝 (只认 数值/'fit'/'1x'/'2x'), 故用 'fit'。
persistent wp wg wpp
if isempty(wp) || ~isvalid(wp)
    wp = uipanel(fig);
    wpp = uilabel(uigridlayout(wp, [1 1], 'ColumnWidth', {100}, 'RowHeight', {'fit'}));
    wg = wpp.Parent;
end
wpp.Text = txt;
wpp.FontSize = fs;
wpp.FontName = fname;
wpp.Interpreter = interp;
wpp.FontWeight = fweight;
wpp.WordWrap = 'on';
wg.ColumnWidth{1} = max(20, round(widthPx));
hq = wpp.Position(4);
prevH = NaN;
for q = 1:12
    drawnow; pause(0.08); drawnow;
    prevH = hq;
    hq = wpp.Position(4);
    if q >= 3 && hq == prevH, break; end
end
h = hq;
end

function natReset()
persistent hp g pb
if ~isempty(hp) && isvalid(hp)
    delete(g); delete(hp);
end
clear hp g pb
persistent wp wg wpp
if ~isempty(wp) && isvalid(wp)
    delete(wg); delete(wp);
end
clear wp wg wpp
end

function n = countLineObjs(app)
% 只数 axes 里的"数据图元"。两条实测理由:
%   1) Title/XLabel/YLabel/Legend 也在 Children 里, 直接数个数会把装饰算进来;
%   2) errorbar 画出来的是 matlab.graphics.chart.primitive.ErrorBar, 其 Type 是
%      'errorbar' 而不是 'line' —— 只认 'line' 会永远漏掉误差棒, 使"线性模式画出
%      数据+误差棒"这条断言恒为 1 (伪失败)。
n = 0;
ch = app.AxSpectrum.Children;
for i = 1:numel(ch)
    if isvalid(ch(i)) && startsWith(class(ch(i)), 'matlab.graphics.chart.primitive.')
        n = n + 1;
    end
end
end

function test_stopall_keeps_cancel_flag_while_job_live(tc)
% 关窗时若作业仍在跑, 取消标志必须**留下**: parfeval 开跑后 cancel() 无效, 而
% execute 唯一的让出点是轮询该文件。旧实现随后无条件 clearFlags() 把它删掉,
% 于是关掉窗口的作业继续跑到底并把 STATUS.json 写成 COMPLETED (幽灵作业)。
c = AppController();
c.transition("Configured"); c.transition("Validated"); c.transition("Running");
c.stopAll();
tc.verifyTrue(isfile(c.CancelFlagPath), '状态仍为 Running 时不得删除取消标志');
tc.verifyEqual(char(c.state()), 'Cancelled');
tc.verifyTrue(isempty(c.Future));
if isfile(c.CancelFlagPath), delete(c.CancelFlagPath); end
end

function test_close_request_cleans_timers_and_flags(tc)
% 关窗后 timer/DataQueue/后台作业/标志文件必须全部清理 (原缺陷: 无 CloseRequestFcn)
app = TEPCApp(false);
tc.verifyFalse(isempty(app.UIFigure.CloseRequestFcn), '必须安装 CloseRequestFcn');
app.startPolling();
tc.verifyTrue(app.PollActive);
app.Controller.requestCancel();
tc.verifyTrue(isfile(app.Controller.CancelFlagPath));
app.onCloseRequest();
tc.verifyTrue(app.Closed);
tc.verifyFalse(app.PollActive, '关窗必须停止轮询');
tc.verifyTrue(isempty(app.PollTimer), 'timer 对象必须删除');
tc.verifyFalse(isfile(app.Controller.CancelFlagPath), '标志文件必须清理');
tc.verifyTrue(isempty(app.Controller.Future), '后台作业句柄必须撤销');
% 关窗后残留回调不得再写已失效控件 (原实现二次异常)
app.pollRun();
app.log('关窗后的日志');
app.setBanner('red', '不应抛错');
app.redrawSpectrum();
app.onProgress(0.5, 'x');
end

function test_cancel_flag_stops_run(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
cflag = fullfile(tempdir, sprintf('tepc_gui_cancel_%d.flag', randi(1e9)));
fid = fopen(cflag, 'w'); fwrite(fid, 'c'); fclose(fid);
tc.verifyError(@() tepc.run.execute(cfg, 'N', 2000, 'CancelFlag', cflag), ...
    'tepc:run:CancelRequested');
delete(cflag);
end

function test_gui_run_completes(tc) %#ok<MANU>
    % TestTag: LongRunning (需进程池, Quick 套件排除, 单独运行)
% 端到端: GUI 控制器后台运行 600 事件并完成 (进程池/线程池均可)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.onValidate();
app.Fields.run_nEvents.Value = '600';
% 前置条件必须由本用例自己建立: 后台 Run 要求进程池存在, 而池可能根本还没起
% (冷会话) 或已被上一个用例关掉。实测症状: 横幅给的是"无法启动: 尚无并行池"、
% Controller 状态停在 Validated, 于是作业从未开始, 进度文件也永远不会出现,
% 失速判据只能报"真卡住" —— 那是判据在替一个缺失的前置条件背锅。
poolReady = false;
poolMsg = '';
tpool = tic;
while ~poolReady && toc(tpool) < 150
    try
        p = gcp();
        nw = 0; ni = -1;
        if isprop(p, 'NumWorkers'), nw = double(p.NumWorkers); end
        if isprop(p, 'NumIdleWorkers'), ni = double(p.NumIdleWorkers); end
        % 空闲 worker 是加分项而不是硬门: 属性名不确定时**不许**让它抛 ——
        % noSuchMethodOrField 会被本 try 吞成"永远不就绪", 白等满 150 s 再照样
        % onRun (本轮 30 秒探针实测就是这个形状: POOL_THREW MATLAB:noSuchMethodOrField)。
        poolReady = nw > 0 && (ni < 0 || ni > 0);
        if ~poolReady
            poolMsg = sprintf('池 workers=%d idle=%d', nw, ni);
            pause(2);
        end
    catch e
        poolMsg = sprintf('%s: %s', e.identifier, e.message);
        % 实测: 空闲内存低于 ~0.3 GB 时 parpool('Processes',1) 直接抛
        % parallel:cluster:PoolRunValidation —— 那是"起不来"而不是"还在起",
        % 再等 150 s 不会变好, 立刻退出等待并把真因带进后面的判定。
        if contains(e.identifier, 'PoolRunValidation')
            break
        end
        pause(2);
    end
end
app.onRun();
% 后台 Run 的门在能力预检上 (probeRuntime 读 gcp('nocreate'), 默认不建池), 而池在
% 低内存机器上可以**根本起不来** (实测 parpool('Processes',1) 抛
% parallel:cluster:PoolRunValidation, 且 license('test','Distrib_Computing_Toolbox')
% 为真 —— 不是没许可)。那种情况下"没进 Running"是**前置条件由机器给出**,
% 不是产品回归: 记成 incomplete 并把预检原文带上, 既不放行也不伪装成红。
% assume 族若在本案对象上不可用, 就走硬判红并把原因打进诊断 —— 不静默放过。
gBG = [];
try
    gBG = tepc.run.probeRuntime();
catch eG
    gBG = struct('can_run_background', false, 'actionable', ...
        string(eG.identifier) + ": " + string(eG.message), 'probe_detail', "");
end
if ~gBG.can_run_background && ~strcmp(char(app.Controller.state()), 'Running')
    reasonBG = sprintf(['后台 Run 前置不满足 (机器能力, 非产品缺陷): %s | ' ...
        '探针明细: %s | 池等待: %s'], char(string(gBG.actionable)), ...
        char(string(gBG.probe_detail)), poolMsg);
    mmTC = string(methods(tc));
    if any(mmTC == 'assumeTrue')
        tc.assumeTrue(false, reasonBG);
        return;
    end
    fprintf(2, '[test_gui] assumeTrue 不可用, 保留硬判红: %s\n', reasonBG);
end
% 断言必须自带诊断: 后台运行被拒时"状态没进 Running"只是症状, 真因 (能力预检的
% actionable / 探针 identifier) 全在横幅里。不带出来就得再跑一轮才能定位。
tc.verifyEqual(char(app.Controller.state()), 'Running', ...
    sprintf('状态没进 Running —— 横幅: %s | 池就绪=%d (gcp 等待 150 s, 最后: %s)', ...
    char(string(app.Banner.Text)), poolReady, poolMsg));
done = false;
R = [];
st = [];
tPoll = tic;
% 预算口径: 固定墙钟预算在本机不可用 —— 实测同一份代码在争用窗口里整文件慢 2.1-6.2 倍,
% 而 600 事件的后台链空闲 ~60 s、争用时 >240 s; 更关键的是单个阶段 (不确定度传播)
% 在负载下可以合法地跑 4 分钟以上, 所以任何"总时长一到就红"的判据都会把
% "慢但仍在推进"误判成失效 (上一代就是这样连红三次, 而空闲复跑 22/22 绿)。
% 改成**失速判据**: 只要作业还在推进就续预算, 连续 stallCapSec 毫无推进才红,
% 另设 totCapSec 作为兜底上限。推进信号取 Controller.LastRunDir 下的
% logs/PROGRESS.json (execute 每步落盘, 不依赖界面定时器);
% pollRun() 的返回体里**没有** fraction (只有 state/done/result/errMsg/...),
% 所以不能拿它当进度源 —— 这点是实测出来的, 不是推断。
totCapSec = 1200;
stallCapSec = 300;
progFile = '';
try
    lrd = string(app.Controller.LastRunDir);
    if lrd ~= ""
        cand = fullfile(char(lrd), 'logs', 'PROGRESS.json');
        if isfile(cand), progFile = cand; end
    end
catch
end
fracSeen = -1;
sigSeen = -1;
runDirSeen = "";
tLastFrac = tic;
stalled = false;
overCap = false;
for k = 1:600
    pause(2);
    st = app.Controller.pollRun();
    % 竞态说明: TEPCApp 自己的轮询定时器会先收割 future 并写入 Controller.Result
    % 并置状态机为 Completed; 此时测试再直接 pollRun 只会看到 Future 已空。
    % 因此以"用户可观测的终态"为准: 状态机进入终态 + Result 已填充。
    if isempty(st.result) && ~isempty(app.Controller.Result)
        st.result = app.Controller.Result;
        st.done = any(strcmp(string(app.Controller.state()), ...
            ["Completed","Failed","Cancelled"]));
        st.succeeded = strcmp(string(app.Controller.state()), "Completed");
        st.cancelled = strcmp(string(app.Controller.state()), "Cancelled");
    end
    if st.done
        done = true; R = st.result; break;
    end
    if progFile == ""
        % run 目录要等作业真起来才存在: 起手那次取数取不到并不代表永远取不到,
        % 所以每拍续找。找到之前本判据没有推进信号可用, 只能靠 totCapSec。
        try
            lrd2 = string(app.Controller.LastRunDir);
            if lrd2 ~= ""
                cand2 = fullfile(char(lrd2), 'logs', 'PROGRESS.json');
                if isfile(cand2), progFile = cand2; end
            end
        catch
        end
    end
    % 推进信号有两个: PROGRESS.json 的 fraction, 以及 run 目录 logs/ 下的文件数与字节数
    % (作业一启动就建目录、按步落盘)。第二个信号是必要的: 只盯 fraction 时, 一次从未
    % 启动成功的后台作业会留下 fraction=-1, 判据就退化成"读不到信号 = 卡住",
    % 而那正是本用例要避免的把环境状态误判成产品失效。
    try
        lrd2 = string(app.Controller.LastRunDir);
        if lrd2 ~= ""
            runDirSeen = lrd2;
            if progFile == ""
                cand2 = fullfile(char(lrd2), 'logs', 'PROGRESS.json');
                if isfile(cand2), progFile = cand2; end
            end
        end
    catch
    end
    sigNow = sigSeen;
    if runDirSeen ~= ""
        try
            dj = dir(fullfile(char(runDirSeen), 'logs'));
            dj = dj(~[dj.isdir]);
            sigNow = double(numel(dj)) + sum([dj.bytes]) / 1e6;
        catch
        end
    end
    if progFile ~= "" && isfile(progFile)
        try
            pv = jsondecode(fileread(progFile));
            fr = double(pv.fraction);
            if isfinite(fr) && fr > fracSeen
                fracSeen = fr;
                tLastFrac = tic;
            end
        catch
        end
    end
    if sigNow > sigSeen
        sigSeen = sigNow;
        tLastFrac = tic;
    end
    el = toc(tPoll);
    if el > totCapSec
        overCap = true; break;
    end
    % 失速只在**确实看得见推进**时才可判: 没有进度文件就没有推进信号, 那时唯一
    % 合法的上限是 totCapSec。否则"读不到信号"会被当成"作业卡住" —— 正是这个判据
    % 要避免的把机器慢误判成失效的那类假红 (本轮实测踩过, 消息与行为自相矛盾)。
    if runDirSeen ~= "" && toc(tLastFrac) > stallCapSec
        stalled = true; break;
    end
end
el = toc(tPoll);
if progFile ~= ""
    progDesc = progFile;
else
    progDesc = "不可用 (回退到总时长上限判据)";
end
tc.verifyFalse(stalled, sprintf( ...
    ['失速: 连续 %.0f s 两个推进信号都没动 (总耗时 %.1f s, 最后 fraction=%.3f, ' ...
     'logs 信号=%.3f, 进度文件 %s, run 目录 %s)。机器慢会持续推进, 而这里连 logs/ ' ...
     '都没有新东西 —— 所以是真卡住/没启动, 不是机器慢。'], ...
    stallCapSec, el, fracSeen, sigSeen, char(progDesc), char(runDirSeen)));
tc.verifyFalse(overCap, sprintf( ...
    '兜底上限: 总耗时 %.1f s 超过 %d s 仍未进入终态 (最后 fraction=%.3f)', ...
    el, totCapSec, fracSeen));
tc.verifyTrue(done, sprintf( ...
    '作业未在判据窗口内完成: 实耗 %.1f s, 最后 fraction=%.3f, 失速判据=%d, 上限判据=%d (空闲机基线 ~60 s)', ...
    el, fracSeen, stalled, overCap));
tc.verifyEqual(st.succeeded, true, '成功通道与取消/失败通道必须可区分');
if ~done
    % 后台运行没跑完时 R 还不是 Result struct —— 不 return 的话后面每一行都会
    % 再抛一个 MATLAB:structRefFromNonStruct, 把"超时"这个唯一真因埋进级联噪声里。
    return;
end
tc.verifyEqual(R.summary.nEvents, 600);
% computational_gates_passed 只度量"有无 FAIL", 不承诺可发布: 断言须落在水印与发布资格上
g = R.gates;
tc.verifyEqual(numel(g.items), 16, 'runGate 应为 16 项');
tc.verifyTrue(all(arrayfun(@(s) isfield(s,'value') && isfield(s,'status'), g.items)), ...
    '每项必须带可复算 value 与 status');
sts = string({g.items.status});
tc.verifyTrue(all(ismember(sts, ["PASS","FAIL","WARN","NOT_EVALUATED"])), '状态取值必须合法');
tc.verifyEqual(g.computational_gates_passed, g.nFail == 0, ...
    'computational_gates_passed 必须等价于"无 FAIL"');
if g.nFail > 0
    tc.verifyEqual(g.watermark, "INVALID");
elseif g.nWarn > 0
    tc.verifyEqual(g.watermark, "VALID(FOR DEMO, WARN)");
else
    tc.verifyEqual(g.watermark, "VALID(FOR DEMO)");
end
tc.verifyFalse(g.release_eligible, '参考场未评估 -> 必须不具备发布资格');
end

function tf = isFitColumn(lb, colIdx)
% 两个入参是刻意的: functiontests 按元数收集局部函数, 1 入参会被当成用例 (实测 602 vs 604 分叉)
% 只有 'fit' 列才是恒等式; '1x' 与定值列的逐格比较仍然有牙, 不进这个累加器。
tf = false;
try
    if ~isprop(lb.Parent, 'ColumnWidth'), return; end
    cw = lb.Parent.ColumnWidth;
    ci = colIdx;
    if ci < 1 || ci > numel(cw), return; end
    v = cw{ci};
    tf = (ischar(v) || isstring(v)) && strcmpi(char(string(v)), 'fit');
catch
    tf = false;
end
end

function [keysOut, sumOut] = addFit(keysIn, sumIn, lay, w)
keysOut = keysIn; sumOut = sumIn;
for i = 1:numel(keysIn)
    if keysIn{i} == lay
        sumOut(i) = sumOut(i) + w;
        return
    end
end
keysOut{end+1} = lay; %#ok<AGROW>
sumOut(end+1) = w; %#ok<AGROW>
end
