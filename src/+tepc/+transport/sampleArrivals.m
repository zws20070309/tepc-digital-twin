function t = sampleArrivals(cfg, N, rs, tStart)
%SAMPLEARRIVALS 到达时间抽样。泊松过程: 相邻间隔指数分布 (高率时间链闭环用)。
%   cfg.source.rate_cps; tStart: 起始时刻(默认 0)。返回 Nx1 递增时间 [s]。

if nargin < 4, tStart = 0; end
switch lower(string(cfg.source.arrivalModel))
    case "poisson"
        dt = -log(rand(rs,N,1)) / cfg.source.rate_cps;   % 指数间隔
        t = tStart + cumsum(dt);
    case "fixed"
        t = tStart + (0:N-1)'/cfg.source.rate_cps;
    otherwise
        error("tepc:source:BadArrival","未知到达模型 %s", char(string(cfg.source.arrivalModel)));
end
end
