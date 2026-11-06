function N = sourceNormalization(cfg, nHist)
%SOURCENORMALIZATION T3 归一因子 k_norm 的唯一算处: 缺项即 NaN, 绝不补 1。
%
%   乘子定义 (无量纲计数):
%     k_norm = Phi * A_eff * f_geo * p_int
%     Phi    [m^-2] cfg.source.fluence_m2                     : 时间积分注量
%     A_eff  [m^2]  cfg.source.normalization.source_area_m2   : 被照面积
%     f_geo  [-]    cfg.source.normalization.acceptance_fraction : 几何接受度;
%                   只给 solid_angle_sr 时按 f_geo = Omega/(2*pi) 折算,
%                   2*pi sr 即半空间立体角 (几何恒等式, 不是拟合参数)
%     p_int  [-]    cfg.source.normalization.interaction_probability :
%                   一个穿过 A_eff 的初级在敏感体积内产生被记录事件的概率
%   因此 k_norm 的含义是"整次照射在该位点上产生的记录事件数", 而
%     D_macro_Gy = k_norm * z_mean_per_history_Gy
%   分子 = 位点累计授予能 [J], 分母 = 位点质量 m_site [kg] —— 它是该微位点的
%   累计平均比能量, 不是任何器官/宏观质量上的平均。
%
%   n_primary_histories 不进 k_norm: <z_h> 是"每初级历史"的量, 其分母 (历史数)
%   由本函数与传入的 nHist 交叉核对, 不一致即报错 (静默接受会同时错两层)。
%
%   status 词表: "NOT_AVAILABLE" (缺省) | "REFERENCE" | "MEASURED"。
%   status 声明可用而任一因子缺位 -> 报错 (与 CONFIG_INVALID 同判据), 因为
%   "标了可用却拿默认 1 硬算"正是本函数要拦的那类错误。
%   输出 N: status/declared/k_norm/phi_m2/area_m2/geo_factor/geo_source/p_int/
%     n_primary_histories/missing[]/reason/formula/units/note。
%   错误标识符 (统一前缀 tepc:norm:): BadBlock (块不是标量结构体) / UnknownKey (键名
%   不在因子上) / GeoConflict (接受度与立体角不一致) / BadStatus (状态词表外) /
%   StatusMismatch (声明可用却缺因子) / BadFactor (非正) / BadRange (份额超过 1) /
%   HistoryMismatch (登记历史数与本次模拟数不等)。

if nargin < 2, nHist = NaN; end
NA = "NOT_AVAILABLE";
src = subOf(cfg, 'source');
nrm = checkNormBlock(src);

Phi  = numField(src, 'fluence_m2');
Aeff = numField(nrm, 'source_area_m2');
facc = numField(nrm, 'acceptance_fraction');
osr  = numField(nrm, 'solid_angle_sr');
pint = numField(nrm, 'interaction_probability');
npry = numField(nrm, 'n_primary_histories');

% --- 几何接受度: 两个来源同时存在且不一致时必须停 (不允许两份真相) ---
geo = NaN; geoSrc = "UNDEFINED";
if ~isnan(facc) && ~isnan(osr)
    conv = osr/(2*pi);
    if abs(conv - facc) > 1e-9*max(abs(facc), abs(conv))
        error("tepc:norm:GeoConflict", ...
            "acceptance_fraction=%.9g 与 solid_angle_sr/(2*pi)=%.9g 不一致, 必须只留一个", facc, conv);
    end
    geo = facc; geoSrc = "acceptance_fraction";
elseif ~isnan(facc)
    geo = facc; geoSrc = "acceptance_fraction";
elseif ~isnan(osr)
    geo = osr/(2*pi); geoSrc = "solid_angle_sr/(2*pi)";
end

% 缺项清单: 一次性按掩码取, 不用 end+1 增长 (AGROW 且难核对)
nms = ["source.fluence_m2", "source.normalization.source_area_m2", ...
    "source.normalization.acceptance_fraction|solid_angle_sr", ...
    "source.normalization.interaction_probability"];
vals = [Phi, Aeff, geo, pint];             % 缺失/非有限都已被 numField 归一为 NaN
missing = nms(~isfinite(vals));

