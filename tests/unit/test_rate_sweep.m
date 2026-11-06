function tests = test_rate_sweep
%TEST_RATE_SWEEP 入射率阶梯上 DAQ / 死时间 / pile-up 链的行为方向。
%   窗口一律取配置自己算出来的值: 占用(堆叠)窗 = tepc.electronics.pulseOccupancy_s(cfg),
%   死时间常数 = electronics.deadTime_s, 固定触发延迟 = filters 的 hidx*Ts。
%   手挑一对窗口只能证明"挑的数满足挑的判据", 换配置就失效, 所以这里不挑。
%
%   判据
%     (a) pile-up 计数随入射率不降 (非瘫痪型, 阶梯内)
%     (b) 活时间占比随入射率不升 (两种模式)
%     (c) 两型死时间在高率端按预期方向分开: 同一入射率下瘫痪型记到的数不多于非瘫痪型;
%         纯死时间腿 (堆叠窗缩到不可达) 上非瘫痪型观测率单调上升并停在 1/tau 以下,
%         瘫痪型观测率先升后降 (r*tau>1 进入瘫痪区, 加大源强反而记得更少);
%         换上配置给的堆叠窗后, 同一率点两型仍同向分开, 且记账只减不增
%     (d) 堆叠窗比死时间常数长 —— 短一丁点 PILEUP 分支就数学不可达 (见第 5 条用例)
%
%   阶梯取点: 单调性阶梯 r*tau ∈ [0.02, 1.2]。非瘫痪型的 pile-up 计数在 r*tau≳1 之后
%   趋于 0.2·N 的平台 (占用期外第一个到达落进 (tau,width) 带的份额不再增长), 平台段
%   相邻两点的差与统计涨落同量级, 因此"不降"只在上升段断言; 分离度阶梯
%   r*tau ∈ [0.02, 4] 只用来判 (c) 的方向, 不判 (a)。
%   统计量: 每点 1e5 个事件 (齐次 Poisson 到达), 计数相对涨落 ~0.3%, 而阶梯相邻点的
%   差在 5% 量级以上 —— 判据不是靠涨落凑出来的。
tests = functiontests(localfunctions);
end

%% ==================== 用例 ====================

function test_pileup_window_is_longer_than_dead_time(tc)
cfg = demoCfg();
w = tepc.electronics.pulseOccupancy_s(cfg);
tau = cfg.electronics.deadTime_s;
msg = sprintf(['堆叠窗 %.4g s <= 死时间 %.4g s: busy 先关闭, 落在上一脉冲内的到达 ' ...
    '都先被判 deadtime, PILEUP 分支不可达'], w, tau);
tc.verifyTrue(w > tau, msg);
alt = max([cfg.electronics.waveWindow_s, cfg.electronics.trigger.pileUpReject_s, ...
    12*cfg.electronics.shaping_s]);
tc.verifyEqual(w, alt, '堆叠窗不是几个候选里的最大值 (pulseOccupancy_s 的取法变了)');
% 上面那条在发货配置下抓不到兜底路径: waveWindow_s 存在就一定覆盖它。所以把显式配置
% 拿掉单独核兜底: 兜底窗必须等于发布出来的拖尾倍数 × 成形时间, 且随成形时间线性走 ——
% 若兜底自己另写一个倍数, 第一条红; 若它吃了别处的常数 (与 τ 无关), 第二条红。
cfgNB = cfg;
cfgNB.electronics = rmfield(cfgNB.electronics, 'waveWindow_s');
wFb = tepc.electronics.pulseOccupancy_s(cfgNB);
tc.verifyEqual(wFb, tepc.electronics.waveTailTau()*cfg.electronics.shaping_s, 'AbsTol', 0, ...
    '去掉显式 waveWindow_s 后, 占用窗的兜底不再等于发布出来的拖尾倍数 × 成形时间');
cfg2 = cfgNB;
cfg2.electronics.shaping_s = 2*cfg.electronics.shaping_s;
tc.verifyEqual(tepc.electronics.pulseOccupancy_s(cfg2), 2*wFb, 'AbsTol', 0, ...
    '成形时间翻倍而兜底占用窗没跟着翻倍: 它吃的不是同一个 τ 口径');
end

function test_pileup_count_nondecreasing(tc)
cfg = demoCfg();
S = sweep(cfg, monoRates(cfg), "nonparalyzable");
nPile = [S.nPile];
all1 = all(nPile > 0);
tc.verifyTrue(all1, sprintf('阶梯上出现 pile-up 计数为 0 的点: %s', mat2str(nPile)));
tol = -0.02 * max(1, nPile(2:end));
mono = all(diff(nPile) >= tol);
tc.verifyTrue(mono, sprintf('pile-up 计数随入射率下降: 率 %s, 计数 %s', ...
    mat2str([S.rate]), mat2str(nPile)));
