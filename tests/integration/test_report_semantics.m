function tests = test_report_semantics
%TEST_REPORT_SEMANTICS 交付措辞、能力登记表与发布标志三者必须一致。
%   结构: 禁语清单在 config/banned_claims.json, 能力状态在
%   config/capability_register.json (entries: id/title/status/gate_layer/requires/
%   evidence/allowed_phrases/forbidden_phrases_ref/reason), 发布标志在
%   runs/<id>/results/gates.json (computational_gates_passed / release_eligible /
%   released / nFail / nNotEvaluated). 本文件核对的是它们之间的推出关系, 而不是
%   某一个字段的当前值。
%
%   为什么用"登记表推出可发布"而不是"人眼看报告": released 是一次计算的产物,
%   登记表是逐项登记的证据指针。两者一旦分叉 (登记表全 PARTIAL 而报告写 RELEASED),
%   只靠人眼会发现不了。这里把推出关系写成断言, 喂错就红。
%
%   jsondecode 对字段类型不一致的结构数组会退化成 cell, 因此所有文本字段统一经
%   asStr() 归一为 string 列向量再比较, 避免 ismember/== 在 cell 上静默错判。
tests = functiontests(localfunctions);
end

%% ==================== 清单与登记表存在 ====================

function test_lexicon_and_register_present(tc)
root = tepc.io.projectRoot();
tc.verifyTrue(isfile(fullfile(root, 'config', 'banned_claims.json')), ...
    '缺 config/banned_claims.json: 禁语扫描会静默空转');
tc.verifyTrue(isfile(fullfile(root, 'config', 'capability_register.json')), ...
    '缺 config/capability_register.json: 发布标志失去可核对的证据来源');
end

%% ==================== 禁语不得出现在交付物里 ====================

