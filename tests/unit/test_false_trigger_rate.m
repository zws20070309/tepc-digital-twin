function tests = test_false_trigger_rate
%TEST_FALSE_TRIGGER_RATE 假符合率与精确矩电子学的三条数值契约。
%   1) 契约 6: PILEUP 必须能通过 tepc.run.execute 真的发生。发货配置里
%      trigger.pileUpReject_s = 3 µs **短于** deadTime_s = 10 µs, busy 窗总是先关闭,
%      于是任何"落在上一个脉冲内"的到达必先被判 deadtime —— PILEUP 分支在生产配置
%      下永不可达, "堆叠脉冲清零权重"整条决策就是死代码。execute 必须用脉冲占用宽度
%      (electronics.waveWindow_s = 1.2e-5 s) 作 pile-up 窗。
%      另一半是本文件真正的回归锁: 逐事件标志位向量必须与 chunkSize **无关**
%      (旧实现在每个块边界复位 pile-up 携带量 -> 块越多漏判越多)。
%   2) 契约 7: 无噪声单事件的主峰必须等于**从配置数字手推**的 ZOH 二阶节级联响应
%      主峰 (相对容差 1e-10, 不是拟合出来的经验系数), 且 t_trigger_s = argmax*Ts。
%   3) 契约 8: 触发判据必须是**极性带符号**峰, 不是 max(abs()) 双侧整流。纯噪声
%      窗口下两者相差近一倍 (对称噪声的极值来自哪一侧各 50%), 用解析可算的 iid
%      情形与生产成型噪声各自锁死。
%   随机一律锚在显式 seed -> 实测数值可复算 (不是"跑一次碰运气")。
tests = functiontests(localfunctions);
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

%% ================= 契约 6: PILEUP 可达 + 标志位与分块无关 =================
function test_pileup_reachable_and_flag_vector_chunk_invariant(tc)
c = demoCfg(); c.uq.enabled = false;
% 前提核对 (破了它下面的一切都不可能成立): pile-up 窗必须**长于**死时间 tau。
tau = c.electronics.deadTime_s;
pw = tepc.electronics.pulseOccupancy_s(c);
tc.verifyGreaterThan(pw, tau, sprintf( ...
    ['脉冲占用宽 %.3e s <= 死时间 %.3e s: PILEUP 在结构上不可达。' ...
     'execute 必须用波窗 electronics.waveWindow_s (=1.2e-5) 作 pile-up 窗, ' ...
     '不能直接吃 trigger.pileUpReject_s (=%.1e) —— 后者短于 tau'], ...
    pw, tau, c.electronics.trigger.pileUpReject_s));
% 率抬高到两类拒收都真的出现: 平均间隔 ~11 us, 落在 [tau, pw) 带内的概率约 7%
c.source.rate_cps = 9.1e4;
FL = cell(1, 2);  W = cell(1, 2);  RR = cell(1, 2);
NM = {'chunkSize=100', 'chunkSize=2000'};
CH = [100, 2000];
for i = 1:2
    [FL{i}, W{i}, RR{i}] = runChain(c, CH(i), 4001);   % 同一 seed: 两次跑的必须是同一批事件
end
F = tepc.domain.Flags();
for i = 1:2
    fl = FL{i};  w = W{i};  sm = RR{i};  nm = NM{i};
    nDead = nnz(bitand(fl, F.DEADTIME_REJECTED) > 0);
    nPile = nnz(bitand(fl, F.PILEUP) > 0);
    nAcc  = nnz(bitand(fl, bitor(F.DEADTIME_REJECTED, F.PILEUP)) == 0);
    tc.verifyGreaterThan(nPile, 0, sprintf( ...
        '%s: PILEUP 计数为 0 —— 堆叠脉冲根本没被识别', nm));
    tc.verifyGreaterThan(nDead, 0, sprintf( ...
        '%s: 该事件率下死时间一类也必须 >0, 实得 0 (判据被旁路)', nm));
    tc.verifyEqual(nDead + nPile + nAcc, numel(fl), sprintf( ...
        ['%s: 三类互斥且穷尽必须成立, 实得 dead=%d pile=%d acc=%d 合计 %d != 事件数 %d ' ...
         '(同一事件带两类标志 = 拒收被双计, 谱账本与活时间占比会互相矛盾)'], ...
        nm, nDead, nPile, nAcc, nDead + nPile + nAcc, numel(fl)));
    tc.verifyEqual(sm.summary.nEvents, numel(fl), ...
        'summary 的事件数必须与落盘行数一致');
    tc.verifyEqual(double(sm.summary.pileupCount), double(nPile), sprintf( ...
        '%s: summary.pileupCount 与 events.h5 逐事件标志回读不符 (汇总与数据各说各话)', nm));
    rej = bitand(fl, bitor(F.DEADTIME_REJECTED, F.PILEUP)) > 0;
    tc.verifyTrue(all(w(rej) == 0), sprintf( ...
        '%s: %d 个 DAQ 拒收事件里有 %d 个权重非零 —— "拒收即零权重"被破坏', ...
        nm, nnz(rej), nnz(w(rej) ~= 0)));
    fprintf('[pileup/%s] dead=%d pile=%d acc=%d n=%d zeroW=%d\n', ...
        nm, nDead, nPile, nAcc, numel(fl), nnz(w == 0));
