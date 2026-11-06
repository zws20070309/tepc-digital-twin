function tests = test_uncertainty_depth_tiers
%TEST_UNCERTAINTY_DEPTH_TIERS 不确定度传播深度档位: 生效、逐位无害、不许静默忽略。
%   方向一律是"档位看起来生效其实没接线 -> 红"与"档位悄悄动了物理量 -> 红",
%   而不是"表读得动"那种恒绿断言。六条:
%     tableDistinct      表解析 + 白名单来自代码 + 两档同向量必拒 (正反两向都试)
%     tiersBitHarmless   四腿同 seed 同 N: 未设档 / standard / screening / publish 的**中心量逐位相同**,
%                        而并档必须真的进到全链 cfg (读盘上的 config_resolved.json 核)
%     tierReachesRun     档位改了 cfg 并把生效值写进 summary (不接受"表里有、代码没读")
%     validateCodes      未知档位 error / 显值覆盖 warn / run 节未知键 error, 各带配对负腿
%     tsIsRelative       TS_TOO_COARSE 的阈值随 shaping_s 移动 (钉住 shaping_s, 不写字面量)
%     honestSurface      措辞只从 depthLine 产出 (判据全用 ASCII, 见下面的码页坑)
%   四条语言/环境事实 (写这类文件时每次都成立):
%     * functiontests 只收集**单参数 (tc)** 的 test_ 子函数, helper 一律带输出参数;
%     * tepc.config.validate 返回 **cell** (元素是 struct), 不能对它做 {s.code} 点展开;
%     * 函数调用结果后面不能再加 (:), 必须先落变量;
%     * 本机 MATLAB 源码码页是 GBK: 用 UTF-8 读来的文件内容与 .m 里的中文常量比对会
%       永远不相等, 于是"不含某句中文"的判据恒真。跨文件扫描一律用 ASCII 判据。
tests = functiontests(localfunctions);
end

%% ============================================================ 用例

function test_tableDistinct(tc)
T = tepc.config.uncertaintyDepthTiers();
tc.verifyGreaterThan(numel(T.ids), 1, '档位表只有一档就不叫档位');
allow = tepc.config.uncertaintyDepthKnobs();
for k = 1:numel(T.tiers)
    e = T.tiers(k);
    tc.verifyFalse(isempty(e.paths), sprintf('%s 档一个旋钮都不设', e.id));
    out = setdiff(e.paths, allow, 'stable');
    tc.verifyTrue(isempty(out), sprintf('%s 档有不在代码白名单里的旋钮: %s', ...
        e.id, strjoin(cellstr(out), ', ')));
    tc.verifyFalse(isempty(strtrim(e.disclosure)), sprintf('%s 档没有披露句', e.id));
end
% 生效向量与书写次序无关: 同一档把两条旋钮写反顺序必须仍判成同一向量。
v1 = depthVector({"uq.enabled", "uq.nSamples"}, {false, 32});
v2 = depthVector({"uq.nSamples", "uq.enabled"}, {32, false});
tc.verifyEqual(v1, v2, '旋钮书写次序改变了生效向量: 表改行序就会被判成两档');
% 负控 A: 表里塞一个代码不读的旋钮必须被拦 (否则白名单是装饰)。
bad = writeFixture({'uq.enabled', 'geometry.a_m'}, {true, 0.001});
tc.verifyError(@() tepc.config.uncertaintyDepthTiers('Path', bad), ...
    'tepc:config:DepthKnobNotAllowed', ...
    '表里塞一个代码不读的旋钮居然解析通过: "表里有、代码没读"的装饰档位会重演');
% 负控 B: 两档向量相同必须解析期就拒 (否则"三档"可能是同一份计算抄三遍)。
dup = writeDupTiers();
tc.verifyError(@() tepc.config.uncertaintyDepthTiers('Path', dup), ...
    'tepc:config:DepthIndistinct', '两个生效值完全相同的档被接受了: 档位开关可以是空转');
% 负控 C: knobs 写成空数组必须报"不设任何旋钮", 而不是被当成形状错。
empty = writeEmptyKnobs();
tc.verifyError(@() tepc.config.uncertaintyDepthTiers('Path', empty), ...
    'tepc:config:DepthKnobEmpty', '空 knobs 走到了形状错分支: 有一条错误码不可达');
