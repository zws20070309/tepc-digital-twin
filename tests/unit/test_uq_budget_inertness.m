function tests = test_uq_budget_inertness
%TEST_UQ_BUDGET_INERTNESS 预算表与已接入扰动必须同清单; 壁参数对发布量实测零响应.
%
% 两件事绑在一起, 因为它们回答同一个问题: 预算表上写的每一项, 代码里真的在传播吗?
%   1) docs/uncertainty_budget.md 的表格行必须逐一覆盖 tepc.uq.mappedVariables() 的
%      每个变量, 且表里不得出现代码没实现的"幽灵变量". 分叉的历史形态是"阈值/死时间"
%      一行写着"点值(未给不确定度)", 而 threshold_rel/deadTime_rel 早已接入链路并计入
%      合成 —— 表低估了代码, 读者据此会重复申请同一项预算.
%   2) 壁厚/壁密度**故意不在**映射表里, 本文件用实测把理由钉住: 名义 3 mm A-150 下壁
%      参数只挪动"壁内沉积 vs 逸出"的分配, 气腔沉积列与 f(y)/y_F 逐位不动, 逸出恒零.
%      一个响应恒为 0 的变量进了 LHS 表会被读成"已评估且可忽略", 比不评估更糟.
%
% 判据形态: 该动的必须真的动 (薄壁处逸出>0, 面密度相同时逸出相同 —— 证明覆盖项确实
% 接到了 wallEscape 而不是接了个死参数), 不该动的必须逐位不动 (AbsTol 0).
tests = functiontests(localfunctions);
end

%% ==================== 夹具 ====================

function [cfg, R, tables] = demoSetup()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
R = tepc.config.resolve(cfg);
tables = struct('proton', tepc.transport.stoppingPower(cfg, "proton"), ...
    'electron', tepc.transport.stoppingPower(cfg, "electron"), ...
    'heavy_C', tepc.transport.stoppingPower(cfg, "heavy_C"), ...
    'heavy_O', tepc.transport.stoppingPower(cfg, "heavy_O"));
end

function E = runAt(cfg, R, tables, nEv, t_m, rho_g_cm3)
% 同一 seed、同一批初级粒子, 只改壁厚(走 geom)与壁密度(走 xopts 覆盖项).
g = R.geom;
if ~isnan(t_m)
    g.wallThickness_m = t_m;
end
rs = RandStream('Threefry', 'Seed', 20260923);
if isnan(rho_g_cm3)
    [E, ~] = tepc.transport.AnalyticAdapter(cfg, g, tables, rs, nEv, 1, struct('tNext', 0));
else
    [E, ~] = tepc.transport.AnalyticAdapter(cfg, g, tables, rs, nEv, 1, ...
        struct('tNext', 0), struct('rho_wall_g_cm3', rho_g_cm3));
end
end

function txt = budgetText()
f = fullfile(tepc.io.projectRoot(), 'docs', 'uncertainty_budget.md');
assert(isfile(f), '缺 docs/uncertainty_budget.md');
txt = fileread(f);
end

function rows = tableRows(txt)
% 只取表格正文行: 丢掉 |---| 分隔行, 否则"覆盖"会被分隔行满足.
L = strsplit(txt, newline);
body = L(startsWith(strtrim(L), '|'));
rows = strings(0, 1);
for i = 1:numel(body)
    s = strtrim(string(body{i}));
    if strlength(regexprep(s, '[-:\s|]', "")) > 0
        rows(end+1) = s; %#ok<AGROW>
    end
end
end

%% ==================== 1. 表与码的清单必须互为子集 ====================

function test_budget_table_covers_every_mapped_variable(tc)
rows = tableRows(budgetText());
tc.verifyGreaterThan(numel(rows), 5, sprintf('预算表只有 %d 个正文行: 覆盖判据会因表被清空而恒真', numel(rows)));
allRows = strjoin(rows, " ");
mp = tepc.uq.mappedVariables();
miss = mp(~contains(allRows, mp));
tc.verifyEmpty(miss, sprintf('这些已接入的扰动变量没在预算表里登记: %s (表低估代码 => 同一项被重复申请)', ...
    strjoin(miss, ', ')));
