function fig = diagnosticFigure(R)
%DIAGNOSTICFIGURE 诊断图: 线性 y f(y) + 对数 y d(y) + 统计带 + 域外沟槽 + 脚注。
%   图例明确标明曲线含义; 零计数 bin 不在 log 图伪造为小正数 (画中断点)。
%
%   配色: Okabe-Ito 色盲安全集 (蓝 0,0.447,0.741 / 朱 0.850,0.325,0.098 /
%   琥珀 0.929,0.694,0.125 / 灰 0.30)。红绿对比在 deuteranopia 下不可分辨, 而这张图
%   唯一的作用就是让人读出差异, 所以不用默认 'b-'/'r-'。
%
%   统计带: ±1.96*sigma_f 的正态近似 95% 区间, sigma_f 是 buildSpectrum 给的逐 bin
%   加权 Poisson 1σ。只对 counts_raw >= 20 的 bin 画带: 小计数下正态近似不成立, 画出
%   一条看起来对称的带就是把偏斜的 Poisson 区间伪装成对称区间 (假精度)。带是逐 bin
%   独立画的, 未做多重比较校正, 因此整条曲线的联合覆盖率低于 95% —— 这句话在脚注里。
%
%   域外沟槽: 直方 f/d 只覆盖域内 bin (∫f dy = 1 - 阈下 - 超溢), 两侧各画一条琥珀色
%   沟槽标出被丢掉的份额, 免得读者以为曲线下的和就是 1。
%   零计数的域外 bin 不在对数轴上伪造为小正数。

A = R.analysis; S = A.spectrum;
C_BLUE = [0 0.447 0.741]; C_VERM = [0.850 0.325 0.098];
C_AMBER = [0.929 0.694 0.125]; C_GRAY = [0.30 0.30 0.30];
NORM_MIN_COUNTS = 20;                 % 正态近似的最低逐 bin 计数
Z95 = 1.96;                           % 双侧 95% 的正态分位数

% 画布尺寸与底部条带高度是耦合的: 脚注是中英混排的可换行长文本, 它需要的垂直空间
% 只能由行数算出来, 不能写死一个分数。写死过一次, 结果是脚注上沿高过坐标轴下沿,
% 文字压在 x 轴刻度数字与轴标签上。这里先给一个保守初值, 五段脚注全部成形后
% 按真实换行数重算 (见文件末尾的 reserve 段)。
figW = 1250; figH = 780;
initBottom = 0.30;
% 顶部条带要装下 sgtitle 整行标题: 0.022 (17 px) 与 0.050 都不够, 标题字顶被画布上沿
% 裁掉 (逐像素量到首行墨迹在第 3 行且字形上缘缺失)。
topMargin = 0.090;
fig = figure('Name', 'TEPC demo diagnostic', 'Visible', 'off', ...
    'Position', [50 50 figW figH], 'Color', 'w');
tl = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
tl.Position = [0.040 initBottom (1 - 2*0.040) (1 - initBottom - topMargin)];

% ---------- 左: 线性 y f(y) + 95% 统计带 ----------
ax1 = nexttile(tl);
yy = S.center .* S.f;
mask = yy > 0 & S.counts_raw > 0;
plot(ax1, S.center(mask), yy(mask), '-', 'Color', C_BLUE, 'LineWidth', 1.4);
hold(ax1, 'on');
band = mask & (S.counts_raw >= NORM_MIN_COUNTS) & isfinite(S.sigma_f) & (S.sigma_f > 0);
if any(band)
    % fill 的 X/Y 必须先转成**行**向量再拼接: 生产谱 (buildSpectrum) 给的是列, 而 fliplr
    % 对 n×1 列是空操作, [xb fliplr(xb)] 就成了 n×2 —— 实测本机 fill 收到这种输入只留下
    % n 个顶点 (上边界整条被丢), 带子退化成分界线, 但 Patch 对象与图例项照旧存在。
    % 转置在这里是必需项, 不是风格; 回归锁见 test_ci_band_is_a_single_face_band。
    xb   = S.center(band).';
    yv   = yy(band).';
    half = (Z95 .* S.center(band) .* S.sigma_f(band)).';   % y 是 bin 常数 => 同比缩放
    fill(ax1, [xb fliplr(xb)], [yv - half fliplr(yv + half)], ...
        C_BLUE, 'FaceAlpha', 0.18, 'EdgeColor', 'none');
