function tests = test_run_dirs_env
%TEST_RUN_DIRS_ENV TEPC_RUNS_DIR 的三种落点：能用、要建、建不出。
%   起因 (实测代价): 旧实现的条件是 `~isempty(env) && isfolder(env) && root==projectRoot`,
%   于是"设了变量但目录还不存在"时整条重定向**静默作废**, run 全部落进仓库 runs/。
%   本文件的三条各自挡住一种退化:
%     created_and_said   目录不存在 → 建出来 + 点名 warning + run 落在它下面 (且幂等)
%     explicit_base      调用方显式给了基准 → 环境变量必须被忽略, 也不许顺手建目录
%     unusable_errors    路径根本建不出来 (父是文件) → 报错, 而不是退回仓库里悄悄写
tests = functiontests(localfunctions);
end

%% ============================================================ 用例

function test_created_and_said(tc)
root = tepc.io.projectRoot();
base = scratchBase('cre');
prev = getenv('TEPC_RUNS_DIR');
cleanup = onCleanup(@() restoreEnv(prev, base));  %#ok<NASGU>
% MATLAB 默认按"每会话一次"投警告: 同一进程里第二次跑就不会再响, 判据会随前序用例
% 是否存在而翻转。off→on 复位该 id 的"已见过"状态, 使本锁与进程历史无关。
% (三参数形式不存在 'always' 这个取值 —— 写成 warning('on',id,'always') 是运行期错误。)
prevW = warning('off', 'tepc:io:RunsDirCreated');
cleanupW = onCleanup(@() warning(prevW));  %#ok<NASGU>
warning('on', 'tepc:io:RunsDirCreated');
setenv('TEPC_RUNS_DIR', base);          % 故意设成一个还不存在的目录 (本条要测的就是这一支)
tc.verifyFalse(isfolder(base), '夹具要求这个目录一开始不存在, 否则测不到"建"这一支');

% 第一次: 必须响, 而且响的是这一个 id (不检查 id 的 verifyWarning 会放过任何杂音)
tc.verifyWarning(@() tepc.io.runDirs(root), 'tepc:io:RunsDirCreated');
tc.verifyTrue(isfolder(base), 'warning 说了要建却没建出来: 话与行为不符');
lastwarn('');
rd2 = tepc.io.runDirs(root);                    %#ok<NASGU> 第二次: 幂等, 不得再 warn
[~, iw] = lastwarn;
tc.verifyTrue(isempty(string(iw)) || ~contains(string(iw), 'RunsDirCreated'), ...
    sprintf('第二次调用仍报 RunsDirCreated (%s): 说明没真建, 或每次都重算', string(iw)));
s = string(rd2.root);
tc.verifyTrue(startsWith(s, string(base)), ...
    sprintf('run 根目录没落在环境变量之下: %s', char(s)));
tc.verifyEqual(string(rd2.output_root), string(base), ...
    'output_root 没记成重定向后的基准: 事后无从核对产物写到了哪');
end

function test_explicit_base(tc)
root = tepc.io.projectRoot();
base = scratchBase('exp');
prev = getenv('TEPC_RUNS_DIR');
cleanup = onCleanup(@() restoreEnv(prev, base));  %#ok<NASGU>
setenv('TEPC_RUNS_DIR', base);
other = fullfile(tempdir, sprintf('tepc_rdenv_explicit_%d', feature('getpid')));
if ~isfolder(other), mkdir(other); end
cleanupOther = onCleanup(@() rmdir(other, 's'));  %#ok<NASGU>
% 显式基准必须被尊重: 这里 root ~= projectRoot(), 所以即使 env 指向一个不存在的目录,
% 也既不接管、也不去建它 (旧注释里"调用方显式指定的基准必须被尊重"是契约, 不是装饰)。
rd = tepc.io.runDirs(other, 'fixedID');
tc.verifyTrue(startsWith(string(rd.root), string(other)), ...
    '显式基准被环境变量抢走了');
tc.verifyFalse(isfolder(base), ...
    '显式基准情形下仍然按 env 建了目录: 不该发生的副作用');
end

function test_unusable_errors(tc)
root = tepc.io.projectRoot();
prev = getenv('TEPC_RUNS_DIR');
cleanup = onCleanup(@() restoreEnv(prev, ''));  %#ok<NASGU>
% 父路径是一个普通文件 → mkdir 必败。这一支存在的意义: 证明"报错而不是退回仓库"可达,
% 否则错误分支永远不被执行, 与没有这条守卫等价 (#71 那一族的"错误分支不可达")。
f = fullfile(tempdir, sprintf('tepc_rdenv_blocker_%d.txt', feature('getpid')));
fid = fopen(f, 'w'); tc_true(fid > 0, '建不出夹具文件'); fwrite(fid, 'x'); fclose(fid);
cleanupF = onCleanup(@() delete(f));  %#ok<NASGU>
bad = fullfile(f, 'sub');              % 父是文件, 这条路建不出来
setenv('TEPC_RUNS_DIR', bad);
tc.verifyError(@() tepc.io.runDirs(root), 'tepc:io:RunsDirUnusable', ...
    '路径建不出时应报错点名; 静默退回仓库 runs/ 正是本条要消灭的行为');
end

%% ============================================================ helper (带输出参数)

function b = scratchBase(tag)
b = fullfile(tempdir, sprintf('tepc_rdenv_%s_%d_%d', tag, feature('getpid'), ...
    round(now*1e6)));
end

function restoreEnv(prev, base)
if isempty(prev)
    unsetenv('TEPC_RUNS_DIR');
else
    setenv('TEPC_RUNS_DIR', prev);
end
if ~isempty(base) && isfolder(base)
    rmdir(base, 's');
end
end

function tc_true(cond, msg)
if ~cond
    error("tepc:tests:RunDirsPrecond", "%s", char(string(msg)));
end
end
