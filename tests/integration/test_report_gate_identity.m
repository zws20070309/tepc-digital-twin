function tests = test_report_gate_identity
%TEST_REPORT_GATE_IDENTITY report.html 的水印与 results/gates.json 必须是同一个结论。
%   断言三件事 (全部对**一次全新的端到端运行**的落盘产物做):
%     1) 报告里 "红线门禁水印: X" 的 X 与 gates.json 的 watermark 逐字相同;
%     2) gates.json 的 released / release_eligible 等于由逐项状态重算出的
%        nFail / nNotEvaluated 再按同一规则推出的值 (计数本身也由 items 重算);
%     3) 负控: 把内存里的 gates 结论改掉再渲染一次报告, 上面那条一致性判据必须**变红**
%        —— 否则 1) 是在测"提取器什么都没提到", 而不是在测两个结论相同。
%   动机: 一次运行曾求值两次门禁 (提交前一次渲染报告, 提交后一次写 gates.json)。
%   提交前那次看不到尚未落盘的 provenance 与产物清单, 「配置哈希与产物可追溯」与
%   「seed 一致性」按缺失计 -> 报告印 INVALID, 而 gates.json 印 VALID(FOR DEMO, WARN)
%   (实测两例)。现在一次运行只有**一次**门禁求值, 两处消费同一个对象, 因此这条
%   逐字相等是可以被锁住的; 求值点与定点迭代的理由见 tepc.run.execute 的
%   phase="manifest"~"commit" 段。
%   另锁一条: 定点迭代第 1 遍的占位水印不许泄漏到发布集里。
%   辅助函数一律不以 tc 作首参、不以 test_ 开头, 且带输出参数 (functiontests 的
%   收集口径与 tools/genCounts 的静态计数都按签名认测试)。
tests = functiontests(localfunctions);
end

%% ==================== 1) 报告水印 == gates.json 水印 ====================

function test_report_watermark_equals_gates_json(tc)
[runDir, G] = readGates(tc);
html = readUtf8(fullfile(runDir, 'results', 'report.html'));
wmHtml = htmlWatermark(tc, html);
wmJson = string(asText(getf(tc, G, 'watermark')));
tc.verifyEqual(wmHtml, wmJson, sprintf( ...
    ['报告与 gates.json 的门禁结论不一致: report.html 印 "%s" 而 gates.json 写 "%s". ', ...
     '一次运行只允许一次门禁求值, 两处必须消费同一个对象。'], ...
    char(wmHtml), char(wmJson)));
% 占位水印只存在于定点迭代的第 1 遍 (提交前的暂存字节), 泄漏进发布集就是"把没算出来的
% 结论印给用户", 与旧的 INVALID-vs-VALID 分叉是同一类缺陷。
tc.verifyFalse(contains(html, "GATES_NOT_YET_EVALUATED"), ...
    '发布集里的报告残留占位水印: 第二遍渲染没覆盖第一遍, 或未在求值后重算清单与溯源');
% 报告里诊断图的可读性契约: 图按原始像素显示 + 外层容器可横向滚动, 而不是缩进 960 px 的 body。
% 这里发生过一次真实缺陷: 1887 px 的图被缩到 960 px 后, 6.5 pt 的脚注只剩约 3.3 pt,
% 中文读不出来 —— 图本体修好了, 报告里还是看不见。本判据不看图 (图有墨迹锁), 只看 HTML 写法。
[v, nImg, nFont, nSmall] = cssReadabilityViolations(html);
% 覆盖面下限: 空集上的"0 违规"不算通过。整份报告没嵌图就没有缩放可判, 一个显式字号都没有
% 就没有下限可判, 两条判据都会静默变绿。
tc.verifyGreaterThanOrEqual(nImg, 1, '报告正文里没有 <img>: 图缩放判据落在空集上, "0 违规"是恒绿装饰');
tc.verifyGreaterThanOrEqual(nFont, 1, '报告正文里没有任何显式 font-size: 字号判据落在空集上');
tc.verifyFalse(any(v == "IMG_SCALED"), ...
    '报告把诊断图缩放显示 (<img> 自身没有 max-width:none): 脚注会缩到读不出来');
tc.verifyFalse(any(v == "IMG_WRAP_NO_SCROLL"), ...
    '图外层容器没有 overflow-x:auto: 原始像素的图会被裁掉而不是滚动, 等于看不见');
