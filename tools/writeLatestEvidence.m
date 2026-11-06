function ev = writeLatestEvidence(varargin)
%WRITELETESTEVIDENCE 生成"最新证据索引" docs/test_evidence/latest_evidence.json。
%   ev = writeLatestEvidence()                    计算并写文件
%   ev = writeLatestEvidence('WriteFile', false)  只计算, 不落盘
%   ev = writeLatestEvidence('Root', r)           指定仓库根 (默认 tepc.io.projectRoot())
%
%   为什么需要它: docs/test_evidence/*.log 只能证明"某次跑过", 证明不了"在哪台机器、
%   哪个 MATLAB、哪一版配置/常数上跑的"。历史 runs/* 文件按代际只读不迁移, 没有这份
%   索引就无法判断一条日志与当前代码是否同一代。本工具把运行环境、计数出处与被哈希
%   对象绑在一条记录里, 使没有 MATLAB 的人也能核对"证据与文件是否对得上"。
%
%   三条口径 (不可省):
%     * 计数一律从 docs/counts.json 读, 这里**不重算**。重算就会长出第二套口径,
%       而计数只能由 tools/genCounts.m 静态生成。
%     * 哈希复用 tepc.io.hashFile (纯 MATLAB sha256pm), 不另写一份 SHA-256。
%     * 本文件自己的哈希**不进表**: 自指哈希在写完的那一刻就过期了。
%
%   sha256 表用 [{path, sha256, bytes, mtime_local}] 的对象数组而不是"路径作键":
%   路径里的 '/' 与 '.' 不是合法的 MATLAB 字段名字符, 动态字段名会被写成
%   input_config_identity_json 那种下划线形状 (见 tepc.io.makeProvenance),
%   路径放进值里才能原样保留。

p = inputParser;
p.addParameter('WriteFile', true, @islogical);
p.addParameter('Root', '', @(x) ischar(x) || isstring(x));
p.addParameter('SourceManifest', true, @islogical);
p.parse(varargin{:});
a = p.Results;

root = char(string(a.Root));
if isempty(root)
    if isempty(which('tepc.io.projectRoot'))
        addpath(fullfile(fileparts(fileparts(mfilename('fullpath'))), 'src'));
    end
    root = tepc.io.projectRoot();
end
% 带 .. 的根必须收平: dir() 返回的是文件系统解析后的绝对路径, 而原来的 relK 是按
% numel(root)+2 这个**字符数**切片得到的 —— 根里塞了 '..' 时字符数比真实路径长,
% 每条路径都会被从前面咬掉一截 (实测咬出 'ct.m'、'ysis/analyze.m' 这种幽灵条目,
% 清单写完仍是合法 JSON, 只有下游的同代锁才看得见)。MATLAB 没有 normpath, 用
% 文件系统的规范路径; 切前缀再按名字核对, 不匹配就报错而不是静默咬。
try
    root = char(java.io.File(root).getCanonicalPath());
catch
    error("tepc:io:EvidenceRootUnresolved", "无法求得仓库根的规范路径: %s", root);
end
pre = [root filesep];
if isempty(which('tepc.io.hashFile'))
    addpath(fullfile(root, 'src'));
end

% 源码哈希清单: "这条证据与哪一版代码同代" 必须可机检 —— 只哈希配置与几何清单,
% 证明不了跑的是哪版 src/tests。清单单独成文件: 自指哈希在写完那一刻就过期,
% 所以本工具自己的源文件也进表, 但清单与 latest_evidence 自身不进 (它们由这一步之后重写)。
if a.SourceManifest && a.WriteFile
    srcRoots = {'src', 'app', 'tests', 'tools', 'config', 'geometry'};
    mrows = struct('path', {}, 'sha256', {}, 'bytes', {}, 'mtime_local', {});
    for i = 1:numel(srcRoots)
        dd = dir(fullfile(root, srcRoots{i}, '**', '*'));
        for k = 1:numel(dd)
            if dd(k).isdir, continue; end
            fpK = fullfile(dd(k).folder, dd(k).name);
            if ~startsWith(fpK, pre, 'IgnoreCase', true)
                error("tepc:io:EvidenceRootMismatch", ...
                    "dir() 给出的路径不在根目录下, 相对路径无法安全求得: %s (根=%s)", fpK, root);
            end
            relK = strrep(fpK(numel(pre)+1:end), '\', '/');
            e = struct('path', relK, 'sha256', tepc.io.hashFile(fpK), ...
                'bytes', dir(fpK).bytes, 'mtime_local', dir(fpK).date);
            mrows(end+1) = e; %#ok<AGROW>
        end
    end
    % 顶层文档与 README 也在版本管理范围内
    topFiles = {'README.md', 'tepc_3d_workbench.m'};
    for i = 1:numel(topFiles)
        fpT = fullfile(root, topFiles{i});
        if isfile(fpT)
            dT = dir(fpT);
            mrows(end+1) = struct('path', topFiles{i}, 'sha256', tepc.io.hashFile(fpT), ...
                'bytes', dT.bytes, 'mtime_local', dT.date); %#ok<AGROW>
        end
    end
    man = struct('generated', char(datetime('now', 'TimeZone', 'UTC', ...
        'Format', 'yyyy-MM-dd''T''HHmmss''Z''')), ...
        'generated_note', '由 tools/writeLatestEvidence.m 生成; 清单自身与 latest_evidence.json 不进表', ...
        'n_files', numel(mrows), 'files', {mrows});
    manPath = fullfile(root, 'docs', 'test_evidence', 'source_manifest.json');
    fid = fopen(manPath, 'w', 'n', 'UTF-8');
    if fid > 0
        fwrite(fid, jsonencode(man, 'PrettyPrint', true), 'char');
        fclose(fid);
        fprintf('writeLatestEvidence: 源码清单 %d 个文件 -> docs/test_evidence/source_manifest.json\n', ...
            numel(mrows));
    end
end

ev = struct();
ev.schema = 'tepc-latest-evidence-v1';
ev.generated_at = utcNow();
ev.note = "运行环境与证据哈希索引; 计数来自 docs/counts.json (tools/genCounts.m 生成); 不含本文件自身哈希";
ev.repo_root = root;
ev.matlab_version = version;
ev.matlab_release = version('-release');
ev.matlabroot = matlabroot;
ev.os = computer;
ev.os_arch = computer('arch');
ev.os_type = featureText('OSType');
ev.installed_toolboxes = toolboxList();

% ---------------- 计数: 只读, 不重算 ----------------
countsPath = fullfile(root, 'docs', 'counts.json');
ev.counts_source = 'docs/counts.json';
ev.counts_generated_at = '';
if isfile(countsPath)
    cj = jsondecode(readTextUtf8(countsPath));
    if hasField(cj, 'generated_utc')
        ev.counts_generated_at = textOf(cj.generated_utc);
    end
    ev.test_functions  = numOf(cj, 'test_functions');
    ev.gates           = numOf(cj, 'gates');
    ev.h5_datasets     = numOf(cj, 'h5_datasets');
    ev.anchor_rows_total = numOf(cj, 'anchor_rows_total');
else
    ev.counts_source = 'docs/counts.json 不存在: 跑 tools/genCounts.m';
    ev.test_functions  = NaN;
    ev.gates           = NaN;
    ev.h5_datasets     = NaN;
    ev.anchor_rows_total = NaN;
end

% ---------------- 哈希表 ----------------
ev.test_evidence_dir = 'docs/test_evidence';
% reference_slots.json 是"数据缺位状态"的唯一真相源, 必须与 counts/constants 同代:
% 它决定 test_reference_slots_invariants 的判据两侧取什么, 落后一代就等于索引与锁分叉。
tracked = {'docs/constants.json', 'docs/counts.json', ...
    'config/defaults/demo_only.json', 'config/reference_slots.json', ...
    'config/uncertainty_depth_tiers.json', 'README.md'};
logRel = evidenceLogs(root);
% 被治理文本与登记表**点名引用**的实测产物 (.json) 也必须进哈希表: 先前 tracked 只收
% *.log 与上面六个显式文件, 于是 docs/test_evidence/uncertainty_depth_ladder_*.json 这类
% 只有 .json 的产物从不被索引 —— "数字要能追到产物"这句话就只剩登记表那条路径字符串
% 撑着, 产物本身换没换过内容无人可查。这里按目录全量收 .json (与 .log 同一口径)。
jsonRel = evidenceJsons(root);
tracked = [tracked, logRel, jsonRel];               % 每个 .log 与 .json 都进表

rows = struct('path', {}, 'sha256', {}, 'bytes', {}, 'mtime_local', {});
nMissing = 0;
newest = "";  haveNewest = false;  newestMT = datetime(1970, 1, 1);
for i = 1:numel(tracked)
    rel = tracked{i};
    % fullfile(root, strsplit(rel,'/'){:}) 是"括号后接花括号展开", MATLAB 不支持;
    % 必须先落到变量再展开。
    parts = strsplit(rel, '/');
    f = fullfile(root, parts{:});
    % 每条都得现造一个 1x1 结构: 若写 e = rows 再 e.path=..., 对已有的 1xN 结构数组
    % 赋标量会把字段刷进**每一个**元素, rows(end+1)=e 于是成倍追加。
    e = struct('path', rel, 'sha256', '', 'bytes', NaN, 'mtime_local', '');
    if isfile(f)
        d = dir(f);
        e.sha256 = hashOrDie(f);
        e.bytes = double(d.bytes);
        % 字段名刻意是 mtime_local 而不是 mtime_utc: dir 给的是文件系统按本机时区记下
        % 的墙上时间, 朴素 datetime 换成带时区的 datetime 只是**改标签不移时间**,
        % 标成 UTC 就是一条假账。
        % dir 的字段名是小写 date; R2025a 在部分平台上给 datetime、部分给
        % 'dd-MMM-yyyy HH:mm:ss' 字符, 两条都归一到 datetime 才能与 newestMT 比较。
        raw = d.date;
        if isdatetime(raw)
            mt = raw;
        else
            mt = datetime(strtrim(string(raw)), 'InputFormat', 'dd-MMM-yyyy HH:mm:ss');
        end
        e.mtime_local = dateText(mt);
        if endsWith(string(rel), ".log") && (~haveNewest || mt > newestMT)
            haveNewest = true;  newestMT = mt;  newest = string(rel);
        end
    else
        % 缺文件照实记成空哈希 + bytes=NaN: 索引的作用就是说清"哪份证据不在",
        % 静默跳过会让表看起来完整。
        nMissing = nMissing + 1;
    end
    rows(end+1) = e; %#ok<AGROW>
end
ev.n_files_tracked = numel(rows);
ev.n_files_missing = nMissing;
ev.latest_log = newest;
ev.sha256 = rows;
ev.sha256_excluded = {'docs/test_evidence/latest_evidence.json'};

if a.WriteFile
    outDir = fullfile(root, 'docs', 'test_evidence');
    if ~isfolder(outDir)
        mkdir(outDir);
    end
    out = fullfile(outDir, 'latest_evidence.json');
    tepc.io.writeJson(out, ev);
    fprintf('writeLatestEvidence: 写入 %s (%d 条目, 缺 %d, 最新日志 %s)\n', ...
        out, numel(rows), nMissing, newest);
end
end

%% ---------------- helpers ----------------

function s = dateText(dt)
% datetime -> 'yyyy-MM-dd HH:mm:ss' 文本。改 Format 属性再 char, 不依赖 string 的
% 第二参数形式 (datetime 的那个重载在个别版本上没有)。
s = '';
if ischar(dt)
    s = dt(1:min(end, 19));
    return;
end
try
    d = dt;
    d.Format = 'yyyy-MM-dd HH:mm:ss';
    s = char(d);
catch
end
end

function r = evidenceLogs(root)
% docs/test_evidence/ 下所有 .log, 按名字排序 (dir 的返回顺序不保证)。
r = {};
d = dir(fullfile(root, 'docs', 'test_evidence', '*.log'));
if isempty(d)
    return;
end
nm = sort(string({d.name}));
for i = 1:numel(nm)
    r{end+1} = ['docs/test_evidence/' char(nm(i))]; %#ok<AGROW>
end
end

function r = evidenceJsons(root)
% docs/test_evidence/ 下所有 .json (实测产物本体), 同样按名字排序。
% latest_evidence.json 自己在 tracked 里另有一份, 这里显式排除以免同一文件进表两次。
r = {};
d = dir(fullfile(root, 'docs', 'test_evidence', '*.json'));
if isempty(d)
    return
end
nm = sort(string({d.name}));
for i = 1:numel(nm)
    if nm(i) == "latest_evidence.json"
        continue
    end
    r{end+1} = ['docs/test_evidence/' char(nm(i))]; %#ok<AGROW>
end
end

function h = hashOrDie(f)
try
    h = tepc.io.hashFile(f);
catch e
    error("tepc:evidence:HashFailed", "哈希 %s 失败: %s", f, e.message);
end
end

function t = toolboxList()
% ver 的结构数组 -> 按名字排序的 {name, version, release} 对象数组。
% Installed 字段只在个别版本出现, 缺失时按"能列出来就算装了"处理。
t = struct('name', {}, 'version', {}, 'release', {});
V = ver;
if iscell(V)
    % 老返回形式 (产品名单元数组): 只记名字, 版本留空, 不把清单静默变空。
    rows = t;
    for i = 1:numel(V)
        nm = textOf(V{i});
        if ~isempty(nm)
            rows(end+1) = struct('name', nm, 'version', '', 'release', ''); %#ok<AGROW>
        end
    end
    t = sortByName(rows);
    return;
end
if ~isstruct(V) || isempty(V)
    return;
end
rows = t;
for i = 1:numel(V)
    keep = true;
    if isfield(V, 'Installed') && ~isempty(V(i).Installed)
        keep = double(V(i).Installed(1)) ~= 0;
    end
    if ~keep, continue; end
    nm = textOf(getf(V(i), 'Name'));
    if isempty(nm), continue; end
    rows(end+1) = struct('name', nm, 'version', textOf(getf(V(i), 'Version')), ...
        'release', textOf(getf(V(i), 'Release'))); %#ok<AGROW>
end
t = sortByName(rows);
end

function rows = sortByName(rows)
% 按名字排序: 输出要可复算, 两次生成的 JSON 只能差在时刻字段上。
if numel(rows) > 1
    [~, ord] = sort(string({rows.name}));
    rows = rows(ord);
end
end

function v = getf(s, nm)
if isfield(s, nm), v = s.(nm); else, v = ''; end
end

function ok = hasField(s, nm)
ok = isstruct(s) && isfield(s, nm);
end

function n = numOf(cj, fld)
% 计数缺失一律 NaN (JSON 里成 null), 不猜 0 —— 0 会被读成"真的一个都没有"。
n = NaN;
if hasField(cj, 'counts') && hasField(cj.counts, fld)
    v = cj.counts.(fld);
    if isnumeric(v) && numel(v) == 1
        n = double(v);
    end
end
end

function t = textOf(v)
% jsondecode 可能把日期样式的串解成 datetime, 也可能给 char/string/cell;
% 统一落成 char, 否则 jsonencode 会在 datetime 上抛错。
if isempty(v)
    t = '';
elseif iscell(v)
    t = textOf(v{1});
elseif isstring(v)
    t = char(v(1));
elseif ischar(v)
    t = v;
else
    try
        t = char(string(v));
    catch
        t = '';
    end
end
end

function s = featureText(name)
try
    s = char(string(feature(name)));
catch
    s = sprintf('(feature(''%s'') 不可用)', name);
end
end

function s = utcNow()
s = char(datetime('now', 'TimeZone', 'UTC', 'Format', "yyyy-MM-dd'T'HH:mm:ss'Z'"));
end

function txt = readTextUtf8(f)
% 显式 UTF-8 读: 本机默认字符集 GBK 会把 UTF-8 中文按双字节解码并吞掉紧随其后的
% 换行字节, 行号与内容都会错位。
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0
    error("tepc:evidence:Unreadable", "无法读取 %s", f);
end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
end
