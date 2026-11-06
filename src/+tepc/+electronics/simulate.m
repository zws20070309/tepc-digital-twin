function [q, instr, aux] = simulate(Edep_keV, evIdx, cfg, rs, ctx)
%SIMULATE 逐事件仪器链: 电离对 -> 雪崩增益 -> Ramo 感应电流时序
%   -> CSA/PZ/CR/RC 成形 -> 串联噪声 -> 峰值/触发时刻 -> 双量程 ADC。
%   L0 电离对:  tepc.detector.sampleIonPairs (Fano 涨落, 单一采样器)。
%   L2 增益:    Diethorn 均值 + Polya(theta) 逐事件涨落。
%   L1 波形:    tepc.detector.ramoWaveform 给出感应电流时序, 经 filters 的
%               一阶节级联 (与 Simulink 同一系数) 成形 => 真正的仪器响应。
%               限制 (必须知道): 雪崩起点 r0 对**所有事件取同一 ASSUMED 值**
%               (ctx.r0_m), 所以弹道亏损是一个确定均值 (由电荷注入刻度吸收),
%               不含真实存在的"电离对径向位置 -> 收集时间分散 -> 峰幅展宽";
%               instr.r0_m 因此是常数列, 不代表逐事件抽样。
%   RNG 纪律:   每事件独立 Threefry 子流 (Seed=ctx.seed+1, Substream=eventID),
%               抽样与分块大小/续跑/并行完全无关 (可复现性按事件锚定)。
%   ctx 必填:   W_eV, fano, G_mean, theta, field, mob, coeffs, noiseSigma, seed。
%               G_mean 由调用方 (execute/resolve) 计算一次并传入 —— 若在此处
%               惰性计算会因值类语义丢失, 且会消耗共享 rs (分块依赖性)。
%   返回: q [C], instr(peak_V, adc_code, flags, t_trigger_s, range, r0_m), aux。

F = tepc.domain.Flags();
Edep_keV = double(Edep_keV(:));
n = numel(Edep_keV);
req = {'W_eV','fano','G_mean','theta','field','mob','coeffs','noiseSigma','seed','r0_m'};
for i = 1:numel(req)
    if ~isfield(ctx, req{i})
        error("tepc:elec:BadCtx","ctx 缺少 %s (仪器链要求显式上下文)", req{i});
    end
end

c   = ctx.coeffs;
Ts  = c.Ts;
sos = c.sos;
nSect = size(sos, 1);
thr  = cfg.electronics.trigger.threshold_V;
hyst = cfg.electronics.trigger.hysteresis_V;
puWin = tepc.electronics.pulseOccupancy_s(cfg);   % 单一真相源 (与 execute/UQ 同窗)
aR = ctx.field.a; bR = ctx.field.b;
if ~(bR > aR && aR > 0), error("tepc:elec:BadField","需要 0<a<b"); end
if ~(ctx.r0_m > aR && ctx.r0_m < bR)
    error("tepc:elec:BadR0","ctx.r0_m=%.3e 必须在 (%.3e,%.3e) 内", ctx.r0_m, aR, bR);
end

q        = zeros(n,1);
peak     = zeros(n,1);
code     = zeros(n,1,'int32');
flags    = zeros(n,1,'uint32');
range    = ones(n,1,'uint8');
tTrig    = zeros(n,1);
blRms    = nan(n,1);      % 逐事件基线 RMS (脉冲窗外的拖尾段, 见循环内注释)
r0v      = zeros(n,1);
Npairs   = zeros(n,1);
Gev      = zeros(n,1);
waveform = [];
% 噪声幅度旋钮 (UQ 用) 与 ctx.noiseSigma 的一致性参考值 —— 每次调用只算一次。
noiseScale = 1;
if isfield(ctx,'noiseScale') && ~isempty(ctx.noiseScale)
    noiseScale = double(ctx.noiseScale);
    if ~(isfinite(noiseScale) && noiseScale >= 0)
        error("tepc:elec:BadNoiseScale","ctx.noiseScale 必须是非负有限标量, 实得 %g", noiseScale);
    end
