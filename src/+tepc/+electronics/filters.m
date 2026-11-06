function c = filters(cfg)
%FILTERS 离散电子学链系数（精确 ZOH 一阶节, MATLAB 与 Simulink 共用单一真相源）。
%   链: q[n](C/样本) -> CSA -> PZ(匹配 tau_f) -> CR(tau) -> RC^n(tau)
%   各节精确离散形式(ZOH, 对分段常输入/采样指数严格):
%     CSA(电荷输入):  v[n] = a_f*v[n-1] + q[n]/Cf          num=[1/Cf],   den=[1,-a_f]
%     PZ(匹配):       y[n] = (1+k)x[n] - k x[n-1],          num=[1+k,-k], den=[1]
%                     k = a_f/(1-a_f)  => 与 CSA 极点精确对消
%     CR:             y[n] = x[n]-x[n-1] + a_d y[n-1]       num=[1,-1],   den=[1,-a_d]
%     RC:             y[n] = (1-a_d)x[n-1] + a_d y[n-1]     num=[0,1-a_d],den=[1,-a_d]
%   物理: 匹配 PZ 把 CSA 衰减化为冲激(强度 Q*tau_f/Cf), 成形峰
%         peak ≈ (Q/Cf)*(tau_f/tau)*(1-Ts/tau)^2 (峰值在 t≈0+, 由 h(0+)=1/tau)。
%         —— "峰值在 t≈0+"不是设计目标而是缺陷, 登记在下方 c.pz 的注释里。
%         标定必须经由同一链的电荷注入完成, 不依赖解析幅度。
%   Simulink 端用相同 {num,den}(Discrete Transfer Fcn, den 首项归一)。

Ts = cfg.electronics.sampleTime_s;
tf = cfg.electronics.Rf_Ohm * cfg.electronics.Cf_F;
tau = cfg.electronics.shaping_s;
nRC = max(1, round(cfg.electronics.shaperOrder));
a_f = exp(-Ts/tf);
a_d = exp(-Ts/tau);

c.Ts = Ts; c.tau_f = tf; c.tau_s = tau; c.a_f = a_f; c.a_d = a_d;
c.csa = {[1/cfg.electronics.Cf_F], [1, -a_f]};
k = a_f/(1-a_f); c.k_pz = k;
% 已知缺陷 (实测): 无分母的 FIR PZ 把 CSA 极点**完全**抵消, 于是整链失去电荷积分特性
% => 冲激响应峰在 idx=2 (t=0.02*tau)、峰高按 (Q/Cf)*(tau_f/tau) 走、下冲 -13.7%。
% 补恢复极点 (tau_p=1.1*tau_f, K=(1-a_p)/(1-a_f)) 会把峰位推到 0.98*tau, 但**必须同时**重定
% 电压工作点, 而且量级口径要分清 (两条都是重测过的):
%   * 冲激响应的**峰高比** 1/149.9 —— 这是"掉 150 倍"这句话的出处, 它说的是 hpeak, 不是事件幅值;
%   * 同一电荷打出的**事件峰幅比** 是 0.010066 (约 1/99), 重定 threshold_V / ADC 量程要按这个数,
%     按 1/150 去缩放会把阈值与量程再错 1.5 倍;
%   * 只在分母加一个 a_f (不给分子补 (1-a_f)) 是**双极点**, 净多乘 (1+k)=5000, 峰高反而涨到 55 倍
%     (1 MeV 反冲质子给到 750 V 量级), 那不是修复而是另一种错。
% 另外补极后脉宽在占用窗内不恢复 (tau_p=55 us 大于 waveWindow/pileUpReject/deadTime,
% 基座相对阈值从 1.5e-3 恶化到 0.21), 所以占用窗三参数也得同批重定 —— 这些值没有装置实测支撑,
% 换上去等于用一组 ASSUMED 常数替换一个已登记的缺陷, 保真度不升。故本树保留 FIR 形态并在此登记。
c.pz  = {[1+k, -k], [1]};
c.cr  = {[1, -1], [1, -a_d]};
c.rc  = {[0, (1-a_d)], [1, -a_d]};
c.nRC = nRC;
% 一阶节串列表 (2 列 cell: {num, den})。注意: 不可写成 [ {a,b},{c,d} ] ——
% 方括号会把内层 cell 拍平成一维, 破坏 {s}{1} 索引 (MATLAB 已知陷阱)。
c.sos = {c.csa{1}, c.csa{2}; c.pz{1}, c.pz{2}; c.cr{1}, c.cr{2}};
for kk = 1:nRC
    c.sos(end+1, :) = {c.rc{1}, c.rc{2}}; %#ok<AGROW>
end

comb = polymul(c.csa{1}, c.csa{2}, c.pz{1}, c.pz{2});
comb = polymul(comb{1}, comb{2}, c.cr{1}, c.cr{2});
for kk = 1:nRC
    comb = polymul(comb{1}, comb{2}, c.rc{1}, c.rc{2});
end
gn = comb{2}(1);
c.combined = {comb{1}/gn, comb{2}/gn};

% 电压模式级联 (PZ+CR+RC^n; 输入=前放输出电压) — 噪声传播用
combV = polymul(c.pz{1}, c.pz{2}, c.cr{1}, c.cr{2});
for kk = 1:nRC
    combV = polymul(combV{1}, combV{2}, c.rc{1}, c.rc{2});
end
gnV = combV{2}(1);
c.combinedV = {combV{1}/gnV, combV{2}/gnV};

% 拖尾截断倍数由 tepc.electronics.waveTailTau 单点定义, 这里只是把它发布到系数包里:
% 冲激响应长度、Simulink 对照的单脉冲窗、脉冲占用宽度、ramo 波形拖尾截断都吃同一个数。
% 改它会沿一条单向链传导: Nwin -> 冲激响应长度 -> 噪声标定的蒙特卡洛窗 -> sigma_peak_V
% -> 能谱; 这些是传导关系, 不是逐项核对, 所以不能只看某一条判据绿就当全链一致。
c.tailTau = tepc.electronics.waveTailTau();
Nwin = ceil(c.tailTau*c.tau_s/Ts) + 200;
c.Nwin = Nwin;
% 冲激响应必须用级联一阶节计算: 展开成高阶直接式在 Ts/RfCf < ~2e-8 时
% 因 (1-a_f) 下溢而数值分解 (实测 Ts=1e-12 峰幅错 9.6e11 倍且极点跑到单位圆外)。
c.h = c;  %#ok<NASGL>
hh = [1; zeros(Nwin-1,1)];
for si = 1:size(c.sos,1)
    hh = filter(c.sos{si,1}, c.sos{si,2}, hh);
end
c.h = hh;
[c.hpeak, c.hidx] = max(abs(c.h));
c.hsign = sign(c.h(c.hidx));
if c.hsign == 0, c.hsign = 1; end
end

function out = polymul(n1, d1, n2, d2)
out = {conv(n1, n2), conv(d1, d2)};
end
