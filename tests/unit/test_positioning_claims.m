function tests = test_positioning_claims
%TEST_POSITIONING_CLAIMS 治理文本里关于测试存在性与能力状态的陈述必须与磁盘/登记表一致.
%
% 起因 (实测): 登记表与 docs/positioning.md 各有 4 条写着"tests/ 下尚无 test_xxx",
% 而那 4 个文件都已落且各带 4~13 条用例。人读这些句子会得出"该判据还没验证"的结论,
% 实际上是"已经验证、只是文本忘了改"。已交付项被记成缺口, 与把缺口记成已交付一样是
% 假陈述 —— 前者让评审把已锁的判据再要一遍, 后者直接构成过度声明.
%
% 五条判据各自可失败:
%   1) "尚无 test_X" 的 X 在磁盘上必须真的不存在;
%   2) 文本点名的 tests/... 路径必须真的存在 (不得指向被改名/被删的文件);
%   3) 每个非 DONE 条目在 positioning 里必须有一行 短横+id+[状态]+标题, 且状态
%      与登记表同值; DONE 条目必须以允许表述的形式出现 (（<id>）), 不允许只有内部状态;
%   4) 反向: positioning 里出现的每个 "- <id> [" 都必须能在登记表找到同 id 同状态,
%      且判据扫描的文本规模不得被清空后"干净地"放行。
%   5) 符号形状的缺位陈述 ("tests/ 下 grep X 零命中" / "没有任何测试读 X") 里被点名的
%      符号, 在 tests/ 下必须真的搜不到 —— 判据 1 只认 test_ 开头的文件名, 这一类
%      走的是另一个形状, 实测有过期到全绿的情况; 该用例自带一真一假两段合成文本,
%      分别挡"恒真"与"恒红"两种空转。
tests = functiontests(localfunctions);
end

%% ==================== 夹具 ====================

function root = projRoot()
root = tepc.io.projectRoot();
end

function txt = governanceText()
% 两份治理文本合并扫描: 判据针对"这个陈述", 与它出现在哪份文件里无关.
r = projRoot();
f = {fullfile(r, 'docs', 'positioning.md'), ...
     fullfile(r, 'config', 'capability_register.json')};
parts = strings(1, numel(f));
for i = 1:numel(f)
    assert(isfile(f{i}), sprintf('缺治理文本 %s', f{i}));
    parts(i) = string(fileread(f{i}));
end
txt = strjoin(parts, newline);
end

function names = existingTestFiles()
r = projRoot();
d = dir(fullfile(r, 'tests', '**', '*.m'));
names = strings(numel(d), 1);
for i = 1:numel(d)
    names(i) = string(d(i).name);
end
end

function [idsPos, stPos] = listedStatuses(txt)
% 逐行解析 positioning 的条目行: 短横 + id + [状态]。
% 对 cellstr 整体做 regexp 会再套一层 cell, 无匹配行取 {1} 必然越界, 所以逐行 once。
L = strsplit(txt, newline);
idsPos = strings(0, 1);
stPos = strings(0, 1);
rx = '^\s*-\s*([A-Za-z0-9\-]+)\s*\[([A-Z_]+)\]';
for i = 1:numel(L)
    tk = regexp(strtrim(L{i}), rx, 'tokens', 'once');
    if isempty(tk)
        continue
    end
    idsPos(end+1) = string(tk{1}); %#ok<AGROW>
    stPos(end+1) = string(tk{2}); %#ok<AGROW>
end
end

%% ==================== 1. "尚无某测试"必须真的没有 ====================

function test_absent_test_claims_are_really_absent(tc)
txt = governanceText();
tok = regexp(txt, '尚无\s*(test_[A-Za-z0-9_]+)', 'tokens');
claims = strings(0, 1);
for i = 1:numel(tok)
    claims(end+1) = string(tok{i}{1}); %#ok<AGROW>
end
have = existingTestFiles();
alive = unique(claims(ismember(claims, have)));
tc.verifyEmpty(alive, sprintf(['治理文本仍写着"尚无"但这些测试文件已在磁盘上: %s —— 读者会据此认为该判据未落地, ' ...
     '而它已经可执行'], strjoin(alive, ', ')));
end

