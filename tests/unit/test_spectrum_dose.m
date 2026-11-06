function tests = test_spectrum_dose
%TEST_SPECTRUM_DOSE 带权谱/剂量链/品质因子/死时间。
%   谱侧锁定的是可审计性: f 归一含区间外份额, d 以"精确矩"归一 (于是 int d dy != 1,
%   其偏离即分箱误差), 末闭区间不得重复计入 overflow, nEff 分子分母同一事件群。
%   剂量链锁定的是物理: A 链用真值沉积, B 链用仪器反演授予能 -> 两链不再是代数恒等式。
tests = functiontests(localfunctions);
end

function test_normalization_and_moments(tc)
rng(1);
eps_ = 0.2 + 9.8*rand(200000,1); w = ones(200000,1);   % 均值 5.1 keV
S = tepc.analysis.buildSpectrum(eps_, 1.0, w, logspace(log10(0.01), log10(100), 121));
yv = eps_;                                              % lbar = 1 um -> y = eps
tc.verifyLessThan(abs(S.intFdy - 1.0), 1e-12, '无区间外丢失时 int f dy = 1');
tc.verifyLessThan(abs(S.yF_exact - 5.1), 0.01);
tc.verifyLessThan(abs(S.yD_exact - sum(yv.^2)/sum(yv)), 1e-9);
tc.verifyLessThan(abs(S.yF_binned - S.yF_exact)/S.yF_exact, 0.02);
% d(y) 以精确矩归一 => int d dy = yF_binned/yF_exact, 偏离 1 的幅度即分箱误差
tc.verifyLessThan(abs(S.intDdy - S.yF_binned/S.yF_exact), 1e-12, ...
    'int d dy 必须等于 yF_binned/yF_exact (yF_exact 归一的直接推论)');
tc.verifyGreaterThan(abs(S.intDdy - 1), 1e-9, ...
    '分箱谱用精确矩归一后 int d dy 不得恒等于 1 (恒等意味着又回到自洽核对)');
tc.verifyLessThan(abs(S.intDdy - 1), 0.05, '分箱误差本身必须是小量');
tc.verifyEqual(S.zeroDepCount, 0);
tc.verifyEqual(S.nEvents, numel(eps_));
end

function test_weight_accounting(tc)
rng(2); eps_ = 0.02 + 10*rand(100000,1); w = rand(100000,1) + 0.1;   % 严格为正
edges = logspace(log10(0.01), log10(100), 121);
S = tepc.analysis.buildSpectrum(eps_, 16.9333, w, edges);
lost = (S.underflowWeight + S.overflowWeight)/sum(w);
tc.verifyLessThan(abs(S.intFdy - (1-lost)), 1e-12, '丢失份额必须可审计');
tc.verifyGreaterThan(S.underflowWeight, 0, '本例必有 y 低于首边界的份额');
tc.verifyEqual(S.overflowWeight, 0, 'AbsTol', 1e-12);
% nEff: 分子与分母必须取同一事件群 (入域且权重>0)
yv = eps_/16.9333;
okv = isfinite(yv) & yv > 0 & isfinite(w) & w > 0 & ~(eps_ == 0);
ref = sum(w(okv))^2/sum(w(okv).^2);
tc.verifyEqual(S.nEff, ref, 'AbsTol', 1e-6);
% 加入一个零沉积事件: 有效样本数不得改变 (过去分子分母取自不同事件群时会变)
S2 = tepc.analysis.buildSpectrum([eps_; 0], 16.9333, [w; 1], edges);
tc.verifyEqual(S2.nEff, S.nEff, 'AbsTol', 1e-6);
% --- 仪器方差拆分与上面共用同一条不变量: 分子分母必须取同一事件群 ---
% 配对口径只在 weight>0 上做, 所以 nPaired 与 nEvents 必须分开出参且这里必须真的不等
w2 = w;  w2(1:7) = 0;
% 零沉积那几条: 权重仍 >0、测量值仍有限, 但产出 v 的两条谱本来就不收它们 (buildSpectrum 要 y>0),
% 所以配对那一路也必须剔掉, 否则 addedPaired 与 v 的分母不是同一个事件群。
t2 = eps_;  t2([9 10 11]) = 0;
evSplit = struct('EdepGas_keV', t2, 'epsilon_meas_keV', eps_ + 0.05*eps_.*randn(size(eps_)), ...
    'weight', w2);
