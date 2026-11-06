function [S, inDomain] = stopAt(T, E_MeV, opts)
%STOPAT 阻止本领对数-对数插值 + 域守卫（域外直接报错, 禁止外推）。
%   opts.mode: "error"(默认, 域外抛错) | "flag"(返回 inDomain=false, S=NaN)。
%   E_MeV 可为向量。log-log 线性插值在幂律段误差 <<1%。

if nargin < 3, opts = struct(); end
if ~isfield(opts,'mode'), opts.mode = "error"; end
E = double(E_MeV(:));
inDomain = E >= T.E(1) & E <= T.E(end);
switch opts.mode
    case "error"
        if any(~inDomain)
            error("tepc:stopping:OutOfRange", ...
                "能量 %.4g MeV 超出阻止本领表域 [%.4g, %.4g] MeV — 禁止外推", ...
                min(E(~inDomain)), T.E(1), T.E(end));
        end
    case "flag"
        % 调用方自行处理
    otherwise
        error("tepc:stopping:BadMode","未知模式 %s", char(opts.mode));
end
% log 栅格构造时保证均匀(logspace), 用 O(1) 索引插值替代 interp1(逐次调用开销大)
if isfield(T,'lgEtab')
    lgE = T.lgEtab; lgS = T.lgStab; d1 = T.d1tab;
else
    lgE = log(T.E); lgS = log(T.S_mass); d1 = lgE(2) - lgE(1);
end
le = log(E);
t = (le - lgE(1))/d1;                        % 连续索引: t=0 -> E(1), t=1 -> E(2)
i0 = floor(t) + 1;                           % 左样本
i0 = min(max(i0, 1), numel(T.E)-1);
w = t - (i0 - 1);
S = exp(lgS(i0) .* (1-w) + lgS(i0+1) .* w);
S = S(:);
S(~inDomain) = NaN;
end
