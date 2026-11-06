function [p, ident] = applyParams(cfg, mdl)
%APPLYPARAMS 把解析后的 config 注入模型参数环境, 并在给出模型时立即自核。
%   [p, ident] = applyParams(cfg)   只注入 (符号 -> 数值) 到 base 工作区
%   applyParams(cfg, mdl)           注入 + 核对 mdl 的参数对话框与该 config 同源;
%                                   不一致抛 tepc:simulink:ParamDivergence。
%                                   mdl 可以是模型名或 .slx 路径 (路径情形由
%                                   checkParamIdentity 自行 load/close, 不保存模型)。
%   换运行参数的正确姿势只有这一条: 改 cfg 再 apply, 模型文件不动一个字节。
p = tepc.simulink.modelParams(cfg);
tepc.simulink.inject(p);
if nargin < 2 || isempty(mdl)
    ident = [];
    return;
end
ident = tepc.simulink.checkParamIdentity(cfg, mdl);
if ~ident.ok
    n = min(8, numel(ident.messages));
    if n == 0, n = 1; ident.messages{1} = sprintf('%d 条对话框判据为红', ident.nBad); end
    error('tepc:simulink:ParamDivergence', ...
        '模型 %s 与 config 参数不同源 (%d 处, 共核 %d 条):\n  %s', mdl, numel(ident.messages), ...
        ident.nRows, strjoin(ident.messages(1:n), '\n  '));
end
end
