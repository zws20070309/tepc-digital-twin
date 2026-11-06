function fig = organDoseFigure(sites, opts, varargin)
%ORGANDOSEFIGURE 大气中子 -> 皮肤/眼晶状体剂量谱图: 左=入射注量谱 (两段分开), 右=逐群剂量 (按 basis 分色)。
%
% 这张图唯一的作用是让人分清"哪一段是什么口径的数"。所以右面板不按器官分色, 而是按 groups.basis
% 分色 + 分别进图例, 并在脚注里给出各自的份额。把外推段和实测段画成同一根线就是把估算洗成测量。
%
% 左面板必须把 1 MeV 以下的反演段一起画出来: 只画 >1 MeV 那段会让读图的人以为入射谱就是这样
% 截断的, 而低能段占拉萨总注量的一半以上。
%
% 配色沿用 diagnosticFigure 的 Okabe-Ito 色盲安全集 (红绿对比在 deuteranopia 下不可分辨)。
% 脚注高度按真实换行数算, 不写死分数 (写死过一次, 结果脚注压在 x 轴刻度上)。
%
% 输入:
%   sites : 站点名 string 数组, 默认 ["Lhasa","Yangbajing","Lanzhou","Guangzhou"]
%   opts  : struct, 传给 tepc.analysis.organDoseFromField (organ/phantom/geometry/lowSegment/...)
% 输出: fig (隐藏 figure); 调用方自己 exportgraphics 或 saveas。

if nargin < 1 || isempty(sites)
    sites = ["Lhasa", "Yangbajing", "Lanzhou", "Guangzhou"];
end
if nargin < 2, opts = struct(); end
% footnoteFs 是刻意留的差分旋钮: 把脚注字号调大, 布局下沿必须跟着抬高 ——
% 不跟着动就说明预留高度是写死的, 那这张图的"不重叠"只是巧合。
pf = inputParser;
pf.addParameter('footnoteFs', 6.5, @(x) isnumeric(x) && isscalar(x) && x > 0 && x < 30);
pf.parse(varargin{:});
footFs = double(pf.Results.footnoteFs);
C_BLUE = [0 0.447 0.741]; C_VERM = [0.850 0.325 0.098];
C_AMBER = [0.929 0.694 0.125]; C_GRAY = [0.30 0.30 0.30];
C_TEAL = [0 0.60 0.50];
axFs = 8;   % footFs 由 pf.Results.footnoteFs 给 (差分旋钮)

R = cell(1, numel(sites));
for i = 1:numel(sites)
    R{i} = organDoseWith(sites(i), opts);
end
r0 = R{1};

figW = 1250; figH = 760;
fig = figure('Name', 'organ dose from atmospheric neutrons', 'Visible', 'off', ...
    'Position', [60 60 figW figH], 'Color', 'w');
set(fig, 'ToolBar', 'none');       % 否则 exportgraphics 会把坐标区工具栏画进图里
topMargin = 0.085;                 % 顶部留给两幅子图的标题
% 用显式 axes 而不是 tiledlayout: 隐藏 figure 里 tiledlayout 不响应后续 Position 改动,
% 手摆 Position 时 x 轴标签会挂到布局框外、压进脚注带。显式 axes 的 OuterPosition 立刻生效。

% ---------------- 左: 入射注量谱 (四站, 实测段 + 反演段) ----------------
ax1 = axes(fig, 'Position', [0.055 0.30 0.395 0.60]);
hold(ax1, 'on');
mk = {'-o', '--s', '-.^', '-*'};
cols = [C_BLUE; C_VERM; C_AMBER; C_GRAY];
hDig = gobjects(0); hInv = gobjects(0);
for i = 1:numel(R)
    gi = R{i}.groups;
    m = gi.basis == "digitized_anchored";
    % 句柄必须从画图调用本身取: HandleVisibility='off' 的对象不进 ax1.Children,
    % 用 Children(1) 回取会拿到上一条**可见**的线 (实测图例里多出一条重复的 Lhasa)。
    hd = semilogx(ax1, gi.energy_MeV(m), gi.dphi_dE_cm2_s_MeV(m), mk{i}, ...
        'Color', cols(min(i,4),:), 'MarkerSize', 4, 'LineWidth', 1.1, ...
        'DisplayName', sprintf('%s  %.1f cm^{-2}h^{-1}', sites(i), ...
        R{i}.meta.published_flux_cm2_h));
    hDig(end+1) = hd; %#ok<AGROW>
    ml = gi.basis == "digitized_inverted";
    if any(ml)
        % Line 没有 MarkerFaceAlpha 这个属性 (写上去是 InvalidProperty), 反演段用
        % 空心小圈 + 细虚线区分, 不靠透明度。
        hl = semilogx(ax1, gi.energy_MeV(ml), gi.dphi_dE_cm2_s_MeV(ml), ':', ...
            'Color', cols(min(i,4),:), 'Marker', 'o', 'MarkerSize', 3, ...
            'LineWidth', 0.8, 'HandleVisibility', 'off', ...
            'DisplayName', '图 3(a) 反演段 (<1 MeV)');
        hInv(end+1) = hl; %#ok<AGROW>
    end
