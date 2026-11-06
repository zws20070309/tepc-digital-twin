function n = waveTailTau()
%WAVETAILTAU 波形拖尾截断倍数 (以成形时间常数 tau 为单位) —— 单一定义处。
%   消费方: filters 的收集窗 Nwin 与冲激响应长度、Simulink 对照的单脉冲窗、
%   pulseOccupancy_s 缺 waveWindow_s 时的兜底、ramoWaveform 的拖尾截断。
%   这几处取的是同一个物理判断 ("等多少个成形常数算脉冲结束"), 分开写就成了
%   四份可以互相漂移的真相; 改这里会同时改 Nwin -> 冲激响应长度 -> 噪声标定的
%   蒙特卡洛窗 -> sigma_peak_V -> 能谱, 是一条单向传导链, 不是逐项核对。
%   显式配置 waveWindow_s 仍然优先: 配置只能加长占用窗, 不能缩短物理占用。
n = 12;
end