tc.verifyGreaterThan(nPile(end), 3*nPile(1), sprintf(...
    '阶梯末端 pile-up 计数只比首点大 %.2f 倍: 阶梯没有真的把堆叠区扫出来', ...
    nPile(end)/max(1, nPile(1))));
ledger = all([S.nAccepted] + [S.nDead] + [S.nPile] == nEvents());
tc.verifyTrue(ledger, '原因码不穷尽 (接受+死时间+堆叠 != 事件数)');
end

function test_live_fraction_nonincreasing(tc)
cfg = demoCfg();
for mode = ["nonparalyzable", "paralyzable"]
    S = sweep(cfg, monoRates(cfg), mode);
    lf = [S.liveFrac];
    tc.verifyTrue(all(isfinite(lf) & lf > 0 & lf <= 1), ...
        sprintf('%s: liveFrac 越界 %s', mode, mat2str(lf)));
    tc.verifyTrue(all(diff(lf) <= 1e-9), sprintf('%s: 活时间占比随入射率上升: %s', ...
        mode, mat2str(lf)));
    tc.verifyGreaterThan(lf(1) - lf(end), 0.2, sprintf(...
        '%s: 阶梯两端活时间占比只差 %.3f, 判据不构成约束', mode, lf(1) - lf(end)));
end
end

function test_paralyzable_and_nonparalyzable_diverge(tc)
cfg = demoCfg();
tau = cfg.electronics.deadTime_s;
r = wideRates(cfg);
% (i) 死时间-only 腿 (占用窗缩到 pileup 不可达): 教科书写法在这里判, 两条率律干净可比
A0 = sweep(cfg, r, "nonparalyzable", tau/1000);
B0 = sweep(cfg, r, "paralyzable", tau/1000);
mN = [A0.nAccepted] ./ [A0.span_s];
mP = [B0.nAccepted] ./ [B0.span_s];
relLow = abs(mP(1) - mN(1))/r(1);
tc.verifyLessThan(relLow, 0.03, sprintf('低率端两型不重合: 相对差 %.4f', relLow));
tc.verifyTrue(all(diff(mN) > 0), sprintf('非瘫痪型观测率不单调: %s', mat2str(mN)));
tc.verifyLessThan(mN(end), 1/tau, sprintf('非瘫痪型观测率越过饱和值 1/tau=%.4g', 1/tau));
[~, ipk] = max(mP);
tc.verifyTrue(ipk > 1 && ipk < numel(r), sprintf(...
    '瘫痪型观测率峰值不在阶梯内部 (第 %d 点): 没有进入瘫痪区', ipk));
tc.verifyLessThan(mP(end), 0.8*mP(ipk), sprintf(...
    '加大源强后瘫痪型没少记: 峰值 %.4g -> 末端 %.4g', mP(ipk), mP(end)));
tc.verifyGreaterThan(mN(end), 1.3*mP(end), sprintf(...
    '高率端两型没分开: 非瘫痪 %.4g /s, 瘫痪 %.4g /s (r*tau=%.2f)', ...
    mN(end), mP(end), r(end)*tau));
% (ii) 换上配置给的占用窗 (pileup 分支打开): 同一率点两型仍按同方向分开, 且记账更少
A1 = sweep(cfg, r, "nonparalyzable");
B1 = sweep(cfg, r, "paralyzable");
mN1 = [A1.nAccepted] ./ [A1.span_s];
mP1 = [B1.nAccepted] ./ [B1.span_s];
tc.verifyGreaterThan(mN1(end), 1.3*mP1(end), sprintf(...
    '带堆叠窗的高率端两型没分开: 非瘫痪 %.4g /s, 瘫痪 %.4g /s', mN1(end), mP1(end)));
tc.verifyTrue(all(mN1 <= mN*1.005), sprintf(...
    '打开堆叠窗后非瘫痪型反而多记: %s vs %s', mat2str(mN1), mat2str(mN)));
tc.verifyLessThan(mN1(end), 0.95*mN(end), sprintf(...
    '堆叠窗在最率端没吃掉任何可记事件: %.4g vs %.4g', mN1(end), mN(end)));
% 实测事实 (不作判据, 只写在这里): 占用窗打开后非瘫痪型的观测率也会掉头 ——
% r*tau 从 1 到 4 时观测量从 ~4.4e4 落到 ~3.6e4/s。经典"非瘫痪型单调趋近 1/tau"
% 只在没有堆叠判据时成立; 堆叠判据把占用期从 tau 拉长到 width, 饱和值随之降低。
end

