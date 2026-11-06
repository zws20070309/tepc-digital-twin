function T = statusScan(cfg)
%STATUSSCAN 扫描配置中所有带 status 标签的物理参数 -> 表(name,status,value,source)。
%   name 为点分路径且不含前导点; 无标签分支不产生行。
rows = scanStruct(cfg, '');
if isempty(rows)
    T = struct2table(struct('name',{}, 'status',{}, 'value',{}, 'source',{}));
else
    T = struct2table([rows{:}]);
end
end

function rows = scanStruct(s, prefix)
rows = {};
if ~isstruct(s), return; end
fn = fieldnames(s);
for i = 1:numel(fn)
    if isempty(prefix), nm = fn{i};
    else,               nm = sprintf("%s.%s", prefix, fn{i}); end
    v = s.(fn{i});
    if isstruct(v) && isfield(v,'status')
        rows{end+1} = struct('name', char(nm), 'status', char(string(v.status)), ...
            'value', extractValue(v), 'source', getf(v,'source')); %#ok<AGROW>
    elseif isstruct(v)
        sub = scanStruct(v, nm);
        rows = [rows, sub]; %#ok<AGROW>
    end
end
end

function val = extractValue(v)
val = NaN;
if isfield(v,'value')
    x = v.value;
    if ~isempty(x) && ~(ischar(x) || isstring(x)) && isscalar(x)
        val = double(x);
    end
end
end

function out = getf(s, f)
if isfield(s,f), out = char(string(s.(f))); else, out = ''; end
end
