function tests = test_io_transaction
%TEST_IO_TRANSACTION canonical 哈希 / 状态词汇 / 提交改名 三件套的单元锁。
%   这些是"发布判定"的地基: 哈希必须是内容寻址的, 状态必须区分"跑完/跑坏",
%   提交必须既不嵌套也不覆盖。全部无随机、无 IO 依赖 (除 tempdir)。
tests = functiontests(localfunctions);
end

%% ---------------- canonicalJson ----------------
function test_canonicalJson_is_field_order_insensitive(tc)
a = struct('b', 1, 'a', struct('y', 2, 'x', 3));
b = struct('a', struct('x', 3, 'y', 2), 'b', 1);
tc.verifyEqual(tepc.io.canonicalJson(a), tepc.io.canonicalJson(b), ...
    '内容相同、字段书写顺序不同的配置必须得到同一 canonical 文本');
tc.verifyEqual(tepc.io.hashText(tepc.io.canonicalJson(a)), ...
    tepc.io.hashText(tepc.io.canonicalJson(b)));
end

function test_canonicalJson_drops_only_named_volatile_fields(tc)
a = struct('created_utc', '2026-01-01', 'v', 1);
b = struct('created_utc', '2026-09-20', 'v', 1);
tc.verifyEqual(tepc.io.canonicalJson(a, {'created_utc'}), ...
    tepc.io.canonicalJson(b, {'created_utc'}), '剔除易变字段后应相等');
tc.verifyFalse(strcmp(tepc.io.canonicalJson(a), tepc.io.canonicalJson(b)), ...
    '不剔除时时间戳必须参与哈希 (否则"剔除"就没有边界)');
end

function test_canonicalJson_number_formats_are_roundtrippable(tc)
x = struct('i', 2000, 'r', 1/3, 'e', 1e-9, 'big', 1e21);
s = tepc.io.canonicalJson(x);
tc.verifyTrue(contains(s, '"i":2000'), sprintf('整值必须写成 2000, 实得 %s', s));
tc.verifyTrue(contains(s, '"r":0.33333333333333331'), ...
    sprintf('1/3 必须以 17 位精确形式出现, 实得 %s', s));
y = jsondecode(s);
tc.verifyEqual(y.i, 2000);
tc.verifyEqual(y.r, 1/3, 'RelTol', 0);       % 17 位保证逐位往返
tc.verifyEqual(y.big, 1e21, 'RelTol', 0);
end

function test_canonicalJson_refuses_non_finite_instead_of_null(tc)
% 静默把 NaN 写成 null 正是本项目反复出现的"看起来合法其实无意义"那一类失效。
tc.verifyError(@() tepc.io.canonicalJson(struct('v', NaN)), 'tepc:io:CanonicalNonFinite');
tc.verifyError(@() tepc.io.canonicalJson(struct('v', Inf)), 'tepc:io:CanonicalNonFinite');
end

function test_canonicalJson_preserves_array_element_order(tc)
% 字段名排序 != 数据排序: cell/结构数组的元素顺序有语义, 绝不能被排掉。
a = struct('s', {{'alpha', 'beta'}});
b = struct('s', {{'beta', 'alpha'}});
tc.verifyFalse(strcmp(tepc.io.canonicalJson(a), tepc.io.canonicalJson(b)), ...
    '单元数组元素顺序必须参与哈希');
end

function test_canonicalJson_rejects_unsupported_types(tc)
tc.verifyError(@() tepc.io.canonicalJson(struct('f', @sin)), ...
    'tepc:io:CanonicalUnsupported', '函数句柄必须显式拒绝而不是悄悄丢字段');
end

%% ---------------- writeCanonicalJson ----------------
function test_writeCanonicalJson_hash_matches_file_bytes(tc)
% 核心契约: "对文本算的哈希" == "对盘上文件算的哈希"。破这条, config_sha256 就是装饰品。
p = fullfile(tempdir, sprintf('tepc_canon_%d.json', randi(1e9)));
cleanup = onCleanup(@() deleteFile(p));
x = struct('k_cn', '中文值', 'v', [1 2 3], 'sub', struct('a', 0.1));
out = tepc.io.writeCanonicalJson(p, x);
tc.verifyTrue(isfile(p));
tc.verifyEqual(numel(out.sha256), 64);
tc.verifyEqual(out.sha256, tepc.io.hashFile(p), '内存文本哈希必须等于文件哈希');
tc.verifyEqual(out.sha256, tepc.io.hashText(tepc.io.canonicalJson(x)));
tc.verifyEqual(out.nBytes, dir(p).bytes);
end

function test_writeCanonicalJson_fails_loudly_on_unwritable_path(tc)
bad = fullfile(tempdir, sprintf('tepc_no_such_dir_%d', randi(1e9)), 'x.json');
tc.verifyError(@() tepc.io.writeCanonicalJson(bad, struct('a', 1)), 'tepc:io:WriteFailed');
end

