function out = compareSpectra(S1, S2)
%COMPARESPECTRA 谱-谱比较 (独立核查层): bin 级相对差 + yF/yD 差。
%   S1/S2: buildSpectrum 输出 (相同 edges)。返回 chi2 加权距离与最大相对差。

if ~isequal(S1.edges, S2.edges)
    error("tepc:compare:Edges","两谱 bin 边界不一致, 不可直接比较");
end
use = S1.counts_weight > 0 & S2.counts_weight > 0;
f1 = S1.f(use); f2 = S2.f(use);
sig = sqrt(S1.sigma_f(use).^2 + S2.sigma_f(use).^2);
sig = sig(:);
sig(sig <= 0) = eps;
z = (f1 - f2) ./ sig;
out = struct('chi2_per_dof', mean(z.^2), 'nBinsUsed', nnz(use), ...
    'maxRelDiff_f', max(abs(f1 - f2) ./ max(abs(f1) + abs(f2), eps)), ...
    'relDiff_yF', abs(S1.yF_exact - S2.yF_exact)/max(S1.yF_exact, eps), ...
    'relDiff_yD', abs(S1.yD_exact - S2.yD_exact)/max(S1.yD_exact, eps), ...
    'note', 'chi2 按每 bin 统计不确定度加权; 模型差异另入 UQ');
end
