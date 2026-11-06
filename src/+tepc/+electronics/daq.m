function out = daq(tArrive, latAbs_s, width_s, tau_s, mode, carry)
%DAQ 统一 DAQ 状态机: 死时间与 pile-up 的**唯一**判据实现。
%   为什么要有这个函数: 之前同一台"仪器"里有三套互不相通的判定 ——
%     deadTime.m  只按到达时刻与常数 tau 计 busy;
%     execute.m   用相邻 t0_s 间隙判 pile-up, 且每 chunk 复位 (跨块漏判);
%     trigger.m   真正的"阈值+迟滞武装"状态机, 但只有测试调用它 (死代码)。
%   三者对"什么事件被接受"没有一致定义, 于是活时间占比与谱账本互相矛盾。
%
%   输入
%     tArrive  [s]  事件到达时刻 (列向量; 不必预先排序, 内部按触发时刻排序)
%     latAbs_s [s]  **固定**触发延迟 = c.hidx*Ts。
%                   刻意不用逐事件实测的 ipk*Ts: 它被噪声驱动, 相邻事件可发生
%                   次序翻转, 会让分块/整段两条路径给出不同标志位。
%     width_s  [s]  脉冲占用宽度 (pile-up 窗); 由成形/波窗决定, 不等于 tau。
%     tau_s    [s]  死时间常数。
%     mode         'nonparalyzable' | 'paralyzable'
%     carry    struct, 可选字段 busyUntil / lastTrigEnd / tStart —— 跨 chunk 携带。
%                   缺省视为 -Inf。旧实现在这里只携带 busyUntil, pile-up 每块重新
%                   开放, 造成块边界漏判 (execute.m 原 puSorted(1)=false)。
%
%   输出
%     out.accepted   逻辑列向量 (与输入同序)
%     out.reason     字符串列: accepted | deadtime | pileup
%     out.nAccepted / out.nDead / out.nPile
%     out.busyUntil / out.lastTrigEnd  供下一块携带
%     out.liveTime_s, out.liveFrac     活时间 = 观察跨度内"未被占用"的时间
%
%   占用规则 (显式定义, 因为不同 DAQ 实现会给出不同答案):
%     * 非瘫痪: 事件到达时若 busy 未结束 -> deadtime 拒收, **不**延长 busy;
%               否则接受, busy 置为 tt+tau。
%     * 瘫痪  : 任何事件都延长 busy 到 tt+tau; 只有落在 busy 之外的才被接受。
%     * pile-up: 在死时间幸存者中, 若 tt < 上一次触发脉冲结束 (lastTrigEnd)
%               则判 pileup。pileup 事件**仍然占用 DAQ** (真实数字化仪会把堆叠
%               脉冲读走再丢弃), 因此它同样把 busy 置为 tt+tau 并更新 lastTrigEnd。
%     * 优先级: deadtime > pileup > accepted, 每个事件恰好一个原因码 -> 三类计数
%               之和恒等于事件数, 不会出现"一个事件同时计两次拒收"的账本错误。

if nargin < 6 || isempty(carry), carry = struct(); end
if nargin < 5, mode = "nonparalyzable"; end
t = double(tArrive(:));
n = numel(t);
if ~isscalar(latAbs_s) || ~isfinite(latAbs_s) || latAbs_s < 0
    error("tepc:dq:BadLatency","固定触发延迟必须是非负标量, 实得 %g", latAbs_s);
end
if ~(isnumeric(width_s) && isscalar(width_s) && width_s > 0)
    % 必须先判 isscalar: 空向量时 ~( [] > 0 ) 得到 **空**, 而 `if 空` 恒为假,
    % 守卫形同不存在, 错误会推迟到深处以更难读的形式冒出来。
    error("tepc:dq:BadWidth","脉冲宽度必须为正标量, 实得 %s", mat2str(width_s));
