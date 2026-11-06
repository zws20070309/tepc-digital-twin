function tests = test_doc_counts
%TEST_DOC_COUNTS 文档计数一致性 + 仓库无缓存。
%   动机: .gitignore 在一个既没有 git 也没有 CI 的仓库里**什么都拦不住**, 而
%   README/quickstart/VV_plan 里的测试数、门禁数、数据集数一直靠手抄, 于是反复出现
%   11/14 门禁、16/22 数据集这类历史口径。实测到的漂移:
%     README.md:41 = 117 项、docs/quickstart.md:21 = 42 项、
%     docs/test_evidence/batch_release.log = 42、README.md:72 = "14 项"。
%   本测试因此必须是**真门禁**: 计数由 tools/genCounts.m 静态解析得出, 文档里的每个
%   引用值都要等于生成值; 少一处不等就红, 并把 file:line 与"声称值/生成值"一起列出。
%   注意: 本测试**不改** README/quickstart —— 修文档是重新生成计数之后的事。
%   同样地, 断言仓库里不存在 slprj/*.slxc 缓存: 今天它们存在, 今天就该红 (提示删除)。
tests = functiontests(localfunctions);
end

% ==================== (E) 文档引用值 == 生成值 ====================

function test_doc_quoted_counts_equal_generated(tc)
root = repoRoot(tc);
fresh = genFresh(tc, root);
counts = fresh.counts;
Q = quoteRules();

scanned = 0;
problems = strings(0,1);
hitsByRule = zeros(numel(Q), 1);
for i = 1:numel(Q)
    if ~isfield(counts, Q(i).countKey)
        problems(end+1) = sprintf('规则 %s: 生成值里没有键 %s (tools/genCounts.m 需补该计数或本规则写错)', ...
            Q(i).name, Q(i).countKey); %#ok<AGROW>
        continue
    end
    want = counts.(Q(i).countKey);
    for d = 1:numel(Q(i).files)
        fp = fullfile(root, Q(i).files{d});
        if ~isfile(fp)
            problems(end+1) = sprintf('规则 %s: 文档不存在 %s', Q(i).name, Q(i).files{d}); %#ok<AGROW>
            continue
        end
        scanned = scanned + 1;
        lines = readLines(fp);
        for j = 1:numel(lines)
            tok = regexp(lines{j}, Q(i).pattern, 'tokens', 'once');
            if isempty(tok), continue; end
            hitsByRule(i) = hitsByRule(i) + 1;
            got = str2double(string(tok{1}));
            if ~(isfinite(got) && got == want)
                problems(end+1) = sprintf('%s:%d 声称 %s = %s, 生成值 = %s  「%s」', ...
                    Q(i).files{d}, j, Q(i).name, fmt(got), fmt(want), clip(lines{j})); %#ok<AGROW>
            end
        end
    end
end
% 反装饰: 如果谁把引用值整段删掉, 上面就变成空集真空通过 —— 每类计数必须至少出现一次
for i = 1:numel(Q)
    if Q(i).minHits > 0 && hitsByRule(i) < Q(i).minHits
        problems(end+1) = sprintf('%s 类计数在文档里出现 %d 次 (<%d): 不许靠删掉引用值来通过一致性检查', ...
            Q(i).name, hitsByRule(i), Q(i).minHits); %#ok<AGROW>
    end
end
tc.verifyGreaterThanOrEqual(scanned, 3, '三份文档没有全部被扫描');
tc.verifyEqual(problems, strings(0,1), sprintf( ...
    ['文档里的计数与 tools/genCounts.m 的生成值不一致 (%d 处):\n  %s\n' ...
     '修复: 跑 genCounts 生成 docs/counts.json, 再把文档引用值改成生成值 (不要反过来改工具)。'], ...
    numel(problems), strjoin(problems, '\n  ')));
end

% ==================== 生成器自检 (口径不能悄悄失效) ====================

function test_generated_counts_are_plausible(tc)
root = repoRoot(tc);
fresh = genFresh(tc, root);
c = fresh.counts;
tc.verifyEqual(string(fresh.schema), "tepc-counts-v1", 'counts schema 版本变了, 消费方要跟改');
tc.verifyEqual(string(fresh.command), "cd tests; runAllTests", '命令串应与文档里引用的那条一致');
tc.verifyMatches(char(fresh.generated_utc), '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', ...
    'generated_utc 必须是 ISO8601 Z 时刻');
tc.verifyMatches(string(fresh.matlab_release), '^R\d{4}[a-z]$', ...
    sprintf('matlab_release=%s 不是 R<年份><字母> 形式', strOr(fresh.matlab_release)));
% 计数为 0 只可能是解析失败 (测试文件改名? runGate 换写法?), 不是"真的没有"
tc.verifyGreaterThanOrEqual(c.test_functions, 50, ...
    sprintf('test_functions=%d 过低: tests/ 下签名 (tc) 的解析口径很可能已经失效', c.test_functions));
tc.verifyGreaterThanOrEqual(c.test_files, 5, 'test_files 过低: tests/**/test_*.m 没被找到');
tc.verifyEqual(c.test_functions_excluded_multiarg, 0, ...
    '存在 function xxx(tc, ...) 多参数函数: functiontests 不收集它, 与套件口径分叉');
