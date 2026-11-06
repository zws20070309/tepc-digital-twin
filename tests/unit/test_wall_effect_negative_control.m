function tests = test_wall_effect_negative_control
%TEST_WALL_EFFECT_NEGATIVE_CONTROL 壁厚扫描: 壁若没进输运, 这里必须红而不是静默通过。
%
% 对照形式: 同 seed、同批事件, 只改 geom.wallThickness_m 一个数, 然后把各物理量拆开看
% 哪些必须动、哪些必须不动。
%   必须动: 出腔剩余能量在 壁内沉积 / 逸出 两侧的分配, ESCAPE 标志数, 逃逸份额。
%   必须不动: 气腔沉积逐事件 (以及由它构成的发布谱 f(y)、零沉积计数) 与三项之和。
% 若整条壁厚阶梯上所有量都恒定, 那就是"壁厚没进输运"的直接证据, 本文件判红。
%
% 为什么不去要求 f(y) 随壁厚变化: 本链的 y = 气腔授予能 / 位点平均弦长, 气腔内的 CSDA
% 步进在出腔时刻就结束了, 壁厚只决定"出腔后那份剩余能量算壁的还是算逸出的"。所以发布谱
% 与壁厚无关是这条链的结构事实, 不是壁没起作用; 壁的可观测量在账本的另一侧。把"谱必须
% 变"写成判据, 只会得到一个永远红的用例或用假量凑绿的用例, 因此这里同时锁两侧: 该变的
% 必须按预期方向变够, 不该变的必须逐位不变。
%
% 阶梯取点: 1 um 起每次翻倍到 128 um, 末端再接发货壁厚 (3 mm), 第 1 腿取 t=0 作参考。
% 1 um 处壁近乎透明 (逸出份额过半), 发货壁厚处出腔剩余能量全部停在壁内 (逸出为 0, 由第
% 一条用例核对这一前提), 于是"过渡必须落在阶梯内部"是可失败判据而不是假设。事件数取 100:
% 判据是逐事件对照而非统计对照, 加大样本只会线性拉长阶梯的耗时。
tests = functiontests(localfunctions);
end

%% ==================== 夹具 (名字不得以 test 开头, 首参不得叫 tc) ====================

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function R = baseResolved()
persistent cached
if ~isempty(cached)
    R = cached;
    return
end
R = tepc.config.resolve(demoCfg());
cached = R;
end

function E = runAdapter(cfg, geom, nEv)
% 一批事件。抽样锚在 cfg.provenance.seed 的每-事件子流上, 与 geom 的壁厚无关, 所以不同
% 壁厚腿之间唯一的差别只能来自壁厚本身, 不是统计涨落。
tables = struct('proton', tepc.transport.stoppingPower(cfg, "proton"), ...
    'electron', tepc.transport.stoppingPower(cfg, "electron"), ...
    'heavy_C', tepc.transport.stoppingPower(cfg, "heavy_C"), ...
    'heavy_O', tepc.transport.stoppingPower(cfg, "heavy_O"));
rs = RandStream('Threefry', 'Seed', cfg.provenance.seed);
[E, ~] = tepc.transport.AnalyticAdapter(cfg, geom, tables, rs, nEv, 1, struct('tNext', 0));
end

function legs = wallLegs()
% 一次算好全部壁厚腿 (persistent 缓存供本文件各用例复用): 第 1 腿是 t=0 参考腿。
persistent cached
if ~isempty(cached)
    legs = cached;
    return
end
cfg = demoCfg();
R = baseResolved();
nEv = 100;
g0 = R.geom;
g0.wallThickness_m = 0;
legs = struct('t', 0, 'L', runAdapter(cfg, g0, nEv));
lad = [1e-6*2.^(0:7), R.geom.wallThickness_m];       % 1..128 um, 末端接发货壁厚
for i = 1:numel(lad)
    gi = R.geom;
    gi.wallThickness_m = lad(i);
    legs(end+1) = struct('t', lad(i), 'L', runAdapter(cfg, gi, nEv));
end
cached = legs;
end

function s = colsOf(L)
% 账本列 + ESCAPE 标志, 统一成列向量。
F = tepc.domain.Flags();
s.gas = L.ev.EdepGas_keV(:);
s.wall = L.ev.EdepWall_keV(:);
s.esc = L.ev.Eescape_keV(:);
s.sec = L.ev.Esecondary_keV(:);
s.escFlag = bitand(L.ev.flags, F.ESCAPE) > 0;
s.wallFlag = bitand(L.ev.flags, F.WALL_LOSS) > 0;
end