function test_no_banned_claim_in_products(tc)
root = tepc.io.projectRoot();
lex = loadJson(tc, root, 'config/banned_claims.json');
ban = asStr(lex.banned_claims);
ban = ban(strlength(ban) > 0);
src = productTexts(root);
% 覆盖面不能取决于"这台机器上有没有跑过仿真": README/docs/GUI/报告生成器是无条件扫的。
% 只扫到两三份文本 = applies_to 声明的范围已经落空, 那时"没有命中"不代表没有禁语。
% 覆盖面按"类别"核而不是按总数核: 总数下限会被一堆同类文件撑满, 于是某一类整个失扫
% 也照样绿 (实测: 丢掉 3 份报告源码就刚好踩在旧下限上)。
grp = groupCounts(root, src);
nv = [grp.n];
missing = string({grp.name}');
missing = missing(nv == 0);
msgMiss = sprintf('applies_to 声明的覆盖面里有 %d 类一份都没扫到: %s (清单=%s)', ...
    numel(missing), strjoin(missing, ', '), strjoin(asStr(lex.applies_to), ' | '));
tc.verifyEqual(missing, strings(0,1), msgMiss);
% 反空转: 类别表只管 README/docs/app/report 四类, HDF5 根属性不在其中 —— 它一旦静默失败,
% "四类都在"照样成立, 而属性其实一份没读。盘上有 events/*.h5 就必须真有 #rootattrs 条目。
rNow = newestRun(root);
if ~isempty(rNow) && ~isempty(dir(fullfile(rNow, 'events', '*.h5')))
    nAttr = nnz(contains(string({src.name}'), "#rootattrs"));
    tc.verifyGreaterThan(nAttr, 0, sprintf( ...
        ['盘上有 events/*.h5 但扫描集合里 #rootattrs 条目为 %d: ' ...
         '属性覆盖面在空转 (读属性失败必须红, 不许返回空文本混过去)'], nAttr));
    % 条目数只证明"遍历到了这个分支", 不证明"读到了可匹配的内容": h5AttrText 在
    % Attributes 为空数组时返回空串, 条目照样计数, 于是禁语匹配恒无命中。
    % 所以还要求这些条目里至少有一份带非空 "名字=值" 文本。
    isAttr = contains(string({src.name}'), "#rootattrs");
    attrTxt = strtrim(string({src(isAttr).text}));
    nTxt = nnz(numel(attrTxt) > 0 & strlength(attrTxt) > 0 & contains(attrTxt, "="));
    tc.verifyGreaterThan(nTxt, 0, sprintf( ...
        ['#rootattrs 条目有 %d 个但非空属性文本 0 份: 读到的都是空串, ' ...
         '"扫过 HDF5 属性"这句话没有内容可匹配'], nAttr));
end
% 类别数下限会被一堆同类文件撑满, 所以它测不到"某一类整个失扫"。run 侧原来只核 nRun>0,
% 那是恒真: newestRun 定义上要求 results/gates.json 存在, 而 gates.json 必然在集合里。
% 改核"发布文本的三类各至少一份" —— 任何一类整个失扫 (报告输出路径变了、summary 改名) 就红。
r = newestRun(root);
if ~isempty(r)
    runNames = string({src.name}');
    runNames = runNames(startsWith(runNames, string(r)));
    base = regexprep(runNames, '^.*[\\/]', '');      % 分隔符两侧都吃: 清单留的是本机 \
    for cls = ["report.html", "summary.json", "gates.json"]
        tc.verifyTrue(any(lower(base) == lower(cls)), sprintf( ...
            ['run 侧扫描集合里没有 %s 这一类发布文本 (共 %d 份 run 文件): ' ...
             'applies_to 第 5 条对这一类落空, "没有命中禁语"对它不成立'], cls, numel(runNames)));
    end
end
hit = strings(0, 1);
for i = 1:numel(src)
    % 必须**纵向**拼接: bannedHits 返 0×1, 而 [0×1, 0×1] 这个横向写法在 MATLAB 里
    % 得到的是 0×2 —— 扫 30 份文本就变成 0×30 的"空数组", 与 strings(0,1) 形状不等,
    % 于是零命中也会红 (实测: 本机 0×30 vs 期望 0×1)。
    hit = [hit; bannedHits(src(i).name, src(i).text, ban)]; %#ok<AGROW>
end
tc.verifyEqual(hit, strings(0, 1), strjoin(hit, newline));
% 上面那句只证明"扫到的文本里没有禁语", 而"清单读空了 / contains 因编码坏掉 / ban 被过滤成
% 全空串"同样会让它成立 —— 那是恒绿判据。所以把一条真禁语喂进**同一个**匹配函数要求命中,
% 再喂一句干净文本要求不命中 (只测正例的话, "什么都算命中"也能通过)。
tc.verifyGreaterThan(numel(ban), 0, sprintf( ...
    '禁语清单读到 %d 条: 空清单让扫描与植入式反例都无从判起', numel(ban)));
planted = ban(1);
hh = bannedHits('planted_probe', "交付物里写着 " + planted + " 这样的字样", ban);
tc.verifyEqual(numel(hh), 1, sprintf( ...
    '植入禁语「%s」后匹配器只给出 %d 条命中: 匹配器在空转, 上面那句"无禁语"不可信', ...
    planted, numel(hh)));
tc.verifyTrue(contains(hh, 'planted_probe'), sprintf( ...
    '命中条目没点名来源, 报告里无法定位: %s', strjoin(hh, ' | ')));
hc = bannedHits('planted_probe', ...
    "本次交付是解析代理模型 (analytic_surrogate_v1), 未对表任何真实装置", ban);
tc.verifyEqual(hc, strings(0, 1), sprintf( ...
    '干净文本被判命中 %d 条: 匹配器过宽, 反例失去意义', numel(hc)));
end

function hit = bannedHits(name, txt, ban)
%BANNEDHITS 禁语匹配的唯一实现: 交付物扫描与植入式反例都走这里 (两份实现必然分叉)。
% 刻意不做大小写或全半角归一: 清单按原样匹配, 归一会把"没命中"与"被归一掉了"混成一谈,
% 要放宽就在清单里显式加条目。
hit = strings(0, 1);
t = string(txt);
for j = 1:numel(ban)
    if contains(t, ban(j))
        hit(end + 1) = sprintf('%s 含禁语「%s」', name, ban(j));
    end
end
end

%% ==================== 登记表的证据指针必须真的能打开 ====================

function test_register_evidence_pointers_resolve(tc)
root = tepc.io.projectRoot();
reg = readRegister(tc, root);
bad = strings(0, 1);
for i = 1:numel(reg)
    ev = reg(i).evidence;
    if isempty(ev)
        continue;
    end
    paths = asStrField({ev.path});
    anchors = asStrField({ev.anchor});
    for k = 1:numel(paths)
        full = fullfile(root, strrep(paths(k), '/', filesep));
        if ~isfile(full)
            bad(end + 1) = sprintf('%s 的证据路径不是可打开的文件: %s', reg(i).id, paths(k));
            continue;
        end
        txt = readAll(full);
        if strlength(anchors(k)) > 0 && ~contains(txt, anchors(k))
            bad(end + 1) = sprintf('%s 的证据锚点在 %s 里找不到: %s', ...
                reg(i).id, paths(k), anchors(k));
        end
    end
end
tc.verifyEqual(bad, strings(0, 1), strjoin(bad, newline));
end

%% ==================== 非 DONE 条目必须写明理由与待办 ====================

function test_register_invariants_hold(tc)
root = tepc.io.projectRoot();
reg = readRegister(tc, root);
vocab = asStr(loadJson(tc, root, 'config/capability_register.json').status_vocabulary);
kinds = asStr(loadJson(tc, root, 'config/capability_register.json').evidence_kinds);
bad = checkRegister(reg, vocab, kinds);
tc.verifyEqual(bad, strings(0, 1), strjoin(bad, newline));
end

function test_negative_control_done_without_evidence_is_flagged(tc)
% 把"喂错要红"钉住: 造一条 status=DONE 但 evidence 为空的条目, 校验器必须点名它。
% 不这么做的后果是登记表可以靠把状态改成 DONE 来解锁发布语, 而没有任何测试会反对。
root = tepc.io.projectRoot();
reg = readRegister(tc, root);
vocab = asStr(loadJson(tc, root, 'config/capability_register.json').status_vocabulary);
kinds = asStr(loadJson(tc, root, 'config/capability_register.json').evidence_kinds);
% 两条负例共用一个校验器: (1) DONE 却零证据; (2) 证据 kind 不在词表内。
m = reg(1);
m.status = "DONE";
m.evidence = struct('path', {}, 'anchor', {}, 'kind', {});
bad = checkRegister([reg; m], vocab, kinds);
tc.verifyFalse(isempty(bad), ...
    '负例未被点名: DONE 且无证据的条目被当成合法, 登记表就不再是发布的门槛');
tc.verifyFalse(isempty(bad(contains(bad, m.id))), ...
    '负例被点名但不是这一条 (命中的是既有问题, 负例本身没有生效)');
m2 = reg(1);
m2.evidence = struct('path', 'README.md', 'anchor', 'TEPC', 'kind', 'bogus_kind');
bad2 = checkRegister([reg; m2], vocab, kinds);
tc.verifyFalse(isempty(bad2(contains(bad2, "bogus_kind"))), ...
    '证据 kind 词表没有约束力: 任意字符串都能进登记表');
end

%% ==================== 发布标志必须由登记表与门禁计数共同支撑 ====================

function test_release_flags_agree_with_gates_and_register(tc)
root = tepc.io.projectRoot();
r = newestRun(root);
tc.assumeTrue(~isempty(r), '仓库里还没有 run 产物, 无法核对发布标志');
G = loadJsonFile(tc, fullfile(r, 'results', 'gates.json'));
reg = readRegister(tc, root);

% 门禁三个标志的内部一致性: 计数与布尔量必须由同一套规则算出。
need = {'nFail', 'nNotEvaluated', 'computational_gates_passed', 'release_eligible', 'released'};
for i = 1:numel(need)
    tc.verifyTrue(isfield(G, need{i}), ...
        sprintf('gates.json 缺字段 %s: 发布语义的核对无从进行', need{i}));
end
tc.verifyEqual(logical(G.computational_gates_passed), G.nFail == 0, ...
    'computational_gates_passed 与 nFail 不自洽');
tc.verifyEqual(logical(G.release_eligible), ~(G.nFail > 0 || G.nNotEvaluated > 0), ...
    'release_eligible 与计数不自洽: 未评估项也必须挡住发布');

% released 的支撑拆成**两条互不吞并**的判据。原先写成
% `released == release_eligible && any(DONE)` 的合取: 第一条 DONE 条目落地后 `any(DONE)`
% 永真, 整个子句对 released 再无约束力 —— 一个会随登记表状态自我失效的断言等于没有断言。
doneAll = any([reg.status] == "DONE");
tc.verifyEqual(logical(G.released), logical(G.release_eligible), ...
    sprintf('released 必须且只能由门禁计数决定 (release_eligible=%d, released=%d)', ...
    G.release_eligible, G.released));
if ~doneAll
    tc.verifyFalse(logical(G.released), ...
        '登记表还没有任何 DONE 条目, released 结构上不允许为 true');
end
% 结构钉: 发货配置下"参考场验证"一项永久 NOT_EVALUATED, 所以今天 release_eligible
% 必须为 false。谁把它放宽成 true, 这条就会红并要求显式定案。
tc.verifyFalse(logical(G.release_eligible), ...
    sprintf(['release_eligible 应为 false (nFail=%d, nNotEvaluated=%d): ' ...
        '参考场门禁未评估时不允许出现可发布姿态'], ...
        G.nFail, G.nNotEvaluated));
end

%% ==================== Q 的研究估计语义必须随数值交付 ====================

function test_Q_research_estimate_label_reaches_products(tc)
% Qbar 是"把 y 当 LET 查经验函数"得到的研究估计, 不是法定剂量当量转换因子。这个语义
% 只在代码注释里说, 拿 summary.json 的读者看不到 —— 因此它必须是产物里的一个字段, 并且
% 报告页上真的印出来。这里跑一次小样本, 核的是产物而不是源码文本。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
R = tepc.run.execute(cfg, 'N', 150, 'Seed', 555, 'RunDir', tempname());
S = R.summary;
tc.verifyTrue(isfield(S, 'Q_y_research_estimate'), ...
    'summary 缺 Q_y_research_estimate: Q 的研究估计身份没有跟着数值走');
tc.verifyTrue(logical(S.Q_y_research_estimate), ...
    'Q_y_research_estimate 必须是 true: Q(y)≈Q(L) 是近似, 不是标定量');
tc.verifyTrue(isfield(S, 'Q_y_approx') && ~isempty(string(S.Q_y_approx)) && ...
        string(S.Q_y_approx) ~= "", ...
    'Q_y_approx 为空: 读者无从知道 Q 是按哪条口径算的');
h = fileread(fullfile(R.runDir.results, 'report.html'));
% 只搜 ASCII 标识: 本机默认字符集 GBK, fileread 读 UTF-8 中文会错位, 中文措辞由
% test_banned_claims_lexicon 那条按字节读的用例负责。
tc.verifySubstring(h, "Q_y_research_estimate", ...
    '报告页没印出 Q 的研究估计标签 (只在 summary 里有, 人看不到)');
end

%% ==================== 横幅文本必须真的被赋值 ====================

function test_banner_text_is_actually_written(tc)
% 界面文案是禁语扫描的落点。若横幅只由一个从不赋值的属性提供, 扫描会永远空转。
root = tepc.io.projectRoot();
txt = readAll(fullfile(root, 'app', 'TEPCApp.m'));
tc.verifyFalse(isempty(regexp(txt, '\.Banner\.Text\s*=', 'once')), ...
    'app/TEPCApp.m 里没有任何给 Banner.Text 赋值的语句: 横幅措辞扫描会空转');
decl = regexp(txt, '(?m)^\s*BannerText\s*(%.*)?$', 'once');
if ~isempty(decl)
    tc.verifyFalse(isempty(regexp(txt, '(?m)^\s*[\w.()]+\.BannerText\s*=', 'once')), ...
        'BannerText 属性被声明却从不赋值: 要么删掉它, 要么与 Banner.Text 同步');
end
end

%% ==================== 辅助函数 (首参不叫 tc, 不计入用例数) ====================

function bad = checkRegister(reg, vocab, kinds)
% 登记表自身的良构检查, 供正向与负例两条用例共用:
%   - status 必须取自 status_vocabulary, 证据 kind 必须取自 evidence_kinds;
%   - 非 DONE 必须写 reason (状态没有说明就等同于没登记);
%   - DONE 必须至少有一条证据, 否则它就成了无据的解锁开关;
%   - id 不得重复 (重复会让逐项扫描只看到第一条)。
bad = strings(0, 1);
% 非标量结构体数组的 s.field 是逗号分隔列表而不是单元格, 直接喂给单参函数会报
% "输入参数太多"; 取列一律写 {s.field}。
ids = asStr({reg.id});
[uq, ~, ic] = unique(ids);
cnt = accumarray(ic, 1);
if any(cnt > 1)
    bad(end + 1) = sprintf('登记表 id 重复: %s', strjoin(uq(cnt > 1)', ', '));
end
for i = 1:numel(reg)
    st = string(reg(i).status);
    if ~ismember(st, vocab)
        bad(end + 1) = sprintf('%s 的 status「%s」不在词表 %s 内', ...
            reg(i).id, st, strjoin(vocab, '/'));
        continue;
    end
    nEv = numel(reg(i).evidence);
    ev = reg(i).evidence;
    for k = 1:numel(ev)
        kd = string(ev(k).kind);
        if ~ismember(kd, kinds)
            bad(end + 1) = sprintf('%s 的证据 kind「%s」不在 evidence_kinds 词表内', ...
                reg(i).id, kd);
        end
    end
    if st == "DONE"
        if nEv == 0
            bad(end + 1) = sprintf('%s 标为 DONE 但没有任何证据条目', reg(i).id);
        end
    elseif strlength(strtrim(string(reg(i).reason))) == 0
        bad(end + 1) = sprintf('%s 状态为 %s 却没写 reason', reg(i).id, st);
    end
end
end

function reg = readRegister(tc, root)
J = loadJson(tc, root, 'config/capability_register.json');
tc.verifyTrue(strcmp(getfieldstr(J, 'schema'), "tepc-capability-register-v1"), ...
    '能力登记表 schema 与测试预期不一致: 字段名可能已改, 逐项核对会错读');
raw = J.entries;
% JSON 对象数组只有在各条目字段集完全一致时 jsondecode 才给结构体数组; 只要有一条少
% 一个字段就退化成 cell, 逐条目扫描的消费方会静默拿不到字段。这里把退化当缺陷报,
% 并直接点名是哪几个字段不一致。
if iscell(raw)
    sets = cellfun(@(s) strjoin(fieldnames(s)', '|'), raw(:), 'UniformOutput', false);
    uniq = unique(sets);
    msg = sprintf('登记表条目字段集不一致 (%d 种): %s', numel(uniq), strjoin(uniq', '  ||  '));
    tc.verifyTrue(false, msg);
    error('tepc:test:RegisterHeterogeneous', '%s', msg);
elseif istable(raw)
    raw = table2struct(raw);
end
tc.verifyTrue(isstruct(raw) && ~isempty(raw), 'entries 必须是非空结构体数组');
reg = raw(:);
for i = 1:numel(reg)
    reg(i).id = string(reg(i).id);
    reg(i).status = string(reg(i).status);
    reg(i).reason = string(reg(i).reason);
    ev = reg(i).evidence;
    if ~isstruct(ev)
        if iscell(ev) && all(cellfun(@isstruct, ev(:)))
            ev = [ev{:}];
        else
            ev = struct('path', {}, 'anchor', {}, 'kind', {});
        end
    end
    reg(i).evidence = ev;
end
end

function v = getfieldstr(s, f)
if isfield(s, f)
    v = string(s.(f));
else
    v = "";
end
end

function J = loadJson(tc, root, rel)
p = fullfile(root, strrep(string(rel), '/', filesep));
tc.assertTrue(isfile(p), sprintf('缺 %s', rel));
J = jsondecode(readAll(p));
end

function J = loadJsonFile(tc, p)
tc.assertTrue(isfile(p), sprintf('缺文件 %s', p));
J = jsondecode(readAll(p));
end

function test_category_coverage_check_can_fail(tc)
% 覆盖面断言自己也要可失败: 造一份"报告生成器一类整个不在扫描集合里"的输入, 检查必须点名它。
% 点不出名就说明这条检查又变回永真式 (此前它从已扫到的文件里 unique 类别, 每类天然 >= 1)。
root = tepc.io.projectRoot();
mk = struct('name', {}, 'text', {});
mk(1).name = fullfile(root, 'README.md');          mk(1).text = "x";
mk(2).name = fullfile(root, 'docs', 'quickstart.md'); mk(2).text = "x";
mk(3).name = fullfile(root, 'app', 'TEPCApp.m');    mk(3).text = "x";
g = groupCounts(root, mk);
nv = [g.n];
missing = string({g.name}');
missing = missing(nv == 0);
tc.verifyEqual(missing, "report", sprintf('报告生成器整类缺席却没点名它 (点名结果=%s): 覆盖面检查是永真式', ...
    strjoin(missing, ',')));
tc.verifyEqual(numel(g), 4, 'AbsTol', 0, '声明的四类覆盖面都要出行, 缺类也要有 n=0 那一行');
end

function src = productTexts(root)
% 扫描集合 = config/banned_claims.json 的 applies_to 所声明的覆盖面: 清单说管到 README
% 与 docs, 扫描就得真的读到它们; 只扫 run 产物的话, 交付主文档里的措辞就没人核。
% 词表自身 (self_exemption: banned_claims.json / test_banned_claims_lexicon.m) 不在本
% 集合里, 所以不需要额外放行规则。
src = struct('name', {}, 'text', {});
lst = {fullfile(root, 'README.md')};
lst = [lst, listOf(fullfile(root, 'app'), '*.m')];
lst = [lst, listOf(fullfile(root, 'app', 'components'), '*.m')];
lst = [lst, listOf(fullfile(root, 'docs'), '*.md')];
lst = [lst, listOf(fullfile(root, 'src', '+tepc', '+report'), '*.m')];
r = newestRun(root);
if ~isempty(r)
    lst = [lst, {fullfile(r, 'results', 'report.html'), ...
        fullfile(r, 'results', 'gates.json'), fullfile(r, 'results', 'spectrum.csv'), ...
        fullfile(r, 'results', 'summary.json'), fullfile(r, 'results', 'provenance.json')}];
end
% applies_to 说的是 runs/*/results/, 所以**已发布 (released=true) 的旧运行**不能因为不是最新
% 就躲开扫描: 禁语一旦进了发布产物就是交付面被污染, 与它属于第几次运行无关。
% 未发布的旧运行不进集合是有意取舍: 每次端到端都会新增一个 run, 全量读 HTML 会让本用例
% 的耗时随历史线性增长, 而它们的文本与最新一次同源同生成器。
% 覆盖要如实说清: 今天仓库里没有任何 released=true 的 run (门禁恒 released=false), 所以
% 下面这个循环在现有套件里**没有已执行的覆盖** —— 它是"一旦有人发布就生效"的前置防线,
% 不能当成已被测过的判据来引用。
dd = dir(fullfile(runsBase(root), '*'));
for i = 1:numel(dd)
    if ~dd(i).isdir, continue; end
    gj = fullfile(dd(i).folder, 'results', 'gates.json');
    if ~isfile(gj) || ~isReleasedGate(gj), continue; end
    lst = [lst, {gj, fullfile(dd(i).folder, 'results', 'report.html'), ...
        fullfile(dd(i).folder, 'results', 'summary.json')}];
end
for i = 1:numel(lst)
    f = lst{i};
    if isfile(f)
        src(end + 1) = struct('name', f, 'text', readAll(f));
    end
end
% HDF5 的根属性同样是交付文本: events/waveforms.h5 把"模拟波形 / 非实测脉冲"这类
% 口径写在文件属性里而不是任何 .json/.html 里, 不读属性就等于让这类措辞躲开扫描。
% 每个存在的 h5 都要产出一条 (读不到就报错, 见 h5AttrText): 静默给空文本会让本用例
% 在"全绿"的名义下扫了个空 —— 这个形状已经踩过一次 (h5readatt 无"读全部属性"形态)。
if ~isempty(r)
    hf = dir(fullfile(r, 'events', '*.h5'));
    for i = 1:numel(hf)
        p = fullfile(hf(i).folder, hf(i).name);
        t = h5AttrText(p);
        src(end + 1) = struct('name', char(string(p) + "#rootattrs"), 'text', t); %#ok<AGROW>
    end
end
end

function t = h5AttrText(f)
% 取一个 HDF5 对象的全部根属性, 拼成 "名字=值" 的多行文本。
%   口径: 列全量只能走 h5info(f).Attributes —— h5readatt 必须给属性名, 省略时报
%   MATLAB:minrhs "输入参数的数目不足"。这里**故意不套 try**: 读不出来就该让本用例红,
%   而不是返回空文本把"这一类根本没扫"伪装成"扫了且干净"。
info = h5info(f);
a = info.Attributes;
buf = strings(numel(a), 1);
for i = 1:numel(a)
    nm = string(a(i).Name);
    v = a(i).Value;
    if isstruct(v)
        buf(i) = nm + "=<struct>";
        continue
    end
    if isempty(v)
        buf(i) = nm + "=<empty>";
        continue
    end
    buf(i) = nm + "=" + strjoin(string(v), ",");
end
t = char(strjoin(buf, newline));
end

function grp = groupCounts(root, src)
% 类别: README / docs / app(界面与组件源码) / +report(报告生成器源码)。
% 每类都必须在扫描集合里出现, 否则"没有命中禁语"这句话对这些类就是空的。
paths = string({src.name}');
rel = strrep(paths, string(root), '');       % 去根前缀 (不写反斜杠字面量: 它会截断字符串)
rel = strrep(rel, char(92), '/');             % 两种分隔符统一成 '/', 类别判定只看一种形状
rel = regexprep(rel, '^[/]+', '');            % 去掉去根前缀后留下的领头分隔符
cat = strings(numel(rel),1);
for i = 1:numel(rel)
    r = rel(i);
    if startsWith(r, "README")
        cat(i) = "README";
    elseif startsWith(r, "docs/")
        cat(i) = "docs";
    elseif startsWith(r, "app/")
        cat(i) = "app";
    elseif contains(r, "+report")
        cat(i) = "report";
    else
        cat(i) = "run";
    end
end
decl = ["README", "docs", "app", "report"];
% 类别表是**声明**的, 不是从扫到的文件里 unique 出来的: 从已扫到的集合 unique 时每类计数
% 天然 >= 1, "某一类整个失扫"永远报不出来 —— 那条覆盖面断言就成了永真式。
grp = struct('name', cellstr(decl), 'n', repmat({0}, size(decl)));
for i = 1:numel(decl)
    grp(i).n = nnz(cat == decl(i));
end
end

function lst = listOf(d, pat)
% dir() 的字段是小写 name/folder; 顺序按名字排, 保证同一仓库两次跑扫的是同一批文件。
lst = {};
if ~isfolder(d)
    return
end
dd = dir(fullfile(d, pat));
nm = sort(string({dd.name}'));
for i = 1:numel(nm)
    lst{end + 1} = fullfile(d, char(nm(i))); %#ok<AGROW>
end
end

function b = runsBase(root)
% runDirs 的落点恒是 <output_root>/runs/<runID>, 设了 TEPC_RUNS_DIR 也一样在它下面
% 再开一层 runs; 只扫 base 本身会看到那个目录名而不是任何一次 run。
base = getenv('TEPC_RUNS_DIR');
if isempty(base)
    base = root;
end
b = fullfile(base, 'runs');
end

function ok = isReleasedGate(gatesPath)
% 只认 gates.json 里 released=true 的 run: 那是"已交付"的机器可读判据。
txt = readAll(gatesPath);
ok = ~isempty(regexp(txt, '"released"\s*:\s*true', 'once'));
end

function r = newestRun(root)
% dir().date 是 cellstr, 不能直接 max; 先转 datenum 再排序。
% 必须跳过"还没有 results/gates.json"的目录: 并行的端到端测试会留下只写了
% 一半的 run 目录, 按 mtime 取最新会选中它, 于是本文件的所有产物断言都变成
% 在测"目录是否写完"而不是在测发布语义。
base = runsBase(root);
r = '';
if ~isfolder(base)
    return;
end
d = dir(base);
keep = [d.isdir] & ~ismember({d.name}, {'.', '..'});
d = d(keep);
if isempty(d)
    return;
end
[~, ord] = sort(datenum({d.date}), 'descend');
for k = 1:numel(ord)
    cand = fullfile(base, d(ord(k)).name);
    if isfile(fullfile(cand, 'results', 'gates.json'))
        r = cand;
        return;
    end
end
end

function txt = readAll(f)
% 按字节读再解 UTF-8: fileread 按系统字符集解码, 这台机器上是 GBK,
% 中文产物会被解成乱码, 于是禁语匹配永远匹配不上。
txt = "";
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0
    return;
end
raw = fread(fid, inf, 'uint8=>uint8');
fclose(fid);
txt = string(native2unicode(raw(:)', 'UTF-8'));
end

function s = asStr(x)
% cell / char / string 归一为 string 列向量。
if isempty(x)
    s = strings(0, 1);
elseif isstring(x)
    s = string(x(:));
elseif ischar(x)
    s = string(x);
elseif iscell(x)
    s = strings(numel(x), 1);
    for i = 1:numel(x)
        s(i) = string(x{i});
    end
else
    s = string(x);
end
end

function s = asStrField(c)
% {struct.field} 的结果: 字段缺失时元素为 [], 归一为 "" 而不是报错。
s = strings(numel(c), 1);
for i = 1:numel(c)
    v = c{i};
    if isempty(v)
        s(i) = "";
    else
        s(i) = string(v);
    end
end
end