end
err = S.center .* S.sigma_f;
yerr = err(mask);
yerr(yerr <= 0) = NaN;
errorbar(ax1, S.center(mask), yy(mask), yerr, '.', 'Color', C_GRAY, ...
    'LineWidth', 0.6, 'CapSize', 2);
xlabel(ax1, 'y (keV/\mum)'); ylabel(ax1, 'y f(y) (无量纲)');
title(ax1, sprintf('频率分布 (线性轴), y\\_F = %s keV/\\mum', tepc.report.publishedNumber(S, 'yF')));
% 图例按"创建顺序"给标签而不是按句柄向量给: Line/Patch/ErrorBar 是不同类, 拼在一起
% 会当场 horzcat 报错 (实测), 而沟槽与统计带之外的辅助图元一律 HandleVisibility off,
% 所以可见序列恰好就是这三项。若以后改了绘制顺序, 必须同步改这里的标签顺序。
if any(band)
    labs = {'y f(y)', sprintf('95%% 正态带 (仅 n\\geq%d)', NORM_MIN_COUNTS), ...
        '统计误差 (1\sigma)'};
else
    labs = {'y f(y)', '统计误差 (1\sigma)'};
end
legend(ax1, labs, 'Location', 'northeast');
gutters(ax1, S, C_AMBER);
grid(ax1, 'on');

% ---------- 右: 对数 y d(y) ----------
ax2 = nexttile(tl);
yyd = S.center .* S.d;
mask2 = yyd > 0 & S.counts_raw > 0;
h2 = semilogx(ax2, S.center(mask2), yyd(mask2), '-', 'Color', C_VERM, 'LineWidth', 1.4);
hold(ax2, 'on');
% 右板误差棒: d = y*f/yF_exact (buildSpectrum.m:107), 画出的纵轴是 y*d(y) = y^2*f/yF_exact,
% 所以同一加权 Poisson 近似下 sigma(纵轴) = y^2*sigma_f/yF_exact —— 是 **y 的平方**,
% 写成 y^3 会让误差棒量纲变成 keV/\mum 而不是无量纲。
% HandleVisibility off: 右板图例按显式句柄 h2 给, 不让新对象扰动通用子级计数判据。
yerrd = (S.center.^2 / S.yF_exact) .* S.sigma_f;
okE = mask2 & isfinite(yerrd) & (yerrd > 0);
errorbar(ax2, S.center(okE), yyd(okE), yerrd(okE), '.', 'Color', C_GRAY, ...
    'LineWidth', 0.6, 'CapSize', 2, 'HandleVisibility', 'off');
xlabel(ax2, 'y (keV/\mum)'); ylabel(ax2, 'y d(y) (无量纲)');
title(ax2, sprintf('剂量分布 (对数轴), y\\_D = %s keV/\\mum', tepc.report.publishedNumber(S, 'yD')));
legend(ax2, h2, {'y d(y)'}, 'Location', 'northeast');
gutters(ax2, S, C_AMBER);
grid(ax2, 'on');

sgt = sgtitle(tl, sprintf(['TEPC 解析基线 demo: %d 事件 (RESEARCH/DEMO, 禁绝对剂量发布) | ' ...
    '零沉积 %d, 死时间拒 %d, liveFrac %.3f | Q(y): %s'], A.nEvents, ...
    A.flags.zeroDep, A.flags.deadRejected, A.liveFrac, R.qmeta.version));
sgt.FontSize = 10;
% 标题里插的是**机器标识符** (R.qmeta.version 之类), 而 TeX 解释器会把标识符里的
% '_' 当取下标: 'icrp60_et0n_γ' 渲染成带下标的乱码, 读者照图抄不回字段名。
% 这条带子上没有任何需要排版的宏, 所以整条改走 none 而不是逐个转义 (未来的数据值
% 再带 '_' 也不会复发)。轴标签仍走 TeX, 因为那里确实需要 \mum。
sgt.Interpreter = 'none';
[bandDrawn, bandReason, bandSd] = sigmaDBand(ax1, R, S, C_VERM, NORM_MIN_COUNTS);
footer(fig, A, S, Z95, NORM_MIN_COUNTS, R, bandDrawn, bandReason, bandSd);
end