end
% 回归锁: 逐事件标志位向量必须与 chunkSize **完全相同**。
%   改前必然失败: 旧实现在每个块边界把 pile-up 携带量复位, chunkSize=100 有 50 个
%   块边界, 于是 pile 计数比 chunkSize=2000 少一截。
tc.verifyEqual(numel(FL{1}), numel(FL{2}), '两次跑的落盘事件数必须相同');
tc.verifyTrue(isequaln(FL{1}, FL{2}), sprintf( ...
    ['chunkSize 100 与 2000 的逐事件标志位不逐位相同: 差异 %d/%d 个事件 ' ...
     '(dead %d vs %d, pile %d vs %d) —— DAQ 的 busyUntil/lastTrigEnd 没跨块携带'], ...
    nnz(FL{1} ~= FL{2}), numel(FL{1}), ...
    nnz(bitand(FL{1}, F.DEADTIME_REJECTED) > 0), nnz(bitand(FL{2}, F.DEADTIME_REJECTED) > 0), ...
    nnz(bitand(FL{1}, F.PILEUP) > 0), nnz(bitand(FL{2}, F.PILEUP) > 0)));
tc.verifyTrue(isequaln(W{1}, W{2}), ...
    '标志位相同而权重不同: 拒收->清零 的映射在块边界上不一致 (账本取决于分块)');
end

%% ================= 契约 7: 精确矩级联主峰的手推锁 =================
function test_exact_moment_cascade_peak_matches_hand_derivation(tc)
c = demoCfg();
cf = tepc.electronics.filters(c);
% --- 我从配置数字**自己**写出的 ZOH 一阶节 (与 filters.m 头部公式独立复述) ---
Ts = c.electronics.sampleTime_s;
tf = c.electronics.Rf_Ohm * c.electronics.Cf_F;
tau = c.electronics.shaping_s;
nRC = max(1, round(c.electronics.shaperOrder));
af = exp(-Ts / tf);   ad = exp(-Ts / tau);
k = af / (1 - af);
mine = {[1 / c.electronics.Cf_F], [1, -af]; [1 + k, -k], 1; [1, -1], [1, -ad]};
for i = 1:nRC
    mine(end + 1, :) = {[0, 1 - ad], [1, -ad]}; %#ok<AGROW>
end
tc.verifyEqual(size(cf.sos, 1), size(mine, 1), sprintf( ...
    '级联节数不同 (filters 给 %d, 手推 %d = 1 CSA + 1 PZ + 1 CR + %d RC)', ...
    size(cf.sos, 1), size(mine, 1), nRC));
for i = 1:min(size(cf.sos, 1), size(mine, 1))
    tc.verifyEqual(double(cf.sos{i, 1}), mine{i, 1}, 'RelTol', 1e-12, ...
        sprintf('第 %d 节分子与手推 ZOH 离散式不符', i));
    tc.verifyEqual(double(cf.sos{i, 2}), mine{i, 2}, 'RelTol', 1e-12, ...
        sprintf('第 %d 节分母与手推 ZOH 离散式不符', i));
end
% --- 已知电荷 Q 的单冲激: 级联主峰必须 = Q*hpeak, 峰位必须 = hidx ---
Q = 3.7e-15;
u = zeros(cf.Nwin, 1);  u(1) = Q;
v = u;
for i = 1:size(mine, 1)
    v = filter(mine{i, 1}, mine{i, 2}, v);
