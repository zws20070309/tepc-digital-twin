function out = uncertaintyDepthLadder(varargin)
%UNCERTAINTYDEPTHLADDER 实测"不确定度传播深度"三个档在各工作点上的墙钟代价。
%   out = uncertaintyDepthLadder()                 默认两点 (N=400 与 N=2500)
%   out = uncertaintyDepthLadder('Quick', true)    只跑小工作点 (冒烟用)
%   out = uncertaintyDepthLadder('Pairs', k)       每档重复几对 (默认 2, 每对内 ABBA 交替)
%   out = uncertaintyDepthLadder('MinFreeMb', 3500) 独占门槛 (0 = 不检查)
%
%   大工作点为什么是 2500 而不是原先声明的 10000: 这条阶梯要答的问题是"关掉 UQ 省下的
%   占比随 N 升还是降", 而 execute.m 的 NEvPerSample=max(300,min(N,2000)) 在 N>2000 封顶。
%   10000 按产物每事件墙钟外推要 3 台时以上、6 腿根本不可能独占, 而**封顶效应只需要
%   N 跨过 2000 就能观测**; 400 (封顶以下, UQ 与主循环同样线性) 与 2500 (封顶以上, UQ
%   的每样本事件数不再随 N 涨) 这两个点正是那条分界线两侧。要再往上的标度律得另测,
%   不许从这两个点外推。
%
%   产物: docs/test_evidence/uncertainty_depth_ladder_<utc>.json + 同名 .log
%   (.log 是必需的: tools/writeLatestEvidence 的哈希表收 docs/test_evidence 下的 *.log
%    与被它显式点名的若干文件; 落单 .json 的那批 09-25 产物因此一直没进索引 —— 本工具
%    现在当场复核两份都在, 缺一份就抛错, 而不是留一个没人知道的产物。)
%
%   设计约束 (都是被实测咬过之后写死的):
%   1) **不写墙钟判据进套件** —— 同配置两腿的墙钟实测离散 ±24%, 任何单次比较都会因
%      GC/杀软/并发翻红。所以这里只做"记录 + 报 min 与 median", 不做通过/失败断言。
%   2) **两个工作点都要测, 不许外推** —— 见上面 2500 那段。
%   3) **每条腿都记中心量** —— 档位本不该动中心量; 数字若不同, 说明有回流, 那比墙钟重要。
%   4) **环境量同批记** —— 空闲内存与并发 MATLAB 数: 没有它们, 墙钟数字无法判读。
%      这一条先前是**空头承诺**: free_mb 用 memory() 的 MemMaxAvailable 取, 本机没这
%      个字段而取数又包在裸 catch 里, 于是产物里那一列整批是 null。现在改走
%      tepc.io.hostMemory (按操作系统取, 并把"从哪儿取到的"一起记), 并在开跑前查独占。

root = tepc.io.projectRoot();
opt = struct('quick', false, 'pairs', 2, 'nsmall', 400, 'nbig', 2500, 'seed', 24680, ...
    'minFreeMb', 3500);
fnames = string(fieldnames(opt));
for i = 1:2:numel(varargin)
    % 选项名按"小写并去下划线"匹配字段: isfield 大小写敏感, 直接 lower(传入名) 会把
    % 'MinFreeMb' 判成未知选项 (探针那边实测就是这样自拒了一次, 这里一起修掉)。
    key = strrep(lower(strtrim(string(varargin{i}))), '_', '');
    j = find(key == strrep(lower(fnames), '_', ''), 1);
    if isempty(j)
        error("tepc:tools:DepthLadderOpt", "未知选项 %s (可用: %s)", ...
            char(varargin{i}), strjoin(fnames, ', '));
    end
    opt.(char(fnames(j))) = varargin{i+1};
end
T = tepc.config.uncertaintyDepthTiers();
Ns = unique([opt.nsmall, opt.nbig]);
if logical(opt.quick), Ns = Ns(1); end

env0 = tepc.io.hostMemory();
if logical(opt.minFreeMb) && env0.free_mb < opt.minFreeMb
    error("tepc:tools:DepthLadderHostBusy", ...
        ['开跑前独占门槛没过: 空闲 %.0f MB < %.0f MB, MATLAB 镜像行 %d (>2 说明机器上不止一条链)。 ' ...
         '墙钟是本产物的唯一被测对象, 与第二个进程并发时它测的是调度而不是档位。'], ...
        env0.free_mb, opt.minFreeMb, env0.matlab_processes);
