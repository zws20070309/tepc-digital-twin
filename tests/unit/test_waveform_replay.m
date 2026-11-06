function tests = test_waveform_replay
%TEST_WAVEFORM_REPLAY 波形数据契约 (events/waveforms.h5) 与回放一致性。
%   本文件锁的是六件事, 每一件都可失败:
%     1 落盘的整数样本与写入值逐位相同 (int16 往返无损), 且同一输入两次调用产生同一份数据集;
%     2 **回放**: 只读盘上样本反量化, 重算 peak / 触发时刻 (argmax*Ts) / ADC 码 / 积分,
%       要求与盘上标量逐位相等 —— 这条才是本特性的全部意义: 标量必须是波形的函数,
%       而不是事件表里另记的一列数;
%     3 负对照: 把真正峰所在的那个样本改成 0, 重算的峰必须**不再**等于盘上标量
%       (证明第 2 条不恒真, 而不是两个各自成立的数碰巧一样);
%     4 写出器不接受调用方喂进来的摘要: meta.event_scalars 只用于交叉核对与披露,
%       故意给它错值, 落盘标量必须仍是波形复算值;
%     5 子集选择只由 (seed, nSub) 与候选上界决定: 两次调用同一批 id, nSub 变大是嵌套
%       追加, 换 seed 必须换选择, 且选择器不得消耗全局随机流;
%     6 抽样重跑的波形与批量生产链的波形逐位相同 (每事件子流锚在 eventID 上),
%       否则"事后重跑取波形"就是在存另一条曲线。
%
%   诚实声明 (不得越过): 本文件里的时序全部由解析代理模型 (tepc.backendId =
%   analytic_surrogate_v1) 的电子学链合成 (Ramo 感应 -> CSA/PZ/CR-RC 成形 -> 串联噪声),
%   它们是**模拟波形**, 不是实测脉冲形状。这里通过的回放只证明"落盘标量与落盘波形
%   自洽"这一数据契约成立, 不证明模型与任何真实装置相符, 也不得被写成"波形已与实测
%   脉冲回放一致"或"电子学已用实测脉冲标定" (措辞口径见 config/banned_claims.json)。
%   量化口径与为什么逐位比对成立: 见 tepc.io.writeWaveformsH5 头注释 (scale_V 取 2 的
%   幂 -> 反量化是精确指数移位; 标量由盘上整数经确定性算术复算, 故可比 AbsTol 0)。
tests = functiontests(localfunctions);
end

%% ================= 1 往返: 整数样本逐位 =================
function test_written_samples_round_trip_bit_exact(tc)
[~, meta, tr, ids] = synthCase();
d = workDir('wf_rt');
f1 = fullfile(d, 'waveforms1.h5');
f2 = fullfile(d, 'waveforms2.h5');
s1 = tepc.io.writeWaveformsH5(f1, ids, tr, meta);
s2 = tepc.io.writeWaveformsH5(f2, ids, tr, meta);
raw1 = h5read(f1, '/waveform/samples');
raw2 = h5read(f2, '/waveform/samples');
tc.verifyTrue(isa(raw1, 'int16'), sprintf( ...
    'samples 落盘类型不是 int16 (实得 %s): 逐位比对的凭据就没了', class(raw1)));
tc.verifyEqual(size(raw1), size(tr), '样本数组形状应为 [nSub x nSamples]');
want = cast(round(tr./s1.scale_V), 'int16');
tc.verifyTrue(isequal(want, raw1), sprintf( ...
    '盘上整数与"按 scale_V=%g 量化"的结果不逐位相同: 定标或写入路径被改动过', s1.scale_V));
tc.verifyTrue(isequal(raw1, raw2), ...
    '同一输入两次调用的数据集不逐位相同: 写出器里混进了不确定因素 (RNG/时间?)');
tc.verifyTrue(isequal(s1.peak_V, s2.peak_V) && isequal(s1.adc_code, s2.adc_code) ...
    && isequal(s1.t_trigger_s, s2.t_trigger_s) && isequal(s1.integral_Vs, s2.integral_Vs), ...
    '同一输入两次调用给出的标量列不同 (标量必须只由输入决定)');
