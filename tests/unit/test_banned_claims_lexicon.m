function tests = test_banned_claims_lexicon
%TEST_BANNED_CLAIMS_LEXICON 禁语词表的合法性锁 (本轮只登记, 不做全文扫描)。
%   config/banned_claims.json 是"当前交付口径下禁止出现的表述"的唯一清单。它一旦无法
%   解析、退化成空表、或者落错目录, 后续的报告文案扫描就只剩两种下场: 静默放行一切,
%   或者去扫一份并不存在的清单。本文件因此只锁三件事: 编码与可解析、内容非空且良构、
%   位置正确。全文匹配不在这里 (在 tests/integration/test_report_semantics.m 的
%   productTexts, 覆盖面由 enforcement_status 声明)。
tests = functiontests(localfunctions);
end

% ==================== 编码与可解析 ====================

function test_lexicon_is_strict_utf8_without_bom(tc)
root = tepc.io.projectRoot();
f = lexiconPath(root);
raw = readBytes(f);
tc.verifyTrue(numel(raw) > 200, sprintf('词表过小 (%d 字节), 不像是装了条目的清单', numel(raw)));
isBom = numel(raw) >= 3 && all(raw(1:3) == uint8([239 187 191]));
tc.verifyFalse(isBom, ...
    '词表带 UTF-8 BOM: 按字节读入的扫描器会把第一条禁语首字符吃成 U+FEFF, 匹配不上');
txt = '';
try
    txt = native2unicode(raw, 'UTF-8');
catch e
    tc.fail(sprintf('词表不能按 UTF-8 解码 (中文说明必须留在 UTF-8 里): %s', e.message));
end
if ~isempty(txt)
    % 往返一致才算"严格 UTF-8": 解码遇到非法字节会被换成占位字符, 再编码回去字节就变了。
    tc.verifyTrue(isequal(unicode2native(txt, 'UTF-8'), raw), ...
        '词表不是严格 UTF-8: 解码再编码后字节发生变化 (存在无法解码的字节序列)');
end
end

function test_lexicon_parses_and_declares_schema(tc)
root = tepc.io.projectRoot();
L = loadLexicon(root);
tc.verifyMatches(textOf(getfOpt(L, 'schema')), '^tepc-banned-claims-v\d+$', ...
    sprintf('schema=%s 不是 tepc-banned-claims-v<N> 形式; 扫描器要靠它认版本', ...
    strOr(getfOpt(L, 'schema'))));
% enforcement_status 必须与"有没有人真的扫这份词表"一致。它原先恒等于 LEXICON_ONLY,
% 而 test_report_semantics 一直在逐份文本匹配 —— 那是不如实的自我低估。现在两个取值
% 都在词表里, 且声明为扫描态时必须真的存在扫描器与扫描集合, 否则状态就是装饰。
st = textOf(getfOpt(L, 'enforcement_status'));
tc.verifyMatches(st, '^(LEXICON_ONLY|SCANNED_IN_TEXT_PRODUCTS)$', ...
    sprintf('enforcement_status=%s 不在词表 {LEXICON_ONLY, SCANNED_IN_TEXT_PRODUCTS} 内', st));
if contains(st, "SCANNED")
    scanFile = fullfile(root, 'tests', 'integration', 'test_report_semantics.m');
    tc.verifyTrue(isfile(scanFile), ...
        '状态声明为扫描态, 但承担扫描的 test_report_semantics.m 不存在');
    txt = fileread(scanFile);           % 只搜 ASCII 标识, GBK 解码错位不影响这些子串
    tc.verifyTrue(contains(txt, 'banned_claims.json'), ...
        '状态说词表被消费, 而扫描用例已经不读这份词表了');
    tc.verifyFalse(isempty(regexp(txt, 'function\s+src\s*=\s*productTexts', 'once')), ...
        '状态为 SCANNED_IN_TEXT_PRODUCTS 却没有 productTexts 扫描集合: 状态比实现跑得远');
end
tc.verifyFalse(isempty(strtrim(textOf(getfOpt(L, 'scope_note')))), ...
    'scope_note 为空: 词表没说清"为什么这些表述当前不许出现"');
% 反装饰: 解析成功但一个条目都没有的清单, 会让未来的扫描器"扫得很干净"地放行一切。
claims = claimList(L);
tc.verifyGreaterThanOrEqual(numel(claims), 4, ...
    sprintf('词表只有 %d 条禁语; 本轮登记的表述是 4 条, 少于它就说明清单被删过', numel(claims)));
end

% ==================== 内容良构 ====================

function test_lexicon_entries_are_well_formed(tc)
L = loadLexicon(tepc.io.projectRoot());
claims = claimList(L);
tc.verifyEqual(numel(claims), numel(unique(claims)), ...
    '词表里有重复表述: 扫描命中数会双计, 排除规则也会互相覆盖');
for i = 1:numel(claims)
    c = string(claims(i));
    tc.verifyFalse(isempty(strtrim(c)), sprintf('第 %d 条禁语是空串或纯空白', i));
    tc.verifyFalse(contains(c, newline) || contains(c, "\r"), ...
        sprintf('第 %d 条禁语含换行: 逐行扫描会永远匹配不上它', i));
    tc.verifyTrue(strcmp(c, strtrim(c)), ...
        sprintf('第 %d 条禁语首尾带空白, 与扫描器的原文匹配对不上: 「%s」', i, c));
end
end

