function [cfg, info] = applyDepthTier(cfg)
%APPLYDEPTHTIER 把档位表的生效值并进 cfg (在 validate 之后、算配置身份与 resolve 之前)。
%   [cfg2, info] = applyDepthTier(cfg)
%     info.id / info.label / info.disclosure  生效档位的身份文本 (来自表, 原样落产物)
%     info.defaulted  true = 本次没写 run.uncertaintyDepth, 由这里显式补的默认档
%     info.applied    N×1 结构体数组, 字段 path/value = 调用结束后 cfg 里的**生效值**
%     info.conflicts  N×1 结构体数组, 字段 path/tier_value/kept_value = 被用户显式值挡住的条目
%
%   语义 (关键, 别改回另一种): **档位是预设, 不是权威**。调用方给了既非档位值又非发货值的
%   显式值时, 那条值保留、档位不覆写它, 并记进 conflicts。理由: "把 cfg.uq.enabled 设成
%   false 让这次跑便宜点" 是合法用法, 静默改掉它正是本仓库一直在清的"配置项被抢/被静默
%   忽略"那一族缺陷; 而且无头运行里 warn 不落盘, 产物上看不出任何痕迹。反过来, 用户值等于
%   档位值或等于发货值时视同"没表态", 档位的值照常生效。
%
%   判据不在本文件里: 生效值与冲突记录都取自 tepc.config.depthConflicts —— validate 的
%   DEPTH_KNOB_OVERRIDDEN 调的是同一个函数。此前判据在两边各写一遍且并不等价 (validate 连
%   "等于档位值"也放过, 这里只比发货值), publish 档 + 显式 nSamples=128 会一边记冲突一边
%   不记; 默认档那一支更是整段跳过, 没写档名的旧配置里 uq.nSamples=64 被保住却一条都不报。
%
%   为什么"显式补默认档"而不是留空: 留空会让产物写着"档位: 未设", 而它其实就是一次
%   standard —— 说不清自己是什么档的产物, 与静默忽略同族。
%
%   顺序口径 (实测): execute 的次序是 applyRunArgs -> validate -> applyDepthTier ->
%   resolve -> cfgId。并档必须落在 validate **之后**、cfgId 之前:
%     * 落在 validate 之前, 拼错的档名会先被读取器抛成裸错误, 丢掉 DEPTH_UNKNOWN 这条
%       带级别与代码的诊断;
%     * 落在 cfgId 之后, config_sha256 对档位失明, 粗档就能冒充细档续跑。
%   并进来的值随 cfg 进身份与 config_resolved.json, 因此不需要第二份记录。

info = struct('id', '', 'label', '', 'disclosure', '', 'defaulted', false, ...
    'applied', struct('path', {}, 'value', {}), ...
    'conflicts', struct('path', {}, 'tier_value', {}, 'kept_value', {}));
[e, defaulted, dec] = tepc.config.depthConflicts(cfg);
if isempty(e)
    % 显式写了表里没有的名字。validate 会把它报成 DEPTH_UNKNOWN 诊断并让 execute 停在这一步;
    % 走到这里说明调用方绕过了 validate, 那就把错交回表的持有者抛 (错误码不在这里复制一份)。
    bad = '';
    if isfield(cfg, 'run') && ~isempty(cfg.run) && isfield(cfg.run, 'uncertaintyDepth')
        bad = char(string(cfg.run.uncertaintyDepth));
    end
    tepc.config.uncertaintyDepthTiers('Id', bad);
end
info.id = e.id;
info.label = e.label;
info.disclosure = e.disclosure;
info.defaulted = defaulted;

% 把生效档位名也规范化写回 cfg: 缺省补的 standard 与显式写的 standard 必须是同一份配置
% (同一 config_sha256、同一份 config_resolved.json), 否则产物上"没写档位"与"写了
% standard"看起来是两件事, 而 resume 守卫会把它们当成不同配置。
cfg = setNested(cfg, {'run', 'uncertaintyDepth'}, e.id);

for j = 1:numel(dec)
    parts = strsplit(string(dec(j).path), '.');
    cfg = setNested(cfg, parts, dec(j).value);
    info.applied(end+1) = struct('path', dec(j).path, 'value', dec(j).value);  %#ok<AGROW>
    if strcmp(dec(j).from, 'preset_conflict')
        info.conflicts(end+1) = struct('path', dec(j).path, ...
            'tier_value', dec(j).tier_val, 'kept_value', dec(j).cfg_val);  %#ok<AGROW>
    end
end
end

function cfg = setNested(cfg, parts, val)
if numel(parts) == 1
    cfg = setfield(cfg, char(parts{1}), val);
    return
end
head = char(parts{1});
if isfield(cfg, head)
    sub = setNested(cfg.(head), parts(2:end), val);
else
    % 中间层不存在时必须新建**空结构体**而不是复用父: 复用 cfg 会把整份配置复制进
    % 这一层, 再附带一个游离的顶层字段 —— 污染 config_sha256 与 config_resolved.json。
    sub = setNested(struct(), parts(2:end), val);
end
cfg = setfield(cfg, head, sub);
end