end
[pkI, ipkI] = max(cf.hsign * v);            % 手推的带符号主峰 (刻意不调用 peakSigned)
tc.verifyGreaterThan(abs(pkI), 0, '冲激响应不得恒零 (零波形上任何峰判据都是空断言)');
relI = abs(pkI / (Q * cf.hpeak) - 1);
tc.verifyLessThan(relI, 1e-10, sprintf( ...
    ['filters 报的 hpeak=%.10e 与手推级联的冲激主峰 %.10e 相对差 %.3e (容差 1e-10): ' ...
     '标定用的峰高不是同一台仪器算出来的'], cf.hpeak, pkI, relI));
tc.verifyEqual(ipkI, cf.hidx, sprintf( ...
    'filters 报的 hidx=%d 与手推响应 argmax=%d 不一致: 触发延迟 latAbs=hidx*Ts 是错的', ...
    cf.hidx, ipkI));
% --- 无噪声单事件走真实测量链: 主峰与取样时刻必须能独立复算 ---
c0 = c;
c0.electronics.noise.en_white_nV_per_rootHz = 0;
c0.electronics.noise.en_1f_amp_nV = 0;
c0.electronics.noise.in_pA_per_rootHz = 0;    % 三者全零 -> noise() 返回严格零波形
R0 = tepc.config.resolve(c0);
cf0 = tepc.electronics.filters(c0);
ctx = struct('W_eV', c0.gas.W_eV.value, 'fano', c0.gas.fano.value, 'field', R0.field, ...
    'mob', R0.mob, 'seed', 13, 'G_mean', R0.G_mean, ...
    'theta', tepc.config.constants('detector.polya.theta'), ...
    'r0_m', R0.r0_m, 'coeffs', cf0, 'noiseSigma', 0);
[q, instr] = tepc.electronics.simulate(20, 1, c0, RandStream('Threefry', 'Seed', 3), ctx);
tc.verifyGreaterThan(q(1), 0, '前提: 20 keV 沉积必须产生正电荷');
wv = tepc.detector.ramoWaveform(q(1), instr.r0_m(1), ctx.field, ctx.mob, c0);
x = wv.dq;
for i = 1:size(mine, 1)
    x = filter(mine{i, 1}, mine{i, 2}, x);    % 同一组**手推**系数, 不吃 filters() 的 sos
end
[pkE, ipkE] = max(cf0.hsign * x);
relE = abs(pkE / instr.peak_V(1) - 1);
tc.verifyLessThan(relE, 1e-10, sprintf( ...
    ['simulate 报的 peak_V=%.10e 与手推级联主峰 %.10e 相对差 %.3e (容差 1e-10)。' ...
     '可测到的坏实现: 测量链偷偷叠了噪声 (噪声旋钮没归零), 或成形用了与 filters() ' ...
     '不同的一组系数 (两条链各自为政)。'], instr.peak_V(1), pkE, relE));
tc.verifyEqual(instr.t_trigger_s(1), ipkE * cf0.Ts, 'RelTol', 1e-12, sprintf( ...
    't_trigger_s=%.6e != 手推响应 argmax(%d)*Ts=%.6e: "精确矩"的取样时刻与峰位脱钩', ...
    instr.t_trigger_s(1), ipkE, ipkE * cf0.Ts));
% 事件峰 <= q*hpeak 是**正核卷积**的不变量 (dq>=0, sum(dq)<=q): 峰高超过"全部电荷
% 一次性注入"的冲激响应在物理上不可能。比值 <1 的另一半来源是弹道亏损 (收集窗 12 µs
% 长于成形), 这里只锁不变量, 不锁比值大小。
tc.verifyLessThanOrEqual(instr.peak_V(1) / (q(1) * cf0.hpeak), 1, ...
    '事件峰高于同电荷单冲激的峰: 级联核被换了符号或 dq 面积被放大 (实得见下条打印)');
fprintf('[exact-moment] relErr(impulse)=%.3e relErr(event)=%.3e peak=%.10e ipk=%d Ts=%.2e peak/(q*hpeak)=%.4f\n', ...
    relI, relE, instr.peak_V(1), ipkE, cf0.Ts, instr.peak_V(1) / (q(1) * cf0.hpeak));
