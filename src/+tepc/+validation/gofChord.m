function out = gofChord(x, R_m, mode, varargin)
%GOFCHORD 弦长分布对闭式 CDF 的拟合优度检验: Kolmogorov-Smirnov + Anderson-Darling。
%
%   out = tepc.validation.gofChord(x, R_m, mode)
%   out = tepc.validation.gofChord(x, R_m, mode, 'MC', 400, 'Seed', 20260923, ...
%                                  'Alpha', 0.05, 'MaxN', 4000)
%
%   x     弦长样本 [m] (任意方向, 内部按列处理; 少于 3 个直接报错)
%   R_m   球半径 [m] (>0)
%   mode  "isotropic_external" 各向同性均匀直线场穿球 (输运链用的就是这个模式)
%         "internal_isotropic" 体内各向同性均匀源到边界的自由程
%   MC    参照复制数; Alpha 拒绝阈值; Seed 参照流的种子 (同种子同结果)
%   MaxN  KS/AD 用的最大子样量: 超过则定步长降采样 (均值仍用全样本, 见返回字段)
%
% 两条闭式 CDF (l = 弦长, t = l/(2R)):
%   isotropic_external:  撞击参数 b 在圆盘上面积均匀 => b = R*sqrt(u), l = 2*sqrt(R^2-b^2),
%                        于是 F(l) = t^2,          逆 F^-1(u) = 2R*sqrt(u)
%                        均值 4R/3 = Cauchy 4V/S (V=4/3 pi R^3, S=4 pi R^2)
%   internal_isotropic:  F(l) = 3l/(4R) - l^3/(16R^3) = 1.5t - 0.5t^3, 均值 3R/4
%                        逆 CDF 取三次方程 t^3 - 3t + 2u = 0 落在 [0,1] 的那一根,
%                        用三角解 t = 2cos(acos(-u)/3 - 2pi/3) (端点 u=0 -> t=0, u=1 -> t=1)
%   两条闭式不靠这里的推导取信: tests/unit/test_validation_gof_chord.m 用三条独立途径核它 ——
%   把 sampleChord 头注里的 pdf 数值积分回来比 CDF、逆 CDF 与 CDF 的往返、以及两种模式各自的
%   p 值校准 (同闭式反复抽样的拒绝率应贴着名义 alpha)。
%
% 为什么 p 值用同分布 MC 参照而不是查表:
%   KS/AD 的渐近式只在 n->inf 且**分布完全给定**时成立, 有限 n 的修正项本机无法复核;
%   这里零假设是简单假设 (CDF 里没有拟合参数), 所以可以直接按同一 CDF 抽样造参照分布,
%   p 值 = (1 + #{参照统计量 >= 观测}) / (1 + MC)。这条路的正确性是可测的:
%   拿"同一分布的另一批样本"喂进来, p 值必须近似均匀分布 (测试里查)。
%   参照抽样走上面的闭式逆 CDF, 不经过 sampleChord, 因此参照与"被测几何代码"无共用路径 ——
%   否则几何抽样器的错会被自己的参照抵消掉, 检不出来。
%
% 返回字段:
%   nInput/nUsed/stride   全样本量 / 进 KS-AD 的子样量 / 降采样步长
%   mode, R_m, alpha, mcReplicates, seed
%   ksStat, ksP          D_n 与 MC p 值
%   adStat, adP          A^2 与 MC p 值 (A^2 用 n 有限时的 Stephens 修正 A2*(1+0.75/n+2.25/n^2)
%                        只作为附加报告字段 adStatCorrected, **不**参与 p 值: p 值参照的是
%                        同一个未修正统计量, 修正在这里是多余的)
%   meanMeasured, meanExact, meanStdErr, meanZ   均值 3-sigma 口径 (用**全样本**, meanZ 超 3 即异常)
%   rejectKs, rejectAd, reject                 (p < Alpha)
%   cdfFormula, meanFormula                   报告用的闭式文本
%   clipEps               CDF 送入 log 前的截断值 (AD 统计量需要, 见下)
%   referenceSeedStream   流名+种子, 让第三方能重放参照分布

p = inputParser;
p.addParameter('MC', 400);
p.addParameter('Seed', 20260923);
p.addParameter('Alpha', 0.05);
p.addParameter('MaxN', 4000);
p.parse(varargin{:});
a = p.Results;
% 参数校验自己报错而不是让 inputParser 抛通用标识符: 调用方 (含测试) 需要能按
% tepc:validation:BadGoFOption 分辨"选项给错了"与"输入样本不合法"这两类完全不同的失败。
numOpt = ["MC", "Seed", "Alpha", "MaxN"];
for q = 1:numel(numOpt)
    v = a.(numOpt(q));
    if ~(isnumeric(v) && isscalar(v) && isfinite(v))
        error("tepc:validation:BadGoFOption", ...
            "%s 必须是有限数值标量, 实得 %s 类型", numOpt(q), class(v));
    end
end
if a.MC < 100
    error("tepc:validation:BadGoFOption", "MC 必须 >= 100 (p 值分辨率 1/(1+MC)), 实得 %d", a.MC);
end
if ~(a.Alpha > 0 && a.Alpha < 1)
    error("tepc:validation:BadGoFOption", "Alpha 必须落在 (0,1), 实得 %.6g", a.Alpha);
end
if a.MaxN < 3
    error("tepc:validation:BadGoFOption", "MaxN 必须 >= 3, 实得 %d", a.MaxN);
end
if a.Seed < 0
    error("tepc:validation:BadGoFOption", "Seed 必须 >= 0, 实得 %.6g", a.Seed);
end
if a.MC ~= round(a.MC) || a.MaxN ~= round(a.MaxN) || a.Seed ~= round(a.Seed)
    % 非整数会在 zeros/rand 深处炸成 MATLAB 的通用标识符, 或让 referenceSeedStream 的 %d 少报。
    error("tepc:validation:BadGoFOption", ...
        "MC/MaxN/Seed 必须是整数, 实得 %s / %s / %s", mat2str(a.MC), mat2str(a.MaxN), mat2str(a.Seed));
end

x = double(x(:));
R_m = double(R_m);
mode = lower(string(mode));
if ~(isfinite(R_m) && R_m > 0)
    error("tepc:validation:BadGoFSphereRadius", ...
        "球半径必须是正的有限数 (收到 %.6g [m]): CDF 与逆 CDF 都以它为标度", R_m);
end
if numel(x) < 3
    error("tepc:validation:BadGoFSample", ...
        "弦长样本至少要 3 个 (收到 %d 个): 少于 3 个时 D_n/A^2 无意义", numel(x));
end
if ~all(isfinite(x))
    % NaN 会被 sort 挤到末尾而 max 又跳过它: 统计量在更少的点上算, n 却按全样本给, p 值偏保守
    % 且没有任何地方报错 —— 非有限值必须在入口拒, 而不是靠事后检查。
    error("tepc:validation:BadGoFSample", ...
        "弦长样本含 %d 个非有限值: 排序会把它们堆到末尾, 有效样本量被静默缩小", nnz(~isfinite(x)));
end
if any(x < 0)
    % 外源模式的闭式是 (l/2R)^2, 负的 l 会给出同样合法的 F: 符号回归在这条 CDF 上是隐形的。
    error("tepc:validation:BadGoFSample", ...
        "弦长不能为负 (实得最小 %.6g m): 负值经 (l/2R)^2 会伪装成合法分布位置", min(x));
end
switch mode
    case "isotropic_external"
        cdf   = @(l) min(max((l ./ (2*R_m)).^2, 0), 1);
        icdf  = @(u) 2*R_m*sqrt(u);
        meanExact = 4/3 * R_m;
        cdfFormula = "F(l) = (l/(2R))^2, 0<=l<=2R";
        meanFormula = "均值 4R/3 = Cauchy 4V/S";
    case "internal_isotropic"
        cdf   = @(l) min(max(1.5*(l/(2*R_m)) - 0.5*(l/(2*R_m)).^3, 0), 1);
        % 三次方程 t^3 - 3t + 2u = 0 落在 [0,1] 的根是 t = 2*cos(acos(-u)/3 - 2*pi/3),
        % 而 l = 2R*t —— 系数 2 落在 cos 外面还是里面是完全不同的分布 (写成 2R*cos(...) 时
        % l 只有正确值的一半, F(l) 最大只到 0.686, 参照分布被整体换掉, 检验再也拒不掉任何
        % 样本却仍是"自洽"的 p 值)。这条由 tests/unit/test_validation_gof_chord.m 的内源
        % 校准用例实测拦 (缺陷态实测: 参照 D 中位 0.380 vs 正常 0.0139, p 恒为 1.0)。
        icdf  = @(u) min(4*R_m*cos(acos(-min(max(u,0),1))/3 - 2*pi/3), 2*R_m);
        meanExact = 3/4 * R_m;
        cdfFormula = "F(l) = 3l/(4R) - l^3/(16R^3), 0<=l<=2R";
        meanFormula = "均值 3R/4";
    otherwise
        error("tepc:validation:BadGoFMode", ...
            "mode 只能是 isotropic_external / internal_isotropic (收到 %s)", mode);
end

% --- 观测统计量 ---
% n 超过 MaxN 时定步长降采样: 参照要复制 MC 次, 每份都要排序, 成本按 n log n 增长。
% 弦长样本彼此可交换 (sampleChord 逐条独立), 所以定步长与随机子样同分布, 且不引入 RNG。
stride = max(1, ceil(numel(x)/a.MaxN));
xs = sort(x(1:stride:end));
n = numel(xs);
clipEps = eps(0.5);                       % ~1.1e-16: log(0) 会让 A^2 变 Inf
F = cdf(xs);
F = min(max(F, clipEps), 1 - clipEps);
i = (1:n).';
% 双侧 KS: D_n = max( max_i(F_i - (i-1)/n), max_i(i/n - F_i) ) —— 两个方向各取自己那一侧的
% 极值。下标错位方向写反就只剩被支配的那一项 (小样本下甚至会给出负的 D_n), 而参照一起跟着错,
% p 值照样"自洽", 所以这条要靠 D_n >= 0 的 tripwire 与一个可手算的小样本用例来守。
ksStat = max([max(F - (i-1)/n), max(i/n - F)]);
adStat = -n - (1/n)*sum((2*i - 1) .* (log(F) + log(1 - flipud(F))));
meanMeasured = mean(x);
meanStdErr = std(x)/sqrt(numel(x));

% --- 同分布参照 (分块以封住内存: 每块 mcChunk x n) ---
rs = RandStream('philox', 'Seed', a.Seed);
mcChunk = max(1, min(64, floor(2e6/max(n,1))));
refKs = zeros(a.MC, 1); refAd = zeros(a.MC, 1);
done = 0;
while done < a.MC
    k = min(mcChunk, a.MC - done);
    U = rand(rs, n, k);
    XR = icdf(U);
    FR = cdf(XR);
    FR = min(max(FR, clipEps), 1 - clipEps);
    FS = sort(FR, 1);                        % 参照与观测同一条统计量: 同样按升序 F 配 flipud
    for c = 1:k
        Fc = FS(:, c);
        dk = max([max(Fc - (i-1)/n), max(i/n - Fc)]);
        % AD 需要按升序排列后的 F 与 1-F 的反序配对, 所以这里用 Fc 与 flipud(Fc)
        ak = -n - (1/n)*sum((2*i - 1) .* (log(Fc) + log(1 - flipud(Fc))));
        refKs(done + c) = dk;
        refAd(done + c) = ak;
    end
    done = done + k;
end
ksP = (1 + nnz(refKs >= ksStat)) / (1 + a.MC);
adP = (1 + nnz(refAd >= adStat)) / (1 + a.MC);

out = struct();
out.nInput = numel(x);
out.nUsed = n;
out.stride = stride;
out.maxN = a.MaxN;
out.mode = char(mode);
out.R_m = R_m;
out.alpha = a.Alpha;
out.mcReplicates = a.MC;
out.seed = a.Seed;
out.ksStat = ksStat;         out.ksP = ksP;
out.adStat = adStat;         out.adP = adP;
out.adStatCorrected = adStat * (1 + 0.75/n + 2.25/n^2);
out.meanMeasured = meanMeasured;
out.meanExact = meanExact;
out.meanStdErr = meanStdErr;
out.meanZ = (meanMeasured - meanExact)/meanStdErr;
out.rejectKs = ksP < out.alpha;
out.rejectAd = adP < out.alpha;
out.reject = out.rejectKs || out.rejectAd;
out.cdfFormula = cdfFormula;
out.meanFormula = meanFormula;
out.clipEps = clipEps;
out.referenceSeedStream = sprintf("philox/Seed=%d/MC=%d/nUsed=%d/stride=%d", ...
    round(a.Seed), round(a.MC), n, stride);
out.nullType = "simple";     % CDF 无拟合参数 => 简单假设, 同分布参照才成立
end
