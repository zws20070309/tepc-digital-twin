function cal = fitChargeInjection(Qin_C, adcCode, opts)
%FITCHARGEINJECTION 电荷注入标定 (>=5 个不同注入点, 覆盖 0.1/1/10/50/90% 满量程)。
%   拟合 adc = a0 + a1·Q (+ a2·Q² 若残差有曲率, opts.quadratic);
%   返回系数与协方差(高斯-牛顿/正规方程), 拟合域 = 注入范围(域外反演拒绝)。
%   opts.FS_code: ADC 满量程码 (默认由 opts.bits)。

if nargin < 3, opts = struct(); end
if ~isfield(opts,'bits'), opts.bits = 14; end
FS = 2^opts.bits;                                  % 合法码数 (码域 0..FS-1)
Q = Qin_C(:); y = double(adcCode(:));
if numel(Q) ~= numel(y)
    error("tepc:cal:Length","注入点数 (%) 与码数 (%) 不一致", numel(Q), numel(y));
end
if any(~isfinite(Q)) || any(~isfinite(y))
    error("tepc:cal:NotFinite","注入数据含 NaN/Inf");
end
if any(Q < 0)
    error("tepc:cal:BadCharge","注入电荷必须非负");
end
nPts = numel(unique(Q));
if nPts < 5
    error("tepc:cal:NTooSmall","电荷注入至少需要 5 个不同注入点, 实得 %d", nPts);
end
if numel(Q) < 5*nPts
    error("tepc:cal:NTooSmall","每个注入点需要足够重复样本以压噪声");
end
useQuad = isfield(opts,'quadratic') && opts.quadratic;
% 尺度归一防病态: Q ~ 1e-15 C 量级, 直接拟合 X=[1,Q] 条件数爆炸。
Qref = max(abs(Q)); if Qref <= 0, Qref = 1; end
Qn = Q/Qref;
if useQuad
    X = [ones(size(Qn)), Qn, Qn.^2];
else
    X = [ones(size(Qn)), Qn];
end
betaN = X \ y;
res = y - X*betaN;
dof = numel(y) - size(X,2);
sigma2 = (res'*res)/max(dof,1);
covN = sigma2 * (X'*X) \ eye(size(X,2));
% 还原到 C 单位: y = b0 + b1*(Q/Qref) => a1 = b1/Qref
if useQuad
    beta = [betaN(1); betaN(2)/Qref; betaN(3)/Qref^2];
    J = diag([1, 1/Qref, 1/Qref^2]);
else
    beta = [betaN(1); betaN(2)/Qref];
    J = diag([1, 1/Qref]);
end
covB = J * covN * J;
cal = struct('beta', beta, 'cov', covB, 'sigma_res', sqrt(sigma2), ...
    'domain_C', [min(Q), max(Q)], 'quadratic', useQuad, 'FS_code', FS, ...
    'nPoints', numel(Q), 'Qref_C', Qref);
% 单调性检查 (标定曲线必须单调)
Qg = linspace(min(Q), max(Q), 200)';
if useQuad
    yg = [ones(200,1), Qg/Qref, (Qg/Qref).^2]*beta;
else
    yg = [ones(200,1), Qg/Qref]*beta;
end
if any(diff(yg) < 0)
    warning("tepc:cal:NonMonotonic","标定曲线非单调, 检查注入数据");
end
end
