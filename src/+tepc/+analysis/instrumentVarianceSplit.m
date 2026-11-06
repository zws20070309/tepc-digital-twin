function out = instrumentVarianceSplit(ev, v, cv2Truth, theta)
%INSTRUMENTVARIANCESPLIT 仪器链方差的逐事件配对拆分。
%   入参
%     ev        事件表 struct（合并后的 EventBatch.ev），需要字段
%                 EdepGas_keV      输运侧真沉积
%                 epsilon_meas_keV 仪器链反演授予能
%                 weight           发布权重（含死时间清零与测量有效性）
%     v         已发布的乘性核方差比 summary.instr_res_fwhm_over_yF。
%               **只作为入参透传**，本函数不从任何谱重算它 —— 该字段的生产者只有一处
%               （+run/execute 在真值谱存在时发布），这里再造一份就会出现两份 v。
%     cv2Truth  真值谱相对方差 = yD_truth/yF_truth - 1，由已发布的 summary 字段算出后传入
%     theta     Polya 形状参数（detector.polya.theta），雪崩份额的解析来源
%   出参（缺位一律 NaN，不给 0、不给假数；v 缺位是正常状态：未走仪器链的运行没有该字段）
%     sigmaM2        = v
%     addedSpectrum  = v*(1+cv2Truth)，乘性核代数下的总新增相对方差
%                      由 1+CV2_obs = (1+CV2_truth)(1+v) 与 CV2=yD/yF-1 直接推出
%     addedPaired    = var_w(eps_meas - eps_true) / mean_w(eps_true)^2，逐事件配对口径
%     addedVarDiff   = (var_w(eps_meas) - var_w(eps_true)) / mean_w(eps_true)^2
%     covPaired      = 2*cov_w(eps_true, eps_meas-eps_true) / mean_w(eps_true)^2
%     covCross       = addedVarDiff - addedPaired - covPaired
%                      两条独立求和算同一个量，应当几乎为 0。
%                      依据是恒等式 var(m) = var(t) + var(m-t) + 2*cov(t, m-t)：
%                      它判的是权重、单位与选择集是否自洽，不是判物理，
%                      所以越界说明实现有错，而不是说明模型破了。
%     avalancheShare = 1/theta（Polya 解析雪崩相对方差）
%     kernelCoverage = sigmaM2 / addedPaired（乘性核覆盖逐事件总新增的比例）
%     coverageFlag   缺位或越界的原因文本，正常时 'ok'
%     nPaired, nEvents
%   口径三条（都是选择，不是事实陈述，读结果前先对齐）：
%     * 配对样本按 weight > 0 **且真沉积 > 0** 筛过（死时间清零、无效测量与零沉积整条剔除），
%       所以逐事件口径的分母是 nPaired 而不是 nEvents；两个数都出参给出。
%       这一项不是可选的保守过滤：谱那一路本来就不收零沉积事件。
%     * wVarMean 给的是**总体型**加权方差（sum(w.*(x-mu).^2)，无有效样本数偏差修正），
%       与谱矩那一路同为总体型；若要和带偏差修正的估计器比，先换算。
%     * 三个"新增"量名字相近但口径不同（核代数 / 配对差 / 两方差之差），
%       把它们当同一个数会得出假的矛盾。

nEvents = numel(ev.EdepGas_keV(:));
t = double(ev.EdepGas_keV(:));
m = double(ev.epsilon_meas_keV(:));
w = double(ev.weight(:));
ok = isfinite(t) & isfinite(m) & isfinite(w) & (w > 0) & (t > 0);
% 选择集必须与产出 v 的那两条谱是**同一个事件群**: buildSpectrum 除 weight>0 还要求 y>0
% (y = t/lbar, lbar 是正标量, 所以 y>0 等价于 t>0), 零沉积必须在这里同样剔掉。
% 少了 t>0 这一项, addedPaired 的分母就比 v 的分母多出一群事件, 两个数从一开始不可比 ——
% 正是 buildSpectrum 与分箱审计反复守的那条不变量。
nPaired = nnz(ok);

