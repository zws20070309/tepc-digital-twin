function tests = test_release_transaction
%TEST_RELEASE_TRANSACTION 发布链契约: seed 进哈希 / 事务提交 / UQ 状态 / 续跑守卫。
%   与 unit/test_io_transaction.m 的分工: 那边测**构件** (canonicalJson/commitRun/
%   runWriteStatus), 这里测**整条 execute 链**的对外承诺。
%   用小 N (300/600) 控制运行时间; 所有随机锚在显式 seed 上。
tests = functiontests(localfunctions);
end

function setupOnce(testData)
import matlab.unittest.fixtures.Fixture
% run 产物一律落在套件设定的 TEPC_RUNS_DIR (runAllTests 已重定向到临时目录)
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function test_seed_override_changes_config_hash(tc)
% 同一配置只改 API seed 时 config_sha256 必变。
% 改动前不可能通过 —— 旧顺序在哈希之后才把 args.Seed 写回 cfg。
c = demoCfg();
Ra = tepc.run.execute(c, 'N', 300, 'Seed', 12345);
Rb = tepc.run.execute(c, 'N', 300, 'Seed', 999);
tc.verifyFalse(strcmp(Ra.config_sha256, Rb.config_sha256), ...
    '只改 API seed 必须改变 config_sha256 (否则续跑守卫是可绕过的)');
tc.verifyEqual(Ra.summary.seed, 12345);
tc.verifyEqual(Rb.summary.seed, 999);
tc.verifyEqual(Rb.provenance.effective_seed, 999, 'provenance 必须记生效 seed');
n = {Rb.provenance.api_overrides.name};
nS = string(n);   % strcmp([装着 string 的 cell], "Seed") 恒 false (实测 [false false]), 必须用 string 比较
tc.verifyTrue(any(nS == "Seed"), 'API 覆盖必须被记录');
end

function test_identity_hash_equals_bytes_on_disk(tc)
% "哈希=盘上内容"必须可被第三方独立复算 (canonical 文本 == 文件字节 == 哈希)。
c = demoCfg();
R = tepc.run.execute(c, 'N', 300, 'Seed', 31337);
p = fullfile(R.runDir.input, 'config_identity.json');
tc.verifyTrue(isfile(p), '必须写出 config_identity.json (身份文件)');
tc.verifyEqual(R.config_sha256, tepc.io.hashFile(p), ...
    'config_sha256 必须等于身份文件的 SHA-256');
tc.verifyEqual(numel(R.config_sha256), 64);
end

function test_same_seed_is_reproducible(tc)
% 同配置同 seed 两次独立运行: 谱文件字节相同, 事件列逐位相同。
c = demoCfg();
R1 = tepc.run.execute(c, 'N', 300, 'Seed', 4242);
R2 = tepc.run.execute(c, 'N', 300, 'Seed', 4242);
tc.verifyEqual(tepc.io.hashFile(fullfile(R1.runDir.results,'spectrum.csv')), ...
    tepc.io.hashFile(fullfile(R2.runDir.results,'spectrum.csv')), ...
    '同 seed 双跑 spectrum.csv 必须逐字节相同');
tc.verifyEqual(R1.config_sha256, R2.config_sha256);
E1 = tepc.io.readEventsH5(R1.eventsPath);
E2 = tepc.io.readEventsH5(R2.eventsPath);
cols = {'y_keV_per_um','weight','flags','charge_C','peak_V','adc_code','t0_s'};
for i = 1:numel(cols)
    a = E1.ev.(cols{i}); b = E2.ev.(cols{i});
    % 必须用 isequaln: 不可测事件的 y 是 NaN, 而 isequal(NaN,NaN) 为假 ——
    % 用 isequal 会把"两次同 seed 完全一致"误判成不一致 (我第一版就踩了)。
    tc.verifyTrue(isequaln(a, b), sprintf('%s 列在两次同 seed 运行间不一致', cols{i}));
end
end

