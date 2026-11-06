function tests = test_pipeline
%TEST_PIPELINE 集成: 端到端管线/可复现/续跑/HDF5 schema/门禁。
tests = functiontests(localfunctions);
end

function test_end_to_end_artifacts(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
R = tepc.run.execute(cfg, 'N', 800, 'Seed', 4242);
tc.verifyEqual(R.summary.nEvents, 800);
tc.verifyTrue(isfile(R.eventsPath), 'events.h5 生成');
tc.verifyTrue(isfile(fullfile(R.runDir.results,'spectrum.csv')));
tc.verifyTrue(isfile(fullfile(R.runDir.results,'summary.json')));
tc.verifyTrue(isfile(fullfile(R.runDir.results,'provenance.json')));
tc.verifyTrue(isfile(fullfile(R.runDir.results,'gates.json')));
tc.verifyTrue(isfile(fullfile(R.runDir.logs,'STATUS.json')));
tc.verifyFalse(isempty(R.gates.items), '门禁项非空');
tc.verifyLessThan(abs(R.summary.intFdy - (1 - (R.summary.underflowWeight+ ...
    R.summary.overflowWeight)/R.analysis.spectrum.SW_valid)), 1e-9);
% 仪器链必须真正启用 (电荷注入刻度 -> 反演授予能 -> 真值谱交叉核对)
tc.verifyEqual(R.analysis.instrument_chain, true, 'execute 必须走仪器链');
tc.verifyGreaterThan(R.summary.n_meas_valid, 0, '必须有可反演的测量');
tc.verifyFalse(isempty(R.analysis.spectrum_truth), '仪器链启用时真值谱必须一并给出');
tc.verifyTrue(isfield(R.summary,'instr_bias_yF') && isfinite(R.summary.instr_bias_yF), ...
    'instr_bias_yF 必须存在且可算');
tc.verifyLessThan(abs(R.summary.instr_bias_yF), 0.5, '刻度偏差应在合理量级');
tc.verifyEqual(R.summary.instrument_chain, true);
% 观测时长/每事件剂量字段 (原实现把累积剂量再乘计数率)
tc.verifyGreaterThan(R.summary.t_obs_s, 0);
tc.verifyEqual(R.summary.D_gas_per_event_Gy*800, R.summary.D_gas_Gy, 'RelTol', 1e-9);
tc.verifyGreaterThan(R.summary.dose_rate_uGy_h, 0);
% 报告**内容**核对。原缺陷: htmlReport 找 figures/diagnostic_spectrum.png 而 execute
% 写的是 diagnostic.png => 走 project.execute()+exportReport() 的报告没有诊断图;
% Qbar 为字符串 "NA" 时 sprintf('%.2f',"NA") 印出 '78.00' (字符 ASCII);
% u(y_F)/剂量率/阈下事件数算了但从不显示。
htxt = fileread(fullfile(R.runDir.results, 'report.html'));
tc.verifyTrue(contains(htxt, 'base64'), '诊断图必须内嵌 (与 execute 写出的文件名一致)');
% 内嵌图还得**解得开、且与盘上 PNG 是同一份字节**。原缺陷: fread 的 precision 只说明文件里
% 是什么类型, 输出仍是 double; base64encode 拿到 double 会按每元素 8 字节重排, 标签名合法
% 但浏览器只显示裂图 (实测 220807 字节的 PNG 编出 2459328 个字符 = 解码 8 倍长)。
fidP = fopen(fullfile(R.runDir.figures, 'diagnostic.png'), 'r');
pngB = fread(fidP, inf, '*uint8'); fclose(fidP);
tokE = regexp(htxt, 'base64,([A-Za-z0-9+/=]+)', 'tokens', 'once');
tc.verifyTrue(~isempty(tokE), '报告里取不到 base64 载荷');
embB = uint8(matlab.net.base64decode(tokE{1}));
tc.verifyEqual(numel(embB), numel(pngB), sprintf( ...
    '内嵌 PNG 解出 %d 字节, 盘上是 %d 字节 (成 8 倍即 double 重排)', numel(embB), numel(pngB)));
tc.verifyTrue(isequal(embB(:), pngB(:)), '内嵌 PNG 与 figures/diagnostic.png 不是同一份字节');
badEnc = matlab.net.base64encode(double(pngB));
badB = uint8(matlab.net.base64decode(badEnc));
tc.verifyNotEqual(numel(badB), numel(pngB), ...
    '把字节按 double 重排编码后解码长度竟没变: 这条锁抓不到已知破坏形态');
% CSV 必须带 UTF-8 BOM: 中文 Windows 的 Excel 对无 BOM 的 UTF-8 按本机码页(GBK)猜,
% 首行的中文口径说明会显示成一串生僻字。
fidC = fopen(fullfile(R.runDir.results, 'spectrum.csv'), 'r');
csvB = fread(fidC, inf, '*uint8'); fclose(fidC);
tc.verifyTrue(numel(csvB) >= 3 && isequal(double(csvB(1:3))', [239 187 191]), sprintf( ...
    'spectrum.csv 头三字节是 [%s] 而不是 UTF-8 BOM [239 187 191]', sprintf('%d ', double(csvB(1:3)))));
csvL = strsplit(native2unicode(csvB(4:end)', 'UTF-8'), newline);
tc.verifyTrue(startsWith(strtrim(csvL{1}), '#') && contains(csvL{1}, '口径'), ...
    sprintf('去 BOM 后首行应是带中文口径说明的注释行, 实得: %s', csvL{1}));
tc.verifyEqual(strtrim(csvL{2}), ...
    'bin_low_keV_um,bin_high_keV_um,center_keV_um,dy,counts_raw,sum_w,sum_w2,f_y,sigma_f,d_y,f_in,d_in', ...
    'BOM 不得跑到表头行上 (它只该落在首行注释之前)');
tc.verifyFalse(contains(htxt, '>78.00<'), 'Qbar 不得被印成字符 ASCII 码 78.00');
tc.verifyTrue(contains(htxt, 'u(y_F)'), '报告页眉承诺了不确定度, 必须真的列出');
tc.verifyTrue(contains(htxt, 'uGy/h'), '剂量率必须显示');
tc.verifyTrue(contains(htxt, '阈下事件'), '阈下事件数必须显示 (underflowWeight 为 0 会掩盖它)');
tc.verifyTrue(contains(htxt, '每事件'), '每事件与累计剂量必须分开标注');
tc.verifyTrue(contains(htxt, '限制声明'), '限制声明必须随报告输出');
% 默认已是 derived, 但 HTML 报告以前根本没有位点行 ——
% 请求 2 um / 实现 0.531 um 必须在报告首页同屏出现, 否则读者只能从 limitations 文字里猜。
tc.verifyTrue(contains(htxt, '位点等效'), '报告必须显示位点等效行 (请求/实现/相对差)');
tc.verifyTrue(contains(htxt, sprintf('%.3f', R.summary.site_realized_d_tissue_um)), ...
    '实现位点数值必须真的印出来');
tc.verifyTrue(contains(htxt, '归一化口径'), ...
    'f(y)/d(y) 与精确矩分母口径不同, 必须在报告里显式声明');
% runDirs/provenance: rd.root 必须是该 run 目录, 否则产物哈希全为空 (原缺陷)
rd = R.runDir;
tc.verifyEqual(fullfile(rd.runs_base, rd.runID), rd.root, ...
    'rd.root 必须是该 run 的目录 (provenance 产物哈希依赖它)');
tc.verifyEqual(rd.project_root, root);
tc.verifyGreaterThan(numel(fieldnames(R.provenance.outputs)), 4, ...
    'provenance 必须哈希 >=5 个产物 (谱/summary/gates/report.html/diagnostic.png); 旧实现只哈希到 2-3 个且 report.html 与图从不生成');
fn = fieldnames(R.provenance.outputs);
for i = 1:numel(fn)
    tc.verifyEqual(numel(R.provenance.outputs.(fn{i})), 64, ...
        sprintf('产物哈希 %s 不得为空', fn{i}));
end
td = fullfile(tempdir, sprintf('tepc_rd_%d', randi(1e9)));
mkdir(td);
cleanupDir = onCleanup(@() rmdir(td, 's'));
pt = tepc.io.runDirs(td);
tc.verifyEqual(pt.output_root, td, ...
    '调用方显式指定的输出基准必须被尊重 (TEPC_RUNS_DIR 只接管隐式的项目根)');
tc.verifyEqual(pt.root, fullfile(td, 'runs', pt.runID), ...
    'runDirs 不得把项目根当作 run 根');
tc.verifyEqual(pt.events, fullfile(td, 'runs', pt.runID, 'events'));
end

function test_analyze_returns_event_batch(tc)
% EventBatch 是值类: analyze 必须靠第二个返回值交出派生列 (原缺陷: h5 里 y/lbar 全 NaN)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
R = tepc.config.resolve(cfg);
[Qfun, ~] = tepc.analysis.qualityFactor(cfg.analysis.qualityFactor, root);
N = 400;
E = tepc.domain.EventBatch.preallocate(N);
rs = RandStream('Threefry','Seed',7);
E.ev.eventID      = (1:N)';
E.ev.EdepGas_keV  = 5 + 20*rand(rs, N, 1);
E.ev.gasPath_um   = 100 + 50*rand(rs, N, 1);
E.ev.t0_s         = (0:N-1)'*0.01;
E.ev.weight       = ones(N, 1);
E.ev.flags        = zeros(N, 1, 'uint32');
E.ev.model_id     = uint16(ones(N, 1));
E.ev.Esecondary_keV = E.ev.EdepGas_keV;
A = tepc.analysis.analyze(E, cfg, R, Qfun);            %#ok<ASGLU> 单输出必须仍可用
% analyze 的第一个返回值是分析结果 A, 第二个才是带派生列的 EventBatch
% (EventBatch 是值类, 不取第二个返回值就拿不到派生列)
[~, E2] = tepc.analysis.analyze(E, cfg, R, Qfun);      % 省略第 5 参 cal
tc.verifyEqual(A.instrument_chain, false, '无标定结构必须显式标注未走仪器链');
tc.verifyTrue(isempty(A.spectrum_truth), '未启用仪器链时真值谱为 []');
tc.verifyEqual(A.n_meas_valid, 0);
tc.verifyGreaterThan(A.t_obs_s, 0);
tc.verifyEqual(numel(A.lbar_tissue_um), 1);
% 值类语义: 入参不被改写, 派生列只在返回值上
tc.verifyTrue(all(isnan(E.ev.y_keV_per_um)), '入参 EventBatch 不得被就地改写');
tc.verifyEqual(nnz(isfinite(E2.ev.y_keV_per_um)), nnz(E.ev.EdepGas_keV > 0));
tc.verifyTrue(all(E2.ev.lbar_tissue_um == R.lbar_tissue_um));
tc.verifyTrue(all(isnan(E2.ev.epsilon_meas_keV)), '无 cal 时测量授予能必须为 NaN');
E2.validate();
end

function test_hdf5_roundtrip(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
R = tepc.run.execute(cfg, 'N', 500, 'Seed', 99);
E = tepc.io.readEventsH5(R.eventsPath);
tc.verifyEqual(E.n, 500);
tc.verifyEqual(double(E.ev.eventID(1)), 1);
tc.verifyEqual(double(E.ev.eventID(end)), 500);
info = h5info(R.eventsPath, '/events');
names = {info.Datasets.Name};
sch = tepc.domain.EventBatch.schema();
tc.verifyEqual(size(sch, 1), 23, 'schema 现应为 23 列 (含 channelId 道标签)');
need = {'event_id','EdepGas_keV','weight','t0_s','flags','adc_code','charge_C', ...
    'Eescape_keV','Esecondary_keV','epsilon_meas_keV','adc_range','t_trigger_s', ...
    'r0_m','peak_V','lbar_tissue_um','y_keV_per_um','gasPath_um','model_id'};
for i = 1:numel(need)
    tc.verifyTrue(any(strcmp(need{i}, names)), sprintf('schema 含 %s', need{i}));
end
for i = 1:size(sch, 1)
    ds = evNameOf(sch{i,1});
    tc.verifyTrue(any(strcmp(ds, names)), sprintf('schema 列 %s 未落盘', ds));
end
att = h5info(R.eventsPath, '/').Attributes;
anames = {att.Name};
tc.verifyTrue(any(strcmp('config_sha256', anames)), '根属性含 config_sha256');
tc.verifyTrue(any(strcmp('seed', anames)), '根属性含 seed');
% analyze 的派生列必须真的写进文件 (不再凭空的 NaN 列)
tc.verifyTrue(all(isfinite(E.ev.lbar_tissue_um)), 'lbar_tissue_um 不得整列 NaN');
tc.verifyEqual(nnz(isfinite(E.ev.y_keV_per_um)), nnz(isfinite(E.ev.epsilon_meas_keV)), ...
    '发布量 y 必须逐事件等于 eps_meas/lbar_t (有限性一致)');
yv = E.ev.y_keV_per_um;
tc.verifyTrue(all(yv(isfinite(yv)) >= 0), '发布线能必须非负');
tc.verifyGreaterThanOrEqual(nnz(isfinite(E.ev.epsilon_meas_keV)), R.summary.n_meas_valid);
tc.verifyEqual(nnz(isnan(E.ev.epsilon_meas_keV)), ...
    nnz(bitand(E.ev.flags, uint32(2+1+256)) > 0), ...
    '反演失败必须逐事件回写标志 (可审计), NaN 列与标志集合一致');
tc.verifyTrue(all(E.ev.adc_range == 1 | E.ev.adc_range == 2), 'adc_range 只能 1/2');
tc.verifyTrue(all(E.ev.t_trigger_s >= 0));
tc.verifyTrue(all(E.ev.r0_m == R.resolve.r0_m));
% 账本逐事件闭合 (Esecondary 与三本沉积同源于落盘文件)
% 单位: Esecondary_keV / EdepGas_keV / EdepWall_keV / Eescape_keV 全是 keV ——
%   原实现把左边再乘 1e3 (当成 eV) 与右边 keV 相减, 于是"残差"恒为 0.999 (实测)。
pos = E.ev.Esecondary_keV > 0;
tc.verifyGreaterThan(nnz(pos), 0, '必须有次级粒子能量列');
rel = abs(E.ev.Esecondary_keV(pos) - (E.ev.EdepGas_keV(pos) + ...
    E.ev.EdepWall_keV(pos) + E.ev.Eescape_keV(pos)))./E.ev.Esecondary_keV(pos);
tc.verifyLessThan(max(rel), 1e-6, '落盘数据账本必须逐事件闭合');
tc.verifyEqual(numel(rel), nnz(E.ev.Esecondary_keV > 0), '筛选不得漏事件 (NaN 会伪装成通过)');
tc.verifyFalse(any(isnan(rel)), '账本残差不得含 NaN');
end

function test_read_events_h5_rejects_missing_column(tc)
% 读取层不得用 preallocate 造 NaN 列掩盖缺失
p = fullfile(tempdir, sprintf('tepc_missing_%d.h5', randi(1e9)));
cleanupObj = onCleanup(@() delete(p));
h5create(p, '/events/event_id', [1 1], 'DataType', 'uint64');
h5write(p, '/events/event_id', uint64(1));
tc.verifyError(@() tepc.io.readEventsH5(p), 'tepc:io:SchemaMissing');
end

function test_write_events_h5_rejects_size_mismatch(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
E = tepc.domain.EventBatch.preallocate(10);
E.ev.eventID = (1:10)';
E.ev.EdepGas_keV(11) = 1;                      % 人为造成长度不一致
p = fullfile(tempdir, sprintf('tepc_size_%d.h5', randi(1e9)));
cleanupObj = onCleanup(@() delete(p));
tc.verifyError(@() tepc.io.writeEventsH5(p, E, struct('seed',1)), 'tepc:io:SizeMismatch');
end

function test_cancel_partial(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
cflag = fullfile(tempdir, sprintf('tepc_cancel_%d.flag', randi(1e9)));
rd = fullfile(tempdir, sprintf('tepc_cancel_run_%d', randi(1e9)));
fid = fopen(cflag, 'w'); fwrite(fid, 'x'); fclose(fid);
tc.verifyError(@() tepc.run.execute(cfg, 'N', 5000, 'Seed', 1, ...
    'CancelFlag', cflag, 'RunDir', rd), 'tepc:run:CancelRequested');
tc.verifyTrue(isfile(fullfile(rd, 'logs', 'STATUS.json')), '取消也必须写 STATUS.json');
if isfile(fullfile(rd,'logs','STATUS.json'))
    st = jsondecode(fileread(fullfile(rd,'logs','STATUS.json')));
    % 状态词汇集中在 tepc.io.runWriteStatus, 统一小写。这里曾断言 'CANCELLED':
    % 大写形式是旧实现的第二个状态词表, 与 runWriteStatus 的 allowed 列表冲突。
    tc.verifyEqual(string(st.status), "cancelled", '取消也必须落盘可审计状态');
    tc.verifyTrue(~isempty(strtrim(string(st.reason))), ...
        'cancelled 必须带 reason, 否则审计上分不清"跑完"与"跑坏"');
    % 取消后已完成 chunk 必须留在 raw/ (续跑承诺)。本用例在第 1 个 chunk 之前就
    % 取消, 所以只在"确实完成了 chunk"时才要求 checkpoint 存在。
    if isfield(st, 'completed_chunks') && st.completed_chunks > 0
        tc.verifyTrue(isfile(fullfile(rd,'raw','checkpoint.json')), ...
            '已完成的 chunk 必须留下 checkpoint.json, 否则"取消后可续跑"是空话');
    end
end
delete(cflag);
rmdir(rd, 's');
end

function test_gates_have_no_unconditional_pass(tc)
% 门禁每项必须带可复算 value, PASS 必须有有限数值依据; 改坏数据必须新增 FAIL。
% 按 name 查找, 不依赖项的顺序 (顺序变了也应照样定位到该项)。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
R = tepc.run.execute(cfg, 'N', 700, 'Seed', 31415);
G0 = R.gates; A0 = R.analysis;
tc.verifyEqual(numel(G0.items), 16, 'runGate 现应为 16 项 (15=UQ 完成度, 16=参考数据域与来源)');
names0 = gateNames(G0);
tc.verifyEqual(numel(unique(names0)), 16, '门禁项名称必须互不相同 (消费方按名字索引)');
for i = 1:numel(G0.items)
    tc.verifyTrue(isfield(G0.items(i), 'value'), sprintf('%d 项缺 value', i));
    tc.verifyFalse(isempty(strtrim(G0.items(i).detail)), '每项必须有细节说明');
    if string(G0.items(i).status) == "PASS"
        tc.verifyTrue(isfinite(G0.items(i).value), ...
            sprintf('PASS 项 "%s" 没有有限数值依据 (无条件 PASS)', G0.items(i).name));
    end
end
sts0 = string({G0.items.status});
tc.verifyTrue(any(sts0 == "NOT_EVALUATED"), '参考场必须如实报告未评估');
tc.verifyEqual(G0.computational_gates_passed, G0.nFail == 0);
tc.verifyEqual(G0.release_eligible, ~((G0.nFail > 0) || (G0.nNotEvaluated > 0)));
tc.verifyEqual(G0.released, G0.release_eligible && strcmp(R.cfg.run.mode,"VALIDATED"));
% 计数器本身必须与逐项状态一致 (原缺陷: strcmp 对"装着 string 的 cell"恒 false,
% 于是 nFail/nWarn/nNE 永远是 0, 整套红线门禁形同无条件通过)
tc.verifyEqual(G0.nFail, nnz(sts0 == "FAIL"), 'nFail 必须等于逐项 FAIL 计数');
tc.verifyEqual(G0.nWarn, nnz(sts0 == "WARN"), 'nWarn 必须等于逐项 WARN 计数');
tc.verifyEqual(G0.nNotEvaluated, nnz(sts0 == "NOT_EVALUATED"), 'nNotEvaluated 必须逐一对上');

% --- 篡改归一化: 只有第 1 项消费 intFdy, 必须恰好新增 1 个 FAIL ---
Ab = A0; Ab.spectrum.intFdy = 2.0;
Gb = tepc.validation.runGate(R, Ab, R.runDir);
tc.verifyEqual(Gb.nFail - G0.nFail, 1, '伪造 intFdy 必须且只多出一个 FAIL');
tc.verifyEqual(gateStatus(Gb, 'int f dy 归一'), "FAIL", '该项必须由伪造值判 FAIL');
tc.verifyEqual(Gb.watermark, "INVALID");
tc.verifyFalse(Gb.computational_gates_passed);
% --- 篡改发布精确矩: 只有 h5 回读重算(项4) 该抓到。项2 现在比的是**同群**矩
%     (A.spectrum_in.yF_binned vs A.spectrum.yF_exact_inRange), 不再消费 yF_exact ——
%     这是把"分箱误差"与"域外份额"分开的代价, 判别面移到下一枪。
Ac = A0; Ac.spectrum.yF_exact = A0.spectrum.yF_exact*10;
Gc = tepc.validation.runGate(R, Ac, R.runDir);
tc.verifyEqual(gateStatus(Gc, 'events.h5 回读重算'), "FAIL", ...
    '回读重算项必须以 h5 为准抓住内存谱的篡改 (不信任内存对象)');
tc.verifyEqual(Gc.nFail - G0.nFail, 1, ...
    'yF_exact 篡改须且仅须新增 1 个 FAIL (项2 已改判同群量, 不再消费 yF_exact)');
tc.verifyEqual(Gc.watermark, "INVALID");
% --- 项2 的可失败性: 篡改它真正消费的同群精确矩 ---
Ae = A0; Ae.spectrum.yF_exact_inRange = A0.spectrum.yF_exact_inRange*10;
Ge = tepc.validation.runGate(R, Ae, R.runDir);
tc.verifyEqual(gateStatus(Ge, '分箱矩-精确矩一致'), "FAIL", ...
    '分箱核对须抓住 yF_exact_inRange 篡改 (项2 的负控必须打在它实际消费的量上)');
tc.verifyEqual(Ge.watermark, "INVALID");

% --- 参数域守卫: 该项必须消费可复算的域外计数并降级 ---
iOOR = gateIndex(G0, '参数域守卫');
tc.verifyFalse(isempty(iOOR), '门禁必须包含参数域守卫项');
if ~isempty(iOOR)
    Ad = A0; Ad.flags.outOfRange = 1e6;
    Gd = tepc.validation.runGate(R, Ad, R.runDir);
    tc.verifyEqual(Gd.items(iOOR).value, 1e6, '该项必须消费可复算的域外计数');
    tc.verifyEqual(gateStatus(Gd, '参数域守卫'), "WARN", '域外计数非零必须降级 (不得无条件 PASS)');
end

% --- 事件文件缺失: 依赖落盘数据的 5 项必须全部转 FAIL (不得静默通过) ---
Re = R; Re.eventsPath = '';
Ge = tepc.validation.runGate(Re, A0, R.runDir);
h5Items = ["能量账本闭合","events.h5 回读重算","无效测量零权重","权重账自洽","seed 一致性"];
for i = 1:numel(h5Items)
    tc.verifyEqual(gateStatus(Ge, h5Items(i)), "FAIL", ...
        sprintf('events.h5 缺失时 "%s" 必须 FAIL 而非静默通过', h5Items(i)));
end
tc.verifyEqual(Ge.nFail, G0.nFail + numel(h5Items), '缺失文件的 FAIL 计数必须逐项对得上');
tc.verifyEqual(gateNames(Ge), names0, '门禁项名称/顺序必须与有文件时一致');
end

function nm = gateNames(G)
nm = string({G.items.name});
end

function k = gateIndex(G, want)
k = find(string({G.items.name}) == want, 1);
end

function st = gateStatus(G, want)
%GATESTATUS 按名字取门禁项状态; 名字不存在时报错 (绝不退化为按序号猜)
k = gateIndex(G, want);
if isempty(k)
    error('tepc:test:NoGate', '门禁中找不到名为 "%s" 的项 (现有: %s)', want, ...
        strjoin(string({G.items.name}), ' | '));
end
st = string(G.items(k).status);
end

function test_config_validation_blocks(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
cfg.gas.composition_molfrac.CH4 = 0.70;   % 组分和 != 1
tc.verifyError(@() tepc.run.execute(cfg, 'N', 100), 'tepc:run:ConfigInvalid');
cfg2 = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
cfg2.run.mode = "VALIDATED";              % 含 ASSUMED 参数 -> 红线
tc.verifyError(@() tepc.run.execute(cfg2, 'N', 100), 'tepc:run:ConfigInvalid');
end

% ---------------- 本地函数 ----------------
function ds = evNameOf(fld)
%EVNAMEOF EventBatch 字段名 -> events.h5 数据集名 (与 writeEventsH5 的映射一致)
map = {'eventID','event_id'; 'primaryClass','primary_class'; ...
       'parent_event_id','parent_event_id'; 'channelId','channel_id'};
ds = fld;
for i = 1:size(map, 1)
    if strcmp(map{i,1}, fld), ds = map{i,2}; return; end
end
end

function test_runDirs_env_redirect_does_not_pollute_repo(tc)
% TEPC_RUNS_DIR 把 run 输出重定向到仓库外 (否则每跑一次套件就往 runs/ 堆若干目录)。
prev = getenv('TEPC_RUNS_DIR');
cleanup = onCleanup(@() setenv('TEPC_RUNS_DIR', prev));
base = fullfile(tempdir, sprintf('tepc_ci_%d', randi(1e9)));
if ~isfolder(base), mkdir(base); end
d2 = onCleanup(@() rmdir(base, 's'));
setenv('TEPC_RUNS_DIR', base);
rd = tepc.io.runDirs(tepc.io.projectRoot());
tc.verifyEqual(rd.output_root, base, '输出基准必须被环境变量接管');
tc.verifyEqual(rd.root, fullfile(base, 'runs', rd.runID));
tc.verifyEqual(rd.project_root, tepc.io.projectRoot(), ...
    'project_root 必须始终是代码根目录 (provenance 要它定位 config)');
tc.verifyTrue(isfolder(rd.root) && isfolder(rd.logs) && isfolder(rd.raw) && isfolder(rd.workRoot), ...
    '状态区(logs)/工作区(raw)/暂存区(_work)必须在重定向后的基准下建立');
tc.verifyTrue(isfolder(rd.work.input) && isfolder(rd.work.results) && isfolder(rd.work.figures), ...
    '提交前发布集只存在于 _work/ 暂存区');
% 提交前发布位置**必须不存在**: layoutRunDirs 刻意不预建它们 —— movefile(a,b) 当 b
% 已存在时是"移入"而非改名, 预建会让提交造出 results/results 这样的嵌套。
tc.verifyFalse(isfolder(rd.input) || isfolder(rd.results) || isfolder(rd.figures) ...
    || isfolder(rd.events) || isfolder(rd.partial), ...
    '提交前不得存在发布位置目录, 否则事务式改名会嵌套');
tc.verifyFalse(rd.committed, '新建布局不得自称已提交');
end
