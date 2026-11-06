function R = execute(cfg, varargin)
%RUNEXECUTE 一键运行编排: 解析配置->哈希->几何->源项->事件->仪器链
%   ->电荷注入刻度->谱分析->写出->门禁。分块执行, 每 chunk 写 checkpoint(RNG 状态
%   + 跨块死时间) 可续跑。
%   Name-Value: 'N' 覆盖事件数, 'Seed', 'RunDir', 'Progress' 句柄 f(frac,msg),
%   'CancelFlag'/'PauseFlag' 文件路径, 'Resume' true 从 RunDir 续跑。
%   取消: 已完成 chunk 保留 raw/, 写 STATUS=CANCELLED, 抛出并停止(不写最终结果)。
%   续跑: 必须 seed 与 config_sha256 与 checkpoint 一致, 否则拒绝 (防止混合两种机制)。

args = parseArgs(varargin);
root = tepc.io.projectRoot();

% --- API 覆盖必须**前移**到 validate/resolve/写盘/哈希之前 -----------------
% 旧顺序: 先写 config_resolved.json 并哈希, 之后才把 args.Seed 写回
% cfg。于是 checkpoint 与 provenance 里的 config_sha256 与实际跑的
% seed 无关 —— 换 seed 不改哈希, 续跑守卫给出"可复现性假象"。
[cfg, apiOverrides] = applyRunArgs(cfg, args);

issAll = tepc.config.validate(cfg);
errs = errorIssues(issAll);
if ~isempty(errs)
    error("tepc:run:ConfigInvalid","配置校验失败: %s", ...
        strjoin(cellfun(@(s) string(s.message), errs), ' | '));
end
% 档位并须在 validate **之后** (之前并会让拼错的档名抛成裸错, 丢掉 DEPTH_UNKNOWN 的
% 带级别诊断), 且必须在下面 cfgId = cfg **之前** (之后并会让 config_sha256 对档位失明,
% 粗档就能冒充细档续跑)。
[cfg, depth] = tepc.config.applyDepthTier(cfg);
prog = @(frac,msg) progCall(args.Progress, frac, msg);
prog(0.02, '配置校验通过');

% 目标目录若已是一次"已提交 (completed)"的发布集, 它对外就是只读的历史:
%   * 非 Resume 重跑 → 直接拒 (tepc:run:AlreadyCommitted)。曾实测: workflows/run_demo.m
%     就是往已提交目录里再写一遍 report.html, 于是 provenance 的"哈希=内容"当场失效。
%   * 被守卫**拒绝**的 Resume 尝试 (seed/sha 不符、旧布局) 一行记账都不该留下 ——
%     下面 failStatus 的 guardOnly 分支会把 STATUS.json **逐字还原**。只"跳过写入"不够:
%     本函数在守卫之前已无条件写过 running, 那会把 completed 抹掉, 于是
%     AlreadyCommitted 这道门自己把自己解除武装 (故障注入测试实测: 一次错误 seed 的
%     被拒续跑之后, 全新一次 non-Resume 运行不报错地静默覆盖了整个已发布产物集)。
frozenPrev = false;
prevStatusBackup = "";
if ~isempty(args.RunDir)
    rd = tepc.io.runDirsForPath(args.RunDir);
    spPrev = fullfile(rd.logs, 'STATUS.json');
    if isfile(spPrev)
        % 备份的是**字节** (copyfile), 不是文本: 本文件按 UTF-8 写、本机默认字符集是 GBK,
        % 用 fileread+回写会把中文 reason 解码成乱码, 还原反而成了破坏。
        prevStatusBackup = fullfile(tempdir, ...
            sprintf('tepc_status_backup_%s_%d.json', rd.runID, feature('getpid')));
        copyfile(spPrev, prevStatusBackup, 'f');
        s0 = jsondecode(fileread(spPrev));
        frozenPrev = string(s0.status) == "completed";
        if ~args.Resume && frozenPrev
            error("tepc:run:AlreadyCommitted", ...
                ['RunDir %s 已是一次已提交 (completed) 的运行, 拒绝覆盖其已发布产物 ' ...
                 '(provenance 哈希会当场失真)。要换目录跑; 要跑更多事件用 Resume=true。'], ...
                rd.root);
        end
    end
else
    rd = tepc.io.runDirs(root);
end

% 运行期一律写 rd.work.*; rd.input/events/results/figures 是**提交后**的位置。
% (目录布局由 tepc.io.layoutRunDirs 唯一决定: logs/ 与 raw/ 在根, 发布集在 _work/)
%
% --- 进度 tee ---------------------------------------------------------------
% 后台/无头运行时"卡在哪一步"必须落盘可查 (否则半成品 run 目录无人记账,
% 事后只能靠 mtime 猜)。每步同时写 logs/PROGRESS.json; 写失败绝不反噬主流程。
userProg = args.Progress;
prog = @(frac, msg) progTee(userProg, rd, frac, msg);

% --- 失败记账前置初始化 -----------------------------------------------------
% catch 里要引用这些量, 因此它们**必须**在 try 之外完成初始化 (否则异常发生在赋值
% 之前时, catch 自己会因"未定义变量"再抛一次, 把真正的根因覆盖掉)。
seed = cfg.provenance.seed;
N = cfg.run.nEvents;
chunk = max(1, cfg.run.chunkSize);
chunks = cell(0, 1);
resumedFrom = 0;
liveSumS = 0;  spanSumS = 0;      % 活时间累计 (daq 区间并集), 续跑时从 checkpoint 恢复
sha = "";
phase = "init";

% 目录一旦建立, 之后任何一步失败都必须留下 STATUS=incomplete + logs/error*.json。
% 旧实现只有"事件循环"和"分析-提交"两段有 catch, 而 resolve/tables/calibration/
% 续跑守卫这一段抛错时磁盘上什么都不写 —— 一个 logs/ 全空、连 STATUS.json 都没有的
% 目录 (实测 runs/20260920_122507476-22860faca47d/) 就是这么来的。
% 注: try 体内的语句刻意保持原有缩进 (MATLAB 语法不依赖缩进), 以免整段重排掩盖真实改动。
tepc.io.runWriteStatus(rd.logs, 'running', 'Phase', phase, ...
    'Reason', '已启动: 配置校验通过, 事件尚未开始', ...
    'RunID', rd.runID, 'CompletedChunks', 0);
try
prog(0.05, '写出配置身份与哈希');
R = struct(); R.cfg = cfg; R.runDir = rd; R.issues = {};
R.api_overrides = apiOverrides;
Rcfg = tepc.config.resolve(cfg);
R.resolve = Rcfg;

% 配置**身份** = 去掉 run.nEvents 的 cfg + 有效 seed + chunkSize + API 覆盖 + schema。
%   * nEvents 刻意排除在外: 它是"这次跑多少个", 不是"这是什么配置"; 续跑正是靠
%     "同一配置跑更多事件" (test_resume_bit_exact 用 N=1000 -> N=2000)。放进身份
%     会让合法续跑被拒。seed **必须**在身份里。chunkSize 也在身份里, 但这是**保守**而不是
%     已知依赖: AnalyticAdapter 已把 mixed 源的类别标签改成每事件子流抽样, 结果不再随分块
%     边界变化 (那里的注释就是这个改动的理由), 所以这条只保证"换了分块方式必须看得出来"。
%   * 哈希对象 = 盘上 config_identity.json 的字节 (writeCanonicalJson 保证同源),
%     这样"哈希=内容"可被第三方独立复算; 人读的 config_resolved.json 仍然写全。
cfgId = cfg;
if isfield(cfgId, 'run') && isfield(cfgId.run, 'nEvents')
    cfgId.run = rmfield(cfgId.run, 'nEvents');
end
% 'N' 覆盖同样**不能**进身份: 否则"同一配置续跑到更多事件"会被自己的哈希守卫拒掉
% (实测: 先 N=400 再 N=800 续跑时报 config_sha256 不一致)。它仍然完整记录在
% config_resolved.json 的 nEvents_target / api_overrides 里, 只是不参与身份判定。
idOv = apiOverrides;
if ~isempty(idOv)
    % 必须用 string 数组比较: {idOv.name} 装的是 **string 标量**, 而 strcmp 对
    % "装着 string 的 cell" 恒给 false (本项目已在此栽过一次: 门禁计数器全为 0)。
    % 后果是 'N' 覆盖漏进配置身份 -> "同一配置续跑到更多事件"被自己的哈希拒掉
    % (实测 test_pipeline/test_resume_bit_exact 报 续跑 config_sha256 不一致)。
    keepN = string({idOv.name}) ~= "N";
    idOv = idOv(keepN);
end
if isempty(idOv)
    idOv = struct('name', {}, 'value', {});
end
idStruct = struct('checkpoint_schema_version', '2.0', ...
    'effective_seed', seed, 'chunk_size', chunk, ...
    'api_overrides', idOv, 'cfg', cfgId);
idOut = tepc.io.writeCanonicalJson(fullfile(rd.work.input, 'config_identity.json'), idStruct);
R.config_sha256 = idOut.sha256;
sha = idOut.sha256;                                  % catch 里要用的本地镜像
resolved = struct('cfg', cfg, ...
    'derived_notes', {Rcfg.notes{:}}, ...
    'rho_g_kg_m3', Rcfg.rho_g, 'lbar_gas_mm', Rcfg.geom.lbar_gas_m*1e3, ...
    'lbar_tissue_um', Rcfg.lbar_tissue_um, 'G_mean', Rcfg.G_mean, ...
    'electrode_topology', Rcfg.electrode.topology, ...
    'field_kind', Rcfg.field.kind, ...
    'site_equivalence_mode', Rcfg.siteMode, ...
    'site_requested_d_tissue_um', Rcfg.site_requested_d_tissue_m*1e6, ...
    'siteConsistency', Rcfg.siteConsistency, ...
    'effective_seed', seed, 'nEvents_target', N, ...
    'config_sha256', R.config_sha256, ...
    'checkpoint_schema_version', '2.0');
tepc.io.writeJson(fullfile(rd.work.input, 'config_resolved.json'), resolved);

prog(0.08, '阻止本领表与电子学系数');
phase = "tables";
tables = struct('proton', tepc.transport.stoppingPower(cfg, "proton"), ...
    'electron', tepc.transport.stoppingPower(cfg, "electron"), ...
    'heavy_C',  tepc.transport.stoppingPower(cfg, "heavy_C"), ...
    'heavy_O',  tepc.transport.stoppingPower(cfg, "heavy_O"));
[Qfun, qmeta] = tepc.analysis.qualityFactor(cfg.analysis.qualityFactor, root);
R.qmeta = qmeta;

ctx = struct('W_eV', cfg.gas.W_eV.value, 'fano', cfg.gas.fano.value, ...
    'field', Rcfg.field, 'mob', Rcfg.mob, 'seed', seed, ...
    'G_mean', Rcfg.G_mean, 'theta', tepc.config.constants('detector.polya.theta'), ...
    'r0_m', Rcfg.r0_m, ...
    'coeffs', tepc.electronics.filters(cfg));
[~, msig] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',seed+1), "sigma");
ctx.noiseSigma = msig.sigma_peak_V;
R.ctx = struct('W_eV',ctx.W_eV,'fano',ctx.fano,'seed',ctx.seed, ...
    'G_mean',ctx.G_mean,'theta',ctx.theta,'noiseSigma',ctx.noiseSigma, ...
    'hpeak',ctx.coeffs.hpeak,'Ts',ctx.coeffs.Ts,'Nwin',ctx.coeffs.Nwin);

prog(0.10, '电荷注入刻度 (与测量共用同一仪器链)');
phase = "calibration";
cal = tepc.calibration.injectCalibrate(cfg, ctx, int64(2e9));
R.cal = cal;
tepc.io.writeJson(fullfile(rd.work.input, 'calibration.json'), struct( ...
    'beta', cal.beta, 'cov', cal.cov, 'sigma_res', cal.sigma_res, ...
    'domain_C', cal.domain_C, 'quadratic', cal.quadratic, 'FS_code', cal.FS_code, ...
    'V_per_C', cal.V_per_C, 'threshold_V', cal.threshold_V, ...
    'note', cal.note, 'points', cal.points));