function test_run_directory_is_committed_not_partial(tc)
% 不得留下"看起来完成了"的部分目录。
c = demoCfg();
R = tepc.run.execute(c, 'N', 300, 'Seed', 5150);
root = R.runDir.root;
must = {'logs/STATUS.json','input/config_identity.json','input/config_resolved.json', ...
    'events/events.h5','results/spectrum.csv','results/summary.json', ...
    'results/gates.json','results/provenance.json','results/artifact_manifest.json', ...
    'results/report.html','figures/diagnostic.png','raw/checkpoint.json'};
for i = 1:numel(must)
    tc.verifyTrue(isfile(fullfile(root, must{i})), ...
        sprintf('COMPLETED 的 run 必须有 %s (缺任何一件都不许写 completed)', must{i}));
end
tc.verifyFalse(isfolder(fullfile(root, '_work')), '提交后 _work 必须被清空');
st = jsondecode(fileread(fullfile(root, 'logs', 'STATUS.json')));
tc.verifyEqual(string(st.status), "completed");
tc.verifyEqual(string(st.runID), string(R.runDir.runID), ...
    'STATUS 里的 runID 必须与目录一致 (续跑提交靠它判定同一个 run)');
end

function test_manifest_covers_and_provenance_hashes_it(tc)
c = demoCfg();
R = tepc.run.execute(c, 'N', 300, 'Seed', 6161);
mp = fullfile(R.runDir.results, 'artifact_manifest.json');
M = jsondecode(fileread(mp));
tc.verifyTrue(isfield(M,'files') && ~isempty(M.files), '清单必须列出产物');
tc.verifyEqual(numel({M.files.sha256}), numel(M.files));
for i = 1:numel(M.files)
    f = fullfile(R.runDir.root, strrep(char(M.files(i).path), '/', filesep));
    tc.verifyTrue(isfile(f), sprintf('清单里的 %s 必须真实存在', M.files(i).path));
    tc.verifyEqual(tepc.io.hashFile(f), char(M.files(i).sha256), ...
        sprintf('清单对 %s 的哈希必须可复算', M.files(i).path));
end
pn = fieldnames(R.provenance.outputs);
tc.verifyTrue(any(contains(string(pn), "artifact_manifest")), ...
    'provenance 必须哈希清单本身 (哈希集合必须覆盖 manifest 文件)');
tc.verifyEqual(numel(pn), 10, '身份/解析/刻度/事件/谱/摘要/UQ/清单/报告/图 = 10 项');
tc.verifyFalse(any(contains(string(pn), "gates")), ...
    'gates.json 刻意不进哈希集: 它在 provenance 之后还会刷新一次, 记了就是假账');
end

function test_uq_incomplete_is_surfaced_not_swallowed(tc)
% UQ 不完整时 summary / gates / HTML 三处一致显示, 且
% DEMO = 橙色降级(WARN, 不阻断 DEMO 出报告), VALIDATED = 阻断发布(FAIL)。
c = demoCfg();
c.uq.minSamples = 10000;                       % 远高于 nSamples -> 判不完整
R = tepc.run.execute(c, 'N', 300, 'Seed', 7171);
tc.verifyEqual(string(R.summary.uq_status), "INCOMPLETE");
tc.verifyFalse(isempty(R.summary.uq_note), '必须说明为什么不完整');
g = R.gates.items(strcmp({R.gates.items.name}, 'UQ 完成度'));
tc.verifyEqual(numel(g), 1);
tc.verifyEqual(string(g(1).status), "WARN", ...
    'DEMO 模式下 UQ 不完整必须是橙色降级而不是无声通过');
htxt = fileread(fullfile(R.runDir.results, 'report.html'));
tc.verifyTrue(contains(htxt, 'u(y_F) 评估状态'), '报告必须固定印出 UQ 状态行');
tc.verifyTrue(contains(htxt, 'INCOMPLETE'), '报告里的状态必须与 summary 一致');
tc.verifyTrue(contains(R.gates.watermark, 'WARN'), ...
    sprintf('水印必须体现降级, 实得 %s', char(R.gates.watermark)));

