function ok = runAllTests(varargin)
%RUNALLTESTS 完整测试套件 + 构建级失败信号。
%   matlab -batch "cd(<root>/tests); runAllTests"        % 全量（含 GUI 长跑）
%   matlab -batch "cd(<root>/tests); runAllTests('Quick',true)"   % 跳过长跑 GUI 全流程
%   runAllTests('WriteLog',true)        % 另由 MATLAB 自己写一份 UTF-8 无 BOM 的
%                                       % 用例级日志到 docs/test_evidence/
%   任一用例失败/未决即 error，使 CI 退出码非 0。
p = inputParser;
p.addParameter('Quick', false, @islogical);
p.addParameter('Silent', false, @islogical);
p.addParameter('WriteLog', false, @islogical);
p.parse(varargin{:});
a = p.Results;

% 测试套件默认把 run 产物写到系统临时目录, 不污染仓库 runs/ (旧版每跑一次套件
% 就在仓库里堆若干个 run 目录)。已在外部设置 TEPC_RUNS_DIR 时尊重调用方。
if isempty(getenv('TEPC_RUNS_DIR'))
    ciBase = fullfile(tempdir, 'tepc_ci_runs');
    if ~isfolder(ciBase), mkdir(ciBase); end
    setenv('TEPC_RUNS_DIR', ciBase);
end

root = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root, 'src'));
addpath(fullfile(root, 'app'));
addpath(fullfile(root, 'workflows'));
addpath(fullfile(root, 'tests'));
import matlab.unittest.TestSuite
suites = [];
try
    s0 = TestSuite.fromFolder(fullfile(root, 'tests'), 'IncludingSubfolders', true);
catch e1
    fprintf('fromFolder(IncludingSubfolders) 失败: %s\n', e1.message);
    s0 = TestSuite.fromFolder(fullfile(root, 'tests', 'unit'));