W = tepc.io.readWaveformsH5(f1);
tc.verifyTrue(isequal(W.samples_int16, raw1), 'readWaveformsH5 没把整数原样交出来');
tc.verifyTrue(isequal(W.v, double(raw1)*s1.scale_V), ...
    '读回 helper 的反量化表达式与写出器不再同一 (v = double(samples)*scale_V)');
err = max(abs(W.v(:) - tr(:)));
tc.verifyLessThanOrEqual(err, s1.scale_V/2, sprintf( ...
    '量化误差 %.3e 超过 scale_V/2 = %.3e: 发生了削顶或非最近取整', err, s1.scale_V/2));
tc.verifyTrue(isequal(W.event_id, cast(ids, 'uint64')), 'event_id 往返变了 (顺序或类型被改)');
tc.verifyTrue(isequal(W.event_id, uint64(ids(:))), ...
    '行序即 ids 的给定顺序: 落盘前后不得静默重排');
% 属性与数据集不得各说各话 (两处同名的量必须逐位一致)
tc.verifyEqual(double(W.attrs.Ts_s), W.Ts_s, 'AbsTol', 0, 'Ts_s 在属性与数据集里不同值');
tc.verifyEqual(double(W.attrs.scale_V), W.scale_V, 'AbsTol', 0, 'scale_V 两处不同值');
tc.verifyEqual(double(W.attrs.n_sub), size(raw1, 1), 'AbsTol', 0, '属性 n_sub 与实得行数不符');
tc.verifyEqual(double(W.attrs.n_samples), size(raw1, 2), 'AbsTol', 0, '属性 n_samples 与实得列数不符');
% 诚实口径跟着数据走: 只读文件的人必须能看出这是模拟波形
dp = lower(string(W.attrs.data_provenance));
tc.verifyTrue(contains(dp, "simulated"), sprintf( ...
    'data_provenance 属性没写明 simulated (实得 "%s"): 只拿到文件的人无从判断来源', dp));
tc.verifyTrue(contains(dp, "not measured"), sprintf( ...
    'data_provenance 属性没写明非实测 (实得 "%s"): 一个不带出处的波形文件会被读成实测数据', dp));
rp = string(W.attrs.replay_recipe);
tc.verifyTrue(contains(rp, "peakSigned") && contains(rp, "adc"), ...
    sprintf('replay_recipe 属性没给出可复算的峰/量化口径 (实得 "%s")', rp));
end

%% ================= 2 回放: 标量必须是波形的函数 =================
function test_stored_scalars_are_recomputed_from_the_stored_trace(tc)
[~, meta, tr, ids] = synthCase();
f = fullfile(workDir('wf_rp'), 'waveforms.h5');
tepc.io.writeWaveformsH5(f, ids, tr, meta);
W = tepc.io.readWaveformsH5(f);
nSub = size(W.samples_int16, 1);
tc.verifyGreaterThan(nSub, 1, '样本数太少, 下面的逐事件循环会空转');
badPk = 0; badT = 0; badCode = 0; badInt = 0; badIdx = 0;
for j = 1:nSub
    v = W.v(j, :).';
    % 回放配方: 与 writeWaveformsH5 头注释里那份唯一口径一致
    [pk, ipk] = tepc.electronics.peakSigned(v, W.hsign);
    [ck, ~] = tepc.electronics.adc(abs(pk), W.cfg);   % cfg 由**文件属性**重建
    % 积分按**行**求 (与写出器同形同次序): sum 对行向量与列向量的求和次序不保证逐位
    % 相同, 这里要的是逐位回放, 所以形状也是契约的一部分 (见 writeWaveformsH5 头注释)。
    integ = sum(W.v(j, :))*W.Ts_s;
    if ~(pk == W.peak_V(j)),                       badPk = badPk + 1; end
    if ~(ipk*W.Ts_s == W.t_trigger_s(j)),          badT = badT + 1; end
    if ~isequal(ck, W.adc_code(j)),                badCode = badCode + 1; end
    if ~(integ == W.integral_Vs(j)),               badInt = badInt + 1; end
    % argmax 直接从盘上整数定位 (不经 helper 的反量化), 必须与落盘时刻同一
    [~, ix] = max(double(W.hsign)*double(W.samples_int16(j, :)));
    if ~(ix == ipk),                               badIdx = badIdx + 1; end
end
tc.verifyEqual(badPk, 0, sprintf( ...
    '%d/%d 行的 peak_V 不等于由盘上样本反量化后复算的峰: 标量与波形分家了', badPk, nSub));