end
noiseRef = NaN;
try
    [~, msigRef] = tepc.electronics.noise(0, cfg, ...
        RandStream('Threefry','Seed', ctx.seed + 1), "sigma");
    noiseRef = msigRef.sigma_peak_V;
catch
end   % 算不出参考值时跳过核对 (不因诊断本身让测量链失败)

% --- sampled 模式的两个常数因子 (与分块/事件数无关, 因此可预先算) ---
ctx.startMode = "fixed";
if isfield(cfg,'detector') && isfield(cfg.detector,'avalancheStartMode')
    ctx.startMode = lower(string(cfg.detector.avalancheStartMode));
end
if isfield(cfg,'detector') && isfield(cfg.detector,'startPositionJitter')
    ctx.startJitter = double(cfg.detector.startPositionJitter);
else
    ctx.startJitter = 0;
end
if ~any(ctx.startMode == ["fixed","sampled"])
    error("tepc:elec:BadStartMode","detector.avalancheStartMode 只允许 fixed|sampled, 实得 %s", char(ctx.startMode));
end
if ~(isfinite(ctx.startJitter) && ctx.startJitter >= 0 && ctx.startJitter < 1)
    error("tepc:elec:BadStartJitter","detector.startPositionJitter 必须在 [0,1), 实得 %g", ctx.startJitter);
end
fmS = tepc.detector.fieldOf(ctx.field, aR, bR, ctx.field.hv_V, tepc.detector.fieldKindOf(ctx.field));
dV = cfg.detector.diethorn_deltaV_V.value;
% 雪崩起点的 (a,b) 钳位系数来自注册表: 与 resolve/avalanche/validate 同值,
% 否则"同一几何、三套增益"的分歧又会回来 (注册表里 wired=true 由测试反查)。
rLoF = tepc.config.constants('detector.avalanche.rStartClampLowerFracOfA');
rUpF = tepc.config.constants('detector.avalanche.rStartClampUpperFracOfB');
% gainExpK 是历史诊断字段 (全仓无读取点): 它的定义依赖闭式 K=1/ln(b/a),
% 而 field.mode='fem_map' 下 K 无对应物 -> NaN, 谁要消费它必须先补场图口径的定义。
ctx.gainExpK = log(2)/dV * ctx.field.hv_V * fmS.K;      % G(r0) = exp(k·∫E dr 的归一化形式)
ctx.gainCond = 1;
if ctx.startMode == "sampled" && ctx.startJitter > 0
    % 条件化因子 E[G(r0)]/G(r0_nom) 用 21 点 Gauss-Hermite 求 (对数正态抽样),
    % 对 p=2 (∝ln r0) 与 p=3 (∝1/a-1/r0) 都成立 —— 闭式只对柱对称成立, 这里不偷懒。
    [zgh, wgh] = gaussHermite(21);
    s = ctx.startJitter;
    num = 0; den = 0;
    for i = 1:numel(zgh)
        rS = min(max(ctx.r0_m*exp(s*zgh(i)), aR*rLoF), bR*rUpF);
        rel = exp((log(2)/dV) * (fmS.intE(aR, rS) - fmS.intE(aR, ctx.r0_m)));
        num = num + wgh(i)*rel;  den = den + wgh(i);
    end
    ctx.gainCond = den/max(num, eps);        % 乘上去把均值拉回名义 G_mean
end

