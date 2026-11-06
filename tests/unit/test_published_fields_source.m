function tests = test_published_fields_source
%TEST_PUBLISHED_FIELDS_SOURCE 报告、GUI 与诊断图的显示精度必须同源于字段表。
%   共享真相源一旦成立, "几处印出的数相等" 就按构造为真, 所以行为学断言是恒绿的;
%   能拉住回归的只有结构性判据: 表面里不得再出现该量的字段名 (精度无处可改),
%   表里每个 key 必须真的被显示它的表面调用 (表不得成为死码), 取不到数不得印成假数。
%   静态判据的反例都在 test_predicatesDiscriminate 里现场构造并验证会转红。
    tests = functiontests(localfunctions);
end

function test_specsWellFormed(tc)
specs = tepc.report.publishedFieldSpecs();
dm = displayMap();
tc.verifyEqual(size(specs, 2), 6, '字段表必须六列: key/主字段/同值别名/倍率/格式/单位');
tc.verifyEqual(size(specs, 1), size(dm, 1), '字段表行数与显示面映射的行数不一致');
tc.verifyEqual(size(dm, 2), numel(surfaces()), '显示面映射的列数与 surfaces() 不一致');
keys = string(specs(:, 1));
tc.verifyEqual(numel(unique(keys)), numel(keys), 'key 不得重复');
tc.verifyFalse(any(keys == ""), 'key 不得为空串');
for i = 1:size(specs, 1)
    k = char(keys(i));
    prim = char(specs{i, 2});
    alt = char(specs{i, 3});
    tc.verifyTrue(~isempty(regexp(prim, '^[A-Za-z][A-Za-z0-9_]*$', 'once')), ...
        sprintf('%s 的主字段名 %s 不是合法标识符', k, prim));
    tc.verifyTrue(isempty(alt) || ~isempty(regexp(alt, '^[A-Za-z][A-Za-z0-9_]*$', 'once')), ...
        sprintf('%s 的别名 %s 不是合法标识符', k, alt));
    tc.verifyFalse(strcmp(alt, prim), sprintf('%s 的别名与主字段名相同', k));
    fmt = char(specs{i, 5});
    tc.verifyTrue(~isempty(regexp(fmt, '^%[0-9]*\.?[0-9]*f$', 'once')), ...
        sprintf('%s 的格式 %s 不是定点格式', k, fmt));
    sc = specs{i, 4};
    tc.verifyTrue(isnumeric(sc) && isscalar(sc) && isfinite(sc), ...
        sprintf('%s 的倍率必须是有限标量', k));
    u = char(specs{i, 6});
    tc.verifyTrue(all(double(u) <= 127), sprintf('%s 的单位含非 ASCII 文本: %s', k, u));
    % key 与字段名同名会踩中"表面零命中"判据 (调用点里的 key 字面量就是那个名字)。
    tc.verifyNotEqual(k, prim, sprintf('key 与主字段名同为 %s', k));
    tc.verifyFalse(strcmp(k, alt), sprintf('key 与别名同为 %s', k));
    % 只有"至少两处显示"才需要进表: 单处的量没有对照, 不可能失配。
    tc.verifyGreaterThan(nnz(dm(i, :)), 1, sprintf('%s 只有一个显示面, 不配进表', k));
end
end

function test_fieldsExistInProducer(tc)
runTxt = readRepo('src/+tepc/+run/execute.m');
specTxt = readRepo('src/+tepc/+analysis/buildSpectrum.m');
specs = tepc.report.publishedFieldSpecs();
for i = 1:size(specs, 1)
    k = char(specs{i, 1});
    prim = char(specs{i, 2});
    tc.verifyGreaterThan(tokenCount(runTxt, prim), 0, sprintf( ...
        '%s -> 主字段 %s 在产出方 execute.m 里零命中: 表指向一个不存在的量', k, prim));
    alt = char(specs{i, 3});
    if ~isempty(alt)
        tc.verifyGreaterThan(tokenCount(specTxt, alt), 0, sprintf( ...
            '%s -> 别名 %s 在谱产出方 buildSpectrum.m 里零命中: 别名已不存在', k, alt));
    end
end
end