tc.verifyFalse(any(startsWith(v, "FONT_TOO_SMALL")), ...
    sprintf('报告里出现低于 6 pt 的字号 (%s): 0.8em / 6pt 是可读下限', strjoin(v, ',')));
tc.verifyFalse(any(startsWith(v, "SMALL_UNDER_FLOOR")), ...
    sprintf('有 %d 个 <small>, 其中折掉 0.8 倍率后低于 6 pt (%s)', nSmall, strjoin(v, ',')));
% 反例腿: 每一类破坏单独注入, 各自要求"自己那类必须报红 + 别类不得连带报红"。
% 只用真报告当正控证明不了检测器有牙, 所以每条腿都带一个 no-op 守卫或健康对照。
FLOOR = 6;
legs = { ...
    'IMG_SCALED',         strrep(html, 'max-width:none', 'max-width:100%'),                       "IMG_SCALED"; ...
    'IMG_ATTR_SCALED',    strrep(html, '<img ', '<img width="400" '),                             "IMG_ATTR_SCALED"; ...
    'IMG_WRAP_NO_SCROLL', strrep(html, 'overflow-x:auto;border', 'border'),                       "IMG_WRAP_NO_SCROLL"; ...
    'IMG_WRAP_SHRUNK',    strrep(html, 'overflow-x:auto;border', 'overflow-x:auto;zoom:0.3;border'), "IMG_WRAP_SHRUNK"; ...
    'FONT_NESTED_EM',     '<div style="font-size:0.6em"><p style="font-size:0.7em"><small>x</small></p></div>', "FONT_BELOW_FLOOR"; ...
    'FONT_ABS_PX',        '<p style="font-size:6px">x</p>',                                       "FONT_BELOW_FLOOR"; ...
    'SMALL_UNDER_FLOOR',  '<div style="font-size:0.5em"><small>x</small></div>',                  "SMALL_UNDER_FLOOR"};
for i = 1:size(legs, 1)
    nmLeg = legs{i,1}; mut = legs{i,2}; want = legs{i,3};
    if startsWith(nmLeg, 'IMG')
        tc.verifyFalse(isequal(mut, html), sprintf('注入 %s 没改动任何字节: 报告里没有那段字样, 反例腿无从判起', nmLeg));
    else
        [okCtl, ~, ~, ~] = cssReadabilityViolations('<div style="font-size:1em"><p>ok</p></div>');
        tc.verifyTrue(isempty(okCtl), '健康对照片段被判违规: 级联实现本身错了, 反例结论不可信');
    end
    [vv, ~, ~, ~] = cssReadabilityViolations(mut);
    tc.verifyTrue(any(contains(vv, want)), sprintf('注入 %s 之后判据没报 %s (实得: %s): 这条腿是空转', nmLeg, want, strjoin(vv, ', ')));
    % 纯度: 这三条注入只应引出自己那一类违规。多引出别类说明判据互相污染,
    % 或者报告里本来就有一条被静默忽略的真违规。
    if any(nmLeg == ["IMG_SCALED", "IMG_ATTR_SCALED", "IMG_WRAP_NO_SCROLL"])
        tc.verifyEqual(numel(vv), 1, sprintf('注入 %s 引出 %d 条违规 (%s): 判据不独立, 或报告里另有一条一直没被说出来的违规', nmLeg, numel(vv), strjoin(vv, ', ')));
    end
end
tc.verifyEqual(FLOOR, 6, '可读性下限常量被改动: 反例片段的量级是按 6 pt 选的');
end

function [v, nImg, nFontDecl, nSmall] = cssReadabilityViolations(html)
%CSSREADABILITYVIOLATIONS 报告 HTML 的可读性契约: 图不被缩放 + 级联后的有效字号不低于 6 pt。
%   字号按标签栈做级联: 根基准 12 pt (浏览器默认 16 px = 12 pt), 每个元素在继承值上乘自己的系数。
%   认得的通道: font-size 的 em/% (相对父级)、rem (相对根)、pt、px; <small>(0.8)、<big>(1.25)、
%   <sup>/<sub>(0.833); zoom:N 与 transform:scale(N); 以及 <style> 里形如 td,th{font-size:0.92em}
%   的简单标签选择器。类选择器与后代选择器不解析 (报告里没有), 认不得的一律不猜。
%   标签切分一律用 find(h=='<') 的位置表而不是正则: 报告里 <img> 带着 ~2 MB 的 base64 载荷,
%   跨它的 '[^>]*>' 在本机 MATLAB 上量到 0 个匹配, 字面扫描没有回溯与长度问题。
v = strings(0, 1);
h = char(html);
ROOT_PT = 12;
FLOOR_PT = 6;
VOID = ["img", "br", "hr", "meta", "link", "input", "source"];

