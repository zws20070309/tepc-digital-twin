function tests = test_golden_baseline_fields
%TEST_GOLDEN_BASELINE_FIELDS 金基线必须真的被读: 只核字段结构, 不比数值。
%   tests/golden/baseline_pre_r17.json 记的是某个改动前时点的字段与数值快照。可是
%   快照一旦没有测试读它, "冻结基线"就是装饰: 门禁字段被改名、summary 字段被删掉,
%   它一句都不会说。本文件因此逐字段核"基线声明存在的字段今天是否仍然产出"。
%
%   为什么只比结构不比数值: 数值会随物理口径的合法变更而变, 拿数值当断言只会把
%   合法的改进变成红灯, 或者逼人改快照来灭灯 (那才是真正丢基线)。逐位数值核对属于
%   "语义重构不许改数值"那一类卡, 由相应的端到端测试按各自的容差各自承担。
%
%   字段名全部从基线 JSON 与当前源码里读出来, 本文件不硬编码任何门禁字段名 ——
%   门禁字段改名时, 只要 JSON 的 gates_fields 清单与 runGate.m 同步, 本测试就照绿;
%   两者只要有一边没跟上, 它当场指名差在哪个名字上。
tests = functiontests(localfunctions);
end

% ==================== 快照本身可读、带代际标记 ====================

function test_baseline_snapshot_is_readable_and_versioned(tc)
root = tepc.io.projectRoot();
B = loadBaseline(root);
% 代际标记: 没有它就无法区分"这份快照属于哪一代 schema", 历史产物只能靠猜。
note = strtrim(textOf(getfOpt(B, 'run_schema_note')));
tc.verifyFalse(isempty(note), ...
    '基线缺 run_schema_note 代际标记: 消费方无法判断它属于哪一代 schema');
need = {'matlab_release', 'created_utc', 'config_file_sha256', 'radii', 'field', ...
    'resolve', 'shaper', 'noise', 'deadtime', 'calibration', 'summary', 'spectrum', ...
    'gates', 'gates_fields', 'released', 'run_root', 'run_schema_note'};
have = asStrings(fieldnames(B));
tc.verifyGreaterThanOrEqual(numel(have), numel(need), ...
    sprintf('基线顶层字段数 (%d) 少于已知结构 (%d): 快照被截断或换版了?', numel(have), numel(need)));
miss = setdiff(string(need), have);
tc.verifyEmpty(miss, ...
    sprintf('基线缺这些顶层字段: %s —— 下面的字段核对会因此空转', strjoin(miss, ', ')));
if ~isempty(miss)
    return;
end
noteToConsole(sprintf('基线顶层 %d 字段; gates_fields %d 项; summary %d 项 (代际: %s)', ...
    numel(have), numel(asStrings(B.gates_fields)), numel(fieldnames(B.summary)), note));
end

% ==================== 门禁字段: 与当前 runGate 产出集合相等 ====================

function test_gates_fields_equal_current_runGate_output(tc)
root = tepc.io.projectRoot();
B = loadBaseline(root);
want = sort(asStrings(getfieldrequired(B, 'gates_fields')));
got = sort(assignedFields(fullfile(root, 'src', '+tepc', '+validation', 'runGate.m'), 'G'));
if ~parseStillWorks(tc, want, got, 'runGate.m 的门禁字段')
    return;
end
lost = setdiff(want, got);
added = setdiff(got, want);
tc.verifyEmpty(lost, ...
    sprintf(['基线声明的门禁字段在当前 runGate 产出里消失了: %s\n' ...
        '门禁结论字段被改名或删除时, 每个消费方 (GUI 横幅/STATUS/报告) 都要连锁跟上。'], ...
    strjoin(lost, ', ')));
tc.verifyEmpty(added, ...
    sprintf(['当前 runGate 产出了基线未记录的门禁字段: %s\n' ...
        '把新字段补进 tests/golden/baseline_pre_r17.json 的 gates_fields 清单; ' ...
        '若这个字段本不该存在, 删掉它。'], strjoin(added, ', ')));
end

% ==================== summary / spectrum / 门禁项名: 基线声明的仍在产出 ====================

function test_summary_fields_still_produced(tc)
root = tepc.io.projectRoot();
B = loadBaseline(root);
want = sort(asStrings(fieldnames(getfieldrequired(B, 'summary'))));
got = sort(assignedFields(fullfile(root, 'src', '+tepc', '+run', 'execute.m'), 'summary'));
if ~parseStillWorks(tc, want, got, 'execute.m 的 summary 字段')
    return;