prog(0.14, '事件生成开始');
phase = "resume";
rs = RandStream('Threefry', 'Seed', seed);
firstID = 1; tNext = 0; busyUntil = -Inf; lastTrigEnd = -Inf;
chunksDone = 0; chunks = cell(0,1);
resumedFrom = 0;
if args.Resume && isfile(fullfile(rd.raw, 'checkpoint.json'))
    cp = jsondecode(fileread(fullfile(rd.raw, 'checkpoint.json')));
    % schema v1 的 config_sha256 不含有效 seed, 拿它当续跑守卫就是
    % "可复现性假象"。这类旧 run 一律拒绝续跑, 而不是假装兼容。
    if ~isfield(cp,'checkpoint_schema_version')
        error("tepc:run:LegacyCheckpoint", ...
            "checkpoint 是 v1 布局 (config_sha256 未包含有效 seed), 拒绝续跑; 请用新 RunDir 重跑");
    end
    if ~isfield(cp,'seed') || ~isfield(cp,'config_sha256')
        error("tepc:run:ResumeGuard","checkpoint 缺少 seed/config_sha256, 拒绝续跑");
    end
    if cp.seed ~= seed
        error("tepc:run:ResumeGuard","续跑 seed 不一致 (%g != %g)", cp.seed, seed);
    end
    if ~strcmp(char(cp.config_sha256), R.config_sha256)
        error("tepc:run:ResumeGuard","续跑 config_sha256 不一致, 拒绝混合两种机制的事件集");
    end
    if isfield(cp,'chunk_size') && cp.chunk_size ~= chunk
        error("tepc:run:ResumeGuard", ...
            "续跑 chunkSize 不一致 (%g != %g): 分块属于运行配置身份, 不一致即拒绝续跑 (保守判定, 不声称它改变哪一步)", ...
            cp.chunk_size, chunk);
    end
    if N < cp.lastEventID
        error("tepc:run:ResumeGuard","续跑目标 N=%d 小于已完成的 %d 事件", N, cp.lastEventID);
    end
    S = load(fullfile(rd.raw, sprintf('chunk_%06d.mat', cp.lastChunk)), 'rs');
    rs.State = S.rs.State;
    firstID = cp.lastEventID + 1; tNext = cp.tNext; busyUntil = cp.busyUntil;
    if isfield(cp,'lastTrigEnd'), lastTrigEnd = cp.lastTrigEnd; end
    if isfield(cp,'liveTime_s'), liveSumS = cp.liveTime_s; end
    if isfield(cp,'liveSpan_s'), spanSumS = cp.liveSpan_s; end
    chunksDone = cp.lastChunk;
    resumedFrom = cp.lastEventID;
    for ck2 = 1:chunksDone
        L = load(fullfile(rd.raw, sprintf('chunk_%06d.mat', ck2)), 'evCk');
        chunks{ck2} = L.evCk;
    end
    prog(0.14, sprintf('续跑: 已完成 %d chunk / %d 事件', chunksDone, resumedFrom));
elseif args.Resume
    error("tepc:run:ResumeGuard","指定 Resume 但 %s 不存在", fullfile(rd.raw,'checkpoint.json'));
end

totalChunks = ceil(N/chunk) + chunksDone;    % 目标: 共 N 个事件 (含续跑前已完成)
totalTarget = N;                             % N 为目标总数; 续跑从 resumedFrom+1 补齐
ck = chunksDone;
dt = cfg.electronics.deadTime_s;
% pile-up 窗 = **脉冲占用宽度** (单一真相源 tepc.electronics.pulseOccupancy_s)。
% 不能直接用配置里的 trigger.pileUpReject_s: 发货值 3 µs 小于死时间 tau=10 µs,
% 于是 busy 窗总是先关闭, PILEUP 分支在生产配置下永不可达 —— "堆叠脉冲清零权重"
% 这条决策就成了死代码 (实测确认: 5000 事件 run 里 PILEUP 计数恒 0)。
phase = "run";
puWin = tepc.electronics.pulseOccupancy_s(cfg);
% 触发延迟用**成形峰位置对应的确定时刻** (c.hidx*Ts), 不用逐事件实测 ipk*Ts:
% 后者被噪声驱动, 相邻事件可发生次序翻转, 会让"分块跑"与"整段跑"给出不同标志位。
latAbs = ctx.coeffs.hidx * ctx.coeffs.Ts;
F = tepc.domain.Flags();
    while firstID <= totalTarget
        checkFlags(args);                          % pause / cancel (取消即写 STATUS)
        nCk = min(chunk, totalTarget - firstID + 1);
        ck = ck + 1;
        [evCk, st] = tepc.transport.AnalyticAdapter(cfg, Rcfg.geom, tables, rs, nCk, firstID, ...
            struct('tNext', tNext));
        [q, instr] = tepc.electronics.simulate(evCk.ev.EdepGas_keV, firstID, cfg, rs, ctx);
        evCk.ev.charge_C    = q;
        evCk.ev.peak_V      = instr.peak_V;
        evCk.ev.adc_code    = instr.adc_code;
        evCk.ev.adc_range   = instr.range;
        evCk.ev.t_trigger_s = instr.t_trigger_s;
        evCk.ev.r0_m        = instr.r0_m;
        evCk.ev.flags = bitor(evCk.ev.flags, instr.flags);
        % --- 死时间 + pile-up: 统一 DAQ 状态机 ---------------------------------
        % 旧实现分三处: deadTime.m 只按到达时刻计 busy; pile-up 用相邻 t0_s 间隙
        % 且每 chunk 复位 (块边界漏判); trigger.m 是只被测试调用的死代码。
        % 现在一个状态机消费 (到达时刻, 固定触发延迟, 脉冲宽度, tau), 且 busyUntil
        % **与** lastTrigEnd 都跨块携带。两类拒收都清零权重 (堆叠脉冲是被损坏的
        % 测量, 留着权重会让活时间占比与谱账本互相矛盾)。
        [tSrt, order] = sort(evCk.ev.t0_s);
        daqRes = tepc.electronics.daq(tSrt, latAbs, puWin, dt, ...
            cfg.electronics.deadTimeMode, struct('busyUntil', busyUntil, ...
            'lastTrigEnd', lastTrigEnd));
        accMask = false(nCk,1);
        accMask(order) = daqRes.accepted;
        rej = ~accMask;
        fAdd = zeros(nCk,1,'uint32');
        fAdd(daqRes.reason == "deadtime") = F.DEADTIME_REJECTED;
        fAdd(daqRes.reason == "pileup")   = F.PILEUP;
        evCk.ev.flags(order) = bitor(evCk.ev.flags(order), fAdd);
        evCk.ev.weight(rej) = 0;                   % 行保留供审计, 权重清零
        busyUntil = daqRes.busyUntil;
        lastTrigEnd = daqRes.lastTrigEnd;
        liveSumS = liveSumS + daqRes.liveTime_s;
        spanSumS = spanSumS + daqRes.span_s;
        firstID = firstID + nCk; tNext = st.tNext;
        save(fullfile(rd.raw, sprintf('chunk_%06d.mat', ck)), 'evCk', 'rs');
        tepc.io.writeJson(fullfile(rd.raw, 'checkpoint.json'), struct( ...
            'lastChunk', ck, 'lastEventID', firstID-1, 'tNext', tNext, ...
            'busyUntil', busyUntil, 'lastTrigEnd', lastTrigEnd, 'seed', seed, ...
            'config_sha256', R.config_sha256, 'nEvents_target', N, ...
            'liveTime_s', liveSumS, 'liveSpan_s', spanSumS, ...
            'chunk_size', chunk, 'checkpoint_schema_version', '2.0'));
        chunks{ck,1} = evCk;
        prog(0.14 + 0.6*ck/totalChunks, sprintf('chunk %d/%d', ck, totalChunks));
    end
catch eHead
    % 取消与真失败分开记账: 取消是用户意图 (STATUS=cancelled, raw/ 保留可续跑);
    % 其余一律 STATUS=incomplete + logs/error*.json, 并把根因原样抛出。
    if string(eHead.identifier) == "tepc:run:CancelRequested"
        cancelStatus(rd, numel(chunks), resumedFrom);
    else
        failStatus(rd, phase, eHead, seed, N, numel(chunks), resumedFrom, sha, frozenPrev, prevStatusBackup);
    end
    rethrow(eHead);
end