end
fprintf('开跑前环境: free_mb=%.0f total_mb=%.0f matlab_rows=%s source=%s\n', ...
    env0.free_mb, env0.total_mb, mat2str(env0.matlab_processes), env0.source);

% 探针自己的 run 目录一律落到仓库外, 且必须**先建目录**: io/runDirs 要求目标已存在,
% 否则重定向静默作废、11 个 run 目录会漏进仓库 runs/ (实测踩过)。
scratch = fullfile(tempdir, sprintf('tepc_depthladder_%d', feature('getpid')));
mkdir(fullfile(scratch, 'runs'));
oldEnv = getenv('TEPC_RUNS_DIR');
setenv('TEPC_RUNS_DIR', scratch);
cleanupEnv = onCleanup(@() restoreEnv(oldEnv, scratch));  %#ok<NASGU>

legs = T.ids;
recs = struct('N', {}, 'tier', {}, 'pair', {}, 'order', {}, 'wall_s', {}, ...
    'yF_keV_um', {}, 'yD_keV_um', {}, 'nEff', {}, 'uq_status', {}, ...
    'config_sha256', {}, 'free_mb', {}, 'matlab_rows', {}, 'env_source', {}, ...
    'run_dir', {});
for nIdx = 1:numel(Ns)
    N = Ns(nIdx);
    % ABBA: 第 p 对里腿序正着走一遍再倒着走一遍, 让"晚跑更慢/更快"的系统效应在对内相消。
    base = legs;
    order = [base, flip(base)];
    for p = 1:opt.pairs
        for q = 1:numel(order)
            cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
            cfg.run.uncertaintyDepth = char(order(q));
            t0 = tic;
            R = tepc.run.execute(cfg, 'N', N, 'Seed', opt.seed, ...
                'RunDir', fullfile(scratch, 'runs', sprintf('l_%d_%d_%d', N, p, q)));
            wall = toc(t0);
            env = tepc.io.hostMemory();
            s = R.summary;
            rec = struct('N', N, 'tier', char(order(q)), 'pair', p, 'order', q, ...
                'wall_s', wall, 'yF_keV_um', dbl(s, 'yF_keV_um'), ...
                'yD_keV_um', dbl(s, 'yD_keV_um'), 'nEff', dbl(s, 'nEff'), ...
                'uq_status', char(string(s.uq_status)), ...
                'config_sha256', char(string(R.config_sha256)), ...
                'free_mb', env.free_mb, 'matlab_rows', env.matlab_processes, ...
                'env_source', env.source, 'run_dir', R.runDir);
            recs(end+1) = rec; %#ok<AGROW>
            fprintf('N=%-6d %-10s pair=%d leg=%d  wall=%7.2f s  yF=%.6f  uq=%s\n', ...
                N, rec.tier, p, q, wall, rec.yF_keV_um, rec.uq_status);
        end
    end
end

stamp = char(datetime('now', 'TimeZone', 'UTC', 'Format', "yyyyMMdd'T'HHmmss'Z'"));
dirEv = fullfile(root, 'docs', 'test_evidence');
if ~isfolder(dirEv), mkdir(dirEv); end
jf = fullfile(dirEv, sprintf('uncertainty_depth_ladder_%s.json', stamp));
lf = fullfile(dirEv, sprintf('uncertainty_depth_ladder_%s.log', stamp));
payload = struct('generated_utc', char(datetime('now', 'TimeZone', 'UTC', ...
        'Format', "yyyy-MM-dd'T'HHmmss'Z'")), ...
    'seeds', opt.seed, 'pairs', opt.pairs, 'tiers', {cellstr(legs)}, ...
    'N_points', Ns, 'quick', logical(opt.quick), 'min_free_mb', opt.minFreeMb, ...
    'env_at_start', env0, ...
    'note', '墙钟只作记录, 不作判据 (同配置两腿实测离散 ±24%)。中心量若跨档不同即为缺陷。', ...
    'summary_by_N_tier', summarize(recs), 'runs', {recs});
tepc.io.writeJson(jf, payload);
txt = ladderText(payload, recs);
fid = fopen(lf, 'w', 'n', 'UTF-8');
if fid < 0
    error("tepc:tools:DepthLadderLogUnwritable", "写不了 %s", lf);
