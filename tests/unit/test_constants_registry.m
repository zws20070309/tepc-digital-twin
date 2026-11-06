function tests = test_constants_registry
%TEST_CONSTANTS_REGISTRY 常数注册表的反装饰测试。
%   动机: "把常数集中登记"这件事本身可以零成本作弊 —— 造一个漂亮的 JSON 表,
%   代码里却继续留着字面量, 表和代码各说各话 (表变成第二份文档而不是真相源)。
%   因此这里锁三件事:
%     (1) 集合相等:  注册表里 wired:true 的 id  ==  src/ 里真实的
%         tepc.config.constants('<id>') 调用点集合 (双向, 注释里的举例不算)。
%         今天 0 项接线、0 个调用点 => 断言平凡成立; 一旦把某条 wired 改 true 却忘了
%         改代码 (或反过来在代码里调用了未登记/未置位的 id), 本测试立刻红。
%         每条未接线项都带 wiring_todo, 三条"代表项"见 idsOfRepresentativeTodo()。
%     (2) 真相源核对: reader 返回值必须等于 JSON 里记录的值; 把 JSON 拷到 tempdir
%         改值/加条目后, 带 path 第二参数的 reader 必须跟着变, 而 reader 自身源码里
%         不得出现该常数的字面量 —— 证明 JSON 是源, 不是镜像。
%     (3) 哈希可判别: sha256(docs/constants.json) 是 64 位十六进制, 且改一个字节
%         哈希必变 —— 否则"常数被偷偷改过"在 provenance 里查不出来。
%   另加两条口径自检: used_by 的 file:line 必须真的指向那个数值; 引用登记册里无 URL
%   来源的条目不得是 REFERENCE/MEASURED (无 URL 的条目保持降级, 不许升格)。
tests = functiontests(localfunctions);
end

% ==================== (0) 表自身合法性 ====================

function test_registry_is_well_formed(tc)
[path, doc] = readRepoRegistry(tc);
tc.verifyGreaterThanOrEqual(numel(doc.constants), 12, ...
    sprintf('注册表只有 %d 条 (<12): 散落的常数没有登记全 (%s)', ...
    numel(doc.constants), path));
ids = idsOf(doc);
tc.verifyEqual(numel(unique(ids)), numel(ids), 'const_id 有重复');
needFields = {'const_id','value','units','status','source_ref','revision', ...
    'uncertainty_rel','used_by','note','wired','measured_condition','wiring_todo'};
bad = strings(0,1);
for i = 1:numel(doc.constants)
    e = doc.constants(i);
    miss = needFields(~isfield(e, needFields));
    if ~isempty(miss)
        bad(end+1) = sprintf('%s: 缺字段 %s', strOr(e.const_id), strjoin(miss, ',')); %#ok<AGROW>
    end
    if ~isfield(e,'wired') || ~islogical(e.wired) || ~isscalar(e.wired)
        bad(end+1) = sprintf('%s: wired 必须是标量 true/false', strOr(e.const_id)); %#ok<AGROW>
    end
    if ~isfield(e,'status') || ~any(strOr(e.status) == ["ASSUMED","MEASURED","REFERENCE"])
        bad(end+1) = sprintf('%s: status=%s 不在词表内', strOr(e.const_id), strOr(e.status)); %#ok<AGROW>
    end
    if isempty(fieldOr(e,'used_by'))
        bad(end+1) = sprintf('%s: used_by 为空 (没有代码位置的登记就是装饰)', strOr(e.const_id)); %#ok<AGROW>
    end
    v = fieldOr(e, 'value');
    if ~isempty(v) && ~(isnumeric(v) || islogical(v))
        bad(end+1) = sprintf('%s: value 必须是数值/布尔标量', strOr(e.const_id)); %#ok<AGROW>
    end
    % ASSUMED 必须写清"怎样才能变成 MEASURED"
    if isfield(e,'status') && strOr(e.status) == "ASSUMED" ...
            && blankText(fieldOr(e, 'measured_condition'))
        bad(end+1) = sprintf('%s: ASSUMED 条目必须说明升级为 MEASURED 的条件', strOr(e.const_id)); %#ok<AGROW>
    end
    if isfield(e,'status') && strOr(e.status) ~= "ASSUMED" && strOr(e.source_ref) == "none"
        bad(end+1) = sprintf('%s: 非 ASSUMED 条目必须给出可核验的 source_ref (登记册里的 ref_id)', ...
            strOr(e.const_id)); %#ok<AGROW>
    end
