function M = artifactManifest(baseDir, varargin)
%ARTIFACTMANIFEST 列出目录树的每个产物: path/bytes/sha256/schema/producer/utc。
%   发布判定不能只看"STATUS 说完成了", 必须有一份可独立复算的清单。
%   provenance 再哈希这份清单本身 (清单覆盖产物, 哈希覆盖清单)。
%   Name-Value: 'RunPhase' 字符串; 'Producer' 字符串; 'ExcludeNames' 单元字符串
%   (默认排除本清单自身, 否则自指哈希不可算)。
a = parseInputs(varargin{:});
root = char(string(baseDir));
if ~isfolder(root)
    error("tepc:io:NoManifestRoot", "目录不存在: %s", root);
end
paths = walk(root, a.ExcludeNames);
n = numel(paths);
M = repmat(manifestRow(), 1, n);
for i = 1:n
    p = paths{i};
    d = dir(p);
    M(i).path         = relativePath(p, root);
    M(i).bytes        = uint64(d.bytes);
    M(i).sha256       = tepc.io.hashFile(p);
    M(i).schema       = a.Schema;
    M(i).producer     = a.Producer;
    M(i).run_phase    = a.RunPhase;
    M(i).modified_utc = char(datetime(d.date, 'TimeZone', 'UTC', ...
        'Format', 'yyyy-MM-dd HH:mm:ss'));
    M(i).created_utc  = a.CreatedUtc;
end
end

function r = manifestRow()
r = struct('path', "", 'bytes', uint64(0), 'sha256', "", 'schema', "", ...
    'producer', "", 'run_phase', "", 'modified_utc', "", 'created_utc', "");
end

function p = walk(root, excl)
out = {};
d = dir(root);
for i = 1:numel(d)
    if ~d(i).isdir, continue; end
    if any(strcmp({d(i).name}, {'.', '..'})), continue; end
    sub = fullfile(root, d(i).name);
    out = [out, walk(sub, excl)]; %#ok<AGROW>
end
f = dir(root);
for i = 1:numel(f)
    if f(i).isdir, continue; end
    if any(strcmp(f(i).name, excl)), continue; end
    out{end+1} = fullfile(root, f(i).name); %#ok<AGROW>
end
p = out;
end

function rel = relativePath(p, root)
rel = replace(string(p), string(root) + "/", "");
rel = replace(rel, string(root) + "\", "");
end

function a = parseInputs(varargin)
p = inputParser;
p.addParameter('RunPhase', "run", @isstringish);
p.addParameter('Producer', "tepc.run.execute", @isstringish);
p.addParameter('Schema', "tepc-artifact-1", @isstringish);
p.addParameter('ExcludeNames', {}, @(c) iscell(c) || isstring(c));
p.parse(varargin{:});
a = p.Results;
a.CreatedUtc = char(datetime('now', 'TimeZone', 'UTC', ...
    'Format', 'yyyy-MM-dd HH:mm:ss'));
if ~iscell(a.ExcludeNames), a.ExcludeNames = cellstr(a.ExcludeNames); end
end

function tf = isstringish(x)
tf = isstring(x) || ischar(x);
end
