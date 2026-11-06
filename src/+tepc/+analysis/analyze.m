function [A, E] = analyze(E, cfg, R, Qfun, cal)
%ANALYZE 微剂量分析: 派生列 -> 谱(f/d)+精确矩 -> 剂量链 -> 标志汇总 -> 诊断量。
%   [A, E] = analyze(...) 同时返回补齐派生列的 EventBatch —— 调用方必须使用返回
%   值: EventBatch 是值类, 在函数内对 E 的写入不会回传给实参 (历史缺陷: events.h5
%   的 y/lbar 两列全 NaN)。
%   发布量 y = epsilon_meas/lbar_tissue (仪器反演授予能);
%   若无标定结构 cal 则退回真值并显式标注 instrument_chain=false;
%   y_track = epsilon/gasPath (轨迹诊断, 不作发布量)。

if nargin < 5, cal = []; end
F = tepc.domain.Flags();
lbar_t = R.lbar_tissue_um;
n = E.n;
ok = E.ev.EdepGas_keV > 0 & isfinite(E.ev.EdepGas_keV);
E.ev.lbar_tissue_um = repmat(lbar_t, n, 1);              % 常量列 -> 逐事件展开
y_truth = nan(n,1);
y_truth(ok) = E.ev.EdepGas_keV(ok)/lbar_t;

% --- 仪器反演授予能 (发布的是"被测量", 不是真值) ---
eps_meas = nan(n,1);  chain = false;  inv = false(n,1);
if ~isempty(cal) && isfield(E.ev,'adc_code')
    phys = struct('W_eV', cfg.gas.W_eV.value, 'G', R.G_mean);
    xc = tepc.electronics.extCode(E.ev.adc_code, E.ev.adc_range, ...
        cfg.electronics.adc.bits, cfg.electronics.adc.range2Gain);
    [eps_meas, infl] = tepc.calibration.adcToEnergy(xc, cal, phys);
    % 反演失败必须回写事件标志, 否则"权重被清零"在落盘数据里不可审计
    E.ev.flags = bitor(E.ev.flags, infl);
    bad = infl;
    if isfield(E.ev,'flags'), bad = bitor(bad, E.ev.flags); end
    inv = bitand(bad, bitor(F.UNDER_THRESHOLD, bitor(F.OVERFLOW_ADC, F.OUT_OF_RANGE))) > 0;
    eps_meas(inv) = NaN;
    chain = true;
end
E.ev.epsilon_meas_keV = eps_meas;
E.ev.y_keV_per_um = y_truth;             % 保留真值诊断列 (审计)
if chain
    E.ev.y_keV_per_um = eps_meas/lbar_t;
end

% 发布权重 w_stat_pub: 原有统计权重(含死时间清零) × 测量有效性; 直接回写 weight 列,
% 使"被剔除"这件事在落盘数据里可见 (否则门禁无法审计权重从何而来)。
% 这一列是**统计权重**, 只进条件分布与每历史分子; 宏观归一 k_norm 在 doseChain 里
% 由 sourceNormalization 单独派生, 二者不得互相顶替。
w_stat_pub = E.ev.weight(:);
if chain
    w_stat_pub(~isfinite(E.ev.y_keV_per_um)) = 0;
    E.ev.weight = w_stat_pub;
end

ytrack = nan(n,1);
haspath = ok & E.ev.gasPath_um > 0;
ytrack(haspath) = E.ev.EdepGas_keV(haspath)./E.ev.gasPath_um(haspath);

% 活时间: 被 DAQ 拒收的两类 (死时间 + 堆叠) 都不计入。若 pileup 保留权重而
% liveFrac 只算死时间, "观测率"与"谱账本"就会互相矛盾。
nRejected = nnz(bitand(E.ev.flags, bitor(F.DEADTIME_REJECTED, F.PILEUP)) > 0);
liveFrac = 1 - nRejected/max(n,1);