o = tepc.analysis.instrumentVarianceSplit(evSplit, 0.11, 0.4, 8);
tc.verifyEqual(o.nEvents, numel(eps_));
tc.verifyEqual(o.nPaired, numel(eps_) - 10, sprintf( ...
    '7 条零权重与 3 条零沉积必须一起排除 (nPaired=%d): 少了 t>0 就与谱那一路不同群', ...
    o.nPaired));
tc.verifyLessThan(o.nPaired, o.nEvents);
% 恒等式 var(m) = var(t) + var(m-t) + 2cov(t, m-t) 走两条独立求和, 必须对得上
scale = max([abs(o.addedVarDiff), abs(o.addedPaired), abs(o.covPaired), eps]);
tc.verifyLessThan(abs(o.covCross), 1e-11*scale, sprintf( ...
    '两条 2cov 算法差 %.3e: 权重或单位有一处错', o.covCross));
tc.verifyEqual(o.sigmaM2, 0.11, 'AbsTol', 0);
tc.verifyEqual(o.addedSpectrum, 0.11*(1 + 0.4), 'AbsTol', 0, ...
    '核代数那一路必须是 v*(1+cv2Truth), 不许从谱重算');
tc.verifyEqual(o.avalancheShare, 1/8, 'AbsTol', 0);
% v 缺位是正常状态 (未走仪器链的运行不发布那个字段): 必须给 NaN 而不是抛错。
% 旧条件 ~(sigmaM2 >= 0) 在 NaN 下为真, 会抛"出现负方差"这种误导错误。
o2 = tepc.analysis.instrumentVarianceSplit(evSplit, NaN, 0.4, 8);
tc.verifyTrue(isnan(o2.sigmaM2), 'v 缺位时 sigmaM2 必须是 NaN 而不是 0 或假数');
tc.verifyTrue(isnan(o2.kernelCoverage));
tc.verifyTrue(contains(o2.coverageFlag, 'not-evaluated'), sprintf( ...
    '缺位要留下可读的旗标, 实际是 "%s"', o2.coverageFlag));
tc.verifyGreaterThan(o2.addedPaired, 0, 'v 缺位不影响配对那一路照常算出');
% 早退路径的出参完整性: 配对数不足 (全零真沉积) 也必须给齐**所有**文档里的字段。
% 这条锁的来源是真回归 —— N=40 的小样本走到 insufficient-pairs 一支, 旧实现没写 covTerm,
% 生产路径按名读它就抛 nonExistentField, 把两个"字段必须带到 summary"的用例一起打红。
evZero = struct('EdepGas_keV', zeros(5, 1), 'epsilon_meas_keV', ones(5, 1), 'weight', ones(5, 1));
o3 = tepc.analysis.instrumentVarianceSplit(evZero, 0.11, 0.4, 8);
needF = {'sigmaM2', 'addedSpectrum', 'addedPaired', 'addedVarDiff', 'covPaired', ...
    'covTerm', 'avalancheShare', 'kernelCoverage', 'coverageFlag', 'nPaired', 'nEvents'};
missF = needF(~isfield(o3, needF));
tc.verifyEqual(o3.nPaired, 0, '全零真沉积不该进配对');
tc.verifyEmpty(string(missF), sprintf('早退路径缺出参字段: %s', strjoin(string(missF), ', ')));
tc.verifyEqual(o3.nEvents, 5);
tc.verifyEqual(S2.zeroDepCount, 1);
tc.verifyEqual(S2.nEvents, S.nEvents + 1);
tc.verifyLessThan(S2.SW_valid, sum(w) + 1, '零沉积事件不得进入归一分母');
end

