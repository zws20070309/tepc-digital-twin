function D = doseChain(ev, geom, cfg, rho_g, massGas_kg, Qfun, opts) %#ok<INUSL>
%DOSECHAIN 微剂量链: 统计权重 w_stat 与物理归一 k_norm 全程分离的三层实现。
%
% 分层 (每层的分子/分母与单位都写在这里, 同一个乘子不得跨层复用):
%   T1 条件分布 —— 只吃 w_stat。
%     本函数里的 T1 量只有 Qbar = sum(w_stat*y*Q(y))/sum(w_stat*y)。
%     f(y)/d(y)/yF/yD 在 tepc.analysis.buildSpectrum 里, 其直方权重同样只是 w_stat。
%     宏观归一 (注量/被照面积/接受度/作用概率) 一旦进入 T1, "给定一个事件它落在哪个
%     bin" 的条件分布就被源的强度扭曲 —— 那就不再是条件分布。
%   T2 每初级历史的位点比能量 (不需要源定义, 因此是可诚实发布的量):
%     z_mean_per_history_Gy = sum_i(w_stat_i*eps_i)*J_per_keV / (N_hist*m_site)
%       分子 = 本次全部历史在被考虑位点上的授予能之和 [J]
%       分母 = 初级历史数 N_hist [-] × 位点质量 m_site [kg]  ->  [J/kg] = Gy
%     它是"一次初级历史在该微位点沉积的平均比能量", 不是宏观照射剂量。
%     另给条件口径 z_mean_given_valid_Gy (分母 = sum_valid w_stat, 只覆盖有效事件):
%     两者之比 = N_hist 内有效份额, 零沉积/零权重历史正是差在那儿。
%   T3 宏观剂量 —— 只吃 k_norm:
%     D_macro_Gy = k_norm * z_mean_per_history_Gy
%     k_norm 由 tepc.analysis.sourceNormalization(cfg) 唯一给出: 它的四个因子是
%     cfg.source.fluence_m2 [m^-2] (注量 Phi)、source_area_m2 [m^2]、几何接受度 f_geo、
%     interaction_probability p_int (定义见该文件)。缺任一项时 k_norm = NaN, 于是
%     D_macro_Gy = NaN 且 D_macro_reason 说明缺哪一项 —— 绝不把缺位因子当 1
%     (那等于把演示值洗成看起来合法的 Gy)。
%
% 单位常数:
%   J_per_keV   = 1.602176634e-16 J/keV                  (CODATA 2018 精确值)
%   KeVUM_to_JM = 1.602176634e-10 (J/m)/(keV/um)
%
% 输入:
%   ev   : 事件 struct。统计权重列取 ev.w_stat, 无该列时取 ev.weight —— 事件契约里
%          weight 的语义就是 w_stat (统计权重), 不是物理归一。
%   opts : .eps_meas_keV  发布用授予能 [keV] (缺省退回真值)
%          .w_stat        覆盖 ev 里的统计权重 (必须逐事件, 长度 = 事件数)
%          .w_stat_pub    发布口径统计权重 (死时间/反演失败已在此清零)
%          .weight_pub    兼容名 = w_stat_pub (现有测试与 +uq/propagateMC 仍在传)
%          .norm          tepc.analysis.sourceNormalization 的返回值
%          .h10, .E0_MeV  剂量当量响应 R_H 用 (h10 表单位必须是 Sv*m^2)
%   槽位防混淆判据 (w_stat 是逐事件向量, k_norm 是标量因子, 放错槽位必须报错):
%     opts.k_norm 出现             -> tepc:dose:KNormSlotRejected
%     opts.weight 出现 (旧名)      -> tepc:dose:LegacyWeightSlotRejected
%     opts.norm 不是该 struct      -> tepc:dose:NormSlotType
%     opts.w_stat 为标量而事件数>1 -> tepc:dose:WeightSlotMismatch
%   返回 D 按层给字段; D.legacy_fields 逐条列出仍保留的旧名、谁在读、正确名。

if nargin < 7, opts = struct(); end
if nargin < 6, Qfun = []; end
J_per_keV = 1.602176634e-16;                 % J/keV, CODATA 2018
KeVUM_to_JM = 1.602176634e-10;               % 1 keV/um = 1.602176634e-10 J/m

