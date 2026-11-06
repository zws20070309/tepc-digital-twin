function tests = test_reference_slots_invariants
%TEST_REFERENCE_SLOTS_INVARIANTS 数据槽位缺位不变量 (config/reference_slots.json)。
%   方向一律是"缺位被当数据消费 / 占位值丢了标签 / 缺位没被说出来 -> 红", 而不是
%   "清单读得动"那种恒绿断言。三条槽位今天全 ABSENT, 所以每条判据的左右两边都先在真实
%   文件树上算过一遍才写下来 (dry-run 结果记在 临时/设计稿/20260925_数据槽位_计划v7_实施基准.md)。
%
%   八个用例:
%     structure         结构自洽, 且登记的消费点行号真指向一条含该键的行
%     idsNotInCode      槽位 id 不得出现在任何 .m 里 (除本测试)
%     closedWorld       config/reference/ 的闭世界: 盘上每个文件都要被声明
%     attribution       锚点文件归属互斥穷尽 (XOR, 不是 OR)
%     presentBinding    PRESENT 侧三向绑 —— 今天零 PRESENT, 故用 tempdir 合成夹具行使正反两向
%     materialAbsent    缺位期间材料表不得出现新的静默 null 组分
%     labelsDisclosure  占位标签按实际值比对, 缺位必须在能力登记表与首页里被说出来
%     cfgPurity         清单读取器不得污染配置身份
%
%   三个写这个文件时踩到/绕开的语言事实:
%     * 函数文件里 functiontests 只收集**单参数 (tc)** 的 test_ 子函数; 把上下文当参数传进去
%       会让整个文件"不是有效的测试文件" (表现为收集到零个用例, 而不是报你想看的那个错)。
%     * 不用 tc.verifySetEquality —— FunctionTestCase 上没有这个方法, 全部用显式集合比较。
%     * 文本一律按 UTF-8 读: fileread 走本机码页 (中文 Windows = GBK), 门禁名/原因都是中文,
%       码页错了集合比较会整体失配, 表现成"全都缺"而不是"个别不符"。
tests = functiontests(localfunctions);
end

%% ============================================================ 用例

function test_structure(tc)
[~, S] = ctx();
gset = registerGrades();
tc.verifyFalse(isempty(S.ids), '清单里没有槽位');
tc.verifyEqual(numel(unique(S.ids)), numel(S.ids), '槽位 id 有重复');
for k = 1:numel(S.slots)
    e = S.slots(k);
    tc.verifyTrue(any(strcmp(e.status, {'absent', 'present'})), sprintf('槽位 %s 的 status=%s 不在 {PRESENT,ABSENT} 内', e.id, e.status));
    tc.verifyTrue(ismember(e.grade, gset), sprintf('槽位 %s 的 grade=%s 不在登记册 evidence_grade 的取值集合 {%s} 内 (词表派生自数据侧, 不由本测试自定)', e.id, e.grade, strjoin(gset, ',')));
    tc.verifyFalse(isempty(e.owner_capability), sprintf('槽位 %s 没登记 owner_capability', e.id));
    if strcmp(e.status, 'absent')
        % ABSENT 却挂着本体 = 两份真相: 状态说缺位, 清单又指着一个文件。
        % 用 isBlank 而不是 isempty: 读取器把缺失字段填成 "" (1×1 string), 而
        % isempty(string("")) 是 false —— 直接 isempty 会把"没有本体"判成"有本体"。
        tc.verifyTrue(isBlank(e.path), sprintf('ABSENT 槽位 %s 不得带 path', e.id));
        tc.verifyTrue(isBlank(e.consumer), sprintf('ABSENT 槽位 %s 不得带 consumer', e.id));
    end
    for q = 1:numel(e.stand_in)
        si = e.stand_in(q);
        tc.verifyFalse(isempty(si.config_key), sprintf('槽位 %s 第 %d 条 stand_in 缺 config_key', e.id, q));
        tc.verifyFalse(isempty(si.label_path), sprintf('槽位 %s 第 %d 条 stand_in 缺 label_path', e.id, q));
        tail = keyTail(si.config_key);
        for c = 1:numel(si.consumers)
            spec = char(si.consumers{c});
            [lnStr, file] = splitFileLine(spec);
            tc.verifyFalse(isempty(lnStr), sprintf('消费点应写成 file:line, 实得 %s', spec));
            if isempty(lnStr), continue; end
            ln = str2double(lnStr);
            tc.verifyFalse(isnan(ln), sprintf('槽位 %s 的消费点 %s 行号不是数字', e.id, spec));
            if isnan(ln), continue; end
            absFile = fullfile(tepcRoot(), strrep(file, '/', filesep));
            tc.verifyTrue(isfile(absFile), sprintf('槽位 %s 登记的消费文件不存在: %s', e.id, file));
            if ~isfile(absFile), continue; end
            txt = readLines(absFile);
            inRange = ln >= 1 && ln <= numel(txt);
            tc.verifyTrue(inRange, sprintf('槽位 %s 的消费点 %s 行号越界 (文件共 %d 行)', e.id, spec, numel(txt)));
            if ~inRange, continue; end
            % 只要求"该行含键名尾段": 登记成注释行是允许的 (注释也是溯源), 但指到一个
            % 与该键无关的行就是假登记 —— 那会让整条 stand_in 记录失去意义。
            tc.verifyTrue(contains(txt(ln), tail), sprintf('槽位 %s 登记的消费点 %s 第 %d 行不含键 %s: 这条登记是空的', e.id, spec, ln, tail));
        end
    end