out = struct('sigmaM2', NaN, 'addedSpectrum', NaN, 'addedPaired', NaN, ...
    'addedVarDiff', NaN, 'covPaired', NaN, 'covTerm', NaN, 'covCross', NaN, ...
    'avalancheShare', NaN, 'kernelCoverage', NaN, ...
    'coverageFlag', 'not-evaluated', 'nPaired', nPaired, 'nEvents', nEvents);
% 出参集合必须在**每条返回路径**上都完整: covTerm 早先只在 v 有效那一支才写入,
% 于是配对数不足时字段根本不存在, 生产路径按名字读它就抛 nonExistentField。

if nPaired < 2
    out.coverageFlag = 'insufficient-pairs';
    return;
end
wn = w(ok) / sum(w(ok));
tv = t(ok);
mv = m(ok);
dv = mv - tv;

[muT, s2T] = wVarMean(tv, wn);
[~,  s2M]  = wVarMean(mv, wn);
[muD, s2D] = wVarMean(dv, wn);
if ~(muT > 0)
    out.coverageFlag = 'nonpositive-mean';
    return;
end
den = muT^2;
out.addedPaired  = s2D / den;
out.addedVarDiff = (s2M - s2T) / den;
out.covPaired    = 2 * sum(wn .* (tv - muT) .* (dv - muD)) / den;
% 恒等式两路核对：var(m)-var(t)-var(m-t) 与 2cov(t, m-t) 是同一个量的两种算法
out.covCross = out.addedVarDiff - out.addedPaired - out.covPaired;
scale = max([abs(out.addedVarDiff), abs(out.addedPaired), abs(out.covPaired), eps]);
if abs(out.covCross) > 1e-11 * scale
    out.coverageFlag = sprintf('covariance-cross-mismatch(%.3e)', out.covCross);
end

if isfinite(v) && v >= 0 && isfinite(cv2Truth) && cv2Truth >= 0
    out.sigmaM2 = v;
    out.addedSpectrum = v * (1 + cv2Truth);
    % 配对口径与核代数口径之差是被测对象本身（加性噪声、量化、按测量值截断），
    % 相等反而意味着协变项为 0，那只在纯乘性核下成立
    out.covTerm = out.addedPaired - out.addedSpectrum;
    if abs(out.covTerm) <= 1e-15 * max(out.addedPaired, eps)
        out.coverageFlag = 'covariate-term-vanished';
    end
end
if isfinite(theta) && theta > 0
    out.avalancheShare = 1 / theta;
end
if isfinite(out.sigmaM2) && isfinite(out.addedPaired) && out.addedPaired > 0
    c = out.sigmaM2 / out.addedPaired;
    out.kernelCoverage = c;
    if ~(c > 0 && c < 1)
        out.coverageFlag = sprintf('coverage-out-of-range(%.6f)', c);
    end
elseif strcmp(out.coverageFlag, 'not-evaluated')
    out.coverageFlag = 'kernel-coverage-not-evaluated';
end
% 负方差只在值确实存在且为负时报错：v 缺位时 sigmaM2 是 NaN，
% 而 ~(NaN >= 0) 为真，旧写法会在"未走仪器链"这种正常运行下抛出误导性的不一致错误。
if (isfinite(out.sigmaM2) && out.sigmaM2 < 0) || out.addedPaired < 0
    error('tepc:analysis:InstrumentSplitInconsistent', ...
        '拆分结果出现负方差: sigmaM2=%g addedPaired=%g', out.sigmaM2, out.addedPaired);
end
if strcmp(out.coverageFlag, 'not-evaluated')
    out.coverageFlag = 'ok';
end
end

function [mu, v] = wVarMean(x, w)
mu = sum(w .* x);
v = sum(w .* (x - mu).^2);
end
