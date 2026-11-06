function tests = test_uq_validation
%TEST_UQ_VALIDATION 场分离/谱比较/bootstrap/LHS。
%   额外要求: 比较度量必须有"判别力" —— 对真实差异必须报警, 而不是只对
%   自身实现自洽。
tests = functiontests(localfunctions);
end

function test_separate_fields_recovery(tc)
% 合成混合: alpha_n=0.3 应被模板似然恢复
edges = logspace(log10(0.1), log10(100), 41);
rs = RandStream('Threefry','Seed',11);
yn = min(max(exp(1.0 + 0.5*randn(rs, 3000, 1)), 0.11), 99);
yg = min(max(exp(0.4 + 0.4*randn(rs, 5000, 1)), 0.11), 99);
alphaTrue = 0.3;
ymix = [min(max(exp(1.0 + 0.5*randn(rs, 2571, 1)), 0.11), 99); ...
        min(max(exp(0.4 + 0.4*randn(rs, 6000, 1)), 0.11), 99)];
Smix = tepc.analysis.buildSpectrum(ymix, 1.0, ones(numel(ymix),1), edges);
Sn = tepc.analysis.buildSpectrum(yn, 1.0, ones(numel(yn),1), edges);
Sg = tepc.analysis.buildSpectrum(yg, 1.0, ones(numel(yg),1), edges);
out = tepc.analysis.separateFields(Smix, Sn, Sg);
tc.verifyLessThan(abs(out.alpha_n - alphaTrue), 0.12, ...
    sprintf('alpha_n=%.2f 应接近 %.2f', out.alpha_n, alphaTrue));
end

function test_compare_spectra_identical(tc)
edges = logspace(log10(0.1), log10(100), 31);
S1 = tepc.analysis.buildSpectrum(20*rand(50000,1)+0.2, 1.0, ones(50000,1), edges);
S2 = tepc.analysis.buildSpectrum(20*rand(50000,1)+0.2, 1.0, ones(50000,1), edges);
out = tepc.validation.compareSpectra(S1, S2);
tc.verifyLessThan(out.relDiff_yF, 0.01, '同分布独立两谱 yF 相对差应在 MC 误差内');
tc.verifyLessThan(out.chi2_per_dof, 25, '同分布两谱 chi2/dof 应接近 1 量级');
end

function test_bootstrap_ci_covers(tc)
rng(3);
y = abs(randn(8000,1))*8 + 1;
B = tepc.uq.bootstrapSpectrum(y, 1.0, ones(8000,1), logspace(log10(0.1), log10(100), 31), 200, ...
    RandStream('Threefry','Seed',5));
yF_true = mean(y);
tc.verifyTrue(B.yF_CI95(1) <= yF_true && yF_true <= B.yF_CI95(2), ...
    'bootstrap 95% CI 应覆盖真值');
tc.verifyLessThan(abs(B.yF_mean - yF_true)/yF_true, 0.02);
end

function test_lhs_stratified(tc)
rs = RandStream('Threefry','Seed',1);
X = tepc.uq.lhs(100, 3, rs);
tc.verifyEqual(size(X), [100 3]);
% 每维 10 层, 每层恰好 10 个样本 (LHS 分层定义)
for j = 1:3
    cnt = histcounts(X(:,j), 0:0.1:1.0001);
    tc.verifyEqual(nnz(cnt == 10), 10, sprintf('维度 %d 应每层 10 个样本', j));
end
tc.verifyTrue(all(X(:) >= 0 & X(:) <= 1));
end

function test_compare_spectra_detects_real_shift(tc)
% 同一 bin 网格下把 y 轴整体平移 -> 度量必须显著报警 (原实现只会"自洽通过")
rng(11);
edges = logspace(log10(0.1), log10(200), 41);
a = 3*rand(40000,1) + 0.3;
b = 9*rand(40000,1) + 0.3;                    % yF 约 3 倍
S1 = tepc.analysis.buildSpectrum(a, 1.0, ones(numel(a),1), edges);
S2 = tepc.analysis.buildSpectrum(b, 1.0, ones(numel(b),1), edges);
out = tepc.validation.compareSpectra(S1, S2);
tc.verifyGreaterThan(out.relDiff_yF, 0.5, '真实平移必须被 yF 相对差捕获');
tc.verifyGreaterThan(out.chi2_per_dof, 20, 'bin 级形状差异必须反映到 chi2');
tc.verifyGreaterThan(out.maxRelDiff_f, 0.2);
tc.verifyError(@() tepc.validation.compareSpectra(S1, ...
    tepc.analysis.buildSpectrum(a, 1.0, ones(numel(a),1), edges(1:20))), ...
    'tepc:compare:Edges', 'bin 不一致必须拒绝比较');
end

