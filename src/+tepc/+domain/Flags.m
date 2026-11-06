function F = Flags()
%FLAGS 事件标志位定义 (uint32 位掩码)。
F.OVERFLOW_ADC        = uint32(1);      % ADC 满量程溢出
F.UNDER_THRESHOLD     = uint32(2);      % 未触发/阈下
F.PILEUP              = uint32(4);      % 事件时间重叠
F.DEADTIME_REJECTED   = uint32(8);      % 死时间拒绝
F.WALL_LOSS           = uint32(16);     % 次级带电粒子在壁内终止
F.ESCAPE              = uint32(32);     % 次级带电粒子携能逸出灵敏体
F.EDGE                = uint32(64);     % 端部几何截断
F.ZERO_DEP            = uint32(128);    % 零沉积(计入效率分母, 不入正 y 谱)
F.OUT_OF_RANGE        = uint32(256);    % 插值/标定域外
F.RANGE2_ADC          = uint32(512);    % 使用第二量程
F.SAT_CSA             = uint32(1024);   % 前放饱和
F.GAIN_SAT            = uint32(2048);   % 空间电荷增益压制触发
F.WAVEFORM_SHAPE      = uint32(4096);   % 反极性过冲盖过主峰: 波形形状异常 (审计标记)
F.SECONDARY_FROM_WALL = uint32(8192);   % 本次事件的次级带电粒子诞生在壁壳层内(不是气腔内)
end