function test_lexicon_notes_parallel_to_claims(tc)
% 词表与"为什么禁止"是两份必须逐项对齐的清单: 只在一处改, 另一处就会悄悄过期。
L = loadLexicon(tepc.io.projectRoot());
claims = claimList(L);
tc.verifyTrue(isfield(L, 'claim_notes'), '词表缺 claim_notes: 每条禁语都要写明理由');
notes = L.claim_notes;
tc.verifyEqual(numel(notes), numel(claims), ...
    sprintf('claim_notes (%d 项) 与 banned_claims (%d 项) 数量不等', numel(notes), numel(claims)));
ids = strings(1, 0);
for i = 1:min(numel(notes), numel(claims))
    tc.verifyTrue(string(textOf(getfOpt(notes(i), 'claim'))) == string(claims(i)), ...
        sprintf('第 %d 项: claim_notes 与 banned_claims 顺序或内容分叉 (「%s」 vs 「%s」)', ...
        i, textOf(getfOpt(notes(i), 'claim')), string(claims(i))));
    tc.verifyFalse(isempty(strtrim(textOf(getfOpt(notes(i), 'why_not')))), ...
        sprintf('第 %d 项缺 why_not: 没有理由的禁语会在下一次改文案时被当成笔误删掉', i));
    tc.verifyFalse(isempty(strtrim(textOf(getfOpt(notes(i), 'say_instead')))), ...
        sprintf('第 %d 项缺 say_instead: 只说禁什么、不说什么能替代, 等于没有可执行的口径', i));
    ids(end+1) = string(textOf(getfOpt(notes(i), 'id'))); %#ok<AGROW,SAGROW>
end
if numel(ids) > 1
    tc.verifyEqual(numel(ids), numel(unique(ids)), ...
        'claim_notes 的 id 有重复: 报告里按 id 引用禁语会指向两条');
end
end

% ==================== 位置 ====================

function test_lexicon_lives_in_config_only(tc)
% 词表必须是机器可读的 JSON 且落在 config/。换成 docs/ 下的 .md 会带来两个后果:
% 仓库内容扫描把它当成随产品发货的文档, 而扫描器无从按 schema 解析它。
root = tepc.io.projectRoot();
f = lexiconPath(root);
tc.verifyTrue(isfile(f), sprintf('词表不在位: %s', f));
rel = relPath(root, f);
tc.verifyTrue(startsWith(rel, "config/"), sprintf('词表当前在 %s: 它必须放在 config/ 下', rel));
stray = strings(1, 0);
names = altNames();
for i = 1:numel(names)
    d = dir(fullfile(root, '**', names{i}));
    for j = 1:numel(d)
        r = relPath(root, fullfile(d(j).folder, d(j).name));
        if startsWith(r, "runs/") || strcmp(r, rel)
            continue;                       % 运行产物里的副本不在本轮口径内
        end
        stray(end+1) = string(r); %#ok<AGROW>
    end
end
tc.verifyEmpty(stray, ...
    sprintf('这些位置也出现了禁语词表的副本: %s —— 两份清单必然分叉, 只留 config/ 那一份', ...
    strjoin(stray, ', ')));
end

% ==================== helpers (不以 test 开头, 首参不是 tc) ====================

function n = altNames()
% 只找"清单副本"可能的载体 (数据/文档), 不收 .m: 读这份词表的测试文件自己就叫
% test_banned_claims_lexicon.m, 把它算成副本会让本测试永远红。
n = {'banned_claims.json', 'banned_claims.md', 'banned_claims.txt', ...
    'banned-claims.json', '*banned_claims*.md'};
end

function f = lexiconPath(root)
f = fullfile(root, 'config', 'banned_claims.json');
end

function L = loadLexicon(root)
f = lexiconPath(root);
if ~isfile(f)
    error('tepc:tests:LexiconMissing', '禁语词表不存在: %s', f);
end
txt = readTextUtf8(f);
if isempty(strtrim(txt))
    error('tepc:tests:LexiconEmpty', '禁语词表是空文件: %s', f);
end
try
    L = jsondecode(txt);
catch e
    error('tepc:tests:LexiconUnparseable', '禁语词表不是合法 JSON (%s): %s', f, e.message);
end
end

function claims = claimList(L)
if ~isfield(L, 'banned_claims')
    error('tepc:tests:LexiconShape', '词表缺 banned_claims 字段 (顶层结构变了?)');
end
v = L.banned_claims;
isStrList = iscell(v) || isstring(v) || ischar(v);
if ~isStrList
    error('tepc:tests:LexiconShape', ...
        'banned_claims 必须是字符串数组, 实得 %s (改成对象数组会让扫描器无从逐条匹配)', class(v));
end
claims = asStrings(v);
end

function raw = readBytes(f)
fid = fopen(f, 'r', 'n');
if fid < 0
    error('tepc:tests:LexiconMissing', '无法读取词表 (按字节): %s', f);
end
b = fread(fid, inf, 'uint8=>uint8');
fclose(fid);
raw = b(:)';                       % 强制行向量: 列向量与 1x3 比较会因隐式扩展变成矩阵
end

function r = relPath(root, p)
r = extractAfter(string(p), string(root) + string(filesep));
r = replace(r, "\", "/");
end

function s = asStrings(v)
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
    error('tepc:tests:LexiconShape', '期望字符串数组, 实得 %s', class(v));
end
end

function v = getfOpt(s, nm)
if isstruct(s) && isfield(s, nm), v = s.(nm); else, v = ''; end
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

function s = strOr(v)
s = textOf(v);
if isempty(s), s = '(缺失)'; end
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