% ---------------- 权重槽位判据 ----------------
if isfield(opts, 'k_norm')
    error("tepc:dose:KNormSlotRejected", "%s", ['k_norm 不接受外部塞入的数值: 它只能由 ' ...
        'tepc.analysis.sourceNormalization(cfg) 从 (注量, 被照面积, 接受度, 作用概率) 显式' ...
        '链派生, 缺项即 NaN。把事件权重塞进这个槽位会让统计权重偷偷变成物理归一。']);
end
if isfield(opts, 'weight')
    error("tepc:dose:LegacyWeightSlotRejected", "%s", ...
        "opts.weight 已废: 统计权重请用 opts.w_stat / ev.w_stat (或事件里的 weight 列)");
end

ws = colv(statWeight(ev), 'w_stat');
if isfield(opts, 'w_stat') && ~isempty(opts.w_stat)
    ws = colv(opts.w_stat, 'opts.w_stat');
end
[wpub, hadPub, pubName] = pubWeight(ev, opts);
if ~hadPub
    wpub = ws;                               % 未给发布口径: 发布权重就是 w_stat 本身
    pubName = "w_stat";
end
if hadPubBoth(opts) && ~isequal(colv(opts.w_stat_pub,'w_stat_pub'), ...
        colv(opts.weight_pub,'weight_pub'))
    error("tepc:dose:WeightDoubleSource", "%s", ...
        "opts.w_stat_pub 与 opts.weight_pub 同时给出且不相等: 只允许一个发布权重源");
end

eps = colv(ev.EdepGas_keV, 'EdepGas_keV');
y   = colv(ev.y_keV_per_um, 'y_keV_per_um');
nEv = numel(eps);
% 标量塞进逐事件槽位 = 把全局归一因子当权重用的典型形状, 必须先于长度核对报出来
if isscalar(ws) && nEv > 1
    error("tepc:dose:WeightSlotMismatch", "%s", ...
        "w_stat 必须是逐事件向量: 标量权重与事件数不符 (标量因子属于 k_norm 槽位)");
end
if isscalar(wpub) && nEv > 1
    error("tepc:dose:WeightSlotMismatch", ...
        "%s 必须是逐事件向量: 标量权重与事件数 %d 不符 (标量因子属于 k_norm 槽位)", ...
        pubName, nEv);
end
if isscalar(y) && nEv > 1
    error("tepc:dose:WeightSlotMismatch", ...
        "y_keV_per_um 必须是逐事件列: 标量与事件数 %d 不符", nEv);
end
if numel(ws) ~= nEv
    error("tepc:dose:Length", "w_stat 长度 (%d) 必须与事件数 (%d) 一致", numel(ws), nEv);
end
if numel(wpub) ~= nEv
    error("tepc:dose:Length", "%s 长度 (%d) 必须与事件数 (%d) 一致", pubName, numel(wpub), nEv);
end
if numel(y) ~= nEv
    error("tepc:dose:Length", "y_keV_per_um 长度 (%d) 必须与事件数 (%d) 一致", numel(y), nEv);
end
if any(ws < 0) || any(~isfinite(ws)) || any(~isfinite(eps)) || any(eps < 0)
    error("tepc:dose:BadInput", "剂量链输入存在负值/NaN");
end
if any(wpub < 0) || any(~isfinite(wpub))
    error("tepc:dose:BadInput", "发布统计权重存在负值/NaN");
end

if isfield(opts, 'eps_meas_keV') && ~isempty(opts.eps_meas_keV)
    epsm = colv(opts.eps_meas_keV, 'eps_meas_keV');
    meas_src = true;
else
    epsm = eps;
    meas_src = false;
end
if numel(epsm) ~= nEv
    error("tepc:dose:Length", "eps_meas 长度 (%d) 必须与事件数 (%d) 一致", numel(epsm), nEv);
end
if any(epsm < 0) || any(isnan(epsm))
    error("tepc:dose:BadInput", "发布用授予能存在 NaN/负值 (无效测量应置零权重)");
end

% ---------------- A 链 (气体, 真值沉积; 分母 = 气腔质量) ----------------
D_gas = sum(ws .* eps) * J_per_keV / massGas_kg;

% ---------------- B 链 (组织位点, 仪器反演授予能; 分母 = 位点质量) ----------------
if ~isfield(geom, 'site')
    error("tepc:dose:NoSite", "缺少 site 参数, 无法计算组织剂量链");