end
tc.verifyEqual(bad, strings(0,1), sprintf('注册表结构不合法:\n  %s', strjoin(bad, '\n  ')));
end

function test_no_upgraded_references(tc)
% 登记册里 doi_or_url 不可核验的来源已降级为 ASSUMED, 任何条目不得借它们升格。
[regPath, doc] = readRepoRegistry(tc);
refPath = fullfile(tepc.io.projectRoot(), 'docs', 'reference_register.csv');
tc.verifyTrue(isfile(refPath), '缺少 docs/reference_register.csv');
refTxt = readLines(refPath);
downgraded = readDowngradedRefs(refTxt);   % 登记册里 doi_or_url 不可核验的 ref_id
bad = strings(0,1);
for i = 1:numel(doc.constants)
    e = doc.constants(i);
    s = strOr(e.source_ref);
    st = strOr(e.status);
    if s ~= "none" && ~isempty(s)
        % source_ref 必须真的指向登记册里存在的行
        if ~refIdExists(refTxt, s)
            bad(end+1) = sprintf('%s: source_ref=%s 在 docs/reference_register.csv 里不存在 (不得凭空造来源)', ...
                strOr(e.const_id), s); %#ok<AGROW>
        end
    end
    if any(s == downgraded) && st ~= "ASSUMED"
        bad(end+1) = sprintf('%s: 引用了无 URL 的 %s 却标 %s —— 必须保持降级', ...
            strOr(e.const_id), s, st); %#ok<AGROW>
    end
end
tc.verifyEqual(bad, strings(0,1), sprintf('来源登记违规 (%s / %s):\n  %s', ...
    regPath, refPath, strjoin(bad, '\n  ')));
end

