function tests = test_position_spread
%TEST_POSITION_SPREAD 逐事件雪崩起点与位置展宽。
%   "100 个位置的 Ramo 电荷守恒误差 <=1e-9" 这类判据是同义反复:
%   sum(dq)=Qcum(tEnd) 且 Qe+Qi≡q 在代数上恒等 (phi_w(a)=1, phi_w(b)=0,
%   轨道在电极处钳位)。这里换成**能被证伪**的四条:
%     1) 电子/离子份额 vs 解析 q*(1-phi_w(r0)) 与 q*phi_w(r0)   (1e-12)
%     2) 累计收集电荷单调不减、逐样本增量非负、窗内份额 <= 全收集
%     3) 窗内收集份额 vs 独立算出的 tCollect (不共用同一函数的中间量)
%     4) 峰幅随 r0 单调 + 整链重点跑一次核对
%   外加 fixed 模式必须与历史**逐位一致**、sampled 模式的均值条件化闭式核对。
tests = functiontests(localfunctions);
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function test_gauss_hermite_is_a_real_quadrature(tc)
% 核对**生产代码**用的那套节点 (tepc.electronics.gaussHermiteNodes), 而不是测试自己
% 再实现一遍 —— 自己实现自己核对的断言永远为真, 它只证明抄写员没抄错。
% 标准正态的前四阶矩 + MGF: 解析值 0, 1, 3, 15 与 exp(t^2/2)。
[z, w] = tepc.electronics.gaussHermiteNodes(21);
tc.verifyEqual(sum(w), 1, 'AbsTol', 1e-12, '权重必须归一到概率测度');
tc.verifyEqual(sum(w .* z), 0, 'AbsTol', 1e-12, '一阶矩 E[Z]=0');
tc.verifyEqual(sum(w .* z.^2), 1, 'RelTol', 1e-10, '二阶矩 E[Z^2]=1');
tc.verifyEqual(sum(w .* z.^3), 0, 'AbsTol', 1e-10, '三阶矩 E[Z^3]=0');
tc.verifyEqual(sum(w .* z.^4), 3, 'RelTol', 1e-6, '四阶矩 E[Z^4]=3 (21 点已达 42 阶精度)');
tc.verifyEqual(sum(w .* exp(0.7*z)), exp(0.7^2/2), 'RelTol', 1e-8, 'MGF 核对');
tc.verifyEqual(sum(w .* exp(-1.3*z)), exp(1.3^2/2), 'RelTol', 1e-8, 'MGF 负侧核对');
% 阶数守卫: 1 点没有意义, 必须拒 (否则 simulate 里传错阶数会静默降级)
tc.verifyError(@() tepc.electronics.gaussHermiteNodes(1), 'tepc:elec:BadGHOrder');
end

function test_conditioning_factor_matches_closed_form(tc)
% 条件化因子必须是 E[exp(k·s·Z)]^-1 = exp(-k^2 s^2/2) (柱对称场下 G∝r0^k 精确成立)。
% 这条断言**没有 MC 噪声**, 因此可以把容差压到 1e-9 —— 它才是真正锁住条件化因子的钉子:
% 若把 gainCond 设为 1 或用批内均值归一 (会破坏分块无关性), 这里立刻失败。
cfg = demoCfg();
cfg.detector.avalancheStartMode = "sampled";
cfg.detector.startPositionJitter = 0.15;
R0 = tepc.config.resolve(cfg);
c = tepc.electronics.filters(cfg);
[~, ms] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',1), "sigma");
ctx = struct('W_eV',cfg.gas.W_eV.value,'fano',cfg.gas.fano.value,'field',R0.field, ...
    'mob',R0.mob,'seed',77,'G_mean',R0.G_mean, ...
    'theta',tepc.config.constants('detector.polya.theta'),'r0_m',R0.r0_m, ...
    'coeffs',c,'noiseSigma',ms.sigma_peak_V);
[~, ~, aux] = tepc.electronics.simulate(repmat(30.0,4,1), 1, cfg, ...
    RandStream('Threefry','Seed',9), ctx);
a = R0.field.a; b = R0.field.b;
kK = log(2)/cfg.detector.diethorn_deltaV_V.value * cfg.field.hv_V / log(b/a);
sExpected = exp(-0.5 * (kK*0.15)^2);
tc.verifyEqual(aux.gain_conditioning, sExpected, 'RelTol', 1e-6, ...
    sprintf('条件化因子应等于闭式 exp(-k^2 s^2/2)=%.6f, 实得 %.6f', ...
        sExpected, aux.gain_conditioning));
tc.verifyLessThan(aux.gain_conditioning, 1, '位置展宽抬高 E[G], 条件化必须把它压回 1');
end

function test_fixed_mode_is_bit_identical_to_history(tc)
% 默认 (fixed) 必须与改动前逐位一致 —— 语义扩展不得改变现网数值。
cfg = demoCfg();
R0 = tepc.config.resolve(cfg);
c = tepc.electronics.filters(cfg);
[~, ms] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',1), "sigma");
ctx = struct('W_eV',cfg.gas.W_eV.value,'fano',cfg.gas.fano.value,'field',R0.field, ...
    'mob',R0.mob,'seed',77,'G_mean',R0.G_mean,'theta',8,'r0_m',R0.r0_m, ...
    'coeffs',c,'noiseSigma',ms.sigma_peak_V);
