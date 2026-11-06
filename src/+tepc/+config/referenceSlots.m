function S = referenceSlots(varargin)
%REFERENCESLOTS 读取数据槽位清单 config/reference_slots.json (缺位状态的唯一真相源)。
%   S = referenceSlots()                 读默认清单
%   S = referenceSlots('Path', p)        读指定清单 (判据自身的合成用例用)
%
%   返回 S:
%     .path              清单绝对路径
%     .slots             结构体数组: id/status/grade/owner_capability/note, ABSENT 另带
%                        stand_in (0×1 结构体数组), PRESENT 另带 path/consumer/ref_id/rows
%     .ids               N×1 string, 全部槽位 id
%     .absentIds         M×1 string, 状态为 ABSENT 的 id
%     .allowedAux        string 数组 (可为空)
%     .unclaimedAnchors  string 数组 (可为空)
%     .raw               jsondecode 的原始结构体
%
%   本文件刻意不内联任何槽位 id: 清单是数据侧真相, 读取器只做结构与词表校验。
%   在本文件里写死某个 id 会让"缺位不得被当数据消费"那条判据把读取器自己也算成消费点。
%   同理 status 词表只有两个词, 直接内联 (两词不构成"词表", 无需从清单取)。
%
%   清单不参与配置身份: 本函数不读也不写 cfg, 调用方不得把它并 cfg ——
%   config_sha256 的身份是合并后的 cfg 结构体 (见 makeProvenance), 并进来会让
%   发货配置身份随清单文本改动而漂移。
%
%   缓存: 按 (路径, mtime, 字节数) 复用上次解析结果, 与 constants.m 同口径 ——
%   清单会被 GUI/报告/测试多处读, 每处重新 jsondecode 一份既慢又会造成
%   "同一份清单两个进程读出不同形状"的隐性分叉。

persistent cacheKey cacheVal
opt = struct('Path', '');
for i = 1:2:numel(varargin)
    nm = lower(string(varargin{i}));
    if ~isfield(opt, nm), error("tepc:config:UnknownSlotOpt", "未知选项 %s", char(varargin{i})); end
    opt.(nm) = varargin{i+1};
end

if opt.Path == ""
    p = fullfile(tepc.io.projectRoot(), 'config', 'reference_slots.json');
else
    p = char(opt.Path);
    if ~isabs(p), p = fullfile(tepc.io.projectRoot(), p); end
end
if ~isfile(p)
    error("tepc:config:SlotsFileMissing", "数据槽位清单不存在: %s", p);
end

d = dir(p);
key = sprintf('%s|%d|%s', p, d.bytes, datestr(d.date, 30));
if ~isempty(cacheKey) && strcmp(cacheKey, key)
    S = cacheVal; return
end

raw = jsondecode(fileread(p));
S = struct();
S.path = p;
S.raw = raw;
if ~isfield(raw, 'schema')
    error("tepc:config:SlotsSchema", "槽位清单缺 schema 字段: %s", p);
end
S.allowedAux = toStringVec(raw, 'allowed_aux_files');
S.unclaimedAnchors = toStringVec(raw, 'unclaimed_anchor_files');

if ~isfield(raw, 'slots')
    error("tepc:config:SlotsEmpty", "槽位清单里没有 slots 数组: %s", p);
end
js = raw.slots;
if ~isstruct(js)
    error("tepc:config:SlotsShape", "slots 必须是对象数组, 实得 %s", class(js));
end
n = numel(js);
slots = struct('id', {}, 'status', {}, 'grade', {}, 'owner_capability', {}, ...
    'note', {}, 'stand_in', {}, 'path', {}, 'consumer', {}, 'ref_id', {}, 'rows', {});
for k = 1:n
    e = js(k);
    need = {'id','status','grade','owner_capability'};
    for q = 1:numel(need)
        if ~isfield(e, need{q})
            error("tepc:config:SlotsField", "第 %d 条槽位缺字段 %s", k, need{q});
        end
    end
    id = strtrim(string(e.id));
    st = lower(strtrim(string(e.status)));
    if st ~= "absent" && st ~= "present"
        error("tepc:config:SlotsStatus", ...
            "槽位 %s 的 status=%s 非法 (只允许 PRESENT 或 ABSENT, 不猜默认值)", id, e.status);
    end
    one.id = char(id);
    one.status = char(st);
    one.grade = upper(strtrim(string(e.grade)));
    one.owner_capability = strtrim(string(e.owner_capability));
    one.note = fieldStr(e, 'note');
    one.stand_in = readStandIn(e, id);
    one.path = fieldStr(e, 'path');
    one.consumer = fieldStr(e, 'consumer');
    one.ref_id = fieldStr(e, 'ref_id');
    one.rows = fieldNum(e, 'rows');
    slots(end+1) = one; %#ok<AGROW>