% ---------- 图 ----------
imgStart = strfind(h, '<img');
nImg = numel(imgStart);
for k = 1:nImg
    gt = find(h(imgStart(k):end) == '>', 1, 'first');
    if isempty(gt), continue; end
    tag = h(imgStart(k):(imgStart(k) + gt - 1));
    if ~contains(tag, 'max-width:none')
        v(end+1) = "IMG_SCALED"; %#ok<AGROW>
    end
    % max-width / min-width / line-height 里都含 "width:"/"height:" 子串, 不先剥前缀会把发货写法
    % 本身误判成缩放 (实测 style="max-width:none" 触发了 IMG_ATTR_SCALED)。
    tagW = regexprep(tag, '(?<=max-)(width)|(?<=min-)(width)|(?<=line-)(height)', 'zz');
    if ~isempty(regexpi(tagW, '(width|height)\s*=')) || ~isempty(regexpi(tagW, '(width|height)\s*:'))
        v(end+1) = "IMG_ATTR_SCALED"; %#ok<AGROW>
    end
    dv = strfind(h(1:max(1, imgStart(k) - 1)), '<div');
    wrap = '';
    if ~isempty(dv)
        ge = find(h(dv(end):end) == '>', 1, 'first');
        if ~isempty(ge), wrap = h(dv(end):(dv(end) + ge - 1)); end
    end
    if isempty(wrap) || ~contains(wrap, 'overflow-x:auto')
        v(end+1) = "IMG_WRAP_NO_SCROLL"; %#ok<AGROW>
    end
    if ~isempty(regexpi(wrap, 'zoom\s*:\s*0\.\d')) || ~isempty(regexpi(wrap, 'scale\(\s*0\.\d'))
        v(end+1) = "IMG_WRAP_SHRUNK"; %#ok<AGROW>
    end
end

% ---------- <style> 里的简单标签选择器 ----------
rulePt = containers.Map('KeyType', 'char', 'ValueType', 'double');
st = strfind(h, '<style');
for a = 1:numel(st)
    close = strfind(h(st(a):end), '</style>');
    if isempty(close), continue; end
    css = h(st(a):(st(a) + close(1) - 1));
    blk = regexp(css, '([a-zA-Z0-9,._#\s-]+)\{([^}]*)\}', 'tokens');
    for b = 1:numel(blk)
        mfs = regexpi(blk{b}{2}, 'font-size\s*:\s*([0-9.]+)\s*(em|pt|px|rem|%)', 'tokens', 'once');
        if isempty(mfs), continue; end
        parts = strsplit(lower(strrep(strrep(blk{b}{1}, newline, ' '), '\r', ' ')), ',');
        for c = 1:numel(parts)
            name = strtrim(parts{c});
            if isempty(name) || name(1) == '.' || name(1) == '#', continue; end
            rulePt(name) = cssToPt(str2double(mfs{1}), lower(mfs{2}), ROOT_PT, ROOT_PT);
        end
    end
end

