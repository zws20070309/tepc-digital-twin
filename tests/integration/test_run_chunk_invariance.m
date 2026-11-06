function tests = test_run_chunk_invariance
%TEST_RUN_CHUNK_INVARIANCE 事件分块大小只是计算参数：两跑的事件数据与发布值必须逐位同。
%   仓库里已有的两处相关锁各核一半：test_false_trigger_rate 比 chunkSize 100/2000 下的
%   flags 与 weight，test_resume_bit_exact 比"续跑 vs 一次跑完"的 yF/yD。**没有任何一条
%   在相同 N 下比过发布值 yF 随 chunkSize 不变，也没有一条核过"分段按权重合并 == 整表"**
%   (本轮实测: grep chunkSize 与 yF 在同一测试文件里的交集为空)。本文件补这两条。
%
%   三条判据各自独立：
%     A 参数被消费   两跑的 completed_chunks 互不相同 (读各自 logs/STATUS.json,
%                    并要 status=="completed"：崩溃跑也会写 completed_chunks)。
%                    不同 ⇒ B 的"逐位相同"不是"两次算了同一件事"的空转。
%     B 事件与发布值 /events 下数据集名字集合双向相等、类型相等、值逐位相等；
%                    summary.yF_keV_um 逐位相等 (AbsTol 0)。
%     C 估计量可加性 用**生产同一个** tepc.analysis.buildSpectrum 把整表按行切段,
%                    核 sum(W_l.*yF_l)/sum(W_l) == 整表 yF_exact。
%                    它核的是估计量的代数性质, 与 A/B 无关: 分块无关性成立时它仍可能红。
%   口径如实：chunkSize 在配置身份里 (execute.m 的保守设计: 凡可能影响结果的量都进哈希),
%   所以两跑严格来说是"两份被记为不同的配置"。本锁的主张只是: 这个被保守对待的参数
%   实际不进入事件计算。这里核的是解析代理模型计算链的数值不变性, 与实测装置无关。
tests = functiontests(localfunctions);
end