function test_last_bin_is_not_double_counted(tc)
% histcounts 末区间为闭: y == edges(end) 的事件既入 bin 又不算 overflow
edges = [0.1 1 10];
eps_ = [0.5; 5; 10]; w = [1; 2; 3];
S = tepc.analysis.buildSpectrum(eps_, 1.0, w, edges);
tc.verifyEqual(S.overflowWeight, 0, 'AbsTol', 1e-12);
tc.verifyEqual(sum(S.sum_w), sum(w), 'AbsTol', 1e-12);
tc.verifyEqual(S.counts_raw(2), 2, '末边界事件应计入最后一 bin');
tc.verifyEqual(S.underflowWeight, 0, 'AbsTol', 1e-12);
tc.verifyLessThan(abs(S.intFdy - 1), 1e-12, '无丢失时 f 必须归一 (不因重复计数而偏离)');
S3 = tepc.analysis.buildSpectrum([eps_; 10.5], 1.0, [w; 4], edges);
tc.verifyEqual(S3.overflowWeight, 4, 'AbsTol', 1e-12);
tc.verifyEqual(S3.overflowY, 4*10.5, 'AbsTol', 1e-9);
end

function test_negative_weight_and_bad_input_rejected(tc)
tc.verifyError(@() tepc.analysis.buildSpectrum([1;2], 1.0, [1;-1], [0.1 1 10]), ...
    'tepc:spectrum:NegativeWeight');
tc.verifyError(@() tepc.analysis.buildSpectrum([1;NaN], 1.0, [1;1], [0.1 1 10]), ...
    'tepc:spectrum:BadEpsilon');
tc.verifyError(@() tepc.analysis.buildSpectrum([1;2], -1.0, [1;1], [0.1 1 10]), ...
    'tepc:spectrum:BadLbar');
tc.verifyError(@() tepc.analysis.buildSpectrum([1;2], 1.0, [1;1], [0.1 1 0.5]), ...
    'tepc:spectrum:BadEdges');
tc.verifyError(@() tepc.analysis.buildSpectrum([1;2], 1.0, [1], [0.1 1 10]), ...
    'tepc:spectrum:Shape');
end

function test_dose_chain_identity_and_removed_norm(tc)
% B 链两种形式恒等 (C 常数由单元测试锁定); N_norm 已删除
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
g = tepc.geometry.buildGeometry(cfg);
[rho, ~] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, cfg.gas.temperature_K, ...
    cfg.gas.composition_molfrac, 1.0);
% y 必须按"本次几何的位点平均弦长"给出: B/B' 恒等式核对的正是
%   y = eps/lbar_t  +  lbar_t = 2 d_t/3  +  m_t = rho_t*pi*d_t^3/6
% 三件事同时成立。原测试把 y 写成 eps/2um (把请求位点直径当成了 lbar),
% 于是恒等式必然差 1.5*d_t/(1.5*lbar) 这样的几何因子 (实测 0.5), 不是 src 的问题。
eps = [10;20;30]; wgt = [1;1;2];
lbarU = g.site.lbar_tissue_m*1e6;
ev = struct('EdepGas_keV', eps, 'y_keV_per_um', eps/lbarU, ...
    'weight', wgt, 'flags', [0;0;0]);
mass = rho*g.V_m3;
D = tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], struct());
tc.verifyLessThan(abs(D.D_tissue_Gy - D.D_tissue_closed_Gy)/D.D_tissue_closed_Gy, 1e-12);
tc.verifyFalse(isfield(D, 'N_norm'), 'N_norm 字段已删除 (不得复活)');
tc.verifyEqual(D.nEvents, 3);
tc.verifyEqual(D.meas_source, false, '未给 eps_meas 时 B 链数据源是真值');
tc.verifyEqual(D.D_gas_per_event_Gy, D.D_gas_Gy/3, 'RelTol', 1e-12);
tc.verifyEqual(D.D_tissue_per_event_Gy, D.D_tissue_Gy/3, 'RelTol', 1e-12);
tc.verifyEqual(D.massGas_kg, mass, 'RelTol', 1e-12);
J = 1.602176634e-16;
% 注意 [1 1 2].*[10;20;30] 是隐式展开出来的 3x3 (行和 270, 列和 [60 60 120]),
% 与 sum(w.*eps)=90 完全不是一个量 —— 参考值必须写成同向列向量的点乘。
tc.verifyEqual(D.D_gas_Gy, sum(wgt.*(eps(:)))*J/mass, 'RelTol', 1e-12);
m_t = g.site.rho_tissue*pi*g.site.d_tissue_m^3/6;
tc.verifyEqual(D.massSite_kg, m_t, 'RelTol', 1e-12);
tc.verifyGreaterThan(numel(D.norm_notes), 0);
tc.verifyFalse(any(contains(string(D.norm_notes), 'N_norm')), '说明文本不得再引用已删除字段');
end

