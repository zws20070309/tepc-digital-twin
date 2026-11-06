function S = buildSpectrum(epsilon_keV, lbar_um, w_stat, edges, opts)
%BUILDSPECTRUM 带权线能谱 f(y)/d(y) 与平均量 —— 只吃统计权重 w_stat。
%   输入:
%     epsilon_keV (:,1) 事件授予能 [keV], 非负
%     lbar_um     (1,1) 组织等效位点平均弦长 [um] (y = epsilon/lbar)
%     w_stat      (:,1) 统计权重 (抽样/方差缩减带来), 非负; 负权重视为输入错误直接拒绝
%     edges       (1,:) bin 边界 [keV/um], 严格递增
%     opts (可选):
%       Qfun        品质因子句柄 (默认 [])
%       renormInRange 是否把 f 重归一到入 bin 事件 (默认 false:
%                     p_j = sum_w_j/SW_all, 使 sum(f*dy) = 1 - 丢失份额,
%                     underflow/overflow 份额显式输出 —— 红线门禁可审计)
%   输出 S: 结构体, 含 bin 表、精确矩、n_eff、丢失份额等。
%
%   设计要点:
%   0) 这里出现的**唯一**乘子是 w_stat。物理归一因子 k_norm (= 注量×被照面积×接受度×
%      作用概率, 见 tepc.analysis.sourceNormalization) 不得进入本函数: f(y)/d(y)/yF/yD/
%      Qbar 全是"给定一个已记录事件"的条件量, 与源强无关。若把 k_norm 乘进来, 改
%      fluence_m2 就会连带改变谱形状, 条件分布就不再是条件分布。
%   1) yF/yD/Qbar 的"发布值"用逐事件精确矩(无分箱偏差);
%      binned 值仅作图与交叉核对, 二者差用于量化分箱误差。
%   2) f(y) 归一分母含全部有效事件权重; underflow/overflow 不入 bin 但计入
%      审计字段, 使丢失份额的敏感性可评估。
%   3) 每个 bin 保存 sum_w/sum_w2/sum_wy/sum_wy2, sigma_stat 用
%      加权 Poisson 近似 sigma_j = sqrt(sum_w2_j)/SW_all/dy_j。

if nargin < 5, opts = struct(); end
if ~isfield(opts,'Qfun'),         opts.Qfun = []; end
if ~isfield(opts,'renormInRange'),opts.renormInRange = false; end

argumentsCheck(epsilon_keV, lbar_um, w_stat, edges);

y = epsilon_keV(:) ./ lbar_um;
w_stat = w_stat(:);
if any(w_stat < 0)
    error("tepc:spectrum:NegativeWeight","存在负权重; 禁止直接处理");
end
if lbar_um <= 0 || ~isfinite(lbar_um)
    error("tepc:spectrum:BadLbar","lbar 必须>0 且有限");
end

n_all = numel(y);
zeroDep = y == 0 | epsilon_keV(:) == 0;      % 零沉积事件
ok = isfinite(y) & y > 0 & isfinite(w_stat) & w_stat > 0 & ~zeroDep;
yv = y(ok); wv = w_stat(ok);
SW = sum(wv);

[~, ~, bin] = histcounts(yv, edges);
nb = numel(edges) - 1;
inb = bin > 0;
bi = bin(inb);
wi = wv(inb); yi = yv(inb);

sum_w  = accumarray(bi, wi, [nb 1], @sum, 0);
sum_w2 = accumarray(bi, wi.^2, [nb 1], @sum, 0);
sum_wy = accumarray(bi, wi.*yi, [nb 1], @sum, 0);
sum_wy2= accumarray(bi, wi.*yi.^2, [nb 1], @sum, 0);
cnt    = accumarray(bi, ones(nnz(bi),1), [nb 1], @sum, 0);

dy = diff(edges(:));
if all(abs(diff(log(edges))) < 1e-9 * mean(abs(diff(log(edges)))))   % 对数 bin
    yc = sqrt(edges(1:end-1).*edges(2:end));
else
    yc = (edges(1:end-1) + edges(2:end))/2;
end
% 位点必须是**列**: 其余逐 bin 数组来自 accumarray(...,[nb 1]) 全是列, 而
% edges 的方向由调用方给 (config 里是行, 手搓用例常给列)。用 .' 转置会把"输入是行"
% 当成前提 —— 输入为列时 center 反而变行, 于是下游 center.*f 成 n×n 外积、
% yF_binned 形状翻转, 全程不报错。归一到列才对调用方的方向不敏感。
yc = yc(:);

SWin = sum(sum_w);
underW = sum(wv(yv <  edges(1)));
overW  = sum(wv(yv >   edges(end)));         % histcounts 末区间为闭, 等于末边界不入"超出"
underY = sum(wv(yv <  edges(1)) .* yv(yv < edges(1)));
overY  = sum(wv(yv >   edges(end)) .* yv(yv > edges(end)));
% 事件**个数** (不只权重): 报告只给权重时, 读者无法判断
% "∫f dy != 1" 是丢了 3 个事件还是丢了 30% 的权重, 也极易被误读成分箱 bug。
underN = nnz(yv <  edges(1));
overN  = nnz(yv >   edges(end));
inN    = nnz(inb);

if opts.renormInRange
    denom = SWin;  renormApplied = true;
else
    denom = SW;    renormApplied = false;
end
if denom <= 0
    % 给出可行动的诊断为裸错误: 常见原因是源在该温压下几乎不与气体作用
    % (如 1000 Pa 气体对 keV-MeV 光子的作用概率 ~1e-6), 需要增大事件数而非改代码。
    msg = sprintf(['有效事件权重总和为 0: 共 %d 个事件, 零沉积 %d 个, 阈下/域外后无剩余。' ...
        '若源类型为 mono_gamma/mixed, 请按作用截面估算所需事件数 ' ...
        '(N_needed ~ 目标可测事件数 / (1-exp(-mu*L))) 后调大 run.nEvents。'], ...
        numel(y), nnz(zeroDep));
    error("tepc:spectrum:NoWeight", "%s", msg);
