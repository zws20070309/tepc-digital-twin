function out = writeErrorLog(logDir, ME, ctx, fname)
%WRITEERRORLOG 把异常根因落成 logs/error*.json。
%   要解决的问题: app/*.m 里 28 个 catch 中 19 个不带异常变量, 用户只看得到
%   "校验失败/红横幅", identifier、堆栈与"该改哪个字段"全部丢失; 而 GUI 日志区
%   只在内存里且满 400 行就丢前 200 行 —— 事后无从复核。
%   ctx 可选字段: runID, configSha256, stage, cfgPath, matlabRelease, extra(任意结构)。
%   fname 可选 (默认 'error.json'): 一次 run 里可能失败多次 (GUI 反复重试),
%   固定文件名会把**首个根因**覆盖掉 —— 而首个根因往往才是真凶。调用方 (execute)
%   用带时间戳的名字, GUI 的即时错误仍用 error.json (最新一条, 给人看)。
%   返回写入路径 (失败时返回 '' 并 fprintf 到 stderr: 记录错误的代码本身不该再抛错,
%   否则又会落回"异常被吞"的原罪)。
if nargin < 3, ctx = struct(); end
if nargin < 4 || isempty(fname), fname = 'error.json'; end
out = '';
try
    if ~isfolder(logDir), mkdir(logDir); end
    st = struct();
    if numel(ME.stack) > 0
        frames = cell(numel(ME.stack), 1);
        for i = 1:numel(ME.stack)
            f = ME.stack(i);
            frames{i} = struct('name', char(f.name), 'file', char(f.file), ...
                'line', double(f.line));
        end
    else
        frames = {};
    end
    rec = struct();
    rec.identifier  = char(string(ME.identifier));
    rec.message     = char(string(ME.message));
    rec.stack       = {frames{:}};
    rec.causes      = causeList(ME);
    rec.stage       = getField(ctx, 'stage', '');
    rec.runID       = getField(ctx, 'runID', '');
    rec.configSha256= getField(ctx, 'configSha256', '');
    rec.cfgPath     = getField(ctx, 'cfgPath', '');
    rec.matlabRelease = char(getField(ctx, 'matlabRelease', version('-release')));
    rec.utc         = char(datetime('now', 'TimeZone', 'UTC', ...
        'Format', 'yyyy-MM-dd HH:mm:ss'));
    rec.os          = computer;
    if isfield(ctx, 'extra'), rec.extra = ctx.extra; end
    p = fullfile(logDir, char(string(fname)));
    tepc.io.writeJson(p, rec);
    out = p;
catch eInner
    fprintf(2, 'writeErrorLog 自身失败 (%s): %s\n', eInner.identifier, eInner.message);
end
end

function c = causeList(ME)
c = {};
if isempty(ME.cause), return; end
for i = 1:numel(ME.cause)
    cc = ME.cause{i};
    c{i} = struct('identifier', char(string(cc.identifier)), ...
        'message', char(string(cc.message)));
end
end

function v = getField(s, nm, dflt)
if isfield(s, nm) && ~isempty(s.(nm)), v = s.(nm); else, v = dflt; end
end