function test_dose_chains_are_independent_data_sources(tc)
% A 链吃真值沉积, B 链吃仪器反演授予能 => 7% 刻度偏差必须原样进入 B 链而不进 A 链
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
g = tepc.geometry.buildGeometry(cfg);
[rho, ~] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, cfg.gas.temperature_K, ...
    cfg.gas.composition_molfrac, 1.0);
eps = [10;20;30]; wgt = [1;1;2];
ev = struct('EdepGas_keV', eps, 'y_keV_per_um', eps/(g.site.lbar_tissue_m*1e6), ...
    'weight', wgt, 'flags', [0;0;0]);
mass = rho*g.V_m3;
D0 = tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], struct());
D1 = tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('eps_meas_keV', ev.EdepGas_keV*1.07));
tc.verifyEqual(D1.meas_source, true);
tc.verifyLessThan(abs(D1.D_tissue_Gy/D0.D_tissue_Gy - 1.07), 1e-12);
tc.verifyEqual(D1.D_gas_Gy, D0.D_gas_Gy, 'RelTol', 1e-12);
% B 链 (仪器量) 与 B' 闭式 (几何定义) 必须分歧 7% —— 二者不再是代数恒等式。
% 写成显式比值判据: verifyNotEqual 不接受 'AbsTol' 名值参 (实测 tooManyInputs)。
tc.verifyLessThan(abs(D0.D_tissue_Gy/D0.D_tissue_closed_Gy - 1), 1e-12, ...
    '未注入刻度偏差时 B 与 B闭 必须恒等 (几何定义核对)');
tc.verifyLessThan(abs(D1.D_tissue_Gy/D1.D_tissue_closed_Gy - 1.07), 1e-12, ...
    '注入 7% 刻度偏差后 B 链须偏离闭式 7% (数据源不同的直接后果)');
% 发布权重与内部权重分离 (死时间清零权重可单独传入)
D2 = tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('weight_pub', [1;1;0]));
tc.verifyLessThan(abs(D2.D_tissue_Gy/(D0.D_tissue_Gy) - 30/90), 1e-12);
tc.verifyEqual(D2.D_gas_Gy, D0.D_gas_Gy, 'RelTol', 1e-12, 'A 链仍用 ev.weight');
end

function test_dose_chain_input_guards(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
g = tepc.geometry.buildGeometry(cfg);
ev = struct('EdepGas_keV', [10;20], 'y_keV_per_um', [5;10], ...
    'weight', [1;1], 'flags', [0;0]);
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, 1, 1, [], ...
    struct('eps_meas_keV', [10; NaN])), 'tepc:dose:BadInput');
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, 1, 1, [], ...
    struct('eps_meas_keV', [10; -1])), 'tepc:dose:BadInput');
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, 1, 1, [], ...
    struct('eps_meas_keV', [10])), 'tepc:dose:Length');
bad = ev; bad.weight = [1;-1];
tc.verifyError(@() tepc.analysis.doseChain(bad, g, cfg, 1, 1, [], struct()), ...
    'tepc:dose:BadInput');
end