function gutters(ax, S, c)
% 在 x 轴两端各画一条沟槽, 标出阈下/超溢被丢掉的份额。沟槽宽度不表达"丢掉的 y 落在
% 哪里", 只表达"这里丢掉了多少权重"。对数轴上不能加减出非正值, 所以留白按比例缩进。
lim = [min(S.center), max(S.center)];
yl = ylim(ax);
if ~(all(isfinite(lim)) && all(isfinite(yl)))
    return
end
if strcmpi(char(string(ax.XScale)), 'log')
    if ~(lim(1) > 0 && lim(2) > lim(1)), return; end
    k = 1.6;                                    % 每侧留 1/1.6 个跨度做留白
    xUnder = [lim(1) lim(1)/k lim(1)/k lim(1)];
    xOver = [lim(2) lim(2)*k lim(2)*k lim(2)];
else
    span = lim(2) - lim(1);
    if ~(span > 0), return; end
    w = 0.06 * span;
    xUnder = [lim(1) lim(1)-w lim(1)-w lim(1)];
    xOver = [lim(2) lim(2)+w lim(2)+w lim(2)];
end
under = fieldNum(S, 'underflowWeight');
over = fieldNum(S, 'overflowWeight');
xLo = lim(1); xHi = lim(2);
if under > 0
    fill(ax, xUnder, [yl(1) yl(1) yl(2) yl(2)], c, 'FaceAlpha', 0.25, ...
        'EdgeColor', 'none', 'HandleVisibility', 'off');
    xLo = xUnder(2);
end
if over > 0
    fill(ax, xOver, [yl(1) yl(1) yl(2) yl(2)], c, 'FaceAlpha', 0.25, ...
        'EdgeColor', 'none', 'HandleVisibility', 'off');
    xHi = xOver(2);
end
% 画幅只在真丢了份额的那一侧扩出去: 域外什么都没有却把 x 轴撑宽, 是给读者留了一个
% 需要去解释的空位。
if xLo < lim(1) || xHi > lim(2)
    ax.XLim = [xLo xHi];
end
end

function footer(fig, A, S, z95, nmin, R, bandDrawn, bandReason, bandSd)
% 脚注: 把"这张图没说的东西"写出来。归一缺口、带的成立条件、配色理由都是图形本身
% 无法自证的部分, 不写就会被读者默认满足。宿主事实: annotation 对象不在 findall(fig)
% 的遍历结果里, 也不允许用 text(fig,...) (Text 不能是 Figure 的子级), 所以核对脚注要
% 走 fig.Annotations; 底部那条空白由 tl.Position 让出来。
l1 = sprintf(['脚注: 直方只在域内 bin 给出, ∫f dy = %.4f (= 1 - 阈下 - 超溢); 域外份额 ' ...
    '阈下 w=%.3g (%d 事件) / 超溢 w=%.3g (%d 事件), 以琥珀色沟槽标出, 沟槽宽度不表示位置。' ...
    '分箱口径见句末。%s'], ...
    fieldNum(S, 'intFdy'), fieldNum(S, 'underflowWeight'), fieldNum(S, 'counts_underflow'), ...
    fieldNum(S, 'overflowWeight'), fieldNum(S, 'counts_overflow'), binText(S));
l2 = sprintf(['统计带 = ±%.2fσ 正态近似, 仅对逐 bin 计数 ≥ %d 画出; 逐 bin 独立, ' ...
    '未做多重比较校正 => 整条曲线的联合覆盖率低于 95%%。两板的灰色误差棒同一口径 ' ...
    '(加权 Poisson 1σ; 右板由 d = y*f/yF 的线性缩放导出, 无新假设)。配色为 Okabe-Ito 色盲安全集。'], ...
    z95, nmin);
l3 = sprintf(['有效样本数 n_eff = %s (事件数 %d): 加权会把有效样本拉低, 不确定度按 ' ...
    'n_eff 而不是 N 读。归一口径: %s'], tepc.report.publishedNumber(S, 'effN'), A.nEvents, ...
    string(S.normalization_scope.note));