end
end

function test_idsNotInCode(tc)
[~, S] = ctx();
files = collectMFiles();
hits = strings(0, 1);
for i = 1:numel(files)
    [~, nm] = fileparts(files(i));
    if strcmp(char(nm), 'test_reference_slots_invariants'), continue; end
    blob = strjoin(readLines(files(i)), ' ');
    for k = 1:numel(S.ids)
        if contains(blob, S.ids(k))
            hits(end+1) = string(nm) + ":" + S.ids(k); %#ok<AGROW>
        end
    end
end
tc.verifyEmpty(hits, sprintf('槽位 id 出现在 .m 里(除本测试): %s —— 缺位数据被接进代码却没改清单状态, 正是本判据要拦的事', strjoin(hits, ', ')));
end

function test_closedWorld(tc)
[root, S] = ctx();
refDir = fullfile(root, 'config', 'reference');
tc.assumeTrue(isfolder(refDir), 'config/reference 不存在');
d = dir(refDir);
isDir = [d(:).isdir];        % Windows 下 dir 返回的字段名是小写 isdir
sub = d(isDir);
sub = sub(~ismember({sub.name}, {'.', '..'}));
tc.verifyEmpty(string({sub.name})', 'config/reference 下出现子目录: 闭世界按文件算, 子目录里的东西会被静默漏掉');
files = d(~isDir);
files = files(~ismember({files.name}, {'.', '..'}));
onDisk = sort(string({files.name})');
allowed = sort(unique([slotClaims(S); anchorFileNames(); string(S.allowedAux)]));
unknown = setdiff(onDisk, allowed, 'stable');
tc.verifyEmpty(unknown, sprintf('config/reference 里有未登记的文件: %s —— 丢一份表进这里而清单与锚点计数都不提它, 缺位状态就不再可信', strjoin(unknown, ', ')));
% aux 允许"声明但尚未落地"(loadAnchors 只在 isfile 时才读它); 但 PRESENT 的 path 必须
% 真实存在。今天零 PRESENT 且 aux 为空, 所以这一半对真实清单是空真, 由 test_presentBinding
% 的 negMissingFile 分支用合成夹具行使。
ghost = setdiff(allowed, onDisk, 'stable');
unexpected = setdiff(ghost, string(S.allowedAux), 'stable');
tc.verifyEmpty(unexpected, sprintf('清单声明了盘上不存在的本体文件: %s —— 声明 PRESENT 却不落文件, 比登记缺位更坏', strjoin(unexpected, ', ')));
end

function test_attribution(tc)
[~, S] = ctx();
anchor = anchorFiles();
tc.assumeTrue(numel(anchor) >= 1, 'docs/counts.json 里没有 anchor_files');
declared = slotClaims(S);
unclaimed = string(S.unclaimedAnchors);
bad = strings(0, 1);
for i = 1:numel(anchor)
    f = string(anchor(i).file);
    inDeclared = any(declared == f);
    inUnclaimed = any(unclaimed == f);
    if ~xor(inDeclared, inUnclaimed)
        bad(end+1) = sprintf('%s(被声明=%d, 在unclaimed=%d)', f, inDeclared, inUnclaimed); %#ok<AGROW>
    end
end
tc.verifyEmpty(bad, sprintf('锚点文件归属不满足互斥穷尽: %s —— 两边都在=两说, 两边都不在=这份本体没有归属', strjoin(bad, '; ')));
ghostU = setdiff(unclaimed, string({anchor.file})', 'stable');
tc.verifyEmpty(ghostU, sprintf('unclaimed_anchor_files 里有不属于锚点表的文件: %s —— 锚点文件改名会让本判据因错误原因变红', strjoin(ghostU, ', ')));
end

function test_presentBinding(tc)
% 真实清单今天零 PRESENT => closedWorld/structure 里那些 PRESENT 分支都是空真。
% 空真判据等于没有判据, 所以在 tempdir 里造一份合法清单与数据表走同一套校验,
% 再逐条伪造, 证明"合法能过、四类伪造各被对应的一半拦住"。夹具不落仓库。
anchorOf = struct('file', 'synth_table.csv', 'rows', 3);
reg = registerRows();
cand = reg(startsWith({reg.doi_or_url}', "http"));
if isempty(cand), cand = reg; end
good = cand(1);
tmp = tempdir;
csvPath = fullfile(tmp, 'synth_table.csv');
keep = onCleanup(@() deleteIfFile(csvPath)); %#ok<NASGU>
writeText(csvPath, sprintf('provenance_status,doi_or_url\na,%s\nc,d\n', char(good.doi_or_url)));

[ok, why] = validatePresent(makePresent(csvPath, good.ref_id, good.evidence_grade, 3), anchorOf, reg);
tc.verifyTrue(ok, sprintf('合法 PRESENT 形态被判不合法: %s (判据修坏了)', why));

[ok1, ~] = validatePresent(makePresent(csvPath, 'NO-SUCH-REF', good.evidence_grade, 3), anchorOf, reg);
tc.verifyFalse(ok1, 'ref_id 不在登记册里却放行 —— 来源可以凭空造');

% 伪造的 grade 必须与来源行真实不同: 实测第一条带 URL 的行 (R01) 本身就是 A,
% 直接写死 'A' 会让这条负控与正控取值相同 (永远不红)。
gOther = 'B';
if strcmp(good.evidence_grade, 'B'), gOther = 'C'; end
[ok2, ~] = validatePresent(makePresent(csvPath, good.ref_id, gOther, 3), anchorOf, reg);
tc.verifyFalse(ok2, sprintf('grade 与来源行的 evidence_grade(%s) 不符却放行', good.evidence_grade));

[ok3, ~] = validatePresent(makePresent(csvPath, good.ref_id, good.evidence_grade, 99), anchorOf, reg);
tc.verifyFalse(ok3, 'rows 与锚点表实数不符却放行 —— 本体被换掉而清单没跟上');

[ok4, ~] = validatePresent(makePresent(fullfile(tmp, 'definitely_absent_xyz.csv'), good.ref_id, good.evidence_grade, 3), anchorOf, reg);
tc.verifyFalse(ok4, '声明的路径不在盘上却放行 —— 这正是 closedWorld 对真实清单空真的那一半');

bad5 = makePresent(csvPath, good.ref_id, good.evidence_grade, 3);
bad5.doi = 'https://example.invalid/not-in-the-file';
[ok5, ~] = validatePresent(bad5, anchorOf, reg);
tc.verifyFalse(ok5, '来源行的 URL 没有真的出现在数据文件里却放行 —— 防的是"绑到一份真实存在但无关的表"');
end

function test_materialAbsent(tc)
[root, S] = ctx();
raw = readJson(fullfile(root, 'geometry', 'materials.json'));
tc.assumeTrue(isfield(raw, 'materials'), '材料表没有 materials 数组');
m = raw.materials;
% jsondecode 对"各元素字段集不一致"的对象数组会退化成 cell (gas 有组分、固体没有)。
% 统一成"元胞数组"再逐条取, 不做 num2cell/下标赋值 —— 异型结构体互拷会抛
% heterogeneousStrucAssignment。
if ~iscell(m), m = num2cell(m); end
nM = numel(m);
names = strings(1, nM);
nullish = false(1, nM);
for k = 1:nM
    names(k) = string(m{k}.material_id);
    nullish(k) = isNullish(m{k}, 'elements') && isNullish(m{k}, 'composition_molfrac');
end
% 实测今天 4/5 条材料无组分 (只有 gas 有)。写成"恰好 4"而不是"以下条目无组分":
% 后者会让"新增一条材料并把组分留空"静默通过, 而静默 null 正是本判据要盯的缺位形态。
tc.verifyEqual(sum(nullish), 4, sprintf('材料表里"无组分"的条目数变了(现在: %s) —— 新增静默 null 会让一种缺位材料看起来像已建模', strjoin(names(nullish), ', ')));
for k = 1:numel(S.slots)
    e = S.slots(k);
    if ~strcmp(e.id, 'wall_a150_composition') || ~strcmp(e.status, 'absent'), continue; end
    for want = ["a150", "tissue_equivalent"]
        % 点名两个材料: 它们的 state 分别是 solid 与 liquid_water_equivalent,
        % 写成"所有固体"会静默漏掉 tissue_equivalent。
        idx = find(names == want, 1);
        tc.verifyFalse(isempty(idx), sprintf('材料表里没有 %s 条目', want));
        if isempty(idx), continue; end
        tc.verifyTrue(nullish(idx), sprintf('%s 有了组分但槽位 wall_a150_composition 仍是 ABSENT: 编一份配方进来, 必须先把该槽位带真实来源翻成 PRESENT', want));
    end
end
end

function test_labelsDisclosure(tc)
[root, S] = ctx();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
for k = 1:numel(S.slots)
    e = S.slots(k);
    for q = 1:numel(e.stand_in)
        si = e.stand_in(q);
        tc.verifyFalse(isempty(getByPath(cfg, si.config_key)), sprintf('占位键 %s 不在发货配置里 (清单与现实分叉)', si.config_key));
        lab = getByPath(cfg, si.label_path);
        % 必须取实际值比对: 只看"标签字段在不在"是空头承诺 —— 实测 statusScan 只认子字段
        % status, 所以 _status 那一族今天改值无人察觉。
        tc.verifyFalse(isempty(lab), sprintf('标签路径 %s 取不到值', si.label_path));
        if isempty(lab), continue; end
        tc.verifyEqual(char(strtrim(string(lab))), char(si.expected_label), sprintf('%s 的标签是 %s 而不是 %s: 顶替缺位数据的量级值被升格成"已测"了', si.label_path, string(lab), si.expected_label));
    end
end
reg = readJson(fullfile(root, 'config', 'capability_register.json'));
posTxt = readText(fullfile(root, 'docs', 'positioning.md'));
for k = 1:numel(S.slots)
    e = S.slots(k);
    row = pickEntry(reg.entries, e.owner_capability);
    tc.verifyFalse(isempty(row), sprintf('槽位 %s 的 owner %s 在能力登记表里没有行', e.id, e.owner_capability));
    if isempty(row), continue; end
    st = upper(strtrim(string(row.status)));
    tc.verifyTrue(any(st == ["BLOCKED", "PARTIAL"]), sprintf('槽位 %s 的 owner %s 状态是 %s: 本体数据仍缺位, 该能力不得转 DONE', e.id, e.owner_capability, st));
    blob = strjoin([string(row.reason), evidenceText(row.evidence)], ' ');
    tc.verifyTrue(contains(blob, e.id), sprintf('%s 的 reason/evidence 里没提到槽位 %s: 缺位没在产物里被说出来', e.owner_capability, e.id));
    rs = strtrim(string(row.reason));
    tc.verifyTrue(contains(posTxt, rs), sprintf('%s 的 reason 没有逐字出现在 docs/positioning.md 里: 改了登记表却没重跑 tools/genPositioning.m, 首页与登记表就此分叉', e.owner_capability));
end
end

function test_cfgPurity(tc)
[root, ~] = ctx();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
before = sort(string(fieldnames(cfg))');
tepc.config.referenceSlots();
after = sort(string(fieldnames(cfg))');
added = setdiff(after, before, 'stable');
removed = setdiff(before, after, 'stable');
tc.verifyEmpty(added, sprintf('读取槽位清单给 cfg 加了字段: %s —— 槽位数据一旦并入 cfg, config_sha256 就随清单文本改动而漂移 (身份是合并后的 cfg, 见 makeProvenance)', strjoin(added, ',')));
tc.verifyEmpty(removed, sprintf('读取槽位清单让 cfg 少了字段: %s', strjoin(removed, ',')));
end

%% ============================================================ 共用工具
% 命名纪律: 下面都不叫 test_ 前缀, 且没有"function 名字(tc)"这种单参数形式,
% 所以 functiontests 不收集它们、genCounts 的两种签名口径也不数 —— 否则文档计数与
% 实跑数会分叉 (这个仓库为这种分叉红过一次 236/234)。

function [root, S] = ctx()
root = tepcRoot();
if isempty(which('tepc.config.referenceSlots'))
    addpath(genpath(fullfile(root, 'src')));
end
S = tepc.config.referenceSlots();
end

function r = tepcRoot()
r = tepc.io.projectRoot();
end

function claims = slotClaims(S)
claims = strings(0, 1);
for k = 1:numel(S.slots)
    e = S.slots(k);
    if strcmp(e.status, 'present') && ~isempty(string(e.path))
        claims(end+1) = baseName(e.path); %#ok<AGROW>
    end
end
end

function b = baseName(p)
% 要的是"带扩展名的文件名": fileparts 会把 .csv 当扩展名剥掉
% (实测 fileparts('synth_table.csv') 的 name 段是 'synth_table'), 而锚点表与盘上
% dir 给的都是带 .csv 的名字, 所以这里必须把 ext 拼回去。
[~, nm, ext] = fileparts(char(p));
if isempty(nm) && isempty(ext), b = string(p); else, b = string(nm) + string(ext); end
end

function e = makePresent(path, refId, grade, rows)
e = struct();
e.status = 'present'; e.grade = grade;
e.path = baseName(path); e.absPath = char(path);
e.ref_id = refId; e.rows = rows; e.doi = '';
end

function [ok, msg] = validatePresent(e, anchorOf, reg)
ok = false; msg = '';
if ~any(strcmp({reg.ref_id}', e.ref_id))
    msg = 'ref_id 不在登记册里'; return
end
row = reg(strcmp({reg.ref_id}', e.ref_id));
if ~strcmp(row.evidence_grade, e.grade)
    msg = sprintf('grade 与来源行不符 (来源行是 %s)', row.evidence_grade); return
end
rn = find(string({anchorOf.file})' == string(e.path), 1);
if isempty(rn)
    msg = 'path 不在锚点表里 (没被 genCounts 数过的本体不算数据)'; return
end
if anchorOf(rn).rows ~= e.rows
    msg = sprintf('rows 与锚点表实数 %d 不符', anchorOf(rn).rows); return
end
absFile = e.absPath;
if isempty(absFile) || ~isfile(absFile)
    absFile = fullfile(tepcRoot(), strrep(string(e.path), '/', filesep));
end
if ~isfile(absFile)
    msg = '声明的数据文件不在盘上'; return
end
doi = string(e.doi);
if isempty(doi) || strtrim(doi) == ""
    doi = string(row.doi_or_url);
end
if ~contains(readText(absFile), doi)
    msg = '来源行的 doi_or_url 没有出现在数据文件里'; return
end
ok = true; msg = 'ok';
end

function v = keyTail(dotted)
s = string(dotted);
i = find(s == ".", 1, 'last');
if isempty(i), v = char(s); else, v = char(extractAfter(s, i(1))); end
end

function v = getByPath(cfg, dotted)
% 清单里登记的是 **JSON 里的键名** (那才是盘上的真相); 但 jsondecode 会把不能当
% MATLAB 标识符的键改名 —— 实测 "_status" 变成 "x_status" (前导下划线非法)。
% 所以两级都试: 先按原名, 再按 matlab.lang.makeValidName 的映射名。
parts = string(strsplit(string(dotted), "."));
v = cfg;
for i = 1:numel(parts)
    f = char(parts(i));
    if isstruct(v)
        if isfield(v, f)
            v = v.(f); continue
        end
        f2 = matlab.lang.makeValidName(f);
        if ~strcmp(f2, f) && isfield(v, f2)
            v = v.(f2); continue
        end
    end
    v = []; return
end
end

function t = pickEntry(entries, id)
t = [];
if ~isstruct(entries), return; end
for k = 1:numel(entries)
    if isfield(entries(k), 'id') && strtrim(string(entries(k).id)) == string(id)
        t = entries(k); return
    end
end
end

function e = evidenceText(ev)
e = strings(0, 1);
if isempty(ev), return; end
if isstruct(ev)
    for k = 1:numel(ev)
        if isfield(ev(k), 'path'),   e(end+1) = string(ev(k).path);   end %#ok<AGROW>
        if isfield(ev(k), 'anchor'), e(end+1) = string(ev(k).anchor); end %#ok<AGROW>
    end
elseif iscell(ev)
    e = string(ev(:))';
end
end

function t = isBlank(v)
% 空或全空串: "" 是 1×1 string 而非 isempty, 读取器用 "" 表示"该字段没出现"。
t = isempty(v) || all(string(v) == "") || all(strtrim(string(v)) == "");
end

function t = isNullish(m, f)
% jsondecode 把 JSON null 变成 [], 所以"空"有 []/''/""/{} 几种形态, 一律算无内容。
t = true;
if ~isfield(m, f), return; end
v = m.(f);
if isempty(v), return; end
if isnumeric(v) || islogical(v) || isstruct(v), t = false; return; end
if (ischar(v) || isstring(v)) && strtrim(string(v)) == "", return; end
t = false;
end

function r = registerRows()
% docs/reference_register.csv 列序 (实测): ref_id=1, doi_or_url=5, evidence_grade=6。
lines = readLines(fullfile(tepcRoot(), 'docs', 'reference_register.csv'));
r = struct('ref_id', {}, 'doi_or_url', {}, 'evidence_grade', {});
for i = 2:numel(lines)
    f = csvRow(lines(i));
    if numel(f) < 6, continue; end
    r(end+1) = struct('ref_id', strtrim(f{1}), 'doi_or_url', strtrim(f{5}), ...
        'evidence_grade', strtrim(f{6})); %#ok<AGROW>
end
end

function g = registerGrades()
r = registerRows();
g = sort(unique(string({r.evidence_grade})'));
g = g(g ~= "");
end

function n = anchorFileNames()
a = anchorFiles();
n = strings(0, 1);
for k = 1:numel(a)
    n(end+1) = string(a(k).file); %#ok<AGROW>
end
end

function a = anchorFiles()
j = readJson(fullfile(tepcRoot(), 'docs', 'counts.json'));
a = struct('file', {}, 'rows', {});
if ~isfield(j, 'details') || ~isfield(j.details, 'anchor_files'), return; end
x = j.details.anchor_files;
if ~isstruct(x), return; end
for k = 1:numel(x)
    a(end+1) = struct('file', string(x(k).file), 'rows', double(x(k).rows)); %#ok<AGROW>
end
end

function d = collectMFiles()
root = tepcRoot();
d = strings(0, 1);
roots = {'src', 'app', 'tools', 'tests', 'workflows'};
for s = 1:numel(roots)
    p = fullfile(root, roots{s});
    if ~isfolder(p), continue; end
    x = dir(fullfile(p, '**', '*.m'));
    for i = 1:numel(x)
        if ~x(i).isdir, d(end+1) = string(fullfile(x(i).folder, x(i).name)); end %#ok<AGROW>
    end
end
x = dir(fullfile(root, '*.m'));
for i = 1:numel(x)
    if ~x(i).isdir, d(end+1) = string(fullfile(x(i).folder, x(i).name)); end %#ok<AGROW>
end
end

function t = readLines(p)
raw = strrep(readText(p), "\r\n", "\n");
c = textscan(raw, '%s', 'Delimiter', '\n', 'CollectOutput', true);
if isempty(c{1}), t = strings(0, 1); else, t = string(c{1}(:)); end
end

function s = readText(p)
fid = fopen(p, 'r', 'n', 'UTF-8');
if fid < 0, error('无法读取 %s', p); end
raw = fread(fid, Inf, 'uint8=>uint8');
fclose(fid);
s = native2unicode(raw', 'UTF-8');
end

function j = readJson(p)
j = jsondecode(fileread(p));
end

function f = csvRow(line)
% 单行 CSV 拆分, 尊重双引号与 "" 转义: 登记册里大量引用字段含逗号, 裸按逗号拆会整列错位。
% 这份与 test_constants_registry.m 的 csvFields 同源 —— 那是局部函数无法共享, 复制是
% 这里的代价; 改任一处都要核对另一处。
f = {}; buf = ''; inQ = false;
L = char(string(line));
k = 1;
while k <= numel(L)
    ch = L(k);
    if ch == '"'
        if inQ && k < numel(L) && L(k+1) == '"'
            buf = [buf '"']; k = k + 1;
        else
            inQ = ~inQ;
        end
    elseif ch == ',' && ~inQ
        f{end+1} = buf; buf = '';
    else
        buf = [buf ch];
    end
    k = k + 1;
end
f{end+1} = buf;
end

function writeText(p, s)
fid = fopen(p, 'w', 'n', 'UTF-8');
fwrite(fid, unicode2native(string(s), 'UTF-8'), 'uint8');
fclose(fid);
end

function deleteIfFile(p)
if isfile(p), delete(p); end
end

function [lnStr, file] = splitFileLine(spec)
% 从右往左切: 路径本身可能含冒号 (Windows 盘符 C:/...), 所以除最后一段外全部并回去。
parts = strsplit(string(spec), ":");
if numel(parts) < 2
    lnStr = ''; file = char(spec);
    return
end
lnStr = char(parts(end));
file = char(strjoin(parts(1:end-1), ':'));
end