% ---------- 标签栈级联 ----------
lt = find(h == '<');
gt = find(h == '>');
effPt = ROOT_PT;
stack = repmat(ROOT_PT, 1, 8192);
depth = 0;
nSmall = 0;
for i = 1:numel(lt)
    a = lt(i);
    if a >= numel(h), continue; end
    if h(a+1) == '/'
        if depth >= 1
            effPt = stack(depth);
            depth = depth - 1;
        end
        continue
    end
    if h(a+1) == '!' || h(a+1) == '?', continue; end
    gj = find(gt > a, 1, 'first');
    if isempty(gj), continue; end
    b = gt(gj);
    if b - a > 400, continue; end      % 正文里出现的 '<' 会配到很远处的 '>', 那不是标签
    t = h(a:b);
    nm = regexp(t, '^<([a-zA-Z0-9]+)', 'tokens', 'once');
    if isempty(nm), continue; end
    name = lower(nm{1});
    inherit = effPt;
    if isKey(rulePt, name)
        inherit = rulePt(name);
    end
    newPt = inherit;
    mfs = regexpi(t, 'font-size\s*:\s*([0-9.]+)\s*(em|pt|px|rem|%)', 'tokens', 'once');
    if ~isempty(mfs)
        newPt = cssToPt(str2double(mfs{1}), lower(mfs{2}), inherit, ROOT_PT);
    end
    switch name
        case 'small', nSmall = nSmall + 1; newPt = newPt * 0.8;
        case 'big',   newPt = newPt * 1.25;
        case {'sup', 'sub'}, newPt = newPt * 0.833;
    end
    mzz = regexpi(t, 'zoom\s*:\s*([0-9.]+)', 'tokens', 'once');
    if isempty(mzz), mzz = regexpi(t, 'scale\(\s*([0-9.]+)', 'tokens', 'once'); end
    if ~isempty(mzz), newPt = newPt * str2double(mzz{1}); end
    if ~isfinite(newPt) || newPt <= 0, newPt = inherit; end
    if newPt < FLOOR_PT
        v(end+1) = sprintf('FONT_BELOW_FLOOR %s->%.2fpt', name, newPt); %#ok<AGROW>
        if strcmp(name, 'small')
            v(end+1) = sprintf('SMALL_UNDER_FLOOR %.2fpt', newPt); %#ok<AGROW>
        end
    end
    if ~any(string(name) == VOID)
        if depth + 1 > numel(stack)
            stack(end + 4096) = ROOT_PT; %#ok<AGROW>
        end
        depth = depth + 1;
        stack(depth) = effPt;
        effPt = newPt;
    end
end
ks = keys(rulePt);   % containers.Map 的 Keys 是受保护属性, 只能走 keys() 函数
for q = 1:numel(ks)
    if rulePt(ks{q}) < FLOOR_PT
        v(end+1) = sprintf('FONT_BELOW_FLOOR %s->%.2fpt', ks{q}, rulePt(ks{q})); %#ok<AGROW>
    end
end
nFontDecl = numel(strfind(h, 'font-size'));
end

function pt = cssToPt(val, unit, inheritPt, rootPt)
% em/% 相对父级, rem 相对根, pt 绝对, px 按 1 px = 0.75 pt; 认不得的单位返回 NaN (不猜)。
switch unit
    case 'em',   pt = inheritPt * val;
    case '%',    pt = inheritPt * val / 100;
    case 'rem',  pt = rootPt * val;
    case 'pt',   pt = val;
    case 'px',   pt = val * 0.75;
    otherwise,   pt = NaN;
end
end

%% ==================== 2) released / release_eligible 必须由计数重算得出 ====================

function test_release_flags_recompute_from_item_counts(tc)
[runDir, G] = readGates(tc);
% 计数不信任落盘的 nFail/nWarn/nNotEvaluated: 先由 items 的逐项状态重算一遍。
st = itemStatuses(tc, G);
nFail = nnz(st == "FAIL");
nWarn = nnz(st == "WARN");
nNE   = nnz(st == "NOT_EVALUATED");
tc.verifyEqual(double(getf(tc, G, 'nFail')), nFail, sprintf( ...
    'gates.json 的 nFail=%g 与逐项重算的 %d 不符 (实得状态: %s)', ...
    getf(tc, G, 'nFail'), nFail, strjoin(unique(st), ',')));
tc.verifyEqual(double(getf(tc, G, 'nNotEvaluated')), nNE, ...
    sprintf('nNotEvaluated=%g 而重算得 %d', getf(tc, G, 'nNotEvaluated'), nNE));
tc.verifyEqual(double(getf(tc, G, 'nWarn')), nWarn, ...
    sprintf('nWarn=%g 而重算得 %d', getf(tc, G, 'nWarn'), nWarn));
tc.verifyEqual(numel(st), numel(G.items), '每项状态都必须被读到 (读不到就没有核对)');

elig = ~(nFail > 0 || nNE > 0);
tc.verifyEqual(logical(getf(tc, G, 'release_eligible')), elig, sprintf( ...
    ['release_eligible=%d 与由计数重算的 %d 不符: 规则是 "无 FAIL 且无 NOT_EVALUATED". ', ...
     '(nFail=%d, nNotEvaluated=%d)'], ...
    logical(getf(tc, G, 'release_eligible')), elig, nFail, nNE));
tc.verifyEqual(logical(getf(tc, G, 'computational_gates_passed')), nFail == 0, ...
    'computational_gates_passed 必须等于 "没有 FAIL"');