end
fwrite(fid, txt, 'char');
fclose(fid);
% 当场复核成对: 只有 .json 的产物不进 writeLatestEvidence 的哈希表, 而这张表是"数字要能
% 追到产物"这句话的唯一机读出口。09-25 那批就是这样落单的, 所以这里宁可直接抛错。
if ~(isfile(jf) && isfile(lf))
    error("tepc:tools:DepthLadderPairMissing", "产物不成对: json=%d log=%d", isfile(jf), isfile(lf));
end
fprintf('产物: %s\n产物: %s\n', jf, lf);
out = struct('json', jf, 'log', lf, 'runs', {recs});
end

function S = summarize(recs)
% 按 (N, 档) 分组报 min 与 median (不报均值: 两腿抖动是重尾的, 均值会被单次慢跑拉走)。
keys = strings(0, 1);
for i = 1:numel(recs)
    keys(end+1) = sprintf('%d|%s', recs(i).N, recs(i).tier);  %#ok<AGROW>
end
[ukeys, ~, ic] = unique(cellstr(keys));
S = struct('N', {}, 'tier', {}, 'n_legs', {}, 'wall_min_s', {}, 'wall_median_s', {}, ...
    'yF_all_equal', {}, 'yF_values', {});
for k = 1:numel(ukeys)
    m = (ic == k);
    w = double([recs(m).wall_s]);
    y = {recs(m).yF_keV_um};
    okEq = all(cellfun(@(v) isequaln(v, y{1}), y));
    parts = strsplit(string(ukeys{k}), '|');
    one = struct('N', str2double(parts{1}), 'tier', char(parts{2}), 'n_legs', nnz(m), ...
        'wall_min_s', min(w), 'wall_median_s', median(w), ...
        'yF_all_equal', okEq, 'yF_values', {y});
    S(end+1) = one; %#ok<AGROW>
end
end

function t = ladderText(payload, recs)
L = {'# TEPC 不确定度传播深度阶梯 (墙钟只作记录, 不作判据)', ...
     sprintf('# generated_utc : %s', payload.generated_utc), ...
     sprintf('# seeds=%d pairs=%d quick=%s N_points=%s tiers=%s', payload.seeds, ...
     payload.pairs, mat2str(payload.quick), mat2str(payload.N_points), ...
     strjoin(payload.tiers, ',')), ...
     sprintf('# 开跑前环境: free_mb=%.0f total_mb=%.0f matlab_rows=%s source=%s (读数>2 即机器上不止一条链)', ...
     payload.env_at_start.free_mb, payload.env_at_start.total_mb, ...
     mat2str(payload.env_at_start.matlab_processes), payload.env_at_start.source), ...
     '# N  tier         pair leg  wall_s     y_F        y_D        nEff   uq_status   free_mb  rows', ...
     '# ------------------------------------------------------------------------------'};
for i = 1:numel(recs)
    r = recs(i);
    L{end+1} = sprintf('%-5d %-12s %4d %3d %9.2f %10.6f %10.6f %6g  %-9s %8.0f %4d', ...
        r.N, r.tier, r.pair, r.order, r.wall_s, r.yF_keV_um, r.yD_keV_um, ...
        r.nEff, r.uq_status, r.free_mb, r.matlab_rows);  %#ok<AGROW>
end
for k = 1:numel(payload.summary_by_N_tier)
    s = payload.summary_by_N_tier(k);
    L{end+1} = sprintf('SUMMARY N=%d tier=%-10s legs=%d wall_min=%.2f wall_median=%.2f per_event=%.4f yF_all_equal=%s', ...
        s.N, s.tier, s.n_legs, s.wall_min_s, s.wall_median_s, ...
        s.wall_median_s/s.N, mat2str(s.yF_all_equal));  %#ok<AGROW>
end
t = strjoin(cellstr(L), sprintf('\n'));
end

function v = dbl(s, f)
if isfield(s, f) && ~isempty(s.(f)) && isnumeric(s.(f))
    v = double(s.(f));
else
    v = NaN;
end
end

function restoreEnv(oldEnv, scratch)
if isempty(oldEnv)
    unsetenv('TEPC_RUNS_DIR');
else
    setenv('TEPC_RUNS_DIR', oldEnv);
end
if isfolder(scratch)
    rmdir(scratch, 's');
end
end
