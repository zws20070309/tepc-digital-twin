function [e, defaulted, dec] = depthConflicts(cfg)
%DEPTHCONFLICTS 档位对每条旋钮的"生效值决定", validate 与 applyDepthTier 共用的一份判据。
%   [e, defaulted, dec] = depthConflicts(cfg)
%     e          生效档位在表里的条目 (uncertaintyDepthTiers 的原样返回);
%                显式写了但表里没有这个名字时返回 **空** —— 由调用方决定怎么报
%                (validate 要出 DEPTH_UNKNOWN 诊断, applyDepthTier 要抛错)。
%     defaulted  true = cfg 没写 run.uncertaintyDepth, 按默认档 standard 处理。
%     dec        结构体数组, 字段 path / tier_val / cfg_val / value / from:
%                  from='tier'             配置没给这条 -> 用档位值
%                  from='preset_eq'        配置给的值等于档位值, 或等于发货值 (standard 档
%                                          里这条的值, 表内它按定义就是发货值) -> 视同没表态,
%                                          仍用档位值
%                  from='preset_conflict'  配置给了既非档位值又非发货值的显式值 -> **保留配置值**,
%                                          档位这条不生效, 必须被说出来 (档位是预设不是权威)
%
%   为什么要有这个文件: 判据原先在 applyDepthTier 与 validate 里各写了一遍, 且两边并不等价
%   —— validate 会把"等于档位值"也放过, applyDepthTier 只比发货值; 于是 publish 档 +
%   显式 nSamples=128 这种组合, 一边记冲突一边不记, 产物上的 uncertainty_depth_conflicted
%   说的是"无"。默认档那一支更漏: validate 整段扫描挂在"键存在"上, 没写键的旧配置里
%   uq.nSamples=64 被保住却一条都不报。两处现在都调这里。
%
%   非标量/非数值的显式值 (例如 uq.enabled 写成字符串 "true") 按 preset_conflict 处理并保留
%   原值, 不在这里抛运行期错误: 这段代码跑在 run 目录建立之前, 裸抛会绕开全部状态记账。

dec = struct('path', {}, 'tier_val', {}, 'cfg_val', {}, 'value', {}, 'from', {});
e = [];
defaulted = true;
T = tepc.config.uncertaintyDepthTiers();
iStd = find(lower(T.ids) == "standard", 1);
if isempty(iStd)
    return
end
std = T.tiers(iStd);
% 键的存在性只在这里判一次: 旧写法把 isfield(cfg,'uncertaintyDepth') 与
% isfield(cfg.run,'uncertaintyDepth') 混过, 结果显式写了 publish 的配置会被当成默认档,
% 那是"档位被静默忽略"这一族缺陷本身。
hasKey = false;
if isfield(cfg, 'run') && ~isempty(cfg.run)
    hasKey = isfield(cfg.run, 'uncertaintyDepth') && ~isempty(cfg.run.uncertaintyDepth);
end
if hasKey
    want = lower(strtrim(string(cfg.run.uncertaintyDepth)));
    hit = find(lower(T.ids) == want, 1);
    if isempty(hit)
        return                       % 未知档名: 交调用方报错
    end
    e = T.tiers(hit);
    defaulted = false;
else
    e = std;
    defaulted = true;
end
for j = 1:numel(e.knobs)
    p = string(e.knobs(j).path);
    tv = e.knobs(j).value;
    % 逐字段赋值, 不用 struct('cfg_val', {}): 后者是 MATLAB 造 **0x0 结构数组** 的写法
    % ({}/空单元数组会让 struct 按单元的个数展开成空数组), 于是 row 是个 0x0 ——
    % "配置没给这条"那一支 dec(end+1)=row 变成静默 no-op (档位从此不生效),
    % "给了"那一支给 0x0 赋字段直接抛错。两种都是灾难, 且都发生在任何测试跑之前。
    row.path = char(p);
    row.tier_val = tv;
    row.cfg_val = [];
    row.value = tv;
    row.from = 'tier';
    [has, cv] = getPath(cfg, p);
    if has
        row.cfg_val = cv;
        sv = shippedOf(std, p);
        if sameAs(cv, tv) || (~isnan(sv) && sameAs(cv, sv))
            row.from = 'preset_eq';
            row.value = tv;
        else
            row.from = 'preset_conflict';
            row.value = cv;
        end
    end
    dec(end+1) = row;  %#ok<AGROW>
end
end

function s = shippedOf(stdTier, p)
% 发货参照值 = standard 档里这条路径的值 (表里它按定义就是发货值); 拿不到给 NaN。
s = NaN;
for j = 1:numel(stdTier.knobs)
    if string(stdTier.knobs(j).path) == string(p)
        v = stdTier.knobs(j).value;
        if isnumeric(v) || islogical(v)
            s = double(v);
        end
        return
    end
end
end

function tf = sameAs(a, b)
% 只在两边都是标量数值/逻辑时比数值; 其它形态一律判"不等" (调用方按冲突处理)。
tf = false;
if ~(isscalar(a) && (isnumeric(a) || islogical(a))) || ~(isscalar(b) && (isnumeric(b) || islogical(b)))
    return
end
af = double(a);
bf = double(b);
if isfinite(af) && isfinite(bf)
    tf = af == bf;
else
    tf = strcmp(mat2str(af), mat2str(bf));   % NaN 自己不等于自己, 按字面比
end
end

function [has, v] = getPath(cfg, p)
has = false;
v = [];
parts = strsplit(string(p), '.');
cur = cfg;
for k = 1:numel(parts)
    f = char(parts(k));
    if ~isstruct(cur) || ~isfield(cur, f)
        return
    end
    cur = cur.(f);
end
has = true;
v = cur;
end
