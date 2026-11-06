function txt = publishedText(s, key)
% 显示文本 = 字段表格式的数值 + 单位。数值一律走 publishedNumber (含"取不到数"的标记)。
specs = tepc.report.publishedFieldSpecs();
i = find(string(specs(:, 1)) == string(key), 1);
if isempty(i)
    error('tepc:report:unknownField', 'publishedText: 字段表里没有 %s', key);
end
n = tepc.report.publishedNumber(s, key);
u = char(specs{i, 6});
if isempty(u) || strcmp(n, 'NOT_RECORDED')
    txt = n;
elseif u(1) == '%'
    txt = [n u];
else
    txt = [n ' ' u];
end
end