for k = 1:n
    eid = evIdx + k - 1;
    rsE = RandStream('Threefry', 'Seed', ctx.seed + 1);
    rsE.Substream = eid;                       % 每事件子流: 与分块无关
    [Nk, mk] = tepc.detector.sampleIonPairs(Edep_keV(k), ctx.W_eV, ctx.fano, rsE);
    % --- 雪崩起点 ---
    % fixed   : 所有事件共用 ctx.r0_m (回归模式, 与历史逐位一致);
    % sampled : 每事件抽 ln(r0), 增益随之逐事件变化 —— 因为
    %           G(r0) = exp((ln2/ΔV)·V·K·ln(r0/a)) ∝ (r0/a)^kk, r0 翻倍增益 ×4.4,
    %           **远大于**收集时间/弹道亏损效应。只抽位置而冻结增益是自相矛盾的。
    % 均值条件化: 若 ln(r0/r0_nom) ~ N(0, s²), 则 E[G] = G_nom·exp(kk²s²/2) ——
    % 闭式因子, 与分块/事件数无关 (用批内均值归一会破坏分块无关性, 已避免)。
    r0 = ctx.r0_m;
    gpos = 1;
    if ctx.startMode == "sampled"
        z = randn(rsE);
        r0 = ctx.r0_m * exp(ctx.startJitter * z);
        r0 = min(max(r0, aR*(1+1e-3)), bR*(1-1e-3));
        gpos = exp((log(2)/dV) * (fmS.intE(aR, r0) - fmS.intE(aR, ctx.r0_m)));
    end
    gk = polyaGain(ctx.G_mean * ctx.gainCond * gpos, ctx.theta, rsE);
    qk = Nk * 1.602176634e-19 * gk;
    Npairs(k) = Nk; Gev(k) = gk; q(k) = qk;
    r0v(k) = r0;
    wv = tepc.detector.ramoWaveform(qk, r0, ctx.field, ctx.mob, cfg);
    v = wv.dq;                                   % 每采样区间注入电荷 [C]
    for s = 1:nSect
        v = filter(sos{s,1}, sos{s,2}, v);
    end
    vnw = tepc.electronics.noise(numel(v), cfg, rsE, "waveform");
    vnw = filter(c.combinedV{1}, c.combinedV{2}, vnw);   % 串联噪声经后级整形
    % ctx.noiseSigma 在旧实现里**必填但无人读** —— 于是 UQ 对噪声的扰动
    % 是个静默空操作。现在: (a) 显式一致性核对 (配置改了而 ctx 没跟上就报错),
    % (b) 提供 ctx.noiseScale 作为可扰动的噪声幅度旋钮 (propagateMC 用它)。
    % 注意: noise() 的 sigma_peak_V 本身是用一条随机实现标定出来的**统计量**
    % (实测同一 cfg 换流会有 ~4% 差异), 所以这里只能是粗核对, 不能要求逐位相等 ——
    % 我第一版要求 1e-9 相对一致, 立刻误报。25% 的窗口足够抓住"拿了另一套配置的
    % sigma"这类粗错, 又不会被统计噪声触发。
    if isfinite(noiseRef) && abs(noiseRef) > 0 && isfinite(ctx.noiseSigma) ...
            && ctx.noiseSigma > 0
        relSig = abs(ctx.noiseSigma/noiseRef - 1);
        if relSig > 0.25
            error("tepc:elec:StaleNoiseSigma", ...
                "ctx.noiseSigma=%.6e 与由 cfg 现算的 %.6e 不一致 (相对差 %.2e): 刻度/上下文不同步", ...
                ctx.noiseSigma, noiseRef, relSig);
        end
    end
    vnw = vnw * noiseScale;
    v = v + vnw;
    % 带符号主峰 (peakSigned 是唯一实现, 刻度链与 Simulink 对照共用)。
    %   旧写法 max(abs(v)) 在**纯噪声波形**上是双侧整流: 零沉积事件的"峰"=max|noise|,
    %   阈值判据 pk<thr 因此失去单侧含义 (假符合概率翻倍, 近阈幅度上偏);
    %   且 adc.m 对负输入是"截底 0 + OUT_OF_RANGE", abs() 让极性反接永远不被发现。
    [pk, ipk, anom] = tepc.electronics.peakSigned(v, c.hsign);
    peak(k) = pk;
    tTrig(k) = ipk * Ts;
    % 形状异常只对**真的被触发的事件**有意义: 零沉积波形的"峰"就是噪声极值,
    % 反极性越界在那里约有一半概率发生, 于是无门槛地把它们计入 shape_anomaly_count
    % 统计的是"没有信号", 不是"波形形状可疑" (实测 P(反侧>正侧)≈0.5)。
    % 零沉积由 ZERO_DEP / UNDER_THRESHOLD 单独表达, 一个标志只说一件事。
    if anom && abs(pk) >= thr
        flags(k) = bitor(flags(k), F.WAVEFORM_SHAPE);   % 只标记, 不清零权重
    end
    % --- 基线 RMS (噪声地板必须是量出来的, 不是 NaN 占位) ---
    % 取**脉冲收集窗之外**的拖尾段: 那里只剩成形后的噪声尾巴, 正是真实 DAQ 估
    % 噪声地板用的"无信号区"。刻意不用配置里的名义 sigma —— 那只是把输入读一遍,
    % 不能发现链路上任何实现错误。样本不足 20 点时保持 NaN (不假装量到了)。
    tailIdx = (ipk + c.Nwin + 1):numel(v);
    if numel(tailIdx) >= 20
        vt = v(tailIdx);
        blRms(k) = sqrt(mean((vt - mean(vt)).^2));
    end
    if k == 1, waveform = v; end
    % 关键: 数字化与触发解耦。真实 DAQ 里 ADC 连续数字化每一样本, 阈值只决定
    % 该事件是否被"分析"。若阈下事件不产生码 (旧实现置 -1), 电荷注入刻度在
    % 低能端会被触发截断系统性抬高 (实测 1 keV 处反演偏高 7.96 倍, 且拟合
    % 截距被拉到 -754 码), 整个低能谱随之失真。
    % 阈值与量化都用**幅度**: 链本身的极性由 hsign 描述 (配置出来的负极性成形是合法
    % 设计, 不是故障), 而"波形形状异常"由上面的 WAVEFORM_SHAPE 负责发现。
    % peak_V 保留带符号值 —— 反接时它直接显为负, 不再被 abs 抹平。
    if abs(pk) < thr
        flags(k) = bitor(flags(k), F.UNDER_THRESHOLD);
    end
    [ck, fl, mm] = tepc.electronics.adc(abs(pk), cfg);
    code(k) = ck; flags(k) = bitor(flags(k), fl); range(k) = mm.range;