end
set(ax1, 'FontSize', axFs, 'XScale', 'log', 'YScale', 'log', 'GridAlpha', 0.25);
set(ax1, 'XLim', [1e-8 1.2e3], 'XTick', 10.^(-8:2:3));
xlabel(ax1, '中子能量 / MeV'); ylabel(ax1, 'd\Phi/dE / cm^{-2} s^{-1} MeV^{-1}');
% 标题必须跟着实际画出的段走: upper_bound / none 档没有反演段, 写死"虚线点=图 3(a) 反演"
% 就是让图说一件它自己没做的事 (10-10 看 z784_fig_ub.png 抓到的)。
if isempty(hInv)
    title(ax1, '入射谱 (实线=图 3(b) 直读; 本档无 1 MeV 以下段)');
else
    title(ax1, '入射谱 (实线=图 3(b) 直读, 虚线点=图 3(a) 反演)');
end
if isempty(hInv)
    lg = legend(ax1, hDig, 'Location', 'southwest', 'FontSize', axFs - 1);
else
    % gobjects 数组是按 end+1 长的**行**向量, 用 [a; b] 串联会 dimensionMismatch。
    lg = legend(ax1, [hDig, hInv(1)], 'Location', 'southwest', 'FontSize', axFs - 1);
end
lg.NumColumns = 1;

% ---------------- 右: 逐群剂量, 按 basis 分色 ----------------
ax2 = axes(fig, 'Position', [0.548 0.30 0.400 0.60]);
hold(ax2, 'on');
g = r0.groups;
bcol = struct('digitized_inverted', C_TEAL, 'upper_bound_below', C_GRAY, ...
    'digitized_anchored', C_BLUE, 'extrapolated_above', C_VERM, 'no_low_segment', C_GRAY);
lab = struct('digitized_inverted', '0.998 MeV 以下 图3(a) 反演 (实测, 逐点 ±20-40%)', ...
    'upper_bound_below', '<1 MeV 上界估算 (非测量)', ...
    'digitized_anchored', '0.998 MeV-1 GeV 图3(b) 直读 (可引用)', ...
    'extrapolated_above', '>1 GeV 幂律外推 (非测量)', ...
    'no_low_segment', '低能段关闭 (对照档)');
% 只画面里真有的段: .lowSegment 换档时 basis 集合会变, 写死三段会在换档时画空或报错。
order = ["digitized_inverted", "upper_bound_below", "digitized_anchored", ...
    "extrapolated_above", "no_low_segment"];
order = order(ismember(order, unique(g.basis)));
shareTot = 0;
for i = 1:numel(order)
    b = order(i);
    m = g.basis == b;
    d = g.dose_rate_pGy_h(m);
    e0 = g.edge_lo_MeV(m); e1 = g.edge_hi_MeV(m);
    x0 = log10(e0(:)'); x1 = log10(e1(:)'); dd = d(:)';
    % 用 patch 不用 bar: bar 的宽度参数只能是标量, 而这里的能群宽度差多个数量级,
    % 画成等宽就是假轮廓。每群一个面 (4 顶点行 × n 列), 一次 patch 调用画完。
    X = [x0; x1; x1; x0]; Y = [zeros(size(x0)); zeros(size(x1)); dd; dd];
    patch(ax2, X, Y, bcol.(b), 'FaceColor', bcol.(b), 'EdgeColor', 'none', ...
        'FaceAlpha', 0.9, 'DisplayName', lab.(b));
    shareTot = shareTot + sum(d);
end
yl = ylim(ax2);
for b = ["upper_bound_below", "extrapolated_above", "no_low_segment"]
    m = g.basis == b;
    if ~any(m), continue; end
    E = g.energy_MeV(m);
    rectangle(ax2, 'Position', [min(log10(E)) 0 max(log10(E))-min(log10(E)) yl(2)], ...
        'EdgeColor', [0.6 0.6 0.6], 'LineStyle', ':', 'FaceColor', [0.94 0.94 0.94], ...
        'FaceAlpha', 0.35, 'HitTest', 'off');
