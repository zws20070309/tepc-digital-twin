function out = bootstrapSpectrum(epsilon_keV, lbar_um, w, edges, B, rs)
%BOOTSTRAPSPECTRUM 事件级 bootstrap (计数统计为 A 类)。
%   重采样事件索引(带权不放回无意义, 用放回重采样), B 次, 输出 yF/yD 分位置区间。
%   注意: 只适用于独立非负权重; 负权重在 buildSpectrum 已拒绝。

y = epsilon_keV(:) / lbar_um;
ok = isfinite(y) & y > 0 & isfinite(w) & w > 0;
yv = y(ok); wv = w(ok);
n = numel(yv);
yFs = zeros(B,1); yDs = zeros(B,1);
for b = 1:B
    idx = randi(rs, n, n, 1);
    yb = yv(idx); wb = wv(idx);
    yFs(b) = sum(wb.*yb)/sum(wb);
    yDs(b) = sum(wb.*yb.^2)/sum(wb.*yb);
end
out = struct('yF_mean', mean(yFs), 'yF_sd', std(yFs), ...
    'yD_mean', mean(yDs), 'yD_sd', std(yDs), ...
    'yF_CI95', quantileCI(yFs), 'yD_CI95', quantileCI(yDs), ...
    'B', B, 'nEvents', n);
end

function q = quantileCI(x)
x = sort(x);
n = numel(x);
q = [x(max(1,round(0.025*n))), x(max(1,round(0.975*n)))];
end