% 代价数字不许自证: 档位表是纯文本, 谁都能改; 所以表里写了 cost_ratio_measured 就必须
% 与它自己点名的阶梯归档产物逐项对账 (墙钟 min/median/腿数/比值), 并由该产物证明
% "同一 N 内跨档中心量只有一个值"。手写一个好看的倍数会在这一条上判红。
% 形状口径 (踩过的坑都在这里挡住): cost_ratio_measured 现在是**数组** (一个 N 一条),
% jsondecode 在字段集不一致时会退化成 cell、把 1 元素数组解成标量结构体、把空数组解成
% 0x0 结构体 —— 三种都会让"逐条对账"静默少做甚至不做, 所以先判形状再对数。
nEntries = 0;
for k = 1:numel(T.tiers)
    e = T.tiers(k);
    c = e.cost_ratio_measured;
    if isempty(c)
        continue;
    end
    tc.verifyTrue(isstruct(c) && numel(c) > 0, ...
        sprintf(['%s 档的 cost_ratio_measured 不是非空结构体数组 (class=%s numel=%d): ' ...
            '0x0 结构体或 cell 会让下面的逐条对账一条都不执行'], ...
            e.id, class(c), numel(c)));
    if ~isstruct(c) || numel(c) == 0
        continue;
    end
    declaredN = zeros(1, numel(c));
    for j = 1:numel(c)
        nEntries = nEntries + 1;
        cj = c(j);
        ap = fullfile(tepc.io.projectRoot(), char(string(cj.artifact)));
        tc.verifyTrue(isfile(ap), ...
            sprintf('%s 档第 %d 条引用了不存在的阶梯产物: %s', e.id, j, char(string(cj.artifact))));
        J = jsondecode(fileread(ap));
        sel = arrayfun(@(s) double(s.N) == double(cj.N) && strcmp(char(string(s.tier)), e.id), ...
            J.summary_by_N_tier);
        art = J.summary_by_N_tier(sel);
        tc.verifyEqual(numel(art), 1, ...
            sprintf('%s 档在产物 %s 里按 N=%d 应该正好命中一个分组, 实得 %d 个', ...
                e.id, char(string(cj.artifact)), cj.N, numel(art)));
        if numel(art) ~= 1
            continue;
        end
        a = art(1);
        tc.verifyEqual(cj.wall_min_s, a.wall_min_s, 'RelTol', 1e-9, ...
            sprintf('%s 档 N=%d 的墙钟最小值与阶梯产物不一致', e.id, cj.N));
        tc.verifyEqual(cj.wall_median_s, a.wall_median_s, 'RelTol', 1e-9, ...
            sprintf('%s 档 N=%d 的墙钟中位数与阶梯产物不一致', e.id, cj.N));
        tc.verifyEqual(cj.legs, a.n_legs, ...
            sprintf('%s 档 N=%d 记的腿数与产物不符 (锁的是几次重复的统计量, 不能少报)', e.id, cj.N));
        tc.verifyTrue(logical(a.yF_all_equal), ...
            sprintf('产物里 %s 档 N=%d 自己的 y_F 就不是一个值: 这个档位动了中心量', e.id, cj.N));
        % 比值必须对**同一产物同一 N** 的 standard 分组取, 不能拿别的 N 的 standard 当分母。
        selStd = arrayfun(@(s) double(s.N) == double(cj.N) && ...
            strcmp(char(string(s.tier)), 'standard'), J.summary_by_N_tier);
        artStd = J.summary_by_N_tier(selStd);
        tc.verifyEqual(numel(artStd), 1, sprintf('%s 档 N=%d 找不到同产物的 standard 分组: 比值无出处', ...
            e.id, cj.N));
        if numel(artStd) ~= 1
            continue;
        end
        tc.verifyEqual(cj.ratio_vs_standard, a.wall_median_s / artStd(1).wall_median_s, ...
            'RelTol', 1e-6, sprintf('%s 档 N=%d 的 ratio_vs_standard 与产物中位数之比不一致', ...
            e.id, cj.N));
        % "跨档不改中心量"必须**按 N 分组**判: 同一产物里 N=400 与 N=2000 的 y_F 本来就该
        % 随事件数不同, 拿全文件去重要一个值会把这条锁变成假红, 而"顺手改成只比同档"又会让
        % 它变成假绿 —— 所以这里点名 (产物, N) 这个粒度。
        sameN = arrayfun(@(r) double(r.N) == double(cj.N), J.runs);
        yRuns = J.runs(sameN);
        if numel(yRuns) > 1
            % %.17g 能区分两个 double 的每一位; 用 string(数值) 会退到 5 位有效数字, 那样
            % "只有一个值"的判据就只是近似相等, 不再是逐位。
            % sprintf 不接 cell —— 传 {…} 会抛 MATLAB:printf:invalidInputType (本机实测),
            % 所以先把结构体数组的字段收成数值行, 再让格式对每个元素循环套用。
            yv = [yRuns(:).yF_keV_um];
            parts = strsplit(strtrim(sprintf('%.17g\n', yv)), newline);
            tc.verifyEqual(numel(unique(parts)), 1, ...
                sprintf('产物 %s 的 N=%d 里跨 %d 条腿出现了 %d 个不同的 y_F: 档位不该动中心量', ...
                    char(string(cj.artifact)), cj.N, numel(yv), numel(unique(parts))));
        end
        declaredN(j) = double(cj.N);
    end
    % 同一个档不许把同一条数字贴两遍 (那会让"两点分别标注"退化成一点)。
    tc.verifyEqual(numel(unique(declaredN)), numel(declaredN), ...
        sprintf('%s 档的 cost_ratio_measured 里 N 有重复: 一个 N 只能有一条', e.id));
end
tc.verifyGreaterThan(nEntries, 0, ...
    '档位表一条代价实测都没有: 措辞里"按实测代价分档"就成了空话 (数字要能追到产物)');
end

function test_tiersBitHarmless(tc)
root = tepc.io.projectRoot();
td = depthTempDir('harmless');
cleanupDir = onCleanup(@() rmdir(td, 's'));  %#ok<NASGU>
cfg0 = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
% 对照腿 = 未引入档位的链: 把键删掉, 让 execute 自己补默认档 (默认必须是 standard)。
cfgPre = rmNested(cfg0, {'run', 'uncertaintyDepth'});
tc.verifyTrue(isfield(cfg0.run, 'uncertaintyDepth'), ...
    '发货配置里没有 run.uncertaintyDepth: 对照腿无从删起, 这条判据会退化成自证');