end
% XTick 与 XTickLabel 的**个数必须相等**: 多给一个 '10' 会让标签整体左移一格, 于是
% 轴末端的 10^4 被标成 10^2 —— 图不报错, 只是把刻度念错。测试里按数量钉住。
set(ax2, 'FontSize', axFs, 'GridAlpha', 0.25, ...
    'XTick', -8:2:4, 'XTickLabel', {'10^{-8}', '10^{-6}', '10^{-4}', '10^{-2}', ...
    '1', '10^{2}', '10^{4}'});
set(ax2, 'XLim', [-8 4.1]);
xlabel(ax2, '中子能量 / MeV'); ylabel(ax2, sprintf('剂量率 / pGy h^{-1} (%s)', r0.organ));
title(ax2, sprintf('%s %s/%s 逐群剂量: 外推段不是测量值', r0.site, r0.organ, r0.phantom));
legend(ax2, 'Location', 'northwest', 'FontSize', axFs - 1);

% ---------------- 脚注: 全部由数据现算, 不写死数字 ----------------
sh = r0.dose_rate_pGy_h;
pct = 100 * [sh.low, sh.digitized, sh.extrapolated] / max(shareTot, realmin);
% 低能段的**名字**必须跟着档位走: 叫它"反演段"而本档其实是上界估算, 就是让图替数据说一句它没做的事。
switch lower(string(r0.low_segment_mode))
    case "inverted",     lowName = "低能反演段(实测)";
    case "upper_bound",  lowName = "低能上界段(非测量)";
    otherwise,           lowName = "低能段(本档未取)";
end
f1 = sprintf('%s %s/%s/%s: 数字化直读段 %.4g pGy/h, %s %.4g, >1 GeV 外推 %.4g; 份额 %.1f%% / %.1f%% / %.1f%%。', ...
    r0.site, r0.organ, r0.phantom, r0.geometry, sh.digitized, lowName, sh.low, sh.extrapolated, ...
    pct(2), pct(1), pct(3));
f2 = sprintf(['直读段复算通量 %.4g vs 正文 %.4g cm^{-2}h^{-1} (差 %+.3f%%); 两表都按 ' ...
    'Σ(dphi/dE×群宽) 在 1 MeV-1 GeV 上锚定到正文值, 与本页求积同式。'], ...
    r0.meta.recomputed_flux_cm2_h, r0.meta.published_flux_cm2_h, 100 * r0.meta.flux_check_rel);
if string(r0.meta.tail_index_source) == "user"
    tailHow = "由调用方指定 (.tailIndex), 不是本谱拟合值";
else
    tailHow = sprintf('由直读段末 %d 点拟合', r0.meta.tail_fit_points);
end
f3 = sprintf('外推段幂律指数 p=%.4f %s; 解谱上限 1 GeV 之上的剂量不是测量值。', ...
    r0.meta.tail_power_law_p, tailHow);
f4 = ['纵轴是吸收剂量 (Gy)。ICRP 116 的 C.12/C.27 是全皮肤体素平均的 H_skin 侧系数, ' ...
    '不是 Hp(0.07); 体模皮肤体素比真实皮肤厚, 表值对中等射程粒子最多低估 35% (只下偏)。'];
% 第二层天花板: 图上的曲线到 1 GeV 就断了, 但外推窗口其实被**系数表末点**钉在另一个位置上。
% 只披露"解谱上限 1 GeV"会让人以为 aboveEnd 之上还有剂量可算 —— 那段注量没有系数可乘,
% 既不在图上也没进总和, 必须单独说一句, 否则"图=全谱剂量"这个误读没有任何东西挡得住。
fCeil = r0.meta.fluence_beyond_coef_max_cm2_h;
fExt  = r0.meta.fluence_extrapolated_cm2_h;
if isfinite(fCeil) && isfinite(fExt) && fExt > 0
    f6 = sprintf(['第二层天花板: ICRP 116 系数表只到 %.3g MeV, 同一幂律在其上还挂着 %.4g cm^{-2}h^{-1} 注量 ' ...
        '(= 已计分外推段的 %.1f%%), 这段无系数可乘: 本页剂量既不是全谱剂量, 也不得读成 0。'], ...
        r0.meta.coef_energy_max_MeV, fCeil, 100 * fCeil / fExt);