function S = spectrumOf(L)
R = baseResolved();
S = tepc.analysis.buildSpectrum(L.ev.EdepGas_keV, R.lbar_tissue_um, L.ev.weight, R.edges);
end

%% ==================== 1. 前提核对 ====================

function test_nominal_wall_absorbs_everything_that_leaves_the_gas(tc)
L = wallLegs();
c = colsOf(L(end).L);
cfgShip = demoCfg();
tShip = cfgShip.geometry.wallThickness_mm*1e-3;     % 发货壁厚 [m]
tc.verifyEqual(L(end).t, tShip, 'AbsTol', 0, ...
    '阶梯末端必须是发货壁厚, 后面的 逸出为零 才有参照');
pos = c.sec > 0;
tc.verifyGreaterThan(nnz(pos), 0, '没有任何带次级带电粒子的事件, 本文件的判据无从谈起');
if ~any(pos), return; end
% 三列与 Esecondary_keV 同为 keV (AnalyticAdapter 已按 E_MeV*1e3 落账, runGate 第 3 项
% 也是直接相加比较), 所以闭合式里没有额外的 1e3 因子。
resid = abs(c.gas + c.wall + c.esc - c.sec);
tc.verifyLessThan(max(resid(pos)), 1e-9*max(c.sec(pos)) + 1e-9, ...
    '逐事件账本必须闭合 (Esecondary_keV = 气 + 壁 + 逸出)');
tc.verifyGreaterThan(sum(c.wall), 0, ...
    '发货壁厚下壁内沉积为 0: 壁根本没进输运, 壁厚扫描自然扫不出东西');
tc.verifyEqual(sum(c.esc), 0, 'AbsTol', 0, ...
    '发货壁厚是厚壁极限: 出腔剩余能量应全部停在壁内, 否则阶梯末端的参照失效');
tc.verifyEqual(nnz(c.escFlag), 0, 'AbsTol', 0, '没有逸出能量就不应有 ESCAPE 标志');
tc.verifyGreaterThan(nnz(c.wallFlag), 0, '在壁内终止的事件必须带 WALL_LOSS 标志');
end

%% ==================== 2. 摘掉壁 ====================

function test_removing_the_wall_moves_all_residual_energy_into_escape(tc)
L = wallLegs();
a = colsOf(L(1).L);                                  % t = 0 (壁摘掉)
b = colsOf(L(end).L);                                % t = 发货壁厚
tc.verifyEqual(a.wall, zeros(size(a.wall)), 'AbsTol', 0, ...
    '壁厚取 0 后壁内沉积必须逐事件精确归零');
tc.verifyEqual(a.gas, b.gas, 'AbsTol', 0, ...
    '控制变量: 气腔沉积与壁厚无关, 差别只允许出现在壁与逸出的分配上');
tc.verifyEqual(a.esc, b.wall + b.esc, 'RelTol', 1e-12, ...
    't=0 的逸出必须逐事件等于发货壁厚下 壁内沉积 + 逸出 之和');
tc.verifyGreaterThan(nnz(a.esc > 0), 0, '剩余能量必须真的挂在逸出列上');
tc.verifyGreaterThan(nnz(a.escFlag), nnz(b.escFlag), '摘掉壁后 ESCAPE 标志数必须增加');
end

%% ==================== 3. 阶梯与预期方向 ====================

function test_thickness_ladder_resolves_a_real_transition(tc)
L = wallLegs();
resTot = sum(colsOf(L(1).L).esc);                     % t=0: 全部剩余能量都算逸出
tc.verifyGreaterThan(resTot, 0, 't=0 参考腿的逸出总量必须为正, 否则相对变化率无定义');
if ~(resTot > 0), return; end
escSum = zeros(numel(L), 1);
wallSum = zeros(numel(L), 1);
for i = 1:numel(L)
    ci = colsOf(L(i).L);
    escSum(i) = sum(ci.esc);
    wallSum(i) = sum(ci.wall);
end
frac = escSum/resTot;
tc.verifyGreaterThan(frac(2), 0.5, ...
    sprintf('阶梯第一个点 (1 um) 就吸走了一半以上剩余能量 (逸出份额 %.3f): 阶梯没有从近透明一侧起步', ...
    frac(2)));