tc.verifyEqual(badT, 0, sprintf( ...
    '%d/%d 行的 t_trigger_s 不等于 argmax*Ts: 触发时刻不是波形的函数', badT, nSub));
tc.verifyEqual(badCode, 0, sprintf( ...
    '%d/%d 行的 adc_code 不等于对复算峰做 ADC 的结果: 数字化没吃波形 (且 cfg 是从文件属性重建的)', ...
    badCode, nSub));
tc.verifyEqual(badInt, 0, sprintf('%d/%d 行的 integral_Vs 不等于 sum(v)*Ts', badInt, nSub));
tc.verifyEqual(badIdx, 0, sprintf('%d/%d 行的峰位置与盘上整数的 argmax 不一致', badIdx, nSub));
% 上面用的是 == 与 isequal (而不是任何容差): scale_V 是 2 的幂, 反量化与求峰都是
% 同一串确定性算术, 所以这里本来就不该需要容差 —— 一旦需要, 就是实现变了。
tc.verifyTrue(all(W.t_trigger_s > 0), '触发时刻应等于 1 基 argmax 索引 x Ts, 不可能为 0');
end

%% ================= 3 负对照: 改一个样本, 回放必须失配 =================
function test_corrupting_the_peak_sample_breaks_the_replay(tc)
% 这条测试的存在理由: 若"重算 == 落盘"永远为真 (例如两边都从同一列数抄), 上面那条
% 就是装饰。这里刻意破坏一个样本, 断言失配确实发生 —— 即本文件**能**红。
[~, meta, tr, ids] = synthCase();
f = fullfile(workDir('wf_nc'), 'waveforms.h5');
tepc.io.writeWaveformsH5(f, ids, tr, meta);
W = tepc.io.readWaveformsH5(f);
raw = W.samples_int16;
ix = round(W.t_trigger_s(1)/W.Ts_s);            % 盘上标量所说的峰位置 (1 基)
tc.verifyGreaterThanOrEqual(ix, 1);
tc.verifyLessThanOrEqual(ix, size(raw, 2));
sv1 = double(W.hsign)*double(raw(1, :));        % 峰所在方向上的样本序列 (与 peakSigned 同口径)
srt = sort(sv1, 'descend');
premMsg = ['前提不成立: 第 1 行的峰在量化后不再唯一, 清零它可能被相邻同值样本抵消, ' ...
    '那条失配就与契约无关了 —— 测试信号必须造出唯一主峰。前两名都是 %g'];
tc.verifyGreaterThan(srt(1), srt(2), sprintf(premMsg, srt(1)));
tc.verifyTrue(raw(1, ix) ~= int16(0), ...
    '前提不成立: 真峰样本本来就是 0, 把它改成 0 不构成破坏, 这条负对照会空转');