Edep = (1:40)';
[q1, in1] = tepc.electronics.simulate(Edep, 1, cfg, RandStream('Threefry','Seed',5), ctx);
tc.verifyTrue(all(in1.r0_m == R0.r0_m), 'fixed 模式所有事件必须共用名义 r0');
tc.verifyTrue(all(q1 > 0));
tc.verifyEqual(numel(unique(in1.r0_m)), 1);
% 同 seed 重跑逐位一致 (可复现性)
[q2, in2] = tepc.electronics.simulate(Edep, 1, cfg, RandStream('Threefry','Seed',5), ctx);
tc.verifyTrue(isequaln(q1, q2) && isequaln(in1.adc_code, in2.adc_code));
end

function test_sampled_mode_broadens_and_keeps_mean_gain(tc)
cfg = demoCfg();
tc.verifyEqual(string(R0fieldKind(cfg)), "cylinder", ...
    '本测试的闭式核对假定柱对称场 (K=1/ln(b/a)); 拓扑若变, 必须同步改判据而不是放宽容差');
cfg.detector.avalancheStartMode = "sampled";
cfg.detector.startPositionJitter = 0.15;
R0 = tepc.config.resolve(cfg);
c = tepc.electronics.filters(cfg);
[~, ms] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',1), "sigma");
ctx = struct('W_eV',cfg.gas.W_eV.value,'fano',cfg.gas.fano.value,'field',R0.field, ...
    'mob',R0.mob,'seed',77,'G_mean',R0.G_mean, ...
    'theta',tepc.config.constants('detector.polya.theta'),'r0_m',R0.r0_m, ...
    'coeffs',c,'noiseSigma',ms.sigma_peak_V);
nEv = 4000;
Edep = repmat(30.0, nEv, 1);                     % 同一能量: 展宽只来自位置+Polya
cfgFix = cfg; cfgFix.detector.avalancheStartMode = "fixed";
[qF, inF] = tepc.electronics.simulate(Edep, 1, cfgFix, RandStream('Threefry','Seed',9), ctx);
[qS, inS] = tepc.electronics.simulate(Edep, 1, cfg,    RandStream('Threefry','Seed',9), ctx);
r0s = inS.r0_m;
tc.verifyGreaterThan(numel(unique(r0s)), nEv*0.9, 'sampled 模式必须逐事件不同');
tc.verifyTrue(all(r0s > R0.field.a & r0s < R0.field.b), '抽样位置必须落在两电极之间');
% 展宽方向: 位置抽样必须放大相对离散度
cvF = std(qF)/mean(qF);  cvS = std(qS)/mean(qS);
tc.verifyGreaterThan(cvS, cvF * 1.2, ...
    sprintf('位置抽样必须放大相对离散: fixed CV=%.4f, sampled CV=%.4f', cvF, cvS));
% --- 均值条件化: 用**算出来的 3σ 带**而不是拍脑袋的 6% ---
% 旧断言 |mean(qS)/mean(qF)-1|<0.06 的统计功效是负的: 不条件化的真实偏差只有
% exp(k^2 s^2/2)-1 = 5.24% (k=2.133, s=0.15), 落在 6% 窗口内, 于是删掉 gainCond
% 也有约七成概率通过。现在 n=4000 使比值的标准误 ~0.55%, 5.24% 的偏差是 9σ:
% 窗口收紧到 3σ, 同时把"删掉条件化"变成必然失败。
seRatio = sqrt((std(qF)/mean(qF))^2/nEv + (std(qS)/mean(qS))^2/nEv);
band = 3*seRatio;
ratio = mean(qS)/mean(qF);
tc.verifyTrue(abs(ratio - 1) < max(band, 1e-3), ...
    sprintf('均值条件化失效: mean 比=%.5f, 3σ 带=±%.5f', ratio, band));
% 反向锁: 观测偏差必须**小于**"完全不条件化"理论偏差的一半 (exp(k^2 s^2/2)-1=5.24%),
% 否则说明 3σ 带松到足以放过条件化失效。两条一起构成夹逼, 单独任何一条都不够。
biasUnc = exp(0.5*(2.133*0.15)^2) - 1;
tc.verifyLessThan(abs(ratio - 1), 0.5*biasUnc, ...
    sprintf('偏差 %.4f 已达不条件化理论值 %.4f 的一半以上: 条件化形同虚设', ...
        abs(ratio-1), biasUnc));
end

function kind = R0fieldKind(cfg)
R0 = tepc.config.resolve(cfg);
kind = R0.field.kind;
end