end

function test_budget_table_declares_no_ghost_variable(tc)
rows = tableRows(budgetText());
tok = regexp(strjoin(rows, " "), '`([A-Za-z][A-Za-z0-9_]*_rel)`', 'tokens');
named = strings(0, 1);
if ~isempty(tok)
    % regexp(...,'tokens') 给的是 1×N cell, 每格再套一个 1×1 cell; 只拆一层会剩下
    % cell-of-cell, 于是 @(c) c{1} 在 char 上抛 MATLAB:cellRefFromNonCell。
    named = string(cellfun(@(c) c{1}, tok(:), 'UniformOutput', false));
end
ghost = named(~ismember(named, tepc.uq.mappedVariables()));
tc.verifyEmpty(ghost, sprintf('预算表登记了这些代码里没有映射的变量: %s (表高估代码 => 读者以为某项已被传播)', ...
    strjoin(ghost, ', ')));
end

function test_wall_terms_are_deliberately_absent_from_the_mapped_set(tc)
% 壁厚/壁密度不入表的决定必须是可失败的: 若有人把它们加进映射表却不同时补上壁内
% 次级产生, 本文件的第 3 节会先指出"响应恒为零", 而不是让一条恒零行悄悄进预算.
mp = tepc.uq.mappedVariables();
tc.verifyFalse(any(mp == "wallDensity_rel") || any(mp == "wallThickness_rel"), ...
    ['壁厚/壁密度已被当作可传播变量; 但在补上壁内反冲核之前它们对发布谱严格零响应 ' ...
     '(见本文件第 3 节实测), 入表等于登记一条恒零的预算项']);
end

%% ==================== 2. 覆盖项确实接到输运 ====================

function test_wall_overrides_reach_the_transport(tc)
[cfg, R, tables] = demoSetup();
rhoN = tepc.transport.wallDensity(struct());
E0 = runAt(cfg, R, tables, 300, 0, NaN);          % 壁摘掉: 全部剩余能量记为逸出
E1 = runAt(cfg, R, tables, 300, 1e-5, rhoN);
E2 = runAt(cfg, R, tables, 300, 1e-5, 0.25*rhoN);
esc1 = sum(E1.ev.Eescape_keV);
esc2 = sum(E2.ev.Eescape_keV);
tc.verifyGreaterThan(sum(E0.ev.Eescape_keV), 0, 't=0 参照腿的逸出为 0: 出腔剩余能量根本没入账');
tc.verifyGreaterThan(esc1, 0, '10 um 壁下逸出仍为 0: 壁厚覆盖项没进输运');
tc.verifyGreaterThan(esc2, esc1 * 1.5, sprintf('密度降到 1/4 后逸出没有显著增加 (%.4g -> %.4g): 壁密度覆盖项没进输运', esc1, esc2));
end

function test_wrong_override_key_is_rejected(tc)
[cfg, R, tables] = demoSetup();
g = R.geom;
rs = RandStream('Threefry', 'Seed', 5);
run1 = @() tepc.transport.AnalyticAdapter(cfg, g, tables, rs, 5, 1, ...
    struct('tNext', 0), struct('rho_wall_g_cm33', 1.124));
tc.verifyError(run1, 'tepc:transport:UnknownXopt');
% 壁厚走 geom 一条路, 覆盖项里再给一次会造出两个真相 -> 白名单外, 必须拒
run2 = @() tepc.transport.AnalyticAdapter(cfg, g, tables, rs, 5, 1, ...
    struct('tNext', 0), struct('wallThickness_m', 1e-5));
tc.verifyError(run2, 'tepc:transport:UnknownXopt');
run3 = @() tepc.transport.AnalyticAdapter(cfg, g, tables, rs, 5, 1, ...
    struct('tNext', 0), struct('rho_wall_g_cm3', 0));
