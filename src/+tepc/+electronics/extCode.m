function x = extCode(code, range, bits, g2)
%EXTCODE 双量程 ADC 的"等效满量程码" (对输入电压线性且跨量程连续)。
%   量程 1: x = code           (1 LSB = LSB1 = FS/2^bits)
%   量程 2: x = code * g2      (衰减 g2 后量化, 故 1 LSB = g2*LSB1)
%   这样 x ~= vin/LSB1 对两个量程同斜率, 边界处连续 (code=FS/LSB1 处 x 相接),
%   因此一条直线即可标定; 量程 2 的分辨率低 g2 倍是真实物理, 由 INL/量化噪声体现。
%   注意: 不可用"码空间平移" (+2^bits) —— 那会在量程边界产生 g2 倍斜率跳变,
%   直线拟合会得到巨大正截距, 使所有低能事件的 Q 反演为负而被判域外 (实测)。
%   未触发/无效码 (<0) 保留为 -1, 由调用方判为域外。
if nargin < 4 || isempty(g2), g2 = 1; end
c = double(code(:));
r = double(range(:));
if numel(r) == 1 && numel(c) ~= 1, r = repmat(r, size(c)); end
if numel(c) ~= numel(r)
    error("tepc:adc:ExtCodeLen","code 与 range 长度不一致 (%d vs %d)", numel(c), numel(r));
end
x = c .* (1 + (r - 1)*(g2 - 1));
x(c < 0) = -1;
end