cfgStd = cfg0;   cfgStd.run.uncertaintyDepth = 'standard';
cfgScr = cfg0;   cfgScr.run.uncertaintyDepth = 'screening';
% 第四条腿: publish。此前它只在归档产物里被去重核过, 活体链没跑过它, 而 publish 改的正是
% uq.nSamples (32->128) —— 若样本数会回流到中心量, 只有活体腿能抓到。
cfgPub = cfg0;   cfgPub.run.uncertaintyDepth = 'publish';
Nev = 120;
RPre = tepc.run.execute(cfgPre, 'N', Nev, 'Seed', 73111, 'RunDir', fullfile(td, 'pre'));
RStd = tepc.run.execute(cfgStd, 'N', Nev, 'Seed', 73111, 'RunDir', fullfile(td, 'std'));
RScr = tepc.run.execute(cfgScr, 'N', Nev, 'Seed', 73111, 'RunDir', fullfile(td, 'scr'));
RPub = tepc.run.execute(cfgPub, 'N', Nev, 'Seed', 73111, 'RunDir', fullfile(td, 'pub'));
cen = {'yF_keV_um', 'yD_keV_um', 'nEff', 'D_gas_Gy', 'D_gas_per_event_Gy'};
for i = 1:numel(cen)
    f = cen{i};
    msgA = sprintf('%s: 显式 standard 档与未设档的链不逐位相同 (%.17g vs %.17g)', ...
        f, RStd.summary.(f), RPre.summary.(f));
    msgB = sprintf('%s: screening 档改动了中心量 (%.17g vs %.17g)', ...
        f, RStd.summary.(f), RScr.summary.(f));
    msgC = sprintf('%s: publish 档改动了中心量 (%.17g vs %.17g) —— 样本数不该回流到中心量', ...
        f, RStd.summary.(f), RPub.summary.(f));
    hasAll = isfield(RStd.summary, f) && isfield(RPre.summary, f) && ...
        isfield(RScr.summary, f) && isfield(RPub.summary, f);
    tc.verifyTrue(hasAll, sprintf('%s: 四条腿中有 summary 缺这个中心量: 逐位比较会退化成缺字段异常', f));
    if ~hasAll, continue; end
    % isequaln 把 NaN 与 NaN 判等 => 四腿同为 NaN 时三条判据全绿却什么都没证。
    % 中心量必须是有限值 (归档侧本来就有 all(isfinite), 活体侧先前漏了这一道)。
    qv = [RPre.summary.(f), RStd.summary.(f), RScr.summary.(f), RPub.summary.(f)];
    tc.verifyTrue(all(isfinite(qv)), sprintf( ...
        '%s: 四腿取值含非有限值 (%s): 逐位相等在这种取值下不具含义', f, mat2str(qv)));
    tc.verifyTrue(isequaln(RStd.summary.(f), RPre.summary.(f)), msgA);
    tc.verifyTrue(isequaln(RStd.summary.(f), RScr.summary.(f)), msgB);
    tc.verifyTrue(isequaln(RStd.summary.(f), RPub.summary.(f)), msgC);
end
% 不确定度陈述**必须**不同, 否则"档位生效"只是文案。
tc.verifyNotEqual(upper(string(RStd.summary.uq_status)), "DISABLED", ...
    'standard 档把 uq 关掉了: 与档位定义相反');
tc.verifyEqual(upper(string(RScr.summary.uq_status)), "DISABLED", ...
    'screening 档没有关掉 uq: 档位没接线');
tc.verifyNotEqual(upper(string(RPub.summary.uq_status)), "DISABLED", ...
    'publish 档把 uq 关掉了: 与档位定义相反');
% publish 生效必须是"样本数真的变多", 而不是只换了个标签: 用产物里记录的样本数判。
tc.verifyTrue(isfield(RPub.summary, 'u_nSamples'), ...
    'publish 腿的 summary 没有 u_nSamples: 无从证明样本数随档位走');
if isfield(RPub.summary, 'u_nSamples') && isfield(RStd.summary, 'u_nSamples')
    tc.verifyGreaterThan(double(RPub.summary.u_nSamples), double(RStd.summary.u_nSamples), ...
        'publish 的样本数没超过 standard: 这一档其实空转');
end
% 并档必须进到**全链 cfg** (config_resolved.json 是它的盘上证据, 也正因为如此才进身份)。
% 只比 config_sha256 是假判据: 三腿的原始 cfg 本来只差 run.uncertaintyDepth 这一个键,
% 哈希必然不同, 即使并档一行代码都没生效。
ePre = resolvedCfg(RPre);
eStd = resolvedCfg(RStd);
eScr = resolvedCfg(RScr);
ePub = resolvedCfg(RPub);
tc.verifyEqual(string(ePre.run.uncertaintyDepth), "standard", ...
    '未设档时补齐的不是 standard: 缺省口径变了却没落到 cfg');
tc.verifyTrue(logical(eScr.uq.enabled) == false, ...
    'config_resolved.json 里 uq.enabled 仍是 true: 档位值只进了局部变量, 没进全链 cfg');