% 第 4 行是来源事实。缺来源时印 NOT_RECORDED 而不是留空: 让读者看见"这里没有来源",
% 比让他以为省略号后面还是同一个配置要诚实。
% 横须文案必须与"到底画没画"绑定: sigmaDBand 有多条不画的分支, 早先这里是无条件写的,
% 于是脚注会宣称一张没有须的图上有须 —— 那是图文不符。
% theta 也从常数注册表读, 不在产品文案里镜像字面量。
theta = polyaTheta();
% 核覆盖只从 summary 取当次运行的数; 取不到就印 NOT_RECORDED —— 既不印假数,
% 也不回退成任何抄写的历史值 (那样图上会显示一次别的运行的数而不说明)。
cCov = NaN;
if isfield(R, 'summary') && isstruct(R.summary) ...
        && isfield(R.summary, 'instrument_kernel_coverage')
    ccR = R.summary.instrument_kernel_coverage;
    if isnumeric(ccR) && isscalar(ccR) && isfinite(ccR)
        cCov = double(ccR);
    end
end
if isfinite(cCov)
    flCov = "";
    if isfield(R.summary, 'instrument_split_flag')
        flCov = string(R.summary.instrument_split_flag);
    end
    if flCov == "" || flCov == "ok"
        covTxt = sprintf('%.4f (取当次 summary.instrument_kernel_coverage)', cCov);
    else
        % 小样本下这个比值可以越出 (0,1)。印出来而不说旗标, 图上就会拿一个不是覆盖率的数
        % 自称覆盖率 —— 与"横须文案必须与画没画绑定"是同一类图文不符。
        covTxt = sprintf('%.4f 但旗标 %s: 比值已越出 (0,1), 这个数不可当覆盖率读', ...
            cCov, flCov);
    end
else
    covTxt = 'NOT_RECORDED (本次未发布逐事件拆分)';
end
if bandDrawn && isfinite(bandSd)
    bandTxt = sprintf(['红色横须 = y*sigma_m, sigma_m = %.4f, 取自已发布的 ' ...
        'summary.instr_res_fwhm_over_yF (= v)。v 就是 sigma_m^2: 由 buildSpectrum 的矩定义 ' ...
        'yD/yF = 1+CV^2, 乘性核 y_obs = y_truth*m 给出 1+v = (1+CV^2_obs)/(1+CV^2_truth), ' ...
        '故本带是乘性响应核的相对标准差 (名字里的 fwhm 是历史误称, 它不是 FWHM/y_F)。' ...
        '%s。注意它不等于"总新增展宽": 逐事件配对 (epsilon_meas 对 EdepGas) 实测总新增相对方差 ' ...
        '比 v 更大, 乘性核对本次总新增的覆盖 = %s; 差额来自仪器链的加性串联噪声、' ...
        'floor() 量化、按测量值截断, ' ...
        '以及 delta 与真值的正协变 —— 所以这条带子不得当电子学分辨率的实测证书, ' ...
        '也不覆盖非乘性那部分。横须只在逐 bin 计数 >= %d 处给出。'], ...
        bandSd, polyaNote(theta), covTxt, nmin);
else
    bandTxt = sprintf(['%s。评估响应展宽需先走完整仪器链并发布 ' ...
        'summary.instr_res_fwhm_over_yF。'], bandReason);
end
l4 = sprintf(['来源: 后端 %s (解析代理, 非蒙特卡罗输运, 非装置对表); 配置身份 %s; 场后端 %s; ' ...
    '电极拓扑 %s; 几何清单哈希 %s; 带 ASSUMED 标签的参数 %s 项。%s'], ...
    tepc.backendId(), ...
    shortHash(txtOf(R, {'summary','config_sha256'})), ...
    txtOf(R, {'resolve','field','mode'}), ...
    txtOf(R, {'summary','electrode_topology'}), ...
    shortHash(txtOf(R, {'summary','geometry_manifest_sha256'})), ...
    nAssumedOf(R), bandTxt);
