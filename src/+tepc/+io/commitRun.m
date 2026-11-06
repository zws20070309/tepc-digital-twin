function [rdOut, moved] = commitRun(rd, varargin)
%COMMITRUN 把 _work 暂存的"发布集"原子改名为正式产物, 并返回重基后的 rd。
%   设计要点:
%   1) 只提交"发布集" input/events/results/figures/partial; **raw/ 与 logs/ 从 t=0
%      起就在 run 根** —— raw/ 是续跑状态 (checkpoint + chunk), 把它事务化会让
%      "已完成 chunk 保留在 raw/" 这条既有承诺失效, 且 Resume 找不到 checkpoint。
%   2) movefile(a,b) 在 b 已存在时是**移入 b**而不是改名, 所以提交前根目录里
%      绝不能预建这些子目录 (runDirs 只在根建 logs/ 与 raw/)。这里再加一道显式检查:
%      目标已存在 -> 拒绝并报错, 绝不静默覆盖已提交产物 (重跑请用新 runID)。
%   3) 提交后所有绝对路径必须重基: 返回的 rdOut.* 指向正式位置, 调用方据此重写
%      R.eventsPath / R.reportPath / R.figurePaths / gates.logPath (否则 provenance
%      哈希与门禁读的是已经不存在的 _work 路径)。
%   4) 提交是"最后一步": 只有 STATUS 允许写 COMPLETED 时才可调用; 失败路径不调用它,
%      而是写 INCOMPLETE + error.json, 于是"部分完成的绿色报告"在结构上不可表示。
a = parseInputs(varargin{:});
names = a.Publish;
rdOut = rd;
moved = {};
root = char(string(rd.root));
sameRun = sameRunAlreadyCommitted(root, getRunID(rd));
for i = 1:numel(names)
    nm = names{i};
    if ~isfield(rd, nm), continue; end
    src  = char(string(workPathOf(rd, nm)));
    dst  = fullfile(root, nm);
    if ~isfolder(src)
        continue;                       % 该阶段没产出 (例: 无图) -> 不算失败
    end
    if exist(dst, 'dir') && ~isempty(dir(dst)) && ~sameRun
        error("tepc:run:CommitTargetBusy", ...
            "目标 %s 已被另一次 run 占满, 拒绝覆盖 (请用新的 runID)。" + ...
            "同一 run 的续跑提交 (logs/STATUS.json 里 runID 相同) 才允许合并。", dst);
    end
    if ~isfolder(dst), mkdir(dst); end
    % 逐文件移动 (而不是整目录改名): 整目录 movefile 在目标已存在时会把源
    % **塞进**目标里, 造出 results/results。
    files = filePaths(src);
    for j = 1:numel(files)
        s = files{j};
        d = fullfile(dst, relativeTo(s, src));
        dd = fileparts(d);
        if ~isfolder(dd), mkdir(dd); end
        ok = movefile(s, d);
        if ~ok
            error("tepc:run:CommitFailed", "无法把 %s 提交到 %s (权限/磁盘/占用?)", s, d);
        end
        moved{end+1} = d; %#ok<AGROW>
    end
    rdOut.(nm) = dst;
end
rdOut.committed = true;
try, rmdir(fullfile(root, '_work'), 's'); catch, end
end

function tf = sameRunAlreadyCommitted(root, runID)
% 同一 run 的第二轮提交 (续跑后重新出报告) 允许合并覆盖; 别的 run 不允许。
p = fullfile(root, 'logs', 'STATUS.json');
tf = false;
if isfile(p)
    try
        s = jsondecode(fileread(p));
        tf = isfield(s,'runID') && strcmp(char(string(s.runID)), char(string(runID)));
    catch
        tf = false;
    end
end
end

function out = filePaths(root)
out = {};
d = dir(root);
for i = 1:numel(d)
    if ~d(i).isdir, continue; end
    if any(strcmp({d(i).name}, {'.','..'})), continue; end
    out = [out, filePaths(fullfile(root, d(i).name))]; %#ok<AGROW>
end
f = dir(root);
for i = 1:numel(f)
    if ~f(i).isdir
        out{end+1} = fullfile(root, f(i).name); %#ok<AGROW>
    end
end
end

function rel = relativeTo(p, root)
rel = replace(string(p), string(root) + "/", "");
rel = replace(rel, string(root) + "\", "");
rel = char(rel);
if rel(1) == filesep, rel(1) = []; end
end

function id = getRunID(rd)
if isfield(rd, 'runID'), id = string(rd.runID); else, id = ""; end
end

function p = workPathOf(rd, nm)
if isfield(rd, 'work') && isfield(rd.work, nm)
    p = rd.work.(nm);
else
    error("tepc:run:NoWorkDir", "rd.work.%s 不存在 (runDirs 未建暂存目录?)", nm);
end
end

function a = parseInputs(varargin)
p = inputParser;
p.addParameter('Publish', {'input','events','results','figures','partial'}, ...
    @(c) iscell(c) || isstring(c));
p.parse(varargin{:});
a = p.Results;
if ~iscell(a.Publish), a.Publish = cellstr(a.Publish); end
end
