function P = makeProvenance(root, cfg, R, rd, seed)
%MAKEPROVENANCE 可追溯性记录: 版本、seed、哈希、参数状态表。
%   三条易被忽略的口径:
%     * effective_seed / api_overrides: 记录"实际跑的 seed"以及哪些值是 API 覆盖
%       来的。旧记录只有 cfg 里的 seed, 与真正生效的可能不是同一个。
%     * outputs 现在覆盖 config_identity.json 与 artifact_manifest.json, 且**刻意
%       不含 gates.json**: 发布门禁在 provenance 之后还要再写一次 (它需要读
%       provenance), 给它记哈希等于留一条必然过期的假账。
%     * constants_sha256: 版本化常数表一旦被改, 哈希就变, 旧 run 不再"看起来一样"。
v = ver('MATLAB');
P = struct();
P.matlab_release = version('-release');
P.matlab_version = version();
P.created_utc = char(datetime('now','TimeZone','UTC'));
P.seed = seed;
P.effective_seed = seed;
P.runID = rd.runID;
P.config_sha256 = R.config_sha256;
P.config_sha256_scope = sprintf(['身份 = cfg (去掉 run.nEvents) + effective_seed + ' ...
    'chunk_size + API 覆盖 + checkpoint_schema_version; 哈希对象是 %s 的字节'], ...
    'input/config_identity.json');
P.checkpoint_schema_version = '2.0';
if isfield(R, 'api_overrides') && ~isempty(R.api_overrides)
    P.api_overrides = R.api_overrides;
else
    P.api_overrides = struct('name', {}, 'value', {});
end
P.project_root = root;
P.no_git = true;   % 本交付无 git 仓库, 以文件哈希与版本标签替代
P.stoppingModel = "Bethe+有效电荷+低能锚定拼接 (锚点: PSTAR 水 10MeV=45.67)";
P.model_scope = "DEMO";      % 解析/经验基线; 参考场未评估
P.backend_id = tepc.backendId();   % 算的是什么模型 (代理模型, 非装置复现, 非蒙卡输运)
P.parameterStatus = tepc.config.statusScan(cfg);
cst = fullfile(root, 'docs', 'constants.json');
if isfile(cst)
    P.constants_sha256 = tepc.io.hashFile(cst);
    P.constants_source = "docs/constants.json";
else
    P.constants_sha256 = "";
    P.constants_note = "docs/constants.json 不存在: 常数未版本化";
end
P.outputs = struct();
% 按 rd 的字段拼真实路径 (config_identity/config_resolved/calibration 落在 input/,
% 以前一份代码靠猜子目录, 结果哈希全是空)。
paths = {fullfile(rd.input,'config_identity.json'), ...
    fullfile(rd.input,'config_resolved.json'), ...
    fullfile(rd.input,'calibration.json'), ...
    fullfile(rd.events,'events.h5'), ...
    fullfile(rd.results,'spectrum.csv'), ...
    fullfile(rd.results,'summary.json'), ...
    fullfile(rd.results,'uq.json'), ...
    fullfile(rd.results,'artifact_manifest.json'), ...
    fullfile(rd.results,'report.html'), ...
    fullfile(rd.figures,'diagnostic.png')};
names = {'input.config_identity.json','input.config_resolved.json', ...
    'input.calibration.json','events.events.h5','results.spectrum.csv', ...
    'results.summary.json','results.uq.json','results.artifact_manifest.json', ...
    'results.report.html','figures.diagnostic.png'};
P.outputs_missing = {};
for i = 1:numel(paths)
    f = paths{i};
    if isfile(f)
        P.outputs.(matlab.lang.makeValidName(names{i})) = tepc.io.hashFile(f);
    else
        P.outputs_missing{end+1} = names{i}; %#ok<AGROW>
    end
end
P.outputs_scope = "数据与报告产物; 不含 gates.json (provenance 之后还会刷新一次)";
clear v
end