end
try,    suites = s0.toArray();
catch,  suites = s0; end
if a.Quick
    nm = cellstr(string({suites.Name}'));
    suites = suites(~contains(nm, "test_gui_run_completes"));
end
if isempty(suites)
    error('tepc:tests:Empty', '未发现任何测试用例');
end

if a.Silent
    runner = matlab.unittest.TestRunner.withNoPlugins;
else
    runner = matlab.unittest.TestRunner.withTextOutput;
end
res = runner.run(suites);

np = nnz([res.Passed]); nf = nnz([res.Failed]); nin = nnz([res.Incomplete]);
nt = numel(res);
fprintf('\n==== 测试汇总: %d 通过 / %d 失败 / %d 未决 / %d 总计 ====\n', np, nf, nin, nt);
for i = 1:numel(res)
    if res(i).Failed,  fprintf('FAILED:   %s\n', res(i).Name); end
    if res(i).Incomplete, fprintf('INCOMPLETE: %s\n', res(i).Name); end
end
if a.WriteLog
    % 写在 error 之前: 失败的那一次跑恰恰最需要留下可读的证据。
    writeEvidenceLog(root, res, np, nf, nin, nt, a);
end
ok = (nf == 0 && nin == 0);
if ~ok
    % 构建级失败信号：抛异常使 matlab -batch 退出码非 0
    error('tepc:tests:Failed', '测试套件未通过: %d 失败 / %d 未决 / %d 总计', nf, nin, nt);
end
end

%% ---------------- UTF-8 证据日志 ----------------
% 这些辅助函数一律不以 test 开头、首参也不是 tc: 用例数由 tools/genCounts.m 按签名
% (tc) 静态统计, 写成 function x = y(tc, ...) 会让清单计数与套件真实收集数分叉。

function writeEvidenceLog(root, res, np, nf, nin, nt, opts)
%WRITEEVIDENCELOG 用例名/通过失败/汇总 -> docs/test_evidence/ 下的 UTF-8 无 BOM 日志。
%   为什么不经 shell 重定向: 重定向落盘的是本机控制台字符集 (GBK) 的字节, 第三方按
%   UTF-8 打开就是乱码。编码这一步必须在 MATLAB 内完成 —— fopen(...,'w','n','UTF-8')
%   写出的是无 BOM 的 UTF-8 (与 tepc.io.writeJson 同一条路径)。
if ~islogical(opts.WriteLog) || ~opts.WriteLog
    return;
end
dirOut = fullfile(root, 'docs', 'test_evidence');
if ~isfolder(dirOut)
    mkdir(dirOut);
end
stamp = char(datetime('now', 'TimeZone', 'UTC', 'Format', "yyyyMMdd'T'HHmmss'Z'"));
logPath = fullfile(dirOut, ['runAllTests_' stamp '.log']);
fid = fopen(logPath, 'w', 'n', 'UTF-8');
if fid < 0
    error('tepc:tests:LogWriteFailed', '无法写入证据日志: %s', logPath);
end
lines = [envHeaderLines(np + nf + nin, opts), caseLines(res), ...
    {sprintf('==== 测试汇总: %d 通过 / %d 失败 / %d 未决 / %d 总计 ====', np, nf, nin, nt)}];
txt = strjoin(lines, sprintf('\n'));
fwrite(fid, txt, 'char');
fclose(fid);
% 回读核对: 写入端一旦走了别的字符集或带上 BOM, 这份证据对第三方就是不可读的,
% 所以宁可当场报出来 (只 warning —— 不让日志本身把一次全绿的跑变成红)。
if ~isequal(readBackUtf8(logPath), txt)
    warning('tepc:tests:LogEncoding', '证据日志回读与写入内容不一致 (字符集?): %s', logPath);
end
fprintf('UTF-8 证据日志: %s (%d 行)\n', logPath, numel(lines));
end

function L = envHeaderLines(nCases, opts)
% 环境头: 没有 MATLAB 版本/字符集/运行目录, 光有用例清单的日志无法复算。
osType = '';
try
    osType = char(string(feature('OSType')));
catch
    osType = '(feature(''OSType'') 不可用)';
end
runsDir = getenv('TEPC_RUNS_DIR');
if isempty(runsDir)
    runsDir = '(未设置: 各测试自行决定落点)';
end
L = { ...
    '# TEPC runAllTests 用例级证据日志 (由 MATLAB 直接以 UTF-8 无 BOM 写出)', ...
    sprintf('# generated_utc  : %s', char(datetime('now', 'TimeZone', 'UTC', ...
        'Format', "yyyy-MM-dd'T'HH:mm:ss'Z'"))), ...
    sprintf('# matlab_version : %s', version), ...
    sprintf('# matlabroot     : %s', matlabroot), ...
    sprintf('# computer       : %s', computer), ...
    sprintf('# os_type        : %s', osType), ...
    sprintf('# TEPC_RUNS_DIR  : %s', runsDir), ...
    sprintf('# quick_filter   : %d (1 = 已跳过 test_gui_run_completes 长跑)', logical(opts.Quick)), ...
    sprintf('# silent_runner  : %d (1 = 无插件 runner, 控制台不含用例明细)', logical(opts.Silent)), ...
    sprintf('# collected_cases: %d', nCases), ...
    '# 明细行: 状态 + 耗时(s) + 用例名; 失败/未决的用例其后紧跟 "    | " 开头的诊断行'};
end

function L = caseLines(res)
L = cell(1, numel(res));
for i = 1:numel(res)
    r = res(i);
    if r.Passed
        st = 'PASS      ';
    elseif r.Failed
        st = 'FAILED    ';
    elseif r.Incomplete
        st = 'INCOMPLETE';
    else
        st = 'UNSUPPORTED';
    end
    L{i} = sprintf('%s %8.3fs  %s', st, secondsOf(r), char(oneLine(string(r.Name))));
    if r.Failed || r.Incomplete
        d = detailLines(r);
        for k = 1:numel(d)
            L{end+1} = sprintf('    | %s', d{k}); %#ok<AGROW>
        end
    end
end
end

function s = secondsOf(r)
s = NaN;
try
    d = r.Duration;
    if isa(d, 'duration')
        s = seconds(d);
    else
        s = double(d);
    end
catch
    s = NaN;
end
end

function d = detailLines(r)
% 不同版本 TestResult 的明细字段大小写与形状不一致, 整段容错: 拿不到明细也必须留下
% 用例行, 不能让"写证据"这一步反过来把套件弄崩。
% Failures/Errors 在 R2025a 上不是 TestResult 的属性 (访问即抛 noSuchMethodOrField)。
% VerboseDiagrams 曾被认为是跨版本稳定的兜底 —— **本机实测不成立**: 三条路全部拿不到
% (2026-09-22 全量跑的 UTF-8 日志里 6 条失败/未决全是占位行)。所以诊断明细的唯一来源
% 是 withTextOutput 打到控制台的原文, 证据日志只负责"哪些用例、什么状态、耗时多少"。
% 三条路都空时必须显式写占位并 warn: 一份看起来完整、实际零诊断的日志比没有日志更坏。
d = {};
try
    f = r.Failures;
    for k = 1:numel(f)
        d{end+1} = msgOf(f(k), '断言失败:'); %#ok<AGROW>
    end
catch
end
try
    e = r.Errors;
    for k = 1:numel(e)
        d{end+1} = msgOf(e(k), '错误:'); %#ok<AGROW>
    end
catch
end
if isempty(d)
    try
        vd = r.VerboseDiagrams;
        for k = 1:numel(vd)
            d{end+1} = [char(string(vd(k).Severity)) ': ', ...
                char(oneLine(string(vd(k).Description)))]; %#ok<AGROW>
        end
    catch
    end
end
if isempty(d)
    warning('tepc:tests:NoDiagnosticDetail', ...
        ['用例 %s 的失败明细在本机取不到 (Failures/Errors/VerboseDiagrams 三条路都不可用): ' ...
         '诊断原文只在控制台/日志里, UTF-8 证据日志不含明细。'], r.Name);
    d = {'<明细不可读: TestResult 未暴露 Failures/Errors/VerboseDiagrams>'};
end
end

function s = msgOf(obj, tag)
msg = '';
try
    msg = char(string(obj.diagnostic));
catch
end
if isempty(strtrim(msg))
    try
        msg = char(string(obj.Diagnostic));
    catch
    end
end
if isempty(strtrim(msg))
    try
        msg = char(string(obj.message));
    catch
    end
end
if isempty(strtrim(msg))
    msg = '<明细不可读>';
end
s = [tag, ' ', char(oneLine(string(msg)))];
end

function s = oneLine(txt)
% 一条用例一行: 断言消息可能跨行, 不折叠就会打乱日志的机器可读结构。
s = replace(string(txt), newline, " | ");
s = strrep(s, sprintf('\r'), "");
end

function txt = readBackUtf8(f)
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0
    txt = '';
    return;
end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
end