function test_chunkSize_is_computation_only(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
cfg.uq.enabled = false;                          % 本锁不核 UQ, 带上会把分钟级成本混进来
if isfield(cfg, 'waveform'), cfg.waveform.enabled = false; end
Nev = 120;
% 每次一个新目录: 绝不删除已存在的目录 (execute 的 AlreadyCommitted 守卫存在的理由就是
% 覆盖已发布产物会丢溯源, 测试不能靠"先删了再说"绕开它)。
% 名字必须"每次进程都不同": MATLAB 的全局随机流跨进程默认同种子, 用 randi 取随机数会得到
% 同一个名字, 于是一次被中途杀掉的跑留下的目录就把之后每一跑都判成"撞名"且永远恢复不了。
% 时间戳(毫秒) + 进程号才给到进程级唯一; 撞上了仍按拒绝复用报错, 不做删除。
td = fullfile(tempdir, sprintf('tepc_chunkinv_%s_%d', ...
    char(string(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd_HHmmssSSS'))), ...
    feature('getpid')));
if isfolder(td)
    error("tepc:tests:ChunkInvBusy", "临时目录已存在, 拒绝复用: %s", td);
end
mkdir(td);
% 局部 onCleanup 句柄活到本用例结束 (它一旦离开作用域就触发 rmdir)。
cleanupDir = onCleanup(@() rmdir(td, 's'));  %#ok<NASGU>
dA = fullfile(td, 'ck7');  dB = fullfile(td, 'ck1000');
cA = cfg; cA.run.chunkSize = 7;
cB = cfg; cB.run.chunkSize = 1000;
RA = tepc.run.execute(cA, 'N', Nev, 'Seed', 6060, 'RunDir', dA);
RB = tepc.run.execute(cB, 'N', Nev, 'Seed', 6060, 'RunDir', dB);

% --- A: 参数确实进入计算 (块数不同), 且两跑都是完成态 -------------------------
nA = completedChunks(dA);  nB = completedChunks(dB);
tc.verifyNotEqual(nA, nB, sprintf( ...
    '两跑分块次数相同 (%d/%d): 后面的"逐位相同"就是空转, 本锁失去意义', nA, nB));
tc.verifyEqual(nA, ceil(Nev/7), 'AbsTol', 0, ...
    sprintf('chunkSize=7 应有 %d 块, 实得 %d (分块循环口径变了?)', ceil(Nev/7), nA));
tc.verifyEqual(nB, 1, 'AbsTol', 0, ...
    sprintf('chunkSize=1000 > N=%d 应一次跑完, 实得 %d 块', Nev, nB));
% chunkSize 进配置身份是保守设计 ⇒ 两跑的身份哈希本就该不同; 若相同反倒是假开关。
tc.verifyNotEqual(string(RA.config_sha256), string(RB.config_sha256), ...
    'chunkSize 没进配置身份: 与 execute 的保守哈希口径矛盾');

% --- B: 事件表与发布值逐位相同 ------------------------------------------------
hA = fullfile(RA.runDir.events, 'events.h5');
hB = fullfile(RB.runDir.events, 'events.h5');
na = groupDatasets(hA, '/events');
nb = groupDatasets(hB, '/events');
% 反空转: 两跑都只写出 0 个数据集时, 上面的双向 setdiff 与下面的逐位比较会一起真空通过。
% 数量取自 docs/counts.json 的静态口径 —— 顺带把"genCounts 声称的数据集个数"与"盘上真的
% 写了这么多"对起来, 两边任一侧漂了这里就红。
C = readJsonUtf8(fullfile(root, 'docs', 'counts.json'));
wantDs = double(C.counts.h5_datasets);
tc.verifyEqual(numel(na), wantDs, 'AbsTol', 0, sprintf( ...
    'A 的 /events 有 %d 个数据集, counts.json 声称 %d (逐位比较的样本量本身就不对)', numel(na), wantDs));
tc.verifyEqual(numel(nb), wantDs, 'AbsTol', 0, sprintf( ...
    'B 的 /events 有 %d 个数据集, counts.json 声称 %d', numel(nb), wantDs));
% 用显式集合比较而不是 verifySetEquality: 后者在 functiontests 建的 FunctionTestCase 上
% 不存在 (实测 MATLAB:noSuchMethodOrField), 而双向 setdiff 的失败信息本来就更有用。
tc.verifyEmpty(setdiff(na, nb, 'stable'), ...
    sprintf('仅 A 有的 /events 数据集: %s', strjoin(setdiff(na, nb, 'stable'), ', ')));
tc.verifyEmpty(setdiff(nb, na, 'stable'), ...
    sprintf('仅 B 有的 /events 数据集: %s', strjoin(setdiff(nb, na, 'stable'), ', ')));
nDiff = 0;
for i = 1:numel(na)
    % h5info 在组里列出的 Datasets.Name 是**组内短名** (event_id 而不是 /events/event_id),
    % h5read 却要求带前导 '/' 的完全路径 —— 直接拿 Name 去读会报 notFullPathName。
    ds = '/events/' + na(i);
    a = h5read(hA, ds);
    b = h5read(hB, ds);
    if ~(isequaln(a, b) && isequal(class(a), class(b)))
        nDiff = nDiff + 1;
        tc.verifyEqual(string(mat2str(size(a))), string(mat2str(size(b))), ...
            sprintf('数据集 %s 在两跑之间不同 (chunkSize 吃进了事件计算)', na(i)));
    end
end
tc.verifyEqual(nDiff, 0, 'AbsTol', 0, ...
    sprintf('%d 个事件数据集随 chunkSize 变了', nDiff));
tc.verifyEqual(RA.summary.yF_keV_um, RB.summary.yF_keV_um, 'AbsTol', 0, sprintf( ...
    '发布值 yF 随 chunkSize 变了: %.17g vs %.17g (相对差 %.3e)', ...
    RA.summary.yF_keV_um, RB.summary.yF_keV_um, ...
    abs(RA.summary.yF_keV_um - RB.summary.yF_keV_um)/max(abs(RA.summary.yF_keV_um),eps)));

% --- C: 估计量可加性 (在 A 那张表上切段) --------------------------------------
yF = pooledBySegments(hA, RA);
tc.verifyTrue(yF.ok, sprintf('分段合并核对失败: %s', yF.detail));
tc.verifyTrue(yF.refMatchesPublished, ...
    sprintf('整表复算没对上发布值, 后面的可加性就不是对发布值的可加性: %s', yF.detail));
end

function test_pooling_probe_is_falsifiable(tc)
% 不跑仿真, 只用合成权重证明 C 的判据会红: 段权取成"事件数"而不是"权重和"时,
% 在有零权重 (DAQ 拒收) 的表上必须与整表值不符。没有这一条, C 只是"看着成立"。
rngSeed = 7;
rs = RandStream('Threefry', 'Seed', rngSeed);
n = 400;
epsV = 1 + 3*rand(rs, n, 1);
w = ones(n, 1);
w(rand(rs, n, 1) < 0.25) = 0;             % 造零权重行 (与 DAQ 拒收同形状)
tc.verifyGreaterThan(nnz(w == 0), 0, ...
    '合成表里必须真有零权重行: 全 1 权重时"权重和"与"事件数"两种段权恒等, 负控证不出区别');
lbar = 6.6667;
% 边界只需合法 (严格递增且为正, buildSpectrum 会拒 0): yF_exact 用的是逐事件精确矩,
% 掩码 ok = isfinite(y)&y>0&w>0&~zeroDep 与分箱无关, 所以下面的可加性与 edges 无关。
edges = linspace(0.05, 5, 26);
Sfull = tepc.analysis.buildSpectrum(epsV, lbar, w, edges, struct());
cut = round(linspace(0, n, 4));
yl = zeros(1, numel(cut)-1);  Wl = zeros(1, numel(cut)-1);  Nl = zeros(1, numel(cut)-1);
for i = 1:numel(cut)-1
    seg = (cut(i)+1):cut(i+1);
    Sk = tepc.analysis.buildSpectrum(epsV(seg), lbar, w(seg), edges, struct());
    yl(i) = Sk.yF_exact;  Wl(i) = Sk.SW_valid;  Nl(i) = numel(seg);
end
% 负控必须走同一段合并代码: 否则它测的是自己另写的一份算式, 把生产路径改错也不会红。
good = poolByWeight(Wl, yl);
badAsCount = poolByWeight(Nl, yl);
tc.verifyEqual(good, Sfull.yF_exact, 'RelTol', 1e-12, ...
    '合成表上"权重和加权"就不等于整表值: 可加性本身不成立, C 的算法写错了');
tc.verifyNotEqual(badAsCount, Sfull.yF_exact, ...
    '用"事件数"当段权居然也对上: 有零权重时这两种权法必须分开, 否则 C 证不出区别');
end

% ==================== helpers (带输出参数, 不被静态计数当用例) ====================

function p = poolByWeight(W, y)
%POOLBYWEIGHT 分段值的权重合并 —— 可加性判据与被检的负控共用这一份算式。
%   两条锁 (整表==分段、以及"段权取错必须对不上") 必须走同一段代码: 各自另写一遍
%   sum(W.*y)/sum(W) 的话, 改错生产侧的合并式也不会让负控变红。
p = sum(W .* y) / sum(W);
end

function S = readJsonUtf8(p)
% 显式按 UTF-8 取字节再解: fileread 走本机码页 (中文 Windows 是 GBK), 而 counts.json /
% STATUS.json 都是 UTF-8 写的, 属性名不受影响但字符串值会成乱码。
tc_true(isfile(p), sprintf('缺 %s', p));
fid = fopen(p, 'r', 'n', 'UTF-8');
b = fread(fid, inf, 'char=>char');
fclose(fid);
S = jsondecode(b(:)');
end

function s = completedChunks(runDir)
% 分块次数只认该跑自己写的 logs/STATUS.json, 并要 status=="completed":
% cancel/fail 路径同样写 completed_chunks, 只看它就等于让崩溃跑帮忙凑"参数被消费"。
S = readJsonUtf8(fullfile(runDir, 'logs', 'STATUS.json'));
tc_true(isfield(S,'status') && isfield(S,'completed_chunks'), ...
    sprintf('STATUS.json 缺 status/completed_chunks'));
tc_true(strcmp(string(S.status), "completed"), ...
    sprintf('该跑不是完成态 (%s), 不能用它的分块数当判据', string(S.status)));
s = double(S.completed_chunks);
end

function y = pooledBySegments(h5path, R)
% 用生产同一个 buildSpectrum 复算整表与分段, 返回判据与逐条数值 (全部进 detail 文本)。
y = struct('ok', false, 'refMatchesPublished', false, 'detail', '');
% h5read 的返回值不能直接接 (:) —— MATLAB 不允许在函数调用结果后再加圆括号索引
% (解析期就报"无效索引", 且整份文件会被 TestSuite 静默丢掉), 所以一律先落临时变量。
epsM0 = h5read(h5path, '/events/epsilon_meas_keV');   epsM = double(epsM0(:));
epsG0 = h5read(h5path, '/events/EdepGas_keV');        epsG = double(epsG0(:));
w0    = h5read(h5path, '/events/weight');             w    = double(w0(:));
lbv0  = h5read(h5path, '/events/lbar_tissue_um');     lbv  = double(lbv0(:));
lbar = lbv(1);
if ~all(lbv == lbar)
    y.detail = sprintf('lbar_tissue_um 非同一标量 (min %.6g max %.6g)', min(lbv), max(lbv));
    return
end
edges = double(R.analysis.spectrum.edges(:)).';
% 发布用的是哪一列由 analyze 的标定分支决定 (epsilon_meas 整列 NaN 即无标定链):
% 不做"哪个接近选哪个"的猜测 —— 选错就是判据在自证, 宁可红并报出两列各自的对不上。
if all(isnan(epsM))
    epsPub = epsG;   col = "EdepGas_keV (epsilon_meas 整列 NaN: 无标定链)";
else
    epsPub = epsM;   col = "epsilon_meas_keV";
    epsPub(~isfinite(epsPub)) = 0;      % 与 analyze.m 同一处理: 无效测量按 0 入谱
end
Sfull = tepc.analysis.buildSpectrum(epsPub, lbar, w, edges, struct());
y.refMatchesPublished = Sfull.yF_exact == R.summary.yF_keV_um;
n = numel(epsPub);
cut = unique(round(linspace(0, n, 4)), 'stable');
if numel(cut) < 3
    y.detail = sprintf('N=%d 切不出 >=2 个非空段', n);
    return
end
yl = zeros(1, numel(cut)-1);
Wl = zeros(1, numel(cut)-1);
for i = 1:numel(cut)-1
    seg = (cut(i)+1):cut(i+1);
    Sk = tepc.analysis.buildSpectrum(epsPub(seg), lbar, w(seg), edges, struct());
    yl(i) = Sk.yF_exact;
    Wl(i) = Sk.SW_valid;
end
pooled = poolByWeight(Wl, yl);
relErr = abs(pooled - Sfull.yF_exact)/max(abs(Sfull.yF_exact), eps);
y.ok = y.refMatchesPublished && relErr <= 1e-12;
y.detail = sprintf(['列=%s 整表复算 %.17g 发布 %.17g (逐位对上=%s); %d 段加权合并 %.17g ' ...
    '相对偏差 %.3e (阈值 1e-12 = 浮点重结合量级, 非物理容差)'], ...
    col, Sfull.yF_exact, R.summary.yF_keV_um, mat2str(y.refMatchesPublished), ...
    numel(yl), pooled, relErr);
end

function nm = groupDatasets(path, grp)
info = h5info(path);
want = string({info.Groups.Name});
k = find(want == grp, 1);
tc_true(~isempty(k), sprintf('%s 里没有 %s 组', path, grp));
ds = info.Groups(k).Datasets;
nm = string({ds.Name}');
end

function tc_true(cond, msg)
% 断言不依赖 tc (helper 不接 tc 才不会被 genCounts 的 (tc) 签名口径当用例): 这里只做
% "拿不到输入就直接报错"的硬前置, 判据本身仍由用例里的 verify* 给。
if ~cond
    error("tepc:tests:ChunkInvPrecond", "%s", char(string(msg)));
end
end
