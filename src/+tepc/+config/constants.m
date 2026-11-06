function out = constants(id, jpath)
%CONSTANTS 版本化常数注册表读取器 (docs/constants.json) —— 真相源是 JSON 文件本身。
%   v = tepc.config.constants(id)              常数值 (数值或逻辑标量)
%   T = tepc.config.constants()                整张表 (struct 数组, 字段同 JSON)
%       tepc.config.constants(id, jsonPath)    从指定 JSON 读取 —— 供测试证明"改文件即改值",
%                                              即代码里没有第二份镜像。
%
% 设计约束:
%   * 本函数不硬编码任何常数值; 每次解析都来自 JSON 文本。
%   * 仓库根由 tepc.io.projectRoot() 解析, 因此当前目录是 tests/、tests/unit 还是仓库根
%     都能工作。
%   * 持久缓存: 同一 (路径, mtime, 字节数) 只解析一次; 文件改动后自动重读, 所以
%     mutation 测试拿到的永远是盘上的值。
%   * 只登记散落的 ASSUMED/经验常数。CODATA 与 tepc.units.convert 的值刻意不进
%     注册表 (集中化它们是折腾, 不是收益)。
%
% 错误标识符:
%   tepc:config:ConstantsFileMissing  注册表不存在/不可读
%   tepc:config:ConstantsSchema       结构不合法 (缺字段 / 状态词表外 / const_id 重复)
%   tepc:config:UnknownConstant       id 未登记 (消息列出可用 id)

persistent cacheKey cacheIds cacheEntries
if nargin < 2, jpath = ''; end

% ---------- 定位注册表 ----------
if isempty(jpath)
    src = sprintf('项目根 %s', tepc.io.projectRoot());
    jpath = fullfile(tepc.io.projectRoot(), 'docs', 'constants.json');
else
    src = '调用方显式传入的路径';
end
jpath = char(string(jpath));
if ~isfile(jpath)
    error("tepc:config:ConstantsFileMissing", ...
        "常数注册表不存在: %s (%s; 期望 docs/constants.json 随仓库发货)", jpath, src);
end

% ---------- 缓存 (按 路径+mtime+大小 失效) ----------
di = dir(jpath);
key = sprintf('%s|%s|%d', jpath, di.date, di.bytes);
if isempty(cacheKey) || ~strcmp(cacheKey, key)
    [cacheIds, cacheEntries] = loadConstants(jpath);
    cacheKey = key;
end

% ---------- 出参 ----------
if nargin == 0
    out = cacheEntries;                                   % 整张表 (报告 ASSUMED 清单用)
    return
end
want = char(string(id));
k = find(strcmp(cacheIds, want), 1);
if isempty(k)
    shown = cacheIds(1:min(12, numel(cacheIds)));
    error("tepc:config:UnknownConstant", ...
        ['常数 ''%s'' 未登记在 %s。表里共 %d 项, 前 %d 项: %s。' ...
         '新增常数必须先在 docs/constants.json 登记 const_id/value/units/status/' ...
         'source_ref/used_by, 再由测试反装饰核对。'], ...
        want, jpath, numel(cacheIds), numel(shown), strjoin(shown, ', '));
end
out = cacheEntries(k).value;
if isempty(out)
    error("tepc:config:ConstantsSchema", ...
        "常数 ''%s'' 的 value 为空: 注册表条目不完整 (%s)", want, jpath);
end
end

% ======================= helpers =======================

