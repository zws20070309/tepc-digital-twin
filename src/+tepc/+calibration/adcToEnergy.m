function [eps_keV, flags] = adcToEnergy(adcCode, cal, phys)
%ADCTOENERGY ADC 码 -> 沉积能 [keV] (域外返回 NaN+OUT_OF_RANGE, 不外推)。
%   反演: code -> Q [C] -> N_pairs = Q/(e*G) -> eps = N*W [eV] -> /1000 [keV]。
%   W 与增益必须在标定时冻结 (phys.W_eV, phys.G), 否则刻度与测量不自洽。
%   饱和码/域外/负码 -> NaN + OUT_OF_RANGE(256)。
%   单位说明: Q = N*e*G 故 Q*W/(e*G) = N*W 的单位是 eV; 必须除以 1e3 才是 keV。

F = tepc.domain.Flags();
eC = 1.602176634e-19;
flags = zeros(size(adcCode), 'uint32');
code = double(adcCode(:));
eps_keV = nan(size(code));

a0 = cal.beta(1); a1 = cal.beta(2);
if numel(cal.beta) >= 3, a2 = cal.beta(3); else, a2 = 0; end
if cal.quadratic
    % code = a0 + a1 Q + a2 Q^2 的正根 (牛顿/闭式皆可, 此处闭式取物理解支)
    disc = max(a1^2 + 4*a2.*(code - a0), 0);
    Q = (-a1 + sqrt(disc)) ./ (2*a2 + eps);
else
    Q = (code - a0)/a1;
end
% 满量程码: 合法码为 0..FS_code-1 (FS_code = 2^bits); 越界或饱和码为域外
valid = code >= 0 & code < cal.FS_code;
inDom = valid & Q >= cal.domain_C(1) & Q <= cal.domain_C(2);
eps_keV(inDom) = Q(inDom) * phys.W_eV / (eC * phys.G) / 1000;
flags(~inDom) = bitor(flags(~inDom), F.OUT_OF_RANGE);
eps_keV = eps_keV(:);
flags = flags(:);
end
