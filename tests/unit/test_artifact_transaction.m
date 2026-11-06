function tests = test_artifact_transaction
%TEST_ARTIFACT_TRANSACTION 事务式发布 (staging -> commit) 的对外契约锁。
%   与既有文件的分工:
%     unit/test_io_transaction.m      测**构件** (canonicalJson / commitRun / runWriteStatus)
%     integration/test_release_transaction.m  测发布链的哈希与续跑语义
%     本文件                           测"提交前后**磁盘状态**不许说谎"这六条:
%       1) 成功 run 的已提交发布集完整且无 _work 残留;
%       2) 事件生成之后注入的失败必须被记账 (STATUS=incomplete + phase + error*.json);
%       3) UQ 可选且状态化: DISABLED 是诚实状态, 门禁不得判 FAIL, provenance 不得
%          把不存在的 uq.json 说成已产出;
%       4) 续跑/重放守卫: 换 seed 拒、覆盖已提交目录拒、合法续跑前 400 事件逐位不变、
%          completed 的 STATUS 必须带门禁计数;
%       5) events.h5 的 run_status 暂存期 PENDING_COMMIT, 提交后必须改口 COMMITTED。
%   全部小 N (250~400) 控制时长; 随机一律锚在显式 seed。
tests = functiontests(localfunctions);
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

%% ================= 契约 1: 提交后的发布集完整 =================
function test_committed_publish_set_is_complete_and_clean(tc)
% 断言点: 正式位置 (run 根, 不是 _work) 必须同时存在 13 件产物, 且 _work 不得残留。
%   改动前的事实: 运行期直接往正式目录写 + 无条件写 completed, 于是
%   "报告没生成"与"跑完了"在磁盘上长得一样 (实测 runs/20260920_122507476-22860faca47d/
%   是一个 logs/ figures/ 全空、连 STATUS.json 都没有的半成品目录)。
c = demoCfg(); c.uq.enabled = false;
rd = newRunDir('commit1');
R = tepc.run.execute(c, 'N', 400, 'Seed', 7, 'RunDir', rd);
tc.verifyEqual(string(R.status), "COMPLETED");
must = {'input/config_identity.json','input/config_resolved.json','input/calibration.json', ...
    'events/events.h5','results/spectrum.csv','results/summary.json','results/gates.json', ...
    'results/report.html','results/provenance.json','results/artifact_manifest.json', ...
    'results/geometry_audit.json','figures/diagnostic.png','logs/STATUS.json'};
for i = 1:numel(must)
    tc.verifyTrue(isfile(fullfile(rd, must{i})), sprintf( ...
        '已提交 run 缺 %s —— 缺任一件都不许把 STATUS 写成 completed', must{i}));
end
tc.verifyFalse(isfolder(fullfile(rd, '_work')), ...
    '提交后 _work 必须消失: 残留意味着 rename 没做完 (半提交状态被发布)');
% "哈希 == 盘上字节"是事务的全部意义: 逐件复算 (破一件即失败)
P = jsondecode(fileread(fullfile(rd, 'results', 'provenance.json')));
chk = {'input/config_identity.json','events/events.h5','results/spectrum.csv', ...
    'results/report.html','figures/diagnostic.png'};
