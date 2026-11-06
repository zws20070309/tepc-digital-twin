function cal = injectCalibrate(cfg, ctx, firstEID)
%INJECTCALIBRATE 电荷注入刻度。
%   物理含义: 用测试脉冲器向电荷灵敏前放注入**确定**电荷, 测 "电荷 -> ADC 码"
%   的传递函数 (code = a0 + a1 Q + [a2 Q^2])。
%   关键纪律 (实测教训): 刻度**不得**叠加气体统计 —— 电离对数涨落 (Fano) 与
%   雪崩增益涨落 (Polya, theta=8 => 单事件 35% 展宽) 属于探测器的随机性, 是
%   "被测量的分辨率"。把它们混进刻度, 斜率会以 1/sqrt(M) 的幅度随机偏掉
%   (实测 M=64 时 b1 偏 +6.7%, 发布 yF 偏 +80%)。
%   刻度链仍包含真实电子学: ramoWaveform 收集时序 -> CSA/PZ/CR/RC 一阶节级联
%   -> 串联噪声 -> 双量程 ADC, 因为脉冲器注入的就是真实电荷。
%   返回 cal: .beta .cov .sigma_res .domain_C .quadratic .FS_code .nPoints
%            .points(Q_C, code_med, frac) .V_per_C .threshold_V .note

if nargin < 3 || isempty(firstEID), firstEID = int64(2e9); end
bits = cfg.electronics.adc.bits;
FS_V = cfg.electronics.adc.fullScale_V;
g2   = cfg.electronics.adc.range2Gain;
if isempty(g2) || ~(g2 >= 1), g2 = 1; end
thr = cfg.electronics.trigger.threshold_V;

% 电压->电荷标度 (确定性链)
qRef = 1e-15;
pkRef = peakOfCharge(qRef, cfg, ctx);
V_per_C = pkRef/qRef;
if ~(V_per_C > 0), error("tepc:cal:NoResponse","仪器链零响应, 检查 ctx/滤波器系数"); end