end
S.slots = slots;
S.ids = string({slots.id})';
S.absentIds = S.ids(strcmp(string({slots.status})', "absent"));

% ---- 结构级校验 (与判据测试同源, 但放这里让任何调用方都不会拿到一份自相矛盾的清单) ----
if numel(unique(S.ids)) ~= numel(S.ids)
    error("tepc:config:SlotsDuplicateId", "槽位 id 有重复");
end
for k = 1:numel(slots)
    e = slots(k);
    if strcmp(e.status, "absent")
        bad = {};
        if e.path ~= "",        bad{end+1} = 'path';     end %#ok<AGROW>
        if e.consumer ~= "",    bad{end+1} = 'consumer'; end %#ok<AGROW>
        if e.ref_id ~= "",      bad{end+1} = 'ref_id';   end %#ok<AGROW>
        if ~isnan(e.rows),      bad{end+1} = 'rows';     end %#ok<AGROW>
        if ~isempty(bad)
            error("tepc:config:SlotsAbsentHasBody", ...
                'ABSENT 槽位 %s 不得带数据本体字段: %s (写着缺位却挂着文件 = 两份真相)', ...
                e.id, strjoin(bad, ', '));
        end
    else
        need = {'path','consumer','ref_id'};
        for q = 1:numel(need)
            v = e.(need{q});
            if isempty(string(v)) || string(v) == ""
                error("tepc:config:SlotsPresentMissing", ...
                    "PRESENT 槽位 %s 缺字段 %s", e.id, need{q});
            end
        end
        if isnan(e.rows)
            error("tepc:config:SlotsPresentMissing", "PRESENT 槽位 %s 缺 rows", e.id);
        end
        if ~isempty(e.stand_in)
            error("tepc:config:SlotsPresentStandIn", ...
                "PRESENT 槽位 %s 不应再有 stand_in (数据本体已就位, 占位值该退役)", e.id);
        end
    end
end

cacheKey = key; cacheVal = S;
end

function si = readStandIn(e, id)
% 空数组在 jsondecode 下会是 [] (double) 或 0×1, 单个对象会是标量 struct, 多个是 struct 数组;
% 统一成"结构体数组"再出去, 否则调用方要按条数分三种写法 —— 那正是清单改一行就崩的地方。
si = struct('config_key', {}, 'label_path', {}, 'expected_label', {}, ...
    'consumers', {}, 'consumer_note', {});
if ~isfield(e, 'stand_in'), return; end
v = e.stand_in;
if isempty(v), return; end
if ~isstruct(v)
    error("tepc:config:SlotsStandInShape", ...
        "槽位 %s 的 stand_in 必须是对象数组, 实得 %s", id, class(v));
end
for k = 1:numel(v)
    one.config_key     = reqStr(v(k), 'config_key', id);
    one.label_path     = reqStr(v(k), 'label_path', id);
    one.expected_label = reqStr(v(k), 'expected_label', id);
    one.consumers      = reqList(v(k), 'consumers', id);
    one.consumer_note  = fieldStr(v(k), 'consumer_note');
    si(end+1) = one; %#ok<AGROW>
end
end

function s = fieldStr(e, f)
if isfield(e, f), s = strtrim(string(e.(f))); else, s = ""; end
end

function s = reqStr(e, f, id)
s = fieldStr(e, f);
if s == "", error("tepc:config:SlotsStandInField", "槽位 %s 的 stand_in 缺 %s", id, f); end
s = char(s);
end

function c = reqList(e, f, id)
s = fieldStr(e, f);
if s == "", error("tepc:config:SlotsStandInField", "槽位 %s 的 stand_in 缺 %s", id, f); end
if iscell(s), c = string(s); else, c = string(s); end
if numel(c) == 1 && c(1) == "", error("tepc:config:SlotsStandInField", "槽位 %s 的 %s 为空", id, f); end
c = cellstr(c);
end

function n = fieldNum(e, f)
n = NaN;
if isfield(e, f) && ~isempty(e.(f)) && isnumeric(e.(f)) && numel(e.(f)) == 1
    n = double(e.(f));
end
end

function v = toStringVec(raw, f)
v = strings(0,1);
if ~isfield(raw, f) || isempty(raw.(f)), return; end
x = raw.(f);
if iscell(x), v = string(x(:))'; else, v = string(x); end
end

function t = isabs(p)
t = ~isempty(regexp(p, '^[A-Za-z]:[\\/]', 'once')) || ~isempty(regexp(p, '^\\\\', 'once')) ...
    || ~isempty(regexp(p, '^/', 'once'));
end
