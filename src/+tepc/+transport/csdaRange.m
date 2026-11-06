function out = csdaRange(T, E_MeV)
%CSDARANGE 从阻止本领表积分 CSDA 连续 slowing-down 射程。
%   R = int_0^E dE' / S_mass(E')   [g/cm^2]  (S_mass 单位 MeV cm2/g)
%   再按密度换算成线射程。表只覆盖 [T.E(1), T.E(end)], 因此:
%     - E 高于表上限: 返回 truncated=true 且结果只积到表上限 (不外推);
%     - E 低于或等于表下限: 用表下限的 S 作残差段 (保守) 并同样标 truncated;
%   积分用**梯形于 log 栅格上**的自适应求积, 对 1/S 的快速变化足够稳。
%   返回 out.range_g_cm2, out.range_mm(rho), out.truncated, out.E_max_used

if nargin < 2, error("tepc:range:BadInput","需要 T 与能量"); end
Eg = T.E(:).';  S = T.S_mass(:).';
if any(~isfinite(S)) || any(S <= 0) || numel(Eg) < 3
    error("tepc:range:BadTable","阻止本领表必须为有限正值且至少 3 个栅格点");
end
if ~all(diff(Eg) > 0), error("tepc:range:NotMonotone","能量栅格必须严格递增"); end

res = zeros(numel(E_MeV), 1);
trunc = false(size(res));
Emax = Eg(end); Emin = Eg(1);
for i = 1:numel(E_MeV)
    E = E_MeV(i);
    if ~(isfinite(E) && E > 0)
        res(i) = 0; trunc(i) = ~isfinite(E); continue;
    end
    Ehi = min(E, Emax);
    if E > Emax, trunc(i) = true; end
    % 表下限及其以下只有残差段可积: 用下限 S 保守积分。
    % 这一支必须排在积分**之前** —— E 恰等于下限时下面的 grid 会塌成 1 个点,
    % trapz 对标量直接报"维度参数必须是正整数", 而参考表的首行常常就是那个下限值。
    if Ehi <= Emin
        res(i) = Ehi / max(S(1), realmin); trunc(i) = true; continue;
    end
    % 栅格内插值点 + 栅格点一起积分
    inside = Eg(Eg > Emin & Eg < Ehi);
    grid = unique([Emin, inside(:).', Ehi]);
    Sj = interp1(Eg, S, grid, 'linear', 'extrap');
    Sj = max(Sj, realmin);
    r = trapz(grid, 1./Sj);
    res(i) = r;
end
out = struct();
out.n_truncated = nnz(trunc);          % 被表上/下限截断的点数 (不得无人读)
out.domain_MeV = [Emin, Emax];
out.range_g_cm2 = res;
out.truncated = trunc;
out.E_max_used = min(E_MeV(:), Emax);
rho = 1.0;
if isfield(T, 'rho_g_cm3') && ~isempty(T.rho_g_cm3) && T.rho_g_cm3 > 0
    rho = T.rho_g_cm3;
end
out.rho_g_cm3 = rho;
out.range_mm = res / rho * 10;                 % g/cm2 -> cm -> mm
out.range_cm = res / rho;
end