declared = statusOf(nrm);
if declared ~= NA && declared ~= "ABSENT" && ~isempty(missing)
    error("tepc:norm:StatusMismatch", ...
        "source.normalization.status=%s 声明可用, 但这些因子缺位: %s —— 不得按 1 处理", ...
        declared, strjoin(missing, ", "));
end
% 符号判据按"因子只要给了就必须成立"来, 与 status 声明无关: 一个写成的 0 或负数在
% 今天不出数 (status 关着), 明天把 status 一翻就变成 k_norm=0 的静默零剂量。
% 缺位的正规写法是不写该键或给 null (numField 归一为 NaN), NaN 在这里不参与判定。
given = [Phi, Aeff, geo, pint];
if any(given == 0) || any(given < 0)
    msgBF = "源归一因子给了就必须为正: Phi=%g A_eff=%g f_geo=%g p_int=%g; " + ...
        "缺位的正规写法是不写该键或给 null, 不是填 0";
    error("tepc:norm:BadFactor", msgBF, Phi, Aeff, geo, pint);
end
% f_geo 与 p_int 是"份额"而不是量度, 上界由定义给出: 前者按半空间 2*pi sr 归一
% (f_geo = Omega/(2*pi) ∈ (0,1]), 后者是一个概率。上界不核的话, acceptance_fraction=5
% 会给出一个有限且看起来合理的 k_norm —— 那等于把几何放大偷偷当作归一因子用。
% 这里按"因子只要给了就必须成立"判, 与 status 声明无关: 现在是 NOT_AVAILABLE 不等于
% 将来有人把 status 翻成 REFERENCE 时它仍然是个错数。
if (~isnan(geo) && geo > 1) || (~isnan(pint) && pint > 1)
    % 跨行长句用 + 拼: ["a" "b"] 是横向拼接出的字符串**数组**, error 只接受标量消息。
    msgBR = "f_geo=%.9g 与 p_int=%.9g 都必须落在 (0,1] 内: f_geo 按本仓库口径以半空间 " + ...
        "2*pi sr 记为 1, p_int 是概率。要表达全空间源应当改折算分母 (4*pi), " + ...
        "而不是把 f_geo 写成 2";
    error("tepc:norm:BadRange", msgBR, geo, pint);
end

available = (declared == "REFERENCE" || declared == "MEASURED") && isempty(missing);
if available
    k = Phi*Aeff*geo*pint;
    reason = "";
else
    k = NaN;
    if isempty(missing)
        % 因子齐但 status 未声明可用: 仍然结构上不产出 (声明本身就是缺的一半)
        reason = "source_normalization_status_not_declared";
    else
        % 原因串里带上缺的是哪几个因子: N.missing 否则没有下游读者, 而报告层只显示
        % reason 这一个字段 —— 不点名就等于让读者自己去翻配置。
        reason = "source_normalization_undefined: 缺 " + strjoin(missing, ", ");
    end
end

% --- 历史数交叉核对 (nHist 由调用方从事件数给出; NaN 表示调用方未提供) ---
histNote = "未传入模拟历史数, 历史数一致性未核";
if ~isnan(nHist) && ~isnan(npry)
    if abs(npry - nHist) > 1e-9*max(npry, nHist)
        error("tepc:norm:HistoryMismatch", ...
            "source.normalization.n_primary_histories=%g 与本次模拟历史数 %g 不等", npry, nHist);
    end
    histNote = sprintf("n_primary_histories=%g 与本次模拟历史数一致", npry);
elseif isnan(npry)
    histNote = "n_primary_histories 未登记: <z_h> 的分母取本次模拟的记录历史数";
end

N = struct();
N.status            = ternary(available, "AVAILABLE", NA);
N.declared          = declared;
N.k_norm            = k;
N.phi_m2            = Phi;
N.area_m2           = Aeff;
N.geo_factor        = geo;
N.geo_source        = geoSrc;
N.p_int             = pint;
N.n_primary_histories = npry;
N.missing           = missing;
N.reason            = reason;
N.formula           = "k_norm = Phi[m^-2] * A_eff[m^2] * f_geo[-] * p_int[-] (无量纲记录事件数)";
N.units             = struct('phi_m2', "m^-2", 'area_m2', "m^2", 'geo_factor', "-", ...
    'p_int', "-", 'k_norm', "-");
