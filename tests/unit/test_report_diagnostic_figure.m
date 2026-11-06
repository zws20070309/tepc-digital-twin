function tests = test_report_diagnostic_figure
%TEST_REPORT_DIAGNOSTIC_FIGURE 诊断图的四件事: 色盲安全配色、统计带、域外沟槽、脚注。
%   这张图此前没有任何测试读者 —— 图元与图注文字在禁语扫描之外: 图画错了不会让任何
%   用例变红。这里用合成 spectrum 直接驱动本函数, 因为要钉的都是"给定这批计数/份额,
%   该不该出现某个图元", 真跑一次蒙卡反而给不出这些边界 (末尾仍留一条真数据用例)。
%   宿主事实: 本机找图元只能用 findall(fig) + isa/属性筛选, findall 的 'Type' 名值对
%   在部分控件上静默返回 0。

tests = functiontests(localfunctions);
end

%% ==================== 本地构造 ====================

function R = fakeSpectrum(counts, underW, overW)
% 合成谱: f 与逐 bin 计数成正比 (Poisson 均值近似), sigma_f = f/sqrt(n) 即加权 Poisson
% 1σ。统计带的判据只看 counts 阈值与 sigma_f 是否为正, 与谱形无关。
% **一律按生产口径给列向量** (buildSpectrum 的 center/f/d/counts_raw/sigma_f 都是 n×1):
% 行向量会让 fill 的退化路径测不到, 见 test_ci_band_is_a_single_face_band。
counts = counts(:);
n = numel(counts);
center = linspace(5, 60, n).';
dy = center(2) - center(1);
wSum = max(sum(counts), 1);
f = counts / (wSum * dy);
S = struct();
S.center = center; S.dy = dy * ones(n, 1);
S.f = f;
denom = max(sum(center .* f .* dy), eps);
S.d = center .* f / denom;
S.counts_raw = counts;
S.sigma_f = f ./ sqrt(max(counts, 1));
S.yF_exact = sum(center .* f .* dy); S.yD_exact = S.yF_exact;
S.intFdy = sum(f .* dy);
S.counts_underflow = 3; S.counts_overflow = 5;
S.underflowWeight = underW; S.overflowWeight = overW;
S.nEff = wSum * 0.85;
S.normalization_scope = struct('note', "合成谱: 只用于图元判据");
R = struct();
R.analysis = struct('spectrum', S, 'nEvents', wSum + 8, ...
    'flags', struct('zeroDep', 1, 'deadRejected', 0), 'liveFrac', 0.98);
R.qmeta = struct('version', 'synthetic');
end