function test_surfacesCarryNoPrivatePrecision(tc)
specs = tepc.report.publishedFieldSpecs();
files = surfaces();
for i = 1:size(specs, 1)
    toks = {specs{i, 2}, specs{i, 3}};
    for s = 1:numel(files)
        txt = readRepo(files{s});
        for t = 1:numel(toks)
            tok = char(toks{t});
            if isempty(tok) || (t == 2 && s == 3)
                % 别名在图里还参与误差棒算式 (sigma(纵轴) = y^2*sigma_f/yF_exact),
                % 那是计算不是显示, 所以别名零命中只判前两个表面; 图侧判显示形状。
                continue
            end
            n = tokenCount(txt, tok);
            tc.verifyEqual(n, 0, sprintf( ...
                '%s 在 %s 里还出现 %d 次: 显示精度只能在字段表里改, 否则各表面会各自漂移', ...
                tok, files{s}, n));
        end
    end
end
fig = readRepo(files{3});
shapes = {'y_F = %.2f', 'y_D = %.2f', 'n_eff = %.4g'};
for i = 1:numel(shapes)
    tc.verifyEqual(numel(strfind(fig, char(shapes(i)))), 0, sprintf( ...
        '诊断图里还留着私有精度形状 "%s": 图注与表格行会印成两种位数', char(shapes(i))));
end
end

function test_keysAreCalledByTheSurfacesThatShowThem(tc)
specs = tepc.report.publishedFieldSpecs();
keys = string(specs(:, 1));
files = surfaces();
dm = displayMap();
for s = 1:numel(files)
    called = calledKeys(readRepo(files{s}), keys);
    want = keys(dm(:, s));
    tc.verifyEqual(called, want, sprintf( ...
        '%s 实际调用的 key 集合与映射不符 (映射 %s / 实调 %s): 要么锁失效要么映射过期', ...
        files{s}, strjoin(want, ','), strjoin(called, ',')));
end
end

function test_formatterIsExactlyTheTable(tc)
specs = tepc.report.publishedFieldSpecs();
s = cell2struct(cell(1, size(specs, 1)), cellstr(specs(:, 2)), 2);
for i = 1:size(specs, 1)
    s.(specs{i, 2}) = 123.456789;
end
for i = 1:size(specs, 1)
    k = char(specs{i, 1});
    want = sprintf(specs{i, 5}, 123.456789 * specs{i, 4});
    u = char(specs{i, 6});
    if ~isempty(u) && u(1) ~= '%'
        want = [want ' ' u];
    else
        want = [want u];
    end
    tc.verifyEqual(tepc.report.publishedText(s, k), want, ...
        sprintf('%s 的产出与表里的格式+单位不一致', k));
end
% 位数的定义就是"再往后的差异不印"。
a = tepc.report.publishedText(struct('yF_keV_um', 78.1234), 'yF');
b = tepc.report.publishedText(struct('yF_keV_um', 78.1249), 'yF');
tc.verifyEqual(a, b, '第 3 位小数的差异被印出来了: y_F 的位数没收敛到字段表');
c = tepc.report.publishedText(struct('yF_keV_um', 78.129), 'yF');
tc.verifyNotEqual(a, c, '连第 2 位小数的差异都印不出来: 格式化根本没取值');
% 别名必须真的能取到数 (诊断图拿的是谱结构体里的同值别名)。
altTxt = tepc.report.publishedNumber(struct('yF_exact', 78.126), 'yF');
tc.verifyEqual(altTxt, '78.13', sprintf('别名没被取用 (得 "%s")', altTxt));
% 取不到数不得印出看起来合法的数: 字符串会被逐字符转码成 ASCII 码, 空值/NaN/向量/整型
% 都会把"这里没有数"伪装成"数长这样"。
bad = {struct('yF_keV_um', "NA"), struct('yF_keV_um', []), struct('yF_keV_um', NaN), ...
    struct('yF_keV_um', [1 2]), struct('zz', 1), struct('yF_keV_um', uint8(7))};
for i = 1:numel(bad)
    got = tepc.report.publishedNumber(bad{i}, 'yF');
    tc.verifyEqual(got, 'NOT_RECORDED', sprintf( ...
        '第 %d 种取不到数的输入被印成了数值 (得 "%s")', i, got));
