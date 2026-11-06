function ok = runUiTests(varargin)
%RUNUITESTS 界面交互用例入口 (放在 tests/ 之外, 不进主套件的收集面)。
%   计数口径: docs/counts.json 用**独立键** ui_test_functions / ui_test_files 记这张面
%   (由 tools/genCounts.m 数 tests_ui/cases/test_*.m), 绝不并进 test_functions —— 并进去会让
%   "静态计数 == 套件实收数"那条主锁变成假等式。文档引用的是这个独立键, 锁也只锁这张面。
%   为什么单列: 这些用例要开真的 uifigure、走真的控件回调, 与纯计算套件混在一起
%   会让 headless 长跑互相污染; 而把它们放进 tests/ 又会被 tools/genCounts.m 的
%   静态计数与 TestSuite.fromFolder 的实收数双重口径牵制。
%
%   本机实测口径 (决定了下面的写法, 任一条写错就是"看着在跑其实一个没收"):
%   * TestSuite.fromFolder(folder,'ParameterName','tc') 对界面用例**静默返回 0 个**,
%     不报错; 去掉 ParameterName 才收到 2 个。旧版正是带着 ParameterName 在跑,
%     于是永远走 isempty -> tepc:tests_ui:Empty, 即使 cases/ 里有真用例。
%   * functiontests(folder,...) 只接受函数句柄/测试数组, 传目录抛 MATLAB:invalidType;
%     旧版的 fromFolder 回退分支因此也是死路。回退改走 TestSuite.fromFile 逐文件收。
%   * functiontests(...,'TestType','uitest') 的用例能被 fromFolder 收到, 但在
%     matlab -batch 里夹具起不来 (实测 pass=0 / fail=2 / inc=2), 所以本目录下的用例
%     用普通 TestCase + 无头 uifigure + 显式调回调来驱动真实控件。
%   * 用例目录缺失时旧版靠 addParameter(..., @isfolder) 报一个无标识的校验错误;
%     现在换成具名错误, 并且收不到用例 / 收了没跑完都是具名失败, 不许报成功。
%   用法:
%     matlab -batch "addpath('<repo>/tests_ui'); runUiTests"
p = inputParser;
p.addParameter('Folder', '', @ischar);
p.addParameter('Silent', false, @islogical);
p.parse(varargin{:});
a = p.Results;

here = fileparts(mfilename('fullpath'));
root = fileparts(here);
if isempty(a.Folder)
    a.Folder = fullfile(here, 'cases');
end
if ~isfolder(a.Folder)
    error('tepc:tests_ui:NoFolder', ...
        'UI 用例目录不存在: %s (缺目录不是"没有 UI 用例可跑", 必须显式失败)', a.Folder);
end
addpath(fullfile(root, 'src'));
addpath(fullfile(root, 'app'));
addpath(fullfile(root, 'app', 'components'));
addpath(fullfile(root, 'workflows'));
addpath(a.Folder);

% 先点文件: 目录在但一个用例文件都没有, 与"文件在却没被收进来"是两种病, 分开报。
files = dir(fullfile(a.Folder, '**', '*.m'));
files = files(~[files.isdir]);
caseFiles = files(startsWith({files.name}', 'test'));
if isempty(caseFiles)
    error('tepc:tests_ui:NoCaseFiles', ...
        '%s 下没有任何 test*.m 用例文件 (缺用例不是通过)', a.Folder);
end

if a.Silent
    diaryOffIfAny();
end
import matlab.unittest.TestSuite
suite = [];
try
    suite = TestSuite.fromFolder(a.Folder, 'IncludingSubfolders', true);
catch ME1
    warning('tepc:tests_ui:FromFolderFallback', ...
        'fromFolder 失败(%s), 改用逐文件 fromFile', ME1.identifier);
end
if isempty(suite)
    % 逐文件收: 一个文件收不到也要点名, 不许静默跳过
    parts = matlab.unittest.TestSuite.empty;
    for i = 1:numel(caseFiles)
        fp = fullfile(a.Folder, caseFiles(i).name);
        try
            one = TestSuite.fromFile(fp);
            if isempty(one)
                error('tepc:tests_ui:EmptyFile', '文件里没收到用例: %s', fp);
            end
            parts = [parts, one]; %#ok<AGROW>
        catch e2
            if strcmp(e2.identifier, 'tepc:tests_ui:EmptyFile'), rethrow(e2); end
            error('tepc:tests_ui:CollectFailed', ...
                '收不到 %s 的用例 [%s] %s', fp, e2.identifier, e2.message);
        end
    end
    suite = parts;
end
nCollected = numel(suite);
if nCollected == 0
    error('tepc:tests_ui:Empty', ...
        '在 %s 下没找到任何 UI 用例 (%d 个用例文件全部空收)', a.Folder, numel(caseFiles));
end
fprintf('==== UI 用例收集: %d 个文件 / %d 个用例 ====\n', numel(caseFiles), nCollected);

if a.Silent
    t = matlab.unittest.TestRunner.withNoPlugins().run(suite);
else
    t = run(suite);
end
if numel(t) ~= nCollected
    error('tepc:tests_ui:Lost', ...
        '收了 %d 个用例只跑了 %d 个 —— 有用例被静默丢弃', nCollected, numel(t));
end

nPass = nnz([t.Passed]);
nFail = nnz([t.Failed]);
nInc = nnz([t.Incomplete]);
fprintf('==== UI 测试汇总: %d 通过 / %d 失败 / %d 未决 / %d 总计 ====\n', ...
    nPass, nFail, nInc, numel(t));
for i = 1:numel(t)
    if ~t(i).Passed
        fprintf('%s: %s\n', upper(class(t(i))), t(i).Name);
    end
end
unlockLeftovers();
if nPass ~= numel(t)
    error('tepc:tests_ui:Failed', ...
        'UI 测试未全绿: %d 通过 / %d 总计', nPass, numel(t));
end
ok = true;
end

function unlockLeftovers()
%uitest 会 lock uifigure; 不显式解锁会留下窗口, 污染后续会话与退出码。
try
    matlab.uitest.unlock('all');
catch ME
    fprintf('unlock 未成功(%s), 需要人工确认是否有遗留窗口\n', ME.identifier);
end
end

function diaryOffIfAny()
try
    if isdiary
        diary off;
    end
catch
end
end
