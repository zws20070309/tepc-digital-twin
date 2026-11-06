function tests = test_uq_measurement
%TEST_UQ_MEASUREMENT 测量侧不确定度是否真的进入链路。
%   "UQ 中反演固定名义 G/W/刻度, 只扰动物理侧" 这个说法并不成立:
%   propagateMC.m 的 adcCal_rel 一直在扰动反演侧。真正的缺口是: 阈值/噪声/死时间
%   既不在白名单也不进链路 (给了就报错), 且不返回任何相关结构。本文件逐条锁住修复。
tests = functiontests(localfunctions);
end

function cfg = baseCfg(nS)
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
cfg.uq.enabled = true;
cfg.uq.nSamples = nS;
cfg.uq.NEvPerSample = 150;
end

function o = runWith(name, sd)
cfg = baseCfg(5);
cfg.uq.variables.(name).sd = sd;
o = tepc.uq.propagateMC(cfg, 5, 'Seed', 555, 'NEvPerSample', 150);
end

function o = runBaseline()
cfg = baseCfg(5);
f = fieldnames(cfg.uq.variables);
for i = 1:numel(f)
    % 注意: 这里只退化 normal 分支。fano 是 uniform(lo/hi), drawVar 不消费 sd, 所以它
    % 仍在 0.15-0.25 里逐样本抽样 —— 本函数的基线是"除 Fano 外无扰动"的参照, 不是名义点。
    % 需要真名义点 (全部变量塌成常数) 的地方用 degenerateAtNominal。
    cfg.uq.variables.(f{i}).sd = 0;
end
o = tepc.uq.propagateMC(cfg, 5, 'Seed', 555, 'NEvPerSample', 150);
end

function test_measurement_variables_are_in_whitelist(tc)
% 三个测量侧旋钮必须可用 (旧实现给就报 tepc:uq:UnknownVariable)
cfg = baseCfg(3);
for nm = ["threshold_rel","noise_rel","deadTime_rel"]
    tc.verifyTrue(isfield(cfg.uq.variables, nm), ...
        sprintf('demo 配置必须声明 %s', nm));
    o = runWith(nm, 0.05);
    tc.verifyEqual(numel(o.failed), 0, ...
        sprintf('%s 扰动不得让样本失败 (实得 %s)', nm, ...
        joinf(o.failed)));
    % 只问"有没有产生 Inf": 原写法 isfinite(o.yF(o.yF~=0)) | isnan(o.yF) 两侧长度不同
    % (一边滤掉零, 一边是全体), 只有在"恰好没有零"时才偶然不报维度错。
    tc.verifyFalse(any(isinf(o.yF)), sprintf('%s 扰动后 y_F 出现 Inf', nm));
end
end

function test_each_measurement_knob_moves_the_result(tc)
% 单变量扰动必须改变 y_F: 否则"接入"只是名义上的 (本项目的老毛病: 必填但无人读)。
b = runBaseline();
for nm = ["adcCal_rel","threshold_rel","noise_rel","deadTime_rel","W_rel","gainScale"]
    o = runWith(nm, 0.08);
    % 本机没装 Statistics 工具箱 -> nanmean 根本不存在 (实测 MATLAB:UndefinedFunction,
    % 且它会让整条用例"报错"而不是"断言失败")。基线等价写法是 mean(...,'omitnan')。
    d = abs(mean(o.yF, 'omitnan') - mean(b.yF, 'omitnan'));
    rel = d / max(abs(mean(b.yF, 'omitnan')), eps);
    tc.verifyGreaterThan(rel, 1e-9, ...
        sprintf('%s 扰动 8%% 后 y_F 完全没动 (相对差 %.3e) => 旋钮未真正接入', nm, rel));
end
end

function test_paired_truth_column_exists_and_bias_is_reported(tc)
o = runWith('W_rel', 0.05);
tc.verifyTrue(isfield(o, 'yF_truth'), '必须给出配对真值 y_F (无仪器链)');
tc.verifyEqual(numel(o.yF_truth), numel(o.yF));
tc.verifyTrue(isfield(o.summary,'instr_bias_mean') && isfinite(o.summary.instr_bias_mean), ...
    '仪器链系统项必须被量化报告, 否则"测量 vs 物理"只是贴标签');
tc.verifyTrue(abs(o.summary.instr_bias_mean) < 0.5, ...
    sprintf('刻度自洽前提下仪器偏差应在小量级, 实得 %.3f', o.summary.instr_bias_mean));
end

