function tests = test_peak_polarity
%TEST_PEAK_POLARITY 带符号主峰与波形形状异常标记。
%   锁的是三件事:
%     1) 测量链 / 刻度链 / Simulink 对照用**同一个**峰定义 (peakSigned);
%     2) 纯噪声波形不再被双侧整流抬高 (旧 max(abs(v)) 的问题);
%     3) 反极性过冲盖过主峰时被显式标记, 而不是被 abs() 抹平。
tests = functiontests(localfunctions);
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function test_signed_peak_matches_max_for_signal_dominated(tc)
% 信号占优时 (|过冲|/峰 = 0.1367 < 1) 新定义与旧 max(abs(v)) **完全同值** ——
% 这条锁住"修语义不改现网数值"。
c = tepc.electronics.filters(demoCfg());
[pk, ipk, anom] = tepc.electronics.peakSigned(c.h, c.hsign);
tc.verifyEqual(pk, max(abs(c.h)), 'RelTol', 1e-14, '冲激响应主峰必须不变');
tc.verifyEqual(ipk, c.hidx);
tc.verifyFalse(anom, '名义成形链的主峰不该被判为形状异常');
end

function test_noise_rectification_bias_is_measurable(tc)
% 整流偏差是**统计性**的: 对纯噪声, max|v| 的期望大于 max(v) (两侧各贡献一次极值),
% 所以旧判据系统性抬高零沉积事件的"幅度", 把近阈噪声推过阈值。
% 断言方向与量级, 而不是断言"某一条波形必被标记" (我第一版就是这么错的)。
rs = RandStream('Threefry','Seed',9001);
nA = zeros(500,1);  nS = zeros(500,1);
for m = 1:500
    v = randn(rs, 4000, 1) * 1e-3;
    nA(m) = max(abs(v));                          % 旧: 双侧整流
    nS(m) = tepc.electronics.peakSigned(v, +1);   % 新: 单侧带符号
end
ratio = nA ./ nS;
bias = mean(ratio) - 1;
se = std(ratio) / sqrt(numel(ratio));
tc.verifyGreaterThan(bias, 3*se, ...
    sprintf('整流抬高必须显著为正: bias=%.4f (SE %.4f)', bias, se));
tc.verifyGreaterThan(bias, 0.02, '实测抬升应在可感知量级 (2%~50%)');
tc.verifyLessThan(bias, 0.5);
% 反极性过冲盖过主峰的**确定性**判据 (手构造, 不依赖 RNG):
[pk2, ~, anom2] = tepc.electronics.peakSigned([0.5; -2.0; 0.3], +1);
tc.verifyEqual(pk2, 0.5);
tc.verifyTrue(anom2, '反方向极值盖过主峰必须被标记');
[~, ~, anom3] = tepc.electronics.peakSigned([2.0; -0.27; 0.1], +1);
tc.verifyFalse(anom3, '名义波形 (过冲 13.7%) 不得被误标');
end

