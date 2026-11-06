function [p, spec] = modelParams(cfg)
%MODELPARAMS 电子学 Simulink 模型的具名参数表 (config -> 符号名 -> 数值)。
%   设计: .slx 里只存**符号名**, 数值由 applyParams 从解析后的 config 注入。
%   于是"模型结构"与"运行参数"分离 —— 文件字节与 Ts/成形常数/阈值/LSB 无关,
%   同一份 .slx 对任意一组电子学参数都成立, 参数不可能在模型里被"烘焙"成第二套真相。
%   离散系数仍由 tepc.electronics.filters 计算 (MATLAB 链与 Simulink 链同源)。
%
%   输出
%     p    结构体, 字段名 = 工作区符号名 (TEPC_*), 每个字段是结构:
%            .value  数值 (标量或向量, 与对话框要求的形状一致)
%            .src    该值取自 config 的哪条路径 (诊断用; 系数类取派生式说明)
%            .kind   'scalar' | 'vector'
%     spec n×4 元胞: {块路径, 对话框参数名, 期望符号名, 类别}
%            块路径 '$model' 指模型级参数 (求解器步长);
%            类别 'param' = 吃 config 的注入项, 'inherited' = 结构上必须继承步长的项。
%   spec 是构建方 (buildElectronicsModel) 与核对方 (checkParamIdentity) 共用的
%   唯一一张表: 两边各自维护一份 "哪个参数该叫什么名" 的清单, 正是当初
%   模型与配置各说各话的成因。

e = cfg.electronics;
c = tepc.electronics.filters(cfg);

thrOn = e.trigger.threshold_V;
hyst = e.trigger.hysteresis_V;
LSB = e.adc.fullScale_V / 2^e.adc.bits;

p = struct();
p.TEPC_Ts         = f(c.Ts,        'electronics.sampleTime_s', 'scalar');
p.TEPC_numCSAPZ   = f(conv(c.csa{1}, c.pz{1}), ...
    'filters(): electronics.Cf_F/Rf_Ohm/sampleTime_s', 'vector');
p.TEPC_denCSAPZ   = f(conv(c.csa{2}, c.pz{2}), ...
    'filters(): electronics.Cf_F/Rf_Ohm/sampleTime_s', 'vector');
p.TEPC_numCR      = f(c.cr{1},     'filters(): CR 分子 [1,-1]', 'vector');
p.TEPC_denCR      = f(c.cr{2},     'filters(): electronics.shaping_s+sampleTime_s', 'vector');
% 模型里 RC 只有一块, 所以 n 级成形要在参数侧合并成一条传递函数。每级 DC 增益是
% (1-a_d)/(1-a_d)=1, 合并后仍为 1, 不需要再归一。nRC=1 时结果与单级逐位相同。
rcNum = c.rc{1}; rcDen = c.rc{2};
for kRc = 2:c.nRC
    rcNum = conv(rcNum, c.rc{1});
    rcDen = conv(rcDen, c.rc{2});
end
p.TEPC_numRC      = f(rcNum,       sprintf('filters(): electronics.shaping_s+sampleTime_s x shaperOrder=%d', c.nRC), 'vector');
p.TEPC_denRC      = f(rcDen,       sprintf('filters(): electronics.shaping_s+sampleTime_s x shaperOrder=%d', c.nRC), 'vector');
p.TEPC_thrOn      = f(thrOn,       'electronics.trigger.threshold_V', 'scalar');
p.TEPC_thrOff     = f(thrOn - hyst, ...
    'electronics.trigger.threshold_V - hysteresis_V', 'scalar');
p.TEPC_lsb        = f(LSB,         'electronics.adc.fullScale_V / 2^bits', 'scalar');

% 块对话框 -> 符号。'$model' 行的对话框是求解器步长。
spec = { ...
    '$model',       'FixedStep',            'TEPC_Ts',       'param'; ...
    'q_in',         'SampleTime',           'TEPC_Ts',       'param'; ...
    'CSA_PZ',       'Numerator',            'TEPC_numCSAPZ', 'param'; ...
    'CSA_PZ',       'Denominator',          'TEPC_denCSAPZ', 'param'; ...
    'CSA_PZ',       'SampleTime',           'TEPC_Ts',       'param'; ...
    'CR',           'Numerator',            'TEPC_numCR',    'param'; ...
    'CR',           'Denominator',          'TEPC_denCR',    'param'; ...
    'CR',           'SampleTime',           'TEPC_Ts',       'param'; ...
    'RC',           'Numerator',            'TEPC_numRC',    'param'; ...
    'RC',           'Denominator',          'TEPC_denRC',    'param'; ...
    'RC',           'SampleTime',           'TEPC_Ts',       'param'; ...
    'TriggerRelay', 'OnSwitchValue',        'TEPC_thrOn',    'param'; ...
    'TriggerRelay', 'OffSwitchValue',       'TEPC_thrOff',   'param'; ...
    'TriggerRelay', 'SampleTime',           '-1',            'inherited'; ...
    'ADC',          'QuantizationInterval', 'TEPC_lsb',      'param'; ...
    'ADC',          'SampleTime',           'TEPC_Ts',       'param'; ...
    'y_out',        'SampleTime',           '-1',            'inherited'; ...
    'trig_out',     'SampleTime',           '-1',            'inherited'; ...
    'adc_out',      'SampleTime',           '-1',            'inherited'};
end

function s = f(value, src, kind)
s = struct('value', value, 'src', string(src), 'kind', string(kind));
end
