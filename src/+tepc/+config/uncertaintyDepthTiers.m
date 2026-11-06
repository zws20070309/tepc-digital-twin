function T = uncertaintyDepthTiers(varargin)
%UNCERTAINITYDEPTHTIERS 读取档位表 config/uncertainty_depth_tiers.json (唯一真相源)。
%   T = uncertaintyDepthTiers()                整表: .path .ids .tiers .raw
%   T = uncertaintyDepthTiers('Id', 'publish') 单档: .id .label .disclosure .knobs
%                                              .paths (N×1 string) .vector .table_path
%   T = uncertaintyDepthTiers('Path', p)       读指定表 (判据自身的合成用例用)
%
%   允许覆写哪些旋钮由代码侧的 tepc.config.uncertaintyDepthKnobs() 决定, 不来自本表:
%   白名单若写在表里, 表就能自证任何旋钮合法, "表里有而代码不读"的装饰档位会重演。
%   读取器也不内联档位 id、不猜默认档位 —— 缺省由调用方显式补并落进产物。
%
%   档位值不并回磁盘上的配置文件: 调用方在算配置身份之前把它写进 cfg, 这样
%   config_sha256 能区分不同档 (身份对象是 resolve 之前的 cfg)。
%
%   缓存按 (路径, 字节数, mtime) 复用, 与 constants.m / referenceSlots.m 同口径。

persistent cacheKey cacheVal
opt = struct('Id', '', 'Path', '');
for i = 1:2:numel(varargin)
    nm = string(varargin{i});
    if ~isfield(opt, nm), error("tepc:config:DepthOpt", "未知选项 %s", char(nm)); end
    opt.(char(nm)) = varargin{i+1};
end

if opt.Path == ""
    p = fullfile(tepc.io.projectRoot(), 'config', 'uncertainty_depth_tiers.json');
else
    p = char(opt.Path);
    if ~isabslocal(p), p = fullfile(tepc.io.projectRoot(), p); end
end
if ~isfile(p)
    error("tepc:config:DepthFileMissing", "档位表不存在: %s", p);
end

d = dir(p);
key = sprintf('%s|%d|%s', p, d.bytes, datestr(d.date, 30));
if ~isempty(cacheKey) && strcmp(cacheKey, key)
    full = cacheVal;
else
    full = parseTable(p);
    cacheKey = key; cacheVal = full;
end

if opt.Id == ""
    T = full;
    return
end
want = lower(strtrim(string(opt.Id)));
hit = find(lower(full.ids) == want, 1);
if isempty(hit)
    error("tepc:config:DepthUnknownTier", "未知档位 %s (可用: %s)", ...
        char(opt.Id), strjoin(cellstr(full.ids), ', '));
end
T = full.tiers(hit);
T.table_path = full.path;
end

function T = parseTable(p)
raw = jsondecode(fileread(p));
T = struct('path', p, 'tiers', makeTierProto(), 'ids', strings(0, 1), 'raw', raw);
if ~isfield(raw, 'schema')
    error("tepc:config:DepthSchema", "档位表缺 schema 字段: %s", p);
end
if ~isfield(raw, 'tiers') || ~isstruct(raw.tiers) || isempty(raw.tiers)
    error("tepc:config:DepthShape", "档位表必须有非空 tiers 对象数组: %s", p);
end
allow = tepc.config.uncertaintyDepthKnobs();
tiers = makeTierProto();
for k = 1:numel(raw.tiers)
    e = raw.tiers(k);
    need = {'id', 'label', 'knobs', 'disclosure'};
    for q = 1:numel(need)
        if ~isfield(e, need{q})
            error("tepc:config:DepthTierField", "第 %d 档缺字段 %s", k, need{q});
        end
        if ~strcmp(need{q}, 'knobs') && strtrim(string(e.(need{q}))) == ""
            error("tepc:config:DepthTierField", "第 %d 档字段 %s 为空", k, need{q});
        end
    end
    id = strtrim(string(e.id));
    one = parseKnobs(e.knobs, id, allow);
    one.id = char(id);
    one.label = char(strtrim(string(e.label)));
    one.disclosure = char(strtrim(string(e.disclosure)));
    if isfield(e, 'cost_ratio_measured') && ~isempty(e.cost_ratio_measured)
        one.cost_ratio_measured = e.cost_ratio_measured;
    end
    tiers(end+1) = one; %#ok<AGROW>