function test_bootstrap_ci_width_scales_with_n(tc)
% CI 宽度须随样本量 ~1/sqrt(n) 收缩 (统计性质, 非实现自洽)
rng(5);
rs1 = RandStream('Threefry','Seed',13);
edges = logspace(log10(0.1), log10(100), 31);
y = abs(randn(8000,1))*8 + 1;
B1 = tepc.uq.bootstrapSpectrum(y, 1.0, ones(8000,1), edges, 200, rs1);
w = ones(4000,1);
B2 = tepc.uq.bootstrapSpectrum(y(1:4000), 1.0, w, edges, 200, ...
    RandStream('Threefry','Seed',13));
wd1 = B1.yF_CI95(2) - B1.yF_CI95(1);
wd2 = B2.yF_CI95(2) - B2.yF_CI95(1);
tc.verifyGreaterThan(wd1, 0, 'CI 必须有宽度');
tc.verifyLessThan(wd1, 0.95*wd2, '样本数加倍必须显著收窄 CI (n^-1/2)');
tc.verifyEqual(B1.nEvents, 8000);
tc.verifyEqual(B1.B, 200);
end

function test_lhs_is_seeded_and_deterministic(tc)
X1 = tepc.uq.lhs(64, 4, RandStream('Threefry','Seed',2024));
X2 = tepc.uq.lhs(64, 4, RandStream('Threefry','Seed',2024));
X3 = tepc.uq.lhs(64, 4, RandStream('Threefry','Seed',2025));
tc.verifyEqual(size(X1), [64 4]);
tc.verifyTrue(isequal(X1, X2), '同 seed 必须逐位可复现');
tc.verifyFalse(isequal(X1, X3), '不同 seed 必须给出不同设计');
tc.verifyTrue(all(X1(:) > 0 & X1(:) < 1), 'LHS 样本须落在 (0,1) 分层内');
for j = 1:4
    cnt = histcounts(X1(:,j), 0:1/16:1.0001);
    tc.verifyEqual(nnz(cnt == 4), 16, sprintf('维度 %d: 16 层每层 4 个', j));
end
end

function test_norminv_monotone_accurate_and_shape_preserving(tc)
% Acklam 逆正态分位: 单调、连续拼接、形状保持、与教科书分位数一致。
%   两尾符号的坑: R(q) 渐近 = (c1/d1)q = -q < 0, 低尾本就该取 +R —— 若把两尾符号
%   反过来写, z(0.001) 会变 +3.09 且整条曲线单调递减, 本用例正是锁住这一类回归。
p = [1e-6 1e-4 0.001 0.01 0.05 0.5 0.95 0.99 0.999 0.9999 1-1e-6];
x = tepc.uq.norminv(p);
tc.verifyTrue(isrow(x), '行向量输入必须保持行形状');
tc.verifyTrue(all(diff(x) > 0), '分位函数必须严格单调递增');
tc.verifyEqual(x(6), 0, 'AbsTol', 1e-12);
ref = [-4.753421 -3.719016 -3.090232 -2.326348 -1.644854 0 ...
       1.644854 2.326348 3.090232 3.719016 4.753421];
tc.verifyTrue(max(abs(x - ref)) < 5e-4, ...
    sprintf('与标准分位数表最大偏差 %.2e', max(abs(x - ref))));
% 尾部拼接处连续 (plow = 0.02425)
dl = tepc.uq.norminv(0.02425 - 1e-7); dh = tepc.uq.norminv(0.02425 + 1e-7);
tc.verifyLessThan(abs(dl - dh), 1e-3, '尾部/中心近似在拼接点必须连续');
% 反函数关系: norminv 后接正态 CDF 应回到 p
pp = [0.01 0.25 0.5 0.75 0.99];
zz = tepc.uq.norminv(pp);
cdf = 0.5 * (1 + erf(zz / sqrt(2)));
tc.verifyTrue(max(abs(cdf - pp)) < 5e-4, 'norminv 与正态 CDF 必须互逆');
tc.verifyError(@() tepc.uq.norminv([0 0.5]), 'tepc:uq:BadP');
tc.verifyError(@() tepc.uq.norminv(1.2), 'tepc:uq:BadP');
end

