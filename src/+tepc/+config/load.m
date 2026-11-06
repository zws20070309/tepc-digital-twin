function [cfg, meta] = load(path)
%CONFIGLOAD 读取配置 JSON (schema v1)。仅补齐"便利性"字段默认值(与物理无关的
%   运行参数); 所有物理量必须来自配置文件, null 在 strict 校验时报错。
if ~isfile(path)
    error("tepc:config:NotFound","配置文件不存在: %s", path);
end
raw = fileread(path);
cfg = jsondecode(raw);
if ~isfield(cfg,'schemaVersion') || ~strcmp(cfg.schemaVersion, "1.0")
    error("tepc:config:Schema","schemaVersion 必须为 1.0");
end
% 便利性默认值 (物理默认值一律不在此处)
D = struct();
D.run = struct('chunkSize', 2000, 'mode', "RESEARCH_DEMO");
D.analysis = struct('binSpacing', "log");
D.provenance = struct('parameterStatusPolicy', "strict");
fn = fieldnames(D);
for i = 1:numel(fn)
    if ~isfield(cfg, fn{i})
        cfg.(fn{i}) = D.(fn{i});
    else
        sub = fieldnames(D.(fn{i}));
        for j = 1:numel(sub)
            if ~isfield(cfg.(fn{i}), sub{j})
                cfg.(fn{i}).(sub{j}) = D.(fn{i}).(sub{j});
            end
        end
    end
end
meta = struct('path', path, 'loadedAt', datetime('now','Format','yyyy-MM-dd HH:mm:ss'), ...
    'demoBanner', contains(raw, "演示参数"), 'raw_sha256', tepc.io.hashFile(path));
end