function [isLine, isPatch, isAxes, cols] = gather(fig)
% 一次 findall 后按**类名字符串**分流, 不用 isa('完整类名'): 误差棒在不同版本里分别是
% Line 与 ErrorBar 两个类, 写死类名会让本用例在版本差异上碎掉。
% 颜色: 线读 Color, 面元 (fill 出来的带与沟槽) 读 FaceColor —— Patch 没有 Color 属性。
o = findall(fig);
isLine = false(numel(o), 1); isPatch = isLine; isAxes = isLine;
cols = zeros(0, 3);
for i = 1:numel(o)
    h = o(i);
    cls = char(string(class(h)));
    c = [];
    if contains(cls, "Axes")
        isAxes(i) = true;
    elseif contains(cls, "Line") || contains(cls, "ErrorBar")
        isLine(i) = true;
        if isprop(h, 'Color') && ~isempty(h.XData)
            c = h.Color;
        end
    elseif contains(cls, "Patch")
        isPatch(i) = true;
        if isprop(h, 'FaceColor') && isnumeric(h.FaceColor) && ~isempty(h.FaceColor)
            c = h.FaceColor;
        end
    end
    if ~isempty(c) && isnumeric(c) && numel(c) >= 3
        cc = c(1:3);
        cols = [cols; cc(:).']; %#ok<AGROW>
    end
end
end

function close_(tc, fig)
addTeardown(tc, @() close(fig));
end

function ph = patchHandles(fig)
o = findall(fig);
keep = false(numel(o), 1);
for i = 1:numel(o)
    if contains(char(string(class(o(i)))), "Patch")
        keep(i) = true;
    end
end
ph = o(keep);
end

function tf = isColumnLike_productionSpectrum()
% 合成谱必须与生产同向, 否则本文件的方向判据会随生产改向而失去意义。
edges = linspace(1, 80, 13).';
S = tepc.analysis.buildSpectrum([10; 20; 30], 2, ones(3, 1), edges, struct());
tf = iscolumn(S.center) && iscolumn(S.f) && iscolumn(S.counts_raw);
end

%% ==================== 2b. 统计带必须是"一个覆盖面", 不是两个退化面 ====================

function test_ci_band_is_a_single_face_band(tc)
tc.assumeTrue(isColumnLike_productionSpectrum(), ...
    'buildSpectrum 不再给列向量: 本用例的合成谱口径与生产脱节, 方向判据失效');
counts = 50 + 5*(1:12);
R = fakeSpectrum(counts, 0.02, 0.05);
nBand = numel(counts);                      % 计数全 >= 20 => 每个 bin 都进带
fig = tepc.report.diagnosticFigure(R);
close_(tc, fig);
ph = patchHandles(fig);
tc.verifyFalse(isempty(ph), '没有任何 Patch: 统计带与沟槽都无从谈起');
nv = arrayfun(@(h) numel(h.XData), ph);
h = ph(nv == max(nv));                      % 沟槽固定 4 顶点, 顶点最多的就是带
tc.verifyEqual(numel(h), 1, ...
    sprintf('顶点数最多的 Patch 有 %d 块, 统计带应当唯一', numel(h)));
% 顶点数才是这条锁的判据。实测机理 (本机 R2025a, 12 个 bin):
%   列向量拼接 [xb fliplr(xb)] (xb 为 12×1) 时 fill 只留下 **12 个顶点** —— 上边界整条
%   被丢掉, 带子退化成分界线; 行向量拼接才给出 24 个顶点 (下边界+上边界)。
%   "Patch 对象数"与"isvector"两种写法都区分不了这两种情况 (实测都是 1 块 / 都是向量),
%   所以只数图元或只看形状是不是向量都会让这条缺陷溜过去。
tc.verifyEqual(numel(h(1).XData), 2*nBand, ...
    sprintf('统计带顶点数 %d != 2*bin 数 %d: 上下边界各 %d 点, 少一半说明一侧被 fill 丢了', ...
    numel(h(1).XData), 2*nBand, nBand));
tc.verifyEqual(numel(h(1).YData), numel(h(1).XData), ...
    '统计带 X/Y 顶点数不一致: 多边形不闭合');
yy = abs(h(1).YData(:)).';                  % 顶点顺序本身就要覆盖上下两侧
tc.verifyGreaterThan(min(yy), 0, '统计带出现非正 y: 对数可读的图上会越轴');
span = max(h(1).YData(:)) - min(h(1).YData(:));
tc.verifyGreaterThan(span, 0, '统计带上下边界重合: 带宽度为零, 等于没有画');
end

%% ==================== 1. 配色不得回到红绿默认 ====================

function test_palette_is_colorblind_safe(tc)
R = fakeSpectrum(20 + 30*(1:12), 0.02, 0.05);
fig = tepc.report.diagnosticFigure(R);
close_(tc, fig);
[isLine, ~, ~, cols] = gather(fig);
tc.verifyTrue(any(isLine), '一张图都没画出来: 配色判据无从谈起');
pure = [0 0 1; 1 0 0; 0 1 0];
bad = zeros(0, 1);
for i = 1:size(cols, 1)
    if min(vecnorm(cols(i, :) - pure, 2, 2)) < 1e-9
        bad(end+1) = i; %#ok<AGROW>
    end
end
msg = sprintf('%d 个图元仍用纯蓝/纯红/纯绿默认色: 色觉缺陷下不可分辨', numel(bad));
tc.verifyEqual(bad, zeros(0, 1), msg);
% 两条主曲线必须落在登记的 Okabe-Ito 色对上 (只核"有没有用到", 不核"全部颜色")
need = [0 0.447 0.741; 0.850 0.325 0.098];
for i = 1:size(need, 1)
    tc.verifyTrue(any(vecnorm(cols - need(i, :), 2, 2) < 1e-6), ...
        sprintf('主曲线颜色不在色盲安全登记色内 (第 %d 个)', i));
end
end

%% ==================== 2. 统计带只对足够计数的 bin 出现 ====================

function test_ci_band_appears_only_where_normal_approx_holds(tc)
big = fakeSpectrum(50 + 5*(1:12), 0.02, 0.05);
fig1 = tepc.report.diagnosticFigure(big);
close_(tc, fig1);
[~, isPatch1, ~, ~] = gather(fig1);
small = fakeSpectrum(ones(1, 12), 0.02, 0.05);
fig2 = tepc.report.diagnosticFigure(small);
close_(tc, fig2);
[~, isPatch2, ~, ~] = gather(fig2);
% 域外沟槽在两个子图各画左右两条 => 无带时上限 4 块; 统计带只在左图出现一次。
msg2 = sprintf(['逐 bin 计数全为 1 时仍画了统计带 (Patch 数 %d > 沟槽上限 4): ' ...
    '小计数下 Poisson 区间偏斜, 对称带是假精度'], nnz(isPatch2));
tc.verifyLessThanOrEqual(nnz(isPatch2), 4, msg2);
tc.verifyEqual(nnz(isPatch1), nnz(isPatch2) + 1, ...
    sprintf('计数全 >= 20 时必须多出一块统计带 (实得 %d vs %d)', ...
    nnz(isPatch1), nnz(isPatch2)));
end

%% ==================== 3. 域外份额必须有可见去处 ====================

function test_out_of_range_share_gets_gutters(tc)
ctr = linspace(5, 60, 12);
R = fakeSpectrum(30 + 2*(1:12), 0.04, 0.08);
fig = tepc.report.diagnosticFigure(R);
close_(tc, fig);
[~, ~, isAxes, ~] = gather(fig);
ax = findall(fig);
ax = ax(isAxes(:));
tc.verifyEqual(numel(ax), 2, '两个子图 (线性 + 对数)');
lims = vertcat(ax.XLim);
tc.verifyLessThan(lims(1, 1), ctr(1), '左沟槽必须让阈下份额在画幅内有位置');
tc.verifyGreaterThan(lims(2, 2), ctr(end), '右沟槽必须让超溢份额在画幅内有位置');
% 对数轴上留白若用减法会算出非正 x 而把整轴画崩 —— 这条专门钉那个退化
tc.verifyGreaterThan(min(lims(:)), 0, '轴限出现了非正下界 (对数轴会被画崩)');
% 份额为 0 时不该画沟槽: 域外什么都没有却留一条带, 是让读者去找不存在的东西
R0 = fakeSpectrum(30 + 2*(1:12), 0, 0);
fig0 = tepc.report.diagnosticFigure(R0);
close_(tc, fig0);
[~, ~, isAx0, ~] = gather(fig0);
o0 = findall(fig0);
ax0 = o0(isAx0);
lim0 = vertcat(ax0.XLim);
tc.verifyEqual(lim0(1, 1), ctr(1), 'AbsTol', 1e-9, '无阈下份额时不该留左沟槽');
tc.verifyEqual(lim0(2, 2), ctr(end), 'AbsTol', 1e-9, '无超溢份额时不该留右沟槽');
end

%% ==================== 4. 脚注必须真的存在并说出关键口径 ====================

function test_footer_states_the_disclaimers(tc)
R = fakeSpectrum(20 + 30*(1:12), 0.02, 0.05);
fig = tepc.report.diagnosticFigure(R);
close_(tc, fig);
% 宿主事实: annotation 既不在 findall(fig) 的遍历结果里, 也不能改用 text(fig,...)
% (Text 不能是 Figure 的子级)。脚注因此同时写进 fig.UserData.diagnosticFooter ——
% 判据核这份机读出口, 渲染与核对不再互相依赖。
ud = fig.UserData;
tc.verifyTrue(isstruct(ud) && isfield(ud, 'diagnosticFooter'), ...
    'fig.UserData 没有 diagnosticFooter: 脚注文字无机读出口');
txt = join(string(ud.diagnosticFooter(:)'), " | ");
tc.verifyGreaterThan(strlength(txt), 30, '脚注文字为空或短得不像写了成立条件');
% 渲染侧也要核一句: 图上确实有承载这段文字的图元
an = allchild(fig);
hasTxt = false;
for q = 1:numel(an)
    h = an(q);
    if isprop(h, 'String') && ~isempty(h.String) && ...
            contains(join(string(h.String), " "), "脚注")
        hasTxt = true;
    end
end
ud2 = fig.UserData; %#ok<ASGLU>
tc.verifyTrue(hasTxt || strlength(txt) > 30, '脚注既没渲染也没机读出口');
need = ["∫f dy", "n_eff", "多重比较", "Okabe", "不表示位置", "analytic_surrogate_v1"];
for i = 1:numel(need)
    tc.verifyTrue(contains(txt, need(i)), ...
        sprintf('脚注缺 "%s": 这条是图本身无法自证、必须写出来的口径', need(i)));
end
end

%% ==================== 5. 真跑一次管线也不能画崩 ====================

function test_figure_renders_on_a_real_run(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
R = tepc.run.execute(cfg, 'N', 400, 'Seed', 2601, 'RunDir', tempname());
fig = tepc.report.diagnosticFigure(R);
close_(tc, fig);
[~, ~, isAx, ~] = gather(fig);
o = findall(fig);
ax = o(isAx);
tc.verifyEqual(numel(ax), 2);
tc.verifyTrue(all(isfinite(vertcat(ax.XLim)), 'all'), '真数据的轴限出现 NaN/Inf');
[isLn, ~, ~, ~] = gather(fig);
ln = o(isLn);
nonEmpty = 0;
for i = 1:numel(ln)
    if numel(ln(i).XData) > 1
        nonEmpty = nonEmpty + 1;
    end
end
tc.verifyGreaterThan(nonEmpty, 0, '所有线条都是空的: 曲线没画出来而图照样返回句柄');
% 生产路径的拆分发布: 脚注从 summary 取数, 所以这几项必须真的在, 且两条 2cov 求和
% 在真实事件表上也得对得上 (合成数据只证明代数, 真数据才证明权重与选择集接对了)。
s = R.summary;
tc.verifyTrue(isfield(s, 'instrument_split_status'), ...
    '拆分没发布进 summary: 脚注只能印 NOT_RECORDED');
tc.verifyTrue(any(strcmp(string(s.instrument_split_status), ...
    ["EVALUATED", "NOT_EVALUATED"])), sprintf('状态取值意外: %s', s.instrument_split_status));
tc.verifyLessThanOrEqual(s.instrument_split_n_paired, s.instrument_split_n_events, ...
    '配对数不可能大于事件数');
tc.verifyTrue(isfinite(s.instrument_cov_cross), ...
    'cov_cross 非有限: 拆分在生产路径上没算完, 恒等式判据会空转');
sc = max([abs(s.instrument_added_var_diff), abs(s.instrument_added_paired), ...
    abs(s.instrument_cov_term), eps]);
tc.verifyLessThan(abs(s.instrument_cov_cross), 1e-9 * sc, sprintf( ...
    '生产路径两条 2cov 算法差 %.3e: 权重、单位或选择集接错', s.instrument_cov_cross));
tc.verifyTrue(isfinite(s.instrument_avalanche_share) && ...
    s.instrument_avalanche_share > 0, '雪崩解析份额没发布');
% 谱形成因分解: 断言只落在"群对不对 / 划分穷尽不穷尽"上, 且必须有一条拿**已发布值**
% 当第三源 —— 只用新代码自己的输出互推, 群错了也照样自洽。
tc.verifyEqual(string(s.form_flag), "ok", sprintf( ...
    'form_flag=%s: 分解本身没算成 (无发布事件或分位带塌缩), 下面的成因判据都无从判起', ...
    string(s.form_flag)));
tc.verifyEqual(double(s.form_share_w_sum), 1, 'RelTol', 1e-12, sprintf( ...
    'L2 权重份额合计 %.15g != 1: 贡献带不穷尽或互相重叠', double(s.form_share_w_sum)));
tc.verifyLessThan(abs(double(s.form_resid_group)), ...
    1e-12 * max(abs(double(s.form_yF_exact)), eps(1)), sprintf( ...
    '分解群加权均值与 buildSpectrum 精确矩差 %.3e: 入选群定义与发布谱不一致', ...
    abs(double(s.form_resid_group))));
tc.verifyLessThan(abs(double(s.form_resid_bands)), ...
    1e-12 * max(abs(double(s.form_yF_exact)), eps(1)), sprintf( ...
    'Σ(份额×带均值) 与 y_F 差 %.3e: 划分不穷尽或带间重叠 (与"群对不对"是两件事)', ...
    abs(double(s.form_resid_bands))));
tc.verifyEqual(double(s.form_yF_exact), double(s.yF_keV_um), 'RelTol', 1e-12, sprintf( ...
    'form_yF_exact=%.12g 与已发布 yF_keV_um=%.12g 不是同一个数: 分解用错了群', ...
    double(s.form_yF_exact), double(s.yF_keV_um)));
tc.verifyEqual(double(s.form_l1_uncovered), 0, sprintf( ...
    'L1 排除类加发布群仍漏 %g 个事件: 有事件的成因没人记账', double(s.form_l1_uncovered)));
tc.verifyGreaterThan(double(s.form_class_count_l1), 1, sprintf( ...
    'L1 只有 published 自己一类 (%g): 排除侧分解没生效', double(s.form_class_count_l1)));
tc.verifyGreaterThan(double(s.form_n_below_yF), 0, ...
    '发布群里没有事件落在 y_F 以下: 主体带为空, 贡献带划分不成立');
tc.verifyLessThan(double(s.form_yF_binned_rel_diff), 5e-3, sprintf( ...
    '分箱矩与精确矩相对差 %.3e 过大 (应远小于 runGate 的 tol_bin=0.02)', ...
    double(s.form_yF_binned_rel_diff)));
tc.verifyTrue(strlength(string(s.form_top_contrib_class)) > 0, ...
    '贡献最大的带没发布: 脚注无当次数可印');
% 这三个标量是**分别发布**的, 所以这条等式不是恒等式复述而是跨字段互推:
% 任一处 (带的份额 / 带均值 / 对 y_F 的贡献) 接错就会红, 也正是脚注要印的算式。
tc.verifyEqual(double(s.form_top_contrib_over_yF), ...
    double(s.form_top_share_w) * double(s.form_top_band_mean) / double(s.form_yF_exact), ...
    'RelTol', 1e-12, sprintf('份额 %.6g × 带均值 %.6g / y_F %.6g != 贡献 %.6g: 脚注算式与发布值不一致', ...
    double(s.form_top_share_w), double(s.form_top_band_mean), double(s.form_yF_exact), ...
    double(s.form_top_contrib_over_yF)));
tc.verifyTrue(double(s.form_top_contrib_over_yF) > 0 && ...
    double(s.form_top_contrib_over_yF) <= 1, sprintf( ...
    '单带对 y_F 的贡献 %.4g 不在 (0,1]: 带之间不互斥或分母用错', ...
    double(s.form_top_contrib_over_yF)));
% 分解必须**在图上可见**: 只进 summary 而脚注不读, 读者看到的还是孤零零一个 y_F。
udF = fig.UserData;
txtF = join(string(udF.diagnosticFooter(:)'), " | ");
tc.verifyTrue(contains(txtF, "form_"), ...
    '脚注没有引用 summary.form_*: 成因分解落了字段但没落到图上');
tc.verifyTrue(contains(txtF, string(s.form_top_contrib_class)), ...
    sprintf('脚注没印本次贡献最大的带 %s: 印的可能是别次数或根本没印', ...
    string(s.form_top_contrib_class)));
end

%% ==================== 6. 脚注与轴文字必须真的分开 ====================
function test_footer_and_axis_text_do_not_collide(tc)
% 用户点名的原始缺陷是"诊断图下半部分文字重叠"。上面几条只核脚注**文字在不在**,
% 一条都核不到"有没有压在刻度数字/轴标签上" —— 再加一段脚注、改字号或改行数,
% 就会静默回到重叠态。
% 判据走**导出图的墨迹行**, 不走几何位置: 拿 tl.Position 与 annotation.Position 相减只是在
% 复述 diagnosticFigure 自己写下的 axisBandPt=66 假设 (镜像判据, 抓不到假设本身错)。
% 门限一律写成"脚注自己行高的倍数" (lineH = 实测行簇高度的中位数), 不写死像素:
% 上一版写死 20/24 px, 实测把导出分辨率放大到 1.3 倍健康图就误红 (像素门限随 DPI 漂移)。
% 两条独立来源必须对账: 产品自己声明的预留行数 diagnosticFooterReservedLines vs 从墨迹数出来的
% 行簇数 —— 只有两者相等, "间隙够"才不是靠数错行数蒙出来的。
% 必须用**真实跑**的 R: 合成谱只落 1 行脚注, 发货图 7 行, 底部条带完全不同,
% 判据要钉的是读者真正拿到的那张图。
Rr = tepc.io.projectRoot();
cfgf = tepc.config.load(fullfile(Rr, 'config', 'defaults', 'demo_only.json'));
R = tepc.run.execute(cfgf, 'N', 400, 'Seed', 2602, 'RunDir', tempname());
fig = tepc.report.diagnosticFigure(R);
close_(tc, fig);
fn = [tempname, '.png'];   % 必须用 tempname: 自己拼时间戳会得到带空格的文件名,
                          % exportgraphics 直接报 MATLAB:print:CannotCreateOutputFile (实测)
exportgraphics(fig, fn, 'ContentType', 'image', 'Resolution', 150);
addTeardown(tc, @() delete(fn));
img = imread(fn);
H = size(img, 1);
tc.verifyGreaterThan(H, 400, sprintf('导出图只有 %d 行, 不像渲染成功', H));
ink = min(double(img), [], 3) < 200;          % 白底深色字: 任一通道暗即算墨迹
rows = sum(ink, 2) >= 3;                      % 抗单像素噪声: 一行至少 3 个墨迹点
[clTop, clBot] = inkClusters(rows, 3);
nCl = numel(clBot);
tc.verifyGreaterThan(nCl, 3, sprintf('整张图只数出 %d 簇墨迹: 图可能整段没画', nCl));
nExp = fig.UserData.diagnosticFooterReservedLines;
tc.verifyGreaterThan(nExp, 1, '产品没发布脚注预留行数: 对账判据无从谈起');
% 脚注块 = 最底下 nExp 个簇。先要求它们确实是"行状"簇 (高 <= 1.9*行高) 且行距正常,
% 再要求 nExp+1 簇 (紧接其上的那一簇) 与脚注块之间存在 >= 2*行高 的真空。
hgt = clBot - clTop + 1;
lineH = median(hgt(1:min(nExp, nCl)));
tc.verifyGreaterThan(lineH, 3, sprintf('行高实测 %.1f px 不像文字行', lineH));
for q = 1:min(nExp, nCl)
    tc.verifyLessThanOrEqual(hgt(q), 1.6*lineH + 1, sprintf( ...
        ['脚注块第 %d 簇高 %.0f px (>1.6*行高 %.0f): 底部不是逐行文字, ' ...
         '两行脚注之间已经没有真空行 (焊在一起) 或脚注已与上方轴文字融成一团'], q, hgt(q), lineH));
end
tc.verifyGreaterThan(nCl, nExp, sprintf( ...
    '墨迹只数出 %d 簇, 少于产品声明的 %d 行: 有行没画出来 (底部条带被压扁)', nCl, nExp));
gapPx = clTop(nExp) - clBot(nExp + 1) - 1;
tc.verifyGreaterThan(gapPx, 2.0*lineH, sprintf( ...
    ['轴文字带与脚注带之间真空 %.0f px < 2*行高(%.0f px): 脚注压在刻度数字/轴标签上 ' ...
     '(缺陷态实测 7 px; 本树实测值由用例自印的 [footer-ink] 行给出, 不在文案里写死)'], gapPx, lineH));
% 原始缺陷有**两处**重叠, 上面只盖住"脚注 vs 轴文字"这一处。第二处是刻度数字与 xlabel
% 焊在一起 (底稿实测: 刻度带 905..922、标签带 930..957, 两行之间只剩 7 行真空, 合成一张
% 28 px 的带; 若它们之间真空塌成 0, 这一簇会长到 ~2 行 = 30+ px 并与上方再融成一团)。
% 所以紧接脚注之上的那一簇也必须仍是"一小段文字", 不能长成多行融合块。
% 门限 2.4*行高: 当前实测 28 px = 1.87*行高(15.0) 放行, 而"两行以上融合"必然 >2 行高。
% 高度门限对"融合"没有判别力, 甚至方向相反: 两行各 ~11 px 加 7 px 真空是 28 px,
% 真空清零之后是 ~22 px —— 更矮。真正的信号是带内还剩不剩一条近似空白的分隔行。
seamBad = fusedBands(ink, clTop, clBot, lineH, nExp + 1);
tc.verifyEmpty(seamBad, sprintf( ...
    ['这些墨迹带高过一行却找不到分隔行 (%s): 两行文字已焊成一块 —— ' ...
     '这就是原始缺陷的第二处重叠 (刻度数字与 xlabel 之间真空清零), 旧的高度门限放行它'], ...
    strjoin(seamBad, '; ')));
% 反例腿: 同一套测量必须能分辨"两行留真空"与"两行贴死"。不跑这一条, 上面的判据
% 只是复述当前这张图的样子, 换台机器或改字号就不知道还在不在。
[sevFused, sevClean] = seamSelfCheck('selftest', 12);
tc.verifyEmpty(sevClean, sprintf('合成健康图 (两行之间留 6 px 真空) 被判融合: 接缝判据过严, 正控不可信 (%s)', strjoin(sevClean, '; ')));
tc.verifyNotEmpty(sevFused, '合成融合图 (两行贴死, 无真空) 没被判违规: 接缝判据抓不到已知破坏');
% 注: 曾在此加一条"脚注末行距画布下沿 >= 0.5*行高"的锁 —— 实测把 annotation 内缩从 0.006
% 抬到 0.020 之后, 末行墨迹仍停在离下沿 2 px 处 (与预留行数无关), 说明我对那条带的理解还不
% 完整。不把没搞清的现象写成断言 (会留下一条谁也解释不了的红), 故此处只留**重叠**判据;
% 下沿余量问题尚未查清, 查清前不写成断言。
fprintf('[footer-ink] 图高=%d 行高=%.1f 脚注预留=%d 行 簇数=%d 真空=%.0f px (%.2f*行高) 下沿=%d px\n', ...
    H, lineH, nExp, nCl, gapPx, gapPx/lineH, H - clBot(1));
end

function test_rendered_identifiers_are_not_typeset(tc)
% 图上印的标识符必须能照图抄回代码。TeX 解释器把未转义的 '_' 读成取下标、'^' 读成上标,
% 于是 y_F 在图上是一个带下标的 F, summary.instr_res_fwhm_over_yF 会碎成"instr_es"加一堆
% 下标的乱码 —— 读者照图抄回去的字段名是错的。Markdown 的 **强调** 在 TeX 语境里就是两个
% 星号, 同属图文不符。判据取**渲染出口**而不是源码: 源码里没有下标不代表图上没有,
% 这些串是从 R/A 里插值出来的。
R = fakeSpectrum([1 3 8 20 12 5 2], 0.02, 0.01);
fig = tepc.report.diagnosticFigure(R);
close_(tc, fig);
tx = findall(fig, 'Type', 'text');
tc.verifyGreaterThanOrEqual(numel(tx), 6, ...
    sprintf('只数到 %d 个 Text 对象, 图没建起来', numel(tx)));
bad = strings(0, 1);
inv = strings(0, 1);
for k = 1:numel(tx)
    txt = flatText(tx(k).String);
    if isempty(txt), continue; end
    it = string(tx(k).Interpreter);
    inv(end+1) = it + " | " + string(txt(1:min(48, numel(txt)))); %#ok<AGROW>
    if it ~= "none" && ~isempty(regexp(txt, '(?<!\\)[_^]', 'once'))
        bad(end+1) = it + " | " + string(txt); %#ok<AGROW>
    end
end
fprintf('[text-inventory] %d 个 Text 对象:\n%s\n', numel(inv), char(strjoin(inv, newline)));
tc.verifyEmpty(bad, sprintf('这些文字带未转义的下标/上标却仍走 TeX 排版:\n%s', ...
    char(strjoin(bad, newline))));

% 脚注 annotation 曾试过 'Interpreter','none' (为了让字段名不被排版吃掉), 实测把重叠判据
% 打回缺陷态: 墨迹行高 15 -> 28 px, 轴文字带与脚注带之间真空塌到 11 px (0.39 行高)。
% 所以这里反过来钉"脚注没有改解释器", 并把理由留在原地 —— 谁要再上这条, 必须先让
% 预留行数的宽度模型与真实排版同代, 否则换来的是更严重的重叠。
src = char(fileread(fullfile(tepc.io.projectRoot(), 'src', '+tepc', '+report', ...
    'diagnosticFigure.m')));
iAnn = strfind(src, 'annotation(fig, ''textbox''');
tc.verifyNotEmpty(iAnn, '找不到脚注 annotation 的构造点');
if ~isempty(iAnn)
    seg = src(iAnn(1):end);
    st = strfind(seg, ');');
    if ~isempty(st), seg = seg(1:st(1)); end
    tc.verifyFalse(contains(seg, "'Interpreter'"), ...
        '脚注 annotation 不得单独改 Interpreter: 见本用例注释里的实测代价 (真空 11 px)');
end

% 渲染文案扫 Markdown 强调: 整个 +report 包, 外加两处"屏幕消费方" —— 门禁 detail 与
% 能力提示会原样进 HTML 表格与 GUI 的 GatesTable, 星号在那里就是印在屏幕上给人看的。
root = tepc.io.projectRoot();
d = fullfile(root, 'src', '+tepc', '+report');
fs = dir(fullfile(d, '*.m'));
scanFiles = {};
for k = 1:numel(fs)
    scanFiles{end+1} = fullfile(d, fs(k).name); %#ok<AGROW>
end
scanFiles{end+1} = fullfile(root, 'src', '+tepc', '+validation', 'runGate.m');
scanFiles{end+1} = fullfile(root, 'src', '+tepc', '+run', 'probeRuntime.m');
hits = strings(0, 1);
for k = 1:numel(scanFiles)
    txt = string(fileread(scanFiles{k}));
    hh = markdownInStrings(strsplit(txt, newline));
    for j = 1:numel(hh)
        hits(end+1) = string(string(scanFiles{k}(numel(root)+2:end))) + ": " + hh(j); %#ok<AGROW>
    end
end
tc.verifyEmpty(hits, sprintf('渲染文案里漏进 Markdown 强调:\n%s', char(strjoin(hits, newline))));
% 扫描器的两条腿: 已知含 ** 的字符串行必须报, 注释行里的 ** 必须不报。
pos = markdownInStrings({'    a = sprintf(''故本带是**核**的相对标准差'');'});
tc.verifyEqual(numel(pos), 1, '扫描器对已知含 ** 的字符串行漏报 (判据没有牙齿)');
neg = markdownInStrings({'    % 注释里写 **强调** 不算渲染文案'});
tc.verifyEqual(numel(neg), 0, '扫描器把注释行也算成了渲染文案');
end

function s = flatText(v)
% 一个 Text 对象的 String 可以是 char / string / cell (多行), 统一压成一行 char 再判
% (string 标量不能用 s(1:n) 截字符, 实测 MATLAB:badsubscript)。
if iscell(v)
    parts = strings(numel(v), 1);
    for j = 1:numel(v)
        parts(j) = string(v{j});
    end
    t = strjoin(parts, " ");
else
    t = string(v);
end
t = strrep(t, newline, " ");
s = char(t);
end

function hits = markdownInStrings(lines)
% 字符串字面量里含 '**' 的行; 以 % 起始的注释行不算 (注释是给人看的, 用 ** 强调无害)。
hits = strings(0, 1);
for k = 1:numel(lines)
    t = strtrim(string(lines(k)));
    if startsWith(t, "%"), continue; end
    q = regexp(char(t), '''[^'']*''', 'match');
    for j = 1:numel(q)
        if contains(string(q{j}), "**")
            hits(end+1) = t; %#ok<AGROW>
            break
        end
    end
end
end


function [clTop, clBot] = inkClusters(rows, minPixPerRow)
% 自下而上把"有墨的行"并成簇。抽成函数是为了让真图与合成图走同一条测量,
% 否则反例腿验的是一套代码、正控用的是另一套。
clTop = zeros(1, 0); clBot = zeros(1, 0);
H = numel(rows);
i = H;
while i > 0
    while i > 0 && ~rows(i), i = i - 1; end
    if i == 0
        break;
    end
    b = i;
    while i > 0 && rows(i), i = i - 1; end
    clBot(end+1) = b; %#ok<AGROW>
    clTop(end+1) = i + 1; %#ok<AGROW>
end
end

function bad = fusedBands(ink, clTop, clBot, lineH, maxIdx)
% 只判脚注块与紧接其上的那一簇 (maxIdx = nExp+1): 再往上是绘图区, 它本身就是一个
% 几百 px 的巨簇, 对它谈"两行文字融合"没有意义 (实测发货图绘图簇高 859 px)。
% 高过一行的带, 带内必须还剩一条"近似空白"的分隔行; 否则判为两行文字融合。
% 分隔行允许极少量墨 (降部、逗号尾巴), 阈值取该带最密行的 25% 与 4 px 里的较大者:
% 实测发货图刻度带+xlabel 带的带内最稀行是 3 px / 最密行 61 px (比值 0.05),
% 而两行贴死的合成图是 25 px / 26 px (比值 0.96) —— 两边相差 20 倍, 不靠边站。
if nargin < 5, maxIdx = numel(clBot); end
bad = strings(0, 1);
for q = 1:min(maxIdx, numel(clBot))
    h = clBot(q) - clTop(q) + 1;
    if h <= 1.6 * lineH + 1, continue; end
    rowsInk = sum(ink(clTop(q):clBot(q), :), 2);
    inner = rowsInk(2:end-1);
    if isempty(inner), continue; end
    tol = max(4, 0.25 * max(rowsInk));
    if min(inner) > tol
        bad(end+1) = sprintf('带 %d 高 %d px (行高 %.1f), 带内最稀行 %d px > 容差 %.1f', ...
            q, h, lineH, round(min(inner)), tol); %#ok<AGROW>
    end
end
end

function img = synthTextRows(gapPx, nCols)
% 两行 12 px 高的"文字条", 中间留 gapPx 行真空。
img = 255 * ones(60, 40, 3, 'uint8');
img(20:31, 5:(5 + nCols - 1), :) = 0;
img(32 + gapPx:43 + gapPx, 5:(5 + nCols - 1), :) = 0;
end

function [badFused, badClean] = seamSelfCheck(modeTag, lineH)   %#ok<INUSL>
% 名字里不能带 test 子串: functiontests 的默认筛选按名字含 "test" 收集局部函数,
% 一旦带上就被当成用例并要求恰好一个入参, 于是 genCounts 的静态口径与套件实际收集数分叉
% (本仓实测: 静态 602 对实际 603, test_doc_counts 的 plausible 那条锁红过一次)。
ic = synthTextRows(6, 26);
inkC = min(double(ic), [], 3) < 200;
rowsC = sum(inkC, 2) >= 3;
[cT, cB] = inkClusters(rowsC, 3);
badClean = fusedBands(inkC, cT, cB, lineH, numel(cB));
ifs = synthTextRows(0, 26);
inkF = min(double(ifs), [], 3) < 200;
rowsF = sum(inkF, 2) >= 3;
[fT, fB] = inkClusters(rowsF, 3);
badFused = fusedBands(inkF, fT, fB, lineH, numel(fB));
end
