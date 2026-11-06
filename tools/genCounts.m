function c = genCounts(varargin)
%GENCOUNTS 由**静态检查**生成发布清单计数, 写入 docs/counts.json。
%   c = genCounts()                      计算并写 docs/counts.json
%   c = genCounts('WriteFile', false)    只计算, 不落盘 (test_doc_counts 用它比对清单是否过期)
%   c = genCounts('Root', r)             指定仓库根 (默认 tepc.io.projectRoot())
%
% 为什么必须有这个工具: .gitignore 在一个既无 git 也无 CI 的仓库里什么都拦不住,
% 而 README/quickstart/VV_plan 里的数字曾各自漂移 (11/14 门禁、16/22 数据集、
% 117 vs 42 测试数)。计数只能"算出来", 不能"抄出来"。
%
% 全部计数**不执行任何测试**, 只做文本解析, 因此本工具与正在跑的套件互不干扰:
%   test_functions  tests/ 下签名为 function xxx(tc) 的函数个数
%                  (= functiontests(localfunctions) 的收集口径; 实测与
%                   matlab.unittest.TestSuite.fromFile 逐文件一致, 0 参辅助函数与
%                   setup(~) 都不计入, 与套件口径相同)
%   gates          src/+tepc/+validation/runGate.m 里 addItem 添加的**去重**门禁项数
%                  (同一项在 if/else 两分支各写一次, 故必须去重而不是数调用语句)
%   h5_datasets    writeEventsH5.m 实际创建的 HDF5 数据集个数
%                  (map 表行数 + 表外独立 h5create 语句数)
%   anchor_rows_*  config/reference/*.csv 的数据行数 (去掉表头与 # 注释行)

p = inputParser;
p.addParameter('WriteFile', true, @islogical);
p.addParameter('Root', '', @(x) ischar(x) || isstring(x));
p.parse(varargin{:});
a = p.Results;

root = char(string(a.Root));
if isempty(root)
    root = tepc.io.projectRoot();
end

% ---------------- 1) 测试函数个数 ----------------
testFiles = dir(fullfile(root, 'tests', '**', '*.m'));
nTestFun = 0; nTestFunMulti = 0; nTestFiles = 0;
perFile = struct('file', {}, 'test_functions', {});
for i = 1:numel(testFiles)
    f = testFiles(i);
    if ~startsWith(f.name, 'test_'), continue; end
    nTestFiles = nTestFiles + 1;
    txt = readTextUtf8(fullfile(f.folder, f.name));
    n = tcCaseCount(txt);
    lines = strsplit(txt, newline);
    for j = 1:numel(lines)
        if ~isempty(regexp(lines{j}, '^\s*function\s+test_[A-Za-z0-9_]*\s*\(tc\s*,', 'once'))
            % 只统计 test_ 前缀的多参数函数: functiontests 既不收集多参数函数, 也不收集
            % 非 test_ 前缀的名字, 所以 "function helper(tc, a, b)" 这类带 tc 的辅助函数
            % 根本不在收集范围内, 不构成口径分叉。把它们计入会让这个本应为 0 的排除数
            % 长期红 (实测 helper expectBadPath(tc, what, f, tag) 触发一次假红)。
            nTestFunMulti = nTestFunMulti + 1;
        end
    end
    nTestFun = nTestFun + n;
    perFile(end+1) = struct('file', f.name, 'test_functions', n); %#ok<AGROW>
end

% ---------------- 1b) UI 用例面 (tests_ui/cases) ----------------
% 这两张面**不在** runAllTests 的采集范围内 (它只 fromFolder(tests)), 所以 UI 用例数绝不能
% 并进 test_functions —— 并进去会让"静态计数 == 套件收集数"那条主锁变成假等式 (左边含 UI、
% 右边不含)。这里给独立键, 文档引用的是独立键, 锁就只锁它自己那一张面。
uiDir = fullfile(root, 'tests_ui', 'cases');
nUiFun = 0; nUiFiles = 0;
perUi = struct('file', {}, 'test_functions', {});
if isfolder(uiDir)
    uAll = dir(fullfile(uiDir, 'test_*.m'));
    for i = 1:numel(uAll)
        u = uAll(i);
        nUi = tcCaseCount(readTextUtf8(fullfile(u.folder, u.name)));
        nUiFiles = nUiFiles + 1;
        nUiFun = nUiFun + nUi;
        perUi(end+1) = struct('file', u.name, 'test_functions', nUi); %#ok<AGROW>
    end
end

% ---------------- 2) 门禁项数 ----------------
gateFile = fullfile(root, 'src', '+tepc', '+validation', 'runGate.m');
gTxt = readOrDie(gateFile);
gLines = strsplit(gTxt, newline);
names = strings(0,1);
nAddCalls = 0;
for i = 1:numel(gLines)
    tok = regexp(gLines{i}, 'addItem\(\s*items\s*,\s*''([^'']+)''', 'tokens');
    if ~isempty(tok)
        nAddCalls = nAddCalls + 1;
        names(end+1) = string(tok{1}{1}); %#ok<AGROW>
    end
end
nGates = numel(unique(names));
% 注释里的 "% 1)" ... "% 14)" 编号: 只做交叉核对, 真值是去重后的 addItem 项名
nGatesNumbered = numel(regexp(gTxt, '(?m)^\s*%\s*\d+\)\s'));

% ---------------- 3) HDF5 数据集个数 ----------------
h5File = fullfile(root, 'src', '+tepc', '+io', 'writeEventsH5.m');
hTxt = readOrDie(h5File);
hLines = strsplit(hTxt, newline); %#ok<NASGU>
% 把 `map = { ... };` 整块抠出来, 数其中的 (字段名, 数据集名, 类型) 三元组。
% 逐行找起止会漏掉 "map = { 'a','b','c';" 这种首行同写、以及 "'x' };" 这种末行同写,
% 因此按字符区间取块而不是按行取块。
i0 = regexp(hTxt, '(?<![\w])map\s*=\s*\{', 'once');
nMapRows = 0;
if ~isempty(i0)
    iRel = regexp(hTxt(i0:end), '\}\s*;', 'once');
    blk = hTxt(i0 : i0 + iRel - 1);
    rowPat = "'[A-Za-z0-9_]+'\s*,\s*'[^']+'\s*,\s*'[A-Za-z0-9_]+'";
    nMapRows = numel(regexp(blk, rowPat));
end
nH5create = numel(regexp(hTxt, 'h5create\s*\('));
if nMapRows > 0
    % map 循环里的那一条 h5create 语句负责 nMapRows 个数据集; 其余语句各算一个
    nDatasets = nMapRows + max(0, nH5create - 1);
else
    nDatasets = nH5create;
end

% ---------------- 4) 锚点表行数 ----------------
refDir = fullfile(root, 'config', 'reference');
refFiles = dir(fullfile(refDir, '*.csv'));
anchorTotal = 0;
anchorNames = strings(0,1);
byFile = struct('file', {}, 'rows', {});
refNames = sort(string({refFiles.name}'));        % 确定性顺序 (dir 顺序不保证)
for i = 1:numel(refNames)
    rows = countCsvRows(fullfile(refDir, char(refNames(i))));
    base = erase(refNames(i), ".csv");
    key = "anchor_rows_" + regexprep(char(base), '[^A-Za-z0-9_]', '_');
    anchorTotal = anchorTotal + rows;
    anchorNames(end+1) = string(key); %#ok<AGROW>
    byFile(end+1) = struct('file', char(refNames(i)), 'rows', rows); %#ok<AGROW>
end

% ---------------- 5) 汇总 ----------------
rel  = version('-release');
if ~startsWith(string(rel), "R"), rel = ['R' rel]; end   % 统一成 R2025a 写法
utcS = char(datetime('now', 'TimeZone', 'UTC', 'Format', "yyyy-MM-dd'T'HH:mm:ss'Z'"));

counts = struct();
counts.test_functions   = nTestFun;
counts.test_files       = nTestFiles;
counts.test_functions_excluded_multiarg = nTestFunMulti;
counts.gates            = nGates;
counts.gates_additem_statements = nAddCalls;
counts.h5_datasets      = nDatasets;
counts.ui_test_functions = nUiFun;
counts.ui_test_files      = nUiFiles;
counts.anchor_rows_total = anchorTotal;
for i = 1:numel(anchorNames)
    counts.(char(anchorNames(i))) = byFile(i).rows;
end

c = struct();
c.schema        = 'tepc-counts-v1';
c.generated_utc = utcS;
c.matlab_release = rel;
c.command       = 'cd tests; runAllTests';
c.regen_command = ['cd <repo>/tests; matlab -batch "addpath ../src; addpath ../app; ' ...
    'addpath ../tools; genCounts"'];
c.method        = 'static inspection only (no test executed)';
c.counts        = counts;
c.details       = struct( ...
    'test_files', {perFile}, 'ui_test_files_detail', {perUi}, 'anchor_files', {byFile}, ...
    'gate_names', {cellstr(unique(names))}, ...
    'numbered_gate_comments', {nGatesNumbered}, ...
    'h5create_statements', {nH5create}, 'h5_map_rows', {nMapRows}, ...
    'root', {root});

if a.WriteFile
    out = fullfile(root, 'docs', 'counts.json');
    tepc.io.writeJson(out, c);
    fprintf('genCounts: 写入 %s (test_functions=%d gates=%d h5_datasets=%d anchors=%d)\n', ...
        out, counts.test_functions, counts.gates, counts.h5_datasets, anchorTotal);
end
end

% ---------------- helpers ----------------

function txt = readOrDie(f)
if ~isfile(f)
    error("tepc:counts:MissingSource", "genCounts 需要静态解析 %s, 但文件不存在", f);
end
txt = readTextUtf8(f);
end

function txt = readTextUtf8(f)
% 显式 UTF-8 读: 本机默认字符集 GBK 会把 UTF-8 中文按双字节解码并吞掉
% 紧随其后的换行字节 -> 行数变少、行号错位、计数静默失真。
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0
    error("tepc:counts:Unreadable", "无法读取 %s", f);
end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
txt = strrep(txt, sprintf('\r\n'), sprintf('\n'));
txt = strrep(txt, sprintf('\r'), sprintf('\n'));
end

function n = countCsvRows(f)
txt = readTextUtf8(f);
lines = strsplit(txt, newline);
n = 0;
for i = 1:numel(lines)
    L = strtrim(lines{i});
    if isempty(L) || startsWith(L, '#'), continue; end
    n = n + 1;
end
n = max(0, n - 1);                    % 表头
end

function n = tcCaseCount(txt)
% 只认 "function name(tc)" —— **函数名必须直接跟 (tc)**。原来写的
% 'function\s+[^(]*\(tc\s*\)' 里 [^(]* 把输出赋值也吞了, 于是
% "function root = repoRoot(tc)" 这类带输出的辅助函数被算成测试:
% functiontests(localfunctions) 不收集带输出参数的局部函数, 静态口径
% 因此比套件收集数多 2 (实测 236 vs 234)。顶层 0 参函数与辅助函数不算测试。
% tests/ 与 tests_ui/cases 两张面共用这一条, 口径分叉会同时骗过两边的锁。
lines = strsplit(txt, newline);
n = 0;
for j = 1:numel(lines)
    if ~isempty(regexp(lines{j}, '^\s*function\s+[A-Za-z_]\w*\s*\(tc\s*\)', 'once'))
        n = n + 1;
    end
end
end