eps_pub = E.ev.EdepGas_keV;
if chain
    eps_pub = eps_meas;
    eps_pub(~isfinite(eps_pub)) = 0;      % 无效测量按零权重进入, 不贡献谱
end
S  = tepc.analysis.buildSpectrum(eps_pub, lbar_t, w_stat_pub, R.edges, struct('Qfun', Qfun));
% 另存一份**域内重归一**的谱 (∫f dy = 1)。上面那份的分母是"全部有效事件",
% 因此 ∫f dy = 1 - 阈下份额 - 超溢份额; 两版同时给出, 报告不必靠读者猜语义。
S_in = tepc.analysis.buildSpectrum(eps_pub, lbar_t, w_stat_pub, R.edges, ...
    struct('Qfun', Qfun, 'renormInRange', true));
St = [];
if chain
    % 真值谱必须在"同一可测量事件群"上构建, 否则阈值截断会被误读成刻度偏差
    same = isfinite(E.ev.epsilon_meas_keV) & E.ev.weight > 0;
    eps_t_same = E.ev.EdepGas_keV;  eps_t_same(~same) = 0;
    w_t = E.ev.weight;  w_t(~same) = 0;
    if any(same)
        St = tepc.analysis.buildSpectrum(eps_t_same, lbar_t, w_t, R.edges, struct());
    end
end

D = tepc.analysis.doseChain(E.ev, R.geom, cfg, R.rho_g, R.massGas_kg, Qfun, ...
    struct('E0_MeV', cfg.source.energy_MeV, 'eps_meas_keV', eps_pub, ...
           'w_stat_pub', w_stat_pub));

flags = E.ev.flags;
fc = struct();
fc.zeroDep       = nnz(bitand(flags, F.ZERO_DEP) > 0);
fc.underThr      = nnz(bitand(flags, F.UNDER_THRESHOLD) > 0);
fc.overflowADC   = nnz(bitand(flags, F.OVERFLOW_ADC) > 0);
fc.wallLoss      = nnz(bitand(flags, F.WALL_LOSS) > 0);
fc.escape        = nnz(bitand(flags, F.ESCAPE) > 0);
fc.pileup        = nnz(bitand(flags, F.PILEUP) > 0);
fc.shapeAnomaly  = nnz(bitand(flags, F.WAVEFORM_SHAPE) > 0);   % 波形形状异常审计标记
% 壁生次级的两条计数要分开: 作用点落在壁里的事件数, 和其中真的把能量送进气腔的那部分。
% 只报前者会让读者把"壁腿开了"读成"伽马能测了" —— 0.5 MeV 电子在 A-150 里的射程 1.57 mm
% 小于 3 mm 壁厚, 多数壁电子在到达气腔之前就被壁吸收 (实测 1472 个壁作用点里只有 97 个
% 在腔内留下沉积)。
wallF = bitand(flags, F.SECONDARY_FROM_WALL) > 0;
fc.wallSecondary      = nnz(wallF);
fc.wallSecondaryInGas = nnz(wallF & E.ev.EdepGas_keV(:) > 0);
fc.deadRejected  = nRejected;
fc.outOfRange    = nnz(bitand(flags, F.OUT_OF_RANGE) > 0);
fc.range2        = nnz(bitand(flags, F.RANGE2_ADC) > 0);

tmin = min(E.ev.t0_s(:)); tmax = max(E.ev.t0_s(:));
tspan = tmax - tmin;
if tspan <= 0
    tspan = n/max(cfg.source.rate_cps,eps);     % 单事件/退化时间轴: 用名义率兜底
end
A = struct('spectrum', S, 'spectrum_in', S_in, 'spectrum_truth', St, 'dose', D, 'flags', fc, ...
    'nEvents', n, 'liveFrac', liveFrac, ...
    't_obs_s', tspan, ...
    'y_track_keV_um', mean(ytrack(haspath), 'omitnan'), ...
    'lbar_tissue_um', lbar_t, ...
    'instrument_chain', chain, ...
    'n_deadRejected', nRejected, ...
    'n_meas_invalid', nnz(inv), ...
    'n_meas_valid', nnz(isfinite(E.ev.epsilon_meas_keV) & w_stat_pub > 0), ...
    'note', "发布量 y=epsilon_meas/lbar_tissue; 真值谱与 y_track 为诊断量");