function test_quality_factor_icrp60(tc)
root = tepc.io.projectRoot();
[qf, meta] = tepc.analysis.qualityFactor(struct('version','icrp60_let_on_y'), root);
tc.verifyEqual(qf(5), 1);
tc.verifyEqual(qf(50), 0.32*50-2.2, 'AbsTol', 1e-12);
tc.verifyEqual(qf(400), 300/sqrt(400), 'AbsTol', 1e-12);
tc.verifyEqual(char(meta.approx), 'QF_APPROX_Y_AS_LET');
[qf2, m2] = tepc.analysis.qualityFactor(struct('version','table', ...
    'file','config/quality-factor/icrp60_let_on_y.csv'), root);
tc.verifyLessThan(abs(qf2(50) - qf(50)), 1e-9, '表版本与解析分段一致');
tc.verifyEqual(char(m2.approx), 'QF_FROM_TABLE');
[qf3, ~] = tepc.analysis.qualityFactor(struct('version','none'), root);
tc.verifyTrue(isnan(qf3(10)), '未配置时 Q=NA');
end

function test_dead_time_laws(tc)
rs = RandStream('Threefry','Seed',5);
tau = 1e-5;
for rTrue = [1e3, 5e4]
    N = 200000; t = cumsum(-log(rand(rs,N,1)))/rTrue; Tobs = t(end);
    dnp = tepc.electronics.deadTime(t, tau, "nonparalyzable");
    tc.verifyLessThan(abs(dnp.nAccepted/Tobs - rTrue/(1+rTrue*tau))/(rTrue/(1+rTrue*tau)), 0.05);
    dp = tepc.electronics.deadTime(t, tau, "paralyzable");
    tc.verifyLessThan(abs(dp.nAccepted/Tobs - rTrue*exp(-rTrue*tau))/(rTrue*exp(-rTrue*tau)), 0.05);
    tc.verifyEqual(dnp.busyTotal_s, tau*dnp.nAccepted, 'RelTol', 1e-12);
    tc.verifyEqual(dnp.nAccepted + dnp.nRejected, N);
    % ---------------- 活时间对表 ----------------
    % 非瘫痪型: 只有触发 DAQ 的事件占用, 且接受事件间隔 >= tau => 占用不重叠,
    %           liveFrac -> 1 - tau*m = 1/(1+r*tau)。
    tc.verifyEqual(dnp.liveFrac, 1/(1+rTrue*tau), 'RelTol', 0.05, sprintf( ...
        '非瘫痪活时间占比 %.4f 与解析值 1/(1+r*tau)=%.4f 不符', dnp.liveFrac, 1/(1+rTrue*tau)));
    % 瘫痪型: **任意**到达都把 busy 重启到 t+tau => 占用 = 全部到达的区间并集
    %         = 一维布尔覆盖, 未覆盖比例 -> exp(-r*tau) (即 liveFrac = m/r)。
    tc.verifyEqual(dp.liveFrac, exp(-rTrue*tau), 'RelTol', 0.05, sprintf( ...
        '瘫痪活时间占比 %.4f 与布尔覆盖真值 exp(-r*tau)=%.4f 不符', dp.liveFrac, exp(-rTrue*tau)));
    % 判别力来源 (为什么必须跑 r*tau=0.5 这一端): 旧实现 deadTime.m:55 的
    % "liveFrac = 1 - tau*nAccepted/span" 同一个式子在 r*tau=0.5 处给
    %   1 - tau*r*exp(-r*tau) = 1 - 0.5*0.606531 = 0.696735
    % 而真值是 exp(-0.5) = 0.606531 (独立栅格 MC 复核 0.607450) —— 相对高估 14.9%,
    % 5% 容差下必红; r*tau=0.01 处两式只差 0.01%, 低计数率端没有判别力。
    % 占用口径本身也被改掉: busyTotal_s 恒等于 tau*nAccepted (旧语义保留),
    % 瘫痪型的真实占用是所有事件的区间并集, 必然更大。
    tc.verifyGreaterThan(dp.occupied_s, dp.busyTotal_s, sprintf( ...
        'paralyzable 占用必须包含被拒事件重启的 busy: occupied=%.6g busyTotal=%.6g', ...
        dp.occupied_s, dp.busyTotal_s));
    tc.verifyTrue(isfinite(dnp.liveTime_s) && isfinite(dp.liveTime_s), sprintf( ...
        '不带 carry 的单次调用活时间必须是有限值 (旧实现 span 起点取 -Inf => Inf)'));
    tc.verifyEqual(dp.liveTime_s + dp.occupied_s, dp.span_s, 'RelTol', 1e-12, ...
        '活时间 + 占用 = 观察跨度 (daq 的窗定义)');
