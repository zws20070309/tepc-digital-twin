function tests = test_gate_layer_map
%TEST_GATE_LAYER_MAP 门禁六层从散文进代码之后, 它必须与 runGate 的实际门禁项同源。
%   tepc.validation.gateLayers 给出 门禁名 -> 层号 的映射。映射本身是可以编出来的, 所以
%   锁的每条都朝"对不上就红"的方向:
%     (1) 名字集合 == runGate.m 里 addItem 用到的去重名字集合 (两个方向都判: 新增门禁没登记
%         层号要红, 门禁删了还留着映射也要红);
%     (1b) 同一份名字集合还须等于 docs/counts.json 里发布的 gate_names —— 那是发布产物侧的
%         清单, 两边不一致说明登记表与产物分叉;
%     (2) 层号全在注册表 gate_layers 的键里, 不另起一套层;
%     (3) 六层每层至少一条门禁 (否则"六层"里有空层, 分层就成了装饰)。
%   两个已实测的语言坑, 写在这里免得下一个人重踩:
%     * 不用 tc.verifySetEquality —— functiontests 建的 FunctionTestCase 上没有这个方法
%       (实测报 MATLAB:noSuchMethodOrField; 同一结论见 tests/integration/
%       test_run_chunk_invariance.m:75 的注释), 所以这里全部用显式集合比较;
%     * 注册表的 gate_layers 键是 "1".."6", jsondecode 会把不能当字段名的键改名 (实测变成
%       x1..x6), 所以层号键**从文件文本正则取**, 不从 jsondecode 的字段名取。
%   文本一律按 UTF-8 读: fileread 走本机码页 (中文 Windows = GBK), 门禁名是中文, 码页错了
%   集合比较会整体失配 (表现成"全都缺", 而不是"个别不符")。
tests = functiontests(localfunctions);
end