% 成因分解也只印当次数: 取不到就印 NOT_RECORDED, 不镜像任何历史测值。
formTxt = 'NOT_RECORDED (本次未发布谱形成因分解)';
if isfield(R, 'summary') && isstruct(R.summary) ...
        && isfield(R.summary, 'form_tail_share_w')
    twF = R.summary.form_tail_share_w;
    if isnumeric(twF) && isscalar(twF) && isfinite(twF)
        formTxt = sprintf(['成因分解 (取当次 summary.form_*): 贡献最大的带 = %s, ' ...
            '它对 y_F 的贡献 = %.4f (= 该带权重份额 %.4f × 该带均值 ÷ y_F, 该带均值 = %.4g); ' ...
            '尾部带 (y >= 累计权重 99%% 分位) 权重份额 = %.4f, 低于 y_F 的权重份额 = %.4f; ' ...
            '排除类 %d 个 / 贡献带 %d 个; 旗标 %s。份额的分母是权重之和 ' ...
            '(不是 y_F, 也不是事件数); 切点取 y_F 与累计权重 90/99%% 分位, ' ...
            '所以"贡献最大的带"依赖切点位置, 它只回答"哪个区间扛住了这个数", ' ...
            '不构成任何物理机理归因。'], ...
            string(R.summary.form_top_contrib_class), ...
            double(R.summary.form_top_contrib_over_yF), ...
            double(R.summary.form_top_share_w), double(R.summary.form_top_band_mean), ...
            double(twF), double(R.summary.form_bulk_share_w), ...
            double(R.summary.form_class_count_l1), double(R.summary.form_class_count_l2), ...
            string(R.summary.form_flag));
    end
end
l5 = sprintf('%s', formTxt);

% ---- 底部条带: 按真实换行数预留, 再按预留量决定画布高度 ----
% 段数不等于行数: 每段本身就是超过一行的长句, 只按 5 段预留会低估一倍以上, 脚注就会
% 顶穿坐标轴下沿、压在刻度数字与轴标签上。字宽按全角 (CJK) 1.00 倍字号、半角 0.55 倍
% 字号逐字符计, 得到行数的保守上界; 画布高度反过来服从脚注, 而不是让脚注服从画布。
% 本函数与主函数不同作用域, 画布尺寸与布局一律从 fig 取回, 不复制主函数的变量名。
fp0 = fig.Position;
figW = fp0(3); figH = fp0(4);
tlArr = findall(fig, 'Type', 'tiledlayout');   % 布局是 fig 的子对象, 不是 fig 的属性
footFs = 6.5;
pxPerPt = get(0, 'ScreenPixelsPerInch') / 72;
boxWPt  = 0.976 * figW / pxPerPt;
foot = {l1, l2, l3, l4, l5};
nLines = 0;
for kF = 1:numel(foot)
    cs = char(string(foot{kF}));
    wPt = (sum(cs > 127) * 1.00 + sum(cs <= 127) * 0.55) * footFs;
    nLines = nLines + max(1, ceil(wPt / boxWPt));
end
footBandPt = nLines * footFs * 1.45 + 6;      % 行距实测约 1.41, 取 1.45 且留白随行数放大
% 刻度数字与轴标签画在 tiledlayout 的 Position **之外**(下方), 只按布局底边预留不够:
% 34 pt 时逐像素量到脚注首行墨迹与轴标签末行墨迹只差约 5 px, 没有安全余量。
axisBandPt = 66;                              % 刻度行 + 轴标签行 + 与脚注的安全间隙
needPx = (footBandPt + axisBandPt) * pxPerPt;
figH2 = max(figH, round(needPx / 0.30));      % 脚注带最多占画布高度的 30%
set(fig, 'Position', [fp0(1) fp0(2) figW figH2]);
bottomFrac = min(0.45, needPx / figH2);
if ~isempty(tlArr)
    tlArr(1).Position = [0.040 bottomFrac 0.920 max(0.30, 1 - bottomFrac - 0.090)];
end
annotation(fig, 'textbox', [0.012 0.020 0.976 (footBandPt * pxPerPt) / figH2], ...
    'EdgeColor', 'none', 'LineStyle', 'none', 'FontSize', footFs, ...
    'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', ...
    'Color', [0.20 0.20 0.20], 'String', {l1; l2; l3; l4; l5});