% 注入点: 覆盖整个数字化域 (最低 2 LSB), 对数铺开
LSB_V = FS_V/2^bits;
vLo = max(2*LSB_V, 1e-4*FS_V);
Vv = logspace(log10(vLo), log10(FS_V*0.985), 12).';
if g2 > 1
    Vv = [Vv; logspace(log10(FS_V*1.03), log10(g2*FS_V*0.985), 8).']; %#ok<AGROW>
end
Qinj = Vv/V_per_C;
% M 由精度需求反推: 刻度侧无气体涨落, 码散布只来自电子学噪声 (~sigma_peak/LSB
% ~ 10 码) 与量化; 中位数标准误 ~ 1.253*sigma/sqrt(M)。M=96 时相对误差 <0.1%,
% 再大只是白烧 CPU (波形链每点需 M 次 1201 点 FFT+级联滤波)。
M = 96;
rsK = RandStream('Threefry', 'Seed', ctx.seed + 7919);
Qall = []; Call = [];
pt = struct('Q_C',{},'code_med',{},'frac',{});
for i = 1:numel(Qinj)
    cd = codesForCharge(Qinj(i), M, cfg, ctx, rsK);
    okc = isfinite(cd) & cd >= 0 & cd < 2^bits*g2;     % 等效码域内
    nOk = nnz(okc);
    pt(end+1) = struct('Q_C', Qinj(i), 'code_med', median(cd(okc)), ...
        'frac', nOk/M); %#ok<AGROW>
    if nOk < 0.5*M, continue; end
    Qall = [Qall; repmat(Qinj(i), nOk, 1)]; %#ok<AGROW>
    Call = [Call;  cd(okc)];               %#ok<AGROW>
end
if numel(unique(Qall)) < 5
    error("tepc:cal:TooFewPoints","有效注入点不足 5 个 (检查 V_per_C/量程/饱和)");
end
o = isfinite(Call) & Qall > 0;
cal = tepc.calibration.fitChargeInjection(Qall(o), Call(o), struct('bits', bits));
cal.FS_code = 2^bits * g2;                 % 等效码域: [0, 2^bits*g2)
if nnz(o) >= 12
    calQ = tepc.calibration.fitChargeInjection(Qall(o), Call(o), ...
        struct('bits', bits, 'quadratic', true));
    calQ.FS_code = cal.FS_code;
    rl = norm(Call(o) - (cal.beta(1)  + cal.beta(2)*Qall(o)));
    rq = norm(Call(o) - (calQ.beta(1) + calQ.beta(2)*Qall(o) + calQ.beta(3)*Qall(o).^2));
    slope = calQ.beta(2) + 2*calQ.beta(3)*Qall(o);
    wexp = V_per_C/(LSB_V);                % 期望斜率 (码/C), 用于物理性判别
    if rq < 0.5*rl && all(slope(o) > 0) && abs(calQ.beta(2)/wexp - 1) < 0.05
        cal = calQ;
    end
end
cal.points = pt;
% 截距钉零 (物理依据: 本 ADC 无失调, Q=0 时码必为 0; 电子学噪声的分布对称且
% floor 量化只会向下)。自由截距的最小二乘会被高能端主导, 使低能端相对偏差达
% ~19% (实测); 钉零后低能端的唯一残余是量化误差 (1 LSB)。
% 仅当截距在统计上与 0 不可区分 (|a0| < 3*sigma_a0) 时才钉零, 否则保留自由
% 截距并告警 —— 那说明存在真实基线失调, 不能强行抹掉。
if ~cal.quadratic && numel(cal.beta) >= 2 && isfield(cal,'cov') ...
        && isfinite(cal.cov(1,1)) && cal.cov(1,1) > 0
    a0 = cal.beta(1); sa0 = sqrt(cal.cov(1,1));
    if abs(a0) < 3*sa0
        Qv = Qall(o); Cx = Call(o);
        a1z = (Qv'*(Cx - 0)) / (Qv'*Qv);
        r_free = norm(Cx - (cal.beta(1) + cal.beta(2)*Qv));
        r_zero = norm(Cx - a1z*Qv);
        if r_zero <= 1.05*r_free
            cal.beta = [0; a1z];
            cal.pedestalPinned = true;
        else
            cal.pedestalPinned = false;
            warning('tepc:cal:PedestalReal', ...
                '截距 %.3g 码 (sigma %.3g) 无法钉零 (残差 %.3g -> %.3g), 存在真实基线失调', ...
                a0, sa0, r_free, r_zero);
        end
    else
        cal.pedestalPinned = false;
    end
end
cal.slope_codes_per_C = cal.beta(2);
cal.threshold_V = thr;
cal.V_per_C = V_per_C;
cal.LSB_V = LSB_V;
cal.M_per_point = M;
cal.slope_codes_per_C_expected = V_per_C/LSB_V;
cal.note = ["电荷注入刻度: 脉冲器注入确定电荷, 链含真实成形与噪声, " ...
    "不含 Fano/Polya 气体统计 (那是分辨率, 不是刻度)"];
end

function cd = codesForCharge(q_C, M, cfg, ctx, rs)
% CODESFORCHARGE 同一注入电荷下 M 次"仅电子学噪声"的等效码 (无气体涨落)。
c = ctx.coeffs;
wv = tepc.detector.ramoWaveform(q_C, ctx.r0_m, ctx.field, ctx.mob, cfg);
vsig = wv.dq;
for s = 1:size(c.sos,1)
    vsig = filter(c.sos{s,1}, c.sos{s,2}, vsig);
end
Nw = numel(vsig);
cd = zeros(M,1);
for m = 1:M
    vn = tepc.electronics.noise(Nw, cfg, rs, "waveform");
    vn = filter(c.combinedV{1}, c.combinedV{2}, vn);
    pk = tepc.electronics.peakSigned(vsig + vn, c.hsign);   % 与测量链同一峰定义
    [ck, fl, mt] = tepc.electronics.adc(abs(pk), cfg);
    if any(bitand(fl, uint32(1)) > 0) || any(bitand(fl, uint32(256)) > 0)
        cd(m) = NaN;                        % 饱和/域外: 不参与刻度
        continue;
    end
    cd(m) = tepc.electronics.extCode(ck, mt.range, cfg.electronics.adc.bits, ...
        cfg.electronics.adc.range2Gain);
end
end

function pk = peakOfCharge(q_C, cfg, ctx)
% PEAKOFCHARGE 无噪声、无涨落的确定性响应峰值 (仅用于定 V/C 标度)
c = ctx.coeffs;
wv = tepc.detector.ramoWaveform(q_C, ctx.r0_m, ctx.field, ctx.mob, cfg);
v = wv.dq;
for s = 1:size(c.sos,1)
    v = filter(c.sos{s,1}, c.sos{s,2}, v);
end
pk = tepc.electronics.peakSigned(v, c.hsign);   % 与测量链同一峰定义
end