end

%% ================= 契约 8 (a): iid 噪声下的假符合率 == 解析值 =================
function test_false_trigger_rate_iid_matches_analytic(tc)
% 统计量 (刻意用**独立**样本, 这样解析值是精确的而不是界):
%   一窗 n 个样本 v ~ N(0, sigma^2), sigma 取发货配置的峰幅噪声标准差;
%   触发规则 = 生产实现 "fires 当且仅当 abs(peakSigned(v,+1)) >= thr"
%   (simulate 用 abs(pk) < thr 判 UNDER_THRESHOLD; sgn=+1 时 pk=max(v)>0, abs 是惰性的),
%   于是 P(fire) = 1 - (1 - Q(u))^n, Q(u) = 0.5*erfc(u/sqrt(2)), u = thr/sigma。
%   双侧整流 (旧实现 max(abs(v))) 的同一统计量是 1 - (1 - 2Q(u))^n ~= 2*P_signed,
%   两者在可分辨带上差 0.25 —— 远大于 MC 标准误, 所以这条断言能炸出旧实现。
%   注意: 发货阈值 thr/sigma = 16.25 -> 解析率下溢为 0, 两种规则都测出 0, 是**空断言**;
%   因此本用例把同一 sigma 的阈值放进 u=4.4 的可分辨带, 并单独断言发货阈值下确为 0。
c = demoCfg();
[~, ms] = tepc.electronics.noise(0, c, ...
    RandStream('Threefry', 'Seed', c.provenance.seed + 1), "sigma");
sigma = ms.sigma_peak_V;
thrShip = c.electronics.trigger.threshold_V;
n = 1e5;   M = 400;                     % 每窗样本数 n>=1e5
uShip = thrShip / sigma;
qShip = 0.5 * erfc(uShip / sqrt(2));
pShip1 = 1 - (1 - qShip)^n;             % 发货阈值下的单侧 iid 解析率
tc.verifyGreaterThan(uShip, 10, sprintf( ...
    '前提漂移: 发货阈值只剩噪声峰的 %.2f 倍, 假符合率不再是"可忽略"级别', uShip));
% ---- 装置工作点常数群的"同批"守卫 ----
% threshold_V / ADC 量程 / 峰幅噪声 sigma 这三个数是围着同一个 (已知缺陷) PZ 峰幅一起定的,
% 但现有回归**没有一条**把它们绑在一起: 单独把 threshold_V 或 Cf/Rf/shaping 改掉, 假符合率那条
% 仍是绿的 (它只要求 u>10), 而 config 里"range2 覆盖 1 MeV 峰"那句话会静默变成谎话。
% 下面三条把整个群钉住: 动任何一边, 至少一条红。数值取自发货 cfg + 同一 seed 的实跑
% (_工作底稿/z868_group.log: sigma=0.00123061531878 两次同 seed 逐位相同, u=16.252032),
% 所以这不是"把注释里的 16.25 再抄一遍", 而是把那条前提变成可失败的断言。
tc.verifyEqual(sigma, 0.00123061531878, 'RelTol', 1e-6, sprintf( ...
    '峰幅噪声 sigma 离开了工作点群 (实得 %.12g V): Rf/Cf/shaping/sampleTime/waveWindow/噪声配置任何一边单独动都会走到这里', sigma));
tc.verifyEqual(uShip, 16.252032, 'RelTol', 1e-5, sprintf( ...
    '发货阈值对峰幅噪声的倍数不再是 16.252 (实得 %.6f): 改 threshold_V 必须连着 sigma 一起重定', uShip));
tc.verifyEqual(c.electronics.adc.fullScale_V / c.electronics.trigger.threshold_V, 100, 'RelTol', 1e-9, ...
    'ADC 满量程对阈值的 100 倍关系断了: 量程与阈值是同一批定的, 单边改动必须一起改');
tc.verifyEqual(c.electronics.adc.range2Gain, 32, 'RelTol', 1e-12, ...
    '第二量程增益离开发货值 32 (range2 = 64 V 是按 1 MeV 反冲峰量级选的, 动它要重核那句话)');