function test_scanned_text_is_big_enough_to_mean_anything(tc)
% 反装饰: 判据 1 在"一条尚无都没有"时恒真。这里要求被扫文本仍有规模、仍有可数的
% 条目号, 否则整份治理文本被清空也能"干净地"放行。
txt = governanceText();
tc.verifyGreaterThan(strlength(txt), 8000, sprintf('治理文本只有 %d 字符: 无从核对任何陈述', strlength(txt)));
% \b 在这份含全角括号的文本上实测匹配不到 (plain 20 命中 / wordbound 0 命中), 故不用它。
ids = regexp(txt, '[DT]-\d+', 'match');
distinct = unique(string(ids));
tc.verifyGreaterThan(numel(distinct), 20, sprintf('治理文本里只数到 %d 个条目号: 覆盖范围已被清空', numel(distinct)));
end

%% ==================== 2. 点名的测试路径必须存在 ====================

function test_named_test_paths_resolve(tc)
txt = governanceText();
tok = regexp(txt, '(tests/[A-Za-z0-9_./]*?test_[A-Za-z0-9_]+\.m)', 'tokens');
r = projRoot();
bad = strings(0, 1);
for i = 1:numel(tok)
    rel = char(tok{i}{1});
    % 函数调用的结果不能直接 {:} 展开: 必须先落成变量。
    seg = strsplit(rel, '/');
    if ~isfile(fullfile(r, seg{:}))
        bad(end+1) = string(rel); %#ok<AGROW>
    end
end
tc.verifyEmpty(unique(bad), sprintf('治理文本点名了这些不存在的路径: %s', strjoin(unique(bad), ', ')));
end

%% ==================== 3+4. 两份文本的状态必须互推 ====================

function test_every_gated_entry_is_listed_with_the_same_status(tc)
r = projRoot();
reg = jsondecode(fileread(fullfile(r, 'config', 'capability_register.json')));
ents = reg.entries;
pos = string(fileread(fullfile(r, 'docs', 'positioning.md')));
[idsPos, stPos] = listedStatuses(pos);
bad = strings(0, 1);
nDone = 0;
for i = 1:numel(ents)
    id = string(ents(i).id);
    st = string(ents(i).status);
    j = find(idsPos == id, 1);
    if st == "DONE"
        nDone = nDone + 1;
        % DONE 条目的对外形态是"允许表述", 在 positioning 里以全角括号挂在句尾。
        if ~contains(pos, "（" + id + "）")
            bad(end+1) = id + ": 状态 DONE 但 positioning 没有把它标成任何允许表述"; %#ok<AGROW>
        end
        continue
    end
    if isempty(j)
        bad(end+1) = id + ": positioning 缺该条的 [状态] 行, 登记表状态=" + st; %#ok<AGROW>
        continue
    end
    if stPos(j) ~= st
        bad(end+1) = id + ": 登记表=" + st + " 而 positioning=" + stPos(j); %#ok<AGROW>
    end
end
tc.verifyEmpty(bad, sprintf('治理文本与登记表的状态陈述分叉: %s', strjoin(bad, ' ; ')));
tc.verifyGreaterThan(nDone, 0, '登记表里没有任何 DONE 条目: DONE 分支的判据恒真');
end

function test_positioning_lists_no_entry_the_register_lacks(tc)
r = projRoot();
reg = jsondecode(fileread(fullfile(r, 'config', 'capability_register.json')));
ents = reg.entries;
pos = string(fileread(fullfile(r, 'docs', 'positioning.md')));
[idsPos, stPos] = listedStatuses(pos);
ids = string({ents.id});
tc.verifyGreaterThan(numel(idsPos), 20, sprintf('positioning 只数到 %d 个带状态的条目行: 判据没有可核对的对象', numel(idsPos)));
bad = strings(0, 1);
for i = 1:numel(idsPos)
    j = find(ids == idsPos(i), 1);
    if isempty(j)
        bad(end+1) = idsPos(i) + ": positioning 有这一条但登记表没有"; %#ok<AGROW>
    elseif stPos(i) ~= string(ents(j).status)
        bad(end+1) = idsPos(i) + ": positioning=" + stPos(i) + " 而登记表=" + string(ents(j).status); %#ok<AGROW>
    end
end
tc.verifyEmpty(unique(bad), sprintf('positioning 里有登记表没有 (或状态不同) 的条目: %s', strjoin(unique(bad), ' ; ')));
end

%% ==================== 5. 符号形状的缺位陈述也必须与磁盘一致 ====================