end
end

function test_dead_time_order_semantics(tc)
% accepted 按"排序后"顺序给出, order 供调用方映射回原始事件
o = tepc.electronics.deadTime([0.3; 0.0; 0.05], 0.1, "nonparalyzable");
tc.verifyEqual(o.order, [2; 3; 1]);
tc.verifyEqual(o.accepted, [true; false; true]);
tc.verifyEqual(o.nAccepted, 2);
mask = false(3,1); mask(o.order) = o.accepted;
tc.verifyEqual(mask, [true; true; false]);
p = tepc.electronics.deadTime([0.3; 0.0; 0.05], 0.1, "paralyzable");
tc.verifyEqual(p.accepted, [true; false; true], 'paralyzable: 每个事件都重启 busy');
% 判据确实来自 daq (壳层里没有第二套 busy 递推): 同一串到达直接喂
% daq(lat=0, width=tau, tau, mode) 必须给出同一张接受掩码。
% 若有人把死时间判据又写回 deadTime (例如把 width 传成 0 或把 busy 判据改成 >),
% 这张掩码就会分叉 -> 本断言红。
dq = tepc.electronics.daq([0.3; 0.0; 0.05], 0, 0.1, 0.1, "nonparalyzable");
tc.verifyEqual(mask(:), dq.accepted(:), '死时间接受判据必须与 daq 逐事件一致');
tc.verifyEqual(dq.nPile, 0, 'width=tau 时 pile-up 分支不可达 (本函数不建模堆积)');
end