% ---- 分析 / 产物 / 提交 --------------------------------------------------
% 纪律: 运行期只往 _work 写; 提交 (改名) 是**最后**一步; STATUS=COMPLETED 只能由
% 提交之后写。任何一步失败 -> 在 run 根写 STATUS=incomplete + logs/error.json 并
% 原样抛出。改动前的事实: htmlReport/图 失败被 catch 吞掉后仍无条件写 COMPLETED,
% 而 runs/20260920_122507476-22860faca47d/ 是一个 logs/ figures/ 全空、连
% STATUS.json 都没有的半成品目录 (后台作业被池回收杀掉, 无人记账)。
phase = "analyze";
try
    prog(0.80, '合并事件并分析');
    E = mergeChunks(chunks);
    E.validate();
    [A, E] = tepc.analysis.analyze(E, cfg, Rcfg, Qfun, cal);   % 派生列回写后再落盘
    % --- 活时间口径 ---
    % analyze 给的 liveFrac 是**计数比** 1-nRejected/n: 它只在非瘫痪型且 r*tau 很小时
    % 才近似活时间。真正的活时间是 DAQ 占用区间的并集补 (paralyzable 在 r*tau=0.5 时
    % 两者差 ~15%: 计数比 0.607 vs 1-m*tau 0.697)。区间并集由 daq 逐块给出, 这里跨块
    % 累加 -> 与"一次跑完"同值 (分块无关性由 checkpoint 的 liveTime_s/liveSpan_s 保证)。
    A.liveFrac_count = A.liveFrac;
    if spanSumS > 0
        A.liveFrac = liveSumS/spanSumS;
        A.liveFrac_basis = "DAQ 占用区间并集: sum(liveTime_s)/sum(span_s), 跨 chunk 累加";
    else
        A.liveFrac = NaN;
        A.liveFrac_basis = "无有效观察跨度 (单事件或全部同时到达): 活时间不可定义";
    end
    A.liveTime_s = liveSumS;
    A.liveSpan_s = spanSumS;
    R.analysis = A;
    % 阻止本领 ASSUMED 带的逐事件占比 (在这里算: 只有此处同时握有事件表与表元数据)
    secMeV = double(E.ev.Esecondary_keV(:))/1000;
    posS = isfinite(secMeV) & secMeV > 0;
    limS = 1.0; tblSha = "";
    if isfield(tables, 'proton')
        if isfield(tables.proton,'assumed_below_MeV'), limS = tables.proton.assumed_below_MeV; end
        if isfield(tables.proton,'sha256'), tblSha = string(tables.proton.sha256); end
    end
    R.bandStats = struct('nPos', nnz(posS), 'nBand', nnz(posS & secMeV < limS), ...
        'limMeV', limS, 'tableSha', tblSha);
    R.transportTables = tables;

    phase = "geometry";
    % 三维/几何审计: 缺任一项就必须在首页显示 3D_NOT_AUDITED,
    % 不得因"画了张图"就声称三维已验证。这里只写**审计结论** (网格门禁 + 零件表 +
    % 拓扑一致性), 不写网格文件 —— 每个 run 落几 MB STL 不是证据而是噪音,
    % 需要网格时用 GUI [导出网格+清单] 或 tepc.geometry.exportGeometry。
    [R.geometryAudit, R.geometryManifestSha256] = writeGeometryAudit(rd, cfg, Rcfg);

    R.eventsPath = fullfile(rd.work.events, 'events.h5');
    tepc.io.writeEventsH5(R.eventsPath, E, struct( ...
        'schema_version', '1.1', 'matlab_release', version('-release'), ...
        'config_sha256', R.config_sha256, ...
        'created_utc', char(datetime('now','TimeZone','UTC')), ...
        'units_system', 'SI/keV/um', 'run_status', 'PENDING_COMMIT', 'seed', seed));

    prog(0.90, '写出 spectrum.csv / summary.json');
    writeSpectrumCsv(fullfile(rd.work.results, 'spectrum.csv'), A.spectrum, A.spectrum_in);
    summary = buildSummary(R, A, seed, N, resumedFrom, cfg);
    % 事件波形落盘 (可选开关, 默认关闭): 事件循环之后唯一的写入点, 实现在 waveformStage。
    % 开关关闭时它只往 summary 里写 waveform_status=DISABLED, 不生成任何文件。
    summary = waveformStage(cfg, R, ctx, E, rd, seed, summary, prog);
    % 漂移-收集诊断: 只读旁路, 用逐事件 r0_m 走 driftCollect, 不参与任何发布量。
    summary = driftDiagnostic(cfg, ctx, E, summary);
    % 拓扑与口径必须**同屏可见** (报告里必须打印场拓扑):
    % 中心球壳场与柱对称场在同一半径比下增益差 1182 倍, 一份不写拓扑的报告是歧义文档。
    summary.electrode_topology = R.resolve.electrode.topology;
    summary.field_kind = R.resolve.field.kind;
    summary.liveFrac_basis = A.liveFrac_basis;
    summary.liveFrac_count = A.liveFrac_count;
    summary.liveTime_s = A.liveTime_s;
    summary.liveSpan_s = A.liveSpan_s;
    summary.n_pileup = A.flags.pileup;
    summary.n_rejected_total = A.n_deadRejected;
    summary.n_shape_anomaly = A.flags.shapeAnomaly;
    % 仪器链方差的逐事件配对拆分发布进 summary: 诊断图脚注从这里当场取数,
    % 不再在任何文案里抄测得的比值。
    summary = instrumentSplitStage(E, summary);
    % 谱形成因分解进 summary: 让"这个 y_F 由哪些区间贡献"成为产物里可核对的数,
    % 而不是只有中心值本身。
    summary = formAttributionStage(A, summary);
    % 不确定度传播深度: 档位与**生效值**都要落盘, 否则事后无法核对档位是否真生效
    % (只有 id 的话, "表里有而代码没读"这种缺陷在产物上看不出来)。
    summary.uncertainty_depth_tier = depth.id;
    summary.uncertainty_depth_label = depth.label;
    summary.uncertainty_depth_note = depth.disclosure;
    summary.uncertainty_depth_knobs_json = depthJson(depth);
    summary.uncertainty_depth_defaulted = depth.defaulted;
    % 档位覆写了用户显式值时必须**进产物**: 无头运行里 warn 不会浮到控制台,
    % 只留在 issues 列表上等于没说 (HEADLESS 里丢警告是这一族的既有缺陷)。
    summary.uncertainty_depth_conflicted = depthConflicts(issAll);

    phase = "uq";
    summary = runUqStage(cfg, R, rd, N, summary, prog);
    tepc.io.writeJson(fullfile(rd.work.results, 'summary.json'), summary);
    R.summary = summary;

    prog(0.94, '诊断图');
    phase = "report";
    % htmlReport 从 **R.runDir.figures** 找 diagnostic.png; 提交前图还在 _work 里,
    % 所以必须给它"工作区视图"的 R, 否则报告里永远没有内嵌图 (实测: 改成事务式
    % 提交后 base64 消失, 就是这个引用没跟着重定向)。图只画一次: 第二遍渲染复用
    % 同一份 PNG 字节, 否则清单要哈希的东西又多一项会不收敛。
    Rw = R;  Rw.runDir = workView(rd);
    R.figurePaths = writeFigures(Rw, workView(rd));
    reportFile = fullfile(rd.work.results, 'report.html');

    % ============ 门禁求值次数 = 1: 报告与 gates.json 共用同一结论 ============
    % 依赖环 (为什么必须迭代):
    %   report.html 的水印 <- 门禁结论 <- R.provenance <- report.html 的字节
    %   清单与溯源要哈希"最终交付的那份报告字节"; 而门禁的「配置哈希与产物可追溯」
    %   项要读 provenance 的 outputs/outputs_missing, 「seed 一致性」项要读
    %   provenance.seed —— 提交前那次求值看不到还不存在的 provenance 与清单, 于是
    %   它合法地判 FAIL, 把这个暂存结论印到用户面前就成了 defect (实测两例:
    %   gates.json = VALID(FOR DEMO, WARN) 而 report.html = INVALID)。
    % 定点迭代 (唯一的门禁求值在第 3 步):
    %   1) 落一份水印写着"未评估"的报告 —— 只为让发布集在暂存区里齐套 (占位字节);
    %   2) events.h5 就地改口 COMMITTED, 再算清单与溯源 (哈希的是第 1 步的字节);
    %   3) 门禁求值**一次**, 输入是齐套的暂存树 -> R.gates 即唯一权威结论;
    %   4) 用 R.gates 重写报告 (最终字节);
    %   5) 清单与溯源各重算一次 -> 它们哈希的就是第 4 步的最终字节;
    %   6) 断言"门禁所读的溯源事实"(outputs 名集合 / 缺失集合 / seed) 在第 2 步与
    %      第 5 步之间逐项相同 —— 不同就是没收敛, 结论作废并记账, 不许带病发布;
    %   7) 提交 (rename 不改字节); 提交后只做"盘上字节 == 清单记录的哈希"的复核,
    %      **不再重跑门禁**。
    % 哈希与事务保证为什么仍然成立:
    %   * 清单排除 gates.json / artifact_manifest.json / provenance.json 三者不变。
    %     溯源 (makeProvenance) 的哈希名单是固定的 10 项, 开启 waveform 后新增的
    %     events/waveforms.h5 **不在**那份名单里 —— 完整产物真相以 artifact_manifest.json
    %     为准 (它递归覆盖整棵 _work), 溯源只负责那 10 个固定锚点。
    %   * 第 5 步是提交前**最后**一次写已哈希的字节; rename 之后没有任何代码再动
    %     被哈希过的文件 (gates.json 写于提交后, 而它本来就不在哈希集里),
    %     所以"哈希 == 盘上最终字节"逐字成立, 由第 7 步的复核当场证明。
    %   * 失败注入位置未移动: 第一遍渲染仍在 setH5RunStatus **之前**, 因此
    %     htmlReport 抛错时暂存 h5 仍自称 PENDING_COMMIT (事务契约所要求)。
    Rw = R;  Rw.runDir = workView(rd);  Rw.gates = provisionalGates();
    tepc.report.htmlReport(Rw, reportFile);

    % events.h5 的 run_status 必须在**哈希之前**从 PENDING_COMMIT 改成 COMMITTED:
    % HDF5 属性是文件内容的一部分, 先哈希再改属性会让 provenance/清单里的哈希当场
    % 对不上字节 (实测 test_release_transaction/test_manifest_covers_and_provenance_hashes_it
    % 在 events.h5 上 9940563... != 62a8e69...)。改名 (commit) 本身不改字节, 所以
    % "哈希最终字节"的承诺只能在暂存区里完成最后一步内容写入的前提下成立。
    % 若在改口之后、提交之前崩掉: 文件仍留在 _work/, 且 logs/STATUS.json 会写
    % incomplete —— 归属由事务状态判定, 不由这个属性判定。
    phase = "manifest";
    if tepc.io.setH5RunStatus(fullfile(rd.work.events, 'events.h5'), 'COMMITTED')
        R.h5_status_attr = "COMMITTED";
    else
        R.h5_status_attr = "NOT_UPDATED";
        tepc.io.writeJson(fullfile(rd.logs, 'h5_status_attribute.json'), struct( ...
            'run_status', "PENDING_COMMIT", 'final_status', "COMMITTED", ...
            'note', "HDF5 属性无法就地更新 (h5writeatt 失败): 以 logs/STATUS.json 为准"));
    end
    writeRunManifest(rd, R, A);
    prov0 = tepc.io.makeProvenance(root, cfg, R, workView(rd), seed);
    R.provenance = prov0;

    prog(0.96, '红线门禁 (唯一一次求值)');
    R.gates = tepc.validation.runGate(R, A, workView(rd));

    prog(0.97, '诊断图与 HTML 报告');
    phase = "report";
    Rw = R;  Rw.runDir = workView(rd);
    tepc.report.htmlReport(Rw, reportFile);
    R.reportPath = reportFile;

    R.manifestFiles = writeRunManifest(rd, R, A);
    R.provenance = tepc.io.makeProvenance(root, cfg, R, workView(rd), seed);
    phase = "provenance";
    tepc.io.writeJson(fullfile(rd.work.results, 'provenance.json'), R.provenance);
    % 收敛判据: 门禁读的是溯源的**名集合/缺失集合/seed**, 与字节无关; 这两次快照
    % 逐项相等才说明第 3 步的结论对最终那棵树依然成立 (不等 => 未收敛 => 拒绝发布)。
    dFact = diffGateFacts(prov0, R.provenance);
    if ~isempty(dFact)
        error("tepc:run:GateNotConverged", ...
            "门禁求值未收敛, 报告与 gates.json 会互相矛盾: %s", strjoin(dFact, ' | '));
    end

    phase = "commit";
    [rdCommitted, moved] = tepc.io.commitRun(rd);
    R = rebasePaths(R, rdCommitted);            % 提交后所有绝对路径重基
    R.runDir = rdCommitted;
    R.movedArtifacts = moved;

    % 提交后**不重跑门禁**: 只证明 rename 没改字节 (清单记的就是暂存期最终字节)。
    % 这条复核比"再算一遍"更强: 再算一遍若给出不同结论, 缺陷恰恰被它掩盖成两处
    % 各说各话; 而字节复核只承认"发布集与求值时看到的那份内容完全相同"。
    dBytes = checkCommittedBytes(rdCommitted, R.manifestFiles, R.provenance);
    if ~isempty(dBytes)
        error("tepc:run:CommittedBytesDiffer", ...
            "提交后的字节与暂存期哈希不符 (rename 改了内容?): %s", strjoin(dBytes, ' | '));
    end
catch eME
    failStatus(rd, phase, eME, seed, N, numel(chunks), resumedFrom, sha, frozenPrev, prevStatusBackup);
    rethrow(eME);
end

prog(0.98, '发布门禁与状态');
phase = "gates";
try
    % R.gates 来自暂存区上那唯一一次求值 (见上面 phase="manifest"~"provenance" 段),
    % 与 report.html 印的是同一个对象; 这里只把它落盘, 不再求值。
    tepc.io.writeJson(fullfile(rdCommitted.results, 'gates.json'), R.gates);
catch eME
    failStatus(rdCommitted, phase, eME, seed, N, numel(chunks), resumedFrom, sha, false);
    rethrow(eME);
end
% STATUS=completed 只声明"**发布集完整并已提交**", 它**不等于**"科学结论通过门禁"。
% 无条件写 completed 会让一个 nFail>0 的 run 在目录列表里看起来一切正常。
% 因此门禁计数与发布判定一起进 STATUS —— "跑完了"与"可以信"在同一文件里可区分。
gateTally = struct('n_fail', R.gates.nFail, 'n_warn', R.gates.nWarn, ...
    'n_not_evaluated', R.gates.nNotEvaluated, 'released', R.gates.released, ...
    'release_eligible', R.gates.release_eligible, 'watermark', R.gates.watermark, ...
    'meaning', "status=completed 仅表示发布集完整并已提交; 可否发布看 released/release_eligible, 明细见 results/gates.json");
tepc.io.runWriteStatus(rdCommitted.logs, 'completed', 'Phase', "commit", ...
    'Reason', sprintf('产物已提交; 门禁 %d FAIL / %d WARN / %d NOT_EVALUATED', ...
        R.gates.nFail, R.gates.nWarn, R.gates.nNotEvaluated), ...
    'RunID', rdCommitted.runID, 'ConfigSha256', R.config_sha256, ...
    'CompletedChunks', numel(chunks), 'Extra', gateTally);
% events.h5 的 run_status 已在哈希前改成 COMMITTED (见上面 phase="manifest" 段),
% 提交后不再动任何已哈希的字节 —— 这里只复核一遍, 不改写。
R.h5_status_check = "";
try
    R.h5_status_check = string(h5readatt( ...
        fullfile(rdCommitted.events, 'events.h5'), '/', 'run_status'));
catch
    R.h5_status_check = "READ_FAILED";
end
R.status = "COMPLETED";
% 布尔代数: nFail==0 && ~(nFail>0 || nNE>0) 与 ~(nFail>0 || nNE>0) 同值,
% 故 release_eligible 直接给出同一个判定, 判定强度不变。
R.release = ternaryStr(R.gates.release_eligible, "RELEASED", "BLOCKED");
prog(1.0, '完成');
end

% ---------------- helpers ----------------
function [cfg, rec] = applyRunArgs(cfg, args)
%APPLYRUNARGS 把 API 覆盖 (Seed/N) 在 validate/resolve/哈希 **之前** 写回 cfg。
%   返回 rec = 结构数组 (name/value), 供 provenance 记录"哪些值不是来自配置文件"。
rec = struct('name', {}, 'value', {});
if ~isempty(args.Seed)
    s = args.Seed;
    if ~(isnumeric(s) && isscalar(s) && isfinite(s) && s >= 0)
        error("tepc:run:BadSeed","API Seed 必须是非负有限标量, 实得 %s", mat2str(s));
    end
    cfg.provenance.seed = s;
    rec(end+1) = struct('name', "Seed", 'value', s); %#ok<AGROW>
end
if ~isempty(args.N)
    n = args.N;
    if ~(isnumeric(n) && isscalar(n) && isfinite(n) && n > 0 && n == round(n))
        error("tepc:run:BadN","API N 必须是正整数, 实得 %s", mat2str(n));
    end
    cfg.run.nEvents = n;
    rec(end+1) = struct('name', "N", 'value', n); %#ok<AGROW>
end
end

