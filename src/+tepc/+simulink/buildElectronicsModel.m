function [mdl, p] = buildElectronicsModel(cfg, outDir, opts)
%BUILDELECTRONICSMODEL 程序化构建 TEPC_Electronics.slx —— 只建结构, 不写数值。
%   与 MATLAB 链 (tepc.electronics.filters) 共用同一组 ZOH 离散系数:
%   q[n] -> CSA_PZ(前放+匹配消取) -> CR -> RC -> [成形输出]
%                                    -> Relay(阈值迟滞) -> [触发]
%                                    -> Quantizer(LSB)  -> [ADC]
%   注: Simulink Discrete Transfer Fcn 要求分母阶>=分子阶, 故 CSA 与 PZ
%   合并为单块(级联后分子/分母同阶), CR/RC 天然同阶。
%
%   参数注入 (单一真相源 = config):
%     每个吃物理参数的对话框 (步长 / 各级 num,den / 阈值 / 迟滞 / 量化间隔) 一律
%     写入 modelParams 给出的**符号名**, 数值由 tepc.simulink.applyParams 放进模型
%     可访问的工作区。因此
%       * 文件里不存在第二个 Ts 字面量: 改配置只改注入, 不改 .slx 字节;
%       * 构建方与核对方共用同一张 spec 表, 参数与块的对应在代码里只有一份。
%
%   输出目录 —— 旧版默认写仓库 simulink/, 任何一次带别的参数的对照都会把发货模型
%   重写成那次的参数 (实测发货步长 1e-9, 配置 1e-8)。现在默认写临时目录, 只有显式
%   传入仓库 simulink/ 才发布: 发布是有意动作, 不是测试副作用。
%
%   [mdl, p] = buildElectronicsModel(cfg)                 -> 临时目录
%   buildElectronicsModel(cfg, fullfile(root,'simulink')) -> 发布 (改发货字节)
%   buildElectronicsModel(cfg, dir, struct('modelName', nm)) -> 同目录内的另一份副本
%   已存在同名文件则关闭并重建 (幂等)。

if nargin < 2 || isempty(outDir)
    outDir = fullfile(tempdir(), 'tepc_simulink_build');
end
if nargin < 3, opts = []; end
mdl = opt(opts, 'modelName', 'TEPC_Electronics');
slx = fullfile(outDir, [mdl, '.slx']);
if bdIsLoaded(mdl), close_system(mdl, 0); end
% 目标文件只在构建成功后由 save_system 覆盖: 先删后建的写法会在建到一半出错时
% 把发货模型删掉而留不下 replacement (实测踩过一次), 这里不留那个窗口。
if ~isfolder(outDir), mkdir(outDir); end

[p, spec] = tepc.simulink.modelParams(cfg);
% 块验证期就要能找到工作区变量: 先注入, 后建块。
tepc.simulink.inject(p);
% From Workspace 在块验证时需要变量已存在(base): 放占位
evalin('base', 'pulseIn = [0 0];');
new_system(mdl);

% --- 模型级: 求解器固定步长, 步长本身也是符号 (数字不进文件) ---
set_param(mdl, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete', ...
    'StopTime', 'Inf');
setModelParam(mdl, spec);

% --- 结构: 块 + 连线 (唯一决定 .slx 字节的部分) ---
pos = [40 40 200 80; 260 40 420 80; 480 40 640 80; 700 40 860 80; ...
       920 40 1080 80; 260 160 420 200; 480 160 640 200; 260 260 420 300; ...
       260 340 420 380; 480 340 640 380];
blks = { ...
    'simulink/Sources/From Workspace',          'q_in',         pos(1,:); ...
    'simulink/Discrete/Discrete Transfer Fcn',  'CSA_PZ',       pos(2,:); ...
    'simulink/Discrete/Discrete Transfer Fcn',  'CR',           pos(3,:); ...
    'simulink/Discrete/Discrete Transfer Fcn',  'RC',           pos(4,:); ...
    'simulink/Discontinuities/Relay',           'TriggerRelay', pos(6,:); ...
    'simulink/Discontinuities/Quantizer',       'ADC',          pos(7,:); ...
    'simulink/Sinks/To Workspace',              'y_out',        pos(8,:); ...
    'simulink/Sinks/To Workspace',              'trig_out',     pos(9,:); ...
    'simulink/Sinks/To Workspace',              'adc_out',      pos(10,:)};
for k = 1:size(blks, 1)
    add_block(blks{k,1}, [mdl '/' blks{k,2}], 'Position', blks{k,3});
end
% 输出端口的工作区变量名是**接口约定** (compareWithMatlab 按它取数), 不是物理参数。
set_param([mdl '/q_in'],     'VariableName', 'pulseIn');
set_param([mdl '/y_out'],    'VariableName', 'simY',    'SaveFormat', 'Array');
set_param([mdl '/trig_out'], 'VariableName', 'simTrig', 'SaveFormat', 'Array');
set_param([mdl '/adc_out'],  'VariableName', 'simADC',  'SaveFormat', 'Array');

add_line(mdl, 'q_in/1', 'CSA_PZ/1');
add_line(mdl, 'CSA_PZ/1', 'CR/1');
add_line(mdl, 'CR/1', 'RC/1');
add_line(mdl, 'RC/1', 'y_out/1');
add_line(mdl, 'RC/1', 'TriggerRelay/1');
add_line(mdl, 'TriggerRelay/1', 'trig_out/1');
add_line(mdl, 'RC/1', 'ADC/1');
add_line(mdl, 'ADC/1', 'adc_out/1');

% --- 参数: 按 spec 写符号名 (数值只在注入里, 永远不经这条路) ---
for k = 1:size(spec, 1)
    blk = spec{k,1};
    if strcmp(blk, '$model') || strcmp(spec{k,4}, 'inherited')
        continue;     % 'inherited' 行只核不写: 继承是块的默认状态, 写它反而可能被拒
    end
    set_param([mdl '/' blk], spec{k,2}, spec{k,3});
end
save_system(mdl, slx);

% 建完立刻自核: 发货的模型必须与传进来的 config 同一套参数 (构造即核对)。
tepc.simulink.applyParams(cfg, mdl);
end

function setModelParam(mdl, spec)
for k = 1:size(spec, 1)
    if strcmp(spec{k,1}, '$model')
        set_param(mdl, spec{k,2}, spec{k,3});
    end
end
end

function v = opt(s, nm, dflt)
if nargin < 2 || isempty(s) || ~isfield(s, nm) || isempty(s.(nm))
    v = dflt;
else
    v = s.(nm);
end
end
