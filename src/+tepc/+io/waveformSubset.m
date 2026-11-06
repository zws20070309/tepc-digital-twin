function ids = waveformSubset(seed, nSub, nHorizon)
%WAVEFORMSUBSET 波形持久化的事件子集选择: 只由 (seed, nSub) 与候选上界决定。
%   ids = waveformSubset(seed, nSub, nHorizon) 返回升序、互不相同的 event_id 列向量。
%   口径: 每个候选事件号 i 取一个只依赖 (seed, i) 的优先级 u_i (Threefry 子流按 i 锚定),
%     取 u 最小的 min(nSub, nHorizon) 个 i。于是
%       * 与调用顺序、分块大小、续跑历史、运行链的共享 RandStream 状态**全部无关**
%         —— 本函数只用自己新建的那条流, 不取用全局 RandStream 也不接收外部流,
%           因此"选了哪些事件"不会扰动事件本身的随机序列;
%       * 同一 seed 下 nSub 变大只可能**新增**事件而不可能换掉已选事件 (嵌套性:
%         优先级 u_i 只依赖 (seed, i), 与取多少个无关),
%         换 nSub 不会把上一次已落盘的事件换走 —— 与"续跑/多跑几个事件"的语义相容;
%       * 唯一依赖 nHorizon 的地方是"候选范围": 事件总数之外的号根本不存在, 而只要
%         nHorizon >= max(ids), 结果就与 nHorizon 的具体取值无关。
%   平手按事件号升序取 (sortrows 的双键排序), 因此选择是纯函数, 不依赖排序算法的不确定性。
%   边界: nSub<=0 或 nHorizon<=0 给空集; nSub>nHorizon 时取全部 (不报错, 因为
%   "把每个事件都存下来"是合法诉求)。非数值/非有限的实参一律报错, 不静默给空集 ——
%   空集会让"这次没落波形"看起来像"跑了但没选到事件"。
if ~isnumScalar(seed) || ~isnumScalar(nSub) || ~isnumScalar(nHorizon)
    error("tepc:io:WaveformSubsetArgs", ...
        "三个实参都必须是有限的数值标量 (seed=%s nSub=%s nHorizon=%s)", ...
        class(seed), class(nSub), class(nHorizon));
end
if ~isfinite(seed) || ~isfinite(nSub) || ~isfinite(nHorizon)
    error("tepc:io:WaveformSubsetArgs", "seed/nSub/nHorizon 必须是有限值 (实得 NaN 或 Inf)");
end
nH = max(0, round(double(nHorizon)));
nK = max(0, round(double(nSub)));
if nH == 0 || nK == 0
    ids = zeros(0, 1);
    return
end
nK = min(nK, nH);
sd = max(0, round(double(seed)));
rs = RandStream('Threefry', 'Seed', sd);
u = zeros(nH, 1);
for i = 1:nH
    rs.Substream = i;         % 优先级只由 (seed, i) 决定, 与已消耗的次数无关
    u(i) = rand(rs);
end
o = sortrows([u, (1:nH).'], [1 2]);
ids = sort(o(1:nK, 2), 'ascend');
end

function tf = isnumScalar(v)
%ISNUMSCALAR 数值标量判定 (逻辑型单独排除: true/false 会被 double() 伪装成 1/0 个事件)。
tf = isnumeric(v) && ~islogical(v) && isscalar(v);
end