end
end

function test_predicatesDiscriminate(tc)
specs = tepc.report.publishedFieldSpecs();
files = surfaces();
keys = string(specs(:, 1));
prim = char(specs{1, 2});
alt = char(specs{1, 3});
for s = 1:numel(files)
    good = readRepo(files{s});
    tc.verifyEqual(tokenCount(good, prim), 0, ...
        sprintf('前提不成立: %s 里 %s 本应零命中', files{s}, prim));
    bad = [newline 'q = sprintf(''%.9f keV/um'', s.' prim ');' newline];
    tc.verifyGreaterThan(tokenCount([good bad], prim), 0, ...
        '把私自改精度的写法插进表面源码后判据没抓到: 这条锁不会红');
    stripped = regexprep(good, 'published(?:Text|Number)\s*\([^)]*\)', 'X');
    miss = missingKeys(stripped, keys);
    tc.verifyEqual(numel(miss), numel(keys), sprintf('%s 的 key-调用判据恒绿', files{s}));
end
altLegs(readRepo(surfacesFile(1)), tc, alt);
runTxt = readRepo('src/+tepc/+run/execute.m');
tc.verifyEqual(tokenCount(regexprep(runTxt, prim, 'zzz'), prim), 0, ...
    '抹掉主字段名后产出方判据没抓到: 存在性判据恒绿');
fig = readRepo(files{3});
tc.verifyEqual(numel(strfind(fig, 'y_F = %.2f')), 0, '前提不成立: 图里本不该有该形状');
tc.verifyGreaterThan(numel(strfind([fig, 'x = sprintf(''y_F = %.2f'', v);'], 'y_F = %.2f')), 0, ...
    '图注重新用私有精度时形状判据没抓到');
end

function altLegs(g1, tc, alt)
% 别名反例。首参刻意不是 tc: genCounts 按"首参是 tc"静态数用例, 首参叫 tc 会把这里算成一个用例。
if isempty(alt), return; end
tc.verifyGreaterThan(tokenCount([g1, newline, 'q = sprintf(''%.9f'', s.', alt, ');'], alt), 0, ...
    '别名字段名的反例没被抓到: 别名判据恒绿');
end

function f = surfacesFile(i)
s = surfaces();
f = s{i};
end

%% ==================== 辅助 (首参不叫 tc, 不计入用例数) ====================

function f = surfaces()
f = {'src/+tepc/+report/htmlReport.m', 'app/TEPCApp.m', 'src/+tepc/+report/diagnosticFigure.m'};
end

function m = displayMap()
% 行 = 字段表行序 (yF, yD, zeroDepPct, effN, intD); 列 = surfaces() 序 (报告, GUI, 诊断图)。
m = [true  true  true; ...
     true  true  true; ...
     true  true  false; ...
     true  true  true; ...
     true  true  false];
end

function root = repoRoot()
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
end

function txt = readRepo(rel)
% 显式 UTF-8 读: 本机默认码页是 GBK, fileread 会把中文按双字节解码并吞掉紧随其后的
% ASCII 字节 -> 同一行里的字段名可能被漏检, "零命中"就成了假绿。
fid = fopen(fullfile(repoRoot(), strrep(rel, '/', filesep)), 'r', 'n', 'UTF-8');
if fid < 0, error('tepc:tests:Unreadable', '无法读取 %s', rel); end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
txt = strrep(txt, sprintf('\r\n'), sprintf('\n'));
txt = strrep(txt, sprintf('\r'), sprintf('\n'));
end

function n = tokenCount(txt, tok)
n = numel(regexp(txt, ['\<' tok '\>']));
end

function called = calledKeys(txt, keys)
hit = false(1, numel(keys));
for i = 1:numel(keys)
    pat = ['published(?:Text|Number)\s*\([^)]*' char(keys(i)) '[^)]*\)'];
    hit(i) = ~isempty(regexp(txt, pat, 'once'));
end
called = keys(hit);
end

function miss = missingKeys(txt, keys)
miss = setdiff(keys, calledKeys(txt, keys));
end