function test_used_by_citations_point_at_the_number(tc)
% 两类引用两种核法, 因为"已接线"与"未接线"的**正确样子**本来就不同:
%   * wired=true  -> 代码里**不该再有字面量** (那正是本注册表要消除的分歧)。所以引用
%     必须指向真正的读取点: 被引文件里必须出现 constants('<id>')。这才是对"wired"
%     这个声明本身的反查 —— 旧版本只查"文件里有这个数值", 于是"validate.m 仍写着
%     10*fmc.a"和"validate.m 已改读注册表"两种相反状态都能通过 (审计: 注册表谎报
%     某处已接线而该处仍是字面量, 或反过来把已接线的位置登记成待办)。
%   * wired=false -> 字面量确实还在原地, 引用必须指向写着这个数的那一行; 行号漂移
%     只打印提示, 不误伤成红灯。
[regPath, doc] = readRepoRegistry(tc);
root = tepc.io.projectRoot();
bad = strings(0,1);
drift = strings(0,1);
for i = 1:numel(doc.constants)
    e = doc.constants(i);
    v = e.value;
    id = strOr(e.const_id);
    ub = cellStr(e.used_by);
    for j = 1:numel(ub)
        tok = strsplit(ub{j}, ':');
        if numel(tok) < 2
            bad(end+1) = sprintf('%s: used_by ''%s'' 不是 file:line 形式', id, ub{j}); %#ok<AGROW>
            continue
        end
        f = fullfile(root, strjoin(tok(1:end-1), ':'));
        if ~isfile(f)
            bad(end+1) = sprintf('%s: used_by 指向不存在的文件 %s', id, ub{j}); %#ok<AGROW>
            continue
        end
        ln = str2double(tok{end});
        lines = readLines(f);
        if ~(ln >= 1 && ln <= numel(lines))
            bad(end+1) = sprintf('%s: used_by %s 行号超出文件长度 %d', id, ub{j}, numel(lines)); %#ok<AGROW>
            continue
        end
        if isfield(e, 'wired') && islogical(e.wired) && e.wired
            % 接线声明反查: 整个文件里必须存在对该 id 的读取 (行号只作提示)
            callQ = sprintf('constants(''%s''', id);
            callD = sprintf('constants("%s"', id);
            hit = any(cellfun(@(s) contains(s, callQ) || contains(s, callD), lines));
            if ~hit
                bad(end+1) = sprintf(['%s: 声明 wired=true, 但 %s 里找不到 %s —— ' ...
                    '"已接线"是假的, 该处仍在用自己的字面量'], id, ub{j}, callQ); %#ok<AGROW>
            end
            continue;
        end
        if ~(isnumeric(v) && ~islogical(v))
            continue;                     % 布尔开关无法做数值反查, 只核对位置存在
        end
        win = lines(max(1,ln-3):min(numel(lines), ln+3));
        near = any(cellfun(@(s) lineHasValue(s, v), win));
        anywhere = any(cellfun(@(s) lineHasValue(s, v), lines));
        if ~anywhere
            bad(end+1) = sprintf('%s: %s 整个文件里都找不到数值 %s —— 这条引用是假的', ...
                id, ub{j}, num2str(v)); %#ok<AGROW>
        elseif ~near
            drift(end+1) = sprintf('%s: %s 行号已漂移 (值仍在该文件中, 请更新 used_by 行号)', ...
                id, ub{j}); %#ok<AGROW>
        end
    end
end
if ~isempty(drift)
    fprintf('[test_constants_registry] 引用行号待更新 (非失败):\n  %s\n', strjoin(drift, '\n  '));
end
tc.verifyEqual(bad, strings(0,1), sprintf('used_by 引用不成立 (%s):\n  %s', regPath, strjoin(bad, '\n  ')));
end

% ==================== (1) 集合相等 ====================

function test_wired_ids_and_call_sites_are_the_same_set(tc)
[~, doc] = readRepoRegistry(tc);
ids = idsOf(doc);
wired = ids(arrayfun(@(k) truthy(doc.constants(k).wired), 1:numel(doc.constants)));
sites = collectCallSites();                       % id -> {file:line,...}
callIds = string(siteKeys(sites));

problems = strings(0,1);
unregistered = setdiff(callIds, ids);
if ~isempty(unregistered)
    problems(end+1) = sprintf('src/ 里有 %d 个调用点引用了未登记的 id: %s', ...
        numel(unregistered), strjoin(unregistered, ', ')); %#ok<AGROW>
end
unflagged = setdiff(callIds, ids);              % 未登记的先由上一条报
unflagged = setdiff(setdiff(callIds, unflagged), wired);
if ~isempty(unflagged)
    problems(end+1) = sprintf('%d 个 id 在 src/ 里已有 tepc.config.constants(''<id>'') 调用点, 但注册表里 wired 仍是 false: %s —— 请把对应条目 wired 改为 true 并填 wiring_done', ...
        numel(unflagged), strjoin(unflagged, ', ')); %#ok<AGROW>
end
orphan = setdiff(wired, callIds);
if ~isempty(orphan)
    problems(end+1) = sprintf('%d 个条目声称 wired:true 但 src/ 里找不到调用点 (装饰性登记): %s', ...
        numel(orphan), strjoin(orphan, ', ')); %#ok<AGROW>
end
tc.verifyEqual(problems, strings(0,1), sprintf( ...
    ['常数注册表与源码调用点集合不相等:\n  %s\n' ...
     '硬要求 registered 包含 callSites; 双向相等按 wired 标志判定 (今日 wired 项数=%d, 调用点数=%d)。'], ...
    strjoin(problems, '\n  '), numel(wired), numel(callIds)));