end
p = sum_w ./ denom;
f = p ./ dy;
yF_bin = sum(yc .* p);
if yF_bin <= 0
    error("tepc:spectrum:EmptySpectrum","无有效事件落入正 y 域");
end
% 逐事件精确矩（发布值）
yF_exact = sum(wv.*yv)/SW;
yD_exact = sum(wv.*yv.^2)/sum(wv.*yv);

d = yc .* f / yF_exact;      % 以精确矩归一: int d dy = yF_binned/yF_exact != 1,
                             % 其偏离正是分箱误差的可审计度量
yD_bin = sum(yc .* d .* dy);
if ~isempty(opts.Qfun)
    Qy = opts.Qfun(yv);
    if any(isnan(Qy))
        Qbar = NaN; Qmissing = true;
    else
        Qbar = sum(wv.*yv.*Qy)/sum(wv.*yv); Qmissing = false;
    end
else
    Qbar = NaN; Qmissing = true;
end

sigma_f = (sqrt(sum_w2)/denom) ./ dy;        % 每bin密度统计不确定度(加权Poisson近似)
n_eff = SW^2 / max(sum(wv.^2), eps);         % 有效样本数: 分子分母同一事件群

S = struct();
S.edges = edges(:).';
S.center = yc; S.dy = dy(:);
S.counts_raw = cnt;                          % 未加权计数(histcounts 语义, 不含区间外)
S.sum_w = sum_w;
S.sum_w2 = sum_w2;
S.sum_wy = sum_wy;
S.sum_wy2 = sum_wy2;
S.counts_weight = sum_w;
S.f = f; S.d = d; S.p = p;
S.sigma_f = sigma_f;
S.yF_binned = yF_bin; S.yD_binned = yD_bin;
S.yF_exact = yF_exact; S.yD_exact = yD_exact;
% 分箱误差必须与**同一事件群**的精确矩比: yF_binned 只由入 bin 的事件构成,
% 而 yF_exact 含全部有效事件 (区间外/溢出的事件进分子不进 bin)。两者相减时,
% 一个落在 y 域外的大 y 事件就能贡献百分之几的"误差", 与 bin 数无关 (实测把
% nBins 从 120 加到 2400 该差值仍停在 3.7%), 于是这个量测的是溢出份额而不是离散误差。
% 下面两个是"只覆盖入 bin 事件"的精确矩, 与 yF_binned 同群, 相减才只剩中心点近似。
S.yF_exact_inRange = sum(sum_wy) / max(SWin, eps);
S.yD_exact_inRange = sum(sum_wy2) / max(sum(sum_wy), eps);
S.Qbar = Qbar; S.Qmissing = Qmissing;
S.SW_valid = SW; S.SW_inBins = SWin;
S.underflowWeight = underW; S.overflowWeight = overW;
S.underflowY = underY;      S.overflowY = overY;
S.zeroDepCount = nnz(zeroDep);
S.nEvents = n_all;
S.nEff = n_eff;
S.renormInRange = renormApplied;
% 归一化口径显式化: 精确矩 y_F/y_D 用**全部有效事件**, 直方 f/d 只覆盖
% 域内 bin —— 于是 ∫f dy = 1 - 阈下份额 - 超溢份额, 而不是 1。不写出来就会被当 bug。
S.normalization_scope = struct( ...
    'moments', "all_valid_events", ...
    'histogram', ternary(renormApplied, "in_range_bins_renormalized", "in_range_bins"), ...
    'exact_denominator', "SW_valid", ...
    'histogram_denominator', ternary(renormApplied, "SW_inBins", "SW_valid"), ...
    'note', "y_F/y_D 为全有效事件的权重矩; f(y)/d(y) 只在域内 bin 上给出, 因此 ∫f dy = 1 - 阈下 - 超溢");
S.counts_inRange = inN;
S.counts_underflow = underN;
S.counts_overflow = overN;
S.intFdy = sum(f.*dy);
S.intDdy = sum(d.*dy);
end

function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end

function argumentsCheck(epsilon_keV, lbar_um, w_stat, edges)
% 槽位形状判据: w_stat 必须与 epsilon 同长的列。标量塞在这里 = 把标量归一因子
% (k_norm 那一类) 当逐事件权重用的典型形状, 因此消息里指名正确去处。
if any(size(epsilon_keV,2) ~= 1) || any(size(w_stat,2) ~= 1)
    error("tepc:spectrum:Shape","epsilon 与 w_stat 必须是列向量");
end
if numel(epsilon_keV) ~= numel(w_stat)
    error("tepc:spectrum:Shape", ...
        ['epsilon 与 w_stat 长度不一致 (' num2str(numel(epsilon_keV)) ' vs ' ...
         num2str(numel(w_stat)) '); 标量归一因子属于 k_norm 槽位, 由 ' ...
         'tepc.analysis.sourceNormalization 给出, 不得用作直方权重']);
end
if any(~isfinite(epsilon_keV)) || any(epsilon_keV < 0)
    error("tepc:spectrum:BadEpsilon","epsilon 存在 NaN/Inf/负值(读取层应已拦截)");
end
if any(diff(edges) <= 0) || any(edges <= 0)
    error("tepc:spectrum:BadEdges","edges 必须严格递增且为正");
end
if ~isscalar(lbar_um)
    error("tepc:spectrum:BadLbar","lbar 必须为标量");
end
end
