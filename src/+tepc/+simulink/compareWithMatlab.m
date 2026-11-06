function out = compareWithMatlab(cfg, nPulses, rs)
%COMPAREWITHMATLAB MATLAB↔Simulink 逐样本对照 (一致性门禁)。
%   nPulses 个合成脉冲 (随机电荷/到达间隔; 调用方可给 8/20/100), 同一输入分别进
%   MATLAB 离散链 (filter) 与 Simulink 模型, 比较:
%   峰值相对差 < 0.1%, 面积相对差 < 0.1%, 触发时刻差 gatePass 用 <= 1 个采样周期,
%   用例侧按 1.5 个采样断言 (留一次编译边界抖动的余量, 实测各工作点都是 0)。
%   模型来源: 仓库里的发货 .slx (存在即用), 参数由 config 注入后再跑;
%   发货模型不存在时才在临时目录建一份。任何情况下都不写仓库 simulink/ ——
%   旧实现每次都按调用方的 cfg 重建发货模型, 于是文件里留着"上一次谁跑过"的参数。

if nargin < 3, rs = RandStream('Threefry','Seed',2024); end
if nargin < 2, nPulses = 100; end
root = tepc.io.projectRoot();
c = tepc.electronics.filters(cfg);
Ts = c.Ts;
Nw = ceil(c.tailTau*c.tau_s/Ts);            % 单脉冲窗 (倍数由 filters 发布)
gap = 200;                                 % 脉冲间隔样本(防交叠)

% 合成脉冲: 电荷随机 log-uniform (跨量程), 无噪声
Q = 10 .^ (rand(rs, nPulses, 1) * 2.4 - 13.4);   % ~4e-14 .. 1e-11 C
train = zeros(nPulses * (Nw + gap), 1);
t0s = zeros(nPulses, 1);
for k = 1:nPulses
    t0s(k) = (k-1) * (Nw + gap) + 1;
    train(t0s(k)) = Q(k);
end

% --- MATLAB 链 ---
yM = filter(c.combined{1}, c.combined{2}, train);
thr = cfg.electronics.trigger.threshold_V;
hyst = cfg.electronics.trigger.hysteresis_V;

