function w = pulseOccupancy_s(cfg)
%PULSEOCCUPANCY_S 脉冲占用 DAQ 的宽度 [s] —— pile-up 判据窗口的**唯一**真相源。
%   物理定义: 第二个事件若落在前一个脉冲"仍被采集/成形"的窗内, 两脉冲在 ADC 上
%   叠加成一个不可分割的码 —— 这就是 pile-up。因此这个窗由**成形链的波窗**决定,
%   与死时间常数 tau 无关 (tau 是"恢复期", 波窗是"占用期")。
%
%   为什么不能直接吃 cfg.electronics.trigger.pileUpReject_s:
%   发货值 pileUpReject_s=3 µs **小于** deadTime_s=10 µs, 于是 busy 窗总是先关闭,
%   任何"落在上一个脉冲内"的到达必然先被判成 deadtime —— PILEUP 分支在生产配置下
%   永不可达, "堆叠脉冲清零权重"整条决策链就成了死代码 (审计发现, 实测确认:
%   5000 事件的 demo run 里 PILEUP 计数恒为 0)。取波窗与显式配置里的较大者:
%   配置值只能**加长**占用窗, 不能缩短物理占用。
%
%   消费方: tepc.run.execute (DAQ 状态机)、tepc.electronics.propagateMC (UQ 复刻同
%   一台仪器)、tepc.config.validate (配置自洽核对)。
w = tepc.electronics.waveTailTau() * cfg.electronics.shaping_s;   % 与 ramoWaveform 的拖尾截断同源
if isfield(cfg.electronics, 'waveWindow_s') && ~isempty(cfg.electronics.waveWindow_s)
    w = cfg.electronics.waveWindow_s;
end
pu = NaN;
if isfield(cfg.electronics, 'trigger') && isfield(cfg.electronics.trigger, 'pileUpReject_s')
    pu = cfg.electronics.trigger.pileUpReject_s;
end
if isnumeric(pu) && isscalar(pu) && isfinite(pu) && pu > 0
    w = max(w, pu);
end
if ~(w > 0)
    error("tepc:elec:BadPulseWidth", "脉冲占用宽度必须为正, 实得 %g", w);
end
end
