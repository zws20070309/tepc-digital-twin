function txt = publishedNumber(s, key)
% 数值部分按字段表的格式产出; 取不到可打印的数时印显式标记, 不印出看起来合法的假数。
% 字符串会被 sprintf('%.2f', ...) 逐字符转码 (double("NA") = [78 65] 于是印出 '78.00'),
% 那是本仓库真出过的缺陷类别, 所以按类型/标量性/有限性三项一起判, 而不是只判"字段在不在"。
specs = tepc.report.publishedFieldSpecs();
i = find(string(specs(:, 1)) == string(key), 1);
if isempty(i)
    error('tepc:report:unknownField', 'publishedNumber: 字段表里没有 %s', key);
end
v = [];
prim = char(specs{i, 2});
alt = char(specs{i, 3});
if isfield(s, prim)
    v = s.(prim);
elseif ~isempty(alt) && isfield(s, alt)
    v = s.(alt);
end
if ~isfloat(v) || ~isscalar(v) || ~isfinite(v)
    txt = 'NOT_RECORDED';
    return;
end
txt = sprintf(specs{i, 5}, double(v) * double(specs{i, 4}));
end
