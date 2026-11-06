function txt = doseLine(s, sep)
%DOSELINE 摘要/控制台/报告的剂量行 —— 每事件值、每历史值、累计值与宏观剂量分别标注。
%   分母口径 (逐个写清, 不靠读者推; 取值一律来自剂量链的分层诚实名):
%     D_gas_per_event_Gy        = sum(w_stat*eps)*J / m_gas / N        (每记录事件)
%     z_mean_per_history_Gy     = sum(w_stat*eps)*J / m_site / N_hist  (每初级历史, T2)
%     z_mean_given_valid_Gy     = 同上, 分母 = sum_valid w_stat (T2 条件口径)
%     累计 D_gas_Gy             = sum(w_stat*eps)*J / m_gas            (本次 N 事件的总和)
%     位点累计                  = z_mean_per_history_Gy * N_hist
%     D_macro_Gy                = k_norm * z_mean_per_history_Gy,
%                               k_norm = Phi[m^-2]*A_eff[m^2]*f_geo*p_int (无量纲)
%   显示纪律: 宏观剂量只在源归一链完整时出现; 链不完整时打印原因而不是数字。
%   动机 (显示层缺陷): GUI 剂量页与 workflows/run_demo 曾把**累计**剂量标成
%   "Gy/事件", N=10000 时读数错 4 个量级 (实测打印 1.367e+05 Gy/事件, 真每事件值 13.67)。
%   两处各自手写标签是该缺陷的根因, 因此全项目共用本函数。
%   旧名回退 (D_tissue_per_event_Gy / D_tissue_Gy) 只服务于"没有新名的历史调用方"
%   (固定构造体的显示层回归用例): 生产路径 (summary.json) 自执行链起就带新名,
%   回退分支一旦取到值会显式印出"旧名"字样, 不让兼容入口变成静默的第二真相源。
if nargin < 2, sep = ", "; end
txt = sprintf('D_gas %.3e Gy/事件%s累计 %.3e Gy', ...
    s.D_gas_per_event_Gy, sep, s.D_gas_Gy);
if isfield(s, 'z_mean_per_history_Gy') && ~isempty(s.z_mean_per_history_Gy)
    z = s.z_mean_per_history_Gy;
    nH = nHistOf(s);
    txt = [txt sprintf('%s位点 z(T2) %.3e Gy/历史', sep, z)];
    if isfinite(nH)
        txt = [txt sprintf('%s累计 %.3e Gy (N_hist=%g)', sep, z * nH, nH)];
    else
        txt = [txt sprintf('%s累计 无 N_hist, 不给累计值', sep)];
    end
elseif isfield(s, 'D_tissue_per_event_Gy') && isfield(s, 'D_tissue_Gy')
    % 旧名回退分支: 数值与新名逐位相同 (改名未改数值), 标签保留旧名并注明是旧名。
    txt = [txt sprintf('%sD_tissue(旧名=z_mean_per_history) %.3e Gy/事件%s累计 %.3e Gy', ...
        sep, s.D_tissue_per_event_Gy, sep, s.D_tissue_Gy)];
else
    txt = [txt sprintf('%s位点链字段缺失 (既无 z_mean_per_history_Gy 也无旧名): 不打印位点剂量', sep)];
end
if isfield(s, 'nEvents') && ~isempty(s.nEvents) && isfinite(s.nEvents)
    txt = [txt sprintf(' (N=%d)', s.nEvents)];
end
if isfield(s, 'z_mean_given_valid_Gy') && isnumeric(s.z_mean_given_valid_Gy) ...
        && isfinite(s.z_mean_given_valid_Gy)
    txt = [txt sprintf('%sz_mean_given_valid %.3e Gy/有效事件', sep, s.z_mean_given_valid_Gy)];
end
if isfield(s, 'D_macro_Gy') && isfinite(s.D_macro_Gy)
    txt = [txt sprintf('%sD_macro %.3e Gy (源归一已定义)', sep, s.D_macro_Gy)];
else
    r = "source_normalization_undefined";
    if isfield(s, 'D_macro_reason')
        rs = string(s.D_macro_reason);
        if ~isempty(rs) && strlength(rs(1)) > 0
            r = rs(1);
        end
    end
    txt = [txt sprintf('%s宏观剂量: 不可用 (%s)', sep, char(r))];
end
end

function nH = nHistOf(s)
% 每历史口径的分母: 优先剂量链给的 nHistories, 退回记录事件数 nEvents (两者在未登记
% n_primary_histories 时同值, 见 doseChain 的 N_primary_histories_source)。
if isfield(s, 'nHistories') && ~isempty(s.nHistories) && isfinite(s.nHistories)
    nH = double(s.nHistories);
elseif isfield(s, 'nEvents') && ~isempty(s.nEvents) && isfinite(s.nEvents)
    nH = double(s.nEvents);
else
    nH = NaN;
end
end
