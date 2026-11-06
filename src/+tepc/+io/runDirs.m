function rd = runDirs(root, runID)
%RUNDIRS 每 run 独立 UUID 目录 (互不覆盖)。
%   rd.root = 该 run 的根目录 (与 input/raw/... 子目录同一父目录), 使
%   makeProvenance 等按 rd.root 寻址的产物哈希真实有效。
%   UUID 纯 MATLAB 生成 (backgroundPool worker 无 Java)。
%   CI/测试可用环境变量 TEPC_RUNS_DIR 把输出重定向到仓库外, 否则每跑一次套件
%   就会往 runs/ 里堆若干个目录。
if nargin < 2 || isempty(runID)
    t = datetime('now','Format','yyyyMMdd_HHmmssSSS');
    r1 = sprintf('%06x', randi(2^24-1));
    r2 = sprintf('%06x', randi(2^24-1));
    runID = char(string(t) + '-' + r1 + r2);
end
outRoot = getenv('TEPC_RUNS_DIR');
if ~isempty(outRoot) && strcmp(root, tepc.io.projectRoot())
    if ~isfolder(outRoot)
        % 设了变量却指向不存在的目录: 旧写法在这里整条静默作废, run 全落进仓库 runs/
        % (实测代价 = 11 个游离目录, 而且没人知道自己被重定向失败了)。建出来并点名,
        % 建不出就直接报错 —— 三种退路里只有"沉默"是不可接受的。
        try
            mkdir(outRoot);
            warning('tepc:io:RunsDirCreated', ...
                'TEPC_RUNS_DIR 指向不存在的目录, 已创建后使用: %s', outRoot);
        catch me
            error('tepc:io:RunsDirUnusable', ...
                'TEPC_RUNS_DIR=%s 既不是文件夹也建不出来 (%s): 拒绝静默把 run 写进仓库 runs/', ...
                outRoot, me.message);
        end
    end
    root = outRoot;          % 只接管"隐式用项目根"的情形; 调用方显式指定的基准必须被尊重
end
runRoot = fullfile(root, 'runs', runID);
rd = struct('runID', runID, 'root', runRoot, ...
    'project_root', tepc.io.projectRoot(), ...
    'output_root', root, 'runs_base', fullfile(root, 'runs'), ...
    'explicit_path', false);
% 目录布局只有 layoutRunDirs 一份 (logs/ 与 raw/ 在根, 发布集暂存于 _work/)。
% 旧实现在这里把七个子目录全建在根, 于是"提交=改名"会与预建目录冲突 (movefile
% 会把源目录**移入**已存在的目标, 造出 results/results)。
rd = tepc.io.layoutRunDirs(rd);
end