tc.verifyEqual(double(eStd.uq.nSamples), 32, 'AbsTol', 0, ...
    'standard 档的 uq.nSamples 不是发货的 32');
tc.verifyEqual(double(ePub.uq.nSamples), 128, 'AbsTol', 0, ...
    'publish 档的 uq.nSamples 不是 128: 档位值没进到全链解析后的 cfg');
end

function test_tierReachesRun(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
cfg.run.uncertaintyDepth = 'screening';
[c2, info] = tepc.config.applyDepthTier(cfg);
tc.verifyFalse(logical(c2.uq.enabled), '档位选了 screening 而 cfg.uq.enabled 仍是 true: 没接线');
tc.verifyEqual(string(info.id), "screening", 'applyDepthTier 回读的档位 id 不对');
T = tepc.config.uncertaintyDepthTiers('Id', 'screening');
tc.verifyEqual(numel(info.applied), numel(T.knobs), '生效旋钮条数与表不一致');
for j = 1:numel(info.applied)
    pth = info.applied(j).path;
    got = getNested(c2, strsplit(string(pth), '.'));
    tc.verifyEqual(string(got), string(T.knobs(j).value), ...
        sprintf('%s 档的 %s 没有真的落到 cfg', info.id, pth));
end
% 中间层缺失时不得把父结构复制进去 (那会污染配置身份)。
bare = rmNested(rmNested(cfg, {'uq'}), {'detector'});
[bb, i2] = tepc.config.applyDepthTier(bare);
tc.verifyTrue(isfield(bb, 'uq') && isfield(bb.uq, 'enabled'), '缺 uq 时并档没建出该层');
tc.verifyFalse(isfield(bb, 'enabled'), '顶层出现了游离的 enabled: 缺层时把父结构复制进了子层');
tc.verifyEqual(numel(i2.applied), numel(T.knobs), '缺层路径下生效条数与表不一致');
% 预设而非权威: 调用方给了非发货的显式值时, 档位那一条不得覆写它 (静默改掉
% "cfg.uq.enabled=false 让这次跑便宜点" 正是本仓库在清的缺陷族), 但必须记进 conflicts。
cm = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
cm.uq.enabled = false;
[c4, i4] = tepc.config.applyDepthTier(cm);
tc.verifyFalse(logical(c4.uq.enabled), ...
    'standard 档把调用方显式写的 uq.enabled=false 又改回 true: 档位越权覆写用户值');
tc.verifyEqual(numel(i4.conflicts), 1, ...
    '显式值挡住了档位却没被记下来: 无头运行里这就没人知道档位其实没全生效');
if numel(i4.conflicts) > 0
    tc.verifyEqual(string(i4.conflicts(1).path), "uq.enabled", '冲突条目路径不对');
end
tc.verifyFalse(logical(i4.applied(1).value), ...
    'applied 没反映调用结束后的真实生效值 (它写的是档位想要什么, 不是配置里是什么)');
% 反过来: 用户值等于发货值时视同没表态, 档位照常生效 (上面的 screening 腿就是这一类)。
td = depthTempDir('screenrun');
cleanupDir = onCleanup(@() rmdir(td, 's'));  %#ok<NASGU>
R = tepc.run.execute(cfg, 'N', 60, 'Seed', 505, 'RunDir', fullfile(td, 'r'));
s = R.summary;
tc.verifyEqual(string(s.uncertainty_depth_tier), "screening", 'summary 没落档位 id');
tc.verifyTrue(contains(string(s.uncertainty_depth_knobs_json), "uq.enabled"), ...
    'summary 没落生效旋钮: 事后无从核对档位是否真生效');
tc.verifyFalse(isEmptyStr(s.uncertainty_depth_note), ...
    '表里的披露句没进产物: 档位表里的 disclosure 成了死文本');
end

function test_validateCodes(tc)
base = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
% 1) 未知档位 => error
c = base; c.run.uncertaintyDepth = 'ultra';
[cds, lvls] = issuesOf(tepc.config.validate(c));
iK = find(cds == "DEPTH_UNKNOWN", 1);
tc.verifyFalse(isempty(iK), '未知档位 id 没有被拒绝');
if ~isempty(iK)
    tc.verifyEqual(lvls(iK), "error", 'DEPTH_UNKNOWN 只是 warn: 拼错的档位会带着假身份出厂');
end
% 2) 缺省档位 => 不报 (否则该分支恒真)
[cds, ~] = issuesOf(tepc.config.validate(rmNested(base, {'run', 'uncertaintyDepth'})));
tc.verifyFalse(any(cds == "DEPTH_UNKNOWN"), '缺省档位被判成未知: 错误分支恒真');
% 3) 覆盖判据的四条腿: 比的必须是**值**, 且必须能把"发货默认"与"用户显式"分开。
%    screening 只翻 uq.enabled, 而发货值就是 true ⇒ 干净的 screening 不得报覆盖。
c = base; c.run.uncertaintyDepth = 'screening';
[cds, ~] = issuesOf(tepc.config.validate(c));
tc.verifyFalse(any(cds == "DEPTH_KNOB_OVERRIDDEN"), ...
    '干净的 screening 就报覆盖: 判据把发货默认当成了用户显式值, 于是每次选粗档都误报');