function test_dead_time_cross_block_consistency(tc)
% 跨块携带 busyUntil: 高计数率序列分块处理必须与一次性处理给出同一接受集合
rs = RandStream('Threefry','Seed',77);
% 高计数率: 平均间隔 1e-7 s << tau=1e-5 -> 块边界几乎必然落在 busy 期内
tau = 1e-5; rTrue = 1e7; N = 40000;
t = cumsum(-log(rand(rs,N,1)))/rTrue;
for mode = ["nonparalyzable", "paralyzable"]
    ref = tepc.electronics.deadTime(t, tau, mode);
    % 整段一次调用的活时间也要能对上独立 oracle (旧实现在这里返回 Inf)
    [w0, w1, liveRef] = liveOracle(t, ref.accepted, tau, mode);
    tc.verifyTrue(isfinite(ref.liveTime_s), sprintf( ...
        '%s: 不带 carry 的 liveTime_s 必须有限 (旧实现 max(t(end)-(-Inf),0)-... = Inf)', mode));
    if isfinite(liveRef)
        tc.verifyEqual(ref.liveTime_s, liveRef, 'RelTol', 1e-6, sprintf( ...
            '%s: liveTime_s 必须等于 daq 的区间并集结果 (扫描线 oracle)', mode));
        tc.verifyEqual(ref.liveFrac, liveRef/(w1-w0), 'RelTol', 1e-6);
    else
        tc.verifyEqual(ref.liveTime_s, 0); tc.verifyTrue(isnan(ref.liveFrac));
    end
    for frac = [0.07 0.5 0.99]
        i1 = max(1, round(frac*N));
        b1 = tepc.electronics.deadTime(t(1:i1), tau, mode);
        b2 = tepc.electronics.deadTime(t(i1+1:end), tau, mode, b1.busyUntilEnd);
        tc.verifyEqual([b1.accepted; b2.accepted], ref.accepted, ...
            sprintf('%s 在分割点 %d 处接受集合必须与整段一致', mode, i1));
        tc.verifyEqual(b1.nAccepted + b2.nAccepted, ref.nAccepted);
        tc.verifyTrue(isfinite(b2.busyUntilEnd));
        tc.verifyTrue(isfinite(b2.liveTime_s), '携带 busy 起点后有效开启时间必须有限');
        % 旧断言 liveTime_s = (t(end)-b1.busyUntilEnd) - tau*nAccepted 是**错的**,
        % 已按 daq 的区间并集定义改写 (上面两行是独立 oracle 复核):
        %   (1) paralyzable 下它只扣"被接受"事件的 tau, 漏掉了被拒事件重启的 busy。
        %       本用例 r*tau=100、frac=0.07 那一刀: b2 有 37200 个事件、**0** 个接受,
        %       旧式给出 liveTime_s = 3.7018e-3 s (整块全算成活的), 而真值 =
        %       span*exp(-100) ~ 1e-47 s -> daq 语义下该块无接受事件 => 0 (实测新值 0)。
        %   (2) 即便在 nonparalyzable (占用互不重叠, 扣项 tau*nAccepted 本身正确) 下
        %       窗口也不对: 它把起点取在上块的 busyUntilEnd (多算了块首那段本来就活的
        %       时间), 又不裁掉末事件越过 t(end) 的占用。实测差值
        %       frac=0.07/+7.557e-06, frac=0.5/+7.572e-06, frac=0.99/+7.596e-06
        %       (新-旧, 相对新值 23%~29%), 且 frac=0.99 时旧式给出 **负** 活时间
        %       -7.2168e-06 s —— 活时间不可能为负。
        [w0b, w1b, liveB] = liveOracle(t(i1+1:end), b2.accepted, tau, mode);
        if isfinite(liveB)
            tc.verifyEqual(b2.liveTime_s, liveB, 'RelTol', 1e-6, sprintf( ...
                '%s frac=%.2f: 块内活时间必须等于区间并集结果', mode, frac));
            tc.verifyEqual(b2.liveFrac, liveB/(w1b-w0b), 'RelTol', 1e-6);
        else
            tc.verifyEqual(b2.liveTime_s, 0, sprintf( ...
                '%s frac=%.2f: 块内无接受事件 -> 窗无定义, daq 约定 liveTime_s=0', mode, frac));
            tc.verifyTrue(isnan(b2.liveFrac));
        end
    end
    % 不携带 busy 的旧做法到底错在哪: 实测 (seed=77, rTrue*tau=100) 非堆积型下
    % 朴素分块的接受**计数**与整段完全相等 (396 vs 396) —— 边界多收 1 个, 之后
    % 相位错开又少收 1 个。所以"计数更大"不是普适判据 (原断言因此是伪命题);
    % 真正的判据是边界那一个事件被"重新开放死时间"错误收下 => 接受集合不一致。
    i1 = N/2;
    b1 = tepc.electronics.deadTime(t(1:i1), tau, mode);
    b2 = tepc.electronics.deadTime(t(i1+1:end), tau, mode);
    tc.verifyTrue(t(i1+1) < b1.busyUntilEnd, '前提: 分割点必须落在块 1 的 busy 期内');
    tc.verifyFalse(ref.accepted(i1+1), '整段处理必须拒绝该事件 (仍在死时间内)');
    tc.verifyTrue(b2.accepted(1), '不携带 busy 的朴素分块会收下该事件');
    tc.verifyFalse(isequal([b1.accepted; b2.accepted], ref.accepted), ...
        '不携带 busy 必须改变接受集合 (分块边界重新开放死时间)');
    b2c = tepc.electronics.deadTime(t(i1+1:end), tau, mode, b1.busyUntilEnd);
    tc.verifyEqual([b1.accepted; b2c.accepted], ref.accepted, ...
        sprintf('%s: 携带 busyUntilEnd 后必须与整段逐事件一致', mode));
end
end