tc.verifyLessThan(pShip1, 1e-12, sprintf('发货阈值下单侧 iid 解析率应为 ~0, 实得 %.3e', pShip1));
rs = RandStream('Threefry', 'Seed', 20260920);
uBand = 4.4;   thrBand = uBand * sigma;
nS = 0;  nR = 0;  nShip = 0;
for m = 1:M
    v = randn(rs, n, 1) * sigma;
    pk = tepc.electronics.peakSigned(v, +1);        % 生产峰定义 (带符号)
    if abs(pk) >= thrBand,  nS = nS + 1; end
    if max(abs(v)) >= thrBand,  nR = nR + 1; end    % 旧实现: 双侧整流
    if max(abs(v)) >= thrShip,  nShip = nShip + 1; end
end
pEmp = nS / M;   pEmpR = nR / M;
q1 = 0.5 * erfc(uBand / sqrt(2));
pSig = 1 - (1 - q1)^n;                  % 带符号规则的理论值
pRec = 1 - (1 - 2 * q1)^n;              % 双侧整流规则的理论值
se = sqrt(max(pEmp * (1 - pEmp), 1 / M) / M);
tc.verifyEqual(nShip, 0, sprintf('发货阈值 (%.2f sigma) 下 %d 窗出现 %d 次假符合, 与解析率 %.1e 矛盾', ...
    uShip, M, nShip, pShip1));
tc.verifyGreaterThan(pEmp, 0.02, sprintf( ...
    '可分辨带前提: 实测率 %.4f 太小 (理论 %.4f), 两种规则在 MC 上分不开', pEmp, pSig));
tc.verifyLessThan(abs(pEmp - pSig), 4 * se, sprintf( ...
    ['带符号峰规则的实测率 %.4f 与解析值 %.4f 相差 %.4f (>4*MC_SE=%.4f; n=%d, M=%d, ' ...
     'Threefry 种子固定)。差到双侧理论值 (%.4f) 那个量级就说明峰定义被换成了整流'], ...
    pEmp, pSig, abs(pEmp - pSig), 4 * se, n, M, pRec));
tc.verifyGreaterThan(abs(pEmp - pRec), 6 * se, sprintf( ...
    ['实测率 (%.4f) 与**双侧整流**理论值 (%.4f) 的距离不足 6*MC_SE (%.4f): ' ...
     '这条用例失去失效能力 —— 旧实现 max(abs(v)) 也能通过, 契约 8 未被锁住'], ...
    pEmp, pRec, 6 * se));
seR = sqrt(max(pEmpR * (1 - pEmpR), 1 / M) / M);
tc.verifyLessThan(abs(pEmpR - pRec), 4 * seR, sprintf( ...
    '同一批样本上整流规则的实测率 %.4f 与其解析值 %.4f 不符 (容差 4*SE=%.4f)', ...
    pEmpR, pRec, 4 * seR));
fprintf('[ftr/iid] sigma=%.6e u=%.2f n=%d M=%d p_emp=%.4f p_signed_theory=%.4f p_rect_theory=%.4f p_emp_rect=%.4f se=%.4f u_shipped=%.2f\n', ...
    sigma, uBand, n, M, pEmp, pSig, pRec, pEmpR, se, uShip);
end

%% ================= 契约 8 (b): 生产成型噪声用带符号峰 =================
function test_shaped_noise_false_trigger_uses_signed_peak(tc)
% 真实测量链的噪声支路: noise() 时域合成 -> combinedV 电压级联 (与 simulate 同一段)。
%   成型后样本**时间相关** (相关时间 ~ tau/Ts = 100 样本), 所以 iid 值是**粗糙的
%   双侧括号而不是等式**: 平滑高斯过程的极值有"聚簇"
%   重尾, 实测率可以高于 iid 值若干倍。因此这里断言
%     (i)  实测带符号率落在 iid 单侧值的 [1/2, 2] 倍内 (括号, 不是等式);
%     (ii) 同一批窗口上"整流率/带符号率" >= 1.25 (对称噪声理论 ~2): 两种规则
%          在生产波形上**可测量地**不同;
%     (iii)代码的率离单侧理论值明显更近, 离双侧理论值明显更远 (>8 MC_SE)。
%   旧实现 max(abs(v)) 会让 (i) 与 (iii) 同时失败。
c = demoCfg();
cf = tepc.electronics.filters(c);
N = cf.Nwin;   M = 4000;
rs = RandStream('Threefry', 'Seed', 4242);
pkS = zeros(M, 1);  pkR = zeros(M, 1);  sd = zeros(M, 1);
for m = 1:M
    vn = tepc.electronics.noise(N, c, rs, "waveform");
    x = filter(cf.combinedV{1}, cf.combinedV{2}, vn);
    pkS(m) = tepc.electronics.peakSigned(x, cf.hsign);   % 生产峰定义
    pkR(m) = max(abs(x));                                % 旧实现
    sd(m) = std(x);