if isempty(problems) && isempty(wired) && isempty(callIds)
    r = ids(arrayfun(@(k) ~truthy(doc.constants(k).wired), 1:numel(doc.constants)));
    fprintf([newline '[test_constants_registry] 提示: 集合相等目前平凡成立 (0 项接线 / 0 个调用点)。' ...
        newline '  尚未接线 %d 项; 代表项 3 个: %s' newline ...
        '  接线 = 改代码 + 把该条目 wired 置 true, 两步缺一即红。' newline], ...
        numel(r), strjoin(idsOfRepresentativeTodo(), ', '));
end
end

% ==================== (2) JSON 才是真相源 ====================

function test_registry_file_is_the_source_not_a_mirror(tc)
[path, doc] = readRepoRegistry(tc);
ids = idsOf(doc);
k = find(ids == "gas.mobilityIon_m2Vs_at_1atm");
if isempty(k)                       % 该 id 是固定选定的变异样本
    assumed = ids(arrayfun(@(j) strOr(doc.constants(j).status) == "ASSUMED", 1:numel(doc.constants)));
    tc.verifyFalse(isempty(assumed), '注册表里没有 ASSUMED 条目, 变异测试无样本');
    target = assumed(1);
else
    target = ids(k);
end
recorded = doc.constants(find(ids == target)).value;
tc.verifyEqual(strOr(doc.constants(find(ids == target)).status), "ASSUMED", ...
    sprintf('%s 不是 ASSUMED 条目, 换一条再跑变异', target));

% reader 与文件必须逐位一致
v = tepc.config.constants(target);
tc.verifyEqual(double(v), double(recorded), 'RelTol', 0, ...
    sprintf('tepc.config.constants(''%s'')=%s 与 docs/constants.json 记录值 %s 不符', ...
    target, mat2str(v), mat2str(recorded)));

% 整张表也要能拿到 (报告 ASSUMED 清单用它生成, 不手抄)
allT = tepc.config.constants();
tc.verifyEqual(numel(allT), numel(doc.constants), 'constants() 返回的表行数与文件不符');
tc.verifyTrue(any(arrayfun(@(j) strcmp(strOr(allT(j).const_id), char(target)), 1:numel(allT))), ...
    'constants() 表里找不到目标 id');

% 改 tempdir 副本: 值要跟着变, 新增条目要能读到, 仓库那份不受影响
tmp = tempCopyName('tepc_constants_mutate.json');
cleanup = onCleanup(@() deleteIfAny(tmp));
mDoc = doc;
mIdx = numel(mDoc.constants) + 1;
mDoc.constants(mIdx).const_id = 'zz.added.only.in.temp.copy';
mDoc.constants(mIdx).value = 42.75;
mDoc.constants(mIdx).units = 'dimensionless';
mDoc.constants(mIdx).status = 'ASSUMED';
mDoc.constants(mIdx).source_ref = 'none';
mDoc.constants(mIdx).revision = 'mutation-test';
mDoc.constants(mIdx).uncertainty_rel = 0;
mDoc.constants(mIdx).used_by = {'src/+tepc/+config/constants.m:1'};
mDoc.constants(mIdx).wired = false;
mDoc.constants(mIdx).note = '测试注入的合成条目: 只有真相源是文件时 reader 才读得到';
mDoc.constants(mIdx).measured_condition = '不适用 (测试用完即删)';
mDoc.constants(mIdx).wiring_todo = '不适用 (测试用完即删)';
mDoc.constants(find(ids == target)).value = recorded * 3 + 7;
writeText(tmp, jsonencode(mDoc, 'PrettyPrint', true));

vm = tepc.config.constants(target, tmp);
tc.verifyEqual(double(vm), double(recorded*3+7), 'RelTol', 0, ...
    sprintf('改了 JSON 副本后 reader 仍返回 %s: 值不是从文件来的 (存在硬编码镜像)', mat2str(vm)));
