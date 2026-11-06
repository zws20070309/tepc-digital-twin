function rd = runDirsForPath(p)
%RUNDIRSFORPATH 为调用方显式指定的 run 路径建立同一套布局。
%   与 tepc.io.runDirs 共用 layoutRunDirs —— 不再有两份目录创建代码
%   (旧 execute.m 里的局部 mkRunDirs 就是第二份, 它把七个子目录全建在 run 根,
%    与事务提交所需的"目标必须不存在"直接冲突)。
root = char(string(p));
if ~isfolder(root), mkdir(root); end
runID = char(string(datetime('now','Format','yyyyMMdd_HHmmss_SSS')));
% 续跑同一目录时必须沿用**原 runID**: commitRun 用 runID 判断"这是同一个 run 的
% 第二轮提交"(允许合并), 换了 ID 就会被当成别人的产物而拒绝覆盖。
st = fullfile(root, 'logs', 'STATUS.json');
if isfile(st)
    try
        j = jsondecode(fileread(st));
        if isfield(j,'runID') && ~isempty(j.runID)
            runID = char(string(j.runID));
        end
    catch
    end
end
rd = struct('runID', runID, 'root', root, ...
    'project_root', tepc.io.projectRoot(), ...
    'output_root', fileparts(root), 'runs_base', root, ...
    'explicit_path', true);
rd = tepc.io.layoutRunDirs(rd);
end
