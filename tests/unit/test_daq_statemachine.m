function tests = test_daq_statemachine
%TEST_DAQ_STATEMACHINE 统一 DAQ 状态机 (死时间与 pile-up 的唯一判据实现) 的回归锁。
tests = functiontests(localfunctions);
end

%% ---------------- 率律: 与解析公式对表 ----------------
function test_rate_law_nonparalyzable(tc)
% 非瘫痪型: m = r/(1+r*tau)。tau=1e-5, r=5e4 => m = 5e4/1.5 = 33333.333 /s
m = rateOf("nonparalyzable", 5e4, 1e-5);
tc.verifyEqual(m, 5e4/1.5, 'RelTol', 0.01, ...
    sprintf('非瘫痪率律偏离解析值超 1%%: m=%.1f (理论 %.1f)', m, 5e4/1.5));
end

function test_rate_law_paralyzable(tc)
% 瘫痪型: m = r*exp(-r*tau)。r=5e4, tau=1e-5 => 5e4*exp(-0.5)=30326.53
m = rateOf("paralyzable", 5e4, 1e-5);
tc.verifyEqual(m, 5e4*exp(-0.5), 'RelTol', 0.01, ...
    sprintf('瘫痪率律偏离解析值超 1%%: m=%.1f (理论 %.1f)', m, 5e4*exp(-0.5)));
end

function test_low_rate_limit_accepts_almost_everything(tc)
% r*tau = 0.01 时两条率律都应收敛到 ~r (相对差 ~1%); 这是"实现没把正常事件吃掉"的下限检查。
for mode = ["nonparalyzable","paralyzable"]
    m = rateOf(mode, 1e3, 1e-5);
    tc.verifyTrue(abs(m/1e3 - 1) < 0.05, ...
        sprintf('%s: 低率极限 m/r=%.4f 应接近 1', mode, m/1e3));
end
end