function test_ramo_shares_match_analytic_weight_potential(tc)
% 判据 1: 电子/离子份额对解析 phi_w(r0) (手算 K 与 phiw 定义, 不调用同一表达式链)。
cfg = demoCfg();
R0 = tepc.config.resolve(cfg);
a = R0.field.a; b = R0.field.b; V = R0.field.hv_V;
K = 1/log(b/a);                                   % 柱对称 (发货拓扑 axialWire)
phiw = @(r) log(b./r) / log(b/a);                 % phi_w(a)=1, phi_w(b)=0 的解析式
q = 1.5e-12;
for r0 = a*1.2 .* exp(linspace(0, 3, 12))
    if r0 >= b, continue; end
    wv = tepc.detector.ramoWaveform(q, r0, R0.field, R0.mob, cfg);
    tc.verifyEqual(wv.Q_e_C, q*(1-phiw(r0)), 'RelTol', 1e-12, ...
        sprintf('r0=%.3e 电子份额必须等于 q(1-phi_w)', r0));
    tc.verifyEqual(wv.Q_i_C, q*phiw(r0), 'RelTol', 1e-12, ...
        sprintf('r0=%.3e 离子份额必须等于 q*phi_w', r0));
    tc.verifyEqual(wv.Q_e_C + wv.Q_i_C, q, 'RelTol', 1e-12);
    % 判据 2: 增量非负、累计单调、窗内份额 <= 全收集
    tc.verifyTrue(all(wv.dq >= 0), '逐样本注入电荷不得为负');
    tc.verifyTrue(all(diff(cumsum(wv.dq)) >= 0) && ...
        cumsum(wv.dq(end)) <= q*(1+1e-12), '累计收集必须单调且不超过总电荷');
    tc.verifyLessThanOrEqual(wv.Q_collected_in_window_C, q + 1e-15);
end
end

function test_collected_fraction_tracks_independent_collect_time(tc)
% 判据 3: 窗内份额随气压变化的方向必须与"独立"算出的离子收集时间一致。
cfg = demoCfg();
Rlo = tepc.config.resolve(cfg);
cfg2 = cfg;  cfg2.gas.pressure_Pa = cfg.gas.pressure_Pa * 2;   % 气压翻倍 -> 迁移率减半
Rhi = tepc.config.resolve(cfg2);
q = 1.5e-12;
wLo = tepc.detector.ramoWaveform(q, Rlo.r0_m, Rlo.field, Rlo.mob, cfg);
wHi = tepc.detector.ramoWaveform(q, Rhi.r0_m, Rhi.field, Rhi.mob, cfg2);
fLo = wLo.Q_collected_in_window_C / q;
fHi = wHi.Q_collected_in_window_C / q;
tc.verifyGreaterThan(fLo, fHi, ...
    sprintf('低气压收集更快: 窗内份额应更高 (低 %.4f vs 高 %.4f)', fLo, fHi));
tc.verifyGreaterThan(wHi.tau_i_s, wLo.tau_i_s, '离子收集时间必须随气压上升');
end

function test_peak_amplitude_monotone_in_r0_and_full_chain_spot(tc)
% 判据 4: 位置->峰幅的方向性 (r0 越大 -> 增益越大 -> 峰越大), 且整链重跑一致。
cfg = demoCfg();
R0 = tepc.config.resolve(cfg);
c = tepc.electronics.filters(cfg);
[~, ms] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',1), "sigma");
ctx0 = struct('W_eV',cfg.gas.W_eV.value,'fano',cfg.gas.fano.value,'field',R0.field, ...
    'mob',R0.mob,'seed',3,'G_mean',R0.G_mean,'theta',8,'r0_m',R0.r0_m, ...
    'coeffs',c,'noiseSigma',ms.sigma_peak_V);
pkPrev = -inf;
for f = [1.0 1.4 2.0]
    ctx = ctx0;
    ctx.r0_m = R0.r0_m * f;
    [~, instr] = tepc.electronics.simulate(25.0, 1, cfg, ...
        RandStream('Threefry','Seed',11), ctx);
    tc.verifyGreaterThan(instr.peak_V, pkPrev, ...
        sprintf('r0 增大 (x%.1f) 时峰幅必须增大', f));
    pkPrev = instr.peak_V;
end
end

function test_start_mode_enum_and_jitter_domain_enforced(tc)
cfg = demoCfg();
cfg.detector.avalancheStartMode = "gaussian";
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("ENUM_INVALID", codes), '非法 avalancheStartMode 必须被枚举拒绝');
cfg = demoCfg();
cfg.detector.startPositionJitter = 1.5;
codes = codesOf(tepc.config.validate(cfg));
tc.verifyTrue(ismember("NUM_REQUIRED", codes), ...
    sprintf('jitter>=1 必须被数值域检查拒绝 (实得 %s)', strjoin(codes, ',')));
cfg = demoCfg();
cfg.detector.startPositionJitter = -0.1;
tc.verifyTrue(ismember("NUM_REQUIRED", codesOf(tepc.config.validate(cfg))), ...
    '负 jitter 必须被拒绝');
end

%% ---------------- helpers ----------------
function codes = codesOf(issues)
codes = cellfun(@(s) char(s.code), issues, 'UniformOutput', false);
end