mode = string(asText(getf(tc, readSummary(tc, runDir), 'mode')));
tc.verifyEqual(logical(getf(tc, G, 'released')), elig && mode == "VALIDATED", sprintf( ...
    'released=%d 与推出值不符: release_eligible=%d 且 run.mode="%s" 才允许 released', ...
    logical(getf(tc, G, 'released')), elig, char(mode)));
% 水印本身也是计数的一致函数 (三条分支), 一并重算 —— 否则"报告 == gates.json"
% 只锁住了两处一起错。
want = "VALID(FOR DEMO)";
if nFail > 0
    want = "INVALID";
elseif nWarn > 0
    want = "VALID(FOR DEMO, WARN)";
end
tc.verifyEqual(string(asText(getf(tc, G, 'watermark'))), want, sprintf( ...
    'watermark 与 (nFail=%d, nWarn=%d) 的分支规则不符 (实得 "%s", 应为 "%s")', ...
    nFail, nWarn, char(string(asText(getf(tc, G, 'watermark')))), char(want)));
end

%% ==================== 3) 负控: 改坏内存结论, 同一判据必须变红 ====================

function test_negative_control_mutated_gates_breaks_identity(tc)
R = sharedRun();
gatesJson = readGatesRaw(tc, R.runDir.root);
wmJson = string(asText(getf(tc, gatesJson, 'watermark')));
% 前提: 未改动的对象渲染出的报告与 gates.json 一致 (否则下面那条红是"一直红",
% 不是被改动弄红的, 负控就毫无信息量)。
pGood = fullfile(tempdir, sprintf('tepc_wmctrl_ok_%s.html', idTag()));
tc.addTeardown(@() delFile(pGood));
tepc.report.htmlReport(R, pGood);
tc.verifyTrue(watermarkMatches(pGood, wmJson), ...
    '前提不成立: 原样渲染的报告就已经与 gates.json 不一致, 负控无从判断');
% 篡改内存里的门禁结论再渲染一次 (只渲染到临时文件, 绝不覆盖发布集里的报告)。
Rbad = R;
bad = string(Rbad.gates.watermark);
if bad == "INVALID"
    bad = "VALID(FOR DEMO)";
else
    bad = "INVALID";
end
Rbad.gates.watermark = bad;
Rbad.gates.nFail = 99;
pBad = fullfile(tempdir, sprintf('tepc_wmctrl_bad_%s.html', idTag()));
tc.addTeardown(@() delFile(pBad));
tepc.report.htmlReport(Rbad, pBad);
tc.verifyFalse(watermarkMatches(pBad, wmJson), sprintf( ...
    '篡改水印为 "%s" 后一致性判据仍然成立: 那条判据没在读报告里的水印 (空转)', char(bad)));
% 同一判据用 assert 走一遍, 让"变红"这件事在本用例的输出里留下现场证据。
red = false;
try
    assert(watermarkMatches(pBad, wmJson), '报告水印与 gates.json 的 watermark 逐字相等');
catch e
    red = true;
    fprintf('[负控] 篡改后同一断言如期变红: %s\n', char(e.message));
end
tc.verifyTrue(red, '负控未让同一条一致性断言失败: 该断言对门禁结论的分叉不敏感');
wmBad = htmlWatermark(tc, readUtf8(pBad));
tc.verifyEqual(wmBad, bad, sprintf('渲染没把篡改写进报告 (实得 "%s")', char(wmBad)));
end

%% ==================== 辅助 (首参不叫 tc, 带输出参数, 不以 test_ 开头) ====================

function R = sharedRun()
% 一次全新的**小**运行, 三个用例共用 (端到端求值一次即可, 也保证核的是同一份产物)。
%   持久化是刻意的: 每次 execute 都要重跑事件生成与刻度, 而这里要证的是"一次运行内
%   两处结论相同", 跑三次反而会把结论摊到三份产物上。目录留在 tempdir 供事后审计。
persistent cache
if isempty(cache)
    rd = newRunDir('gateident');
    cache = tepc.run.execute(demoCfg(), 'N', 250, 'Seed', 4242, 'RunDir', rd);
end
R = cache;
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
% UQ 关掉: 本文件核的是"报告与 gates.json 同一结论", 与不确定度评估无关;
% uq.json 按设计不产, 可追溯性项把它的缺失算成"按设计不产"而不是违规。
cfg.uq.enabled = false;
end

