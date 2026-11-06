function tests = test_run_waveform_stage
%TEST_RUN_WAVEFORM_STAGE 集成: 事件波形开关两态的产物级判据。
%   同一 seed 跑两趟 (关 / 开), 三件事在这两趟的差上核对:
%     1) 开关不参与事件数据的计算 —— events.h5 的每个数据集、spectrum.csv 的字节、
%        以及其后才跑的 UQ 数值必须两态相同。"默认关闭就不许影响任何东西"这句话
%        只有落到盘上字节才算被证明。
%     2) 打开时 events/waveforms.h5 真的进了发布集并被清单哈希; 盘上标量可由盘上样本
%        复算 (回放配方 v=double(samples)*scale_V 记在文件属性 replay_recipe 里;
%        readWaveformsH5 只负责取数与自描述核对, 复算发生在调用方 —— 本用例与单测)。
%     3) 报告页对两态各印一行状态, 读者不必打开 summary.json 也知道这次有没有波形文件。
%   两态的 config_sha256 必须不同: 相同就说明这个块没进配置身份, 那是假开关。
%   诚实声明: 这里落盘的是解析代理模型电子学链的模拟波形, 不是实测脉冲形状。
tests = functiontests(localfunctions);
end

function test_two_states_products_and_inertness(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
cfg.waveform.enabled = false;
cfg.waveform.nSub = 8;
cfg.run.chunkSize = 60;                       % N=120 => 2 个 chunk, 顺带跨块核对行序
% MATLAB 全局随机流跨进程默认同种子: randi 出的"随机名"每一跑都一样, 一旦有中途被杀的
% 跑把目录留在 tempdir, 下一跑就会在已发布过的 off/ 上撞 execute 的 AlreadyCommitted 守卫
% 且无法自愈。改用毫秒时间戳 + 进程号取进程级唯一名。
td = fullfile(tempdir, sprintf('tepc_wf_%s_%d', ...
    char(string(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd_HHmmssSSS'))), ...
    feature('getpid')));
mkdir(td);
% 句柄必须活到本用例结束: clear/赋值给别的变量都会当场触发 rmdir。
cleanupDir = onCleanup(@() rmdir(td, 's'));  %#ok<NASGU>

% --- 关闭态: 不生成文件, 但披露键必须在 (状态词不是可选的) ---------------------
Roff = tepc.run.execute(cfg, 'N', 120, 'Seed', 771, 'RunDir', fullfile(td, 'off'));
sOff = readSummary(tc, fullfile(td, 'off', 'results', 'summary.json'));
tc.verifyEqual(string(sOff.waveform_status), "DISABLED", ...
    sprintf('实得 %s', string(sOff.waveform_status)));
tc.verifyEqual(sOff.waveform_nSub, 0, '关闭态不该有任何波形事件被落盘');
tc.verifyFalse(isfile(fullfile(td, 'off', 'events', 'waveforms.h5')), ...
    'enabled=false 却生成了 waveforms.h5');
tc.verifyEqual(eventFileNames(fullfile(td, 'off', 'events')), "events.h5", ...
    '关闭态的 events/ 里只该有 events.h5');

% --- 打开态: 文件在发布集里, 且被清单哈希 ------------------------------------
cfgOn = cfg;
cfgOn.waveform.enabled = true;
Ron = tepc.run.execute(cfgOn, 'N', 120, 'Seed', 771, 'RunDir', fullfile(td, 'on'));
sOn = readSummary(tc, fullfile(td, 'on', 'results', 'summary.json'));
wf = fullfile(td, 'on', 'events', 'waveforms.h5');
tc.verifyEqual(string(sOn.waveform_status), "WRITTEN", ...
    sprintf('状态词实得 %s (note=%s)', string(sOn.waveform_status), string(sOn.waveform_note)));
tc.verifyTrue(isfile(wf), 'events/waveforms.h5 必须出现在提交后的发布集里');
tc.verifyEqual(sOn.waveform_nSub, 8, ...
    sprintf('waveform_nSub 实得 %s', mat2str(sOn.waveform_nSub)));
tc.verifyGreaterThan(sOn.waveform_bytes, 0);
tc.verifyGreaterThan(sOn.waveform_scale_V, 0);
tc.verifyNotEqual(string(sOff.config_sha256), string(sOn.config_sha256), ...
    'waveform 块没进配置身份: 配置改了而运行不区分它, 就是假开关');

M = jsondecode(fileread(fullfile(td, 'on', 'results', 'artifact_manifest.json')));
tc.verifyTrue(isfield(M, 'files') && ~isempty(M.files), '清单必须有 files 行');
% 清单里的相对路径带**本机分隔符** (artifactManifest 只是去掉了根前缀), 而 summary 的
% waveform_path 写的是可移植的 '/'。这里统一成 '/' 再比, 否则同一个文件有两种拼法。
paths = replace(manifestPaths(M), char(92), "/");
hit = contains(paths, "events/waveforms.h5");
tc.verifyTrue(any(hit), ...
    sprintf('清单必须覆盖 events/waveforms.h5, 实得路径: %s', strjoin(paths, ', ')));
if any(hit)
    hs = manifestSha(M);
    tc.verifyMatches(hs(hit), "^[0-9a-f]{64}$", '清单里 waveforms.h5 的 sha256 不像哈希');
    tc.verifyEqual(hs(hit), string(tepc.io.hashFile(wf)), ...
        '清单记录的哈希必须等于盘上字节 (记录与实际可对上)');
end

% --- 惰性: 事件数据与谱两态逐位相同 ------------------------------------------
[diffs, nCmp] = differingEventDatasets(fullfile(td, 'off', 'events', 'events.h5'), ...
    fullfile(td, 'on', 'events', 'events.h5'));
% 反空转: 数据集名字集合一旦变空, 下面的 verifyEmpty 就恒真 —— "两态逐位全等"必须建立在
% 确实比过全量之上, 下界取生成器记的 h5_datasets (与清单、门禁同一真相源)。
nWant = countsN(root, 'h5_datasets');
% verifyGreaterThanOrEqual 不接受 'AbsTol' 这类容差名值对 (实测 narginchk:tooManyInputs)。
tc.verifyGreaterThanOrEqual(nCmp, nWant, sprintf( ...
    '只比了 %d 个事件数据集, 少于 counts.json 记的 %d: 逐位全等这句话没有覆盖全表 (结构性缺失: %s)', ...
    nCmp, nWant, strjoin(diffs, ', ')));
tc.verifyEmpty(diffs, sprintf('这些事件数据集在两态之间不同: %s —— 开关吃进了事件计算', ...
    strjoin(diffs, ', ')));
tc.verifyEqual(tepc.io.hashFile(fullfile(td, 'off', 'results', 'spectrum.csv')), ...
    tepc.io.hashFile(fullfile(td, 'on', 'results', 'spectrum.csv')), ...
    'spectrum.csv 的字节必须与开关无关');
% runUqStage 在 waveformStage 之后执行: 它抽自己的 cfg.uq.seed 流, 数值应当逐位相同。
% 不同就说明波形重跑动了某个下游还在用的随机状态。
KK = uqKeys;
for i = 1:numel(KK)
    k = KK(i);
    if ~isfield(Roff.summary, k) || ~isfield(Ron.summary, k), continue; end
    tc.verifyTrue(isequaln(Roff.summary.(k), Ron.summary.(k)), ...
        sprintf('%s 两态不同: 波形阶段影响了 UQ 结果', k));
end

% --- 回放: 盘上标量是盘上样本的函数 ------------------------------------------
W = tepc.io.readWaveformsH5(wf);
tc.verifyEqual(size(W.samples_int16, 1), 8, '落盘行数 = nSub');
tc.verifyGreaterThan(size(W.samples_int16, 2), 1, '每条波形要有多个样本');
for j = 1:size(W.v, 1)
    [pk, ipk] = tepc.electronics.peakSigned(W.v(j, :).', W.hsign);
    tc.verifyEqual(pk, W.peak_V(j), sprintf('第 %d 行的 peak_V 不等于由盘上样本复算的峰', j));
    tc.verifyEqual(ipk * W.Ts_s, W.t_trigger_s(j), sprintf('第 %d 行的 t_trigger_s 不等于 argmax*Ts', j));
    tc.verifyEqual(sum(W.v(j, :)) * W.Ts_s, W.integral_Vs(j), sprintf('第 %d 行的 integral_Vs 不等于 sum(v)*Ts', j));
end
% 子集口径: 文件里的 event_id 与 summary 记的那批必须是同一批, 且都在事件表里
tc.verifyEqual(uint64(sOn.waveform_event_ids(:)), W.event_id, ...
    'summary.waveform_event_ids 与文件里的 event_id 分叉');
Eid = double(h5read(fullfile(td, 'on', 'events', 'events.h5'), '/events/event_id'));
tc.verifyEqual(nnz(ismember(Eid, double(W.event_id))), 8, ...
    '落盘的 event_id 必须都能在事件表里找到 (各一行)');
% 交叉核对披露: 事件表峰与波形复算峰的差应当只有量化半步量级。两个出口都要核:
% summary.json 里的键 (读者实际看得到的那份), 以及文件根属性 (证明文件自描述)。
% 列全量根属性只能走 h5info(...).Attributes: h5readatt 没有"省略属性名读全部"的形态
% (只给文件名和位置会报 MATLAB:minrhs "输入参数的数目不足", 实测), 而 W.attrs 只是
% readWaveformsH5 挑过的必需属性集合, 不含 xcheck_* 这类派生属性 —— 拿它判"没写"会误判。
tc.verifyTrue(isfield(sOn, 'waveform_table_vs_trace_peak_abs_max_V'), ...
    sprintf('summary 缺 waveform_table_vs_trace_peak_abs_max_V; 有的波形键: %s', ...
    strjoin(fieldnamesLike(sOn, "waveform_"), ', ')));
rootA = rootAttrs(wf);
tc.verifyTrue(isfield(rootA, 'xcheck_peak_V_abs_max'), ...
    sprintf('文件根属性里没有 xcheck_peak_V_abs_max; 现有: %s', ...
    strjoin(sort(string(fieldnames(rootA))), ', ')));
if isfield(sOn, 'waveform_table_vs_trace_peak_abs_max_V')
    dPeak = double(sOn.waveform_table_vs_trace_peak_abs_max_V);
    tc.verifyLessThan(dPeak, 1.5 * double(W.scale_V), ...
        sprintf('事件表 peak_V 与波形复算 peak_V 差 %.3e V (scale_V=%.3e), 超出量化半步的合理量级', ...
        dPeak, double(W.scale_V)));
    if isfield(rootA, 'xcheck_peak_V_abs_max')
        tc.verifyEqual(double(rootA.xcheck_peak_V_abs_max), dPeak, 'AbsTol', 0, ...
            '同一偏差在 summary 与文件属性里给了两个数 (两处必须同源)');
    end
end

% --- 基线口径由生产路径自己写进文件 ---
% 单测只能证明"给 Nwin 时会自述"; 这一条证明 execute 真的给了它 (缺 baseline_n_tail_short
% 就等于发货的波形文件仍在说"噪声地板无法只凭本文件复算")。计数只判区间与整数性:
% 独立复算在 test_waveform_replay 里做过, 在这里重做一遍只会多养一份窗口算术。
tc.verifyEqual(char(rootA.baseline_applied(:)'), 'none', ...
    '发布集里的波形文件没声明基线口径, 或声明成了别的值');
blRule = char(rootA.baseline_rule(:)');
% 生产路径给了 Nwin, 所以规则文本里必须有窗口边界; 但"不可复算"这句话**该不该出现**
% 取决于窗口够不够长, 不取决于 Nwin 是否给出。发货窗长下每个事件都判不出, 于是文件里
% 必须同时出现 "Nwin=" 和 "cannot be recomputed from these traces" —— 只准出现前者就是
% 自说得好听。两个方向都判。
tc.verifyTrue(contains(blRule, "Nwin="), ...
    sprintf('生产路径没把 Nwin 交给写出器: %s', blRule));
nbTail = double(rootA.baseline_n_tail_short);
if nbTail == double(rootA.n_sub)
    tc.verifyTrue(contains(blRule, "cannot be recomputed from these traces"), ...
        sprintf('全部 %d 个事件都判不出噪声地板窗口, 规则文本却仍在给一条可复算的口风: %s', ...
        nbTail, blRule));
else
    tc.verifyFalse(contains(blRule, "EVERY stored event"), ...
        sprintf('只有 %g/%g 个事件判不出, 不该说"每一个": %s', ...
        nbTail, double(rootA.n_sub), blRule));
end
tc.verifyTrue(contains(blRule, "Nwin="), ...
    sprintf('baseline_rule 里没有窗口边界 Nwin=: %s', blRule));
tc.verifyTrue(isfield(rootA, 'baseline_n_tail_short'), ...
    sprintf('缺 baseline_n_tail_short; 现有根属性: %s', ...
    strjoin(sort(string(fieldnames(rootA))), ', ')));
nb = double(rootA.baseline_n_tail_short);
tc.verifyTrue(isscalar(nb) && nb == round(nb) && nb >= 0 && nb <= double(rootA.n_sub), ...
    sprintf('baseline_n_tail_short=%s 不是 [0, n_sub=%g] 内的整数', mat2str(nb), double(rootA.n_sub)));

% --- 报告页两态各印一行 ------------------------------------------------------
hOff = fileread(fullfile(td, 'off', 'results', 'report.html'));
hOn = fileread(fullfile(td, 'on', 'results', 'report.html'));
% 只在**波形那一行**内核状态词: 整份报告里 DISABLED/WRITTEN 这类词可能被别的行用到,
% 全页 contains 会把别处的文本当成这里的证据 (也会把无关行改成假阳性失败)。
rOff = string(extractRow(hOff));
rOn = string(extractRow(hOn));
tc.verifyTrue(contains(rOff, '事件波形落盘'), '报告必须有波形状态行 (关闭态也要有)');
tc.verifyTrue(contains(rOff, '<b>DISABLED</b>'), ...
    sprintf('关闭态那一行里没有 <b>DISABLED</b>, 实得: %s', rOff));
tc.verifyFalse(contains(rOff, '<b>WRITTEN</b>'), '关闭态那一行不得出现 WRITTEN');
tc.verifyTrue(contains(rOn, '<b>WRITTEN</b>'), ...
    sprintf('打开态那一行里没有 <b>WRITTEN</b>, 实得: %s', rOn));
tc.verifyFalse(contains(rOn, '<b>DISABLED</b>'), '打开态那一行不得出现 DISABLED');
tc.verifyTrue(contains(rOn, 'events/waveforms.h5'), ...
    '打开态要把文件路径印在波形行里, 读者才知道去哪儿找');

% --- 渲染层的异常披露分支: FAILED / 残留标志 / 未知状态词 ---------------------
% 这里只改内存里的 summary 再渲染一次, 不注入 execute 的异常 (那需要一个测试专用接缝,
% 代价与收益不成比例)。核的是"报告不许把失败或残留说成正常关闭"这句话在渲染层成立。
Rbad = Ron;
Rbad.summary.waveform_status = "FAILED";
Rbad.summary.waveform_partial_left = true;
pBad = fullfile(td, 'render_failed.html');
tepc.report.htmlReport(Rbad, pBad);
rBad = string(extractRow(fileread(pBad)));
tc.verifyTrue(contains(rBad, '<b>FAILED</b>'), ...
    sprintf('FAILED 状态词没印出来, 实得: %s', rBad));
tc.verifyTrue(contains(rBad, 'color:red'), 'FAILED 行必须是红色 (与 DISABLED 同色等于伪装成正常)');
tc.verifyTrue(contains(rBad, '[PARTIAL_LEFT'), ...
    'waveform_partial_left=true 时报告必须显式警告: 那半件会被清单哈希并提交 (判据匹配 ASCII 标记)');
% 未知状态词 (被改写/拼错) 不得与 DISABLED 同色: 那等于把不一致显示成"正常关闭"。
Runk = Ron;
Runk.summary.waveform_status = "WRITTEN_BUT_REALLY_NOT";
pUkn = fullfile(td, 'render_unknown.html');
tepc.report.htmlReport(Runk, pUkn);
rUkn = string(extractRow(fileread(pUkn)));
tc.verifyTrue(contains(rUkn, 'color:orange'), ...
    sprintf('未知状态词应当标橙色而不是与 DISABLED 同灰, 实得: %s', rUkn));
end

function row = extractRow(h)
% 取出"事件波形落盘"那一行的原文 (到行尾 </tr> 为止)。
% 用 regexp 取位置: contains 对 char 输入给的是**标量逻辑值**, find 它会返回 1 而不是偏移。
k = regexp(h, '事件波形落盘', 'once');
if isempty(k)
    row = "(整行都没有)";
else
    j = regexp(h(k:end), '</tr>', 'once');
    if isempty(j)
        row = h(k:min(numel(h), k + 700));
    else
        row = h(k:k + j + 3);
    end
end
end

% ==================== helpers (都有输出参数: 不被静态计数当成用例) ====================

function names = eventFileNames(d)
df = dir(fullfile(d, '*'));
keep = ~[df.isdir];
names = join(string({df(keep).name}), ",");
end

function s = readSummary(tc, p)
tc.verifyTrue(isfile(p), sprintf('缺 summary.json: %s', p));
s = jsondecode(fileread(p));
end

function k = uqKeys()
k = ["u_yF_rel", "u_nSamples", "u_Dcum_rel", "u_yF_CI95"];
end

function [diffs, nCmp] = differingEventDatasets(pA, pB)
% 逐个数据集比内容: 事件表 23 列, 按名字取比硬编码清单稳 (列名变了这里自动跟上)。
% 第二个输出是**比过的个数**: 调用方要用它挡住"名字集合空了导致 diffs 恒空"的假绿。
diffs = strings(0, 1);
nCmp = 0;
if ~isfile(pA) || ~isfile(pB)
    diffs = "events.h5 缺失 (两态都要在盘上才能比对)";
    return
end
info = h5info(pA);
gn = string({info.Groups.Name});
w = find(gn == "/events", 1);
if isempty(w)
    diffs = sprintf('events.h5 里没有 /events 组 (组名变了? 现有: %s)', strjoin(gn, ', '));
    return
end
names = string({info.Groups(w).Datasets.Name});
nCmp = numel(names);
for i = 1:numel(names)
    a = h5read(pA, '/events/' + names(i));
    b = h5read(pB, '/events/' + names(i));
    if ~isequaln(a, b)
        diffs(end + 1) = names(i); %#ok<AGROW>
    end
end
end

function n = countsN(root, key)
% docs/counts.json 里的一项生成计数 (显式 UTF-8 取字节: fileread 走本机码页)。
p = fullfile(root, 'docs', 'counts.json');
if ~isfile(p)
    error("tepc:tests:NoCounts", "缺 %s (先跑 tools/genCounts)", p);
end
fid = fopen(p, 'r', 'n', 'UTF-8');
b = fread(fid, inf, 'char=>char');
fclose(fid);
C = jsondecode(b(:)');
if ~isfield(C, 'counts') || ~isfield(C.counts, key)
    error("tepc:tests:NoCountsKey", "counts.json 里没有 counts.%s", key);
end
n = double(C.counts.(key));
end

function k = fieldnamesLike(s, pre)
fn = string(fieldnames(s));
k = sort(fn(startsWith(fn, pre)));
end

function v = manifestPaths(M)
% 清单行在 rec.files 里; jsondecode 对单元素可能给标量结构, 大括号取字段两种都给 cell。
if isstruct(M) && isfield(M, 'files') && ~isempty(M.files) && isfield(M.files, 'path')
    v = reshape(string({M.files.path}), [], 1);
else
    v = strings(0, 1);
end
end

function v = manifestSha(M)
if isstruct(M) && isfield(M, 'files') && ~isempty(M.files) && isfield(M.files, 'sha256')
    v = reshape(string({M.files.sha256}), [], 1);
else
    v = strings(0, 1);
end
end

function a = rootAttrs(path)
% 列出一个 HDF5 对象的全部根属性 (名字 -> 值)。属性名可能不是合法 MATLAB 字段名,
% 所以按名字逐个塞进结构体 (非法名字走 makeValidName, 名字本身仍会出现在 fieldnames 里)。
a = struct();
info = h5info(path);
if isempty(info.Attributes)
    return
end
for i = 1:numel(info.Attributes)
    nm = string(info.Attributes(i).Name);
    key = char(nm);
    if ~isvarname(key)
        key = matlab.lang.makeValidName(key);
    end
    a.(key) = info.Attributes(i).Value;
end
end