% --- Simulink 链: 加载 + 注入, 不重建 ---
[mdl, slx, builtHere] = loadForSim(cfg, root);
assignin('base', 'pulseIn', [((0:numel(train)-1)'*Ts), train]);
% 注入的 Ts 必须真的成为求解器步长: 采样点数 = 时长/Ts + 1 是对"模型吃的是注入值"
% 最直接的观测 (对话框只存符号名, 数值只在工作区)。
nExp = numel(train);         % 步数 = 时长/注入步长 + 1: 模型若还留着烘进文件的旧步长就对不上
simOut = sim(mdl, 'StopTime', num2str((numel(train)-1)*Ts, '%.17g'), ...
    'ReturnWorkspaceOutputs', 'on');
yS = simOut.get('simY');
trigS = simOut.get('simTrig');
adcS = simOut.get('simADC');
ident = tepc.simulink.checkParamIdentity(cfg, mdl);
close_system(mdl, 0);
if builtHere
    delete(slx);
end
yS = yS(:); trigS = trigS(:);
adcS = adcS(:);

% --- 逐脉冲比较 ---
pkM = zeros(nPulses,1); pkS = zeros(nPulses,1);
arM = zeros(nPulses,1); arS = zeros(nPulses,1);
ttM = nan(nPulses,1); ttS = nan(nPulses,1);
armed = true;
for k = 1:nPulses
    i0 = t0s(k); i1 = min(i0 + Nw - 1, numel(train));
    segM = yM(i0:i1); segS = yS(i0:i1);
    % 两侧共用**同一个**峰定义 (tepc.electronics.peakSigned, 合成脉冲为正极性):
    % 对照的意义是"两套实现一致", 若两侧各自实现峰搜索, 差值里就混进了定义差。
    % imM 必须接住: 下面的"降回迟滞以下才重新布防"从峰位置起搜 (曾写成 ~ 而 imM
    % 未定义 -> 迟滞重新布防那段直接抛"函数或变量 'imM' 无法识别", 整个 Simulink
    % 对照门禁红在运行时而不是判据上)。
    [pkM(k), imM] = tepc.electronics.peakSigned(segM, +1);
    [pkS(k), ~] = tepc.electronics.peakSigned(segS, +1);
    % 电荷模式面积: 正部积分 sum(max(y,0)) (单极脉冲净面积≈0, 过零搜索对噪声敏感)
    arM(k) = sum(max(segM, 0))*Ts;
    arS(k) = sum(max(segS, 0))*Ts;
    % 触发时刻: 阈值穿越 (迟滞: 触发后需降回 thr-hyst 才重新布防)
    ttM(k) = NaN; ttS(k) = NaN;
    if armed
        j = find(segM >= thr, 1);
        if ~isempty(j), ttM(k) = (i0 + j - 1) - t0s(k); end
        j = find(trigS(max(1,i0-5):i1) > 0.5, 1);
        if ~isempty(j), ttS(k) = (max(1,i0-5) + j - 1) - t0s(k); end
    end
    if any(segM >= thr)
        armed = false;
        jRe = find(segM(max(1,imM):end) <= thr - hyst, 1);
        if ~isempty(jRe), armed = true; end
    end
end
relPk = max(abs(pkM - pkS) ./ max(abs(pkM), eps));
relAr = max(abs(arM - arS) ./ max(abs(arM), eps));
ttDiff = abs(ttM - ttS); ttDiff(isnan(ttDiff)) = 0;
maxTT = max(ttDiff);
LSB = cfg.electronics.adc.fullScale_V / 2^cfg.electronics.adc.bits;
out = struct('nPulses', nPulses, 'maxRelPeak', relPk, 'maxRelArea', relAr, ...
    'maxTrigSampleDiff', maxTT, 'Ts', Ts, 'model', slx, ...
    'nSamplesSim', numel(yS), 'nSamplesExpected', nExp, 'stepOk', numel(yS) == nExp, ...
    'adcLevelStep_V', adcLevelStep(adcS), 'adcLsbCfg_V', LSB, ...
    'paramIdentityOk', ident.ok, 'paramViolations', {ident.messages}, ...
    'gatePass', relPk < 0.001 && relAr < 0.001 && maxTT <= 1 && numel(yS) == nExp && ident.ok, ...
    'note', '门禁: 峰值<0.1%, 面积<0.1%, 触发时刻<=1Ts, 采样点数与注入 Ts 一致, 参数与 config 同源');
end

function [mdl, slx, builtHere] = loadForSim(cfg, root)
% 发货模型优先; 没有就在临时目录按同一份 spec 建一份 (仓库不被写)。
builtHere = false;
mdl = 'TEPC_Electronics';
slx = fullfile(root, 'simulink', [mdl, '.slx']);
if bdIsLoaded(mdl), close_system(mdl, 0); end
if ~isfile(slx)
    outDir = fullfile(tempdir(), 'tepc_simulink_build');
    [mdl, ~] = tepc.simulink.buildElectronicsModel(cfg, outDir);
    slx = fullfile(outDir, [mdl, '.slx']);
    builtHere = true;
    return;
end
load_system(slx);
tepc.simulink.applyParams(cfg, mdl);     % 注入 + 不同源就抛错 (对照跑在错的参数上没意义)
end

function step = adcLevelStep(adcS)
% 量化输出**相邻电平的最小间距** = 模型里真正生效的量化间隔。
%   这是从仿真结果反读参数, 而不是再读一遍配置: 烘进文件的旧 LSB 与注入的新 LSB
%   会在这里露出来 (旧实现里 QuantizationInterval 是字面量, 换配置跑对照它不动)。
v = unique(double(adcS(:)));
d = diff(v);
d = d(d > max(abs(v(1)), 1) * eps * 8);
if numel(d) < 1
    step = NaN;
else
    step = min(d);
end
end