end
T.tiers = tiers;
T.ids = string({tiers.id})';
if numel(unique(lower(T.ids))) ~= numel(T.ids)
    error("tepc:config:DepthDuplicateId", "档位 id 有重复: %s", strjoin(cellstr(T.ids), ', '));
end
% 两档的生效旋钮向量相同 => 分档是空转: 解析期就拒, 不留到运行时靠人眼发现。
for a = 1:numel(tiers)
    for b = a+1:numel(tiers)
        if strcmp(tiers(a).vector, tiers(b).vector)
            error("tepc:config:DepthIndistinct", ...
                "档位 %s 与 %s 的生效旋钮向量完全相同: 这两档是同一份计算, 不是两档", ...
                tiers(a).id, tiers(b).id);
        end
    end
end
end

function proto = makeTierProto()
proto = struct('id', {}, 'label', {}, 'disclosure', {}, 'knobs', {}, ...
    'paths', {}, 'vector', {}, 'cost_ratio_measured', {}, 'table_path', {});
end

function one = parseKnobs(knobs, id, allow)
one = struct('id', '', 'label', '', 'disclosure', '', ...
    'knobs', struct('path', {}, 'value', {}), ...
    'paths', strings(0, 1), 'vector', '', 'cost_ratio_measured', [], 'table_path', '');
if isempty(knobs)
    % 必须先于 isstruct 判: jsondecode 把 "knobs": [] 解成 0×0 double,
    % 先判形状会让这一-情况报成 DepthKnobShape 而永远走不到 DepthKnobEmpty。
    error("tepc:config:DepthKnobEmpty", "档位 %s 一个旋钮都不设: 它不改变任何东西", id);
end
if ~isstruct(knobs)
    error("tepc:config:DepthKnobShape", ...
        "档位 %s 的 knobs 必须是 {path,value} 对象数组, 实得 %s", id, class(knobs));
end
vec = strings(0, 1);
for j = 1:numel(knobs)
    if ~isfield(knobs(j), 'path') || ~isfield(knobs(j), 'value')
        error("tepc:config:DepthKnobField", "档位 %s 第 %d 条 knob 缺 path 或 value", id, j);
    end
    pp = strtrim(string(knobs(j).path));
    if ~any(allow == pp)
        error("tepc:config:DepthKnobNotAllowed", ...
            "档位 %s 试图覆写 %s, 不在代码侧白名单里 (允许: %s)", ...
            id, pp, strjoin(cellstr(allow), ', '));
    end
    if any(one.paths == pp)
        error("tepc:config:DepthKnobDuplicate", "档位 %s 里 %s 出现两次", id, pp);
    end
    vv = knobs(j).value;
    if ~(isnumeric(vv) || islogical(vv)) || numel(vv) ~= 1
        error("tepc:config:DepthKnobValue", ...
            "档位 %s 的 %s 必须是数值或逻辑标量, 实得 %s", id, pp, class(vv));
    end
    one.knobs(end+1) = struct('path', char(pp), 'value', vv); %#ok<AGROW>
    one.paths(end+1) = pp; %#ok<AGROW>
    vec(end+1) = pp + "=" + fmtVal(vv); %#ok<AGROW>
end
one.vector = char(vecSort(vec, one.paths));
end

function out = vecSort(vec, paths)
% 向量按路径排序后拼值: 同一档把两个旋钮写反顺序也必须判成相同向量。
[~, ix] = sort(paths);
out = strjoin(cellstr(vec(ix)), ';');
end

function s = fmtVal(v)
if islogical(v)
    if v
        s = "true";
    else
        s = "false";
    end
else
    s = string(sprintf('%g', v));
end
end

function t = isabslocal(p)
t = ~isempty(regexp(p, '^[A-Za-z]:[\\/]', 'once')) || ~isempty(regexp(p, '^\\\\', 'once')) ...
    || ~isempty(regexp(p, '^/', 'once'));
end
