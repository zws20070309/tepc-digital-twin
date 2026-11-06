function names = inject(p, ws)
%INJECT 把 modelParams 的数值写进模型可访问的工作区 (默认 base)。
%   这是参数进入模型的唯一通道: .slx 里存的是符号名, 数值只活在 workspaces 里,
%   所以换一组 Ts/成形常数/阈值不会改动模型文件的一个字节。
%   重复注入覆盖同名符号 (幂等), 不累积。
if nargin < 2 || isempty(ws), ws = 'base'; end
fn = fieldnames(p);
names = cell(numel(fn), 1);
for i = 1:numel(fn)
    assignin(ws, fn{i}, p.(fn{i}).value);
    names{i} = fn{i};
end
end