function test_correlation_structures_returned(tc)
% 相关结构只能在"输入列真的有变化"时谈: runBaseline() 把全部 sd 设成 0, 每个输入列
% 于是是常数列, corrcoef 按定义给 NaN —— 用它来断言"corr_inputs 必须是有限互相关值"
% 永远不可能成立 (实测)。所以这里用**发货配置自带的 sd** 抽样。
% N=40 而不是 5: 独立性上界必须**小于 1** 才是有判别力的断言, 而且要按比较次数校正。
% 独立样本下 Spearman 的标准差约 1/sqrt(N-1): N=12 时 0.30, 而这里有 d*(d-1)=72 个
% 配对同时受检 —— 3σ 上界会被随机涨落正常越过去, 断言就成了"靠种子运气通过"。
% 取 4σ (≈ Bonferroni 对 72 次的水平) 并要求 N 大到该上界明显小于 1。
cfg = baseCfg(40);
o = tepc.uq.propagateMC(cfg, 40, 'Seed', 555, 'NEvPerSample', 150);
tc.verifyEqual(numel(o.failed), 0, sprintf('发货 sd 下样本不应失败: %s', joinf(o.failed)));
d = numel(o.variables);
tc.verifyTrue(isfield(o,'corr_inputs') && isfield(o,'corr_with_yF'));
tc.verifyEqual(size(o.corr_inputs), [d d]);
tc.verifyEqual(numel(o.corr_with_yF), d);
tc.verifyTrue(all(abs(o.corr_with_yF(:)) <= 1 + 1e-12), '相关系数必须在 [-1,1]');
tc.verifyTrue(all(abs(diag(o.corr_inputs) - 1) < 1e-9), '自相关必须是 1 (矩阵没接错线)');
% 敏感度必须**有限且非零**: 旧断言写的是 `corr_with_yF("W_rel") ~= 0`, 而 NaN ~= 0
% 在 MATLAB 里为真 —— 基线配置里 sd 全为 0 时该列是 NaN, 断言恒过 (永远不会失效)。
iW = find(strcmp(o.variables, 'W_rel'), 1);
tc.verifyFalse(isempty(iW), '基线必须声明 W_rel 变量');
rW = o.corr_with_yF(iW);
tc.verifyTrue(isfinite(rW), ...
    sprintf('W_rel 的 Spearman 必须是有限值, 实得 %s (扰动没传进链路就是 NaN)', mat2str(rW)));
% 这里**不再**断言 |rho| 的大小: 9 个旋钮同时扰动时 y_F 的方差由全体共同贡献,
% 单个变量的 Spearman 就是它自己的方差占比的开方 —— 实测 |rho(W_rel)|=0.016 是
% 正确的统计结果而不是"链路未接"。"单变量必须可见地改变 y_F"这条判别力属于
% test_uq_validation/test_uq_every_nuisance_variable_actually_propagates
% (那里每次只留一个变量在动, 要求 spread>1e-4 且 |rho|>0.5), 不在这里重复。
% 声明的输入相关必须真的复现: config uq.correlations = {} (全独立) => LHS/copula
% 只能给出抽样噪声级别的互相关。3/sqrt(n) 是独立样本下 Spearman 的粗上界,
% 明显超过它说明"独立"承诺被接线错误破坏 (或某列是常数导致 NaN 被无声吃掉)。
off = ~eye(d);
mc = o.corr_inputs(off);
mc = mc(isfinite(mc));
tc.verifyFalse(isempty(mc), 'corr_inputs 必须给出有限互相关值');
tol = 4/sqrt(max(o.nSamples - 1, 1));   % 4σ: 对 72 个配对同时受检的粗 Bonferroni 水平
% 原来写的 max(tol, 0.6) 下限会在 N 变小时悄悄把判据放宽成恒真, 去掉。
tc.verifyTrue(all(abs(mc) <= tol), ...
    sprintf('声明独立的输入出现 |rho|=%.3f > 4/sqrt(N-1)=%.3f 的互相关', max(abs(mc)), tol));
end

function test_class_tags_present(tc)
o = runBaseline();
tc.verifyTrue(isfield(o,'class'));
tc.verifyEqual(numel(o.class), numel(o.variables));
iW = find(strcmp(o.variables,'W_rel'),1);  iT = find(strcmp(o.variables,'threshold_rel'),1);
tc.verifyEqual(o.class(iW), "physics");
tc.verifyEqual(o.class(iT), "measurement");
end

function test_unknown_variable_still_rejected(tc)
cfg = baseCfg(2);
cfg.uq.variables.nonexistent_knob = struct('dist','normal','mean',0,'sd',1);
tc.verifyError(@() tepc.uq.propagateMC(cfg, 2, 'Seed', 1, 'NEvPerSample', 60), ...
    'tepc:uq:UnknownVariable');
end

function test_dead_time_replicates_pipeline_semantics(tc)
% UQ 里的死时间必须与 execute 同一实现 (同一个 daq), 否则两边评的不是同一台仪器。
% 做法: 把 tau 拉到极大 (相对率) -> 接受数骤降 -> y_F 变化方向可预期。
cfg = baseCfg(3);
for nm = fieldnames(cfg.uq.variables)'
    cfg.uq.variables.(nm{1}).sd = 0;
end
cfg.uq.variables.deadTime_rel.sd = 0;
o1 = tepc.uq.propagateMC(cfg, 3, 'Seed', 77, 'NEvPerSample', 200);
cfg2 = cfg; cfg2.electronics.deadTime_s = cfg.electronics.deadTime_s * 50;
o2 = tepc.uq.propagateMC(cfg2, 3, 'Seed', 77, 'NEvPerSample', 200);
tc.verifyGreaterThan(nnz(isfinite(o1.yF) & o1.yF ~= 0), 0, ...
    '至少一个样本给出非零 y_F (numel 是分配长度, 断言它等于非零毫无意义)');