% 静态正则与 matlab.unittest 的**实际收集数**必须相等。这一条原先只是注释里的
% "实测一致", 没有锁: 于是带输出参数的辅助函数 (function root = repoRoot(tc)) 被算成
% 测试, 文档里的 236 与套件真实跑的 234 分叉了 2 个而无人察觉。
% 直接用 runAllTests 同一句 fromFolder —— 口径与被锁的对象完全同源。
ts = matlab.unittest.TestSuite.fromFolder(fullfile(root, 'tests'), ...
    'IncludingSubfolders', true);
tc.verifyEqual(c.test_functions, numel(ts), ...
    sprintf('静态计数 %d 与套件实际收集 %d 不符: genCounts 的解析口径已与 functiontests 分叉', ...
    c.test_functions, numel(ts)));
% 只比总数不够: 一个测试文件因**解析错误**被 TestSuite 静默排除时, 总数只少一点点,
% 失败信息也不会指名是哪个文件 —— 于是整份文件的用例凭空消失而套件照样接近全绿。
% 实测发生两次 (test_uq_validation.m 因 sprintf( 后直接换行成为无效表达式, 12 个用例
% 整体被排除)。这里把磁盘上的 test_*.m 名字集合与收集结果里出现的名字集合直接比对。
diskF = strings(0, 1);
dAll = dir(fullfile(root, 'tests', '**', 'test_*.m'));
for i = 1:numel(dAll)
    diskF(end+1) = string(dAll(i).name); %#ok<AGROW>
end
colF = extractBefore(string({ts.Name}), "/") + ".m";   % Name 形如 "文件/用例"
missF = sort(setdiff(diskF, unique(colF)));
tc.verifyEmpty(missF, sprintf( ...
    ['这些测试文件在磁盘上存在却没被套件收集 (很可能是解析错误被 TestSuite 静默排除): %s'], ...
    strjoin(missF, ', ')));
tc.verifyGreaterThanOrEqual(c.gates, 10, 'gates 过低: runGate.m 的 addItem 解析可能失效');
tc.verifyLessThanOrEqual(c.gates, 60, 'gates 过高: 解析可能把非门禁调用也算进来了');
tc.verifyGreaterThanOrEqual(c.h5_datasets, 5, 'h5_datasets 过低: writeEventsH5.m 的 map 表解析可能失效');
tc.verifyLessThanOrEqual(c.h5_datasets, 200, 'h5_datasets 过高: 解析可能重复计数');
tc.verifyGreaterThanOrEqual(c.anchor_rows_total, 1, '锚点表行数为 0: config/reference/*.csv 解析失效');
if isfield(fresh.details, 'numbered_gate_comments') ...
        && fresh.details.numbered_gate_comments ~= c.gates
    fprintf('[test_doc_counts] 提示: runGate.m 的 "%% N)" 编号注释数 (%d) 与去重门禁项数 (%d) 不等, 编号注释需补齐\n', ...
        fresh.details.numbered_gate_comments, c.gates);
end
end

function test_counts_manifest_is_up_to_date(tc)
root = repoRoot(tc);
mf = fullfile(root, 'docs', 'counts.json');
tc.verifyTrue(isfile(mf), ...
    sprintf('缺少 docs/counts.json —— 跑一次 genCounts 再提交 (计数只能生成, 不能手抄)'));
if ~isfile(mf), return; end
doc = jsondecode(readTextUtf8(mf));
fresh = genFresh(tc, root);
bad = strings(0,1);
if ~isfield(doc, 'counts')
    bad(end+1) = 'docs/counts.json 没有顶层 counts 字段';
else
    fn = fieldnames(fresh.counts);
    for i = 1:numel(fn)
        if ~isfield(doc.counts, fn{i})
            bad(end+1) = sprintf('清单缺键 %s (清单已过期)', fn{i}); %#ok<AGROW>
            continue
        end
        a = doc.counts.(fn{i});  b = fresh.counts.(fn{i});
        if ~(isnumeric(a) && a == b)
            bad(end+1) = sprintf('%s: 清单=%s, 现算=%s', fn{i}, mat2str(a), mat2str(b)); %#ok<AGROW>
        end
    end
    extra = setdiff(string(fieldnames(doc.counts)), string(fn));
    if ~isempty(extra)
        bad(end+1) = sprintf('清单里有生成器不再产出的键: %s', strjoin(extra, ', ')); %#ok<AGROW>
    end
end
if isfield(doc, 'matlab_release') && ~strcmp(string(doc.matlab_release), string(fresh.matlab_release))
    bad(end+1) = sprintf('matlab_release: 清单=%s 现算=%s', strOr(doc.matlab_release), ...
        strOr(fresh.matlab_release)); %#ok<AGROW>
end
tc.verifyEqual(bad, strings(0,1), sprintf( ...
    'docs/counts.json 与静态检查结果不一致 (%d 项):\n  %s\n修复: matlab -batch "addpath ../tools; genCounts"', ...
    numel(bad), strjoin(bad, '\n  ')));
end

% ==================== (F) 仓库里不得有构建缓存 ====================

function test_latest_evidence_is_same_generation(tc)
% docs/test_evidence/latest_evidence.json 是"某条日志与哪一代代码同批"的唯一索引,
% 但此前**没有任何判据引用过它**: 用例数从 488 一路涨上来, 索引一直停在旧代而全绿。
% 这里只比"出处一致"(索引记的计数 == counts.json 记的计数, 且它引用的生成时刻就是盘上
% 那份), 不比墙钟 —— 重跑顺序不该让测试变红, 但"索引没跟着这次生成走"必须变红。
root = repoRoot(tc);
ev = fullfile(root, 'docs', 'test_evidence', 'latest_evidence.json');
cf = fullfile(root, 'docs', 'counts.json');
tc.verifyTrue(isfile(ev), sprintf('缺证据索引 %s', relPath(root, ev)));
if ~isfile(ev) || ~isfile(cf), return; end
E = jsondecode(readTextUtf8(ev));
C = jsondecode(readTextUtf8(cf));
need = {'test_functions', 'counts_source', 'counts_generated_at', 'schema'};
miss = need(~isfield(E, need));
tc.verifyEmpty(string(miss), sprintf('证据索引缺字段: %s', strjoin(string(miss), ', ')));
tc.verifyEqual(string(E.schema), "tepc-latest-evidence-v1", '索引 schema 变了, 判据要同步');
tc.verifyEqual(string(E.counts_source), "docs/counts.json", ...
    '索引的计数出处不再声明为 docs/counts.json: 长出了第二套计数口径');
tc.verifyEqual(E.test_functions, C.counts.test_functions, 'AbsTol', 0, sprintf( ...
    '证据索引记 test_functions=%g, docs/counts.json 记 %g: 索引是旧代的, 重跑 tools/writeLatestEvidence', ...
    E.test_functions, C.counts.test_functions));
tc.verifyEqual(string(E.counts_generated_at), string(C.generated_utc), sprintf( ...
    '索引引用的 counts.json 生成时刻 %s 与盘上那份 %s 不一致: 两者不是同一次生成', ...
    string(E.counts_generated_at), string(C.generated_utc)));
% 源码哈希清单: 可复现性那一栏要能回答"这条证据是哪版代码跑出来的",
% 只哈希配置与几何答不了这半句。这里核三件事 —— 清单存在且自洽、路径集合与盘上
% 实际走一遍**相等** (生成器漏掉某个根目录就会红, 而不是静默少哈希)、
% 索引里带的是清单**当前**的哈希 (清单重生成而索引没跟上, 或反之, 都会红)。
manF = fullfile(root, 'docs', 'test_evidence', 'source_manifest.json');
tc.verifyTrue(isfile(manF), '缺源码哈希清单 docs/test_evidence/source_manifest.json (跑 tools/writeLatestEvidence)');
if isfile(manF)
    M = jsondecode(readTextUtf8(manF));
    tc.verifyTrue(isfield(M, 'files') && isfield(M, 'n_files'), '清单缺 files/n_files 字段');
    nListed = numel({M.files.path});
    tc.verifyEqual(M.n_files, nListed, sprintf( ...
        '清单自报 n_files=%g, 实际列出 %d 条: 生成或序列化过程截断了', M.n_files, nListed));
    roots = {'src', 'app', 'tests', 'tools', 'config', 'geometry'};
    onDisk = strings(0, 1);
    for i = 1:numel(roots)
        dd = dir(fullfile(root, roots{i}, '**', '*'));
        for k = 1:numel(dd)
            if ~dd(k).isdir
                relK = strrep(fullfile(dd(k).folder, dd(k).name), [root filesep], '');
                onDisk(end+1, 1) = string(strrep(relK, '\', '/')); %#ok<AGROW>
            end
        end
    end
    % 顶层这两个文档也在这一步的版本范围内 (与生成器的 topFiles 同口径),
    % 漏掉它们会让双向 setdiff 把真实条目报成"幽灵"。
    topFiles = {'README.md', 'tepc_3d_workbench.m'};
    for i = 1:numel(topFiles)
        if isfile(fullfile(root, topFiles{i}))
            onDisk(end+1, 1) = string(topFiles{i}); %#ok<AGROW>
        end
    end
    listed = string({M.files.path}');
    onlyDisk = setdiff(onDisk, listed);
    onlyList = setdiff(listed, onDisk);
    tc.verifyEmpty(onlyDisk, sprintf('这些源文件没进清单 (生成器漏了根目录?): %s', ...
        strjoin(onlyDisk, ', ')));
    tc.verifyEmpty(onlyList, sprintf('清单里有盘上不存在的路径 (幽灵条目): %s', ...
        strjoin(onlyList, ', ')));
    % 清单条目 vs 盘上。上一段只核过"清单存在、路径集合相等", 那判不住清单**新不新**:
    % 改了 src/tests 却不重跑 writeLatestEvidence, 清单仍是那 221 个路径、集合等式照样成立,
    % 于是"这条证据是哪版代码跑出来的"回答的是一个过期版本号。
    % 判据先比 mtime_local (清单逐条存了), 只对 mtime 变过的文件再算哈希:
    % 本机 SHA-256 是纯 MATLAB 实现, 无条件哈希 221 个文件实测把本用例从 ~51s 推到 >68s,
    % 一个治理测试不该贵到这个量级。代价是"保持 mtime 的内容替换"逃过本判据 ——
    % 那是刻意伪造而非日常工作流, 记录在此而不是假装覆盖。
    changed = strings(0, 1);
    for i = 1:numel(M.files)
        partsK = strsplit(char(M.files(i).path), '/');
        fpK = fullfile(root, partsK{:});
        if ~isfile(fpK)
            % 路径集合的双向 setdiff 上面已经判过"幽灵条目", 这里只追内容是否换过。
            continue
        end
        dK = dir(fpK);
        if string(dK.date) ~= string(M.files(i).mtime_local)
            if string(tepc.io.hashFile(fpK)) ~= string(M.files(i).sha256)
                changed(end+1) = string(M.files(i).path); %#ok<AGROW>
            end
        end
    end
    tc.verifyEmpty(changed, sprintf( ...
        '%d 个文件的盘上哈希与清单不符: 代码改过而清单没重生成, 这条证据已不是当前这版代码的产物。跑 tools/writeLatestEvidence。前 %d 个: %s', ...
        numel(changed), min(8, numel(changed)), ...
        strjoin(changed(1:min(8, numel(changed))), ', ')));
    hMan = tepc.io.hashFile(manF);
    sel = string({E.sha256.path}') == "docs/test_evidence/source_manifest.json";
    tc.verifyEqual(nnz(sel), 1, '证据索引没有收录源码清单条目: 两者不是同一次生成');
    if any(sel)
        tc.verifyEqual(string(E.sha256(sel).sha256), string(hMan), ...
            '索引记的清单哈希与盘上那份不符: 清单重生成后没重跑 writeLatestEvidence');
    end
end
end

function test_no_build_caches_in_repository(tc)
% slprj/ 与 *.slxc 是构建缓存, 不是源。无 git/CI 时只有测试能拦住它们。
% 注: tests/integration/slprj 之所以出现, 是因为 Simulink 对照测试的工作目录在
% tests/integration 里, 缓就落在那儿 —— 发布前必须清掉。
root = repoRoot(tc);
caches = { ...
    'TEPC_Electronics.slxc',              'file'; ...
    'slprj',                              'dir';  ...
    'simulink/slprj',                     'dir';  ...
    'tests/integration/slprj',            'dir';  ...
    'tests/integration/TEPC_Electronics.slxc', 'file'};
present = strings(0,1);
for i = 1:size(caches, 1)
    p = fullfile(root, caches{i,1});
    kind = caches{i,2};
    real = kind == "dir" && isfolder(p);
    real = real || (kind == "file" && isfile(p));
    if real
        present(end+1) = sprintf('%s (%s 存在于 %s)', caches{i,1}, kind, p); %#ok<AGROW>
    end
end
tc.verifyEqual(present, strings(0,1), sprintf( ...
    ['仓库里还有 %d 个构建缓存, 发布包无法区分源与缓存:\n  %s\n' ...
     '删除它们; 只靠 .gitignore 不算数 (本仓库无 git/CI)。源文件 simulink/TEPC_Electronics.slx 必须保留。'], ...
    numel(present), strjoin(present, '\n  ')));
end

% ==================== (G) 目录约定: 审查产物不得留在仓库内 ====================

function test_no_review_artifacts_in_repository(tc)
% 目录约定: 仓库内只放 (a) 仿真运行文件 (b) README 与技术文档
% (c) 运行产物与运行日志; GUI 截图与历次审查报告放仓库外的 ../临时/。本仓库既没有
% git 也没有 CI, .gitignore 拦不住任何回退 —— 只有测试能拦住"又把截图和报告
% 塞回 docs/", 与上一条 test_no_build_caches_in_repository 是同一条纪律。
root = repoRoot(tc);
imgExt = {'png','jpg','jpeg','gif','bmp','tif','tiff','fig','docx','pptx','xlsx','zip'};
banPat = {'review_log.md', '*设计质疑*', '*勘误*', 'implementation_plan*'};
stray = strings(0,1);
nScan = 0;
for i = 1:numel(imgExt)
    d = dir(fullfile(root, '**', ['*.' imgExt{i}]));
    for j = 1:numel(d)
        r = relPath(root, fullfile(d(j).folder, d(j).name));
        nScan = nScan + 1;
        if startsWith(r, "runs/"), continue; end   % run 产物 (figures/raw) 合法
        stray(end+1) = sprintf('%s (%s)', r, imgExt{i}); %#ok<AGROW>
    end
end
for i = 1:numel(banPat)
    d = dir(fullfile(root, '**', banPat{i}));
    for j = 1:numel(d)
        r = relPath(root, fullfile(d(j).folder, d(j).name));
        nScan = nScan + 1;
        if startsWith(r, "runs/"), continue; end
        stray(end+1) = sprintf('%s (匹配 %s)', r, banPat{i}); %#ok<AGROW>
    end
end
% 反装饰: 扫到 0 个候选只可能是通配符或项目根解析失效, 那不是"仓库干净"。
tc.verifyGreaterThan(nScan, 0, ...
    '一个候选文件都没扫到: 通配符/项目根解析已失效, 本锁证明不了任何事');
tc.verifyEqual(stray, strings(0,1), sprintf( ...
    ['仓库里有 %d 个审查产物或办公文档, 违反目录约定:\n  %s\n' ...
     '移到仓库外的 ../临时/ (截图 -> 临时/GUI截图审查/, 报告 -> 临时/审查报告/), ' ...
     '并把引用它们的地方一并改成 ../临时/... 路径。'], ...
    numel(stray), strjoin(stray, '\n  ')));
end

% ==================== helpers ====================

function Q = quoteRules()
% 文档中"引用计数"的写法 -> 生成值键名。规则要精确到不会误伤散文里的数字,
% 因此每条都带上下文关键字; 每类都要求至少命中一次 (minHits)。
Q = struct('name', {}, 'pattern', {}, 'countKey', {}, 'files', {}, 'minHits', {});
Q(end+1) = struct('name', '测试用例数', ...
    'pattern', 'runAllTests[^0-9%]*%[^0-9]*([0-9]+)\s*项', ...
    'countKey', 'test_functions', ...
    'files', {{'README.md', 'docs/quickstart.md', 'docs/VV_plan.md'}}, 'minHits', 2);
Q(end+1) = struct('name', '门禁项数', ...
    'pattern', '门禁\s*\*{0,2}(\d+)\s*项', ...
    'countKey', 'gates', ...
    'files', {{'README.md', 'docs/quickstart.md', 'docs/VV_plan.md'}}, 'minHits', 1);
Q(end+1) = struct('name', 'HDF5 数据集数', ...
    'pattern', '(\d+)\s*个?\s*数据集', ...
    'countKey', 'h5_datasets', ...
    'files', {{'README.md', 'docs/quickstart.md', 'docs/VV_plan.md'}}, 'minHits', 1);
Q(end+1) = struct('name', '质子射程锚点行数', ...
    'pattern', '共程\s*(\d+)\s*点', ...
    'countKey', 'anchor_rows_pstar_water_proton_range', ...
    'files', {{'README.md', 'docs/quickstart.md', 'docs/VV_plan.md'}}, 'minHits', 1);
Q(end+1) = struct('name', 'UI 用例数', ...
    'pattern', 'UI 用例\s*(\d+)\s*例', ...
    'countKey', 'ui_test_functions', ...
    'files', {{'README.md', 'docs/quickstart.md'}}, 'minHits', 1);
% UI 用例数这条**只比 README 与 quickstart**: VV_plan 讲的是数值 V 与 VV 判据, 把界面入口
% 的计数塞进它反而让那张表混进不属于它的口径; 少一个文件不等于规则放松, 两文件都已 minHits>=1。
end

function c = genFresh(tcase, root)
% 第一个参数**故意不叫 tc**: 叫 tc 的两参数函数会被 genCounts 的签名口径看见,
% 而 MATLAB 的 functiontests 不收集它 -> 计数与套件口径分叉 (测试会红, 那是真问题)。
if isempty(which('genCounts'))
    addpath(fullfile(root, 'tools'));         % runAllTests 只加 src/app/workflows/tests
end
tcase.assumeTrue(~isempty(which('genCounts')), '找不到 tools/genCounts.m');
c = genCounts('WriteFile', false, 'Root', root);
end

function root = repoRoot(tc)
root = tepc.io.projectRoot();
tc.assumeTrue(isfolder(fullfile(root, 'tests')), sprintf('项目根解析失败: %s', root));
end

function r = relPath(root, p)
% 相对仓库根的正斜杠路径: 失败消息里要能一眼看出文件在仓库里的哪个位置。
r = extractAfter(string(p), string(root) + string(filesep));
r = replace(r, '\', '/');
end

function L = readLines(f)
txt = readTextUtf8(f);
L = strsplit(txt, sprintf('\n'), 'CollapseDelimiters', false);
end

function txt = readTextUtf8(f)
% 显式 UTF-8 读: 本机 MATLAB 默认字符集是 GBK, fileread 会把 UTF-8 中文按双字节解码,
% 从而吞掉紧随其后的换行字节 -> 行号错位, 报告里的 file:line 会指到别处。
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0, error("tepc:tests:Unreadable", '无法读取 %s', f); end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
txt = strrep(txt, sprintf('\r\n'), sprintf('\n'));
txt = strrep(txt, sprintf('\r'), sprintf('\n'));
end

function t = clip(s)
% 失败消息里只留证据行的一段, 不要把整张 Markdown 表倒进报告。
% 注意: 对 string 标量要用 strlength, numel 永远是 1。
s = strtrim(string(s));
if strlength(s) > 100
    t = extractBefore(s, 101) + "…";
else
    t = s;
end
end

function s = fmt(x)
if isnan(x) || ~isfinite(x), s = "NaN"; else, s = string(x); end
end

function s = strOr(x)
if isempty(x), s = ""; elseif iscell(x), s = string(x{1}); else, s = string(x); end
if numel(s) > 1, s = s(1); end
end
