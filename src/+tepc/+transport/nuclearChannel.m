function out = nuclearChannel(E_n_MeV, channel, dir_n, rs)
%NUCLEARCHANNEL 中子弹性散射两体运动学（解析基线, 各向同性 CM 假设, ASSUMED 角分布）。
%   channel: "elastic_H" | "elastic_C" | "elastic_O"。
%   输入 dir_n: 3x1 入射中子单位方向。
%   输出: out.recoil.E_MeV / out.recoil.dir (3x1) / out.E_n_prime_MeV / out.Q_MeV。
%   账本(测试锁定): E_n = E_R + E_n' (Q=0) 精确闭合。
%   H: 各向同性 CM -> E_R 在 [0,E_n] 均匀 (精确)。
%   C/O: 各向同性 CM 为低能近似 (ASSUMED; E_R,max = 4A/(1+A)^2 * E_n)。

A = struct('elastic_H',1.0,'elastic_C',12.0,'elastic_O',16.0);
if ~isfield(A, channel)
    error("tepc:nuclear:BadChannel","未知反应道 %s", channel);
end
Am = A.(channel);
costh_cm = 2*rand(rs,1)-1;                    % 各向同性 CM (ASSUMED for C/O)
sinth_cm = sqrt(max(1-costh_cm^2,0));
phi_cm = 2*pi*rand(rs,1);
E_R = E_n_MeV * 2*Am/(1+Am)^2 * (1-costh_cm);
E_n_prime = E_n_MeV - E_R;
% 反冲实验室方向 (入射沿 dir_n, 现场构造正交基)
if nargin < 3 || isempty(dir_n), dir_n = [0;0;1]; end
dir_n = dir_n(:)/norm(dir_n);
[perp1, perp2] = orthonormalTo(dir_n);
% CM 系反冲方向: -(sin cos phi, sin sin phi, cos)_cm 映到 lab(入射=z')
% lab: v_R = V_cm*z + v*_R ; V_cm = v_n/(A+1) z ; v*_R = v_n/(A+1)*(-sin,0,-cos)_cm
% => v_R ∝ ( -sin*cosφ, -sin*sinφ, 1-cosθ ) 在 (perp1,perp2,dir_n) 基下
v_lab = (-sinth_cm*cos(phi_cm))*perp1 + (-sinth_cm*sin(phi_cm))*perp2 ...
        + (1-costh_cm)*dir_n;
v_lab = v_lab / norm(v_lab);
out = struct();
out.recoil = struct('E_MeV', E_R, 'dir', v_lab, 'A', Am);
out.E_n_prime_MeV = E_n_prime;
out.Q_MeV = 0.0;
out.isotropicCM = true;  % H 精确; C/O 为 ASSUMED 近似 (登记册注明)
end

function [e1, e2] = orthonormalTo(v)
if abs(v(3)) < 0.9
    t = [0;0;1];
else
    t = [1;0;0];
end
e1 = cross(v, t); e1 = e1/norm(e1);
e2 = cross(v, e1);
end