function txt = readUtf8(p)
assert(isfile(p), '缺文件 %s', p);
fid = fopen(p, 'r', 'n', 'UTF-8');
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = string(b(:)');
end

function names = gateNamesInRunGate()
% 与 tools/genCounts.m 同一个正则口径 (只取 addItem(items, '名字') 的第一实参)。
% 刻意不另写一套解析: 两处解析不一样, counts.json 的门禁数与本锁就会各说各话。
p = fullfile(tepc.io.projectRoot(), 'src', '+tepc', '+validation', 'runGate.m');
tok = regexp(readUtf8(p), 'addItem\(\s*items\s*,\s*''([^'']+)''', 'tokens');
raw = strings(numel(tok), 1);
for i = 1:numel(tok)
    raw(i) = string(tok{i}{1});
end
names = unique(raw, 'stable');
end

function keys = registerLayerKeys()
% 从注册表文本里取 gate_layers 块的键 (见头部关于 jsondecode 改名的说明)。
% regexp 对 **string 标量**输入会把结果按元素包进 cell, 那时 blk 不是 struct 而是 cell
% (实测报"此类型的变量不支持使用点进行索引") —— 所以显式按 char 走, 拿回 start/end 结构体。
t = char(readUtf8(fullfile(tepc.io.projectRoot(), 'config', 'capability_register.json')));
% char(含换行的 string标量) 会交回**二维** char 阵列, 那时 regexp 按列处理并返回 cell,
% blk 就不是 struct (实测报"此类型的变量不支持使用点进行索引") —— 一律压成行向量。
txt = t(:).';
% 取区间用 [s, e] = regexp(...) 的双输出形式而不是 s = regexp(...); s.end:
% regexp 交回的 struct 里字段名就叫 end, 而 blk.end 写在 txt(...) 内部时 end 会先按
% "末索引"解析, 于是变成 blk.<双精度> —— 实测报"此类型的变量不支持使用点进行索引"。
[gs, ge] = regexp(txt, '"gate_layers"\s*:\s*\{[^}]*\}', 'once');
assert(~isempty(gs), '注册表里没有 gate_layers 块');
seg = txt(gs(1):ge(1));
tk = regexp(seg, '"(\d+)"\s*:', 'tokens');
keys = strings(numel(tk), 1);
for i = 1:numel(tk)
    keys(i) = string(tk{i}{1});
end
end

function sameTo(tc, a, b, msg)
% 显式集合相等 (顺序无关, 假定两侧都已去重)。缺哪边、多哪边, 都写进消息。
missA = setdiff(b, a, 'stable');
missB = setdiff(a, b, 'stable');
ok = isempty(missA) && isempty(missB);
tc.verifyTrue(ok, sprintf('%s 实得: 映射 %d 条 / 对照 %d 条; 缺 %s; 多 %s', ...
    char(string(msg)), numel(a), numel(b), strjoin(missA, ', '), strjoin(missB, ', ')));
end

function test_map_names_equal_the_gates_runGate_emits(tc)
M = tepc.validation.gateLayers();
names = gateNamesInRunGate();
mapped = string(M(:, 1));
sameTo(tc, mapped, names, '门禁名集合与 runGate 的 addItem 不一致');
tc.verifyEqual(numel(unique(mapped)), numel(mapped), '映射里有重名门禁 (层号会互相覆盖)');
end

function test_map_names_equal_the_published_gate_inventory(tc)
% docs/counts.json 是发布侧的清单, 但两段不同名: 数字在 counts 下 (counts.gates),
% 门禁名清单在 details 下 (details.gate_names) —— 实测 C.counts.gate_names 报 nonExistentField。
C = jsondecode(readUtf8(fullfile(tepc.io.projectRoot(), 'docs', 'counts.json')));
M = tepc.validation.gateLayers();
mapped = sort(string(M(:, 1)), 'ascend');
pub = sort(string(C.details.gate_names(:)), 'ascend');
nGate = size(M, 1);              % 不是 numel(M): 16x2 cell 的 numel 是 32
sameTo(tc, mapped, pub, '门禁名集合与 docs/counts.json 发布的 gate_names 不一致');
tc.verifyEqual(double(C.counts.gates), nGate, sprintf('counts.json 记 gates=%g 而映射有 %d 条: 门禁总数的两处口径分叉', double(C.counts.gates), nGate));
end

function test_layers_are_the_registers_own_six(tc)
M = tepc.validation.gateLayers();
keys = sort(registerLayerKeys(), 'ascend');
lay = string(M(:, 2));
unknown = setdiff(unique(lay), keys, 'stable');
tc.verifyEmpty(unknown, sprintf('映射用了注册表里没有的层号: %s', strjoin(unknown, ', ')));
missing = setdiff(keys, unique(lay), 'stable');
tc.verifyEmpty(missing, sprintf('注册表声明的层里有 %d 条没有任何门禁: %s', ...
    numel(missing), strjoin(missing, ', ')));
end

function test_no_layer_is_left_empty(tc)
M = tepc.validation.gateLayers();
lay = str2double(string(M(:, 2)));      % 不是 double(string): "1"->49 会让六层全判空
tc.verifyFalse(any(isnan(lay)), '层号列里有非数字项');
for L = 1:6
    n = nnz(lay == L);
    tc.verifyGreaterThan(n, 0, sprintf('第 %d 层一条门禁都没有: 分层退化成散文', L));
end
end

function test_negative_control_a_dropped_name_is_caught(tc)
% 本文件的判据会不会恒真? 造一个"少一条门禁名"的映射, 断言集合比较确实报不一致。
M = tepc.validation.gateLayers();
names = gateNamesInRunGate();
tc.verifyGreaterThan(numel(names), 2, '前提: runGate 至少要有 3 条门禁, 否则本负控无内容');
M2 = M;  M2(1, :) = [];
tc.verifyEqual(size(M2), [size(M, 1) - 1, size(M, 2)], ...
    '删行没有真的少掉一行 (cell 数组拼接退化)');
tc.verifyFalse(isequal(sort(string(M2(:, 1)), 'ascend'), sort(names, 'ascend')), ...
    '删掉一条映射后集合仍然相等: 判据 (1) 是空的');
% 层号列同样要有内容: 造一个只覆盖第 1 层的假映射, 空层判据必须报出来。
M3 = M;  for i = 1:numel(M3), M3{i, 2} = '1'; end
tc.verifyEqual(nnz(str2double(string(M3(:, 2))) > 1), 0, '假映射构造失败 (没把层号全压成 1)');
tc.verifyGreaterThan(nnz(str2double(string(M(:, 2))) > 1), 0, ...
    '真映射里没有任何非第 1 层门禁: 上面那条"全压成 1"的负控就没有对照');
end
