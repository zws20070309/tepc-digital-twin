function txt = canonicalJson(x, dropFields)
%CANONICALJSON 把结构体/单元/数值确定性地序列化成"内容寻址"的 JSON 文本。
%   为什么不用 jsonencode 直接哈希: jsonencode 按**结构体字段顺序**输出, 于是
%   内容相同、来源文件书写顺序不同的两份配置会得到不同哈希 —— 而 config_sha256
%   的用途正是"续跑守卫 + 产物身份"。本函数递归排序字段名, 因此
%     canonicalJson(shuffleFields(cfg)) == canonicalJson(cfg)
%   是硬性质 (单测锁定)。同时显式规定:
%     * 浮点 -> '%.17g' (可精确往返), 整值且 |v|<2^53 -> '%d' (避免 2000 写成 2000.0);
%     * 字符串用 jsonencode 逐标量转义 (统一 \\u 转义, 不受区域设置影响);
%     * 非有限数值 (NaN/Inf) 一律**报错**而不是悄悄写成 null —— 静默 null 化
%       正是本项目反复出现的"看起来合法其实无意义"那一类失效;
%     * dropFields 只用于剔除易变字段 (时间戳等), 由调用方显式列出。
if nargin < 2, dropFields = {}; end
txt = enc(x, cellstr(string(dropFields)));
end

function s = enc(v, drop)
if isempty(v)
    s = 'null';
elseif isstruct(v)
    if numel(v) > 1                       % 结构数组 -> 数组 (元素顺序即语义, 不排序)
        s = '[' + strjoin(string(cellfun(@(k) enc(v(k), drop), num2cell(1:numel(v)), ...
            'UniformOutput', false)), ',') + ']';
    else
        fn = fieldnames(v);
        keep = ~ismember(fn, drop);       % 剔除易变字段
        fn = fn(keep);
        if isempty(fn), s = '{}'; return; end
        [~, o] = sort(fn);                    % 字段名排序 = 内容寻址的关键
                                              % (元胞数组的 sort 不接受 'ascend' 选项)
        fn = fn(o);
        parts = cell(numel(fn), 1);
        for i = 1:numel(fn)
            parts{i} = escStr(fn{i}) + ':' + enc(v.(fn{i}), drop);
        end
        s = '{' + strjoin(string(parts), ',') + '}';
    end
elseif iscell(v)
    if numel(v) == 1 && ~iscell(v{1})
        s = enc(v{1}, drop);              % 1x1 cell 与其内容同义 (MATLAB 惯例)
    else
        s = '[' + strjoin(string(cellfun(@(k) enc(v{k}, drop), num2cell(1:numel(v)), ...
            'UniformOutput', false)), ',') + ']';
    end
elseif islogical(v)
    s = joinNum(cellfun(@(b) tern(b, 'true', 'false'), num2cell(v(:)), ...
        'UniformOutput', false));
elseif isnumeric(v)
    s = joinNum(cellfun(@fmtNum, num2cell(v(:)), 'UniformOutput', false));
elseif isstring(v) || ischar(v)
    if ischar(v), v = string(v); end
    if numel(v) == 1
        s = escStr(v(1));
    else
        s = '[' + strjoin(string(cellfun(@(x) escStr(x), num2cell(v(:)), 'UniformOutput', false)), ',') + ']';
    end
else
    error("tepc:io:CanonicalUnsupported", ...
        "canonicalJson 不支持 %s 类型 (要哈希的东西必须全部可确定性文本化)", class(v));
end
end

function out = joinNum(parts)
if numel(parts) == 1
    out = parts{1};
else
    out = '[' + strjoin(string(parts), ',') + ']';
end
end

function s = fmtNum(v)
if ~isfinite(v)
    error("tepc:io:CanonicalNonFinite", ...
        "配置哈希链里出现 NaN/Inf (值 %g): 拒绝而不是写成 null", v);
end
if v == floor(v) && abs(v) < 2^53
    s = sprintf('%d', v);
else
    s = sprintf('%.17g', v);       % 17 位十进制可精确往返 double
end
end

function s = escStr(str)
s = string(jsonencode(char(string(str))));   % 转义由 jsonencode 负责, 结果确定
end

function out = tern(c, a, b)
if c, out = string(a); else, out = string(b); end
end