for i = 1:numel(chk)
    rec = provSha(P, chk{i});
    tc.verifyTrue(~isempty(rec), sprintf('provenance 必须哈希 %s (实得字段集 %s)', ...
        chk{i}, strjoin(fieldnames(P.outputs)', ',')));
    if isempty(rec), continue; end
    tc.verifyEqual(char(rec), char(tepc.io.hashFile(fullfile(rd, chk{i}))), sprintf( ...
        '%s 的哈希与盘上字节不符: 提交后又被改过 (哈希=内容 的承诺当场失效)', chk{i}));
end
st = jsondecode(fileread(fullfile(rd, 'logs', 'STATUS.json')));
tc.verifyEqual(string(st.status), "completed");
tc.verifyEqual(string(st.runID), string(R.runDir.runID), ...
    'STATUS 的 runID 必须与目录一致 (续跑提交靠它判定同一个 run)');
end

%% ================= 契约 2: 事件之后的失败必须记账 =================
function test_failure_after_events_is_recorded(tc)
% 用**影子包**在 htmlReport 里注入失败 (事件已生成、提交未发生的那一段)。
%   断言点: execute 原样抛出注入标识符; STATUS=incomplete 且 phase=report;
%   logs/error*.json 记下根因; 发布集不得出现在正式位置; 暂存 h5 仍自称 PENDING_COMMIT。
%   改动前的事实: htmlReport 的异常被 catch 吞掉后仍无条件写 COMPLETED。
sd = fullfile(tempdir, sprintf('tepc_shadow_%08x', randi(intmax('uint32'))));
mkdir(fullfile(sd, '+tepc', '+report'));
fid = fopen(fullfile(sd, '+tepc', '+report', 'htmlReport.m'), 'w');
fprintf(fid, 'function htmlReport(R, outPath)\n');
fprintf(fid, '%%影子实现: 只用于注入失败, 绝不产出报告\n');
fprintf(fid, 'error(''tepc:test:Injected'', ''boom'');\nend\n');
fclose(fid);
realFile = which('tepc.report.htmlReport');
tc.verifyTrue(isUnder(realFile, fullfile(tepc.io.projectRoot(), 'src')), ...
    sprintf('前提: 影子之前 htmlReport 必须解析到 src/ 下的真实现, 实得 %s', realFile));
cleanup = onCleanup(@() dropShadow(sd));
addpath(sd, '-begin');
try, clear('tepc.report.htmlReport'); catch, end
sh = which('tepc.report.htmlReport');
tc.verifyTrue(isUnder(sh, sd), ...
    sprintf('影子包未生效 (which=%s), 这条测试将无条件通过 —— 必须先解决解析顺序再说', sh));
id = shadowId();
if id ~= "tepc:test:Injected"
    % 已加载进内存的真实现仍可能被复用: 清函数缓存后再探一次
    try, clear functions; catch, end
    id = shadowId();
end
tc.verifyEqual(id, "tepc:test:Injected", ...
    sprintf('调用影子函数没得到注入标识 (实得 "%s"): 包函数在调用期未被重新解析, 影子失效', id));
if id ~= "tepc:test:Injected", return; end

c = demoCfg(); c.uq.enabled = false;
rd = newRunDir('inject2');
% 注入在报告阶段的失败必须原样抛出 (吞掉=绿旗假账)
tc.verifyError(@() tepc.run.execute(c, 'N', 300, 'Seed', 99, 'RunDir', rd), ...
    'tepc:test:Injected');
sp = fullfile(rd, 'logs', 'STATUS.json');
tc.verifyTrue(isfile(sp), '失败必须写 STATUS.json (旧实现留下无人记账的空目录)');
if isfile(sp)
    st = jsondecode(fileread(sp));
    tc.verifyEqual(string(st.status), "incomplete", sprintf( ...
        '实得 status=%s: 非完成状态被写成 completed 就是"部分完成伪装成完成"', string(st.status)));
    tc.verifyEqual(string(st.phase), "report", ...
        sprintf('phase 必须是失败发生的阶段, 实得 %s', string(st.phase)));
    tc.verifyFalse(isempty(char(string(st.reason))), '非 completed 必须带 reason');
end
els = dir(fullfile(rd, 'logs', 'error*.json'));
tc.verifyTrue(~isempty(els), '根因必须落成 logs/error*.json, 不得只留在内存里');
if ~isempty(els)
    txt = fileread(fullfile(els(1).folder, els(1).name));
    tc.verifyTrue(contains(txt, 'tepc:test:Injected'), ...
        sprintf('error*.json 里找不到注入标识 (前 200 字符: %s)', txt(1:min(200,end))));
    tc.verifyTrue(contains(txt, 'report'), '错误记录必须带阶段, 否则事后无法定位是哪一步坏的');
end
tc.verifyFalse(isfile(fullfile(rd, 'results', 'report.html')), ...
    '未提交的失败不得在正式位置留下报告 (暂存区不许伪装成发布集)');
h5w = fullfile(rd, '_work', 'events', 'events.h5');
tc.verifyTrue(isfile(h5w), '事件阶段已完成 -> 暂存 h5 应在 _work 里等着 (raw/ 才可续跑)');
if isfile(h5w)
    tc.verifyEqual(string(h5readatt(h5w, '/', 'run_status')), "PENDING_COMMIT", ...
        '未提交的 h5 必须自称 PENDING_COMMIT —— 事务的判据是"产物不许说谎"');
end
tc.verifyTrue(isfolder(fullfile(rd, 'raw')), 'raw/ 必须留在 run 根 (取消/失败后仍可续跑)');
end

function tf = isUnder(s, sub)
% 路径前缀判断 (Windows 分隔符归一)
a = strrep(char(string(s)), '\', '/');
b = strrep(char(string(sub)), '\', '/');
tf = ~isempty(a) && ~isempty(strfind(lower(a), lower(b)));
end

function id = shadowId()
% 直接调一次影子函数, 拿它真实抛出的标识符 (which 说影子赢不等于调用也走影子)。
try
    tepc.report.htmlReport(struct(), 'noop');
    id = "<未抛出>";
catch e
    id = string(e.identifier);
end
end

function dropShadow(sd)
try, rmpath(sd); catch, end
try, clear('tepc.report.htmlReport'); catch, end
try, clear functions; catch, end
try, if isfolder(sd), rmdir(sd, 's'); end; catch, end
end

function test_no_shadow_package_left_behind(tc)
% 泄漏检查: 影子包若残留在 path 上, 会**污染整个套件** (后面每个 run 的报告都是假的)。
w = which('tepc.report.htmlReport');
tc.verifyFalse(isempty(w), 'tepc.report.htmlReport 必须可解析');
tc.verifyTrue(~isempty(strfind(strrep(char(w), '\', '/'), '/src/+tepc/+report/htmlReport.m')), ...
    sprintf('影子包泄漏: htmlReport 现在解析到 %s (应为 src/ 下的真实现)', w));
end

%% ================= 契约 3: UQ 可选 + 状态化 + provenance 诚实 =================
function test_uq_is_optional_and_status_bearing(tc)
% (a) cfg.uq.enabled=false -> uq_status=DISABLED 是**诚实状态**:
%     门禁 "UQ 完成度" 不得判 FAIL (DEMO 下 WARN 降级), 但 VALIDATED 下必须 FAIL 并阻断;
%     provenance 的已哈希产物清单不得出现 uq.json (文件根本不存在), 必须进 outputs_missing。
% (b) 开 UQ 但样本不足 -> INCOMPLETE + DEMO WARN, 且 uq.json 真被哈希。
% 门禁一律**按名字**取, 不按序号 (序号会随门禁增删漂移: 14 -> 16 就是现例)。
c = demoCfg(); c.uq.enabled = false;
rdA = newRunDir('uqoff3');
RA = tepc.run.execute(c, 'N', 300, 'Seed', 21, 'RunDir', rdA);
tc.verifyEqual(string(RA.summary.uq_status), "DISABLED", ...
    sprintf('实得 %s: 未开启必须显式说"没做", 不得留空或伪装 COMPLETE', string(RA.summary.uq_status)));
gA = gateByName(RA.gates, 'UQ 完成度');
tc.verifyEqual(numel(gA), 1, '门禁里必须恰有一项 "UQ 完成度"');
if numel(gA) == 1
    tc.verifyNotEqual(string(gA(1).status), "FAIL", sprintf( ...
        'uq.enabled=false 时门禁判了 %s —— "用户没要不确定度"被当成红线违规, DEMO 出口被无谓堵死', ...
        string(gA(1).status)));
    tc.verifyTrue(any(string(gA(1).status) == ["WARN", "PASS"]), ...
        sprintf('实得 %s: 必须是可见的降级 (WARN) 而不是无声通过或 FAIL', string(gA(1).status)));
end
PA = jsondecode(fileread(fullfile(rdA, 'results', 'provenance.json')));
tc.verifyFalse(isfile(fullfile(rdA, 'results', 'uq.json')), '前提: DISABLED 的 run 不该有 uq.json');
onA = string(fieldnames(PA.outputs));
tc.verifyFalse(any(contains(lower(onA), "uq")), sprintf( ...
    'provenance 声称哈希了 uq.json (%s) 而该文件不存在 —— 这就是"哈希了一个不存在的产物"的假账', ...
    strjoin(onA, ',')));
missA = missingNames(PA);
tc.verifyTrue(any(contains(missA, "uq")), sprintf( ...
    'outputs_missing 必须点名缺失的 uq.json (实得 %s): 缺失要显式记账而不是静默少一项', ...
    strjoin(missA, ',')));
% VALIDATED 下"根本没评估不确定度"必须是发布阻断项
RAv = RA; RAv.cfg.run.mode = "VALIDATED";
GAv = tepc.validation.runGate(RAv, RAv.analysis, RAv.runDir);
gAv = gateByName(GAv, 'UQ 完成度');
tc.verifyEqual(numel(gAv), 1);
if numel(gAv) == 1
    tc.verifyEqual(string(gAv(1).status), "FAIL", ...
        sprintf('VALIDATED + DISABLED 实得 %s: 已提交模式下必须阻断发布', string(gAv(1).status)));
end
tc.verifyFalse(GAv.release_eligible, 'FAIL 必须让 release_eligible 为假 (否则 FAIL 只是装饰)');

% (b) 开 UQ 但样本不足 -> INCOMPLETE (DEMO WARN, VALIDATED FAIL), 且 uq.json 真存在并被哈希
c2 = demoCfg(); c2.uq.enabled = true; c2.uq.minSamples = 10000;   % 远大于 nSamples=32
rdB = newRunDir('uqon3');
RB = tepc.run.execute(c2, 'N', 400, 'Seed', 22, 'RunDir', rdB);
tc.verifyEqual(string(RB.summary.uq_status), "INCOMPLETE", ...
    sprintf('样本 %s < minSamples 1e4 时实得 %s: 不完整必须写 INCOMPLETE', ...
    txtOr(RB.summary, 'u_nSamples'), string(RB.summary.uq_status)));
% INCOMPLETE 的**原因**必须是"样本数不足"这条规则, 而不是某个被吞回 summary 的异常 ——
% 否则状态词只是给"跑坏了"换了个名字, 读者仍分不清"没跑够样本"与"UQ 崩了"。
tc.verifyFalse(isfield(RB.summary, 'u_error'), sprintf( ...
    'UQ 阶段的异常被塞进 summary.u_error (%s): 状态词写着 INCOMPLETE 但真实原因是崩了', ...
    string(getfieldOr(RB.summary, 'u_error', ''))));
noteB = string(getfieldOr(RB.summary, 'uq_note', ''));
tc.verifyTrue(contains(noteB, "样本数"), ...
    sprintf('uq_note 必须点名不成立的具体规则 (实得 "%s")', noteB));
tc.verifyGreaterThan(getfieldOr(RB.summary, 'u_nSamples', 0), 0, ...
    'uq 必须真的跑过样本, 否则上面两条无从谈起');
gB = gateByName(RB.gates, 'UQ 完成度');
if numel(gB) == 1
    tc.verifyEqual(string(gB(1).status), "WARN", ...
        sprintf('DEMO + INCOMPLETE 实得 %s: 只能橙色降级并在水印体现', ...
        string(gB(1).status)));
end
PB = jsondecode(fileread(fullfile(rdB, 'results', 'provenance.json')));
tc.verifyTrue(isfile(fullfile(rdB, 'results', 'uq.json')), ...
    '开 UQ 的 run 必须真的产出 uq.json (状态写 INCOMPLETE 不等于可以不落文件)');
sB = provSha(PB, 'results/uq.json');
tc.verifyTrue(~isempty(sB), 'uq.json 存在时 provenance 必须哈希它');
if ~isempty(sB)
    tc.verifyEqual(char(sB), char(tepc.io.hashFile(fullfile(rdB, 'results', 'uq.json'))), ...
        'uq.json 的哈希必须可复算 (声称哈希了另一份内容就是假账)');
end
end

function v = getfieldOr(s, nm, dflt)
if isstruct(s) && isfield(s, nm) && ~isempty(s.(nm)), v = s.(nm); else, v = dflt; end
end

function t = txtOr(s, nm)
v = getfieldOr(s, nm, NaN);
if isnumeric(v), t = sprintf('%g', v); else, t = string(v); end
end

%% ================= 契约 4: 续跑 / 重放 / 覆盖守卫 =================
function test_resume_replay_and_overwrite_guards(tc)
% (c) 已提交目录上的**非续跑**重跑必须被拒 (而不是静默覆盖已发布产物集);
% (b) 换 seed 续跑必须被拒;
% (a) 同 seed 续跑到更大 N 必须成功, 且**前 400 事件逐位不变** (续跑不许重算历史);
% (d) completed 的 STATUS 必须带门禁计数 (跑完了 != 可以信)。
% 顺序刻意是 (c)->(b)->(a): (c) 测的是"干净的已提交目录", 那正是契约的前提。
oldEnv = getenv('TEPC_RUNS_DIR');
base = fullfile(tempdir, sprintf('tepc_txbase_%08x', randi(intmax('uint32'))));
mkdir(base);
cleanup = onCleanup(@() restoreBase(oldEnv, base));
setenv('TEPC_RUNS_DIR', base);
% 前提: 环境变量真的被 runDirs 吃 (否则"测试不污染仓库 runs/"是空的)
rdImp = tepc.io.runDirs(tepc.io.projectRoot());
tc.verifyTrue(startsWith(lower(string(rdImp.root)), lower(string(base))), ...
    sprintf('TEPC_RUNS_DIR 未被 honour: runDirs 给 %s (应以 %s 为基准)', rdImp.root, base));

c = demoCfg(); c.uq.enabled = false;
X = fullfile(base, 'X');
R1 = tepc.run.execute(c, 'N', 400, 'Seed', 7, 'RunDir', X);
tc.verifyEqual(string(R1.status), "COMPLETED");
% (c) 非续跑重跑同一已提交目录 -> 拒, 且已发布产物一字不改
%   必须被拒的理由: 静默覆盖会让 provenance 刚哈希过的产物当场失真 (哈希=内容 破防)。
specCsv = fullfile(X, 'results', 'spectrum.csv');
shaBefore = tepc.io.hashFile(specCsv);
tc.verifyError(@() tepc.run.execute(c, 'N', 400, 'Seed', 7, 'RunDir', X), ...
    'tepc:run:AlreadyCommitted');
tc.verifyEqual(shaBefore, char(tepc.io.hashFile(specCsv)), ...
    '被拒的重跑不得改动已发布产物字节');
% (b) 换 seed 续跑 -> 拒 (否则事件集是两种随机机制的杂交)
tc.verifyError(@() tepc.run.execute(c, 'N', 800, 'Seed', 8, 'RunDir', X, 'Resume', true), ...
    'tepc:run:ResumeGuard');
% (b2) 一次**被拒的续跑**不得把已发布 run 的 STATUS 改写成非 completed:
%      已发布集一个字节都没动, 状态却被降级; 更糟的是 STATUS=completed 同时是 (c)
%      的守卫依据, 被改写等于自毁防线 (下一次覆盖重跑就不再被拒)。
stX = jsondecode(fileread(fullfile(X, 'logs', 'STATUS.json')));
tc.verifyEqual(string(stX.status), "completed", sprintf( ...
    ['被拒的续跑把已发布 run 的 STATUS 改成了 "%s" (原因 %s): ' ...
     '守卫拒绝不该产生任何记账变化'], ...
    string(stX.status), string(field_or_empty(stX, 'reason'))));
% (b3) 防线自毁的直接后果: 一次被拒的尝试之后, 覆盖重跑仍必须被拒。
%   AlreadyCommitted 判据是 STATUS=="completed", 所以上一条一旦被破坏, 这里就会
%   让一次"静默覆盖已发布产物集"的整跑跑完 —— 本条就是那个越权的现场取证。
tc.verifyError(@() tepc.run.execute(c, 'N', 400, 'Seed', 7, 'RunDir', X), ...
    'tepc:run:AlreadyCommitted');
% (a) 合法续跑: 同 seed、更大 N; 历史事件必须逐位不变
cols = {'/events/event_id', '/events/t0_s', '/events/y_keV_per_um', '/events/weight', ...
    '/events/flags', '/events/charge_C', '/events/peak_V', '/events/adc_code'};
before = cell(1, numel(cols));
for i = 1:numel(cols)
    before{i} = h5read(fullfile(X, 'events', 'events.h5'), cols{i});
end
R2 = tepc.run.execute(c, 'N', 800, 'Seed', 7, 'RunDir', X, 'Resume', true);
tc.verifyEqual(string(R2.status), "COMPLETED");
tc.verifyEqual(R2.summary.nEvents, 800);
tc.verifyEqual(R2.summary.resumed_from, 400, '必须如实记录续跑起点');
fNew = fullfile(X, 'events', 'events.h5');
for i = 1:numel(cols)
    a = before{i}(:); b = h5read(fNew, cols{i}); b = b(1:numel(a));
    tc.verifyTrue(numel(h5read(fNew, cols{i})) == 800, ...
        sprintf('%s 行数应为 800 (续跑后), 实得 %d', cols{i}, numel(h5read(fNew, cols{i}))));
    tc.verifyTrue(isequaln(a, b), sprintf( ...
        '%s 的前 400 个事件与续跑前不逐位相同 —— 续跑重算了历史 (RNG 子流/DAQ 携带被破坏)', cols{i}));
end
% (d) completed 的 STATUS 必须带门禁计数 (n_fail/n_warn/n_not_evaluated/released)
st = jsondecode(fileread(fullfile(X, 'logs', 'STATUS.json')));
tc.verifyEqual(string(st.status), "completed");
tc.verifyTrue(isfield(st, 'extra'), ...
    'completed 的 STATUS 必须携带门禁计数 (runWriteStatus 的 Extra): 只有"跑完了"没有"能不能信"');
if isfield(st, 'extra')
    fn = string(fieldnames(st.extra));
    for k = ["n_fail", "n_warn", "n_not_evaluated", "released"]
        tc.verifyTrue(any(fn == k), sprintf('STATUS.extra 缺 %s 字段 (实得 %s)', k, strjoin(fn, ',')));
    end
    if any(fn == "n_fail"), tc.verifyEqual(st.extra.n_fail, R2.gates.nFail, ...
        'STATUS 记的 FAIL 数必须与门禁对象一致 (不一致就是两处各写各的)'); end
    if any(fn == "n_not_evaluated")
        tc.verifyEqual(st.extra.n_not_evaluated, R2.gates.nNotEvaluated);
    end
end
end

function restoreBase(oldEnv, base)
try
    if isempty(oldEnv), setenv('TEPC_RUNS_DIR', ''); else, setenv('TEPC_RUNS_DIR', oldEnv); end
catch
end
try, if isfolder(base), rmdir(base, 's'); end; catch, end
end

%% ================= 契约 5: h5 run_status 提交后必须改口 =================
function test_events_h5_run_status_updated_at_commit(tc)
% 暂存期写 PENDING_COMMIT; 提交 (改名) 之后必须更新为 COMMITTED。
%   不更新就是落盘数据自称"未提交", 与同一目录里的 STATUS=completed 互相矛盾 ——
%   读者无法判断这份 events.h5 是发布物还是半成品 (事务的全部意义即在此)。
c = demoCfg(); c.uq.enabled = false;
rd = newRunDir('h5attr5');
R = tepc.run.execute(c, 'N', 250, 'Seed', 5, 'RunDir', rd);
f = fullfile(rd, 'events', 'events.h5');
tc.verifyTrue(isfile(f), '前提: 已提交的 events.h5 必须存在');
v = string(h5readatt(f, '/', 'run_status'));
tc.verifyEqual(v, "COMMITTED", sprintf( ...
    '提交后 run_status 仍是 "%s": 没有任何代码把暂存态改口为已提交 (或就地改写属性失败未记账)', v));
% 就地改属性不得顺手破坏同文件的其它属性与数据
tc.verifyEqual(string(h5readatt(f, '/', 'config_sha256')), string(R.config_sha256), ...
    '更新 run_status 后 config_sha256 属性必须仍在且仍等于身份哈希');
tc.verifyEqual(double(h5readatt(f, '/', 'seed')), 5, 'seed 属性不得在改写中丢失');
w = h5read(f, '/events/weight');
tc.verifyEqual(numel(w), 250, 'run_status 就地更新不得截断/改写事件数据');
end

%% ================= 辅助 (不得以 test_ 开头) =================
function g = gateByName(G, nm)
g = G.items(strcmp({G.items.name}, nm));
end

function s = provSha(P, relpath)
% 取 provenance 对某产物的哈希 (字段名是 matlab.lang.makeValidName(名字) 的结果,
% 名字里的点被换成下划线, 所以这里按"下划线化"的键找, 不做二次猜测)。
key = strrep(strrep(char(string(relpath)), '/', '_'), '.', '_');
f = fieldnames(P.outputs);
i = find(strcmp(f, key), 1);
if isempty(i), s = []; else, s = string(P.outputs.(f{i})); end
end

function m = missingNames(P)
if ~isfield(P, 'outputs_missing') || isempty(P.outputs_missing)
    m = strings(0, 1);
elseif iscell(P.outputs_missing)
    m = string(P.outputs_missing(:));
else
    m = string(P.outputs_missing);
end
end

function v = field_or_empty(s, nm)
if isfield(s, nm), v = string(s.(nm)); else, v = "<无字段>"; end
end

function p = newRunDir(tag)
% 每次调用一个唯一且预先清空的 run 目录 (tempdir 下, 不污染仓库 runs/)。
%   刻意不在测试函数内 onCleanup 删除: 产物是"事后审计"的证据, 保留在临时目录里
%   便于失败时人工复核; OS 负责回收 tempdir。
p = sprintf('%s%c%s', tempdir, filesep, ...
    sprintf('tepc_txart_%s_%s_%04x', tag, ...
    char(string(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))), randi(65535)));
if isfolder(p), rmdir(p, 's'); end
mkdir(p);
end