%    显式值 == 档位值 => 不报
c = base; c.run.uncertaintyDepth = 'publish'; c.uq.nSamples = 128; c.uq.enabled = true;
[cds, ~] = issuesOf(tepc.config.validate(c));
tc.verifyFalse(any(cds == "DEPTH_KNOB_OVERRIDDEN"), '显式值与档位取值相同时也报覆盖');
%    档位管该旋钮且用户给了第三个值 => 报 warn
c = base; c.run.uncertaintyDepth = 'publish'; c.uq.nSamples = 64;
[cds, lvls] = issuesOf(tepc.config.validate(c));
iK = find(cds == "DEPTH_KNOB_OVERRIDDEN", 1);
tc.verifyFalse(isempty(iK), ...
    'publish 管着 uq.nSamples 而用户显式给了 64, 却没被说出来: 不说出来就是档位静默失效');
if ~isempty(iK)
    tc.verifyEqual(lvls(iK), "warn", '覆盖提示应当是 warn (显式值优先是设计, 但必须落到产物与状态行)');
end
%    档位不管该旋钮 => 不报 (publish 只管 uq.enabled/uq.nSamples 之外的旋钮时同理)
c = base; c.run.uncertaintyDepth = 'screening'; c.uq.nSamples = 999;
[cds, ~] = issuesOf(tepc.config.validate(c));
tc.verifyFalse(any(cds == "DEPTH_KNOB_OVERRIDDEN"), ...
    'screening 不管 uq.nSamples, 改它却被判成与档位冲突');
% 4) run 节未知键 => error (拼错的档位键今天会静默失效)
c = base; c.run.uncertaintyDepth = 'screening'; c.run.uncertaintyDepthy = 'x';
[cds, ~] = issuesOf(tepc.config.validate(c));
tc.verifyTrue(any(cds == "RUN_UNKNOWN_FIELD"), 'run 节的拼错键被静默接受');
c = base; c.run.uncertaintyDepth = 'screening';
[cds, ~] = issuesOf(tepc.config.validate(c));
tc.verifyFalse(any(cds == "RUN_UNKNOWN_FIELD"), ...
    '合法键 uncertaintyDepth 被自己的白名单判成未知');
c = base; c.run.x_note = 'prose';
[cds, ~] = issuesOf(tepc.config.validate(c));
tc.verifyFalse(any(cds == "RUN_UNKNOWN_FIELD"), ...
    '散文键 x_note 被白名单拦下 (jsondecode 把 _note 改名 x_note, 两种前缀都要放行)');
end

function test_tsIsRelative(tc)
base = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
sh0 = double(base.electronics.shaping_s);
tc.verifyEqual(sh0, 1.0e-6, 'RelTol', 0, ...
    '发货 shaping_s 不再是 1e-6: 本条把阈值当 shaping/50 的口径要跟着改');
thr = sh0/50;
c = base; c.electronics.sampleTime_s = thr;
[cds, ~] = issuesOf(tepc.config.validate(c));
tc.verifyFalse(any(cds == "TS_TOO_COARSE"), 'Ts 恰等于 shaping/50 就报了 (判据是严格大于)');
c = base; c.electronics.sampleTime_s = thr*1.5;
[cds, lvls] = issuesOf(tepc.config.validate(c));
iK = find(cds == "TS_TOO_COARSE", 1);
tc.verifyFalse(isempty(iK), sprintf('超出 shaping/50 的 Ts=%g 没报警', thr*1.5));
if ~isempty(iK)
    tc.verifyEqual(lvls(iK), "warn", 'TS_TOO_COARSE 必须是 warn: 它是精度提示不是配置非法');
end
% 关键: shaping_s 加倍后**同一个绝对 Ts 不再越界** —— 证明判据是相对的,
% 也证明这条锁不是拿 2e-8 这个巧合数字自证。
c = base; c.electronics.shaping_s = 2*sh0; c.electronics.sampleTime_s = thr*1.5;
[cds, ~] = issuesOf(tepc.config.validate(c));
tc.verifyFalse(any(cds == "TS_TOO_COARSE"), ...
    sprintf('shaping_s 加倍后 Ts=%g 仍报 TS_TOO_COARSE: 阈值被写成了绝对值', thr*1.5));
end

function test_honestSurface(tc)
root = tepc.io.projectRoot();
s = struct('uncertainty_depth_tier', 'screening', 'uncertainty_depth_label', 'L', ...
    'uncertainty_depth_knobs_json', '{"uq.enabled":false}', 'uq_status', 'DISABLED', ...
    'uncertainty_depth_note', 'NOTE');
txt = tepc.report.depthLine(s);
% 这三条比的是 depthLine.m 与**本文件**的中文常量: 两侧都由 MATLAB 按同一码页解析,
% 所以自洽 (跨文件扫 UTF-8 文本时才不能用中文判据, 见文件头)。
tc.verifyTrue(contains(txt, "不确定度传播深度"), '状态行没点名档位');
tc.verifyTrue(contains(txt, "中心量逐位相同"), ...
    '状态行没写"档位不改物理量": 读者会把粗档当精度损失, 或把细档当更准');
