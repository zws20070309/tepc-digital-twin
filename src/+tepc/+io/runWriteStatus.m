function s = runWriteStatus(logsDir, status, varargin)
%RUNWRITESTATUS STATUS.json 的唯一写入口。
%   旧实现有三处各写各的 STATUS (execute.m 的 COMPLETED、cancelStatus 的 CANCELLED,
%   以及失败时什么都不写), 于是"报告没生成"与"跑完了"在磁盘上长得一样 —— 实测
%   runs/20260920_122507476-22860faca47d/ 就是一个 logs/ 全空、无 STATUS.json 的
%   半成品目录 (后台作业被池回收杀掉, 无人记账)。
%   现在: 状态词汇集中在这里, 且任何**非** COMPLETED 都必须带 reason/phase,
%   让"部分完成"在结构上无法被伪装成完成。
%   Name-Value: 'Phase' 'RunID' 'Reason' 'ConfigSha256' 'CompletedChunks' 'Extra'(struct)
a = parseInputs(varargin{:});
status = lower(char(string(status)));
allowed = {'running','progress','cancelled','incomplete','completed'};
if ~any(strcmp(status, allowed))
    error("tepc:io:BadStatus", "状态 %s 不在允许值内 (%s)", status, strjoin(allowed, ', '));
end
if ~strcmp(status, 'completed') && isempty(char(string(a.Reason)))
    error("tepc:io:StatusNeedsReason", ...
        "非 completed 状态必须给 Reason, 否则审计上无法区分'跑完'与'跑坏'");
end
s = struct();
s.status = status;
s.phase = char(string(a.Phase));
s.reason = char(string(a.Reason));
s.runID = char(string(a.RunID));
s.config_sha256 = char(string(a.ConfigSha256));
s.completed_chunks = a.CompletedChunks;
s.created_utc = char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss'));
s.matlab_release = version('-release');
if isfield(a, 'Extra') && ~isempty(a.Extra), s.extra = a.Extra; end
p = fullfile(char(string(logsDir)), 'STATUS.json');
tepc.io.writeJson(p, s);
s.path = p;
end

function a = parseInputs(varargin)
p = inputParser;
p.addParameter('Phase', "", @isstringish);
p.addParameter('Reason', "", @isstringish);
p.addParameter('RunID', "", @isstringish);
p.addParameter('ConfigSha256', "", @isstringish);
p.addParameter('CompletedChunks', [], @(x) isempty(x) || isnumeric(x));
p.addParameter('Extra', []);
p.parse(varargin{:});
a = p.Results;
end

function tf = isstringish(x)
tf = isstring(x) || ischar(x);
end