end

instr = struct('peak_V', peak, 'adc_code', code, 'flags', flags, ...
    't_trigger_s', tTrig, 'range', range, 'r0_m', r0v);
aux = struct('N_pairs', Npairs, 'G_event', Gev, 'G_mean', ctx.G_mean, ...
    'r0_m', r0v, 'waveform_first_event', waveform, 'pileUpWindow_s', puWin, ...
    'hysteresis_V', hyst, 'start_mode', ctx.startMode, ...
    'start_jitter', ctx.startJitter, 'gain_conditioning', ctx.gainCond, ...
    'gain_raw_mean_over_nominal', 1/max(ctx.gainCond, eps), ...
    'gain_raw_note', "两种口径同时给出: 条件化后 E[G]=G_nom (本链采用); 不条件化则 E[G]/G_nom=1/gainCond=exp(k^2 s^2/2)", ...
    'noise_scale', noiseScale, ...
    'baseline_rms_V', median(blRms, 'omitnan'), ...
    'baseline_rms_n_events', nnz(isfinite(blRms)), ...
    'baseline_rms_scope', "脉冲收集窗之外拖尾段的去均值 RMS (逐事件算, 报告取中位数)", ...
    'trigger_method', "shaped_waveform_signed_extremum (tepc.electronics.peakSigned, 极性与 hsign 一致)", ...
    'waveform_shape_count', nnz(bitand(flags, F.WAVEFORM_SHAPE) > 0));
end

function [z, w] = gaussHermite(n)
%GAUSSHERMITE 转调 tepc.electronics.gaussHermiteNodes (单一真相源)。
%   刻意不在这里重复实现: 位置展宽的条件化因子依赖这套节点, 而测试必须能核对
%   "链上实际用的节点", 而不是测试自己手抄一遍公式 (那样写出的断言永远为真)。
[z, w] = tepc.electronics.gaussHermiteNodes(n);
end

function g = polyaGain(Gmean, theta, rs)
% POLYAGAIN Polya(theta) 增益: Gamma(theta, mean/theta) (Marsaglia-Tsang)。
if Gmean <= 0, g = 0; return; end
d = theta - 1/3; c = 1/sqrt(9*d);
while true
    x = randn(rs); v = (1+c*x)^3;
    if v <= 0, continue; end
    u = rand(rs);
    if u < 1 - 0.0331*x^4, g = d*v*(Gmean/theta); return; end
    if log(u) < 0.5*x^2 + d*(1 - v + log(v)), g = d*v*(Gmean/theta); return; end
end
end