function test_dead_time_guards(tc)
tc.verifyError(@() tepc.electronics.deadTime([0; NaN], 1e-5, "nonparalyzable"), ...
    'tepc:deadtime:BadTime', '含 NaN 时间戳必须报错而非静默接受');
tc.verifyError(@() tepc.electronics.deadTime([0; 1], -1, "nonparalyzable"), ...
    'tepc:deadtime:BadTau');
tc.verifyError(@() tepc.electronics.deadTime([0; 1], 1e-5, "bogus"), ...
    'tepc:deadtime:BadMode');
tc.verifyError(@() tepc.electronics.deadTime([0; 1], 1e-5, "nonparalyzable", 'busy'), ...
    'tepc:deadtime:BadCarry');
end

function test_dose_line_labels_per_event_separately(tc)
% 显示层回归锁: 每事件值与累计值必须分别标注。GUI 剂量页与 workflows/run_demo 曾把
% **累计**剂量写成 "Gy/事件" —— N=10000 时读数错 4 个量级 (实测打印 1.367e+05
% Gy/事件, 而真每事件值 13.67 Gy)。现在两处共用 tepc.report.doseLine。
s = struct('D_gas_per_event_Gy', 1.47e-9, 'D_gas_Gy', 1.47e-5, ...
    'D_tissue_per_event_Gy', 13.67, 'D_tissue_Gy', 136715, 'nEvents', 1e4);
txt = tepc.report.doseLine(s);
tc.verifyTrue(contains(txt, sprintf('%.3e Gy/事件', s.D_gas_per_event_Gy)), ...
    sprintf('Gy/事件 前必须是每事件值; 实得 %s', char(txt)));
tc.verifyTrue(contains(txt, sprintf('%.3e Gy/事件', s.D_tissue_per_event_Gy)), ...
    '组织每事件值须以 Gy/事件 标注');
tc.verifyFalse(contains(txt, sprintf('%.3e Gy/事件', s.D_tissue_Gy)), ...
    '累计值不得被标成每事件');
tc.verifyTrue(contains(txt, '累计') && contains(txt, '1.470e-05'), ...
    '累计值必须显式标"累计"');
end

% ---------------- 本地 oracle (不是测试, 签名为 (tb,acc,tau,mode)) ----------------
function [w0, w1, liveExp] = liveOracle(tb, acc, tau, mode)
%LIVEORACLE 独立算一遍"活时间", 用作 deadTime/daq 的外部复核。
%   窗定义与 daq 相同: w0 = 块内首个被接受事件, w1 = 块内末事件 (二者皆为触发时刻,
%   固定延迟 0 时即到达时刻)。占用者集合:
%     nonparalyzable -> 只有被接受的事件 (被拒到达不延长 busy, 不占 DAQ);
%     paralyzable    -> **全部**到达 (每个到达都把 busy 重启到 t+tau, 都在占 DAQ)。
%   并集用"端点扫描线"求 (每个区间 +1/-1, 深度>0 的段长求和), 与 daq.m 里
%   occupancySpan 的"排序后逐区间合并"是不同算法, 因此是真正的独立复核。
%   块内没有接受事件 -> 窗无定义, daq 约定 liveTime_s=0 / liveFrac=NaN。
w0 = NaN; w1 = NaN; liveExp = NaN;
acc = logical(acc(:)); tb = double(tb(:));
if ~any(acc), return; end
w0 = tb(find(acc, 1, 'first')); w1 = tb(end); span = w1 - w0;
if ~(tau > 0), liveExp = span; return; end
if string(mode) == "paralyzable", tv = tb; else, tv = tb(acc); end
s0 = min(max(tv, w0), w1); e0 = min(max(tv + tau, w0), w1);   % 裁进窗
pt = [s0; e0]; sg = [ones(numel(s0),1); -ones(numel(e0),1)];
[ps, ord] = sort(pt, 'ascend'); depth = cumsum(sg(ord));
occ = 0;
for i = 1:numel(ps)-1
    if depth(i) > 0 && ps(i+1) > ps(i)
        occ = occ + (ps(i+1) - ps(i));
    end
end
liveExp = max(span - occ, 0);
end
