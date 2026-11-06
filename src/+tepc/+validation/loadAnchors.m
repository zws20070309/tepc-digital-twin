function anc = loadAnchors(root)
%LOADANCHORS 读取外部物理锚点登记表 (config/reference/stopping_anchors.csv)。
%   返回 table: anchor_id quantity particle material energy energy_unit value unit
%     tolerance_rel i_value_eV source provenance_status retrieved doi_or_url notes
%   离线自校验: 文件必须存在、列齐全、数值有限、粒子枚举合法; 若存在
%   anchors_manifest.json 则比对 sha256 —— 不符即报错 (登记表被改动必须知情)。
f = fullfile(root, 'config', 'reference', 'stopping_anchors.csv');
if ~isfile(f)
    error("tepc:validation:NoAnchors","锚点登记表不存在: %s", f);
end
raw = strsplit(strtrim(fileread(f)), newline);
raw = raw(~cellfun(@(s) isempty(strtrim(s)), raw));
rows = cellfun(@(s) strsplit(s, ','), raw, 'UniformOutput', false);
need = {'anchor_id','quantity','particle','material','energy','energy_unit', ...
    'value','unit','tolerance_rel','i_value_eV','source','provenance_status'};
body = rows(2:end);
C = cell(numel(body), numel(need));
for i = 1:numel(body)
    fld = strtrim(body{i});
    if numel(fld) < numel(need)
        error("tepc:validation:AnchorRow","锚点表第 %d 行数据行列数不足 (%d < %d)", ...
            i+1, numel(fld), numel(need));
    end
    C(i, :) = fld(1:numel(need));
end
anc = table();
anc.anchor_id = C(:,1);  anc.quantity = C(:,2);  anc.particle = C(:,3);
anc.material   = C(:,4);
anc.energy     = numCol(C(:,5),  'energy');
anc.energy_unit = C(:,6);
anc.value      = numCol(C(:,7),  'value');
anc.unit       = C(:,8);
anc.tolerance_rel = numCol(C(:,9),  'tolerance_rel');
anc.i_value_eV    = numCol(C(:,10), 'i_value_eV');
anc.source     = C(:,11);
anc.provenance_status = C(:,12);
bad = ~(isfinite(anc.energy) & isfinite(anc.value) & isfinite(anc.tolerance_rel) ...
        & isfinite(anc.i_value_eV) & anc.value > 0 & anc.energy > 0 ...
        & anc.tolerance_rel > 0 & anc.tolerance_rel < 1 & anc.i_value_eV > 0);
if any(bad)
    error("tepc:validation:AnchorRow","锚点表第 %s 行数值非法", ...
        strjoin(string(find(bad) + 1), ','));
end
if ~all(ismember(anc.particle, {'proton','electron'}))
    error("tepc:validation:AnchorParticle","锚点表含未实现粒子类型");
end
if ~all(ismember(anc.unit, {'MeV_cm2_per_g'}))
    error("tepc:validation:AnchorUnit","锚点表含未实现单位");
end
mf = fullfile(root, 'config', 'reference', 'anchors_manifest.json');
if isfile(mf)
    m = jsondecode(fileread(mf));
    want = char(string(m.sha256));
    got  = tepc.io.hashFile(f);
    if ~strcmp(want, got)
        error("tepc:validation:AnchorHash","锚点表哈希与清单不符 (%s != %s)", got, want);
    end
end
end

function v = numCol(col, nm)
v = cellfun(@(s) str2double(s), col);
if any(~isfinite(v)), error("tepc:validation:AnchorNum","列 %s 含非数值", nm); end
end