function test_symbol_absence_claims_match_tests_dir(tc)
% 判据 1 只认 "尚无 test_X" 这种**文件名形状**的缺位陈述。治理文本里还有另一种形状:
%   "tests/ 下 grep X 零命中" / "没有任何测试读 X"
% —— 它点的是一个**符号**, 而符号可以在判据写完之后就出现在测试里。实测就有一条登记表
% 理由这么说的时候 tests/ 下已经有两处读那个符号, 而这套判据全绿: 过期文本逃过了机检。
% 这里补上这一类, 并把两个方向的空转都钉住:
%   * 恒真方向: 扫不到任何这类句子时 (现在就是), 用一段**明知为假**的合成文本证明
%     检查函数确实会报出来;
%   * 恒红方向: 再用一段**明知为真**的合成文本证明它不会把没有的东西也报成过期。
txt = governanceText();
real = brokenSymbolClaims(txt);
tc.verifyEmpty(real, sprintf(['治理文本仍写着"没有测试读/零命中", 但这些符号已在 tests/ 下被读到: %s ' ...
    '—— 读者会据此认为那条接线无人断言, 而它已经有人断言了'], strjoin(real, ' ; ')));

% 为假的合成文本: runAllTests 在 tests/ 下确实存在 (tests/runAllTests.m 本体 + 两处引用)。
fake = ['这是给判据本身用的合成句子: tests/ 下 grep runAllTests 零命中, ' ...
        '并且没有任何测试读 TestResult。'];
gotFake = brokenSymbolClaims(fake);
tc.verifyGreaterThan(numel(gotFake), 0, ...
    '明知为假的缺位陈述没被报出来: 这条判据在真实治理文本上也是恒真, 整条锁是装饰');
% 两个句式都要真的被抓到, 否则其中一支正则写错了也不会红 (这里两个符号都存在)。
tc.verifyGreaterThan(numel(gotFake), 1, ...
    sprintf('只报了 %d 条 (合成文本里两种句式各一条): 有一支正则没生效', numel(gotFake)));

% 为真的合成文本: 这个符号不可能在 tests/ 下出现。
probeSym = ['zzzNoSuch' 'SymbolName'];   % 拆开拼: 本文件里不得出现完整字面量, 否则自指引发恒红
trueClaim = sprintf('tests/ 下 grep %s 零命中。', probeSym);
gotTrue = brokenSymbolClaims(trueClaim);
tc.verifyEmpty(gotTrue, ...
    sprintf('明知为真的缺位陈述被报成过期 (%s): 这条判据恒红, 只会逼着人删句子', strjoin(gotTrue, ' ; ')));
end

function bad = brokenSymbolClaims(txt)
% 从治理文本里抽出"符号级缺位陈述", 逐条去 tests/ 下核对。命中即为过期。
syms = strings(0, 1);
tk = regexp(txt, 'grep\s+([A-Za-z_][A-Za-z0-9_]*)\s*零命中', 'tokens');
for i = 1:numel(tk)
    syms(end+1) = string(tk{i}{1}); %#ok<AGROW>
end
tk = regexp(txt, '没有任何测试[^。;]{0,40}?读\s+([A-Za-z_][A-Za-z0-9_.]*)', 'tokens');
for i = 1:numel(tk)
    syms(end+1) = string(tk{i}{1}); %#ok<AGROW>
end
bad = strings(0, 1);
for i = 1:numel(syms)
    s = syms(i);
    if strlength(s) < 4
        % 太短的词 (读 X) 会被派生名与注释大面积误命中, 不作为缺位陈述处理。
        continue
    end
    hit = filesMentioningInTests(char(s));
    if ~isempty(hit)
        bad(end+1) = s + " 被点名零命中, 实际在 " + strjoin(hit, ', '); %#ok<AGROW>
    end
end
end

function hits = filesMentioningInTests(sym)
% 在 tests/ 下所有 .m 里按整词搜 (<\b 在这份文本上不可用, 这里用 MATLAB 的 \< \> 边界):
% 纯子串会把 ChipSpec 之类派生名也算成命中, 那会让判据恒红。
r = projRoot();
d = dir(fullfile(r, 'tests', '**', '*.m'));
hits = strings(0, 1);
rx = ['\<' sym '\>'];
for i = 1:numel(d)
    fp = fullfile(d(i).folder, d(i).name);
    if isempty(regexp(string(fileread(fp)), rx, 'once'))
        continue
    end
    rel = strrep(fp(numel(r) + 2:end), '\', '/');
    hits(end+1) = string(rel); %#ok<AGROW>
end
end