N.note              = ["D_macro_Gy = k_norm * z_mean_per_history_Gy; 分母质量 = m_site (微位点), " ...
    "因此 T3 是该位点的累计平均比能量, 不是宏观质量上的平均剂量", ...
    "任一因子缺位 => k_norm=NaN 且 reason=source_normalization_undefined (不补 1)", ...
    histNote, ...
    sprintf("status 声明值 = %s", declared)];
end

% ---------------- 本地取值工具 ----------------
function nrm = checkNormBlock(src)
% 块形状与键名核: 畸形块不得与"整段缺席"同形, 拼错的键不得被静默忽略。
% JSON null / [] 就是"没有这个块" (发货配置允许整段不写)。注记键不放行: jsondecode
% 会把 _source 这类非法标识符改名成 x_source (实测), 所以放行 _ 前缀是死代码, 而真正
% 走到这里的注记键只会以 x_ 的形状出现 —— 一律按未知键拒掉, 不许当成缺位静默吞下。
nrm = subOf(src, 'normalization');
if ~isstruct(src) || ~isscalar(src) || ~isfield(src, 'normalization')
    return
end
raw = src.normalization;
if isempty(raw)
    return
end
if ~(isstruct(raw) && isscalar(raw))
    error("tepc:norm:BadBlock", ...
        "source.normalization 必须是标量结构体, 或整段缺席/null, 实得 %s —— 畸形块不得与缺块同形", ...
        class(raw));
end
known = ["status", "source_area_m2", "acceptance_fraction", "solid_angle_sr", ...
    "interaction_probability", "n_primary_histories"];
bad = setdiff(string(fieldnames(raw)), known);
if ~isempty(bad)
    % 跨行长句必须用 + 拼成标量: ["a" "b"] 是 1x2 字符串数组, error 会当场报
    % "消息标识符必须后跟...消息" 而把真正的诊断换成一个无关的报错。
    msg = "source.normalization 里有不认识的键: " + strjoin(bad, ", ") + ...
        " —— 已知键是 " + strjoin(known, ", ") + ...
        "; 拼错的因子会被当作缺位处理, k_norm 就此静默变 NaN; 本块也不收 _source 这类注记键 (jsondecode 会把它们改名成 x_source)";
    error("tepc:norm:UnknownKey", msg);
end
end

function s = subOf(parent, nm)
% 缺失/非结构一律返回空 struct: 后续 numField 即得 NaN, 不抛 "未定义字段"。
% isscalar 判据: s.field 在非纯量结构数组上是逗号分隔列表, 会让下游
% isfield/isempty 以 "输入参数太多" 的形式炸掉。
if isstruct(parent) && isscalar(parent) && isfield(parent, nm) && ...
        isstruct(parent.(nm)) && isscalar(parent.(nm))
    s = parent.(nm);
else
    s = struct();
end
end

function v = numField(s, nm)
% 取一个标量数值字段; 缺位/JSON null(missing)/空/非数值/非有限一律给 NaN。
% isempty 必须先判: JSON null 解出的是 missing 哨兵, 对它再套任何 is* 函数都会把
% missing 传下去, 从而在 if 里报"需要逻辑值"。
v = NaN;
if ~isstruct(s) || ~isscalar(s) || ~isfield(s, nm), return; end
x = s.(nm);
if isempty(x) || ~isnumeric(x) || ~isscalar(x) || ~isfinite(x), return; end
v = double(x);
end

function st = statusOf(nrm)
% status 词表校验: 未给 = ABSENT; 词表外一律报错, 不静默退回 NOT_AVAILABLE。
NA = "NOT_AVAILABLE";
if ~isstruct(nrm) || ~isscalar(nrm) || ~isfield(nrm, 'status')
    st = "ABSENT"; return;
end
x = nrm.status;
if iscell(x), x = x{1}; end
if ~(ischar(x) || isstring(x))
    error("tepc:norm:BadStatus", "source.normalization.status 必须是字符串, 实得 %s", class(x));
end
st = upper(strtrim(string(x)));
if ~(st == "NOT_AVAILABLE" || st == "REFERENCE" || st == "MEASURED")
    error("tepc:norm:BadStatus", ...
        "source.normalization.status=%s 不在词表 {NOT_AVAILABLE, REFERENCE, MEASURED} 内", st);
end
if st == NA, st = NA; end
end

function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end