% ---------------- 阈下截断的可见化 ----------------
% 发布矩与"真值谱"都建立在**同一**过阈且测量有效的事件群上 (上面 same 掩码), 所以阈值
% 造成的截断偏差在既有字段里是结构性看不见的: 两个数一起变小, 相减为零。
% 这里另给一份不加有效性掩码的全历史真值矩作对照, 并把偏差直接算出来发布。
eps_true = E.ev.EdepGas_keV(:);
y_true_all = eps_true / lbar_t;
ok_true = isfinite(y_true_all) & (y_true_all > 0);
A.n_truth_all = nnz(ok_true);
if any(ok_true)
    yt = y_true_all(ok_true);
    A.yF_truth_all_keV_um = mean(yt);
    A.yD_truth_all_keV_um = sum(yt.^2)/sum(yt);
else
    A.yF_truth_all_keV_um = NaN;
    A.yD_truth_all_keV_um = NaN;
end
A.published_moment_population = "过阈且测量有效的事件 (阈下事件按零权重排除)";
A.n_published_moments = A.n_meas_valid;
A.threshold_lost_count = fc.underThr;
A.threshold_lost_fraction = fc.underThr / max(n, 1);
if isfield(S, 'yF_exact') && isfinite(S.yF_exact) && isfinite(A.yF_truth_all_keV_um) && A.yF_truth_all_keV_um > 0
    A.threshold_truncation_bias_rel_yF = S.yF_exact / A.yF_truth_all_keV_um - 1;
    A.threshold_truncation_bias_rel_yD = S.yD_exact / A.yD_truth_all_keV_um - 1;
else
    A.threshold_truncation_bias_rel_yF = NaN;
    A.threshold_truncation_bias_rel_yD = NaN;
end

% ---------------- 谱形成因分解 ----------------
% 入选群逐字复用 buildSpectrum 的判据 (y 有限>0、权重>0、非零沉积):
% 分母若不是发布 y_F 自己那一群, 下面的贡献和就与已发布值无关。
y_all = eps_pub(:) / lbar_t;
w_all = w_stat_pub(:);
zd_all = (y_all == 0) | (eps_pub(:) == 0);
ok_pub = isfinite(y_all) & (y_all > 0) & isfinite(w_all) & (w_all > 0) & ~zd_all;

A.form_flag = 'ok';
A.form_class_count_l1 = 0;
A.form_class_count_l2 = 0;
A.form_share_w_sum = NaN;
A.form_resid_group = NaN;
A.form_resid_bands = NaN;
A.form_l1_uncovered = NaN;
A.form_n_below_yF = NaN;
A.form_n_above_q99w = NaN;
A.form_yF_exact = NaN;
A.form_yF_binned = NaN;
A.form_yF_binned_rel_diff = NaN;
A.form_q90w = NaN;
A.form_q99w = NaN;
A.form_tail_share_w = NaN;
A.form_bulk_share_w = NaN;
A.form_top_share_w = NaN;
A.form_top_band_mean = NaN;
A.form_top_contrib_over_yF = NaN;
A.form_top_contrib_class = "";
A.form_attribution = struct('level', {}, 'cls', {}, 'n', {}, 'share_n', {}, ...
    'weight', {}, 'share_w', {}, 'yF', {}, 'contrib', {});