vs = tepc.config.constants('zz.added.only.in.temp.copy', tmp);
tc.verifyEqual(double(vs), 42.75, 'RelTol', 0, '临时副本里新增的 id 读不到: reader 不是以文件为准');
vRepo = tepc.config.constants(target);
tc.verifyEqual(double(vRepo), double(recorded), 'RelTol', 0, ...
    '读临时副本之后, 仓库路径的值被污染了 (缓存未按路径隔离)');
tc.verifyError(@() tepc.config.constants('zz.added.only.in.temp.copy'), ...
    'tepc:config:UnknownConstant', ...
    '仓库表里居然能读到临时副本注入的 id —— 缓存串了');
tc.verifyError(@() tepc.config.constants('no.such.constant.at.all'), 'tepc:config:UnknownConstant', ...
    '未知 id 必须以 tepc:config:UnknownConstant 报错');

% reader 自身不得留着该常数的字面量 (镜像式实现的直接证据)
rf = which('tepc.config.constants');
if isempty(rf), rf = fullfile(tepc.io.projectRoot(),'src','+tepc','+config','constants.m'); end
rTxt = readTextUtf8(rf);
lit = {sprintf('%g', recorded), strrep(sprintf('%g', recorded), 'e', 'e-')};
tc.verifyFalse(contains(rTxt, '0.0002') || contains(rTxt, '2.0e-4') || contains(rTxt, '42.75'), ...
    'constants.m 里出现了被登记常数的字面量: JSON 不再是唯一真相源');
end

% ==================== (3) provenance 哈希可判别 ====================

function test_hash_of_registry_detects_tampering(tc)
[path, doc] = readRepoRegistry(tc);
h = tepc.io.hashFile(path);
tc.verifyTrue(ischar(h) || isstring(h), 'hashFile 必须返回字符');
tc.verifyEqual(numel(char(h)), 64, sprintf('sha256 长度 %d != 64 (%s)', numel(char(h)), path));
tc.verifyTrue(~isempty(regexp(char(h), '^[0-9a-f]{64}$', 'once')), ...
    sprintf('hashFile(''%s'') = %s 不是 64 位十六进制', path, char(h)));

tmp = tempCopyName('tepc_constants_tamper.json');
cleanup = onCleanup(@() deleteIfAny(tmp));
copyfile(path, tmp);
h0 = tepc.io.hashFile(tmp);
tc.verifyEqual(h0, char(h), '同一内容的副本哈希不同: hashFile 不可信');

ids = idsOf(doc);
target = ids(find(ids == "gas.mobilityIon_m2Vs_at_1atm", 1));
if isempty(target), target = ids(1); end
b = readFileBytes(tmp);
needle = bytesOf(num2str(doc.constants(find(ids == target)).value));
pos = findSubseq(b, needle);
tc.assumeFalse(isempty(pos), ...
    sprintf('在注册表文本里找不到 %s 的字面量 %s, 无法构造单字节篡改', char(target), char(needle)))
tampered = b;
posLast = pos(end);                     % 改最后一处 (通常落在数字的低位上)
tampered(posLast) = byteFlip(tampered(posLast));
writeBytes(tmp, tampered);
h1 = tepc.io.hashFile(tmp);
tc.verifyFalse(strcmp(h1, h0), ...
    '改一个字节后哈希不变 —— constants.json 进 provenance 就没有判别力');
tc.verifyEqual(numel(h1), 64);
tc.verifyEqual(numel(h0), 64);
end

% ==================== helpers (不以 tc 为入参 -> 不会被算作测试) ====================

function ids = idsOfRepresentativeTodo()
% 三条代表项: 接线它们就能让"集合相等"从今天起非平凡成立。
ids = ["detector.diethorn.deltaV_V", "detector.avalanche.rStartFactor", ...
    "detector.gain.proportionalRegionUpperBound"];
end

