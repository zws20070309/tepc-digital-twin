function [pk, ipk, anom] = peakSigned(v, sgn)
%PEAKSIGNED 成形波形的**带符号**主峰。
%   唯一实现, 由 simulate / injectCalibrate / Simulink 对照共用 —— 测量链与刻度链
%   必须用同一个峰定义, 否则"电荷注入刻度"与"事件幅度"量的是两件不同的东西。
%
%   为什么不用 max(abs(v)):
%     * 双侧整流: 纯噪声波形 (零沉积事件) 的"峰"= max|noise|, 而阈值判据
%       `pk < thr` 只对**正方向**有意义 -> 假符合概率翻倍, 近阈幅度系统性上偏;
%     * 掩盖极性反接: adc.m 对负输入是"截底到码 0 + OUT_OF_RANGE", 取 abs 之后
%       这条保护永远不会被触发, 反接看起来一切正常。
%   现在: 在信号极性的正方向找极值 (sgn 由 filters.m 的 hsign 给出), 结果带符号;
%   同时把"反方向过冲超过主峰"标记出来 (anom) 供审计 —— 弹道/基线异常的信号。
%   数值说明: 对 hsign=+1 且信号占优的事件, 本函数与 max(abs(v)) 完全同值
%   (实测 |过冲|/峰 = 0.1367 < 1), 差异只出现在噪声主导的波形上, 那正是修的对象。
if nargin < 2 || isempty(sgn), sgn = 1; end
sgn = double(sgn);
if ~(sgn == 1 || sgn == -1)
    error("tepc:elec:BadPolarity","sgn 只能是 +1 或 -1 (成形链极性), 实得 %g", sgn);
end
sv = sgn * double(v(:));
[pk, ipk] = max(sv);
pk = sgn * pk;                                   % 带符号主峰
oppositeMag = -min(sv);                          % 反方向最大偏离 (>=0)
if nargout > 2
    anom = oppositeMag > abs(pk);                % 反极性过冲盖过主峰 => 波形异常
end
end