function rdw = workView(rd)
%WORKVIEW 运行期视图: 发布集字段指向 _work (提交前唯一可写位置)。
rdw = rd;
f = {'input','events','results','figures','partial'};
for i = 1:numel(f)
    rdw.(f{i}) = rd.work.(f{i});
end
rdw.workRoot = rd.workRoot;
end

function R = rebasePaths(R, rdC)
%REBASEPATHS 提交后把保存在 R 里的绝对路径从 _work 重基到正式位置。
%   不重基则 provenance/门禁/GUI 读的是已经不存在的 _work 路径。
if isfield(R,'eventsPath') && ~isempty(R.eventsPath)
    R.eventsPath = fullfile(rdC.events, 'events.h5');
end
if isfield(R,'reportPath') && ~isempty(R.reportPath)
    R.reportPath = fullfile(rdC.results, 'report.html');
end
if isfield(R,'figurePaths') && ~isempty(R.figurePaths)
    fp = R.figurePaths;
    for i = 1:numel(fp)
        [~, nm] = fileparts(fp{i});
        fp{i} = fullfile(rdC.figures, [nm '.png']);
    end
    R.figurePaths = fp;
end
if isfield(R,'gates') && isfield(R.gates,'logPath')
    R.gates.logPath = fullfile(rdC.results, 'gates.json');
end
end

function M = writeRunManifest(rd, R, A)
%WRITERUNMANIFEST 数据与报告产物的清单 (provenance 会哈希它)。
%   刻意不含 gates.json: 门禁结论本身不参与"哈希集" (它落盘于提交之后, 且报告已经
%   把它的内容印在页面上), 把会被后写的文件写进"覆盖清单"等于造一份过期哈希的假账。
%   同理不含清单自身 (自指哈希不可算) 与 provenance.json (它哈希清单, 不能被自己哈希)。
%   返回清单行 (path/bytes/sha256): 调用方在提交后拿它复核"盘上字节 == 暂存期哈希"
%   (见 execute 主链 phase="commit" 之后), 因此最后一次写入的返回值才是有效账本。
M = tepc.io.artifactManifest(rd.workRoot, 'RunPhase', "analyze+report", ...
    'Producer', "tepc.run.execute", 'ExcludeNames', ...
    {'gates.json','artifact_manifest.json','provenance.json'});
rec = struct();
rec.scope = "数据与报告产物 (不含 gates.json/provenance.json/清单自身: 前者写于提交后, " + ...
    "后两者不可自指哈希); 本清单在报告定稿后重算一次, 哈希的是将被提交的那份最终字节";
rec.run_phase = "analyze+report";
rec.root = "_work";
rec.nFiles = numel(M);
rec.files = M;
rec.config_sha256 = R.config_sha256;
rec.nEvents = R.summary.nEvents;
rec.created_utc = char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss'));
tepc.io.writeJson(fullfile(rd.work.results, 'artifact_manifest.json'), rec);
end

function G = provisionalGates()
%PROVISIONALGATES 定点迭代第 1 遍报告用的门禁占位对象。
%   它**不是**一次求值: items 为空、水印固定写"未评估", 只用来让 report.html 以
%   真实写盘路径落一份占位字节, 好让清单与溯源把发布集看成套齐的 (否则门禁看到的
%   是缺 provenance/清单的树, 那次求值就会把"缺产物"当成红线违规)。
%   这份占位报告在同一个 run 里被最终报告覆盖, 永不出暂存区。
z = struct('name', {}, 'status', {}, 'value', {}, 'detail', {});
G = struct('items', z, 'nFail', 0, 'nWarn', 0, 'nNotEvaluated', 0, ...
    'computational_gates_passed', false, 'release_eligible', false, ...
    'released', false, 'watermark', "GATES_NOT_YET_EVALUATED", ...
    'backend_id', tepc.backendId(), 'logPath', "");
end

function d = diffGateFacts(P0, P1)
%DIFFGATEFACS 门禁实际消费的溯源事实逐项比对 (名集合 / 缺失集合 / seed)。
%   哈希**值**允许不同 (报告字节本来就变了), 名集合与存在性不允许不同: 那两项一旦
%   漂移, 第 3 步的门禁结论对最终树就不再成立 —— 迭代没定点, 必须拒绝发布。
d = strings(0, 1);
n0 = sort(string(fieldnames(P0.outputs)));
n1 = sort(string(fieldnames(P1.outputs)));
if ~isequal(n0, n1)
    d(end+1) = "provenance.outputs 名集合变了: {" + strjoin(setdiff(n0, n1), ',') + ...
        "} vs {" + strjoin(setdiff(n1, n0), ',') + "}"; %#ok<AGROW>
end
m0 = sortedMissing(P0);
m1 = sortedMissing(P1);
if ~isequal(m0, m1)
    d(end+1) = sprintf('outputs_missing 变了: {%s} vs {%s}', strjoin(m0, ','), strjoin(m1, ',')); %#ok<AGROW>
end
if P0.seed ~= P1.seed
    d(end+1) = sprintf('seed 变了: %g vs %g', P0.seed, P1.seed); %#ok<AGROW>
end
if numel(P0.config_sha256) ~= numel(P1.config_sha256) || ~strcmp(P0.config_sha256, P1.config_sha256)
    d(end+1) = "config_sha256 变了"; %#ok<AGROW>
end
end

function m = sortedMissing(P)
if isfield(P, 'outputs_missing') && ~isempty(P.outputs_missing)
    m = sort(string(P.outputs_missing(:)));
else
    m = strings(0, 1);
end
end

