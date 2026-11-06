function [y, c] = shaper(x, cfg)
%SHAPER 成形器: cr_rc | double_exp | trapezoid。
%   cr_rc:      PZ(匹配 tau_f) + CR(tau) + RC^n(tau) — 半高斯单极性。
%   double_exp: 双指数冲激响应 h(t) ∝ (e^{-t/t1} - e^{-t/t2}), 面积归一。
%   trapezoid:  梯形(平顶)成形 — 递归实现, 平顶时间 = tau, 上升/下降 = tau。
%   x: 前放输出波形; 返回成形波形 y 与所用系数 c。
%   脉冲面积用于电荷模式, 峰值用于幅度模式 —— 两者不可混用。

if nargin < 2, cfg = defaultCfg(); end
x = x(:);
switch lower(string(cfg.electronics.shaperType))
    case "cr_rc"
        c = tepc.electronics.filters(cfg);
        % 从前放输出接 PZ+CR+RC^n (不含 CSA 级)
        comb = {conv(c.pz{1}, c.cr{1}), conv(c.pz{2}, c.cr{2})};
        for k = 1:c.nRC
            comb = {conv(comb{1}, c.rc{1}), conv(comb{2}, c.rc{2})};
        end
        gn = comb{2}(1);
        y = filter(comb{1}/gn, comb{2}/gn, x);
    case "double_exp"
        Ts = cfg.electronics.sampleTime_s;
        t1 = cfg.electronics.shaping_s;      % 慢分量
        t2 = cfg.electronics.shaping_s/5;    % 快分量 (固定比, ASSUMED)
        N = ceil(10*t1/Ts);
        t = (0:N-1)'*Ts;
        h = exp(-t/t1) - exp(-t/t2);
        h = h/trapz(t, h);                   % 面积归一(电荷模式守恒)
        y = conv(x, h); y = y(1:numel(x));
        c = struct('type',"double_exp",'t1',t1,'t2',t2);
    case "trapezoid"
        Ts = cfg.electronics.sampleTime_s;
        tau = cfg.electronics.shaping_s;
        M = max(1, round(tau/Ts));           % 上升沿样本数
        K = M;                                % 平顶 = M
        N = numel(x);
        y = zeros(N,1);
        % 标准梯形递归 (着名 z-域实现): p[n] = p[n-1] + x[n] - x[n-M] ...
        p = zeros(N+2*M,1); s = zeros(N+2*M,1); acc = zeros(N+2*M,1);
        xz = [x; zeros(2*M,1)];
        for n = 2:(N+2*M)
            p(n) = p(n-1) + xz(n) - xz(n-M);
            s(n) = s(n-1) + p(n);
            acc(n) = acc(n-1) + s(n) - M*p(n-M);
        end
        y = acc(1:N) / (M*M);                % 增益归一 ~ 峰值 ≈ 输入阶跃幅值
        c = struct('type',"trapezoid",'M',M,'K',K);
    otherwise
        error("tepc:shaper:BadType","未知成形器 %s", char(string(cfg.electronics.shaperType)));
end
end

function cfg = defaultCfg()
cfg.electronics = struct('sampleTime_s',1e-8,'Cf_F',1e-12,'Rf_Ohm',5e8, ...
    'shaperType',"cr_rc",'shaping_s',1e-6,'shaperOrder',1);
end