end
d_t     = geom.site.d_tissue_m;
rho_t   = geom.site.rho_tissue;
lbar_t  = geom.site.lbar_tissue_m;
m_t     = rho_t * pi * d_t^3 / 6;                % 球位点质量 [kg]
ok = isfinite(y) & y > 0 & wpub > 0;             % 有效事件掩码 (逐事件口径)
eps_t_keV = epsm;                                % 发布授予能即为该位点的授予能
D_t = sum(wpub(ok) .* eps_t_keV(ok)) * J_per_keV / m_t;
% 定义核对: 由 y 与位点几何出发的恒等式 (lbar_t=2d_t/3 且 m_t=rho_t*pi*d_t^3/6 时与
% B 链恒等), 捕获的是"位点定义/单位换算被改坏", 不是独立物理核对。
D_t_closed = 4 * KeVUM_to_JM * sum(wpub(ok).*y(ok)) / (pi * rho_t * d_t^2);

% ---------------- C 链: 品质因子 (T1, 只吃 w_stat) ----------------
if ~isempty(Qfun)
    Qy = Qfun(y(ok));
    if any(isnan(Qy))
        Qbar = NaN; Qnote = "Q(y) 域外/未配置, Qbar=NA";
    else
        Qbar = sum(wpub(ok).*y(ok).*Qy) / sum(wpub(ok).*y(ok));
        Qnote = "Q(y) 已配置(见 qualityFactor meta)";
    end
else
    Qbar = NaN; Qnote = "Q(y) 未配置, Qbar=NA (不擅自解释为法定剂量当量)";
end

% ---------------- T2: 每初级历史的位点比能量 ----------------
% N_hist: 每历史口径的分母。配置登记了 n_primary_histories 就用它 (并与记录历史数
% 核对), 否则用本次记录的历史数 nEv —— 一个历史可以产生 0 个记录事件, 两者不总相等。
N = normOf(cfg, opts, nEv);
N_hist = N.n_primary_histories;
histSrc = "n_recorded_histories";
if ~isnan(N_hist)
    if abs(N_hist - nEv) > 1e-9*max(N_hist, nEv)
        error("tepc:norm:HistoryMismatch", ...
            "n_primary_histories=%g 与本次记录历史数 %d 不等: 每历史口径无法成立", ...
            N_hist, nEv);
    end
    histSrc = "source.normalization.n_primary_histories";
else
    N_hist = nEv;
end
z_mean_per_history = D_t/N_hist;        % 分子与 B 链同一算法, 只做分母口径转换:
%   改名不许改数值 —— 若在此重写 sum(wpub(ok).*eps(ok))*J/m/N 会因浮点结合次序不同
%   而在末比特上偏离旧字段 (实测 N=800 时差 1 ulp), 那就不再是纯改名。
z_mean_gas_per_history = D_gas/N_hist;
zv = eps_t_keV(ok) * J_per_keV / m_t;              % 条件分布 (仅有效事件) [Gy]
wv = wpub(ok);
SWv = sum(wv);
z_mean_given_valid = sum(wv .* zv)/SWv;
z_var_given_valid  = sum(wv .* (zv - z_mean_given_valid).^2)/SWv;
% 加权均值的方差取一阶近似 Var(z_bar) = sum(w^2*(z-z_bar)^2)/SW^2 (频率权重口径)
z_sem_given_valid = sqrt(sum(wv.^2 .* (zv - z_mean_given_valid).^2))/SWv;
n_eff_stat = SWv^2/max(sum(wv.^2), realmin);
z_dist_convention = ["z_mean_per_history_Gy: 分母 = N_hist (含零沉积/零权重历史)", ...
    "z_mean_given_valid_Gy: 分母 = sum_valid w_stat (仅满足 y 有限>0 且 w_stat>0 的事件)", ...
    "权重按频率权重解释: 方差 = sum(w*(z-zbar)^2)/sum(w) (有偏二阶中心矩); " ...
    "标准误 = sqrt(sum(w^2*(z-zbar)^2))/sum(w); n_eff = SW^2/sum(w^2)"];

% ---------------- T3: 宏观剂量 (只吃 k_norm) ----------------
k_norm = N.k_norm;                                 % 无量纲记录事件数; 链不完整即 NaN
D_macro = k_norm * z_mean_per_history;             % [Gy] = [-] * [J/kg]
H_macro = D_macro * Qbar;                          % [Sv] = [Gy] * [-]