end
sigS = sqrt(mean(sd.^2));                                % 成型噪声样本标准差
tc.verifyGreaterThan(sigS, 0, '成型噪声方差为零: 这条契约在这组参数下不可测');
u = 3.4;   a = u * sigS;                                 % 放在可分辨带
Q1 = 0.5 * erfc(u / sqrt(2));
p1 = 1 - (1 - Q1)^N;                                     % iid 单侧
p2 = 1 - (1 - 2 * Q1)^N;                                 % iid 双侧 = 旧规则理论值
e1 = mean(pkS >= a);   e2 = mean(pkR >= a);
se = sqrt(max(e1 * (1 - e1), 1 / M) / M);
nDisc = nnz(pkR >= a & pkS < a);                         % 只有整流规则才误报的窗口
tc.verifyGreaterThan(nDisc, 0.05 * M, sprintf( ...
    '两种峰规则在同一批 %d 窗上只差 %d 例: 该阈值下契约没有失效能力', M, nDisc));
tc.verifyGreaterThan(e2, 1.25 * e1, sprintf( ...
    '整流率 %.4f / 带符号率 %.4f = %.3f < 1.25: 两侧未可测量地分开 (对称噪声理论值 ~2)', ...
    e2, e1, e2 / max(e1, realmin)));
tc.verifyGreaterThan(e1, p1 / 2, sprintf('带符号实测率 %.4f 低于 iid 括号下界 %.4f/2', e1, p1 / 2));
tc.verifyLessThan(e1, 2 * p1, sprintf('带符号实测率 %.4f 高于 iid 括号上界 2*%.4f', e1, p1));
tc.verifyGreaterThan(abs(e1 - p2), 8 * se, sprintf( ...
    ['实测率 %.4f 与双侧整流理论值 %.4f 的距离不足 8*MC_SE (%.4f): ' ...
     '区分不出代码用的是哪种峰定义 (整流实现在此通过 = 测试无失效能力)'], ...
    e1, p2, 8 * se));
tc.verifyLessThan(abs(e1 - p1), abs(e1 - p2), sprintf( ...
    '实测率 %.4f 反而更接近双侧值 (|d|=%.4f) 而非单侧值 (|d|=%.4f): 峰定义是整流的', ...
    e1, abs(e1 - p2), abs(e1 - p1)));
fprintf('[ftr/shaped] sigma=%.6e thr=%.6e p_signed=%.4f p_rect=%.4f ratio=%.3f iid1=%.4f iid2=%.4f se=%.4f disc=%d/%d\n', ...
    sigS, a, e1, e2, e2 / max(e1, realmin), p1, p2, se, nDisc, M);
end

%% ================= 辅助 (不得以 test_ 开头) =================
function [fl, w, R] = runChain(cfg, chunkSize, seed)
% 一次完整 execute 后**回读** events.h5 的逐事件标志位与权重 (不信任内存对象)。
c = cfg;
c.run.chunkSize = chunkSize;
rd = newRunDir(sprintf('pu%d', chunkSize));
R = tepc.run.execute(c, 'N', 5000, 'Seed', seed, 'RunDir', rd);
f = fullfile(rd, 'events', 'events.h5');
if ~isfile(f)
    error("tepc:tests:NoEvents", 'chunkSize=%d 的 run 没提交 events.h5 (RunDir=%s)', chunkSize, rd);
end
fl = h5read(f, '/events/flags');   fl = fl(:);
w  = h5read(f, '/events/weight');  w  = w(:);
end

function p = newRunDir(tag)
p = sprintf('%s%c%s', tempdir, filesep, ...
    sprintf('tepc_ft_%s_%s_%04x', tag, ...
    char(string(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))), randi(65535)));
if isfolder(p), rmdir(p, 's'); end
mkdir(p);
end
