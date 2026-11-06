function fp = modelFingerprint(slxPath)
%MODELFINGERPRINT .slx 的"内容指纹": 结构成员的字节哈希, 与包元数据的易变项分离。
%   为什么不能只看文件 sha256: .slx 是个 zip 包, 每次保存都会重写
%     metadata/coreProperties.xml  (dcterms:created / dcterms:modified)
%     simulink/blockdiagram.xml    (ModifiedDateFormat / ModelUUID)
%     simulink/ScheduleEditor.xml  (每次构建的调度器状态)
%   实测同一份结构 re-save / rebuild 得到三个不同的文件 sha256, 而
%     simulink/systems/*.xml + simulink/configSet*.xml
%   这三类成员逐字节稳定 (参数被烘进文件时 system_root.xml 才会变)。
%   于是两条判据各用一把尺子:
%     fp.file      判"文件有没有被重写" (跑一次仿真不该改它)
%     fp.structure 判"结构/参数有没有变" (换 Ts、换成形常数不该改它)
%   输出 fp.members = {成员名, sha256} 便于失败时定位是哪一块变了。
if ~isfile(slxPath)
    error('tepc:simulink:NoModel', '模型文件不存在: %s', slxPath);
end
[~, uniq] = fileparts(tempname());
d = fullfile(tempdir(), ['tepc_slxread_' uniq]);
if ~isfolder(d), mkdir(d); end
clean = onCleanup(@() rmdir(d, 's')); %#ok<NASGU>
unzip(slxPath, d);
sys = dir(fullfile(d, 'simulink', 'systems', '**', '*.xml'));
cfg = dir(fullfile(d, 'simulink', 'configSet*.xml'));
allm = [sys; cfg]; %#ok<AGROW>
if isempty(allm)
    error('tepc:simulink:FingerprintEmpty', ...
        '在 %s 里没找到 systems/*.xml 或 configSet*.xml: 包结构变了, 指纹定义要跟着改', slxPath);
end
names = cell(numel(allm), 1);
hashes = cell(numel(allm), 1);
for i = 1:numel(allm)
    full = fullfile(allm(i).folder, allm(i).name);
    names{i} = strrep(full, [d filesep], '');
    hashes{i} = tepc.io.hashFile(full);
end
[names, ord] = sort(names);
hashes = hashes(ord);
txt = '';
for i = 1:numel(names)
    txt = [txt sprintf('%s=%s\n', names{i}, hashes{i})]; %#ok<AGROW>
end
fp = struct();
fp.file = tepc.io.hashFile(slxPath);
fp.members = [names(:), hashes(:)];
fp.structure = tepc.io.sha256pm(uint8(txt));
end