end
tc.verifyGreaterThan(numel(want), 10, ...
    sprintf('基线 summary 只有 %d 个字段, 与已知的发布摘要结构不符: 快照被换过?', numel(want)));
lost = setdiff(want, got);
tc.verifyEmpty(lost, ...
    sprintf(['基线记录的这些 summary 字段当前不再产出: %s\n' ...
        '字段被删除或改名会静默改变 summary.json 的契约 (报告/GUI/门禁都按名字取值)。'], ...
    strjoin(lost, ', ')));
% 反方向不要求相等: 基线是时点快照, 之后新增字段是正常演进, 只报数量差。
noteToConsole(sprintf('summary 字段: 基线 %d 项, 当前产出 %d 项 (新增不算回归)', ...
    numel(want), numel(got)));
end

function test_spectrum_fields_still_produced(tc)
root = tepc.io.projectRoot();
B = loadBaseline(root);
S = getfieldrequired(B, 'spectrum');
fnames = asStrings(fieldnames(S));
% first_bins 不是谱结构里的字段, 而是快照当时从 f/d/counts_raw 各截前几个组成的抽样
% 视图, 因此它的**子键**才是要核对的真字段名。
want = strings(1, 0);
for i = 1:numel(fnames)
    if string(fnames(i)) == "first_bins"
        want = [want, asStrings(fieldnames(getfieldrequired(S, 'first_bins')))];
    else
        want = [want, string(fnames(i))];
    end
end
want = sort(unique(want));
got = sort(assignedFields(fullfile(root, 'src', '+tepc', '+analysis', 'buildSpectrum.m'), 'S'));
if ~parseStillWorks(tc, want, got, 'buildSpectrum.m 的谱字段')
    return;
end
lost = setdiff(want, got);
tc.verifyEmpty(lost, sprintf('基线记录的这些谱字段当前不再产出: %s', strjoin(lost, ', ')));
end

function test_gate_item_names_still_registered(tc)
% 门禁项**名字**是消费方索引它们的唯一凭据 (按名字查, 不靠顺序), 所以改名等于删除。
root = tepc.io.projectRoot();
B = loadBaseline(root);
G = getfieldrequired(B, 'gates');
names = sort(asStrings(getfieldrequired(G, 'names')));
sts = asStrings(getfieldrequired(G, 'statuses'));
nRec = double(getfieldrequired(G, 'n'));
% 快照自身的内部一致 (与今天的实现无关): n / names / statuses 必须同数, 否则这份
% 基线连"当时记录了什么"都说不清。
tc.verifyEqual(numel(names), nRec, sprintf('基线自相矛盾: gates.n=%d 但 names 有 %d 项', ...
    nRec, numel(names)));
tc.verifyEqual(numel(sts), nRec, sprintf('基线自相矛盾: gates.n=%d 但 statuses 有 %d 项', ...
    nRec, numel(sts)));
got = sort(gateItemNames(fullfile(root, 'src', '+tepc', '+validation', 'runGate.m')));
if ~parseStillWorks(tc, names, got, 'runGate.m 的门禁项名')
    return;
end
lost = setdiff(names, got);
tc.verifyEmpty(lost, sprintf('基线里的这些门禁项在当前 runGate 里已不存在: %s', ...
    strjoin(lost, ', ')));
noteToConsole(sprintf('门禁项: 基线 %d 项全部仍在当前 %d 项之中', numel(names), numel(got)));
end

% ==================== helpers (不以 test 开头, 首参不是 tc) ====================

function ok = parseStillWorks(tcase, want, got, what)
% 解析口径失效与"字段真的没了"是两件事, 但都必须红: 空集会让后面的集合比较变成
% 空对空, 看着绿其实什么也没核。返回 false 让调用方就此打住。
% 首参**故意不叫 tc**: 叫 tc 的多参数函数会被 genCounts 的签名口径看见, 而
% functiontests 不收集它 -> 清单计数与套件真实收集数分叉。
ok = numel(want) > 0 && numel(got) > 0;
tcase.verifyGreaterThan(numel(want), 0, sprintf('基线里的 %s 清单是空集: 无从核对', what));
tcase.verifyGreaterThan(numel(got), 0, ...
    sprintf(['没从当前源码解析出任何 %s: 静态解析口径已失效 (赋值写法变了?), ' ...
        '本测试因此证明不了基线不是孤儿快照'], what));