tc.verifyError(run3, 'tepc:transport:BadXoptValue');
% straggle 是白名单里的第二项, 但它的合法形状与壁密度**不同** (逻辑标量 vs 正数值)。
% 通用判据 "正的有限标量" 会把 false 拒掉而把 true 当 1 收下 —— 那就成了一个能开不能关
% 的半死旋钮, 而探针的配对腿要的正是"关"这一边。四条各挡一种错法。
% "不许抛错"不能用 verifyError(..., 'NO_ERROR') —— 那是把 NO_ERROR 当成期望的异常标识符,
% 实测报"预期的异常: NO_ERROR"然后判红; 直接调用并把返回值当断言对象才是"不抛错"的写法。
runOk = @() tepc.transport.AnalyticAdapter(cfg, g, tables, rs, 5, 1, ...
    struct('tNext', 0), struct('straggle', false));
evOk = runOk();
tc.verifyEqual(evOk.n, 5, 'straggle=false 这条腿没产出 5 个事件: 覆盖项被吞了');
runChar = @() tepc.transport.AnalyticAdapter(cfg, g, tables, rs, 5, 1, ...
    struct('tNext', 0), struct('straggle', 'false'));
tc.verifyError(runChar, 'tepc:transport:BadXoptValue');   % logical('false')=1, 收下即反义
runNum = @() tepc.transport.AnalyticAdapter(cfg, g, tables, rs, 5, 1, ...
    struct('tNext', 0), struct('straggle', 0.5));
tc.verifyError(runNum, 'tepc:transport:BadXoptValue');    % 数值不算布尔
runVec = @() tepc.transport.AnalyticAdapter(cfg, g, tables, rs, 5, 1, ...
    struct('tNext', 0), struct('straggle', [true false]));
tc.verifyError(runVec, 'tepc:transport:BadXoptValue');    % 向量在 if 里恒假, 看着像生效
end

%% ==================== 3. 名义几何下: 壁参数对发布量严格零响应 ====================

function test_wall_density_is_bitwise_inert_at_ship_thickness(tc)
[cfg, R, tables] = demoSetup();
rhoN = tepc.transport.wallDensity(struct());
nEv = 600;
a = runAt(cfg, R, tables, nEv, NaN, NaN);
b = runAt(cfg, R, tables, nEv, NaN, 3*rhoN);
c = runAt(cfg, R, tables, nEv, NaN, 0.3*rhoN);
Sa = tepc.analysis.buildSpectrum(a.ev.EdepGas_keV, R.lbar_tissue_um, a.ev.weight, R.edges);
Sb = tepc.analysis.buildSpectrum(b.ev.EdepGas_keV, R.lbar_tissue_um, b.ev.weight, R.edges);
Sc = tepc.analysis.buildSpectrum(c.ev.EdepGas_keV, R.lbar_tissue_um, c.ev.weight, R.edges);
tc.verifyEqual(b.ev.EdepGas_keV, a.ev.EdepGas_keV, 'AbsTol', 0, '壁密度 x3 改变了气腔沉积列');
tc.verifyEqual(c.ev.EdepGas_keV, a.ev.EdepGas_keV, 'AbsTol', 0, '壁密度降到 0.3x 改变了气腔沉积列');
tc.verifyEqual(Sb.yF_exact, Sa.yF_exact, 'AbsTol', 0, 'y_F 随壁密度变了: 与厚壁极限结论不符');
tc.verifyEqual(Sc.yF_exact, Sa.yF_exact, 'AbsTol', 0, 'y_F 随壁密度变了');
tc.verifyEqual(sum(a.ev.Eescape_keV), 0, 'AbsTol', 0, ...
    '发货壁厚下出现逸出: 本节"逃逸通道未打开"的前提不再成立, 壁密度的预算项需要重新评估');
tc.verifyEqual(sum(b.ev.Eescape_keV), 0, 'AbsTol', 0, 'x3 密度下逸出非零');
tc.verifyGreaterThan(sum(a.ev.EdepWall_keV), 0, '壁内沉积为 0: 壁根本没进账本');
end