tc.verifyTrue(contains(txt, "不得进报告结论"), 'screening 档没说出来它不能进结论');
s2 = s;
s2.uncertainty_depth_tier = 'standard';
s2.uq_status = 'COMPLETE';
s2.uncertainty_depth_knobs_json = '{"uq.enabled":true,"uq.nSamples":32}';
txt2 = tepc.report.depthLine(s2);
tc.verifyFalse(contains(txt2, "不得进报告结论"), '非 screening 档也带"不得进结论": 措辞没随档位走');
tc.verifyTrue(contains(txt2, "32"), '生效值没进状态行');
% 单一来源: 报告与界面必须调 depthLine, 且不得自己拿原始字段拼一句。
% 判据全 ASCII —— 中文常量与 UTF-8 读来的内容在本机码页下永不相等, 那会让判据恒真。
rpt = filereadInUtf8(fullfile(root, 'src', '+tepc', '+report', 'htmlReport.m'));
tc.verifyFalse(isempty(regexp(rpt, 'tepc\.report\.depthLine', 'once')), ...
    'htmlReport 没调用 depthLine: 档位措辞在第二处手写');
tc.verifyFalse(contains(rpt, "uncertainty_depth_note"), ...
    'htmlReport 自己拼了披露句: 与 depthLine 形成第二处措辞来源');
app = filereadInUtf8(fullfile(root, 'app', 'TEPCApp.m'));
tc.verifyFalse(isempty(regexp(app, 'tepc\.report\.depthLine', 'once')), ...
    'GUI 没调用 depthLine: 状态带措辞在第二处手写');
tc.verifyFalse(contains(app, "uncertainty_depth_label"), ...
    'GUI 自己拼了档位标签: 与 depthLine 形成第二处措辞来源');
end

function test_ladderRunsMatchTheirGroups(tc)
% tableDistinct 只把档位表与产物的 summary_by_N_tier 分组对账, 逐腿明细 runs[] 与那些分组
% 之间没有任何锁: 从 runs[] 里删掉 publish 的几条腿、或改一条腿的 uq_status, 现有锁全绿,
% 而"三档 12 腿同一个 y_F"这类引用读的就是 runs[] 的行数。补三段:
%   (i)  runs[] 按 (N, 档) 数出的腿数 == summary 的 n_legs == 档位表的 legs;
%   (ii) 同一 N 内 y_D 与 nEff 也必须逐位唯一 (旧锁只去重 y_F);
%   (iii) 每档腿的 uq_status 必须与档位定义一致 (screening 关 / 另两档开)。
% 不拿 config_sha256 当生效证据: 三腿原始 cfg 只差 run.uncertaintyDepth 一个键, 哈希必然
% 不同, 本文件 tiersBitHarmless 里已把"只比 sha"定为假判据。产物只覆盖表里点名的 N,
% 且每腿的 N 都远小于发货 nEvents —— 它是量级记录, 不是发货工况。
T = tepc.config.uncertaintyDepthTiers();
nEntries = 0;      % 进入逐腿对账的 (档, N) 条数
nChecks = 0;       % 实际执行过的对账断言条数
covered = false(1, numel(T.tiers));
arts = strings(0);
for k = 1:numel(T.tiers)
    c = T.tiers(k).cost_ratio_measured;
    if isempty(c) || ~isstruct(c) || numel(c) == 0
        continue;
    end
    for j = 1:numel(c)
        a = string(c(j).artifact);
        if ~any(arts == a)
            arts(end+1) = a; %#ok<AGROW>
        end
    end
end
tc.verifyGreaterThan(numel(arts), 0, '档位表没点名任何阶梯产物: 逐腿对账无对象');
decoded = cell(1, numel(arts));
for m = 1:numel(arts)
    p = fullfile(tepc.io.projectRoot(), char(arts(m)));
    tc.verifyTrue(isfile(p), sprintf('阶梯产物不存在: %s', char(arts(m))));
    if isfile(p)
        decoded{m} = jsondecode(fileread(p));
    end