fEv = flags(:);
wsum_all = sum(w_all);
% L1: 全体事件按"为什么没进发布谱"互斥穷尽 (first-match)。
l1def = {"dead_rejected",   bitand(fEv, bitor(F.DEADTIME_REJECTED, F.PILEUP)) > 0 & ~ok_pub; ...
         "out_of_range",    bitand(fEv, F.OUT_OF_RANGE) > 0 & ~ok_pub; ...
         "overflow_adc",    bitand(fEv, F.OVERFLOW_ADC) > 0 & ~ok_pub; ...
         "under_threshold", bitand(fEv, F.UNDER_THRESHOLD) > 0 & ~ok_pub; ...
         "zero_dep",        zd_all & ~ok_pub};
l1taken = false(n, 1);
for i = 1:size(l1def, 1)
    mk = l1def{i, 2} & ~l1taken;
    l1taken = l1taken | mk;
    if ~any(mk), continue; end
    A.form_class_count_l1 = A.form_class_count_l1 + 1;
    e = struct('level', "L1_exclusion", 'cls', l1def{i, 1}, 'n', nnz(mk), ...
        'share_n', nnz(mk)/n, 'weight', sum(w_all(mk)), ...
        'share_w', sum(w_all(mk))/max(wsum_all, eps(1)), 'yF', NaN, 'contrib', NaN);
    A.form_attribution(end + 1) = e; %#ok<AGROW>
end
% 排除类 + 发布群必须覆盖全部事件: 缺这一条时"某类一直没被置位"会静默少账。
A.form_l1_uncovered = n - (nnz(l1taken) + nnz(ok_pub));
A.form_attribution(end + 1) = struct('level', "L1_exclusion", 'cls', "published", ...
    'n', nnz(ok_pub), 'share_n', nnz(ok_pub)/n, 'weight', sum(w_all(ok_pub)), ...
    'share_w', sum(w_all(ok_pub))/max(wsum_all, eps(1)), 'yF', NaN, 'contrib', NaN);
A.form_class_count_l1 = A.form_class_count_l1 + 1;

np = nnz(ok_pub);
if np < 2
    A.form_flag = 'no-published-events';
else
    yp = y_all(ok_pub);
    wp = w_all(ok_pub);
    swp = sum(wp);
    yF_here = sum(wp .* yp) / swp;
    A.form_yF_exact = yF_here;
    A.form_yF_binned = S.yF_binned;
    % 两侧同群: 与 S.yF_exact 相减会把域外事件的权重当成"分箱误差" (见 buildSpectrum 说明),
    % 而继续用 S.yF_binned (f 的分母是全有效权重 SW) 则把 1-∫f dy 的丢失份额当成误差。
    % 分子侧取 analyze 上面另存的 S_in (renormInRange=true, 分母=SWin)。
    % 注: A.form_yF_binned 仍是发布谱 (非重归一) 的 binned 值, 与本判据不同群, 不要混用。
    A.form_yF_binned_rel_diff = abs(S_in.yF_binned - S.yF_exact_inRange) / max(abs(S.yF_exact_inRange), eps);
    % 群一致性: 与发布值自己比 (跨到 buildSpectrum 的精确矩)。
    A.form_resid_group = yF_here - S.yF_exact;
    % 带划分自身的一致性: 贡献和必须回到同一个 yF_here。两条互不吞并。
    [ys, ix] = sort(yp);
    ws = wp(ix);
    cw = cumsum(ws) / swp;
    A.form_q90w = ys(max(1, find(cw >= 0.90, 1)));
    A.form_q99w = ys(max(1, find(cw >= 0.99, 1)));
    if ~issorted([yF_here, A.form_q90w, A.form_q99w]) || A.form_q90w >= A.form_q99w
        A.form_flag = 'degenerate-quantiles';
    else
        band = strings(np, 1);
        band(yp < yF_here) = "below_yF";
        band(yp >= yF_here & yp < A.form_q90w) = "yF_to_q90";
        band(yp >= A.form_q90w & yp < A.form_q99w) = "q90_to_q99";
        band(yp >= A.form_q99w) = "above_q99";
        A.form_n_below_yF = nnz(yp < yF_here);
        A.form_n_above_q99w = nnz(yp >= A.form_q99w);
        cls = unique(band);
        shsum = 0;
        ctsum = 0;
        bestc = -inf;
        for i = 1:numel(cls)
            mk = band == cls(i);
            wk = sum(wp(mk));
            yk = sum(wp(mk) .* yp(mk)) / max(wk, eps(1));
            sh = wk / swp;
            ct = sh * yk;
            shsum = shsum + sh;
            ctsum = ctsum + ct;
            if ct > bestc
                bestc = ct;
                A.form_top_contrib_class = cls(i);
                A.form_top_share_w = sh;
                A.form_top_band_mean = yk;
            end
            if strcmp(cls(i), "above_q99"), A.form_tail_share_w = sh; end
            if strcmp(cls(i), "below_yF"),  A.form_bulk_share_w = sh;  end
            e = struct('level', "L2_shape", 'cls', cls(i), 'n', nnz(mk), ...
                'share_n', nnz(mk)/np, 'weight', wk, 'share_w', sh, 'yF', yk, 'contrib', ct);
            A.form_attribution(end + 1) = e; %#ok<AGROW>
        end
        A.form_class_count_l2 = numel(cls);
        A.form_share_w_sum = shsum;
        A.form_resid_bands = ctsum - yF_here;
        A.form_top_contrib_over_yF = bestc / yF_here;
        % 自检恒等式 (不是证据): 带划分穷尽 + 带均值按同权重归一 ⇒ Σshare=1 与
        % Σ(share×带均值)=yF 由定义望远镜相消, 只能抓"划分/群被改错", 不能佐证成因。
        % 可假的只有 form_l1_uncovered (数的是没被 L1 掩码覆盖的排除原因)。
    end