function test_daq_windows_ordered_as_declared(tc)
% 机理核对: 同一对 (tau, width) 下, 间隔 <tau 判 deadtime、tau<间隔<width 判 pileup、
% >width 重新接受。把 tau 与 width 用反 (或把占用窗缩到 <=tau) 会立刻在这里红。
cfg = demoCfg();
tau = cfg.electronics.deadTime_s;
w = tepc.electronics.pulseOccupancy_s(cfg);
c = tepc.electronics.filters(cfg);
lat = c.hidx * c.Ts;
o1 = tepc.electronics.daq([0; 0.5*tau], lat, w, tau, "nonparalyzable");
tc.verifyEqual(string(o1.reason)', ["accepted","deadtime"], '死时间内的第二事件应判 deadtime');
gap2 = 1.05*tau;
o2 = tepc.electronics.daq([0; gap2], lat, w, tau, "nonparalyzable");
tc.verifyEqual(string(o2.reason)', ["accepted","pileup"], sprintf(...
    '落在 (tau, width)=(%.3g, %.3g) 带内的第二事件应判 pileup', tau, w));
o3 = tepc.electronics.daq([0; w + 0.05*tau], lat, w, tau, "nonparalyzable");
tc.verifyEqual(string(o3.reason)', ["accepted","accepted"], '超出占用窗之后必须重新布防');
end

function test_pileup_channel_dies_if_window_equals_dead_time(tc)
% 反例: 占用窗缩成 tau (deadTime.m 的旧映射就是这样) 时 PILEUP 恒 0 ——
% "堆叠脉冲"整条决策链静默变成死代码。这条用例锁住"窗口取大者"这个设计的必要性。
cfg = demoCfg();
tau = cfg.electronics.deadTime_s;
t = (0:9)' * 1.05 * tau;
withBand = tepc.electronics.daq(t, 0, tepc.electronics.pulseOccupancy_s(cfg), tau, "nonparalyzable");
withWidth = tepc.electronics.daq(t, 0, tau, tau, "nonparalyzable");
tc.verifyGreaterThan(withBand.nPile, 0, sprintf('配置窗口下都没触发 pileup: %s', ...
    strjoin(withBand.reason', " ")));
tc.verifyEqual(withWidth.nPile, 0, 'width=tau 时 pileup 分支不可能到达 (busy 先关闭)');
d = tepc.electronics.deadTime(t, tau, "nonparalyzable");
tc.verifyEqual(d.nPile, 0, 'deadTime 薄壳自己不带占用窗 (它按 width=tau 委托 daq)');
tc.verifyEqual(double(d.accepted), double(withWidth.accepted), ...
    'deadTime 薄壳与它委托的 daq 判定不一致');
end

%% ==================== 助手 (首参不是 tc) ====================

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function n = nEvents()
n = 1e5;
end

function r = monoRates(cfg)
% r*tau = 0.02, 0.05, 0.1, 0.2, 0.4, 0.7, 1.2 (非瘫痪型 pile-up 计数的上升段)
r = [0.02 0.05 0.1 0.2 0.4 0.7 1.2] / cfg.electronics.deadTime_s;
end

function r = wideRates(cfg)
% 分离度阶梯: 末端进瘫痪区 (瘫痪型观测率峰值在 r*tau=1/ln2≈1.44, 之后回落)
r = [0.02 0.1 0.5 1.0 1.44 2.5 4.0] / cfg.electronics.deadTime_s;
end

function S = sweep(cfg, rates, mode, width)
% 每个入射率一条独立的齐次 Poisson 到达序列 (固定 seed => 阶梯各点只差率这一个变量),
% 送进 DAQ 状态机, 返回计数 / 活时间占比 / 观察跨度。
%   width 缺省取 pulseOccupancy_s(cfg) (生产占用窗); 传 tau/1000 则堆叠分支不可达,
%   得到"只有死时间"的那条对照腿。
tau = cfg.electronics.deadTime_s;
if nargin < 4 || isempty(width)
    width = tepc.electronics.pulseOccupancy_s(cfg);
end
c = tepc.electronics.filters(cfg);
lat = c.hidx * c.Ts;                      % 固定触发延迟: 与成形峰位置同源
n = nEvents();
S = struct('rate', {}, 'nPile', {}, 'nDead', {}, 'nAccepted', {}, ...
    'liveFrac', {}, 'span_s', {});
for i = 1:numel(rates)
    rs = RandStream('Threefry', 'Seed', 90210);
    t = cumsum(exprndAux(1/rates(i), n, rs));     % 间隔 iid 指数 => 齐次 Poisson 过程
    o = tepc.electronics.daq(t, lat, width, tau, mode);
    S(end+1) = struct('rate', rates(i), 'nPile', o.nPile, 'nDead', o.nDead, ...
        'nAccepted', o.nAccepted, 'liveFrac', o.liveFrac, 'span_s', o.span_s); %#ok<AGROW>
end
end

function e = exprndAux(mu, n, rs)
% 指数到达间隔 (rand 流上的逆变换, 不用工具箱): 间隔 iid 指数 => 齐次 Poisson 过程。
u = 1 - rand(rs, n, 1);
e = -mu * log(u);
end
