function [code, flags, meta] = adc(v, cfg)
%ADC 量化 + INL + 饱和 + 双量程。
%   两个量程各自占据同一码空间 [0, 2^bits-1], 由 RANGE2_ADC(512) 标志区分
%   (真实双量程数字化仪的做法); 跨量程不保证码连续, 量程内严格单调。
%     量程1: 0 <= vin < FS           code = floor(vin/LSB1)
%     量程2: FS <= vin < g2*FS       输入衰减 1/g2 后按原生 LSB 量化, 置 RANGE2
%     vin >= g2*FS                   码封顶 2^bits-1 且置 OVERFLOW_ADC(1) (不外推)
%   量程判决用**未经 INL 修正**的输入 vv: 修正量把 vin 越过 FS 的点下移约
%   inl*LSB1, 而量程 2 的等效码按 g2 取整, 二者叠加会在边界产生最大 (g2-1) 码
%   的回退 (实测 v=FS 处 x: 16383 -> 16352), 破坏"等效码对输入电压单调"。
%   v 为 NaN/Inf 或非有限 -> code = 2^bits-1 + OUT_OF_RANGE(256) + OVERFLOW_ADC。
%   INL: inl_lsb*(v/FS)^2*LSB 单调弓形 (确定性模型)。
%   返回 int32 code, uint32 flags, meta(LSB_V, range, fullScale_code)。
%   cfg 必填: 量程 2 上限 = range2Gain × fullScale_V, 它必须盖住反冲质子的峰 (FS=2 V 时
%   峰值 ~35 V 要求 range2Gain ≥ 18)。这个数一旦在代码里再存一份兜底, 少传参数的调用就会
%   静默拿到另一套仪器参数并削顶, 所以量化参数只允许有配置一处来源。

bits = cfg.electronics.adc.bits;
FS   = cfg.electronics.adc.fullScale_V;
LSB1 = FS/2^bits;
inl  = cfg.electronics.adc.inl_lsb;
g2raw = cfg.electronics.adc.range2Gain;
% 缺位或 <1 会让量程 2 塌回量程 1: 反冲质子的峰被削顶, 而返回值里不留任何痕迹。
% 按头注释这个数只允许有配置一处来源, 所以判错而不是替调用方补一个 1。
if isempty(g2raw) || ~isnumeric(g2raw) || ~isscalar(g2raw) || ~isfinite(g2raw) || g2raw < 1
    error('tepc:adc:BadRange2Gain', ...
        'electronics.adc.range2Gain 必须是有限的 >=1 标量 (收到 %s, %d 个元素)', ...
        class(g2raw), numel(g2raw));
end
g2 = double(g2raw);
CODEMAX = int32(2^bits - 1);

F = tepc.domain.Flags();
v = double(v(:));
flags = zeros(size(v), 'uint32');
code  = zeros(size(v), 'int32');
meta  = struct('LSB_V', LSB1, 'range', ones(size(v), 'uint8'), ...
    'fullScale_code', 2^bits, 'FS_V', FS, 'range2Gain', g2);

bad = ~isfinite(v);
flags(bad) = bitor(flags(bad), F.OUT_OF_RANGE);
flags(bad) = bitor(flags(bad), F.OVERFLOW_ADC);
code(bad)  = CODEMAX;

vv = v;  vv(bad) = 0;                         % 非有限值单独处理, 其余按 0 兜底
neg = vv < 0;
vv(neg) = 0;                                   % 负输入截底到码 0 (不产生回绕)
flags(neg) = bitor(flags(neg), F.OUT_OF_RANGE);

vin = vv + inl*LSB1*(vv/FS).^2;                % 单调 INL 等效输入
% 非有限输入已在上面单独封顶, 这里必须把它们从所有分支排除 —— 否则 vv(bad)=0
% 会让 bad 落进量程 1 分支, 把 CODEMAX 覆写成码 0 (实测 NaN 输入得到码 0)。
inR1 = (vv < FS) & ~bad;                       % 量程判决: 未修正输入
inR2 = ~(vv < FS) & (vin < g2*FS) & ~bad;
ovf  = ~(vv < FS) & ~(vin < g2*FS) & ~bad;

code(inR1) = min(int32(floor(vin(inR1)/LSB1)), CODEMAX);
if any(inR2)
    vr2 = vv(inR2)/g2;
    vin2 = vr2 + inl*LSB1*(vr2/FS).^2;
    code(inR2) = min(int32(floor(vin2/LSB1)), CODEMAX);
    flags(inR2) = bitor(flags(inR2), F.RANGE2_ADC);
    meta.range(inR2) = 2;
end
if any(ovf)
    code(ovf) = CODEMAX;
    flags(ovf) = bitor(flags(ovf), F.OVERFLOW_ADC);
end
code = max(code, int32(0));
end