raw(1, ix) = int16(0);                           % 只动内存里的副本
[pkC, ipkC] = tepc.electronics.peakSigned(double(raw(1, :)).'*W.scale_V, W.hsign);
tc.verifyNotEqual(pkC, W.peak_V(1), sprintf( ...
    '把峰样本清零后重算的峰仍等于盘上 peak_V: 那条回放断言是恒真的装饰'));
tc.verifyLessThan(abs(pkC), abs(W.peak_V(1)), ...
    '清零真峰之后 |重算峰| 没有变小: 破坏没落到被消费的那个样本上');
tc.verifyNotEqual(ipkC, ix, '清零真峰后 argmax 仍指在同一位置: 峰定位没吃波形');
% 控制组: 未破坏的那一行必须仍然逐位吻合 —— 失配是被这一处破坏引起的, 不是普遍现象
[pkOk, ~] = tepc.electronics.peakSigned(W.v(2, :).', W.hsign);
tc.verifyEqual(pkOk, W.peak_V(2), 'AbsTol', 0, ...
    '未破坏的行也不再吻合: 上面看到的失配就不是负对照的功劳');
% 盘上字节不许被测试改动 (破坏只发生在内存副本)
W2 = tepc.io.readWaveformsH5(f);
tc.verifyTrue(isequal(W2.samples_int16, W.samples_int16), ...
    '内存副本的破坏写回了文件 (readWaveformsH5 不应有任何写能力)');
% adc_code 刻意不断言: 清零后的新峰可能落在同一 LSB 桶里, 码不变是正确行为
end

%% ================= 4 反并行记账: 摘要列不得被当结论 =================
function test_writer_ignores_the_event_table_scalars_it_is_given(tc)
% meta.event_scalars 的唯一用途是披露偏差。给它故意错开的值, 落盘标量必须仍是波形
% 复算值 —— 否则"回放一致"只是把事件表的两列数搬到了波形文件里 (并行记账)。
[~, meta, tr, ids] = synthCase();
d = workDir('wf_ab');
sGood = tepc.io.writeWaveformsH5(fullfile(d, 'good.h5'), ids, tr, meta);
es = struct();
es.peak_V = sGood.peak_V*1.5 + 0.01;          % 逐字段赋值: struct('a', 列向量) 会展开成结构数组
es.t_trigger_s = sGood.t_trigger_s + 1.0;
es.adc_code = sGood.adc_code + int32(7);
metaWrong = meta;
metaWrong.event_scalars = es;
f2 = fullfile(d, 'wrong.h5');
sX = tepc.io.writeWaveformsH5(f2, ids, tr, metaWrong);
W2 = tepc.io.readWaveformsH5(f2);
tc.verifyFalse(isequal(W2.peak_V, es.peak_V), ...
    '落盘 peak_V 等于调用方喂进来的摘要列: 写的是事件表的副本, 不是波形的函数');
tc.verifyFalse(isequal(W2.t_trigger_s, es.t_trigger_s), ...
    '落盘 t_trigger_s 来自摘要列而非 argmax*Ts');
tc.verifyFalse(isequal(W2.adc_code, es.adc_code), '落盘 adc_code 来自摘要列而非数字化');
tc.verifyTrue(isequal(W2.peak_V, sGood.peak_V), ...
    '给了错摘要之后复算值反而变了: 交叉核对通道污染了落盘标量');
tc.verifyTrue(isfield(sX.xcheck, 'peak_V_rel_max') && sX.xcheck.peak_V_rel_max > 0, ...
    '交叉核对没报告偏差: 事件表与波形分家时无人披露 (静默比报错更糟)');
dv = h5readatt(f2, '/', 'xcheck_peak_V_abs_max');
tc.verifyGreaterThan(double(dv), 0, '偏差只回给调用方, 没落进文件属性: 只读文件的人看不到披露');
end

%% ================= 5 子集确定性 =================
function test_subset_ids_depend_only_on_seed_and_nsub(tc)
d = 400;
a1 = tepc.io.waveformSubset(12345, 25, d);
a2 = tepc.io.waveformSubset(12345, 25, d);
tc.verifyTrue(isequal(a1, a2), '同一 (seed, nSub, 上界) 两次调用给出不同的子集');
tc.verifyEqual(numel(a1), 25, '实得个数应等于 nSub');
tc.verifyTrue(all(a1 >= 1 & a1 <= d), '子集越出候选范围');
tc.verifyTrue(issorted(a1) && all(diff(a1) > 0), '子集必须升序且无重复 (行序即契约)');
b1 = tepc.io.waveformSubset(12345, 60, d);
tc.verifyEqual(numel(b1), 60);
tc.verifyTrue(all(ismember(a1, b1)), ...
    'nSub 变大时已选事件被换掉了: 续跑/加大样本会把已落盘的事件换成别的 (嵌套性破坏)');
c1 = tepc.io.waveformSubset(999, 25, d);
tc.verifyFalse(isequal(a1, c1), '换 seed 给出同一批 id: seed 在子集选择里是装饰');
% nSub 超过上界: 取全部, 不报错也不静默少给
all1 = tepc.io.waveformSubset(12345, 500, 7);
tc.verifyEqual(all1(:).', 1:7, 'AbsTol', 0, 'nSub > 事件数时应返回全部事件号');
tc.verifyEmpty(tepc.io.waveformSubset(12345, 0, d), 'nSub=0 必须是空集');
tc.verifyEmpty(tepc.io.waveformSubset(12345, 10, 0), '上界=0 必须是空集');
tc.verifyError(@() tepc.io.waveformSubset('x', 10, d), 'tepc:io:WaveformSubsetArgs', ...
    '非数值 seed 被静默接受: 会给出一个与任何 seed 都无关的固定子集');
% 选择器不得消耗全局随机流 (否则"选了哪些事件"会反过来扰动事件本身)
g1 = globalDrawsWithSubset(12345, 25, d, true);
g2 = globalDrawsWithSubset(12345, 25, d, false);
tc.verifyTrue(isequal(g1, g2), ...
    '调用 waveformSubset 之后全局流的后续抽样变了: 子集选择扰动了我认为是"只由 seed 决定"的事件序列');
end

%% ================= 6 写出器不许写出与自己属性文本矛盾的定标 =================
function test_writer_rejects_scale_that_breaks_its_own_contract(tc)
% 文件根属性恒写 "int16 x scale_V (power of two); dequantisation is an exact exponent
% shift" —— 这句话只在 scale_V 是 2 的幂时成立。允许调用方给任意正数就等于让自描述
% 属性可以说假话 (非 2 的幂时 double(samples)*scale_V 引入舍入, 回放不再逐位可复现)。
[~, meta, tr, ids] = synthCase();
d = workDir('wf_scale');
metaBad = meta; metaBad.scale_V = 3 * 2^-20;      % 正的有限标量, 但不是 2 的幂
tc.verifyError(@() tepc.io.writeWaveformsH5(fullfile(d, 'bad.h5'), ids, tr, metaBad), ...
    'tepc:io:WaveformScaleNotPow2', ...
    '非 2 的幂的 scale_V 被接受: 属性里的「精确指数移位」就成了假话');
metaOk = meta;
% 显式给一个"合法且不会削顶"的 2 的幂: 与写出器默认同一式子, 但这里是调用方给的,
% 核的是"给定合法定标时按给定值落盘", 不是"默认值算得对"。
metaOk.scale_V = 2^ceil(log2(max(abs(tr(:)))/32767));
sOk = tepc.io.writeWaveformsH5(fullfile(d, 'ok.h5'), ids, tr, metaOk);
tc.verifyEqual(sOk.scale_V, metaOk.scale_V, 'AbsTol', 0, '显式合法定标未被原样采用');
W = tepc.io.readWaveformsH5(fullfile(d, 'ok.h5'));
raw = h5read(fullfile(d, 'ok.h5'), '/waveform/samples');
tc.verifyEqual(W.scale_V, sOk.scale_V, 'AbsTol', 0, ...
    '读取端报回的 scale_V 与写出器采用的不是同一个数 (属性往返不一致)');
% 判据必须独立于读取端: W.v 本身就是 double(raw)*scale 算出来的, 拿它和同一式子比是
% 自证。这里比"盘上整数 == 按给定定标对原始波形的最近取整" —— 只依赖写出器与调用方。
tc.verifyTrue(isa(raw, 'int16'), sprintf('落盘类型不是 int16 (实得 %s)', class(raw)));
tc.verifyTrue(isequal(raw, cast(round(tr ./ sOk.scale_V), 'int16')), ...
    '给定 2 的幂定标时盘上整数不再是"原始波形按该定标的最近取整"');
tc.verifyTrue(all(abs(double(raw(:)) * sOk.scale_V - tr(:)) <= sOk.scale_V/2 + eps), ...
    '反量化与原波形的偏差不在一个量化半步内: 定标或取整路径被改动过');
% 削顶仍是独立的一条: 合法的 2 的幂但太小, 必须在写之前拒
metaTiny = meta; metaTiny.scale_V = 2^-40;
tc.verifyError(@() tepc.io.writeWaveformsH5(fullfile(d, 'tiny.h5'), ids, tr, metaTiny), ...
    'tepc:io:WaveformSaturation', '会削顶的定标必须拒, 不许静默截断后照常发布');
end

function out = globalDrawsWithSubset(seed, nSub, d, useSubset)
% 从一个固定种子的全局流画 4 个, (可选) 跑一次选择器, 再画 4 个: 返回后 4 个。
% 首参不是 tc 且带多个实参 -> 既不被 functiontests 收集, 也不被 genCounts 的签名口径看见。
old = RandStream.getGlobalStream();
restore = onCleanup(@() RandStream.setGlobalStream(old)); %#ok<NASGU>
RandStream.setGlobalStream(RandStream('mt19937ar', 'Seed', 3));
rand(4, 1);
if useSubset
    tepc.io.waveformSubset(seed, nSub, d);
end
out = rand(4, 1);
end

%% ================= 6 抽样重跑 == 批量生产链 =================
function test_harvested_trace_equals_the_batched_chain_trace(tc)
% execute.m 的可选波形阶段是**逐事件**重跑 tepc.electronics.simulate 取
% aux.waveform_first_event。这条路只有在"每事件子流锚在 eventID 上、与分块无关"时才
% 等价于生产循环里那条 v。这里就是把这个前提当断言来核 (不是当注释)。
c = demoCfg();
Rcfg = tepc.config.resolve(c);
seed = c.provenance.seed;
ctx = struct('W_eV', c.gas.W_eV.value, 'fano', c.gas.fano.value, ...
    'field', Rcfg.field, 'mob', Rcfg.mob, 'seed', seed, ...
    'G_mean', Rcfg.G_mean, 'theta', tepc.config.constants('detector.polya.theta'), ...
    'r0_m', Rcfg.r0_m, 'coeffs', tepc.electronics.filters(c));
[~, msig] = tepc.electronics.noise(0, c, RandStream('Threefry', 'Seed', seed + 1), "sigma");
ctx.noiseSigma = msig.sigma_peak_V;
ev = [12 45 7 200];                                   % EdepGas_keV
[~, instrB, auxB] = tepc.electronics.simulate(ev, 1, c, ...
    RandStream('Threefry', 'Seed', seed), ctx);       % 批量: eventID 1..4
pkS = zeros(numel(ev), 1); codeS = zeros(numel(ev), 1, 'int32'); tS = zeros(numel(ev), 1);
trS = zeros(numel(ev), numel(auxB.waveform_first_event));
for k = 1:numel(ev)
    [~, iS, aS] = tepc.electronics.simulate(ev(k), k, c, ...
        RandStream('Threefry', 'Seed', seed), ctx);   % 单事件: Substream = k
    pkS(k) = iS.peak_V; codeS(k) = iS.adc_code; tS(k) = iS.t_trigger_s;
    trS(k, :) = aS.waveform_first_event(:).';
end
tc.verifyTrue(isequaln(instrB.peak_V, pkS), ...
    '批量与逐事件重跑的 peak_V 不逐位相同: 每事件子流锚定已被破坏, 抽样落盘存的是另一条曲线');
tc.verifyTrue(isequaln(instrB.t_trigger_s, tS), '批量与逐事件重跑的 t_trigger_s 不一致');
tc.verifyTrue(isequal(instrB.adc_code, codeS), '批量与逐事件重跑的 adc_code 不一致');
tc.verifyTrue(isequaln(trS(1, :).', auxB.waveform_first_event), ...
    'eventID=1 的重跑波形与批量链给出的 waveform_first_event 不逐位相同');
tc.verifyFalse(all(trS(:) == 0), '前提: 波形不得是全零 (那样上面几条断言都无内容)');
% 把这条真波形交给写出器, 落盘标量与生产标量的偏差必须被量化误差界住 (而不是别的原因)
f = fullfile(workDir('wf_hv'), 'waveforms.h5');
meta = struct('Ts_s', ctx.coeffs.Ts, 'cfg', c, 'hsign', ctx.coeffs.hsign, 'seed', seed);
tepc.io.writeWaveformsH5(f, (1:numel(ev)).', trS, meta);
W = tepc.io.readWaveformsH5(f);
lsb = c.electronics.adc.fullScale_V/2^c.electronics.adc.bits;
tc.verifyTrue(all((abs(W.peak_V) < c.electronics.adc.fullScale_V) ...
        == (abs(instrB.peak_V(:)) < c.electronics.adc.fullScale_V)), ...
    '量程判决在量化前后翻转了: 峰恰好贴着 FS 边界一个定标之内, 码会跨量程跳变 (需换不贴边的幅度)');
inlAmp = 1 + 2*c.electronics.adc.inl_lsb*max(abs(instrB.peak_V(:))) ...
    /c.electronics.adc.fullScale_V;            % INL 把峰值误差再放大一点点 (adc.m 的弓形项)
codeSlack = ceil(W.scale_V*inlAmp/(2*lsb)) + 1;    % 半 LSB 的定标误差能推动几个码
tc.verifyLessThanOrEqual(max(abs(W.peak_V - instrB.peak_V(:))), W.scale_V/2, ...
    '落盘峰与生产峰的偏差超过 scale_V/2: 偏差来源不再是量化 (须按不可解释的差异对待)');
dCode = abs(double(W.adc_code) - double(instrB.adc_code(:)));
tc.verifyLessThanOrEqual(max(dCode), codeSlack, sprintf( ...
    '落盘码与生产码相差 %d 码, 超出量化定标能解释的 %d 码 (半 LSB 内不应走这么多)', ...
    max(dCode), codeSlack));
% 触发时刻的**索引**在平顶上可被量化挪动 1~2 个样本, 这是离散量的合法行为,
% 因此这里只核它没飞出窗口, 而把逐位相等留给第 2 条 (对同一份盘上样本自洽)。
tc.verifyTrue(all(W.t_trigger_s > 0) && all(W.t_trigger_s <= numel(trS(1, :))*W.Ts_s), ...
    '落盘触发时刻飞出波形窗口');
end

%% ================= helpers (名字不以 test 开头) =================
function c = demoCfg()
c = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function [cfg, meta, tr, ids] = synthCase()
% 合成一段"像脉冲"的双极时序 + 确定性微纹波 + 两个孤立极端样本 (全程无 RNG:
% 平手必须由构造排除, 而不是靠运气 —— 见 test_corrupting_the_peak_sample_breaks_the_replay
% 里那条"主峰唯一"的前提断言)。幅度取得越过 threshold_V 并留在量程 1 内。
cfg = demoCfg();
cf = tepc.electronics.filters(cfg);           % 极性 hsign 取自同一实现, 不自己猜
nSub = 6; nS = 601;
t = 1:nS;
g1 = (t/40).*exp(1 - t/40);
g2 = (t/160).*exp(1 - t/160);
tr = zeros(nSub, nS);
for j = 1:nSub
    A = 0.25 + 0.03*j;
    row = A*(g1 - 0.35*g2) + 1e-4*sin(t/7 + j);
    row(60 + 3*j) = 1.7*A;                    % 孤立正尖峰 (hsign=+1 时的唯一主峰)
    row(nS - 40 - 3*j) = -1.4*A;              % 孤立负过冲 (hsign=-1 时的唯一主峰)
    tr(j, :) = row;
end
ids = (101:101 + nSub - 1).';
% 逐个字段赋值而不是 struct('a', v, ...): v 是多元素数组时 struct() 会展开成结构数组
meta = struct();
meta.Ts_s = cfg.electronics.sampleTime_s;
meta.cfg = cfg;
meta.hsign = cf.hsign;
meta.seed = 12345;
meta.config_sha256 = repmat('0', 1, 64);
meta.matlab_release = version('-release');
meta.created_utc = '1970-01-01 00:00:00';     % 固定值: 写出器内部不得取当前时间
meta.waveWindow_s = nS*cfg.electronics.sampleTime_s;
end

function test_baseline_is_declared_not_silently_assumed(tc)
% 波形文件不写基线口径, 读者就无从判断 samples 减没减 pedestal —— 而 peak/integral 恰好
% 是**未减基线**的样本上取的, 这个事实只能由文件自己说。四条判据各挡一种退化:
%   ① 未给 Nwin: 必须承认"噪声地板无法只凭本文件复算", 且不得报出一个短窗事件数
%      (报了就是拿没依据的数当属性);
%   ② 给了 Nwin: 短窗事件数要用"读回器从盘上整数自己取的峰"重算一遍再比对。这里的
%      独立性只到**计数公式**为止: 峰位本身仍与写出器同源 (都由同一份 samples 经
%      peakSigned 得出), 所以先断言两处峰位一致, 再判计数 —— 它防的是"公式抄错",
%      不防"取峰实现错" (后者由 test_waveform_replay 前面的逐位回放判据负责);
%   ③ 写出侧写了不等于读侧交得出: 同一批值要从 W.attrs 里再取一次;
%   ④ 两种情形的规则文本都得是 ASCII (属性编码押在字符集上就等于赌运行机器)。
[~, meta, tr, ids] = synthCase();
nSub = size(tr, 1); nS = size(tr, 2);
d1 = workDir('bl_nwin');
f1 = fullfile(d1, 'a.h5');
tepc.io.writeWaveformsH5(f1, ids, tr, meta);
aA = attrMap(f1);
tc.verifyEqual(string(aA.baseline_applied), "none", ...
    '写出器没有去均值步骤, baseline_applied 却不是 none: 属性与实现脱钩');
tc.verifyTrue(contains(string(aA.baseline_rule), "NOT recomputable"), ...
    '没给 Nwin 却把噪声地板规则写得像可复算: 缺依据的自述');
tc.verifyFalse(isfield(aA, 'baseline_n_tail_short'), ...
    '没有 Nwin 就没有"窗够不够"的判据, 短窗事件数不得凭空出现');
tc.verifyTrue(all(double(aA.baseline_rule) < 128) && all(double(aA.baseline_applied) < 128), ...
    '根属性含非 ASCII: 回放配方的可读性被押在本机字符集上');
tc.verifyEqual(string(tepc.io.readWaveformsH5(f1).attrs.baseline_applied), "none", ...
    '读侧没把 baseline_applied 交出来: 写出来说了等于没说');
% ② 给一个让窗口"部分够用"的 Nwin: 太短会让每条都过 (属性恒为 0, 锁不到判据),
%    太长会让每条都不过 (恒为 nSub), 两种都退化成常数。取"最晚峰只剩 10 个样本"的窗长,
%    于是最晚峰那条必判不出、最早峰那条必判得出 (夹具峰位散布 15 点 > 20-10)。
ipkTr = zeros(nSub, 1);
for j = 1:nSub
    [~, ipkTr(j)] = tepc.electronics.peakSigned(tr(j, :).', meta.hsign);
end
nwin = max(1, nS - max(ipkTr) - 10);
metaB = meta; metaB.Nwin = nwin;
d2 = workDir('bl_given');
f2 = fullfile(d2, 'b.h5');
sB = tepc.io.writeWaveformsH5(f2, ids, tr, metaB);
aB = attrMap(f2);
tc.verifyTrue(contains(string(aB.baseline_rule), sprintf('Nwin=%d', nwin)), ...
    'baseline_rule 没把给出的 Nwin 写进去: 第三方拿不到窗口边界');
W = tepc.io.readWaveformsH5(f2);
tc.verifyEqual(double(W.attrs.baseline_n_tail_short), double(aB.baseline_n_tail_short), ...
    '读侧与盘上的 baseline_n_tail_short 不是一个数');
ipk = zeros(nSub, 1);
for j = 1:nSub
    [~, ipk(j)] = tepc.electronics.peakSigned(W.v(j, :).', W.hsign);
end
tc.verifyEqual(ipk(:), sB.peak_index(:), '读回器复算的峰位与写出器返回值不一致 (下面用前者)');
nExp = nnz(nS - (ipk + nwin) < 20);
tc.verifyEqual(double(aB.baseline_n_tail_short), double(nExp), ...
    '短窗事件数与按盘上量独立复算的值不符');
tc.verifyTrue(nExp > 0 && nExp < nSub, sprintf( ...
    '前提破了: Nwin=%d 下所有事件同判 (%d/%d), 这条属性退化成了常数', nwin, nExp, nSub));
end

function a = attrMap(f)
%ATTRMAP 根属性名->值的映射, 直接来自 h5info 的全量枚举。
%   列全量只能走 h5info: h5readatt 必须给属性名, 省略时报错而不是返回全部, 所以
%   "某属性没被写过"这类判据只能问这张表 (问 W.attrs 会被读侧的挑拣污染)。
%   h5info 把文本属性交成 uint8 行向量, 直接 string() 会按字节展开成字符串数组,
%   contains 也就跟着变成逐字节的逻辑向量 —— 统一在这里收回成 char。
info = h5info(f);
a = struct();
for i = 1:numel(info.Attributes)
    v = info.Attributes(i).Value;
    if isnumeric(v) || isinteger(v)
        v = char(v(:)');
    end
    a.(info.Attributes(i).Name) = v;
end
end

function p = workDir(tag)
% 每次调用一个唯一且预先清空的临时目录 (tempdir 下, 不污染仓库 runs/)。
% 刻意不在测试函数里删: 产物是失败时人工复核的证据, 由 OS 回收 tempdir。
p = sprintf('%s%c%s', tempdir, filesep, sprintf('tepc_wfr_%s_%s_%04x', tag, ...
    char(string(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS'))), randi(65535)));
if isfolder(p), rmdir(p, 's'); end
mkdir(p);
end