function [path, doc] = readRepoRegistry(tc)
path = fullfile(tepc.io.projectRoot(), 'docs', 'constants.json');
tc.verifyTrue(isfile(path), sprintf('缺少常数注册表: %s', path));
txt = readTextUtf8(path);
doc = jsondecode(txt);
tc.verifyTrue(isfield(doc,'schema') && startsWith(strOr(doc.schema), "tepc-constants"), ...
    sprintf('注册表 %s 的 schema 不是 tepc-constants-vN', path));
tc.verifyTrue(isfield(doc,'generated_utc') && ~isempty(strOr(doc.generated_utc)), ...
    '注册表缺 generated_utc');
tc.verifyTrue(isfield(doc,'constants') && isstruct(doc.constants), ...
    '注册表缺 constants 数组');
end

function ids = idsOf(doc)
ids = strings(numel(doc.constants), 1);
for i = 1:numel(ids)
    ids(i) = strOr(doc.constants(i).const_id);
end
end

function sites = collectCallSites()
% 扫 src/**/*.m 的真实代码 (剔除行注释与 %{ %} 块注释), 收集 constants('<id>') 调用点。
root = tepc.io.projectRoot();
files = dir(fullfile(root, 'src', '**', '*.m'));
sites = struct('id', {}, 'where', {});
for i = 1:numel(files)
    f = files(i);
    code = stripComments(readLines(fullfile(f.folder, f.name)));
    rel = strrep(strrep(fullfile(f.folder, f.name), root, ''), '\', '/');
    rel = erase(rel, "/");
    for j = 1:numel(code)
        tok = regexp(code{j}, ...
            'tepc\.config\.constants\(\s*[''"]([^''"]+)[''"]', 'tokens');
        for k = 1:numel(tok)
            sites(end+1) = struct('id', tok{k}{1}, ...
                'where', sprintf('%s:%d', rel, j)); %#ok<AGROW>
        end
    end
end
end

function keys = siteKeys(sites)
keys = strings(numel(sites),1);
for i = 1:numel(sites)
    keys(i) = string(sites(i).id);
end
end

function out = stripComments(lines)
out = cell(size(lines));
inBlock = false;
for i = 1:numel(lines)
    L = lines{i};
    if inBlock
        if ~isempty(regexp(L, '^\s*%\}', 'once')), inBlock = false; end
        out{i} = ''; continue;
    end
    if ~isempty(regexp(L, '^\s*%\{', 'once'))
        inBlock = true; out{i} = ''; continue;
    end
    out{i} = stripLineComment(L);
end
end

function code = stripLineComment(L)
% 去掉行尾注释, 但字符串字面量里的 % 不算注释。
inS = false; inD = false;
for k = 1:numel(L)
    ch = L(k);
    if inS
        if ch == ''''
            if k < numel(L) && L(k+1) == ''''
                k = k + 1;                  % '' 是转义的一个单引号
            else
                inS = false;
            end
        end
    elseif inD
        if ch == '"'
            inD = false;
        end
    elseif ch == ''''
        inS = true;
    elseif ch == '"'
        inD = true;
    elseif ch == '%'
        code = L(1:max(0, k-1));
        return;
    end
end
code = L;
end

function tf = lineHasValue(lineTxt, v)
tok = regexp(lineTxt, '\d+\.?\d*(?:[eE][-+]?\d+)?', 'match');
for i = 1:numel(tok)
    x = str2double(tok{i});
    if ~isnan(x) && abs(x - double(v)) <= 1e-12 * max(1, abs(double(v)))
        tf = true; return
    end
end
tf = false;
end

function tf = refIdExists(refTxt, id)
id = char(id);
tf = false;
for i = 1:numel(refTxt)
    c = csvFields(refTxt{i});
    if ~isempty(c) && strcmp(strtrim(c{1}), id), tf = true; return; end
end
end

function d = readDowngradedRefs(refTxt)
% 登记册列: ref_id=1, doi_or_url=5。该列不是 http(s) 链接的行 = 无可核验 URL,
% 这些来源只够支撑 ASSUMED 条目, 注册表不得借它们给条目升格。
d = strings(0,1);
for i = 2:numel(refTxt)
    c = csvFields(refTxt{i});
    if numel(c) < 5, continue; end
    url = strtrim(c{5});
    if ~startsWith(url, "http")
        d(end+1) = string(strtrim(c{1})); %#ok<AGROW>
    end
end
end

function c = csvFields(line)
% 单行 CSV 拆分: 尊重双引号与 "" 转义 (登记册里有大量含逗号的引用字段)。
c = {}; buf = ''; inQ = false;
k = 1;
while k <= numel(line)
    ch = line(k);
    if inQ
        if ch == '"'
            if k < numel(line) && line(k+1) == '"'
                buf = [buf, '"']; k = k + 1;
            else
                inQ = false;
            end
        else
            buf = [buf, ch];
        end
    elseif ch == '"'
        inQ = true;
    elseif ch == ','
        c{end+1} = buf; buf = '';
    else
        buf = [buf, ch];
    end
    k = k + 1;
end
c{end+1} = buf;
end

function L = readLines(f)
txt = readTextUtf8(f);
L = strsplit(txt, sprintf('\n'), 'CollapseDelimiters', false);
end

function txt = readTextUtf8(f)
% 显式 UTF-8 读: 本机 MATLAB 默认字符集是 GBK, fileread 会把 UTF-8 中文按双字节解码,
% 从而吞掉紧随其后的换行字节 —— 行号错位, 报告里的 file:line 会指到别处。
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0, error("tepc:tests:Unreadable", '无法读取 %s', f); end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
txt = strrep(txt, sprintf('\r\n'), sprintf('\n'));
txt = strrep(txt, sprintf('\r'), sprintf('\n'));
end

function s = strOr(x)
if isempty(x), s = ""; elseif iscell(x), s = string(x{1}); else, s = string(x); end
if numel(s) > 1, s = s(1); end
end

function tf = blankText(x)
% 空白判定必须用 strlength: string 标量的 numel 永远是 1。
tf = isempty(x) || strlength(strtrim(string(x))) == 0;
end

function c = cellStr(x)
if iscell(x), c = x(:); else, c = cellstr(string(x)); end
end

function e = fieldOr(s, f)
if isfield(s, f), e = s.(f); else, e = []; end
end

function tf = truthy(x)
tf = ~isempty(x) && any(logical(x(:)));
end

function tmp = tempCopyName(nm)
% 唯一且必定不存在的临时路径 (并行 MATLAB 会话之间不互相覆盖)。
[d, n, ~] = fileparts(tempname);
tmp = fullfile(d, ['tepc_' n '_' nm]);
if isfile(tmp), delete(tmp); end
end

function writeText(f, txt)
fid = fopen(f, 'w', 'n', 'UTF-8');
if fid < 0, error("tepc:tests:TempWrite", '无法写临时文件 %s', f); end
fwrite(fid, txt, 'char');
fclose(fid);
end

function b = readFileBytes(f)
fid = fopen(f, 'r', 'n');
b = fread(fid, inf, 'uint8=>uint8');
fclose(fid);
end

function writeBytes(f, b)
fid = fopen(f, 'w', 'n');
fwrite(fid, uint8(b), 'uint8');
fclose(fid);
end

function p = findSubseq(b, needle)
% 字节子序列定位 (行向量对齐后再比, 避免 fread 的列向量与 needle 隐式扩展)
b = b(:)';  needle = needle(:)';
p = [];
n = numel(b) - numel(needle) + 1;
for i = 1:n
    if all(b(i:i+numel(needle)-1) == needle), p(end+1) = i; end %#ok<AGROW>
end
end

function nb = bytesOf(s)
nb = uint8(s(:)');
end

function nb = byteFlip(u)
nb = bitxor(u, uint8(1));
end

function deleteIfAny(f)
if isfile(f), delete(f); end
end