%% ---------------- runWriteStatus ----------------
function test_status_vocabulary_is_enforced(tc)
d = tempdir;
tc.verifyError(@() tepc.io.runWriteStatus(d, 'COMPLETE'), 'tepc:io:BadStatus', ...
    '拼错的状态必须拒绝 (COMPLETED/COMPLETE 混用会让读者误判)');
% 非 completed 必须带 reason —— "部分完成"不得伪装成完成
tc.verifyError(@() tepc.io.runWriteStatus(d, 'incomplete'), 'tepc:io:StatusNeedsReason');
tc.verifyError(@() tepc.io.runWriteStatus(d, 'cancelled'), 'tepc:io:StatusNeedsReason');
s = tepc.io.runWriteStatus(d, 'incomplete', 'Reason', "报告写失败", 'Phase', "report");
tc.verifyEqual(s.status, 'incomplete');
tc.verifyTrue(isfile(fullfile(d, 'STATUS.json')), '写入口必须真的落盘');
end

%% ---------------- commitRun ----------------
function test_commit_moves_publish_set_and_rebases_paths(tc)
[rd, rdWork] = makeRunDirs(); %#ok<ASGLU>
tc.verifyTrue(isfile(fullfile(rd.work.events, 'events.h5')));
tc.verifyFalse(isfile(fullfile(rd.events, 'events.h5')), '提交前正式目录必须为空');
[rd2, moved] = tepc.io.commitRun(rd);
tc.verifyTrue(isfile(fullfile(rd2.events, 'events.h5')), '提交后产物在 run 根');
tc.verifyEqual(rd2.events, rdWork.events_final);
tc.verifyEqual(numel(moved), 4);
% raw/ 与 logs/ 从一开始就在根: 续跑状态绝不能被事务化 (否则 Resume 找不到 checkpoint)
tc.verifyTrue(isfile(fullfile(rd2.root, 'raw', 'checkpoint.json')));
tc.verifyTrue(isfolder(fullfile(rd2.root, 'logs')));
tc.verifyEqual(rd2.raw, fullfile(rd2.root, 'raw'), 'raw/ 必须始终在 run 根 (续跑状态不被事务化)');
end

function test_commit_refuses_to_clobber_or_nest(tc)
% MATLAB 的 movefile(a,b) 当 b 已存在时是"移入", 会造出 results/results 嵌套。
[rd, ~] = makeRunDirs();
target = rd.results;
if ~isfolder(target), mkdir(target); end
w = fopen(fullfile(target, 'report.html'), 'w'); fprintf(w, '旧产物'); fclose(w);
tc.verifyError(@() tepc.io.commitRun(rd), 'tepc:run:CommitTargetBusy', ...
    '已提交产物不得被第二次提交覆盖或移入');
if exist(fullfile(target, 'results'), 'dir')
    error("tepc:tests:NestedAfterRefusal", "拒绝失败: 目标目录里出现了嵌套 results/");
end
end

function test_commit_is_idempotent_for_missing_stages(tc)
% 某阶段没产出 (例如无图) 不算失败: 只提交存在的东西。
[rd, ~] = makeRunDirs();
rmdir(rd.work.figures, 's');
rd2 = tepc.io.commitRun(rd);
tc.verifyTrue(isfile(fullfile(rd2.results, 'report.html')));
end

%% ---------------- helpers (不得以 test 开头) ----------------
function deleteFile(p)
try, if isfile(p), delete(p); end; catch, end
end

function [rd, info] = makeRunDirs()
root = tempname();                       % 唯一且不存在, 避免 randi 撞名
mkdir(root);
% 根目录只建 logs/ 与 raw/ (与新版 runDirs 的契约一致)
mkdir(fullfile(root, 'logs')); mkdir(fullfile(root, 'raw'));
f = fopen(fullfile(root, 'raw', 'checkpoint.json'), 'w'); fprintf(f, '{}'); fclose(f);
pub = {'input','events','results','figures'};
work = struct();
for i = 1:numel(pub)
    d = fullfile(root, '_work', pub{i});
    mkdir(d);
    w = fullfile(d, [pub{i} '.h5']);
    if strcmp(pub{i}, 'results'), w = fullfile(d, 'report.html'); end
    fid = fopen(w, 'w'); fprintf(fid, 'x'); fclose(fid);
    work.(pub{i}) = d;
end
rd = struct('root', root, 'work', work, ...
    'raw', fullfile(root,'raw'), 'logs', fullfile(root,'logs'), ...
    'project_root', root);
for i = 1:numel(pub)
    rd.(pub{i}) = fullfile(root, pub{i});      % 提交后的目标位置
end
info.events_final = fullfile(root, 'events');
end