function d = checkCommittedBytes(rdC, M, P)
%CHECKCOMMITTEDBYTES 提交后唯一允许的门禁相关工作: 证明 rename 没改任何字节。
%   清单行覆盖暂存树里除 gates.json/清单/溯源之外的每个产物; 溯源的 10 个名键则按
%   "相对路径下划线化" (与 matlab.lang.makeValidName 同一口径) 反查提交后的文件。
%   两份账本记的是同一批字节, 因此先把 (文件, 记录哈希) 归并再逐文件哈希一次 ——
%   纯 MATLAB 的 SHA-256 每 MB 要十几秒, 对大 events.h5 重复哈希会白付一倍时间。
d = strings(0, 1);
ap = strings(0, 1); rk = strings(0, 1); lb = strings(0, 1);
for i = 1:numel(M)
    rel = strrep(strrep(char(string(M(i).path)), '/', filesep), '\', filesep);
    ap(end+1) = string(fullfile(rdC.root, rel)); %#ok<AGROW>
    rk(end+1) = string(M(i).sha256); %#ok<AGROW>
    lb(end+1) = "清单:" + string(M(i).path); %#ok<AGROW>
end
tab = committedKeyTable(rdC);
on = fieldnames(P.outputs);
for i = 1:numel(on)
    k = string(on{i});
    j = find(tab.key == k, 1);
    if isempty(j)
        d(end+1) = sprintf('溯源项 %s 在提交后的发布集里找不到对应文件', k); %#ok<AGROW>
        continue;
    end
    ap(end+1) = tab.file(j); %#ok<AGROW>
    rk(end+1) = string(P.outputs.(on{i})); %#ok<AGROW>
    lb(end+1) = "溯源:" + k; %#ok<AGROW>
end
[ua, ~, ic] = unique(ap);
% 一律按列向量比对: unique 的索引方向与输入形状未必一致, 行×列的 & 会被隐式扩展成
% N×N 矩阵, find 出来的下标就越界 (实测"索引超过 9")。
ua = ua(:); ic = ic(:); rk = rk(:); lb = lb(:);
for q = 1:numel(ua)
    idx = (ic == q);
    f = char(ua(q));
    if ~isfile(f)
        for w = find(idx)'
            d(end+1) = sprintf('%s 提交后不在盘上', lb(w)); %#ok<AGROW>
        end
        continue;
    end
    h = string(tepc.io.hashFile(f));
    bad = idx & (rk ~= h);
    for w = find(bad)'
        d(end+1) = sprintf('%s 的字节与记录的哈希不符 (哈希=内容 的承诺当场失效)', lb(w)); %#ok<AGROW>
    end
end
end

function tab = committedKeyTable(rdC)
%COMMITTEDKEYTABLE 提交后发布集的 "下划线化相对路径 -> 绝对路径" 反查表。
%   溯源键是 matlab.lang.makeValidName('<发布目录>.<文件名>') 的结果, 点与分隔符都
%   被折成下划线, 因此**不能**再从键里切点复原路径; 只能把盘上的相对路径按同一
%   口径折一次再比对。raw/ 与 logs/ 不在发布集里, 逐目录列举而不是走 run 根。
key = strings(0, 1);
file = strings(0, 1);
pub = {'input', 'events', 'results', 'figures', 'partial'};
for i = 1:numel(pub)
    if ~isfield(rdC, pub{i}), continue; end
    dirPath = char(string(rdC.(pub{i})));
    if ~isfolder(dirPath), continue; end
    fs = collectFiles(dirPath);
    for j = 1:numel(fs)
        % 键的相对路径必须带上**发布目录名** (溯源键是 '<目录>.<文件>' 折出来的,
        % 只折文件名会得到 report_html 而不是 results_report_html, 逐项匹配全落空)。
        rel = fullfile(pub{i}, fs{j});
        key(end+1) = string(strrep(strrep(strrep(rel, filesep, '_'), '/', '_'), '.', '_')); %#ok<AGROW>
        file(end+1) = string(fullfile(dirPath, fs{j})); %#ok<AGROW>
    end
end
tab = struct('key', key, 'file', file);
end

function out = collectFiles(root)
% 递归列相对路径 (与 commitRun 的 filePaths 同一口径, 只列文件)。
out = {};
dd = dir(root);
for i = 1:numel(dd)
    if ~dd(i).isdir, continue; end
    if any(strcmp({dd(i).name}, {'.', '..'})), continue; end
    sub = fullfile(root, dd(i).name);
    inner = collectFiles(sub);
    for j = 1:numel(inner)
        out{end+1} = fullfile(dd(i).name, inner{j}); %#ok<AGROW>
    end
end
ff = dir(root);
for i = 1:numel(ff)
    if ~ff(i).isdir
        out{end+1} = ff(i).name; %#ok<AGROW>
    end
end
end

function summary = formAttributionStage(A, summary)
%FORMATTRIBUTIONSTAGE 把谱形成因分解发布成标量字段。
%   字段一律 form_ 前缀、不进 publishedFieldSpecs: 发布表是报告/GUI 的显示面,
%   新增成因字段不应改变既有显示口径; summary 侧的字段锁是单向包含, 新增不算回归。
%   缺位写 ""/NaN 而不抛错: 未走输运或仪器链的配置也必须拿到同名字段,
%   否则按字段取数的下游 (诊断图脚注、报告) 会在一类合法配置上炸。
%   本函数不修改任何既有 summary 字段的值。
numNames = {'form_class_count_l1', 'form_class_count_l2', 'form_share_w_sum', ...
    'form_resid_group', 'form_resid_bands', 'form_l1_uncovered', ...
    'form_n_below_yF', 'form_n_above_q99w', 'form_yF_exact', 'form_yF_binned', ...
    'form_yF_binned_rel_diff', 'form_q90w', 'form_q99w', ...
    'form_tail_share_w', 'form_bulk_share_w', 'form_top_share_w', ...
    'form_top_band_mean', 'form_top_contrib_over_yF', ...
    'chan_share_w_sum', 'chan_resid_bands', 'chan_uncovered', ...
    'chan_top_share_w', 'chan_top_y_mean', 'chan_top_contrib_over_yF', ...
    'chan_top_code', 'chan_n_published', 'chan_n_unlabelled', ...
    'chan_labelled_share_w'};
strNames = {'form_flag', 'form_top_contrib_class', 'chan_flag', ...
    'form_note', 'chan_note'};
for i = 1:numel(numNames)
    nm = numNames{i};
    if isfield(A, nm) && ~isempty(A.(nm))
        summary.(nm) = A.(nm);
    else
        summary.(nm) = NaN;
    end
end
for i = 1:numel(strNames)
    nm = strNames{i};
    if isfield(A, nm) && ~isempty(A.(nm))
        summary.(nm) = A.(nm);
    else
        summary.(nm) = "";
    end
end
end

function summary = instrumentSplitStage(E, summary)
%INSTRUMENTSPLITSTAGE 把仪器链方差的逐事件配对拆分发布进 summary。
%   v 的生产者只有上面写 summary.instr_res_fwhm_over_yF 的那一处, 这里**不重算**:
%   sigma_m2 直接取该已发布字段, cv2Truth 由两条已发布真值矩之比算出。
%   未走仪器链 (没有真值谱) 时这些字段不存在 -> 整个拆分记 NOT_EVALUATED。
%   状态、原因、计数与数值字段**无论走哪条分支都写齐**, 数值留 NaN:
%   让读者看见"这里没算", 比让他以为省略号后面还是同一个口径诚实。
%   不声明逐位可复现: 本函数对合并后的整表做加权和, 与分块共享同一事件群,
%   但浮点重结合顺序不在承诺范围内 (一致性判据用相对量级)。
z = E.ev;
nEv = numel(z.EdepGas_keV(:));
nP = nnz(isfinite(z.EdepGas_keV) & isfinite(z.epsilon_meas_keV) ...
    & isfinite(z.weight) & z.weight > 0 & z.EdepGas_keV > 0);
theta = tepc.config.constants('detector.polya.theta');
hasV = isfield(summary, 'instr_res_fwhm_over_yF') ...
    && isfinite(double(summary.instr_res_fwhm_over_yF)) ...
    && isfield(summary, 'yF_truth_keV_um') && isfield(summary, 'yD_truth_keV_um') ...
    && isfinite(double(summary.yF_truth_keV_um)) && double(summary.yF_truth_keV_um) > 0 ...
    && isfinite(double(summary.yD_truth_keV_um));
summary.instrument_split_status = "NOT_EVALUATED";
summary.instrument_split_note = "未走仪器链或真值谱缺失: 没有已发布的核方差比, 拆分不评估";
summary.instrument_sigma_m2 = NaN;
summary.instrument_added_paired = NaN;
summary.instrument_added_spectrum = NaN;
summary.instrument_added_var_diff = NaN;
summary.instrument_cov_term = NaN;
summary.instrument_cov_cross = NaN;
summary.instrument_kernel_coverage = NaN;
summary.instrument_split_flag = "instrument-chain-absent";
summary.instrument_split_n_paired = nP;
summary.instrument_split_n_events = nEv;
if isfinite(theta) && theta > 0
    % 解析量, 与有没有走仪器链无关, 照常发布 (Polya: var(G)/G^2 = 1/theta)
    summary.instrument_avalanche_share = 1 / theta;
else
    summary.instrument_avalanche_share = NaN;
end
if ~hasV
    return;
end
v = double(summary.instr_res_fwhm_over_yF);
cv2Truth = double(summary.yD_truth_keV_um) / double(summary.yF_truth_keV_um) - 1;
Sp = tepc.analysis.instrumentVarianceSplit(z, v, cv2Truth, theta);
summary.instrument_split_status = "EVALUATED";
summary.instrument_split_note = sprintf( ...
    'sigma_m2 取自已发布的 instr_res_fwhm_over_yF, cv2Truth = yD_truth/yF_truth - 1 = %.6g', ...
    cv2Truth);
summary.instrument_sigma_m2 = Sp.sigmaM2;
summary.instrument_added_paired = Sp.addedPaired;
summary.instrument_added_spectrum = Sp.addedSpectrum;
summary.instrument_added_var_diff = Sp.addedVarDiff;
summary.instrument_cov_term = Sp.covTerm;
summary.instrument_cov_cross = Sp.covCross;
summary.instrument_kernel_coverage = Sp.kernelCoverage;
summary.instrument_split_flag = string(Sp.coverageFlag);
summary.instrument_split_n_paired = Sp.nPaired;
summary.instrument_split_n_events = Sp.nEvents;
end

function summary = runUqStage(cfg, R, rd, N, summary, prog)
%RUNUQSTAGE 不确定度传播 + **状态化**。
%   旧实现: propagateMC 抛错只在 summary 里留一句 u_error, 主流程照样 COMPLETED,
%   报告里那一行还因为字段缺失而整行消失 -> "不确定度未评估"被读成"有不确定度"。
%   现在: uq_status 是显式词汇, 门禁与报告都消费它; 异常仍记录但不再伪装成功。
uqEnabled = isfield(cfg,'uq') && isfield(cfg.uq,'enabled') && cfg.uq.enabled;
if ~uqEnabled
    summary.uq_status = "DISABLED";
    summary.uq_note = "cfg.uq.enabled=false: 本次未评估不确定度";
    return
end
nS = 32;
if isfield(cfg.uq,'nSamples') && cfg.uq.nSamples > 0, nS = round(cfg.uq.nSamples); end
sU = 24680;
if isfield(cfg.uq,'seed') && ~isempty(cfg.uq.seed), sU = cfg.uq.seed; end
minN = 32;
if isfield(cfg.uq,'minSamples') && ~isempty(cfg.uq.minSamples), minN = round(cfg.uq.minSamples); end
prog(0.92, sprintf('不确定度传播 (%d 样本)', nS));
summary.uq_status = "INCOMPLETE";
summary.uq_note = "";
summary.u_nSamples = 0;
summary.u_nFailed = NaN;
try
    Uo = tepc.uq.propagateMC(cfg, nS, 'Seed', sU, ...
        'NEvPerSample', max(300, round(min(N, 2000))), ...
        'ProgressFcn', @(k, nTot) prog(0.92 + 0.015*k/max(nTot, 1), ...
            sprintf('不确定度传播 %d/%d 样本', k, nTot)));
    tepc.io.writeJson(fullfile(rd.work.results, 'uq.json'), struct( ...
        'summary', Uo.summary, 'tornado', Uo.tornado, 'nSamples', Uo.nSamples, ...
        'variables', {Uo.variables}, 'nFailed', numel(Uo.failed), ...
        'failed', {Uo.failed}, 'seed', sU, 'note', Uo.note));
    summary.u_yF_rel = Uo.summary.u_yF_rel;
    summary.u_yF_CI95 = Uo.summary.yF_CI95;
    % 剂量侧的相对不确定度也要进 summary (口径 = 累计位点比能量, 见 propagateMC 的
    % Dt 定义): 此前只落在 uq.json 里, 报告的剂量读数没有误差棒 (谱有、剂量没有)。
    % 缺字段即抛错而不是静默跳过 —— 否则 uq_status=COMPLETE 也能带着空误差棒出厂。
    if ~isfield(Uo.summary, 'u_Dcum_rel')
        error("tepc:uq:MissingDcumU", ...
            "propagateMC 没给 u_Dcum_rel: 剂量侧不确定度无从上报 (静默缺席比报错更糟)");
    end
    summary.u_Dcum_rel = Uo.summary.u_Dcum_rel;
    summary.u_nSamples = Uo.nSamples;
    summary.u_nFailed = numel(Uo.failed);
    % UQ 样本越出已验证域的数量必须显式披露: 悄悄丢掉样本会让不确定度
    % 低估, 全部拒掉又会让 UQ 瘫掉 —— 所以"算它, 但也说出来"。
    if isfield(Uo, 'nSamplesOutOfDomain')
        summary.u_n_out_of_domain = Uo.nSamplesOutOfDomain;
    else
        summary.u_n_out_of_domain = NaN;
    end
    reasons = strings(0,1);
    if numel(Uo.failed) > 0
        reasons(end+1) = sprintf("%d/%d 样本失败", numel(Uo.failed), Uo.nSamples); %#ok<AGROW>
    end
    if Uo.nSamples < minN
        reasons(end+1) = sprintf("样本数 %d < minSamples %d", Uo.nSamples, minN); %#ok<AGROW>
    end
    if ~all(isfinite(Uo.summary.yF_CI95))
        reasons(end+1) = "CI 非有限"; %#ok<AGROW>
    end
    if ~isfinite(Uo.summary.u_yF_rel)
        reasons(end+1) = "u(y_F) 非有限"; %#ok<AGROW>
    end
    if isempty(reasons)
        summary.uq_status = "COMPLETE";
    else
        summary.uq_note = strjoin(reasons, "; ");
    end
catch e
    summary.u_error = e.message;
    summary.uq_note = sprintf("异常 %s: %s", e.identifier, e.message);
    try
        tepc.io.writeErrorLog(rd.logs, e, struct('stage', "uq", ...
            'runID', rd.runID, 'configSha256', R.config_sha256));
    catch
    end
end
end

function summary = driftDiagnostic(cfg, ctx, E, summary)
%DRIFTDIAGNOSTIC 逐事件电离簇的一维漂移-收集诊断 (只读旁路, 不参与任何发布量)。
%   为什么按逐事件 r0 而不是统一雪崩半径: 收集时间是起始半径的函数
%   (t = 积分 dr/v_d(E(r))), 用同一个 r0 只会得到一个数, 既看不出分布, 也答不出
%   "有没有事件的输运时间已经接近成形峰时间" (弹道亏损的风险指标)。
%   参数口径: 数密度 N = p/(Z*kB*T) 由配置量导出; 饱和漂移速度、半饱和 E/N、附着系数
%   是配置里显式标 ASSUMED 的演示级值 —— 可核对的电子输运关系需要外部数据表,
%   所以这里只报量级与相对排序, 不构成任何时间域符合性结论。
%   抽样用等距跨步而不是随机流: 本阶段既不消耗 RNG 也不写事件数据, 因此它的开与关
%   不会改变任何已发布数值。
kB = 1.380649e-23;
summary.drift_status = "SKIPPED";
summary.drift_n = 0;
summary.drift_note = "";
tp = cfgGet(cfg, {'gas','transport'});
if isempty(tp)
    summary.drift_note = "配置里没有 gas.transport: 不报漂移诊断 (缺参数就不给数, 也不猜默认值)";
    return
end
need = {'vd_max_m_s','vd_half_Ed_Vm2','eta_attach_per_m'};
g = zeros(1, numel(need));
for i = 1:numel(need)
    v = cfgGet(cfg, {'gas','transport', need{i}, 'value'});
    if isempty(v) || ~isnumeric(v) || ~isscalar(v) || ~isfinite(v) || v < 0
        summary.drift_note = sprintf('gas.transport.%s 缺失或非有限非负标量: 诊断跳过', need{i});
        return
    end
    g(i) = double(v);
end
T = cfgGet(cfg, {'gas','temperature_K'});
p = cfgGet(cfg, {'gas','pressure_Pa'});
Z = cfgGet(cfg, {'gas','compressibility_Z'});
if isempty(Z), Z = 1.0; end
if isempty(T) || isempty(p) || ~(T > 0) || ~(p > 0) || ~(Z > 0)
    summary.drift_note = "温度/压强/压缩因子不可用: 数密度无法导出, 诊断跳过";
    return
end
Nden = p / (Z * kB * T);
gasTbl = struct('N_density', Nden, 'vd_max', g(1), 'vd_half_Ed', g(2), 'eta_attach', g(3));
opts = struct('temperature_K', T, 'nStepsMax', 20000);
if ~isfield(ctx, 'field')
    summary.drift_note = "ctx.field 不可用: 漂移需要与雪崩/Ramo 同一场模型, 不自己另建一份";
    return
end
nDiag = 400;
step = max(1, floor(E.n / nDiag));
ids = step:step:E.n;
r0 = E.ev.r0_m(ids(:));
if numel(unique(r0)) < 2
    % 统一雪崩半径模式 (detector.avalancheStartMode='fixed') 下所有事件同一个 r0:
    % 诊断仍然算, 但必须把"这是单一半径不是分布"写在披露里, 否则读者会把它当分布读。
    summary.drift_r0_degenerate = true;
else
    summary.drift_r0_degenerate = false;
end
tC = nan(numel(ids), 1);  sv = nan(numel(ids), 1);  sg = nan(numel(ids), 1);
for i = 1:numel(ids)
    o = tepc.detector.driftCollect(struct('r0', r0(i), 'N0', 1, 't0', 0), ...
        ctx.field, gasTbl, [], opts);
    tC(i) = o.t_collect_s;  sv(i) = o.survival;  sg(i) = o.sigma_long_m;
end
% 成形峰时刻 = 峰位索引 x 采样间隔, 与本文件触发延迟 latAbs 同一个量。
% 不能用 ctx.coeffs.hpeak: 那是 max(abs(h)) 即冲激响应的**幅度** (filters.m 里
% [c.hpeak, c.hidx] = max(abs(c.h))), 拿它乘 Ts 会得到一个毫无意义的时间。
tPeak = double(ctx.coeffs.hidx) * double(ctx.coeffs.Ts);
summary.drift_status = "COMPLETE";
summary.drift_n = numel(ids);
summary.drift_sample_stride = step;
summary.drift_r0_min_m = min(r0);
summary.drift_r0_max_m = max(r0);
summary.drift_t_collect_med_s = median(tC);
summary.drift_t_collect_p90_s = qAt(tC, 0.90);
summary.drift_t_collect_max_s = max(tC);
summary.drift_peaking_time_s = tPeak;
summary.drift_frac_over_peaking = mean(tC > tPeak);
summary.drift_sigma_long_max_m = max(sg);
summary.drift_survival_min = min(sv);
summary.drift_N_density_m3 = Nden;
% 多段文本一律用 + 拼成**字符串标量**: `[A B]` 得到的是 1x2/1x3 字符串数组,
% 后面任何 `+ 别的串` 都会维度不一致, 而 jsonencode 也会把它写成数组而不是一个值。
summary.drift_model = "L1 一维漂移-收集: v_d=vd_max*EN/(EN+Ed_half), " ...
    + "D=v_d*kT/(eE) (Einstein), 每步 P_surv=exp(-eta*dr)";
summary.drift_note = "输运参数 ASSUMED (vd_max/Ed_half/eta 无实测也无外部输运表); " ...
    + "数密度由 p/T/Z 导出; 逐事件 r0 取自事件表 r0_m 列; 只报量级与相对排序, " ...
    + "不参与发布量, 不构成时间域符合性结论";
if summary.drift_r0_degenerate
    % 跨行长句必须先合成单一字面量再参与 + : `a + "x" ... "y"` 会被解析成
    % `a + ("x" "y")` 的隐式拼接, 直接报"运算符的使用无效"。
    degTxt = "; 本次所有事件 r0 相同 (fixed 起始半径), " ...
        + "所以下面的 med/p90/max 是同一个数, 不是分布";
    summary.drift_note = summary.drift_note + degTxt;
end
end

function v = cfgGet(cfg, path)
%CFGGET 按字段路径取配置值: 任一级缺失或为空给 [] (由调用方决定跳过还是报错)。
v = cfg;
for i = 1:numel(path)
    if ~isstruct(v) || ~isfield(v, path{i})
        v = [];
        return
    end
    v = v.(path{i});
    if isempty(v)
        v = [];
        return
    end
end
end

function q = qAt(x, frac)
%QAT 最近秩分位数 (只用基础运算, 不引入统计工具箱依赖)。非有限值先剔除。
y = x(isfinite(x(:)));
if isempty(y)
    q = NaN;
    return
end
s = sort(y(:));
k = max(1, min(numel(s), ceil(frac * numel(s))));
q = s(k);
end

function summary = waveformStage(cfg, R, ctx, E, rd, seed, summary, prog)
%WAVEFORMSTAGE 事件波形的抽样落盘 + 状态化披露 (默认关闭)。%   状态词与 runUqStage 同一套纪律: 未开启写 DISABLED 并点名判据字段, 失败写 FAILED
%   并落 logs/error*.json 且**不留半件产物**, 成功写 WRITTEN 并给出规模/量化口径/偏差披露。
%   为什么是事后逐事件重跑而不是在事件循环里接住波形: 每事件的 Threefry 子流锚在
%   eventID 上 (simulate 内 rsE = Threefry(Seed=ctx.seed+1), rsE.Substream=eventID),
%   与分块大小、续跑历史、调用形状全部无关, 所以单事件重跑得到的就是生产循环里那条 v
%   —— 这里不把它当公设: "同一 id 重跑得到同一条 v"本身就是可核的判据。
%   落盘的是解析代理模型电子学链的**模拟波形**, 不是实测脉冲形状; 这里只兑现"标量
%   是波形的函数"这一数据契约, 不构成任何电子学符合性结论。
% 开关读取必须全定义: +config/validate 会拒空值与字符串, 但直接构造 cfg 的调用方绕过它,
% 而实测 `if ~([])` 走假分支 —— 若写成 `A && B && cfg.waveform.enabled`, JSON 里的 null
% 会既不关掉开关也不报错, 反而进入写盘路径。非法值在这里就抛, 不猜它想表达什么。
wfOn = false;
if isfield(cfg,'waveform') && isstruct(cfg.waveform) && isfield(cfg.waveform,'enabled')
    enW = cfg.waveform.enabled;
    okE = (islogical(enW) || (isnumeric(enW) && isreal(enW))) && isscalar(enW) ...
        && any(double(enW) == [0 1]);
    if ~okE
        error("tepc:run:BadWaveformSwitch", ...
            "waveform.enabled 必须是 0/1 的实数或逻辑标量, 实得 %s %s", ...
            class(enW), mat2str(size(enW)));
    end
    wfOn = logical(enW);
end
if ~wfOn
    summary.waveform_status = "DISABLED";
    if isfield(cfg,'waveform') && isfield(cfg.waveform,'enabled')
        summary.waveform_note = "cfg.waveform.enabled=false: 本次未落盘事件波形, 不生成 events/waveforms.h5";
    else
        summary.waveform_note = "配置里没有 waveform.enabled 字段: 按关闭处理, 不生成 events/waveforms.h5";
    end
    summary.waveform_nSub = 0;
    return
end
nSub = 100;
if isfield(cfg.waveform,'nSub')
    nsW = cfg.waveform.nSub;
    if ~(isnumeric(nsW) && isreal(nsW) && isscalar(nsW) && isfinite(nsW) && nsW >= 1)
        error("tepc:run:BadWaveformNSub", ...
            "waveform.nSub 必须是 >=1 的整数值有限标量, 实得 %s %s", ...
            class(nsW), mat2str(size(nsW)));
    end
    nSub = round(nsW);
end
wfPath = fullfile(rd.work.events, 'waveforms.h5');
% 先写到发布树之外 (tempdir), 成功后一步 movefile 进 _work/events。
% 直接在 rd.work.events 里写不行: 清单是整棵 _work 递归枚举的
% (artifactManifest.m 的 walk), 半途失败的 h5 会被哈希、被提交, 而 summary 说它 FAILED。
% 运行目录之内没有任何"不被枚举"的落脚处, 所以暂存点必须在树外。
tmpWf = fullfile(tempdir, sprintf('tepc_%s_waveforms.h5', rd.runID));
summary.waveform_status = "FAILED";
summary.waveform_note = "";
summary.waveform_nSub = 0;
try
    ids = tepc.io.waveformSubset(seed, nSub, E.n);
    if isempty(ids)
        error("tepc:run:WaveformEmpty", "waveform.nSub=%g 而事件数 %d: 选不出任何事件", nSub, E.n);
    end
    prog(0.915, sprintf('抽样波形落盘 (%d/%d 事件)', numel(ids), E.n));
    % simulate 的事件级随机全部取自 rsE = Threefry(Seed=ctx.seed+1) 的 eventID 子流;
    % 形参 rs 在这条链上不被消费 (逐事件增益与噪声都走 rsE), 所以传一条新建的流,
    % 不借它携带任何状态 —— 重跑与生产循环共用同一 per-event 子流, 这正是取到同一条 v 的理由。
    rsW = RandStream('Threefry', 'Seed', seed);
    tr = zeros(numel(ids), 0);
    nSamp = 0;
    for j = 1:numel(ids)
        idj = ids(j);
        if double(E.ev.eventID(idj)) ~= idj
            error("tepc:run:WaveformIdMismatch", ...
                "第 %d 行的 event_id %d 与事件表第 %d 行不符: 子集口径要求事件按 id 升序落表, 该假设已破", ...
                j, idj, idj);
        end
        [~, ~, auxW] = tepc.electronics.simulate(E.ev.EdepGas_keV(idj), idj, cfg, rsW, ctx);
        v = auxW.waveform_first_event(:).';
        if nSamp == 0
            nSamp = numel(v); tr = zeros(numel(ids), nSamp);
        end
        if numel(v) ~= nSamp
            error("tepc:run:WaveformLen", ...
                "event %d 的波形长 %d != %d (采样窗/sampleTime 在事件之间变了?)", idj, numel(v), nSamp);
        end
        tr(j, :) = v;
    end
    % 事件表摘要: 只交给写出器做交叉核对披露, 不参与落盘标量的计算。
    % 逐字段赋值而不是 struct('a', cellVal): 后者的 cell 实参会被展开成结构数组,
    % 核对会因此静默不生效 (数值列向量不展开, 但这里统一写法以免后续加进字符串列)。
    esW = struct();
    esW.peak_V      = E.ev.peak_V(ids(:));
    esW.t_trigger_s = E.ev.t_trigger_s(ids(:));
    esW.adc_code    = E.ev.adc_code(ids(:));
    sw = tepc.io.writeWaveformsH5(tmpWf, ids, tr, struct( ...
        'Ts_s', ctx.coeffs.Ts, 'cfg', cfg, 'hsign', ctx.coeffs.hsign, 'seed', seed, ...
        'config_sha256', R.config_sha256, 'matlab_release', version('-release'), ...
        'created_utc', char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss')), ...
        'waveWindow_s', nSamp*ctx.coeffs.Ts, 'Nwin', ctx.coeffs.Nwin, 'event_scalars', esW));
    movefile(tmpWf, wfPath);          % 一步落地: 失败时发布树里从来没有过这个文件
    summary.waveform_status = "WRITTEN";
    summary.waveform_nSub = sw.nSub;
    summary.waveform_n_samples = sw.nSamples;
    summary.waveform_bytes = sw.bytes;
    summary.waveform_scale_V = sw.scale_V;
    summary.waveform_Ts_s = sw.Ts_s;
    summary.waveform_hsign = sw.hsign;
    summary.waveform_event_ids = ids(:).';
    summary.waveform_path = "events/waveforms.h5";   % 相对发布集的路径 (提交前后同一口径)
    if isfield(sw.xcheck, 'peak_V_abs_max')
        % 事件表 peak_V 与"由落盘波形复算的 peak_V"的偏差: 期望量级 = 量化半步 scale_V/2
        summary.waveform_table_vs_trace_peak_abs_max_V = sw.xcheck.peak_V_abs_max;
        summary.waveform_table_vs_trace_adc_max_codes  = sw.xcheck.adc_code_abs_max;
    end
    summary.waveform_note = ["模拟波形: 解析代理模型 (analytic_surrogate_v1) 电子学链输出, " ...
        "非实测脉冲形状; 落盘标量由 samples 复算 (peak/argmax*Ts/ADC/积分); " ...
        "量化 int16 x scale_V, 定标为 2 的幂; 子集只由 (seed, nSub, 事件数) 决定"];
catch e
    % 状态词必须在这里改口: WRITTEN 是在 movefile 成功后写的, 而它后面还有赋值与 note
    % 拼接等语句 —— 那些一旦抛, 不重置就会留下"summary 说 WRITTEN、文件已被下面删掉"
    % 的一致谎言 (报告与 summary 同源, 两边一起错给读者看)。
    summary.waveform_status = "FAILED";
    % 失败不许在发布树里留下半件 h5: 写盘走 tempdir, 只有一步 movefile 落地, 所以正常
    % 失败路径下 rd.work.events 里从未出现过这个文件; 仍兜一次删除, 并把"删不掉"
    % (Windows 上文件被占用时 delete 会失败) 记成一个可被读者看到的标志而不是静默吞掉。
    summary.waveform_note = sprintf("异常 %s: %s", e.identifier, e.message);
    % delete 本身也可能抛 (Windows 上文件被占用), 不包起来就会让下面两个披露键根本没写,
    % 报告连"这次是失败态"都看不到 —— 宁可留下 partial_left=true 也要把状态说全。
    try
        if isfile(tmpWf), delete(tmpWf); end
        if isfile(wfPath), delete(wfPath); end
    catch eDel
        summary.waveform_note = sprintf('%s | 清理也失败 %s: %s', summary.waveform_note, ...
            eDel.identifier, eDel.message);
    end
    summary.waveform_partial_left = isfile(wfPath);
    try
        tepc.io.writeErrorLog(rd.logs, e, struct('stage', "waveforms", ...
            'runID', rd.runID, 'configSha256', R.config_sha256));
    catch
    end
end
end

function failStatus(rd, phase, e, seed, N, nChunks, resumedFrom, sha, frozen, prevStatusBackup)
%FAILSTATUS 失败路径的唯一记账出口: 状态 + 根因, 两者都必须落盘。
%   文件名带时间戳与序号: 固定名 error.json 会被后一次失败覆盖, 于是"最近一次
%   失败"成为唯一可见的历史 (那会抹掉首个根因)。STATUS.json 仍只有一份,
%   因为它表达"当前状态", 而错误日志表达"发生过什么"。
%   frozen=true 且失败发生在**守卫阶段**: 说明这次尝试根本没有动过任何产物, 只是
%   被拒之门外 —— 已发布 run 的 STATUS 必须逐字还原 (只跳过写入会把早先无条件写的
%   running 留在盘上, 那等于替攻击者解除门禁)。
if nargin < 8, sha = ""; end
if nargin < 9, frozen = false; end
if nargin < 10, prevStatusBackup = ""; end
guardOnly = frozen && strcmp(char(string(phase)), "resume");
try
    st = struct();
    st.stage = char(string(phase));
    st.runID = rd.runID;
    st.configSha256 = char(string(sha));
    st.extra = struct('seed', seed, 'N', N, 'completed_chunks', nChunks, ...
                      'resumed_from', resumedFrom, ...
                      'status_left_untouched', guardOnly);
    nm = sprintf('error_%s_%s.json', char(datetime('now','Format','yyyyMMdd_HHmmss_SSS')), ...
        regexprep(char(string(e.identifier)), '[^A-Za-z0-9]', '_'));
    tepc.io.writeErrorLog(rd.logs, e, st, nm);
catch
end
if guardOnly
    if numel(prevStatusBackup) > 2 && isfile(char(prevStatusBackup))
        copyfile(char(prevStatusBackup), fullfile(rd.logs, 'STATUS.json'), 'f');
        try, delete(char(prevStatusBackup)); catch, end
    end
    return;
end
try
    tepc.io.runWriteStatus(rd.logs, 'incomplete', 'Phase', string(phase), ...
        'Reason', sprintf("%s: %s", e.identifier, e.message), ...
        'RunID', rd.runID, 'ConfigSha256', sha, 'CompletedChunks', nChunks);
catch
end
end

function [verdict, manifestSha] = writeGeometryAudit(rd, cfg, Rcfg)
%WRITEGEOMETRYAUDIT 几何规格 + 网格门禁结论落盘, 并把 verdict 写进 summary 可见处。
spec = tepc.geometry.meshSpec(cfg, Rcfg);
M = tepc.geometry.checkMesh(spec);
okAll = M.closed && M.nonmanifold_edges == 0 && M.zero_area_faces == 0;
rec = struct();
rec.schema = "tepc-geometry-audit-1";
rec.verdict = ternaryStr(okAll, "3D_AUDITED", "3D_NOT_AUDITED");
rec.closed = M.closed;
rec.nonmanifold_edges = M.nonmanifold_edges;
rec.zero_area_faces = M.zero_area_faces;
rec.sensitive_volume = char(spec.geometryType);
rec.electrode_topology = char(spec.electrodeTopology);
rec.field_topology = char(spec.fieldTopology);
rec.anode_type = char(spec.anodeType);
rec.units = char(spec.units);
rec.requested_diameter_um = spec.requestedDiameter_m*1e6;
rec.realized_diameter_um = spec.realizedDiameter_m*1e6;
rec.world_envelope_factor = spec.worldEnvelopeFactor;
% 循环必须按**零件数** (spec.parts 是 8 元结构数组), 而不是按"第一个元素的字段名数"。
% 曾写成 numel(fieldnames(spec.parts)) => 21 个字段名对上 8 个零件, 第 9 次索引
% 越界, 每次 execute 都死在 geometry 相 (实测, 已在回归测试里锁住)。
rec.parts = struct();
for i = 1:numel(spec.parts)
    q = spec.parts(i);
    key = regexprep(char(string(q.part_id)), '[^A-Za-z0-9_]', '_');
    keep = {'part_id','label','shape','material','materialStatus','transport_role',...
            'transport_evidence','units','display_only','coincident_with','note',...
            'analyticVolume_m3','analyticArea_m2'};
    for k = 1:numel(keep)
        if isfield(q, keep{k})
            rec.parts.(key).(keep{k}) = q.(keep{k});
        end
    end
    % 顶点/面坐标数组 (V/F) 刻意不落盘: 审计要的是"结论+规模", 不是第二份网格文件
    if isfield(q, 'V'), rec.parts.(key).n_vertices = size(q.V, 1); end
    if isfield(q, 'F'), rec.parts.(key).n_faces = size(q.F, 1); end
end
rec.n_parts = numel(spec.parts);
% 清单哈希是"这份图对应哪一份几何"的唯一机读出口: 报告与诊断图都要能说出自己画的
% 是哪一版几何, 而 rec 此前只带零件计数, 换几何不会留下任何痕迹。
if isfield(spec, 'manifest') && isfield(spec.manifest, 'sha256')
    rec.geometry_manifest_sha256 = string(spec.manifest.sha256);
else
    rec.geometry_manifest_sha256 = "NOT_RECORDED";
end
rec.note = "审计只覆盖展示网格与拓扑一致性; 输运/FEM 网格与真实电极场求解未做, " + ...
    "因此不得据此宣称'三维模型已通过实验验证'";
tepc.io.writeJson(fullfile(rd.work.results, 'geometry_audit.json'), rec);
verdict = rec.verdict;
manifestSha = rec.geometry_manifest_sha256;
end

function s = ternaryStr(c, a, b)
if c, s = a; else, s = b; end
end

% ---------------- helpers ----------------
function s = depthConflicts(iss0)
% 把 validate 给出的 DEPTH_KNOB_OVERRIDDEN 提取成一行文本 (无冲突时给"无")。
% validate 返回 cell (元素是 struct), 不能点展开, 只能逐格取。
parts = strings(0, 1);
for i = 1:numel(iss0)
    if string(iss0{i}.code) == "DEPTH_KNOB_OVERRIDDEN"
        parts(end+1) = string(iss0{i}.message); %#ok<AGROW>
    end
end
if isempty(parts)
    s = "无";
else
    s = strjoin(cellstr(parts), ' | ');
end
end

function s = depthJson(depth)
% 生效旋钮的机器可读形态。**手写而不是 jsonencode**: jsonencode 对 logical 与整数的
% 输出形态随版本变, 而这一列要能被产物级逐字比对 (事后核对档位生效值用)。
parts = strings(0, 1);
for i = 1:numel(depth.applied)
    v = depth.applied(i).value;
    if islogical(v)
        sv = "false";
        if v, sv = "true"; end
    else
        sv = string(sprintf('%g', double(v)));
    end
    parts(end+1) = sprintf('"%s":%s', depth.applied(i).path, char(sv));  %#ok<AGROW>
end
s = char("{" + strjoin(parts, ",") + "}");
end

function iss = errorIssues(iss0)
if isempty(iss0), iss = {}; return; end
lv = cellfun(@(s) string(s.level), iss0, 'UniformOutput', false);
iss = iss0([lv{:}] == "error");
end

function args = parseArgs(v)
known = {'N','Seed','RunDir','Progress','CancelFlag','PauseFlag','Resume'};
args = struct('N', [], 'Seed', [], 'RunDir', '', 'Progress', [], ...
    'CancelFlag', '', 'PauseFlag', '', 'Resume', false);
if mod(numel(v),2) ~= 0
    error("tepc:run:Args","Name-Value 参数必须成对给出 (实得 %d 项)", numel(v));
end
for i = 1:2:numel(v)
    nm = char(v{i});
    if ~any(strcmp(nm, known))
        error("tepc:run:Args","未知参数 '%s' (允许: %s)", nm, strjoin(known, ', '));
    end
    args.(nm) = v{i+1};
end
end

function progTee(userProg, rd, frac, msg)
%PROGTEE 用户回调 + logs/PROGRESS.json 落盘。
%   记账失败绝不能反噬主流程 (进度是诊断信息, 不是数据), 所以这里的 catch 是
%   有意为之的 silent-by-design, 并留下注释供静态检查豁免。
if ~isempty(userProg), userProg(frac, msg); end
try
    tepc.io.writeJson(fullfile(rd.logs, 'PROGRESS.json'), struct( ...
        'fraction', frac, 'message', char(string(msg)), ...
        'utc', char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss'))));
catch %#ok<CTCH> % silent-by-design: 进度落盘失败不影响结果
end
end

function progCall(f, frac, msg)
if ~isempty(f), f(frac, msg); end
end

function checkFlags(args)
if ~isempty(args.PauseFlag) && isfile(args.PauseFlag)
    while isfile(args.PauseFlag) && ~iscancel(args), pause(0.5); end
end
if iscancel(args)
    error("tepc:run:CancelRequested","运行被取消");
end
end

function tf = iscancel(args)
tf = ~isempty(args.CancelFlag) && isfile(args.CancelFlag);
end

function cancelStatus(rd, nChunks, resumedFrom)
% 取消也必须留下可审计状态 (旧实现里这段位于死代码之后, 从不执行)。
% 状态词统一由 tepc.io.runWriteStatus 决定; 非 completed 必须带 reason。
try
    tepc.io.runWriteStatus(rd.logs, 'cancelled', 'Phase', "run", ...
        'Reason', sprintf("收到取消标志: 已完成 %d chunk, %d 事件 (raw/ 保留可续跑)", ...
        nChunks, resumedFrom), ...
        'RunID', rd.runID, 'CompletedChunks', nChunks);
catch
end
end

function E = mergeChunks(chunks)
n = 0;
for i = 1:numel(chunks), n = n + chunks{i}.n; end
E = tepc.domain.EventBatch.preallocate(n);
if n == 0, return; end
pos = 1;
for i = 1:numel(chunks)
    ck = chunks{i};
    fn = fieldnames(ck.ev);
    for j = 1:numel(fn)
        src = ck.ev.(fn{j});
        if numel(src) == 1 && ck.n ~= 1, src = repmat(src, ck.n, 1); end
        E.ev.(fn{j})(pos:pos+ck.n-1) = src;
    end
    pos = pos + ck.n;
end
end

function writeSpectrumCsv(path, S, Sin)
% 列口径写进表头: f_y/d_y 的分母是**全部有效事件**, f_in/d_in 是域内重归一。
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0, error("tepc:run:CsvFailed","无法写 %s", path); end
% BOM 不是冗余: 中文 Windows 的 Excel 打开无 BOM 的 UTF-8 CSV 时按本机码页(GBK)猜,
% 第一行中文口径说明会显示成一串生僻字。BOM 只落在首行注释上, 表头行仍是纯 ASCII,
% 按字节比对的哈希锁与 readmatrix 都不受影响。
fwrite(fid, [239 187 191], 'uint8');
fprintf(fid, ['# 口径: f_y/d_y 分母=全部有效事件 (int f dy = 1-阈下-超溢); ' ...
    'f_in/d_in 分母=域内 bin (int f_in dy = 1)。counts 列为事件个数, sum_w 列为权重。\n']);
fprintf(fid, ['bin_low_keV_um,bin_high_keV_um,center_keV_um,dy,counts_raw,' ...
    'sum_w,sum_w2,f_y,sigma_f,d_y,f_in,d_in\n']);
if nargin < 3 || isempty(Sin), Sin = S; end
for i = 1:numel(S.center)
    fprintf(fid, '%.6e,%.6e,%.6e,%.6e,%d,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e\n', ...
        S.edges(i), S.edges(i+1), S.center(i), S.dy(i), S.counts_raw(i), ...
        S.sum_w(i), S.sum_w2(i), S.f(i), S.sigma_f(i), S.d(i), ...
        Sin.f(i), Sin.d(i));
end
fclose(fid);
end

function paths = writeFigures(R, rd)
%WRITEFIGURES 每次运行都把诊断图落到 run 目录的 figures/ (无头模式安全)。
%   刻意**不**吞异常: diagnostic.png 是发布集成员 (报告内嵌它, provenance 哈希它),
%   画不出来就是产物不完整, 必须让 execute 走 STATUS=incomplete 记账, 而不是
%   "图上没画出来但状态写着 completed"。
%   离屏渲染固定用 opengl/隐藏 figure, 无显示器也能出图。
paths = {};
fig = tepc.report.diagnosticFigure(R);
p1 = fullfile(rd.figures, 'diagnostic.png');
try
    exportgraphics(fig, p1, 'Resolution', 150);
catch eG
    % 实测一次全量套件里 exportgraphics 报 MATLAB:print:CannotCreateOutputFile
    % ("No such file or directory"), 而同一用例单跑 8/8 通过 —— 目录由 layoutRunDirs
    % 建好, 所以这是一次性的渲染/IO 抖动, 不是产物布局缺陷。补一次"缺目录就重建 +
    % 重画"; 再失败仍原样抛出 (诊断图是发布集成员, 不许静默降级)。
    if ~isfolder(rd.figures)
        mkdir(rd.figures);
    end
    try
        exportgraphics(fig, p1, 'Resolution', 150);
    catch eG2
        close(fig);
        rethrow(eG2);
    end
end
di1 = dir(p1);
if isempty(di1) || di1.bytes == 0
    close(fig);
    error("tepc:run:FigureNotWritten", "diagnostic.png 未生成或为空文件: %s", p1);
end
% 非零字节但被截断的 PNG 以前会被当成写完: 报告照嵌、provenance 照哈希, 读者看到的是半张图。
% PNG 一定以 IEND 块 + 固定 CRC 收尾, 也一定以 8 字节签名开头, 两头都查才算写完。
if ~isPngComplete(p1)
    close(fig);
    error("tepc:run:FigureTruncated", ...
        "diagnostic.png 不是完整 PNG (签名或 IEND 块尾缺失): %s (%d 字节)", p1, di1.bytes);
end
paths{1} = p1;
close(fig);
end

function ok = isPngComplete(f)
ok = false;
fid = fopen(f, 'r');
if fid < 0, return; end
cleanOn = onCleanup(@() fclose(fid));          %#ok<NASGU>
hdr = fread(fid, 8, 'uint8=>uint8');           % fread 返回列向量, 这里统一成行再比
if numel(hdr) ~= 8 || ~isequal(hdr(:).', [137 80 78 71 13 10 26 10])
    return
end
if fseek(fid, -8, 'eof') ~= 0, return; end
tail = fread(fid, 8, 'uint8=>uint8');
ok = numel(tail) == 8 && isequal(tail(:).', [73 69 78 68 174 66 96 130]);
end

function summary = buildSummary(R, A, seed, N, resumedFrom, cfg)
summary = struct();
summary.runID = R.runDir.runID;
summary.schemaVersion = "1.1";
summary.label = "RESEARCH/DEMO";
% 后端标识与 label 同层: label 说的是发布档位, backend_id 说的是算的是什么模型。
summary.backend_id = tepc.backendId();
if string(cfg.run.mode) == "VALIDATED"
    % 旧实现无条件写 "RESEARCH/DEMO", 与 run.mode=VALIDATED 自相矛盾
    summary.label = "VALIDATED";
end
summary.mode = R.cfg.run.mode;
summary.seed = seed;
summary.nEvents = N;
summary.resumed_from = resumedFrom;
summary.config_sha256 = R.config_sha256;
summary.yF_keV_um = A.spectrum.yF_exact;
summary.yD_keV_um = A.spectrum.yD_exact;
if A.spectrum.Qmissing
    summary.Qbar = "NA";
else
    summary.Qbar = A.spectrum.Qbar;
end
% 仪器链 vs 真值交叉核对
summary.instrument_chain = A.instrument_chain;
summary.n_meas_valid = A.n_meas_valid;
if ~isempty(A.spectrum_truth)
    summary.yF_truth_keV_um = A.spectrum_truth.yF_exact;
    summary.yD_truth_keV_um = A.spectrum_truth.yD_exact;
    summary.instr_bias_yF = A.spectrum.yF_exact/A.spectrum_truth.yF_exact - 1;
    summary.instr_res_fwhm_over_yF = ...
        (A.spectrum.yD_exact/A.spectrum.yF_exact) / ...
        (A.spectrum_truth.yD_exact/A.spectrum_truth.yF_exact) - 1;
end
% --- 剂量摘要: 唯一输入源是剂量链的分层诚实名 (T1/T2/T3), 不读旧名 ----------------
% 分层与分母 (逐列不同, 见 tepc.analysis.doseChain 的头注释):
%   D_gas_Gy / D_gas_per_event_Gy        A 链: 气腔质量, 累计 / 每记录事件
%   z_mean_per_history_Gy                T2: 位点质量 m_site, 每初级历史
%   z_mean_given_valid_Gy                T2 条件口径: 分母 = sum_valid w_stat
%   D_macro_Gy = k_norm*z_mean_per_history_Gy   T3: 只在源归一链完整时有限
%   H_macro_Sv = Qbar*D_macro_Gy         T3 剂量当量: 同样只在 k_norm 有限时有定义
% 旧名 (D_tissue_Gy / D_tissue_per_event_Gy / H_micro_Sv) 仍写进 summary, 但**由新名
% 反算**: 它们是 GUI 剂量页、workflows/run_demo 与 tests/golden 基线的取值凭据,
% 删掉就是单方面改契约; 本函数不再从剂量链读旧名, 改名链一旦断供会当场报错而不是静默。
Dz = A.dose;
summary.z_mean_per_history_Gy   = Dz.z_mean_per_history_Gy;
summary.z_mean_given_valid_Gy   = Dz.z_mean_given_valid_Gy;
summary.z_mean_gas_per_history_Gy = Dz.z_mean_gas_per_history_Gy;
summary.k_norm                  = Dz.k_norm;
summary.D_macro_Gy              = Dz.D_macro_Gy;
summary.H_macro_Sv              = Dz.H_macro_Sv;
summary.nHistories              = Dz.nHistories;
summary.source_normalization_status = Dz.book.source_normalization_status;
% 剂量链给的"为什么不可用"必须跟着进 summary: report.doseLine 读的就是这个名, 不传
% 的话它只能落到自己的兜底串 source_normalization_undefined —— 于是"因子齐但状态未
% 声明"这类情况被误诊成"因子没给", 读者会去补 A_eff 而真正缺的是 status 声明。
summary.D_macro_reason            = Dz.D_macro_reason;
summary.D_gas_Gy                = Dz.D_gas_Gy;
summary.D_gas_per_event_Gy      = Dz.D_gas_per_event_Gy;
summary.D_tissue_Gy             = Dz.z_mean_per_history_Gy * Dz.nHistories;
summary.D_tissue_per_event_Gy   = Dz.z_mean_per_history_Gy;
summary.H_micro_Sv              = Dz.H_macro_Sv;
summary.dose_legacy_aliases = ["D_tissue_Gy = z_mean_per_history_Gy*nHistories", ...
    "D_tissue_per_event_Gy = z_mean_per_history_Gy", "H_micro_Sv = H_macro_Sv", ...
    "旧名仅供既有消费方取值, 新代码请改用左列新名"];
summary.dose_note = A.dose_note;
summary.t_obs_s = A.t_obs_s;
% 剂量率: 累计剂量 / 观测时长 (旧实现把累积剂量再乘一次计数率 => 恰好偏大 N 倍)。
% 这个数仍是**演示值**: 分子是 A 链在本次 N 个事件上的累计量, 分母是模拟观察跨度,
% 既没有源归一链 (k_norm=NaN 时宏观注量无定义) 也没有参考场标定, 所以它不能当作
% 可发布的绝对剂量率。此处只显式标注口径与不可发布性, 不改数值 (test_pipeline 按
% "存在且 > 0" 核对它, 语义变更应由那条测试自己改)。
summary.dose_rate_uGy_h = Dz.D_gas_Gy/max(A.t_obs_s,eps) * 3.6e9;
summary.dose_rate_kind = "DEMO";
summary.dose_rate_basis = "演示口径: 累计 D_gas / 观测时长 x 3.6e9; " + ...
    "源归一链状态 = " + string(Dz.book.source_normalization_status) + ...
    " (k_norm = " + string(mat2str(Dz.k_norm)) + ...
    "); 绝对剂量率须经参考场标定后方可发布";
summary.dose_rate_publishable = false;
summary.dose_rate_basis = summary.dose_rate_basis + ...
    " | 分子 = 本次 N 个事件的累计真值气腔沉积 (EdepGas_keV, 不是仪器反演授予能), 靶质量 = m_gas; " + ...
    "分母 = 模拟源强 cfg.source.rate_cps 下的到达跨度 t_obs, 不是实测计时";
summary.zeroDep_fraction = A.flags.zeroDep/A.nEvents;
summary.overflow_count = A.flags.overflowADC;
summary.underflow_threshold_count = A.flags.underThr;
% 阈下截断的可审计口径: 发布矩只覆盖"过阈且有效"的事件群, 必须同时给出全历史真值矩
% 与两者的偏差, 否则读者只能看到"丢失=0"而以为谱是完整的。
summary.threshold_lost_count      = A.threshold_lost_count;
summary.threshold_lost_fraction   = A.threshold_lost_fraction;
summary.n_published_moments       = A.n_published_moments;
summary.n_truth_all               = A.n_truth_all;
summary.yF_truth_all_keV_um       = A.yF_truth_all_keV_um;
summary.yD_truth_all_keV_um       = A.yD_truth_all_keV_um;
summary.threshold_truncation_bias_rel_yF = A.threshold_truncation_bias_rel_yF;
summary.threshold_truncation_bias_rel_yD = A.threshold_truncation_bias_rel_yD;
summary.published_moment_population = A.published_moment_population;
summary.underflowWeight = A.spectrum.underflowWeight;
summary.overflowWeight = A.spectrum.overflowWeight;
summary.deadRejected = A.flags.deadRejected;
summary.pileupCount = A.flags.pileup;
summary.shape_anomaly_count = A.flags.shapeAnomaly;
% 壁生次级的发布: 伽马道的作用点现在按"入射壁 -> 气腔 -> 出射壁"整条线路抽样, 所以必须
% 同时给出"有多少事件在壁里作用"和"其中有多少真把能量送进气腔", 否则读者无法区分
% "模型看见了壁"与"这台配置能测伽马" (1000 Pa 下前者成立、后者不成立)。
summary.wall_secondary_count    = A.flags.wallSecondary;
summary.wall_secondary_in_gas   = A.flags.wallSecondaryInGas;
summary.wall_secondary_fraction = A.flags.wallSecondary / max(A.nEvents, 1);
summary.liveFrac = A.liveFrac;
summary.nEff = A.spectrum.nEff;
summary.intFdy = A.spectrum.intFdy;
summary.intDdy = A.spectrum.intDdy;
% 归一化口径与区间外**事件个数**: 只有权重时读者分不清"丢 3 个事件"和
% "丢 30% 权重", 也极易把 ∫f dy != 1 误判成分箱 bug。
summary.spectrum_scope = ["y_F/y_D = 全部有效事件的权重矩; f(y)/d(y) 直方只覆盖域内 bin, " ...
    "故 ∫f dy = 1 - 阈下份额 - 超溢份额 (另有 *_in_range 为域内重归一版)"];
summary.counts_in_range = A.spectrum.counts_inRange;
summary.counts_underflow = A.spectrum.counts_underflow;
summary.counts_overflow = A.spectrum.counts_overflow;
summary.intFdy_in_range = A.spectrum_in.intFdy;
summary.y_track_keV_um = A.y_track_keV_um;
summary.Qnote = A.dose.Qnote;
% Qbar 的语义要跟着数走: 它是"用 y 当 LET 查 ICRP 经验函数"得到的研究估计, 不是法定
% 剂量当量转换因子。只写 Qnote 的话, summary.json 的读者拿到的是一个看起来可直接换算
% 的无量纲数。approx 记算法口径 (QF_APPROX_Y_AS_LET / QF_FROM_TABLE / none)。
summary.Q_y_research_estimate = true;
summary.Q_y_approx = string(R.qmeta.approx);
summary.Q_y_source = string(R.qmeta.source);
% 壁密度的取值与来源也进 summary: 壁能损与逃逸份额吃的是常数注册表里那个 ASSUMED 值,
% 报告读者要能在产物里看到它是多少、从哪一条读来的, 而不是翻代码。取数点与被锁对象同
% 一个函数 (tepc.transport.wallDensity), 因此这里不会出现第二份判定。
[wallRhoRun, wallRhoSrcRun] = tepc.transport.wallDensity(struct());
summary.wall_rho_g_cm3 = wallRhoRun;
summary.wall_rho_source = wallRhoSrcRun;
summary.lbar_tissue_um = A.lbar_tissue_um;
summary.site_equivalence_mode = R.resolve.siteMode;
summary.site_realized_d_tissue_um = R.resolve.geom.site.d_tissue_m*1e6;
summary.site_requested_d_tissue_um = R.resolve.site_requested_d_tissue_m*1e6;
summary.G_mean = R.resolve.G_mean;
% "在插值域内" != "对标过实测"。次级带电粒子能量落在 ASSUMED 锚定拼接带
% (<assumed_below_MeV, 默认 1 MeV) 的事件占比必须显示出来 (门禁第 16 项消费它)。
% 数据取自 execute 在分析阶段暂存的 R.bandStats —— A.dose 里没有逐事件次级能量。
if isfield(R,'bandStats') && R.bandStats.nPos > 0
    summary.pct_events_in_ASSUMED_band = 100*R.bandStats.nBand/R.bandStats.nPos;
else
    summary.pct_events_in_ASSUMED_band = NaN;
end
summary.n_events_with_secondaries = R.bandStats.nPos;
if isfield(R,'geometryAudit')
    summary.geometry_audit = R.geometryAudit;
else
    summary.geometry_audit = "3D_NOT_AUDITED";
end
if isfield(R,'geometryManifestSha256')
    summary.geometry_manifest_sha256 = R.geometryManifestSha256;
else
    summary.geometry_manifest_sha256 = "NOT_RECORDED";
end
summary.stopping_assumed_band_MeV = R.bandStats.limMeV;
summary.stopping_table_sha256_proton = R.bandStats.tableSha;
summary.limitations = [ ...
    "解析/经验基线: 未用蒙卡输运, 不宣称精确中子/伽马响应", ...
    "RESEARCH/DEMO 标签: 无参考场标定, 禁止绝对剂量发布", ...
    "载流子迁移率与电离云半径为 ASSUMED (影响弹道亏损, 已由同模型刻度吸收均值)", ...
    R.resolve.notes{:}];
end
