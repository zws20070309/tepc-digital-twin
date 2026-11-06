function tests = test_simulink_gate
%TEST_SIMULINK_GATE MATLAB↔Simulink 电子学对照门禁 (多工作点矩阵)。
%   单一配置的对照只能证明"那一组参数下两条链一致", 而参数是注入进模型的:
%   换一个 config 就可能换一套失效 (旧步长被烘进文件、阶数只在 MATLAB 侧生效…)。
%   所以这里按矩阵跑: Ts × 成形时间的全交叉, 加发货配置本身, 加一条二阶成形。
%   每条腿既核数值差 (峰/面积/触发时刻), 也核"注入的值确实生效了" (采样点数、
%   参数同源判据、从仿真结果反读的量化间隔), 最后核这条腿的工作点在矩阵里
%   不与其他腿重合 —— 否则"跑了 6 条腿"可以退化成重复跑同一条。
tests = functiontests(localfunctions);
end

function test_pulse_gate_matrix(tc)
root = tepc.io.projectRoot();
tc.assumeTrue(license('test', 'Simulink') == 1, '本机无 Simulink 许可, 对照矩阵不适用');
% Simulink 的编译缓存落在两处: 模型/测试所在目录, 以及**当前工作目录** (套件从仓库根
% 启动时就是仓库根)。它们是构建产物, 留在仓库里会让"仓库文件数"随是否跑过仿真而漂移,
% 直接破坏文档计数核对 (test_doc_counts 既比仓库文件数, 也显式禁根目录的 slprj/ 与 .slxc)。
% 所以用完即清, 且三处都清。
cln = onCleanup(@() purgeSimulinkCache(root));  %#ok<NASGU>
base = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
m = legsOf();
n = size(m, 1);
relPk = zeros(n, 1);
relAr = zeros(n, 1);
nSamp = zeros(n, 1);
tapLen = zeros(n, 1);
for i = 1:n
    cfg = base;
    cfg.electronics.Cf_F = 1e-12;      % 钉住反馈电容: 矩阵只沿 Ts / 成形时间 / 阶数 三个方向变
    cfg.electronics.sampleTime_s = m{i, 1};
    cfg.electronics.shaping_s = m{i, 2};
    cfg.electronics.shaperOrder = m{i, 3};
    tag = sprintf('腿 %d (Ts=%gs, tau=%gs, 阶数 %d)', i, m{i, 1}, m{i, 2}, m{i, 3});
    out = tepc.simulink.compareWithMatlab(cfg, 100);
    relPk(i) = out.maxRelPeak;
    relAr(i) = out.maxRelArea;
    nSamp(i) = out.nSamplesExpected;
    p = tepc.simulink.modelParams(cfg);
    tapLen(i) = numel(p.TEPC_numRC.value);
    % 实测余量 (本机, 100 脉冲): 峰差最大 4.6e-5, 面差最大 1.2e-4, 触发时刻差恒为 0;
    % 门槛仍按 1e-3 —— 收紧到实测值附近会让门禁变成对 BLAS 归约顺序的过敏。
    tc.verifyLessThan(out.maxRelPeak, 1e-3, sprintf('%s: 峰值相对差 %.3g', tag, out.maxRelPeak));
    tc.verifyLessThan(out.maxRelArea, 1e-3, sprintf('%s: 正部面积相对差 %.3g', tag, out.maxRelArea));
    tc.verifyLessThanOrEqual(out.maxTrigSampleDiff, 1.5, sprintf('%s: 触发时刻差 %g 个采样', tag, out.maxTrigSampleDiff));
    % 下面三条是"注入环节"的判据: 数值差只能说明两条链算得一样, 不能说明它们吃的是这一组 config。
    tc.verifyTrue(out.stepOk, sprintf('%s: 模型给了 %d 个点, 注入步长应有 %d 个 —— 求解器没吃 TEPC_Ts', ...
        tag, out.nSamplesSim, out.nSamplesExpected));
    tc.verifyTrue(out.paramIdentityOk, sprintf('%s: 模型参数与这组 config 不同源: %s', ...
        tag, strjoin(out.paramViolations, ' | ')));
    tc.verifyEqual(out.adcLevelStep_V, out.adcLsbCfg_V, 'RelTol', 2e-3, ...
        sprintf('%s: 仿真里量化电平间距 %.6g V != 配置 LSB %.6g V', tag, out.adcLevelStep_V, out.adcLsbCfg_V));
    % 阶数必须走到参数侧: 单级 RC 是 2 个分子系数, n 级级联是 n+1 个。这一条读的是
    % modelParams 的算式本身; 模型侧的对应证据是同腿的 paramIdentityOk —— 它的 valueOk
    % 要求工作区解析出的向量与算式**同尺寸同数值**, 尺寸不同即红。
    tc.verifyEqual(tapLen(i), m{i, 3} + 1, sprintf('%s: RC 分子有 %d 个系数, 阶数 %d 应为 %d 个', ...
        tag, tapLen(i), m{i, 3}, m{i, 3} + 1));
    tc.verifyTrue(out.gatePass, sprintf('%s: 门禁总判据未过 (峰 %.3g 面 %.3g 触发 %g)', ...
        tag, out.maxRelPeak, out.maxRelArea, out.maxTrigSampleDiff));
end
% 反空话: 每条腿的工作点必须可与其它腿区分 (采样点数 + 系数长度), 且数值差不得逐位雷同。
% 若某个 config 字段被链路静默忽略, 就会有两行在这两个判据上完全重合。
sig = [nSamp, tapLen];
tc.verifyEqual(size(unique(sig, 'rows'), 1), n, ...
    sprintf('矩阵里有工作点重合 (采样点数/系数长度): 某个 config 字段没被消费\n%s', mat2str(sig)));
tc.verifyEqual(numel(unique(relAr)), n, ...
    sprintf('各腿面积相对差不够互异: 有两条腿跑在同一组参数上\n%s', mat2str(relAr')));
end

function m = legsOf()
% 6 条腿: Ts{1,10}ns × tau{2,4}us 全交叉 (前四行) + 发货配置本身的 (Ts=10ns, tau=1us,
% 阶数 1) + 一条二阶成形。所有腿共用同一份 demo_only.json, 只改这三项。
m = {1e-8, 2e-6, 1; ...
     1e-9, 2e-6, 1; ...
     1e-8, 4e-6, 1; ...
     1e-9, 4e-6, 1; ...
     1e-8, 1e-6, 1; ...
     1e-8, 2e-6, 2};
end

function purgeSimulinkCache(root)
d = fileparts(mfilename('fullpath'));
targets = unique({d, root, pwd}, 'stable');
nm = {'slprj', 'TEPC_Electronics.slxc'};
for k = 1:numel(targets)
    for i = 1:numel(nm)
        p = fullfile(targets{k}, nm{i});
        if isfolder(p)
            rmdir(p, 's');
        elseif isfile(p)
            delete(p);
        end
    end
end
end
