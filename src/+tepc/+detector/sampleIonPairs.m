function [N, meta] = sampleIonPairs(Edep_keV, W_eV, F, rs)
%SAMPLEIONPAIRS 单一涨落采样器（禁止 Poisson 与 Fano 双重叠加）。
%   mu = Edep*1000/W_eV。
%   mu < 50  : Poisson 采样 (Knuth 逆变换, 自实现, 无 Statistics Toolbox 依赖)。
%   mu >= 50 : 高斯 Fano 近似 N ~ round(Normal(mu, sqrt(F*mu)))。
%   meta 记录两条分支的计数与截断率。无实验复合 PMF 时, 小信号分支
%   的 Poisson 是保守默认(方差>=Fano), 标签写入元数据。

if nargin < 4, rs = RandStream('Threefry'); end
Edep_keV = double(Edep_keV(:));
mu = Edep_keV * 1e3 / W_eV;
N = zeros(size(mu));
small = mu < 50 & mu > 0;
large = mu >= 50;
% --- 小均值: Poisson (Knuth) ---
for k = find(small).'
    L = exp(-mu(k)); p = 1; cnt = 0;
    while p > L
        p = p * rand(rs, 1);
        cnt = cnt + 1;
        if cnt > 1000, break; end      % 安全阀(mu<50 理论不会触到)
    end
    N(k) = cnt - 1;
end
% --- 大均值: Gaussian-Fano ---
if any(large)
    x = mu(large) + sqrt(F .* mu(large)) .* randn(rs, nnz(large), 1);
    N(large) = max(0, round(x));
end
meta = struct('smallModel', "Poisson", 'largeModel', "GaussianFano", ...
    'F', F, 'W_eV', W_eV, 'smallCount', nnz(small), 'largeCount', nnz(large), ...
    'gaussianTruncation', mean(N(large) == 0), ...
    'note', "小信号分支为保守默认; 若有复合 PMF 数据请替换 compoundIonModel");
end