function [ids, entries] = loadConstants(jpath)
%解析 + 校验注册表。返回 id 单元数组与条目 struct 数组。
% 注意: 必须显式按 UTF-8 读。本机 MATLAB 的默认字符集是 GBK, fileread 会把
% UTF-8 中文按双字节解码, 从而**吞掉紧随其后的换行/引节字节** —— 行号错位、
% 解析口径静默失效。
% 有界重试: 注册表可能在同一时刻被外部编辑器改写, 读到的是一份写到一半的字节流,
% 于是 jsondecode 报"不是合法 JSON"。实测过这种撕裂读: 一次套件里 11 个用例因此假红,
% 而事后用 node 解析同一个文件是合法 JSON。重试只吸收撕裂读 —— 文件真损坏时五次
% 全部失败, 仍然按 ConstantsSchema 抛错, 不会把坏数据放过去。
doc = [];
lastErr = [];
for attempt = 1:5
    raw = readTextUtf8(jpath);
    try
        doc = jsondecode(raw);
        break
    catch e
        lastErr = e;
        pause(0.2);
    end
end
if isempty(doc)
    error("tepc:config:ConstantsSchema", "注册表 %s 不是合法 JSON (重试 5 次仍失败): %s", ...
        jpath, lastErr.message);
end
if ~isstruct(doc) || ~isfield(doc, 'constants')
    error("tepc:config:ConstantsSchema", "注册表 %s 缺顶层 constants 数组", jpath);
end
if isfield(doc, 'schema') && ~emptyText(doc.schema)
    sch = char(string(doc.schema));
    if ~startsWith(sch, "tepc-constants")
        error("tepc:config:ConstantsSchema", ...
            "注册表 %s 的 schema=%s 不受支持 (期望 tepc-constants-vN)", jpath, sch);
    end
end
entries = doc.constants;
if ~isstruct(entries) || isempty(entries)
    error("tepc:config:ConstantsSchema", "注册表 %s 的 constants 为空或不是对象数组", jpath);
end
need = {'const_id','value','units','status','source_ref','revision','used_by','wired','note'};
ids = cell(1, numel(entries));
for i = 1:numel(entries)
    e = entries(i);
    miss = need(~isfield(e, need));
    if ~isempty(miss)
        error("tepc:config:ConstantsSchema", "注册表 %s 第 %d 条缺字段: %s", ...
            jpath, i, strjoin(miss, ','));
    end
    ids{i} = char(string(e.const_id));
    st = lower(char(string(e.status)));
    if ~any(st == ["assumed", "measured", "reference"])
        error("tepc:config:ConstantsSchema", ...
            "注册表 %s 第 %d 条 (%s) 的 status=%s 不在 {MEASURED,REFERENCE,ASSUMED} 内", ...
            jpath, i, ids{i}, char(string(e.status)));
    end
    v = e.value;
    if ~(isnumeric(v) || islogical(v)) || ~isscalar(v) || ~all(isfinite(v(:)))
        error("tepc:config:ConstantsSchema", ...
            "注册表 %s 第 %d 条 (%s) 的 value 必须是有限数值或逻辑标量", jpath, i, ids{i});
    end
    w = e.wired;
    if ~((islogical(w) || isNumericBool(w)) && isscalar(w))
        error("tepc:config:ConstantsSchema", ...
            "注册表 %s 第 %d 条 (%s) 的 wired 必须是 true/false", jpath, i, ids{i});
    end
    entries(i).wired = logical(w);
    if emptyText(e.note)
        error("tepc:config:ConstantsSchema", ...
            "注册表 %s 第 %d 条 (%s) 缺 note: 登记理由与去向必须写清", jpath, i, ids{i});
    end
end
if numel(unique(ids)) ~= numel(ids)
    error("tepc:config:ConstantsSchema", "注册表 %s 存在重复 const_id", jpath);
end
end

function tf = isNumericBool(x)
tf = isnumeric(x) && isscalar(x) && (x == 0 || x == 1);
end

function txt = readTextUtf8(f)
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0
    error("tepc:config:ConstantsFileMissing", "无法读取常数注册表: %s", f);
end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
txt = strrep(txt, sprintf('\r\n'), sprintf('\n'));
end

function tf = emptyText(x)
tf = isempty(x) || (isstring(x) && all(x(:) == "")) || (ischar(x) && isempty(x));
end