function test_escape_depends_only_on_areal_density(tc)
% 面密度 rho*t 相同 => 逸出必须相同. 这条同时证明两件事: 覆盖项真的进了 wallEscape,
% 以及"壁厚不确定度"与"壁密度不确定度"在模型里是**同一个方向** —— 分成两个 LHS 变量
% 会把一个物理量当成两个独立分量平方和开方, 系统性低估其影响.
[cfg, R, tables] = demoSetup();
rhoN = tepc.transport.wallDensity(struct());
nEv = 400;
% 壁厚取 5 um 而不是 30 um: 按本仓库阻止本领表实算的 CSDA 射程 (A-150, rho=1.124)
% 为 1 MeV 质子 22.8 um、200 keV 质子 2.6 um、200 keV 碳反冲 1.4 um，
% 30 um 壁会把反冲核全部停住 => 逸出恒为 0，下面"阶梯前提"就失效了。
% 5 um 仍显著低于最高能反冲质的射程，逸出非零且对 rho*t 敏感，性质可观测。
tA = 5.0e-6;
B = runAt(cfg, R, tables, nEv, tA/0.3, 0.3*rhoN);
A = runAt(cfg, R, tables, nEv, tA, rhoN);
ea = sum(A.ev.Eescape_keV);
eb = sum(B.ev.Eescape_keV);
tc.verifyGreaterThan(ea, 0, '30 um 壁下逸出为 0: 阶梯前提失效');
tc.verifyEqual(eb, ea, 'RelTol', 1e-9, sprintf('同面密度给出不同逸出 (%.6g vs %.6g): 壁参数不是只经 rho*t 进入模型', ea, eb));
end

%% ==================== 3. 档位那一行必须可指（统计功效损失登记） ====================

function test_budget_row_records_depth_tier_power_cost(tc)
% 预算表里必须有一行说清"选粗档省墙钟时放弃了哪个统计量"，并把档位 id 一起点名。
% 这一行还是 config/defaults/demo_only.json 那句"正式不确定度评定应按
% docs/uncertainty_budget.md 取 nSamples>=500"的落点：文档里原本没有 nSamples 这句话，
% 引用是悬空的（实测 grep 全文零命中），所以先补文档再补锁，而不是把那句引用删掉。
% 判据一律 ASCII：本用例用 fileread 读这份 UTF-8 markdown，本机码页下中文常量与读来的
% 内容永不相等，用中文判据会让"含某词"的断言恒假或恒真，取决于哪一侧被重新解码。
rows = tableRows(budgetText());
T = tepc.config.uncertaintyDepthTiers();
% ids 是列向 (cellstr/string 都按列给), 后面要与行向的锚词表拼接, 所以在这里统一成 1×N:
% 上一版留它成列 [1x3, 3x1] 直接抛"维度不一致", 用例是**报错**而不是判红 (fail+incomplete 同现
% 就是这个形状), 容易被误读成"判据抓到了问题"。
ids = string(T.ids);
ids = ids(:).';
allHit = find(depthRowHit(rows, ids));
tc.verifyGreaterThan(numel(allHit), 0, sprintf( ...
    '预算表里没有同时含 nSamples / 1/sqrt / 500 并点名全部档位 (%s) 的行: 为省墙钟接受的统计功效损失没登记, 而 demo_only.json 对本文件的引用会悬空', ...
    strjoin(ids, '/')));
if isempty(allHit)
    return
end
% 特异性判据的形态在本轮被审查纠正过一次, 记在这里防止改回去: 原先只抹**第一个**命中行, 而
% nSamples 全文唯一, 抹完自然无命中 => 那条判据恒绿, 什么也没判。现在是两种能真的失败的方向:
%   (a) 抹掉**全部**命中行后必须一条都不命中 (挡住"锚词在别处也凑得齐");
%   (b) 逐锚留一: 每抽掉一个锚 (含每个档位 id) 都必须让判据转假 (挡住"某个锚是装饰, 从不承重")。
rest = rows;
rest(allHit) = [];
tc.verifyFalse(any(depthRowHit(rest, ids)), ...
    '抹掉全部命中行后仍有行满足四元合取: 锚词在表里别处也凑得齐, 这条锁不特异');