end
if ~(isnumeric(tau_s) && isscalar(tau_s) && tau_s > 0)
    error("tepc:dq:BadTau","死时间常数必须为正标量, 实得 %s", mat2str(tau_s));
end
mode = lower(string(mode));
if ~any(mode == ["nonparalyzable","paralyzable"])
    error("tepc:dq:BadMode","mode 只允许 nonparalyzable|paralyzable, 实得 %s", char(mode));
end
busyUntil = getc(carry, 'busyUntil', -Inf);
lastTrigEnd = getc(carry, 'lastTrigEnd', -Inf);
tStart = getc(carry, 'tStart', Inf);

tt = t + latAbs_s;                       % 绝对触发时刻 (固定延迟 => 与 t 同序)
[~, ord] = sort(tt, 'ascend');
acc = false(n,1); rea = strings(n,1);

for k = ord(:)'
    if tt(k) < busyUntil
        rea(k) = "deadtime";
        if mode == "paralyzable"
            busyUntil = tt(k) + tau_s;   % 瘫痪型: 每个事件都重启
        end
        continue
    end
    if tt(k) < lastTrigEnd
        rea(k) = "pileup";               % 仍占用 DAQ
        busyUntil = tt(k) + tau_s;
        lastTrigEnd = tt(k) + width_s;
        tStart = min(tStart, tt(k));
        continue;
    end
    acc(k) = true; rea(k) = "accepted";
    busyUntil = tt(k) + tau_s;
    lastTrigEnd = tt(k) + width_s;
    tStart = min(tStart, tt(k));
end

out = struct();
out.accepted = acc;  out.reason = rea;
out.nAccepted = nnz(acc);
out.nDead = nnz(rea == "deadtime");
out.nPile = nnz(rea == "pileup");
out.busyUntil = busyUntil;  out.lastTrigEnd = lastTrigEnd;
tEnd = max(tt);
out.span_s = 0;
if isfinite(tStart) && tEnd > tStart
    span = tEnd - tStart;
    out.span_s = span;
    % 占用掩码: 非瘫痪型只有"真的触发了 DAQ"的事件占用 (busy 期内到达不重启);
    %          瘫痪型所有到达都重启 busy => 全部占用。
    occupies = (rea == "accepted") | (rea == "pileup") | (mode == "paralyzable");
    ttS = tt(ord);  ocS = occupies(ord);
    occ = occupancySpan(ttS, ocS, tau_s, tStart, tEnd);
    out.liveTime_s = max(span - occ, 0);
    out.liveFrac = out.liveTime_s/span;
else
    out.liveTime_s = 0; out.liveFrac = NaN;
end
% 账本恒等式: 原因码互斥且穷尽 —— 拒收原因求和必须等于总拒收数
assert(out.nAccepted + out.nDead + out.nPile == n, ...
    "DAQ 原因码不穷尽: %d+%d+%d ~= %d", out.nAccepted, out.nDead, out.nPile, n);
end

function v = getc(s, nm, dflt)
if isfield(s, nm) && ~isempty(s.(nm)) && isfinite(s.(nm)), v = s.(nm); else, v = dflt; end
end

function occ = occupancySpan(tt, occupies, tau, t0, t1)
% 被占用时间 = [tt, tt+tau] 区间并集与观察窗 [t0,t1] 的交。tt 必须升序, 线性扫描。
occ = 0;  curEnd = -Inf;  curStart = -Inf;
for i = 1:numel(tt)
    if ~occupies(i), continue; end
    s0 = tt(i);  e0 = tt(i) + tau;
    if s0 > curEnd
        if isfinite(curEnd), occ = occ + min(curEnd,t1) - max(curStart,t0); end
        curStart = s0; curEnd = e0;
    else
        curEnd = max(curEnd, e0);
    end
end
if isfinite(curEnd), occ = occ + min(curEnd,t1) - max(curStart,t0); end
occ = max(occ, 0);
end
