function [Ee_MeV, Egamma_MeV, costheta] = comptonKN(E0_MeV, N, rs)
%COMPTONKN Klein-Nishina 康普顿电子能量抽样（逆 CDF, 单色入射）。
%   d(sigma)/dE' ~ (E'/E0 + E0/E' - sin^2theta), 单位反冲电子能量 Ee = E0-E'。
%   守恒关系(测试锁定): cos(theta) = 1 - mec2*(1/E' - 1/E0) 精确成立。
%   返回: Ee_MeV (Nx1), Egamma_MeV (Nx1 散射光子), costheta (Nx1)。

mec2 = 0.510998950; % MeV
E0 = E0_MeV;
if E0 <= mec2/2*1e-6
    error("tepc:compton:LowEnergy","康普顿模型不适用于 %.4g MeV", E0);
end
% 散射光子能量域: [mec2/2 * 1/(1+2*E0/mec2)?  反冲极限: E'_min = E0/(1+2*E0/mec2)
Epmin = E0/(1 + 2*E0/mec2);
Ep = linspace(Epmin, E0, 20001).';            % 散射光子能量栅格
costh = 1 - mec2.*(1./Ep - 1/E0);
costh = min(max(costh,-1),1);
sin2 = 1 - costh.^2;
r = Ep/E0;
% d(sigma)/dOmega = (r0^2/2) r^2 [r + 1/r - sin^2]; dE'/dcos = alpha*E'^2/E0
% => r^2 被态密度 Jacobian 精确抵消, d(sigma)/dE' ~ [r + 1/r - sin^2]
pdf = r + 1./r - sin2;                        % ~ d(sigma)/dEp (任意常数)
cdf = cumtrapz(Ep, pdf);
cdf = cdf / cdf(end);
u = rand(rs, N, 1);
Egamma_MeV = interp1(cdf, Ep, u, 'linear', 'extrap');  % cdf 单调
Egamma_MeV = min(max(Egamma_MeV, Epmin), E0);
costheta = 1 - mec2.*(1./Egamma_MeV - 1/E0);
Ee_MeV = E0 - Egamma_MeV;
end