anchors = ["nSamples", "1/sqrt", "500"];
for a = 1:numel(anchors)
    anc = string(anchors(a));
    part = rows;
    for q = 1:numel(allHit)
        mod = strrep(rows(allHit(q)), anc, "");
        % 先自证"这一步真的把锚词抽掉了": 上一版只判抽完之后的结果, 于是"抽词没生效"会伪装成
        % "判据抓到了装饰锚", 排查要绕一大圈 (本轮实测就是这样)。抽词失败本身必须是红。
        tc.verifyFalse(contains(mod, anc), ...
            sprintf('锚词「%s」没能从命中行里抽掉 (strrep 后仍含), 下面的留一判据无从解释', char(anc)));
        part(allHit(q)) = mod;
    end
    tc.verifyFalse(any(depthRowHit(part, ids)), ...
        sprintf('抽掉锚词「%s」后判据仍然成立: 这个锚从不承重, 是装饰', char(anc)));
end
% 档位 id 不用"抽词"来证承重, 而直接证**整表唯一性**: 每个 id 在预算表里必须只属于这一行。
% 换这个写法的原因是被实测逼出来的 —— 抽掉 id 后合取仍成立, 而同一-形式的 ASCII 锚全部通过,
% 说明 id 的承重要用"它在表里出现几行"来判, 而不是用"抹掉它还能不能凑齐"来判 (后者在这里
% 会被表里别处的 nSamples/500 组合满足, 判出来的不是 id 的问题)。
for a = 1:numel(ids)
    inRows = zeros(1, numel(rows));
    for i = 1:numel(rows)
        inRows(i) = contains(rows(i), ids(a));
    end
    tc.verifyEqual(sum(inRows), 1, sprintf( ...
        '档位 id「%s」在预算表里出现在 %d 行 (应为 1): 它没能把这一行与别的行区分开, 点名等于没点名', ...
        char(ids(a)), sum(inRows)));
end
% "建议 nSamples>=500" 必须比档位表里任何一档真的设过的样本数大, 否则这句下限没有含义
% (500 这个数本身也不特异: 表里别处有 N=5000, 所以它只能靠合取与留一判据承重, 不能单独引用)。
ns = [];
for k = 1:numel(T.tiers)
    kn = T.tiers(k).knobs;
    if ~isstruct(kn) || numel(kn) == 0
        continue
    end
    for q = 1:numel(kn)
        if contains(string(kn(q).path), "nSamples")
            ns(end+1) = double(kn(q).value); %#ok<AGROW>
        end
    end
end
tc.verifyGreaterThan(numel(ns), 0, '档位表里没有任何 nSamples 旋钮: 预算行那句下限没有可比的量');
if ~isempty(ns)
    tc.verifyGreaterThan(500, max(ns), sprintf( ...
        '预算行写的建议下限 500 不高于档位表里最大的 nSamples (%d): "正式评定取 >=500"与档位定义矛盾', ...
        max(ns)));
end
end

function tf = depthRowHit(rows, ids)
% 命中判据独立成 helper: 上一条用例要对"原表"和"抹掉锚词的同表"各判一次。
% helper 带输出参数, functiontests 不会把它当用例收集。
tf = false(1, numel(rows));
for i = 1:numel(rows)
    r = rows(i);
    tf(i) = contains(r, "nSamples") && contains(r, "1/sqrt") && ...
        contains(r, "500") && all(contains(r, ids));
end
end

%% ==================== 4. README 的对外计数不得与清单分叉 ====================

function test_readme_quoted_variable_count_matches_the_code(tc)
% README 曾写"六个不确定度源全部实测可传播", 而 mappedVariables() 是 9 条 —— 表低估代码,
% 读者据此会以为还有三项没做。计数现在写成 ASCII 数字, 本用例把它与清单直接对账。
f = fullfile(tepc.io.projectRoot(), 'README.md');
tc.verifyTrue(isfile(f), '缺 README.md: 对外计数无从核对');
txt = string(fileread(f));
tok = regexp(txt, '(\d+)\s*个不确定度源', 'tokens');
tc.verifyGreaterThan(numel(tok), 0, ...
    'README 里找不到"N 个不确定度源"这句话: 要么被删要么改了写法, 本锁会静默失效');
if isempty(tok), return; end
quoted = str2double(string(tok{1}{1}));
n = numel(tepc.uq.mappedVariables());
tc.verifyEqual(quoted, n, sprintf('README 声称 %d 个不确定度源可传播, 代码清单实为 %d 条: 对外数字与实现分叉', quoted, n));
end
