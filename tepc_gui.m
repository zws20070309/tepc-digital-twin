function app = tepc_gui(visible)
%TEPC_GUI 启动 TEPC 图形界面 (唯一入口)。
%   干净 MATLAB 工作区执行:  tepc_gui          % 打开窗口
%   自检/无窗 (测试用):       app = tepc_gui(false)
%   为什么需要这个脚本: GUI 只放在 app/ 里是打不开的 —— 每个页签都要调 src/+tepc
%   服务层 (只 addpath('app') 会在点 [校验配置] 时报"无法识别的名称 'tepc'");
%   而配置文件框的默认值是相对路径 config/defaults/demo_only.json, 需要当前目录
%   就是仓库根目录。两件事都在这里一次做完。
if nargin < 1, visible = true; end
root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'));
addpath(fullfile(root, 'app'));
cd(root);
app = TEPCApp(visible);
if visible
    fprintf('TEPC GUI 已启动 (root: %s)。默认配置: %s\n', root, ...
        fullfile(root, 'config', 'defaults', 'demo_only.json'));
end
end