% ---------------- 响应 R_H: 需要 h10 表 + 完整源归一链 ----------------
R_H = NaN; Rnote = "h*(10) 未提供, R_H=NA";
if isfield(opts,'h10') && ~isempty(opts.h10) && isfield(opts,'E0_MeV')
    if ~isfinite(k_norm)
        Rnote = "源归一链不完整 (k_norm=NaN), R_H=NA: 响应分母里的注量不能单独成立";
    else
        h10 = interp1(opts.h10(:,1), opts.h10(:,2), opts.E0_MeV, 'linear');
        if isfinite(h10) && h10 > 0 && isfinite(N.phi_m2) && isfinite(H_macro) && H_macro > 0
            R_H = H_macro / (N.phi_m2 * h10);      % h10 表单位必须是 Sv*m^2
            Rnote = "R_H = H_macro/(Phi*h*(10,E0)); h10 表单位 Sv*m^2; 需完整源归一链";
        else
            Rnote = "h*(10) 在 E0 处非正/非有限, 或 H_macro 非正有限, R_H=NA";
        end
    end
end

% ---------------- 账本: 事件计数与归一状态 ----------------
n_valid    = nnz(ok);
n_zero_dep = nnz(y == 0 | eps_t_keV == 0);         % 零沉积 (与谱侧同一判据)
n_zero_w   = nnz(wpub == 0);                       % 统计权重被清零 (死时间/反演失败)
n_other_ex = nnz(~ok & wpub > 0);                  % 有权重但 y 非有限或 <=0
book = struct( ...
    'N_primary_histories', N_hist, ...
    'N_primary_histories_source', histSrc, ...
    'N_recorded_events', nEv, ...
    'N_valid', n_valid, ...
    'N_zero_deposition', n_zero_dep, ...
    'N_zero_stat_weight', n_zero_w, ...
    'N_excluded_other', n_other_ex, ...
    'valid_fraction', n_valid/max(nEv, 1), ...
    'zero_deposition_fraction', n_zero_dep/max(nEv, 1), ...
    'w_stat_sum_valid', SWv, ...
    'w_stat_sum_all', sum(wpub), ...
    'n_eff_stat', n_eff_stat, ...
    'k_norm', k_norm, ...
    'source_normalization_status', N.status, ...
    'source_normalization_reason', N.reason, ...
    'source_normalization_missing', N.missing);

legacy = ["D_tissue_Gy: N 事件累计的位点比能量 (名不副实的 Gy); 消费方 = execute.m 的 " ...
    "summary 旧名别名段, htmlReport.m 的位点链存在性判据, test_spectrum_dose.m " ...
    "-> 正确名 z_mean_per_history_Gy*N_hist (propagateMC.m 已改读新名)", ...
    "D_tissue_per_event_Gy: 正确名 z_mean_per_history_Gy (数值与本字段相同)", ...
    "D_tissue_closed_Gy: 定义核对式, 正确名 z_closed_per_history_Gy*N_hist", ...
    "H_micro_Sv: 现与 H_macro_Sv 同值 (T3 不产出即 NaN); 正确名 H_macro_Sv", ...
    "opts.weight_pub: 正确名 opts.w_stat_pub"];

D = struct();
% --- T2: 可诚实发布的每历史量 ---
D.z_mean_per_history_Gy   = z_mean_per_history;
D.z_mean_gas_per_history_Gy = z_mean_gas_per_history;
D.z_mean_given_valid_Gy   = z_mean_given_valid;
D.z_var_given_valid_Gy2   = z_var_given_valid;
D.z_sem_given_valid_Gy    = z_sem_given_valid;
D.z_closed_per_history_Gy = D_t_closed/N_hist;
D.z_dist_convention       = z_dist_convention;
D.n_eff_stat              = n_eff_stat;
D.histories_field_note    = "N_hist 的来源见 book.N_primary_histories_source";
% --- T3: 需要源定义才允许存在的量 ---
D.D_macro_Gy         = D_macro;
D.D_macro_scope      = "该微位点的累计平均比能量 (分母质量 = m_site); 非宏观质量上的平均剂量";
D.D_macro_reason     = N.reason;
D.D_macro_note       = ["D_macro_Gy = k_norm * z_mean_per_history_Gy", N.formula, N.note];
D.k_norm             = k_norm;
D.source_normalization = N;
D.H_macro_Sv         = H_macro;
% --- A/B/C 链与定义核对 (旧字段名, 见 D.legacy_fields) ---
D.D_gas_Gy             = D_gas;
D.D_tissue_Gy          = D_t;
D.D_tissue_closed_Gy   = D_t_closed;
D.D_gas_per_event_Gy   = D_gas/nEv;
D.D_tissue_per_event_Gy = D_t/nEv;
D.Qbar                 = Qbar;
D.Qnote                = Qnote;
D.H_micro_Sv           = H_macro;                 % T3 不产出即 NaN, 不再给放大值
D.R_H                  = R_H;
D.Rnote                = Rnote;
D.nEvents              = nEv;
D.nHistories           = N_hist;
D.meas_source          = meas_src;
D.massGas_kg           = massGas_kg;
D.massSite_kg          = m_t;
D.lbar_t_m             = lbar_t;
D.book                 = book;
D.dose_note = ["T2 z_mean_per_history_Gy: 分子 = sum(w_stat*eps) 换算成 [J], " ...
    "分母 = N_hist*m_site [kg]; 不含任何源强信息", ...
    sprintf("T3 D_macro_Gy 状态 = %s (reason = %s)", N.status, N.reason), ...
    "w_stat 是统计权重: 只进 T1 与 T2 的分子, 绝不进 k_norm", ...
    "旧名保留清单见 D.legacy_fields (消费方改完即可删)"];
