function out = deadTime(t, tau, mode, busyUntil0)
%DEADTIME 薄壳: 死时间判定全部委托给唯一权威状态机 tepc.electronics.daq。
%   本函数过去自带一套 busy 递推, 与 daq.m 的判定和
%   活时间定义互相矛盾 (三套竞争实现之一)。现在它只做参数适配 + 字段回填,
%   函数体内不再有任何 busy/pile-up 递推。签名与原有输出字段名保持不变。
%
%   ---- 与 daq 的参数映射 (daq(tArrive, latAbs_s, width_s, tau_s, mode, carry)) ----
%     latAbs_s = 0     本函数的 t 已是"触发时刻"的等价物, 旧模型没有固定触发延迟。
%     tau_s    = tau   死时间常数, 直接传递。
%     width_s  = tau   关键取法: pile-up 判据是 tt < lastTrigEnd (= 上次触发脉冲末
%                      = tt_prev + width)。被接受的事件满足 tt >= busyUntil =
%                      tt_prev + tau >= tt_prev + width = lastTrigEnd, 故 width<=tau
%                      时 pileup 分支在数学上不可达 => nPile 恒 0, 与"旧模型不建模
%                      pile-up"逐事件等价 (实测 80 组随机序列: 接受掩码与 daq 完全
%                      一致, pileup 计数恒 0)。生产链的 pile-up 窗 (>tau) 来自
%                      tepc.electronics.pulseOccupancy_s(cfg), 那是 daq 调用方的事,
%                      本函数不引入。
%     carry    = struct('busyUntil', busyUntil0)  旧签名只能携带 busy。daq 还支持
%                      lastTrigEnd/tStart: width=tau 时 lastTrigEnd 与 busyUntil 同值,
%                      不带它不改变判定; tStart 无法从旧签名传入 => 活时间窗按 daq
%                      的默认取"本块首个被接受事件"(见下)。
%
%   ---- 占用与活时间 (采用 daq 的区间并集定义) ----
%     * nonparalyzable: 只有真正触发 DAQ 的事件占用 [t, t+tau]; 死时间内到达者被拒
%       且不延长 busy => liveTime = span - tau*nAccepted (与旧公式的扣项一致)。
%     * paralyzable   : 任意到达 (含被拒) 都把 busy 重启到 t+tau, 因而**全部**占用;
%       liveTime = span - union_i([t_i, t_i+tau])。Poisson 率 r 下该并集的占比趋于
%       1-exp(-r*tau) (一维布尔覆盖), 即 liveFrac -> exp(-r*tau) = m/r。实测
%       (tau=1e-5, N=4e5, seed=11; 真值另用独立栅格 Monte-Carlo 复核):
%         r*tau=0.5 : 真值 exp(-0.5)=0.606531, 栅格 MC 0.607450, daq 0.606785;
%                     旧 :55 式 1-tau*nAccepted/span 给 0.696647 (高 14.9%)。
%         r*tau=2   : 真值 0.135335, 栅格 MC 0.134955, daq 0.135328;
%                     旧式给 0.728742 (高 5.4 倍)。
%     span = [本块首个被接受事件, 本块末事件] (daq 的窗)。块内无接受事件时窗无定义
%       => liveTime_s = 0, liveFrac = NaN (与 daq 一致)。
%     诚实说明 (旧输出无法在不改变语义下从 daq 复现的两个字段):
%       liveTime_s  旧式 `max(ts(end)-busyUntil0,0) - tau*nnz(accepted)` 有两处错:
%                   (a) 不带 carry 时 busyUntil0=-Inf => liveTime_s 恒为 **Inf**
%                       (实测 15 组用例中 12 组返回 Inf);
%                   (b) paralyzable 只扣接受事件的 tau, 漏掉被拒事件重启的 busy,
%                       高活时间被系统性高估 (见上表)。字段名保留, 值改为 daq 的
%                       区间并集结果。
%       busyUntilEnd paralyzable 且块内零接受时旧值退回 busyUntil0, 而 busy 实际已
%                   被最后一个被拒事件重启 => 现取 daq.busyUntil (= 末事件+tau)。
%                   其余情形 (含全部 nonparalyzable) 与旧值逐位相同。
%     busyTotal_s 仍是 tau*nAccepted (旧语义, 有测试锁定), 故它在 paralyzable 下
%       **不等于**被占用时间; 占用时间另出新字段 occupied_s = span - liveTime_s。
%     liveFrac/span_s/occupied_s/reason/nDead/nPile 是新增字段, 不影响老调用方。
%   高损失区观测率不可稳定反演, 调用方(GUI/门禁)必须检查 r_obs/r_true。

if nargin < 4 || isempty(busyUntil0), busyUntil0 = -Inf; end
if ~(isscalar(tau) && isreal(tau) && isfinite(tau) && tau >= 0)
    error("tepc:deadtime:BadTau","deadTime_s 必须为非负标量");
end
if ~(isscalar(busyUntil0) && (isfinite(busyUntil0) || isinf(busyUntil0)))
    error("tepc:deadtime:BadCarry","busyUntil0 非法");
end
t = t(:);
if any(~isfinite(t))
    error("tepc:deadtime:BadTime","到达时间含 NaN/Inf");
end
modeL = lower(string(mode));
if ~any(modeL == ["nonparalyzable","paralyzable"])
    error("tepc:deadtime:BadMode","未知死时间模式 %s", char(modeL));
end
[ts, order] = sort(t);
n = numel(ts);

if tau > 0
    % 唯一的判定入口: 接受/拒绝/占用 全由 daq 决定。
    dq = tepc.electronics.daq(ts, 0, tau, tau, modeL, struct('busyUntil', busyUntil0));
    accepted = dq.accepted;
    busyUntilEnd = dq.busyUntil;
    liveTime_s = dq.liveTime_s;
    liveFrac = dq.liveFrac;
    reason = dq.reason;
    nDead = dq.nDead;  nPile = dq.nPile;
else
    % 退化工况 tau=0: 没有死时间, daq 的守卫要求 tau>0 故不能走上面这条路。
    % 判定退化为"不早于携带进来的 busy 截止"这一次比较 (无递推, 无 busy 状态机),
    % 占用长度为 0 => 全部时间都是活时间。
    accepted = ts >= busyUntil0;
    if any(accepted)
        busyUntilEnd = ts(end);
    else
        busyUntilEnd = busyUntil0;
    end
    reason = strings(n,1);
    reason(accepted) = "accepted";
    reason(~accepted) = "deadtime";
    nDead = nnz(~accepted);  nPile = 0;
    liveFrac = NaN; liveTime_s = 0;
end

nAccepted = nnz(accepted);
span_s = NaN; occupied_s = NaN;
if nAccepted > 0
    % 与 daq 同一定义: 窗 = [首个触发事件, 末事件]; 占用 = 区间并集与窗的交。
    span_s = ts(end) - ts(find(accepted, 1, 'first'));
    if tau > 0
        occupied_s = span_s - liveTime_s;
    else
        occupied_s = 0; liveTime_s = span_s; liveFrac = 1;
    end
end

out = struct('accepted', accepted, 'nAccepted', nAccepted, ...
    'nRejected', n - nAccepted, ...
    'busyTotal_s', tau*nAccepted, ...
    'liveTime_s', liveTime_s, ...
    'order', order, 'busyUntilEnd', busyUntilEnd, ...
    'mode', char(modeL), 'tau_s', tau, ...
    'reason', reason, 'nDead', nDead, 'nPile', nPile, ...
    'span_s', span_s, 'occupied_s', occupied_s, 'liveFrac', liveFrac);
end