end
A.form_note = ["L1=为何没进发布谱(互斥穷尽, 含 published 类); " ...
    "L2=发布群内按累计权重分位的贡献带; 恒等式只对精确矩成立, 分箱矩另发 rel_diff"];

% ---------------- 核种道分解 (按核反应道标签的机理轴) ----------------
% 为什么是这条轴而不是"按反冲能量分带": 能量带在混合谱里对 y 几乎没有解释力
% (实测 R^2=0.62%, 带均值 20.21/19.44/15.32 —— 高反冲能径迹穿出气腔, 单位径迹长度
%  沉积反而下降, 于是非单调), 而道标签是逐事件的真值且三类均值差到 11 倍
% (同 seed 单核种腿 y_F: H 23.45 / C 3.63 / O 2.12)。反过来从能量推核种只有
% 单向纯度(高于碳上限必为氢), 所以这条轴必须有列才能算 —— 不是可选项。
% 分母与 L2 同一群、同一权重 (w_stat_pub), 因此贡献和应当回到同一个 yF_here。
A.chan_flag = 'ok';
A.chan_share_w_sum = NaN;
A.chan_resid_bands = NaN;
A.chan_uncovered = NaN;
A.chan_top_share_w = NaN;
A.chan_top_y_mean = NaN;
A.chan_top_contrib_over_yF = NaN;
A.chan_top_code = NaN;
A.chan_n_published = NaN;
A.chan_n_unlabelled = NaN;
A.chan_labelled_share_w = NaN;
A.chan_table = struct('code', {}, 'n', {}, 'share_w', {}, 'y_mean', {}, 'contrib', {});
if np < 2
    A.chan_flag = 'no-published-events';
