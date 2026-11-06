function v = chargeAmp(q, cfg)
%CHARGEAMP 电荷灵敏前放: V_CPA(s) = (Q/Cf)·1/(1+s·RfCf)。
%   q: 输入电荷脉冲序列 [C] (离散, Ts 采样); 返回前放输出电压波形 [V]。
%   Tustin 离散(见 filters.m), 与 Simulink 模型同系数。

c = tepc.electronics.filters(cfg);
v = filter(c.csa{1}, c.csa{2}, q(:));
end