end

function B = loadBaseline(root)
f = fullfile(root, 'tests', 'golden', 'baseline_pre_r17.json');
if ~isfile(f)
    error('tepc:tests:BaselineMissing', '金基线快照不存在: %s', f);
end
txt = readTextUtf8(f);
if isempty(strtrim(txt))
    error('tepc:tests:BaselineEmpty', '金基线快照是空文件: %s', f);
end
try
    B = jsondecode(txt);
catch e
    error('tepc:tests:BaselineUnparseable', '金基线快照不是合法 JSON (%s): %s', f, e.message);
end
end

function v = getfieldrequired(s, nm)
if ~isfield(s, nm)
    error('tepc:tests:BaselineShape', '基线里没有字段 %s (顶层结构变了?)', nm);
end
v = s.(nm);
end

function v = getfOpt(s, nm)
% 允许缺失的取值 (缺失返回空), 判空由调用方负责。
if isfield(s, nm), v = s.(nm); else, v = ''; end
end

function names = assignedFields(file, varName)
% 静态取出形如 "varName.<字段> =" 的赋值目标 (整行注释跳过), 返回去重的字符串数组。
%   为什么静态解析而不是跑一次 execute 再 fieldnames: 本测试锁的是**字段名集合**,
% 与数值无关; 跑一次端到端会给 unit 测试背上与这项锁定无关的成本, 而它一旦因为
% 别的原因红掉, 就报不出"是哪个字段名分了叉"。静态口径与 tools/genCounts.m 数门禁
% 项、数数据集的方式同源, 解析写法变了会被同一批测试抓到。
%   已知边界: 行尾注释里再写 X.foo = ... 会被误收 —— 那属于该改的写法。
if ~isfile(file)
    error('tepc:tests:BaselineSourceMissing', '要静态解析的源文件不存在: %s', file);
end
lines = strsplit(readTextUtf8(file), sprintf('\n'), 'CollapseDelimiters', false);
pat = ['(?<![\w.])' varName '\.([A-Za-z0-9_]+)\s*=(?!=)'];
found = strings(1, 0);
for i = 1:numel(lines)
    if ~isempty(regexp(lines{i}, '^\s*%', 'once'))
        continue;
    end
    tok = regexp(lines{i}, pat, 'tokens');
    for k = 1:numel(tok)
        found(end+1) = string(tok{k}{1}); %#ok<AGROW>
    end
end
names = unique(found);
end

function names = gateItemNames(file)
% runGate 里 addItem(items, '项名', ...) 的去重项名 (与 genCounts 的门禁口径一致)。
tok = regexp(readTextUtf8(file), 'addItem\(\s*items\s*,\s*''([^'']+)''', 'tokens');
found = strings(1, 0);
for k = 1:numel(tok)
    found(end+1) = string(tok{k}{1}); %#ok<AGROW>
end
names = unique(found);
end

function s = asStrings(v)
% JSON 字符串数组经 jsondecode 可能是 cell of char、string 数组, 单元素时是 char。
if iscell(v)
    s = strings(1, numel(v));
    for i = 1:numel(v)
        s(i) = string(v{i});
    end
elseif isstring(v)
    s = reshape(v, 1, []);
elseif ischar(v)
    s = string(v);
else
    error('tepc:tests:BaselineShape', '期望字符串数组, 实得 %s', class(v));
end
end

function t = textOf(v)
if isempty(v)
    t = '';
elseif iscell(v)
    t = textOf(v{1});
elseif isstring(v)
    t = char(v(1));
elseif ischar(v)
    t = v;
else
    t = char(string(v));
end
end

function txt = readTextUtf8(f)
% 显式 UTF-8 读: 本机默认字符集 GBK 会把 UTF-8 中文按双字节解码并吞掉紧随其后的
% 换行字节, 行号与内容都会错位。
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0
    error('tepc:tests:Unreadable', '无法读取 %s', f);
end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
txt = strrep(txt, sprintf('\r\n'), sprintf('\n'));
end

function noteToConsole(msg)
% 信息行: TestCase 没有"记录摘要"的方法, 直接打到输出。
% 首参不叫 tc 且带输入参数, 不会被 genCounts 的 (tc) 签名口径计入测试数。
fprintf('%s\n', char(string(msg)));
end