% 这里试过把 Interpreter 设成 none 让字段名不被排版吃掉, 实测**反而把重叠判据打回缺陷态**:
% 同一张真跑图上墨迹行高从 15 px 变成 28 px, 轴文字带与脚注带之间的真空从 >=2 行高
% 塌到 11 px (0.39 行高), 也就是脚注自己两行并成一簇、并顶到轴文字下面。
% 标识符可读性 << 不重叠, 所以这条留作已知欠账: 要修字段名排版, 必须先把
% 预留行数的宽度模型与真实排版口径对齐 (模型按字符数算, 换解释器后两者不再同代)。
% 底沿内缩从 0.006 抬到 0.020: 实测 0.006 时最后一行脚注墨迹停在图高-2 px 处 (文字几乎贴画布
% 下沿), 与上方 74 px 的安全间隙相反, 下沿是零余量。抬到 0.020 后下沿留出一个行高以上的空白,
% 而脚注带上沿只上移约 0.014*figH (~11 px), 与轴标签的间隙仍远大于缺陷态的 7 px。
% 同一份文字也记到 figure 的 UserData 上: annotation 对象不进 findall(fig) 的遍历,
% 各版本/各图类型上能不能被读回来并不稳定 (实测 allchild 这条路两种图结果不同)。
% 判据要能核对图上的免责文字, 就得让它有一个与渲染无关的机读出口。
ud = fig.UserData;
if ~(isstruct(ud) && isscalar(ud))
    ud = struct();
end
ud.diagnosticFooter = [string(l1); string(l2); string(l3); string(l4); string(l5)];   % 行长度不同, 不能按 char 竖拼
% 把"我为脚注预留了几行"与字号一起发布出来: 判据要能拿**实测墨迹数出的行数**与这个预留值
% 相对账 (两者独立来源), 否则任何像素门限都得依赖导出分辨率, 换台机器就误红/误绿。
ud.diagnosticFooterReservedLines = nLines;
ud.diagnosticFooterFontSize = footFs;
fig.UserData = ud;
end

function v = polyaTheta()
% 极阿起伏的特征量只从常数注册表取 (avalanche.m / propagateMC.m 读的是同一个键);
% 在产品文案里镜像 "=8" 这类字面量会造成注册表改了、图上还写着旧数。
v = NaN;
try
    v = double(tepc.config.constants('detector.polya.theta'));
catch
end
if ~(isfinite(v) && v > 0)
    v = NaN;
end
end

function s = polyaNote(theta)
% theta 读不到时只说"同量级"而不编造数字。
if isfinite(theta)
    s = sprintf('且与 ASSUMED 雪崩起伏 1/sqrt(theta) = %.4f (theta = %.4g, 常数注册表) 同量级', ...
        1/sqrt(theta), theta);
else
    s = '且与雪崩统计涨落同量级 (theta 未能从常数注册表读到)';
end
end

function s = txtOf(R, path)
% 沿字段路径取文本; 任一级缺失、为空或不是标量都回 NOT_RECORDED。
s = "NOT_RECORDED";
try
    x = R;
    for i = 1:numel(path)
        if ~isstruct(x) || ~isfield(x, path{i}), return; end
        x = x.(path{i});
    end
    t = string(x);
    if ~isempty(t) && strlength(t(1)) > 0
        s = t(1);
    end
catch
end
end

function s = shortHash(t)
% 64 位十六进制在脚注里读不出来, 取前 16 位足够对回 summary.json 的全值。
s = t;
if strlength(t) > 16
    s = extractBefore(t, 17);
end
end

function s = nAssumedOf(R)
% 直接问 statusScan, 不在这里复制它的判据。
s = "-";
try
    if isstruct(R) && isfield(R, 'cfg') && isstruct(R.cfg)
        T = tepc.config.statusScan(R.cfg);
        s = string(sum(string(T.status) == "ASSUMED"));
    end
catch
end
end