%% ---------------- pile-up: 只在脉冲比死时间长时才可能 ----------------
function test_pileup_requires_width_gt_tau(tc)
% 手算序列 (tau=10, width=30, 固定延迟 0):
%   t=0   -> accepted   (busy 到 10, 脉冲到 30)
%   t=15  -> 不在 busy  (15>=10) 但脉冲仍在 -> pileup (busy 到 25, 脉冲到 45)
%   t=26  -> busy(25) 已结束, 但 26 < 45 -> pileup (busy 到 36, 脉冲到 56)
%   t=60  -> accepted
o = tepc.electronics.daq([0;15;26;60], 0, 30, 10, "nonparalyzable");
tc.verifyEqual(string(o.reason)', ["accepted","pileup","pileup","accepted"]);
tc.verifyEqual([o.nAccepted o.nPile o.nDead], [2 2 0]);
end

function test_no_pileup_when_width_smaller_than_tau(tc)
% width<tau 时 busy 边界先打开, pileup 在数学上不可能 (上面两条率律测试依赖这一点)。
o = tepc.electronics.daq((0:9)'*1.2e-5, 0, 1e-6, 1e-5, "nonparalyzable");
tc.verifyEqual(o.nPile, 0);
tc.verifyEqual(o.nAccepted, 10);
end

%% ---------------- 分块 == 整段 ----------------
function test_chunked_equals_single_pass(tc)
% 旧实现: pile-up 每块复位 (execute.m 原 puSorted(1)=false) => 块边界漏判。
% 这里用 width>tau 让 pileup 真的会出现, 再比较"分块+携带"与"整段一次"。
rs = RandStream('Threefry','Seed',777);
t = sort(1e-6*rand(rs, 4000, 1)*10);          % 10 s 内 4000 个事件
lat = 2e-8; width = 3.4e-5; tau = 1e-5;
oneShot = tepc.electronics.daq(t, lat, width, tau, "nonparalyzable");

carry = struct();  got = strings(numel(t),1);
edges = 1:500:numel(t)+1;
for i = 1:numel(edges)-1
    seg = t(edges(i):edges(i+1)-1);
    o = tepc.electronics.daq(seg, lat, width, tau, "nonparalyzable", carry);
    got(edges(i):edges(i+1)-1) = o.reason;
    carry = struct('busyUntil', o.busyUntil, 'lastTrigEnd', o.lastTrigEnd);
end
tc.verifyEqual(got, oneShot.reason, ...
    '分块+跨块携带必须与整段逐事件一致 (旧实现块边界漏判 pileup)');
tc.verifyEqual(nnz(got=="accepted"), nnz(oneShot.reason=="accepted"));
end

function test_carry_default_reproduces_reset_behaviour(tc)
% 不带 carry 时 busyUntil/lastTrigEnd 从 -Inf 起 —— 显式锁住默认值, 防止将来
% 把默认改成 0 造成"第一块多拒收一个事件"的静默偏差。
t = [1e-6; 2e-6];
o = tepc.electronics.daq(t, 0, 1e-5, 1e-5, "nonparalyzable");
tc.verifyEqual(o.nAccepted, 1);
tc.verifyEqual(o.nDead, 1);
end

%% ---------------- 账本与健壮性 ----------------
function test_reason_codes_are_exhaustive_and_disjoint(tc)
rs = RandStream('Threefry','Seed',2024);
t = sort(1e-5*rand(rs, 1234, 1));
o = tepc.electronics.daq(t, 3e-8, 2e-5, 1e-5, "paralyzable");
tc.verifyEqual(o.nAccepted + o.nDead + o.nPile, 1234, ...
    '原因码必须互斥且穷尽 (旧实现一个事件可同时带死时间与 pileup 标志)');
tc.verifyTrue(all(o.reason ~= ""));
tc.verifyEqual(nnz(o.accepted), o.nAccepted);
end

function test_live_fraction_matches_hand_computation(tc)
% 100 个间隔 1.5e-5 s 的事件, tau=1e-5: 全部被接受且占用区间互不重叠。
% 跨度 = 99*1.5e-5 = 1.485e-3; 占用 = 前 99 个完整区间 99*1e-5 = 9.9e-4 (末区间越窗被裁)。
% 手算 liveFrac = (1.485e-3 - 9.9e-4)/1.485e-3 = 0.33333。
o = tepc.electronics.daq((0:99)'*1.5e-5, 0, 1e-6, 1e-5, "nonparalyzable");
tc.verifyEqual(o.nAccepted, 100);
tc.verifyTrue(o.liveFrac >= 0 && o.liveFrac <= 1, ...
    sprintf('liveFrac=%.4f 必须落在 [0,1]', o.liveFrac));
tc.verifyEqual(o.liveFrac, 1/3, 'AbsTol', 1e-3, ...
    sprintf('活时间占比与手算不符: 实得 %.5f (期望 0.33333)', o.liveFrac));
tc.verifyLessThan(o.liveFrac, 1, '有死时间时活时间必须小于观察跨度');
end

function test_bad_arguments_rejected(tc)
tc.verifyError(@() tepc.electronics.daq([0;1], 0, 1e-6, 0,   "nonparalyzable"), 'tepc:dq:BadTau');
tc.verifyError(@() tepc.electronics.daq([0;1], 0, 0,   1e-6, "nonparalyzable"), 'tepc:dq:BadWidth');
tc.verifyError(@() tepc.electronics.daq([0;1], -1, 1e-6, 1e-5,"nonparalyzable"), 'tepc:dq:BadLatency');
tc.verifyError(@() tepc.electronics.daq([0;1], 0, 1e-6, 1e-5, "weird"),           'tepc:dq:BadMode');
end

%% ---------------- helpers (不得以 test 开头) ----------------
function m = rateOf(mode, r, tau)
% 在 [0,T] 上按 Poisson 率 r 抽 4e5 个到达 (T = 4e5/r), 返回接受率 (接受数/T)。
% 4e5 个接受事件 => 相对统计误差 ~0.2%, 足以支撑 1% 判据。
n = 4e5;  T = n/r;
rs = RandStream('Threefry','Seed',4242);
t = sort(T*rand(rs, n, 1));
% width < tau: pileup 在数学上不可能 => 该测试只核死时间 (见上一条测试)
o = tepc.electronics.daq(t, 0, tau/1000, tau, mode);
m = o.nAccepted / T;
end
