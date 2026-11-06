function [vn, meta] = noise(nSamples, cfg, rs, mode)
%NOISE 电子学噪声波形。
%   单边 PSD (V^2/Hz):  G(f) = en_w^2 + en_1f^2 * f_c/(f+f_c) + (in/(2*pi*f*Ctot))^2
%     en_w   = electronics.noise.en_white_nV_per_rootHz
%     en_1f  = electronics.noise.en_1f_amp_nV,  拐角 f_c = en_1f_corner_Hz (必须来自配置)
%     in     = electronics.noise.in_pA_per_rootHz, Ctot = 10*Cf (ASSUMED)
%   mode "waveform": 频域合成时域噪声, 严格满足 var(vn) = int_0^{Fs/2} G df。
%   mode "sigma":    经电压级联 (PZ+CR+RC^n) 后的峰幅标准差, MC 200 次标定。
%   rs: RandStream。噪声种子随 run 记录。

if nargin < 4, mode = "waveform"; end
en = cfg.electronics.noise;
Ctot = cfg.electronics.Cf_F * 10;   % 探测器+杂散 ~10x Cf (ASSUMED)
% 拐角只允许有配置一处来源: 旧实现先写 fc = 100.0 再被配置覆盖, 于是"字段缺位"会静默
% 拿到一套与任何发货配置都无对照关系的 1/f 拐角, 与本文件头注释"必须来自配置"矛盾。
if ~isfield(en, 'en_1f_corner_Hz') || isempty(en.en_1f_corner_Hz)
    error('tepc:noise:NoCorner', ...
        'electronics.noise.en_1f_corner_Hz 缺位: 1/f 拐角没有兜底值可用, 请补配置');
end
fc = double(en.en_1f_corner_Hz);
if ~(fc > 0), error("tepc:noise:BadCorner","en_1f_corner_Hz 必须为正"); end
switch mode
    case "waveform"
        N = max(8, round(nSamples));
        Fs = 1/cfg.electronics.sampleTime_s;
        nh = floor(N/2);                              % 正频 bin 数 (不含 Nyquist)
        f = (0:nh).' * Fs/N;
        ew = (en.en_white_nV_per_rootHz*1e-9)^2;
        e1 = (en.en_1f_amp_nV*1e-9)^2;
        ip = (en.in_pA_per_rootHz*1e-12);
        G = ew + e1*(fc./max(f + fc, eps)) + (ip ./ (2*pi*max(f, f(2))*Ctot)).^2;
        % 目标方差: 单边 PSD 积分, DC 与 Nyquist 各计半权
        df = Fs/N;
        if mod(N,2) == 0
            targetVar = df*(G(1)/2 + sum(G(2:nh)) + G(nh+1)/2);
        else
            targetVar = df*(G(1)/2 + sum(G(2:nh+1)));
        end
        % Hermitian 频谱: X(1),X(N/2+1) 实; 镜像长度严格等于 N
        X = zeros(nh+1,1) + 1i*zeros(nh+1,1);
        X = (randn(rs, nh+1,1) + 1i*randn(rs, nh+1,1)).*sqrt(G/2);
        X(1) = randn(rs)*sqrt(G(1));                   % DC 实
        if mod(N,2) == 0
            X(nh+1) = randn(rs)*sqrt(G(nh+1));         % Nyquist 实
            full = [X; flipud(conj(X(2:nh)))];
        else
            full = [X; flipud(conj(X(2:nh+1)))];
        end
        vn = real(ifft(full, N));
        s = std(vn);
        if s > 0, vn = vn*sqrt(targetVar)/s; end
        vn = vn(:);
        meta = struct('rms_V', std(vn), 'target_rms_V', sqrt(targetVar), ...
            'psd_model', "white+1/f(拐角取自配置)+parallel(折算)", ...
            'f_corner_Hz', fc, 'Ctot_F', Ctot, 'N', N);
    case "sigma"
        c = tepc.electronics.filters(cfg);
        M = 200; pk = zeros(M,1);
        Nw = numel(c.h);
        for m = 1:M
            vnw = tepc.electronics.noise(Nw, cfg, rs, "waveform");
            pk(m) = max(abs(filter(c.combinedV{1}, c.combinedV{2}, vnw)));
        end
        vn = std(pk);
        meta = struct('sigma_peak_V', vn, 'mc_realizations', M);
    otherwise
        error("tepc:noise:BadMode","未知模式 %s", char(mode));
end
end
