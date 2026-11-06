function tepc_quickstart()
%TEPC_QUICKSTART 一键快速开始。
%   干净 MATLAB 工作区执行:  tepc_quickstart
%   1) 建立路径 2) 跑 10000 事件 demo 3) 打印产出位置与摘要。
root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'));
addpath(fullfile(root, 'workflows'));
fprintf('TEPC 解析代理模型 (Fast Surrogate) quickstart (root: %s)\n', root);
R = run_demo();
fprintf('\n打开报告: %s\n', fullfile(R.runDir.results, 'report.html'));
end