else
    if ~isfield(E.ev, 'channelId')
        % 缺列的实际来路是**内存里手搓的事件批** (测试夹具): readEventsH5 对缺数据集是直接
        % 报错的, 旧产物走不到这里。缺列必须是看得见的缺位 —— 造一个全 0 的列会把"没有
        % 核种信息"伪装成"全是无道事件"。
        A.chan_flag = 'column-absent';
        A.chan_note = ["事件表没有 channelId 列 (早于该列的产物): 本解释放弃, " ...
            "标量字段留 NaN, 不伪造全零列"];
    else
    cidAll = E.ev.channelId(:);
    codes = [1 2 3 0];                    % 0=无核反应道 (光子/纯电子), 放最后兜底
    cidPub = cidAll(ok_pub);
    swp_ref = swp;                        % 与 L2 同一个分母
    shsum = 0; ctsum = 0; bestc = -inf; npLabelled = 0;
    for i = 1:numel(codes)
        mk = (cidPub == codes(i));
        if ~any(mk), continue; end
        wk = sum(wp(mk));
        yk = sum(wp(mk) .* yp(mk)) / max(wk, eps(1));
        sh = wk / swp_ref;
        ct = sh * yk;
        shsum = shsum + sh; ctsum = ctsum + ct;
        if codes(i) ~= 0, npLabelled = npLabelled + nnz(mk); end
        if ct > bestc
            bestc = ct; A.chan_top_code = codes(i);
            A.chan_top_share_w = sh; A.chan_top_y_mean = yk;
        end
        A.chan_table(end + 1) = struct('code', codes(i), 'n', nnz(mk), ...
            'share_w', sh, 'y_mean', yk, 'contrib', ct);
    end
    A.chan_n_published = np;
    A.chan_n_unlabelled = nnz(cidPub == 0);
    A.chan_labelled_share_w = sum(wp(cidPub ~= 0)) / swp_ref;
    A.chan_share_w_sum = shsum;
    A.chan_resid_bands = ctsum - yF_here;
    A.chan_top_contrib_over_yF = bestc / yF_here;
    % 唯一可假的覆盖量: 每个发布事件必须落在四个码之一 (列被压平/漏写会在这里露出来)
    A.chan_uncovered = np - sum([A.chan_table.n]);
    if A.chan_uncovered ~= 0
        A.chan_flag = 'uncovered-events';
    elseif A.chan_labelled_share_w == 0
        % 全 0 列是这一族最现实的失效 (漏写、被压平), 光数覆盖抓不到它:
        % 覆盖数仍为 0, 但 labelled_share_w=0、top_code=0。中子源下一条道都没有,
        % 不是物理结论, 是断线。
        A.chan_flag = 'unlabelled-only';
    end
    A.chan_note = ["码: 1=弹性H 2=弹性C 3=弹性O 0=无核反应道(光子/纯电子); " ...
        "share_w 的分母与 form_* 同一条 w_stat_pub, 故贡献和应回到同一个 y_F; " ...
        "混合场里 0 码非零不是缺陷, 是光子事件本来就没有核反应道"];
    end
end

% ---------------- 诚实账本 (剂量数字旁边必须跟着"多少个事件/多少权重换来的") ----------------
% N_primary : 每历史口径的分母 (来自源归一链登记的初级历史数, 未登记则=记录历史数)
% N_valid   : 满足 (y 有限>0 且 w_stat>0 且非零沉积) 的事件数
% 活度/拒收: 死时间与堆叠两类都不计入活时间
% 归一状态  : T3 是否可用; 不可用时 reason 指名缺哪一项 (绝不默认 1)
book = D.book;
book.live_fraction = liveFrac;
book.n_rejected = nRejected;
book.n_meas_valid = A.n_meas_valid;
book.n_meas_invalid = A.n_meas_invalid;
book.n_flag_zeroDep = fc.zeroDep;
book.spectrum_intFdy = S.intFdy;
book.spectrum_intDdy = S.intDdy;
A.bookkeeping = book;
A.N_primary = book.N_primary_histories;
A.N_valid = book.N_valid;
A.n_zero_deposition = book.N_zero_deposition;
A.z_mean_per_history_Gy = D.z_mean_per_history_Gy;
A.D_macro_Gy = D.D_macro_Gy;
A.k_norm = D.k_norm;
A.source_normalization_status = book.source_normalization_status;
A.source_normalization_reason = book.source_normalization_reason;
A.dose_note = D.dose_note;
end