else
    f6 = sprintf('系数表末点 %.3g MeV 不在本图外推窗口之上, 没有无系数可乘的注量段。', ...
        r0.meta.coef_energy_max_MeV);
end
if isnan(r0.meta.overlap_dphi_ratio)
    f5 = ['低能段本档不是实测反演 (lowSegment=' char(r0.low_segment_mode) '); ' ...
        '反演档才给两通道同能量比对。'];
else
    f5 = sprintf(['低能段来自同一篇论文图 3(a) 的 109 群 (逐群注量/本图群宽), 与图 3(b) 是同一个解: ' ...
        '两表 E>=1 MeV 的 30 群逐点吻合到 %.2f%% 以内, 同能量读数比 %.4f; 单群幅值 ±20-40%%。'], ...
        100 * maxRelOffset(R), r0.meta.overlap_dphi_ratio);
end
% 预留高度不能靠"每字符多少像素"的估算 —— 第一版就是估小了, 脚注上沿压住左面板的
% x 轴标签与刻度数字, 最后一行还被画布下沿裁掉。TextBox 没有 Extent 量不了,
% 所以先在一张"占满图高"的隐形坐标轴上放同样的 text, 读它的 Extent 拿到真实换行后的高度,
% 删掉它, 再用这个高度去抬布局。
foot = {f1, f2, f3, f4, f5, f6};
tmp = axes(fig, 'Position', [0 0 1 1], 'Visible', 'off', 'XTick', [], 'YTick', []);
tmp.XLim = [0 1]; tmp.YLim = [0 1];
th = text(tmp, 0.012, 1.0, foot, 'VerticalAlignment', 'top', ...
    'HorizontalAlignment', 'left', 'FontSize', footFs, 'Clipping', 'off');
drawnow;
e = th.Extent;
ip = tmp.InnerPosition;      % text 的 Extent 是**数据单位**, 要乘内框高度才换成图归一单位
delete(tmp);
footPx = max(e(4) * ip(4) * figH, 40);

% 摆 Position 的下沿要同时给脚注带和坐标区外挂 (x 轴标签+刻度数字) 留钱, 后者只能量:
% 每轮读所有坐标区 OuterPosition 的最低点, 与已留高度之差就是还缺的像素, 补上再量。四轮收敛。
axs = [ax1, ax2];
band = footPx + 8;
for k = 1:4
    bot = band / figH;
    hgt = max(0.05, 1 - bot - topMargin);
    ax1.Position = [0.055 bot 0.395 hgt];
    ax2.Position = [0.548 bot 0.400 hgt];
    drawnow;
    ob = inf;
    for j = 1:numel(axs)
        ob = min(ob, axs(j).OuterPosition(2) * figH);
    end
    deficit = footPx + 3 - ob;             % 外沿(含 x 轴标签)与脚注上沿的间隙, 不够就补
    if deficit <= 0, break; end
    band = band + deficit;
end
ann = annotation(fig, 'textbox', [0.012 0.010 0.976 (footPx / figH)], ...
    'String', foot, 'EdgeColor', 'none', 'FontSize', footFs, ...
    'VerticalAlignment', 'top');
drawnow;
% 收尾硬判据: 任何坐标区的外沿压到脚注带上沿, 就报错而不是发一张重叠图
ob2 = inf;
for j = 1:numel(axs)
    ob2 = min(ob2, axs(j).OuterPosition(2) * figH);
end
if ob2 < footPx + 2
    error("tepc:organDoseFigure:FootnoteCollides", ...
        "坐标区外沿最低 %.1f px 低于脚注上沿 %.1f px, 文字会重叠", ob2, footPx);
end
end

function v = maxRelOffset(R)
% 两表 E>=1 MeV 的群心最大相对偏移 —— 从站点结果里带出来, 不写死。
v = 0;
for i = 1:numel(R)
    if isfield(R{i}.meta, 'overlap_center_offset') && isfinite(R{i}.meta.overlap_center_offset)
        v = max(v, R{i}.meta.overlap_center_offset);
    end
end
end

function r = organDoseWith(site, opts)
fn = fieldnames(opts);
a = {'site', site};
for i = 1:numel(fn)
    % 必须用 {} 追加元胞元素: a(end+1) = 'lowSegment' 是"把 char 数组塞进一个格",
    % MATLAB 报"无法将 char 转换为 cell" —— 只要 opts 非空这条接口就整条崩 (10-10 实测)。
    a{end+1} = fn{i}; a{end+1} = opts.(fn{i}); %#ok<AGROW>
end
r = tepc.analysis.organDoseFromField(a{:});
end