% VALIDATED 分支不可端到端跑 (validate 直接拒绝 mode=VALIDATED), 用同一 R 合成复算。
Rv = R;
Rv.cfg.run.mode = "VALIDATED";
Gv = tepc.validation.runGate(Rv, R.analysis, R.runDir);
gv = Gv.items(strcmp({Gv.items.name}, 'UQ 完成度'));
tc.verifyEqual(string(gv(1).status), "FAIL", ...
    'VALIDATED 模式下同一条件必须变成 FAIL 并阻断发布');
tc.verifyFalse(Gv.release_eligible, 'FAIL 必须让 release_eligible 为假');
end

function test_resume_guards_reject_mismatch_and_legacy(tc)
c = demoCfg();
% 目录名必须**每次唯一**且用完即删: 用 datetime('now','JDN') 时同一天内所有用例
% 撞同一个目录 (本文件既有 A 又有续跑, 撞目录会把上一个用例的状态读成自己的),
% 而且留下的 run 会让 docs/counts.json 的仓库文件数漂移。
tag = randi(1e9);
rd = fullfile(tempdir, sprintf('tepc_tx_%d', tag));
cln = onCleanup(@() rmdir(rd, 's'));
R = tepc.run.execute(c, 'N', 300, 'Seed', 8080, 'RunDir', rd);
tc.verifyEqual(string(R.status), "COMPLETED");
% (a) 换 seed 续跑必须拒
tc.verifyError(@() tepc.run.execute(c, 'N', 600, 'Seed', 1234, ...
    'RunDir', rd, 'Resume', true), 'tepc:run:ResumeGuard');
% (b) v1 checkpoint (没有 checkpoint_schema_version) 必须拒
cp = fullfile(rd, 'raw', 'checkpoint.json');
j = jsondecode(fileread(cp));
tc.verifyEqual(string(j.checkpoint_schema_version), "2.0");
tc.verifyEqual(j.chunk_size, c.run.chunkSize);
tc.verifyTrue(isfield(j,'lastTrigEnd'), 'DAQ 状态必须跨块携带');
jv1 = rmfield(j, 'checkpoint_schema_version');
tepc.io.writeJson(cp, jv1);
tc.verifyError(@() tepc.run.execute(c, 'N', 600, 'Seed', 8080, ...
    'RunDir', rd, 'Resume', true), 'tepc:run:LegacyCheckpoint');
% (c) 合法续跑: 同 seed、N 更大
tepc.io.writeJson(cp, j);
R2 = tepc.run.execute(c, 'N', 600, 'Seed', 8080, 'RunDir', rd, 'Resume', true);
tc.verifyEqual(string(R2.status), "COMPLETED");
tc.verifyEqual(R2.summary.nEvents, 600);
tc.verifyEqual(R2.summary.resumed_from, 300);
end

function test_cancel_writes_auditable_status(tc)
% 取消不是失败, 但必须留下可审计状态 (旧实现这段位于死代码之后从不执行)。
c = demoCfg();
cflag = fullfile(tempdir, sprintf('tepc_tx_cancel_%d.flag', randi(1e9)));
fid = fopen(cflag,'w'); fprintf(fid,'c'); fclose(fid);
cleanup = onCleanup(@() delete(cflag));
rd = fullfile(tempdir, sprintf('tepc_tx_cancel_%d', randi(1e9)));
cln2 = onCleanup(@() rmdir(rd, 's'));
tc.verifyError(@() tepc.run.execute(c, 'N', 5000, 'CancelFlag', cflag, 'RunDir', rd), ...
    'tepc:run:CancelRequested');
sp = fullfile(rd, 'logs', 'STATUS.json');
tc.verifyTrue(isfile(sp), '取消也必须写 STATUS.json');
st = jsondecode(fileread(sp));
tc.verifyEqual(string(st.status), "cancelled");
tc.verifyFalse(isempty(char(string(st.reason))), '取消状态必须带原因');
tc.verifyFalse(isfile(fullfile(rd,'results','report.html')), ...
    '取消的 run 不得有已提交报告 (未提交即不发布)');
tc.verifyTrue(isfolder(fullfile(rd,'raw')), 'raw/ 必须保留以便续跑');
end