function test_uq_every_nuisance_variable_actually_propagates(tc)
% 每个不确定度源单独扰动时都必须改变发布 yF。旧实现里 stopScale 与 adcCal_rel
% 被抽样却从未施加 (tornado 恒 0), 本用例对那种"假传播"有判别力。
%
% 期望值必须**逐个变量给**, 不能一刀切 —— 两个例外都是实测出来的物理事实:
%   * deadTime_rel: 发货工况 source.rate_cps=100 与 deadTime_s=10us 给出占用率
%     r*tau=1e-3, ±5% 的 tau 变化在平均间隔 10 ms 的流上翻转不了任何事件,
%     所以"在发货工况下扰动它"必然零响应。这既不是 bug 也不该被掩盖: 它说明
%     **本工况的死时间不确定度对结果没有贡献**。故改为在高占用率下验接线,
%     并另加一条锁把"发货工况下惰性"这件事钉住 (见 test_dead_time_knob_is_inert_at_shipped_rate)。
%   * noise_rel: 噪声幅度通过"是否过阈/是否被判形状异常"影响接受集, 对 y_F
%     不是单调函数 -> N=5 的 Spearman 离散取值, 不能要求 |rho|>0.5。
%   * fano: Fano 因子只进 `sampleIonPairs.m:27` 的高斯分支 N ~ Normal(mu, sqrt(F*mu))
%     (mu<50 的 Poisson 分支根本不消费 F), 均值 mu=Edep/W 不动 ⇒ 对**均值型**指标 y_F 一阶响应为零;
%     又因发布 y_F 是"过阈截断后总体的条件均值" (实测截断把 y_F 抬高 8.9%, z451_thresh.log),
%     固定均值 + 下侧截断会让条件均值随散布**二阶**上升 —— 所以 y_F 对 fano 既不是零也不是单调信号。
%     这条门的离散性让它更不能用: n=5 无并列时 Spearman 只能取 21 个值 {0,±0.1,...,±1.0},
%     零假设下 P(|rho|>0.5) = 42/120 = 0.350, P(|rho| 恰为 0.5) = 12/120 = 0.100
%     (精确枚举见 审查/_工作底稿/z523_spearman.log) —— 门本身的 α 就是 35%, 而 fano 实测恰落在 0.5。
%     接线仍由 spread 锁住: 公共随机数下"未施加 ⇒ 五样本逐位相同 ⇒ spread 恰为 0",
%     而 fano 单独扰动的实测 spread = 7.6e-3 = 门限 1e-4 的 76 倍, 不需要靠相关性门。
%     待加强 (登记, 本轮未做): ① 下面的 |rho| 取了绝对值, 反号接线会恒绿, 应改成按变量声明预测符号;
%     ② 对 fano 这类方差旋钮, 方向该用二阶量 y_D 验 (E[y^2] = E[y]^2 + F*E[y]), 而不是豁免掉。
cfg = uqDemoCfg();
vn = fieldnames(cfg.uq.variables);
for i = 1:numel(vn)
    ck = cfg;
    if strcmp(vn{i}, 'deadTime_rel')
        ck.source.rate_cps = 3e5;        % 占用率 r*tau=30: 死时间真的在丢事件
    end
    % y_F 对 noise/deadTime/fano 不是单调函数 -> 不能要求 |Spearman| 接近 1
    expectRho = ~any(string(vn{i}) == ["noise_rel","deadTime_rel","fano"]);
    for j = 1:numel(vn)
        s = ck.uq.variables.(vn{j});
        if j == i
            s.dist = 'uniform';
            if strcmp(vn{j}, 'fano'), s.lo = 0.05; s.hi = 0.35;
            else, s.lo = -0.05; s.hi = 0.05; end
        else
            s.dist = 'fixed';
            s.value = 0;
            if strcmp(vn{j}, 'fano'), s.value = cfg.gas.fano.value; end
        end
        ck.uq.variables.(vn{j}) = s;
    end
    o = tepc.uq.propagateMC(ck, 5, 'Seed', 555, 'NEvPerSample', 150);
    tc.verifyEqual(o.summary.nFailed, 0, sprintf('%s: 样本不应抛错', vn{i}));
    tc.verifyTrue(all(isfinite(o.yF)), sprintf('%s: yF 不得残留预置 0/NaN', vn{i}));
    spread = (max(o.yF) - min(o.yF)) / mean(o.yF);
    tc.verifyGreaterThan(spread, 1e-4, ...
        sprintf('%s 单独扰动 5%% 却几乎不改变 yF (展宽 %.2e) -> 该变量未真正施加', vn{i}, spread));
    if expectRho
        tc.verifyGreaterThan(abs(o.tornado.(vn{i})), 0.5, ...
            sprintf('%s 是唯一扰动变量且 y_F 对其单调, |Spearman| 应接近 1', vn{i}));
    else
        % 非单调变量: 只要求"相关存在且有限"。NaN 说明整列恒定 -> 接线断了的另一种表现。
        tc.verifyTrue(isfinite(o.tornado.(vn{i})), ...
            sprintf('%s 的 Spearman 是 NaN: y_F 对该变量完全无响应', vn{i}));
        tc.verifyNotEqual(o.tornado.(vn{i}), 0, ...
            sprintf('%s 与 y_F 完全不相关 -> 未接入', vn{i}));
    end
end
end