tc.verifyEqual(frac(end), 0, 'AbsTol', 1e-12, '发货壁厚处逸出份额必须为 0');
% 预期方向: 壁厚增加 => 逸出单调下降、壁内沉积单调上升, 两者之和恒等于出腔剩余能量。
tc.verifyTrue(all(diff(frac) <= 1e-12), ...
    sprintf('逸出份额必须随壁厚单调不增 (实得 %s)', mat2str(frac.')));
relSpan = frac(2) - frac(end);
tc.verifyGreaterThan(relSpan, 0.5, ...
    sprintf('从 1 um 到发货壁厚的逸出份额只挪动了 %.3g: 壁厚对输运没有作用', relSpan));
tc.verifyEqual(wallSum + escSum, repmat(resTot, size(wallSum)), 'RelTol', 1e-9, ...
    '壁与逸出之和必须恒等于出腔剩余能量: 壁厚只是把同一份能量挪来挪去');
% 中点处一次翻倍的效应: 方向必须明确 (逸出降 / 壁沉积升), 且落在阶梯可分辨的位置。
k50 = find(frac > 0.5, 1, 'last');
tc.verifyTrue(~isempty(k50) && k50 < numel(L), ...
    '找不到 0.5 份额的交叉位置: 要么全程透明要么全程吸收, 阶梯不覆盖过渡');
if ~isempty(k50) && k50 < numel(L)
    tc.verifyLessThan(escSum(k50+1), escSum(k50), '壁厚翻倍必须降低逸出 (方向)');
    tc.verifyGreaterThan(wallSum(k50+1), wallSum(k50), '壁厚翻倍必须抬高壁内沉积 (方向)');
    tc.verifyGreaterThan(frac(k50) - frac(k50+1), 0, '翻倍处的份额必须真的在移动');
end
end

function test_per_event_escape_is_monotone_in_thickness(tc)
% 逐事件而不是只看总量: wallEscape 用的是 v = Eres*(1 - t/Rm), 对 t 单调不增, 所以任何
% 一个事件的逸出都不允许随壁厚上升。总量单调而逐事件不单调, 意味着两批事件被换过了。
L = wallLegs();
M = zeros(numel(L), numel(L(1).L.ev.Eescape_keV));
W = zeros(size(M));
for i = 1:numel(L)
    ci = colsOf(L(i).L);
    M(i, :) = ci.esc.';
    W(i, :) = ci.wall.';
end
% 矩阵是"腿 x 事件": 逐事件单调性 = 沿第 1 维 (壁厚) 差分, 沿第 2 维差分会变成
% "同一腿内相邻两个事件"的比较, 那与壁厚无关 (实测: 沿第 2 维差分给出 115 处伪违例)。
dE = diff(M, 1, 1);
dW = diff(W, 1, 1);
tc.verifyTrue(all(dE(:) <= 1e-12), ...
    sprintf('存在随壁厚上升的逸出事件 (最大正增量 %.3g keV)', max([0; dE(:)])));
tc.verifyTrue(all(dW(:) >= -1e-12), ...
    sprintf('存在随壁厚下降的壁内沉积事件 (最大负增量 %.3g keV)', min([0; dW(:)])));
end

%% ==================== 4. 不该动的东西一格都不能动 ====================

function test_wall_knob_moves_nothing_outside_the_wall_escape_split(tc)
L = wallLegs();
ref = colsOf(L(2).L);                                 % 阶梯第一个点 (1 um) 作参照
S0 = spectrumOf(L(2).L);
for i = 1:numel(L)
    ci = colsOf(L(i).L);
    tc.verifyEqual(ci.gas, ref.gas, 'AbsTol', 0, ...
        sprintf('壁厚 %.3g m 改变了气腔沉积列', L(i).t));
    Si = spectrumOf(L(i).L);
    tc.verifyEqual(Si.yF_exact, S0.yF_exact, 'RelTol', 1e-12);
    tc.verifyEqual(Si.yD_exact, S0.yD_exact, 'RelTol', 1e-12);
    tc.verifyEqual(Si.zeroDepCount, S0.zeroDepCount, 'AbsTol', 0);
    tc.verifyEqual(Si.nEff, S0.nEff, 'AbsTol', 0);
    tc.verifyEqual(numel(ci.wall), numel(ref.wall), 'AbsTol', 0);
end
% 同一批事件、同一个发布谱, 但壁那一列必须逐事件地不同, 否则"分配"二字是空的。
thin = colsOf(L(2).L).wall;
thick = colsOf(L(end).L).wall;
tc.verifyGreaterThan(nnz(thin ~= thick)/numel(thin), 0.1, ...
    '绝大多数事件的壁内沉积在两个壁厚之间纹丝不动: 壁没有进入逐事件输运');
end