function [runDir, G] = readGates(tcase)
R = sharedRun();
runDir = string(R.runDir.root);
G = readGatesRaw(tcase, R.runDir.root);
end

function G = readGatesRaw(tcase, runDir)
p = fullfile(char(string(runDir)), 'results', 'gates.json');
tcase.assertTrue(isfile(p), sprintf('缺 gates.json: %s', p));
G = jsondecode(readUtf8(p));
end

function S = readSummary(tcase, runDir)
p = fullfile(char(runDir), 'results', 'summary.json');
tcase.assertTrue(isfile(p), sprintf('缺 summary.json: %s', p));
S = jsondecode(readUtf8(p));
end

function w = htmlWatermark(tcase, html)
% 提取契约见 htmlReport.m 里水印那一行: "<b>红线门禁水印: X</b>", X 逐字等于
% gates.json 的 watermark (不追加解释性后缀)。取不到即为红, 不得静默返回空串。
tok = regexp(html, '红线门禁水印:\s*([^<]*)</b>', 'tokens', 'once');
tcase.verifyFalse(isempty(tok), ...
    '报告里找不到 "红线门禁水印: ...</b>": 首页固定字段变了, 一致性核对无从取值');
if isempty(tok)
    w = "<提取失败>";
    return;
end
w = strtrim(string(tok{1}));
end

function tf = watermarkMatches(htmlPath, expected)
% 与用例 1 同一条判据 (供负控复用): 报告里的水印与给定字符串逐字相等。
html = readUtf8(htmlPath);
tok = regexp(html, '红线门禁水印:\s*([^<]*)</b>', 'tokens', 'once');
if isempty(tok)
    tf = false;
    return;
end
tf = strtrim(string(tok{1})) == string(expected);
end

function st = itemStatuses(tcase, G)
% items 经 jsondecode 可能是结构体数组, 也可能因字段集不齐退化成 cell; 两条都读。
tcase.assertTrue(isfield(G, 'items'), 'gates.json 缺 items: 无法重算计数');
raw = G.items;
if iscell(raw)
    c = cellfun(@(s) asText(getfieldSafe(s, 'status')), raw(:), 'UniformOutput', false);
    st = string(c(:))';
elseif isstruct(raw) && ~isempty(raw)
    % 非标量结构体数组的 s.field 是逗号分隔列表 -> 逐元素走 arrayfun, 不点索引
    c = arrayfun(@(s) asText(getfieldSafe(s, 'status')), raw, 'UniformOutput', false);
    st = string(c(:))';
else
    tcase.verifyTrue(false, 'gates.json 的 items 既不是结构体数组也不是 cell');
    st = strings(0, 1);
end
end

function v = getfieldSafe(s, nm)
if isstruct(s) && isfield(s, nm)
    v = s.(nm);
else
    v = "";
end
end

function v = getf(tcase, s, nm)
tcase.assertTrue(isstruct(s) && isfield(s, nm), sprintf( ...
    'gates/summary 里没有字段 %s (实得字段: %s)', nm, strjoin(string(fieldnames(s)), ',')));
v = s.(nm);
end

function t = asText(v)
% jsondecode 对字符串可能给 char / string / cell of char, 统一成 string。
if isempty(v)
    t = "";
elseif iscell(v)
    t = string(v{1});
elseif isstring(v)
    t = v(1);
else
    t = string(v);
end
end

function txt = readUtf8(f)
% 按字节读再显式解 UTF-8: 本机默认字符集是 GBK, fileread 会把中文解成乱码,
% 于是"红线门禁水印"这个锚点根本匹配不上 (测试会变成在测提取器找不到东西)。
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0
    txt = "";
    return;
end
raw = fread(fid, inf, 'uint8=>uint8');
fclose(fid);
txt = string(native2unicode(raw(:)', 'UTF-8'));
end

function p = newRunDir(tag)
p = sprintf('%s%c%s', tempdir, filesep, sprintf('tepc_wm_%s_%s_%04x', tag, ...
    char(string(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))), randi(65535)));
if isfolder(p), rmdir(p, 's'); end
mkdir(p);
end

function s = idTag()
s = sprintf('%08x', randi(intmax('uint32')));
end

function n = delFile(p)
n = 0;
try
    if isfile(p)
        delete(p);
        n = 1;
    end
catch
end
end