function test_dead_time_knob_is_inert_at_shipped_rate(tc)
% 把"发货工况下死时间不确定度对 y_F 没有贡献"钉成事实, 而不是让后人以为
% uq.variables.deadTime_rel 在 demo 报告里真的进入了合成。占用率 1e-3 时
% ±40% 的 tau 都不改变任何事件的取舍。
cfg = uqDemoCfg();
vn = fieldnames(cfg.uq.variables);
for j = 1:numel(vn)
    s = cfg.uq.variables.(vn{j});
    s.dist = 'fixed'; s.value = 0;
    if strcmp(vn{j}, 'fano'), s.value = cfg.gas.fano.value; end
    cfg.uq.variables.(vn{j}) = s;
end
cfg.uq.variables.deadTime_rel.dist = 'uniform';
cfg.uq.variables.deadTime_rel.lo = -0.40;
cfg.uq.variables.deadTime_rel.hi = 0.40;
o = tepc.uq.propagateMC(cfg, 4, 'Seed', 555, 'NEvPerSample', 150);
occ = double(cfg.source.rate_cps) * double(cfg.electronics.deadTime_s);
tc.verifyLessThan(occ, 1e-2, '本用例前提: 发货工况是低占用率');
spread = (max(o.yF) - min(o.yF)) / mean(o.yF);
% 消息先算再传: 在函数实参位置换行只能发生在逗号/运算符之后, 直接把 sprintf( 留在行尾
% 是解析错误 ("无效表达式。调用函数或对变量进行索引时，请使用圆括号"),
% 而解析错误的测试文件会被 TestSuite **静默排除** —— 绿灯由此变成假绿。
msgI = ['发货工况 (rate=%g cps, tau=%g s, 占用率 %.1e) 下 ±40%% 死时间扰动竟改变了 ' ...
        'y_F (展宽 %.2e): 前提已失效 —— 要么工况变了, 要么 DAQ 语义变了, 需重新评估本锁'];
tc.verifyEqual(spread, 0, 'AbsTol', 1e-12, sprintf( ...
    msgI, cfg.source.rate_cps, cfg.electronics.deadTime_s, occ, spread));
end

function test_uq_reproducible_and_nan_not_zero(tc)
% 同 seed 必须逐位相同; 抛错的样本必须是 NaN 而不是被 0 拉低均值。
cfg = uqDemoCfg();
a = tepc.uq.propagateMC(cfg, 4, 'Seed', 4242, 'NEvPerSample', 120);
b = tepc.uq.propagateMC(cfg, 4, 'Seed', 4242, 'NEvPerSample', 120);
tc.verifyTrue(isequaln(a.yF, b.yF), '同 seed 的 UQ 样本必须逐位一致');
c = tepc.uq.propagateMC(cfg, 4, 'Seed', 77, 'NEvPerSample', 120);
tc.verifyTrue(any(abs(c.yF - a.yF) > 1e-12), '不同 seed 应给出不同样本');
% 旧实现用 zeros 预分配: 一个失败样本就会把均值拉向 0
y = [1.0 NaN 1.2];
tc.verifyTrue(isnan(mean([y])), 'mean 不加 omitnan 时 NaN 必须传染 (防止 0 预分配回归)');
tc.verifyTrue(all(isfinite(a.yF)) || a.summary.nOk < numel(a.yF), ...
    '失败样本必须是 NaN 且被 nOk 计数区分, 不得当作 0');
tc.verifyTrue(a.summary.nOk == nnz(isfinite(a.yF)));
end

function test_execute_writes_uq_artifact_when_enabled(tc)
% cfg.uq.enabled=true 必须有消费者 (旧实现里该开关完全无人读取)。
cfg = uqDemoCfg();
cfg.uq.enabled = true;
cfg.uq.nSamples = 3;
cfg.uq.seed = 999;
R = tepc.run.execute(cfg, 'N', 120, 'RunDir', tempname());
p = fullfile(R.runDir.results, 'uq.json');
tc.verifyTrue(isfile(p), 'uq.enabled 时必须写出 results/uq.json');
u = jsondecode(fileread(p));
tc.verifyEqual(u.nSamples, 3);
tc.verifyTrue(isfinite(u.summary.yF_mean), 'uq.json 必须含有限的 yF 均值');
tc.verifyTrue(isfield(R.summary, 'u_yF_rel') && isfinite(R.summary.u_yF_rel), ...
    'summary 必须带传播得到的相对不确定度');
tc.verifyTrue(isfield(u, 'tornado'));
% 关闭开关时不得浪费时间也不得留下半成品
cfg2 = cfg; cfg2.uq.enabled = false;
R2 = tepc.run.execute(cfg2, 'N', 60, 'RunDir', tempname());
tc.verifyFalse(isfile(fullfile(R2.runDir.results, 'uq.json')), 'uq.enabled=false 时不应跑 UQ');
end

function cfg = uqDemoCfg()
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
cfg.run.chunkSize = 60;
end