end
for k = 1:numel(T.tiers)
    e = T.tiers(k);
    c = e.cost_ratio_measured;
    if isempty(c) || ~isstruct(c) || numel(c) == 0
        continue;
    end
    for j = 1:numel(c)
        m = find(arts == string(c(j).artifact), 1);
        if isempty(m) || isempty(decoded{m})
            continue;
        end
        J = decoded{m};
        NN = double(c(j).N);
        tc.verifyTrue(isfield(J, 'runs') && isfield(J, 'summary_by_N_tier'), ...
            sprintf('产物 %s 缺 runs 或 summary_by_N_tier: 逐腿对账退化成不判', char(arts(m))));
        if ~(isfield(J, 'runs') && isfield(J, 'summary_by_N_tier'))
            continue;
        end
        isTier = arrayfun(@(r) double(r.N) == NN && strcmp(char(string(r.tier)), e.id), J.runs);
        legs = J.runs(isTier);
        tc.verifyGreaterThan(numel(legs), 0, ...
            sprintf('%s 档在产物 %s 的 N=%d 里一条腿都没有: 表里的代价数字无出处', ...
                e.id, char(arts(m)), NN));
        % (iii) uq_status 与档位定义一致。字段缺失在这里是**红**而不是跳过: 上一版把它包在
        % `if numel(legs)>0 && isfield(...)` 里, 于是 jsondecode 把 runs 退化成 cell 时 isfield
        % 返回 false (不抛错), 整段一条断言都不执行却全绿 —— 与本仓库判过的"惰性代码"同形。
        tc.verifyTrue(isstruct(J.runs) && isfield(J.runs, 'uq_status'), ...
            sprintf('产物 %s 的 runs 不是带 uq_status 字段的结构体数组 (class=%s): 字段被改名或解码退化, 一致性判据无从执行', ...
                char(arts(m)), class(J.runs)));
        st = string({legs.uq_status});
        nChecks = nChecks + 1;
        tc.verifyEqual(numel(st), numel(legs), ...
            sprintf('%s 档 N=%d: uq_status 读出 %d 条而腿有 %d 条 —— all([]) 会把缺项当成通过', ...
                e.id, NN, numel(st), numel(legs)));
        if strcmp(e.id, 'screening')
            tc.verifyTrue(all(st == "DISABLED"), ...
                sprintf('%s 档有腿的 uq_status 不是 DISABLED: %s', e.id, strjoin(cellstr(st), '/')));
        else
            tc.verifyTrue(all(st ~= "DISABLED"), ...
                sprintf('%s 档出现了 DISABLED 的腿: 与该档"开着 uq 传播"的定义相反', e.id));
        end
        nEntries = nEntries + 1;
        covered(k) = true;
        % (i) 明细腿数与分组、与表三方一致
        sel = arrayfun(@(s) double(s.N) == NN && strcmp(char(string(s.tier)), e.id), ...
            J.summary_by_N_tier);
        grp = J.summary_by_N_tier(sel);
        tc.verifyEqual(numel(grp), 1, ...
            sprintf('%s 档 N=%d 在 summary_by_N_tier 里应命中 1 个分组, 实得 %d', e.id, NN, numel(grp)));
        if numel(grp) == 1
            tc.verifyEqual(numel(legs), double(grp(1).n_legs), ...
                sprintf('%s 档 N=%d: runs 里有 %d 条腿, 分组记 n_legs=%d, 表记 legs=%d —— 三方必须一致', ...
                    e.id, NN, numel(legs), grp(1).n_legs, c(j).legs));
            tc.verifyEqual(double(grp(1).n_legs), double(c(j).legs), ...
                sprintf('%s 档 N=%d: 分组的 n_legs 与档位表的 legs 不一致', e.id, NN));
        end
        % (ii) 同 N 内 y_D 与 nEff 也逐位唯一 (不挑 NaN: 排掉 NaN 会让"唯一"变弱)
        allN = arrayfun(@(r) double(r.N) == NN, J.runs);
        legsN = J.runs(allN);
        if numel(legsN) > 1
            for fld = ["yD_keV_um", "nEff"]
                v = arrayfun(@(r) double(r.(fld)), legsN);
                tc.verifyTrue(all(isfinite(v)), ...
                    sprintf('%s 的 N=%d 有 %d/%d 条腿取不到有限值: 逐位去重会把它当数比', ...
                        fld, NN, sum(~isfinite(v)), numel(v)));
                % %.17g 才能区分 double 的每一位; string(数值) 退到 5 位有效数字就不是逐位了。
                parts = strsplit(strtrim(sprintf('%.17g\n', v)), newline);
                tc.verifyEqual(numel(unique(parts)), 1, ...
                    sprintf('产物 %s 的 N=%d 里跨 %d 条腿出现了 %d 个不同的 %s: 档位不该动中心量', ...
                        char(arts(m)), NN, numel(v), numel(unique(parts)), char(fld)));
                nChecks = nChecks + 1;
            end
        end
    end
end
% 防掏空守卫 (与 tableDistinct 的 nEntries 同一形态): 上面的短路分支如果全部走 continue,
% 这条用例可以一条断言都不执行而判绿, 那它就只是在假装对账。
tc.verifyGreaterThan(nEntries, 0, ...
    '没有任何 (档, N) 进入逐腿对账: 本用例一条承重断言都没执行, 表里的代价数字仍无人核');
tc.verifyEqual(nnz(covered), numel(T.tiers), ...
    sprintf('只有 %d/%d 个档位被产物覆盖: "三档不改中心量"其实只核了 %d 档', ...
        nnz(covered), numel(T.tiers), nnz(covered)));
tc.verifyGreaterThanOrEqual(nChecks, 3 * nEntries, ...
    sprintf('逐腿对账只执行了 %d 条断言 (%d 个 (档,N) 条目, 每条至少应有 uq_status 两条加 y_D/nEff 去重): 短路分支把它掏空了', ...
        nChecks, nEntries));
end

%% ============================================================ helper (全部带输出参数)

function [cds, lvls] = issuesOf(iss)
% validate 返回 **cell** (元素是 struct): 对它做 {s.code} 点展开是错的, 必须逐格取。
cds = strings(0, 1);
lvls = strings(0, 1);
for i = 1:numel(iss)
    cds(end+1) = string(iss{i}.code);    %#ok<AGROW>
    lvls(end+1) = string(iss{i}.level);  %#ok<AGROW>
end
end

function cfg = resolvedCfg(R)
% 提交后的路径是 <run>/input/config_resolved.json; 未提交的中间态才在 <run>/_work/input/。
% 两个都试并把候选路径一起报出来 —— 判据不该因为猜错目录而退化成"缺文件"。
cand = strings(0, 1);
if isfield(R.runDir, 'root')
    cand(end+1) = fullfile(R.runDir.root, 'input', 'config_resolved.json');  %#ok<AGROW>