function [drawn, reason, sd] = sigmaDBand(ax, R, S, col, nmin)
% 乘性响应核的相对展宽 sigma_m (含雪崩统计), 不是"电子学分辨率"。
% sigma_m^2 只有一个来源: R.summary.instr_res_fwhm_over_yF (下面记作 v), 在 execute.m 里发布,
%   本函数不再自己从两条谱重推 —— 同一物理量有两份实现正是本项目在消灭的东西。
% 为什么 sd = sqrt(v) 是对的 (代数, 不是近似):
%   buildSpectrum 的矩定义给 yD/yF = E[y^2]/E[y]^2 = 1 + CV^2 (恒等式), 而发布式是
%   v = (yD/yF)_obs/(yD/yF)_truth - 1; 乘性核 y_obs = y_truth*m (E[m]=1, Var(m)=sigma_m^2,
%   m 与 y_truth 独立) 代入得 1 + CV^2_obs = (1 + CV^2_truth)(1 + sigma_m^2) => v = sigma_m^2。
%   近似的地方是**核模型本身**, 不是这条代数: 真实仪器链还含加性串联噪声、floor() 量化,
%   且按测量值截断, 所以"乘性核"只覆盖其中一份。
% 覆盖多少是实测问题, 数值只存在证据里 (源码不抄测量结果, 否则改了模型这里会留着不动):
%   登记表 D-17 的 kind=log 证据 docs/test_evidence/instrument_variance_split_20260927T1415Z.log
%   记着 v、按谱矩与按逐事件配对的总新增相对方差、以及两者的协方差差项;
%   乘性核只覆盖总新增的一部分, 其余是加性与截断效应。
% 该名字里的 fwhm 是历史误称 (它是方差比, 不是 FWHM/y_F): 不改名是因为基线快照对
%   summary 字段是单向包含, 删名会让"基线字段不再产出"判红; 只在文字里纠正读法。
% 只画在逐 bin 计数 >= nmin 处; 用**一个** Line 画 NaN 分隔横线而不是 Patch
%   (既有判据按 Patch 数量与顶点数区分"统计带画没画")。
drawn = false;  sd = NaN;  reason = "";
if ~isfield(R, 'summary') || ~isstruct(R.summary) ...
        || ~isfield(R.summary, 'instr_res_fwhm_over_yF')
    reason = "本图无横须: 未走仪器链, 没有已发布的展宽量";
    return;
end
v = double(R.summary.instr_res_fwhm_over_yF);
if ~isfinite(v)
    reason = "本图无横须: 展宽量非有限";
    return;
end
if v <= 0
    reason = sprintf('本图无横须: 反卷积结果 %.3g 非正, 那是口径问题不是零展宽', v);
    return;
end
sd = sqrt(v);
sel = isfinite(S.center) & isfinite(S.f) & (S.counts_raw >= nmin) & (S.center > 0);
if nnz(sel) < 3
    reason = sprintf('本图无横须: 计数 >= %d 的 bin 只有 %d 个, 宽度不可信', ...
        nmin, nnz(sel));
    return;
end
y = S.center(sel); h = y .* S.f(sel); w = sd * y;
n = numel(y);
X = nan(3, n);  Y = nan(3, n);
X(1,:) = (y - w).';  X(2,:) = (y + w).';
Y(1,:) = h.';        Y(2,:) = h.';
line(ax, 'XData', X(:), 'YData', Y(:), 'Color', col, 'LineWidth', 1.1, ...
    'HandleVisibility', 'off');
% gutters() 把 XLim 手工钉死, 最外侧 bin 的整条须会被裁掉 => 主动把可视域扩到须端,
% 否则图上"看得见须"的 bin 少于脚注声明的 bin 数, 是图文不符。
xl = ax.XLim;
ax.XLim = [min([xl(1), min(y - w)]), max([xl(2), max(y + w)])];
drawn = true;
reason = "";
end

function s = binText(S)
% 分箱口径一句话。缺 edges/dy 时**明说未登记**而不是留空: 合成谱 (测试夹具) 就没这些字段,
% 硬取会让整张图画不出来, 而"没登记分箱"本身才是该被读出来的事实。
if ~(isfield(S, 'edges') && isfield(S, 'dy') && numel(S.edges) > 1 && ~isempty(S.dy))
    s = '分箱: 未登记 (调用方没给 edges/dy)。';
    return;
end
dy = double(S.dy(:));
nb = numel(S.edges) - 1;
if max(dy) - min(dy) <= 1e-12 * max(abs(dy))
    kind = sprintf('等宽 %.4g', dy(1));
else
    kind = sprintf('不等宽 %.4g~%.4g', min(dy), max(dy));
end
s = sprintf('分箱: %d 个 bin, Δy %s keV/\\mum, y 域 [%.4g, %.4g]。', ...
    nb, kind, min(double(S.edges(:))), max(double(S.edges(:))));
end

function v = fieldNum(s, nm)
% 缺位或非有限一律给 0: 脚注是说明文字, 不该因为某个诊断量没登记而画不出图。
v = 0;
if isfield(s, nm) && ~isempty(s.(nm)) && isnumeric(s.(nm)) && isscalar(s.(nm)) ...
        && isfinite(s.(nm))
    v = double(s.(nm));
end
end