d12 = max([max(abs(o2.yF(:) - o1.yF(:)), [], 'omitnan'), ...
           max(abs(o2.Qbar(:) - o1.Qbar(:)), [], 'omitnan'), ...
           max(abs(o2.D_site(:) - o1.D_site(:)), [], 'omitnan')]);
tc.verifyGreaterThan(d12, 1e-12, ...
    sprintf('死时间放大 50 倍后 y_F/Q̄/D 的最大变化只有 %.3e: daq 未接入 UQ', d12));
end

function test_uq_chain_is_the_pipeline_chain(tc)
% 名义点上, propagateMC 内部那条"逐字复刻 execute"的链必须给出与发布管线**同一个** y_F。
% 它是仓库里第二份链实现; 没有这条锚, 任何"计算方式对 y_F 的贡献"的结论都建立在一份
% 可能与主管线漂移的实现上。口径: 两边都取精确矩 yF_exact (propagateMC 的 yFk = S.yF_exact)。
% 要求逐位相等且不给容差 —— 名义点已把全部扰动中性化, 两边又共用同一 (seed, eventID)
% 子流与同一 DAQ, 数值上没有应许的差异。
cfg = baseCfg(3);
cfg.uq.enabled = false;                       % 别让 execute 再嵌一次 UQ
cfg = degenerateAtNominal(cfg);
o = tepc.uq.propagateMC(cfg, 3, 'Seed', 555, 'NEvPerSample', 150);
tc.verifyTrue(all(isfinite(o.yF(:))), ...
    sprintf('名义样本 y_F 出现非有限值 (失败样本: %s)', joinf(o.failed)));
% 前置判据先单独核: 名义点若没真塌成常数, 后面那句"与发布值相等"就是拿三个不同点比一个点。
tc.verifyTrue(all(o.yF(:) == o.yF(1)), sprintf( ...
    '名义点的 %d 个样本 y_F 互不相同 (%s): 至少一个变量没有真正退化, 锚的前提已破', ...
    numel(o.yF), strjoin(compose("%.17g", o.yF(:)'), ', ')));
R = tepc.run.execute(cfg, 'N', 150, 'Seed', 555, 'RunDir', tempname());
yPub = R.analysis.spectrum.yF_exact;
for i = 1:numel(o.yF)
    tc.verifyEqual(o.yF(i), yPub, 'AbsTol', 0, sprintf( ...
        ['第 %d 个名义样本的 y_F %.17g 与发布管线的 yF_exact %.17g 不逐位相同 ' ...
         '(相对差 %.3e): UQ 评的不是主管线那台仪器'], ...
        i, o.yF(i), yPub, abs(o.yF(i) - yPub) / max(abs(yPub), eps)));
end
end

function cfg = degenerateAtNominal(cfg)
% 把每个扰动变量塌到名义点。**uniform 分支不消费 sd** (drawVar 用 lo + u*(hi-lo)),
% 所以"把 sd 设成 0"对 fano 是空操作 —— 那样每个名义样本仍各自抽到不同的 Fano,
% 而 Fano 经 sampleIonPairs 直接进电荷/峰位/码, 锚就会拿三个不同的 y_F 比同一个发布值。
f = fieldnames(cfg.uq.variables);
for i = 1:numel(f)
    nm = string(f{i});
    sp = cfg.uq.variables.(f{i});
    switch string(sp.dist)
        case "normal"
            sp.mean = 0;  sp.sd = 0;
        case "uniform"
            v = nominalOf(nm, cfg);
            sp.lo = v;    sp.hi = v;
        case "fixed"
            % 本来就是常数, 不动
        otherwise
            error('tepc:tests:NominalDist', ...
                '变量 %s 的分布 %s 不认识: 名义点无法构造 (新增分布要在这里登记退化方式)', ...
                nm, string(sp.dist));
    end
    cfg.uq.variables.(f{i}) = sp;
end
end

function v = nominalOf(nm, cfg)
% uniform 变量的名义值来自各自的物理块, 不在此登记就报错而不是猜一个中点。
switch nm
    case "fano",  v = cfg.gas.fano.value;
    otherwise
        error('tepc:tests:NominalMap', ...
            'uniform 变量 %s 没有登记名义值: 取区间中点会把一个凭空的数当成名义点', nm);
end
end

%% ---------------- helpers ----------------
function s = joinf(failed)
% out.failed 是 **cell of struct** (与 tepc.config.validate 的 issues 同一约定)。
% 旧写法 strjoin({failed.id}) 对 cell 做点索引 -> MATLAB:structRefFromNonStruct:
% "报告失败原因"这件事本身把用例崩掉, 真正的原因 (每个样本都失败) 反而看不见。
% 先 [failed{:}] 拍成 struct 数组再取字段。
if isempty(failed), s = "无"; return; end
rec = [failed{:}];
s = strjoin(string({rec.id}), ", ");
end