D.legacy_fields = legacy;
D.norm_notes = ["A链: 真值沉积 sum(w_stat*eps)/m_gas, 为 N 事件累计量 (不对初级数二次归一)", ...
    "B链: 仪器反演授予能 sum(w_stat*eps_meas)/m_site, 与 A 数据源不同 => 可交叉核对", ...
    "B闭式: 位点几何定义与单位换算的恒等式核对 (非独立物理核对)", ...
    "C链: Qbar 逐事件剂量加权 (只用 w_stat), 不混用 w_R", ...
    "T3: k_norm 只乘在 z_mean_per_history_Gy 上, 不进任何分布/矩/比值"];
end

% ---------------- 本地取值 ----------------
function w = colv(x, nm)
% 列向量化 + 数值性检查; NaN/负值由调用方的 BadInput 判据统一报错。
if ~isnumeric(x) && ~islogical(x)
    error("tepc:dose:BadInput", "%s 必须是数值列, 实得 %s", nm, class(x));
end
w = double(x(:));
end

function w = statWeight(ev)
% 事件统计权重列: 优先 ev.w_stat, 退回 ev.weight (契约里 weight 的语义即 w_stat)。
if isfield(ev, 'w_stat')
    w = ev.w_stat;
elseif isfield(ev, 'weight')
    w = ev.weight;
else
    error("tepc:dose:NoWeight", "%s", ...
        "事件里既无 w_stat 也无 weight 列, 无法确定统计权重 w_stat");
end
end

function [src, had, nm] = pubWeight(ev, opts)
% 发布口径统计权重: 新名 w_stat_pub 优先, 其次兼容名 weight_pub, 再退回复用 ws。
src = []; had = false; nm = "w_stat_pub";
if isfield(opts, 'w_stat_pub') && ~isempty(opts.w_stat_pub)
    src = opts.w_stat_pub; had = true; nm = "w_stat_pub";
elseif isfield(opts, 'weight_pub') && ~isempty(opts.weight_pub)
    src = opts.weight_pub; had = true; nm = "weight_pub";
elseif isfield(ev, 'w_stat_pub') && ~isempty(ev.w_stat_pub)
    src = ev.w_stat_pub; had = true; nm = "ev.w_stat_pub";
end
end

function t = hadPubBoth(opts)
t = isfield(opts,'w_stat_pub') && ~isempty(opts.w_stat_pub) && ...
    isfield(opts,'weight_pub') && ~isempty(opts.weight_pub);
end

function M = normOf(cfg, opts, nEv)
% T3 归一 struct: 只接受 opts.norm (sourceNormalization 的返回值) 或从 cfg 现算。
if isfield(opts, 'norm') && ~isempty(opts.norm)
    x = opts.norm;
    if ~isstruct(x) || ~isscalar(x) || ~isfield(x,'status') || ~isfield(x,'k_norm')
        error("tepc:dose:NormSlotType", "%s", ['opts.norm 必须是 ' ...
            'tepc.analysis.sourceNormalization 的返回值 (含 status/k_norm 字段的标量 struct); ' ...
            '数值数组属于 w_stat 槽位, 不能塞进这里']);
    end
    M = x;
else
    M = tepc.analysis.sourceNormalization(cfg, nEv);
end
end
