function fig = tepc_3d_workbench(cfgPath, varargin)
%TEPC_3D_WORKBENCH 启动独立三维审计工作台 (显示层剖切, 唯一入口)。
%   干净 MATLAB 工作区执行:  tepc_3d_workbench                     % 默认演示配置
%                           fig = tepc_3d_workbench('cfg.json')     % 指定配置路径
%                           fig = tepc_3d_workbench([], 'Visible', false)  % 自检无窗
%   为什么需要这个脚本: 工作台只放在 app/ 里是打不开的 —— 它要调 src/+tepc 服务层
%   (meshSpec/clipVolume/overlapCheck/toleranceMonteCarlo), 只 addpath('app') 会在
%   点任何按钮时报"无法识别的名称 'tepc'"; 而默认配置是相对路径 config/defaults/
%   demo_only.json, 需要当前目录就是仓库根目录。两件事在这里一次做完 (与 tepc_gui 同法)。
if nargin < 1, cfgPath = ''; end
root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'));
addpath(fullfile(root, 'app'));
addpath(fullfile(root, 'workflows'));
cd(root);
if ischar(cfgPath) || isstring(cfgPath)
    s = char(string(cfgPath));
    if isempty(s)
        fig = TEPC3DWorkbench(varargin{:});
    else
        fig = TEPC3DWorkbench(s, varargin{:});
    end
elseif isstruct(cfgPath)
    fig = TEPC3DWorkbench(cfgPath, varargin{:});
else
    fig = TEPC3DWorkbench(varargin{:});
end
end