end
if isfield(R.runDir, 'work') && isfield(R.runDir.work, 'input')
    cand(end+1) = fullfile(R.runDir.work.input, 'config_resolved.json');  %#ok<AGROW>
end
p = "";
for i = 1:numel(cand)
    if isfile(cand(i)), p = cand(i); break; end
end
tc_true(p ~= "", sprintf('两个候选路径都没有 config_resolved.json: %s', ...
    strjoin(cellstr(cand), ' | ')));
fid = fopen(p, 'r', 'n', 'UTF-8');
tc_true(fid > 0, sprintf('打不开 %s', p));
raw0 = fread(fid, Inf, 'uint8=>uint8');
fclose(fid);
txt = native2unicode(raw0(:)', 'UTF-8');
J = jsondecode(txt);
tc_true(isfield(J, 'cfg'), 'config_resolved.json 里没有 cfg 字段');
cfg = J.cfg;
end

function t = isEmptyStr(x)
s0 = string(x);
t = isempty(s0) || strlength(s0(1)) == 0;
end

function v = depthVector(paths, vals)
% 与读取器同一口径的生效向量 (排序后拼接): 这里独立复算, 因为要证的就是"次序无关"。
[srt, ix] = sort(string(paths));
parts = strings(1, numel(srt));
for i = 1:numel(srt)
    parts(i) = srt(i) + "=" + fmtScalar(vals{ix(i)});
end
v = char(strjoin(cellstr(parts), ';'));
end

function s = fmtScalar(x)
if islogical(x)
    if x
        s = "true";
    else
        s = "false";
    end
else
    s = string(sprintf('%g', double(x)));
end
end

function f = writeFixture(paths, vals)
f = fixtureDirFile('tiers_fx.json');
kn = strings(0, 1);
for i = 1:numel(paths)
    kn(end+1) = sprintf('{ "path": "%s", "value": %s }', ...
        char(string(paths{i})), char(fmtScalar(vals{i})));  %#ok<AGROW>
end
body = sprintf(['{ "schema": "tepc-uncertainty-depth-tiers-v1", "tiers": [' ...
    '{ "id": "t1", "label": "x", "disclosure": "d", "knobs": [ %s ] } ] }'], ...
    char(strjoin(cellstr(kn), ', ')));
writeUtf8(f, body);
end

function f = writeDupTiers()
f = fixtureDirFile('tiers_dup.json');
body = ['{ "schema": "tepc-uncertainty-depth-tiers-v1", "tiers": [' ...
    '{ "id": "a", "label": "x", "disclosure": "d", "knobs": [' ...
    '{ "path": "uq.enabled", "value": true } ] },' ...
    '{ "id": "b", "label": "y", "disclosure": "d", "knobs": [' ...
    '{ "path": "uq.enabled", "value": true } ] } ] }'];
writeUtf8(f, body);
end

function f = writeEmptyKnobs()
f = fixtureDirFile('tiers_empty.json');
body = ['{ "schema": "tepc-uncertainty-depth-tiers-v1", "tiers": [' ...
    '{ "id": "z", "label": "x", "disclosure": "d", "knobs": [] } ] }'];
writeUtf8(f, body);
end

function f = fixtureDirFile(name)
d = fullfile(tempdir, sprintf('tepc_depthfx_%d', feature('getpid')));
if ~isfolder(d), mkdir(d); end
f = fullfile(d, sprintf('%d_%s', round(now*1e6), name));
end

function writeUtf8(p, body)
fid = fopen(p, 'w', 'n', 'UTF-8');
tc_true(fid > 0, sprintf('写不出合成档位表: %s', p));
fwrite(fid, char(string(body)), 'char');
fclose(fid);
end

function v = getNested(cfg, parts)
v = cfg;
for i = 1:numel(parts)
    fld = char(parts(i));
    tc_true(isfield(v, fld), sprintf('配置里没有路径元素 %s', fld));
    v = v.(fld);
end
end

function cfg = rmNested(cfg, parts)
% 删掉 run.uncertaintyDepth 这类嵌套字段 (parts 是**一层一个元素**的 cellstr);
% 任一层不存在就原样返回。
if isempty(parts), return; end
head = char(string(parts{1}));
if ~isfield(cfg, head), return; end
if numel(parts) == 1
    cfg = rmfield(cfg, head);
    return
end
cfg = setfield(cfg, head, rmNested(cfg.(head), parts(2:end)));
end

function td = depthTempDir(tag)
td = fullfile(tempdir, sprintf('tepc_depth_%s_%s_%d', tag, ...
    char(string(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd_HHmmssSSS'))), ...
    feature('getpid')));
if isfolder(td)
    error("tepc:tests:DepthBusy", "临时目录已存在, 拒绝复用: %s", td);
end
mkdir(td);
end

function t = filereadInUtf8(p)
tc_true(isfile(p), sprintf('缺文件 %s', p));
fid = fopen(p, 'r', 'n', 'UTF-8');
tc_true(fid > 0, sprintf('打不开 %s', p));
raw0 = fread(fid, Inf, 'uint8=>uint8');
fclose(fid);
t = string(native2unicode(raw0(:)', 'UTF-8'));
end

function tc_true(cond, msg)
% 前置断言不接 tc (helper 带 tc 会被当成用例收集, 单参数才是用例)。
if ~cond
    error("tepc:tests:DepthPrecond", "%s", char(string(msg)));
end
end