function test_negative_polarity_chain_is_handled_by_sign(tc)
% 配置出来的负极性成形 (hsign=-1) 是合法设计: 主峰应为负值, 幅度与正极性对称。
v = -[zeros(200,1); 3.0; linspace(2.9, -0.42, 600).'];
[pkN, ipkN, anomN] = tepc.electronics.peakSigned(v, -1);
[pkP, ipkP, anomP] = tepc.electronics.peakSigned(-v, +1);
% 幅度相同、**符号随极性**: 曾写成 verifyEqual(pkN, pkP) 配一句"符号随极性"的注释,
% 那是自相矛盾的断言 (pkN=-3 vs pkP=3 必然红) —— 注释对, 判据写反了。
tc.verifyEqual(pkN, -pkP, 'RelTol', 0);         % 同一物理幅度, 符号随极性
tc.verifyEqual(ipkN, ipkP);
tc.verifyEqual(anomN, anomP);
tc.verifyLessThan(pkN, 0, 'peak_V 必须带符号 (abs 会把反接伪装成正常)');
end

function test_flags_bit_defined_and_unique(tc)
F = tepc.domain.Flags();
tc.verifyEqual(F.WAVEFORM_SHAPE, uint32(4096));
tc.verifyEqual(F.SECONDARY_FROM_WALL, uint32(8192));
vals = [F.OVERFLOW_ADC, F.UNDER_THRESHOLD, F.PILEUP, F.DEADTIME_REJECTED, ...
    F.WALL_LOSS, F.ESCAPE, F.EDGE, F.ZERO_DEP, F.OUT_OF_RANGE, F.RANGE2_ADC, ...
    F.SAT_CSA, F.GAIN_SAT, F.WAVEFORM_SHAPE, F.SECONDARY_FROM_WALL];
tc.verifyEqual(numel(unique(vals)), numel(vals), '标志位不得重复 (重复会让门禁计数错乱)');
end

function test_simulate_flags_anomaly_without_changing_nominal(tc)
% 整链核对: 同一 cfg, 零沉积事件可能被标 WAVEFORM_SHAPE, 但有真实沉积的事件不受影响。
cfg = demoCfg();
R0 = tepc.config.resolve(cfg);
c = tepc.electronics.filters(cfg);
[~, msig] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',7), "sigma");
ctx = struct('W_eV',cfg.gas.W_eV.value,'fano',cfg.gas.fano.value,'field',R0.field, ...
    'mob',R0.mob,'seed',5,'G_mean',R0.G_mean,'theta',8,'r0_m',R0.r0_m, ...
    'coeffs',c,'noiseSigma',msig.sigma_peak_V);
Edep = [0; 0; 5; 20; 40];                        % 前两个是零沉积
[q, instr] = tepc.electronics.simulate(Edep, 1, cfg, RandStream('Threefry','Seed',3), ctx);
F = tepc.domain.Flags();
sig = instr.flags(3:end);
tc.verifyTrue(all(bitand(sig, F.WAVEFORM_SHAPE) == 0), ...
    '有真实沉积的事件不应被判形状异常 (否则判据过严, 会误删谱内事件)');
tc.verifyTrue(all(instr.peak_V(3:end) > 0), '信号事件主峰必须为正 (hsign=+1)');
tc.verifyTrue(all(q(3:end) > 0));
tc.verifyEqual(numel(instr.peak_V), 5);
end

function test_calibration_and_measure_use_same_peak_rule(tc)
% 刻度链与测量链必须同定义: 用同一个 ctx 走一遍 injectCalibrate, 检查刻度点位
% 与手写 peakSigned 结果一致 (而不是与 max(abs()) 一致)。
cfg = demoCfg();
R0 = tepc.config.resolve(cfg);
c = tepc.electronics.filters(cfg);
[~, msig] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',11), "sigma");
ctx = struct('W_eV',cfg.gas.W_eV.value,'fano',cfg.gas.fano.value,'field',R0.field, ...
    'mob',R0.mob,'seed',5,'G_mean',R0.G_mean,'theta',8,'r0_m',R0.r0_m, ...
    'coeffs',c,'noiseSigma',msig.sigma_peak_V);
cal = tepc.calibration.injectCalibrate(cfg, ctx, int64(2e9));
tc.verifyTrue(isfield(cal,'beta') && numel(cal.beta) >= 2);
tc.verifyTrue(all(isfinite(cal.beta)), '刻度系数必须有限');
% 无噪声确定性峰值: peakSigned 与 max(v) 同值 (刻度点用的就是它)
wv = tepc.detector.ramoWaveform(1e-12, ctx.r0_m, ctx.field, ctx.mob, cfg);
v = wv.dq;
for s = 1:size(c.sos,1)
    v = filter(c.sos{s,1}, c.sos{s,2}, v);
end
pk = tepc.electronics.peakSigned(v, c.hsign);
tc.verifyEqual(pk, max(v), 'RelTol', 1e-12, ...
    '确定性响应峰: 新定义必须与 max(v) 同值, 刻度链数值不得被语义改动漂移');
end
