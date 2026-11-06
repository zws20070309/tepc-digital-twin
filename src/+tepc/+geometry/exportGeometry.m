function man = exportGeometry(spec, outBase, varargin)
%EXPORTGEOMETRY 把 meshSpec 的零件表落成可交换网格 + 审计 manifest。
%
%   man = exportGeometry(spec, 'out/tepc_geometry')            % 最小调用
%   man = exportGeometry(spec, outDir, 'Units','m', 'View','section')
%
% Name/Value
%   'Units'    'mm' (默认) | 'm' —— STL **本身不带单位**, 所以单位必须同时出现在
%              (a) 文件名后缀 _unit_mm / _unit_m, (b) manifest 的 units_export 与
%              unit_scale_from_m, (c) 落盘后的包络尺寸复核 (见下)。
%   'Formats'  默认 {'stl','obj','ply'}
%   'View'     'exploded'|'section'|'overlay' (只记录进 manifest: 剖切不删面,
%              三种视图共用同一套完整网格)
%   'Camera'   [az el] 视角 (记录用)
%   'Resolution' 网格 n (默认 spec.displayResolution_n)
%   'VerifyOnly' true: 不重写文件, 只对盘上已有产物做包络复核。这是**负测试入口** ——
%              把 STL 顶点乘 1000 后再 VerifyOnly, 门禁必须响 (不会失败的门禁不是门禁)。
%
% 1000 倍缩放门禁 (STL 本身无单位 => 外部软件可能把它放大/缩小 1000 倍):
%   写完 **重新读回** 二进制 STL 的顶点, 求 xyz 包络, 与由 shape 解析尺寸 + 网格构造
%   参数 (环角量化) 得到的**期望包络**比较, 相对误差 > 1e-3 即抛 'tepc:geometry:UnitScaleMismatch'。
%   球/圆柱/盒的期望值由解析尺寸独立算出 (不读网格顶点 => 不是自比自); 圆锥的期望值走
%   tepc.geometry.coneMesh 的顶点集, 所以它只与"构造式 + 落盘字节"自洽 —— 锥构造式自身错了
%   检不出来 (那由 checkMesh 的解析体积/半径门负责), 但单位缩放与写盘损坏仍然可检。
%
% 二进制 STL 手写 (fopen(path,'w','l') + fwrite): 本机 R2025a 的 stlwrite 不接受
%   stlwrite(file, triangulation) 这一参数组合 (实测 "输入参数太多"), 且手写让
%   "落盘字节 == 我们声明的字节" 可被 sha256 审计。
%
% manifest 每个零件都带: 路径 / 字节数 / sha256 (tepc.io.hashFile) / 单位 / 顶点数 /
% 面数 / checkMesh 判据 / 视角 / 相机 / 分辨率 / matlab_release / sourceConfigSha256 /
% geometrySha256 / topology。schema 见 docs/geometry_manifest.schema.json。

p = inputParser;
p.addParameter('Units','mm', @(v) ischar(v) || isstring(v));
p.addParameter('Formats', {'stl','obj','ply'});
p.addParameter('View','section');
p.addParameter('Camera',[35 25]);
p.addParameter('Resolution',[]);
p.addParameter('VerifyOnly',false);
p.parse(varargin{:});
a = p.Results;

u = lower(char(string(a.Units)));
switch u
    case "mm", uFac = 1e3;                    % 1 m = 1e3 mm (显式系数)
    case "m",  uFac = 1.0;
    otherwise
        error("tepc:geometry:BadUnits", ...
            "STL/OBJ/PLY 导出单位只允许 mm|m, 实得 %s", u);
end
nRes = a.Resolution;
if isempty(nRes), nRes = spec.displayResolution_n; end
fmtRaw = a.Formats;
if ~iscell(fmtRaw), fmtRaw = {fmtRaw}; end
if numel(fmtRaw) == 1 && iscell(fmtRaw{1}), fmtRaw = fmtRaw{1}; end
fmts = lower(cellstr(string(fmtRaw)));

[dirN, baseN] = fileparts(outBase);
if isempty(baseN) && ~isempty(dirN), baseN = dirN; dirN = ''; end
if ~isempty(dirN) && ~isfolder(dirN)
    if ~mkdir(dirN), error("tepc:geometry:CannotCreateDir","无法创建目录 %s", dirN); end
end
if isempty(dirN), dirN = pwd; end

M = tepc.geometry.checkMesh(spec);            % 导出的前提: 先过网格质量门禁
tolEnv = 1e-3;                                % 包络复核容差 0.1% (1000x 门禁)
rowsList = {};

for k = 1:numel(spec.parts)
    P = spec.parts(k);
    id = char(P.part_id);
    if isempty(P.V) || isempty(P.F), continue; end
    if nRes == spec.displayResolution_n || ~isfield(spec,'buildPartMesh')
        V = double(P.V)*uFac;                 % 米 -> 导出单位 (显式系数, 只在这里乘)
        F = double(P.F);
    else
        mm = spec.buildPartMesh(P.shape, nRes);
        V = double(mm.V)*uFac;
        F = double(mm.F);
    end
    row = newPartRow();
    row.part_id = id;
    row.label = char(P.label);
    row.material = char(P.material);
    row.material_status = char(P.materialStatus);
    row.transport_role = char(P.transport_role);
    row.transport_mode = transportModeOf(P);
    row.transport_evidence = char(P.transport_evidence);
    row.units_internal = char(spec.units);
    row.units_export = u;
    row.unit_scale_from_m = uFac;
    row.resolution_n = nRes;
    row.vertices = size(V,1);
    row.faces = size(F,1);
    row.view = lower(char(string(a.View)));
    row.camera = double(a.Camera(:)).';
    row.matlab_release = version;
    row.source_config_sha256 = char(spec.sourceConfigSha256);
    row.geometry_sha256 = char(spec.geometrySha256);
    row.sha256_source = char(spec.sha256Source);
    row.topology = char(spec.fieldTopology);      % == R.field.kind == electrode(cfg).fieldKind
    row.electrode_topology = char(spec.electrodeTopology);
    row.sensitive_volume = char(spec.geometryType);
    row.check_mesh = struct('closed', M.parts(k).closed, ...
        'nonmanifold_edges', M.parts(k).nonmanifold_edges, ...
        'zero_area_faces', M.parts(k).zero_area_faces, ...
        'duplicate_vertices', M.parts(k).duplicate_vertices, ...
        'normals_outward', M.parts(k).normals_outward, ...
        'free_boundary_edges', M.parts(k).free_boundary_edges, ...
        'volume_m3', M.parts(k).volume_m3, ...
        'area_m2', M.parts(k).area_m2, ...
        'volume_rel_err', M.parts(k).volume_rel_err, ...
        'radius_err_rel', M.parts(k).radius_err_rel, ...
        'mesh_check_ok', M.ok);
    row.analytic_volume_m3 = P.analyticVolume_m3;
    row.analytic_area_m2 = P.analyticArea_m2;
    expEnv = analyticEnvelope(P.shape, nRes)*uFac;   % 解析期望包络 (含环角量化)
    row.envelope_expected_units = expEnv;

    if any(strcmp(fmts,'stl'))
        row.path_stl = fullfile(dirN, sprintf('%s_%s_unit_%s.stl', baseN, id, u));
        if ~a.VerifyOnly
            writeStlBinary(row.path_stl, V, F, ...
                sprintf('tepc part=%s units=%s topology=%s', id, u, row.topology));
        end
        row.bytes_stl = bytesOf(row.path_stl);
        row.sha256_stl = tepc.io.hashFile(row.path_stl);
        got = readStlEnvelope(row.path_stl);
        row.envelope_units = got;
        rel = max(abs(got - expEnv)./max(expEnv, realmin));
        row.envelope_rel_err = rel;
        row.envelope_tolerance = tolEnv;
        row.envelope_ok = rel <= tolEnv;
        if ~row.envelope_ok
            error("tepc:geometry:UnitScaleMismatch", ...
                ['零件 %s 的 STL 包络复核失败: 读回 %s (声明单位 %s), 期望 %s, ' ...
                 '最大相对误差 %.3e > %.1e。这正是 STL 无单位的 1000 倍缩放坑: ' ...
                 '检查文件名单位后缀与 unit_scale_from_m'], ...
                id, mat2str(got), u, mat2str(expEnv), rel, tolEnv);
        end
    end
    if any(strcmp(fmts,'obj'))
        row.path_obj = fullfile(dirN, sprintf('%s_%s_unit_%s.obj', baseN, id, u));
        if ~a.VerifyOnly, writeObj(row.path_obj, V, F, id, row); end
        row.bytes_obj = bytesOf(row.path_obj);
        row.sha256_obj = tepc.io.hashFile(row.path_obj);
    end
    if any(strcmp(fmts,'ply'))
        row.path_ply = fullfile(dirN, sprintf('%s_%s_unit_%s.ply', baseN, id, u));
        if ~a.VerifyOnly, writePly(row.path_ply, V, F, id, row); end
        row.bytes_ply = bytesOf(row.path_ply);
        row.sha256_ply = tepc.io.hashFile(row.path_ply);
    end
    rowsList{end+1} = row; %#ok<AGROW>
end

if isempty(rowsList)
    error("tepc:geometry:NothingToExport","零件表里没有可导出的网格");
end
partsMan = rowsList{1};
for j = 2:numel(rowsList), partsMan(j) = rowsList{j}; end

%% ---------------- manifest ----------------
man = struct();
man.schema = "tepc-geometry-manifest-1.0";
man.schema_file = "docs/geometry_manifest.schema.json";
man.producer = "tepc.geometry.exportGeometry";
man.matlab_release = version;
man.units_internal = char(spec.units);             % 始终 SI
man.units_export = u;                              % 文件名/包络用的单位
man.unit_scale_from_m = uFac;                      % 1 m -> 导出单位 的显式系数
man.geometry_type = char(spec.geometryType);       % 敏感体积 (球/有限圆柱)
man.electrode_topology = char(spec.electrodeTopology);
man.topology = char(spec.fieldTopology);           % 四元一致: == R.field.kind
man.field_topology = char(spec.fieldTopology);
man.anode_type = char(spec.anodeType);
man.source_config_sha256 = char(spec.sourceConfigSha256);
man.geometry_sha256 = char(spec.geometrySha256);
man.sha256_source = char(spec.sha256Source);
man.audit_complete = logical(spec.auditComplete);
man.provenance_status = char(provenanceStatus(man.audit_complete, man.source_config_sha256, ...
    man.geometry_sha256));
man.view = lower(char(string(a.View)));
man.camera = double(a.Camera(:)).';
man.resolution_n = nRes;
man.display_resolution_n = spec.displayResolution_n;
man.transport_grid = struct('kind', char(spec.transportGrid.kind), ...
    'note', char(spec.transportGrid.note));
man.site = struct('requested_diameter_m',spec.requestedDiameter_m, ...
    'realized_diameter_m', spec.realizedDiameter_m, ...
    'relative_difference', spec.siteRelativeDifference, ...
    'equivalence_mode', char(spec.siteEquivalenceMode), 'mismatch', logical(spec.site_mismatch));
man.dims_m = struct('gas_radius_m',spec.gasRadius_m,'wall_thickness_m',spec.wallThickness_m, ...
    'wall_outer_radius_m',spec.wallOuterRadius_m,'anode_radius_m',spec.anodeRadius_m, ...
    'anode_length_m',spec.anodeLength_m,'bbox_radius_m',spec.bboxR_m, ...
    'world_envelope_half_m',spec.worldEnvelopeHalf_m, ...
    'world_envelope_factor',spec.worldEnvelopeFactor, ...
    'world_envelope_min_factor_of_bbox',spec.worldEnvelopeMinFactorOfBbox);
man.analytic = struct('V_m3',spec.V_m3,'S_m2',spec.S_m2,'lbar_gas_m',spec.lbar_gas_m, ...
    'mean_chord_4V_over_S_m',spec.meanChord_4V_over_S_m);
man.field = struct('kind',char(spec.field.kind),'p',spec.field.p,'K',spec.field.K, ...
    'a_m',spec.field.a_m,'b_m',spec.field.b_m,'hv_V',spec.field.hv_V, ...
    'clip_m',spec.field.clip_m,'note',char(spec.field.note));
man.source = struct('type',char(spec.source.type),'energy_MeV',spec.source.energy_MeV, ...
    'direction_unit',spec.source.directionUnit,'cone_half_angle_deg', ...
    spec.source.coneHalfAngle_deg,'status',char(spec.source.status), ...
    'angular_model',char(spec.source.angularModel));
man.mesh_check = struct('closed',M.closed,'nonmanifold_edges',M.nonmanifold_edges, ...
    'zero_area_faces',M.zero_area_faces,'duplicate_vertices',M.duplicate_vertices, ...
    'normals_consistent_outward',M.normals_consistent_outward, ...
    'min_skin_gap_m',M.min_skin_gap_m,'skin_gap_required_m',M.skin_gap_required_m, ...
    'skin_gap_ok',M.skin_gap_ok,'max_radius_err_rel',M.max_radius_err_rel, ...
    'wall_thickness_err_rel',M.wall_thickness_err_rel, ...
    'dimension_tolerance_rel',M.dimension_tolerance_rel,'dimension_err_ok',M.dimension_err_ok, ...
    'ok',M.ok,'convexhull_note',M.convexhull_note);
man.envelope_gate_rel_tolerance = tolEnv;
man.n_parts_exported = numel(partsMan);
man.parts = partsMan;
man.assumed = spec.assumed;
man.limits = { ...
    '网格是**展示网格**: 解析基线的输运不消费它 (transport_grid.kind = analytic_none)', ...
    '壁只以能量损失表进入输运 (csdaTransport/wallEscape), 不是 MC 几何体 (见 parts.transport_mode)', ...
    '源方向与锥半角的来源按 spec.source.status 标注 (配置供数或兜底常量), 无论哪种都只驱动显示几何: 输运角分布仍是各向同性外源弦', ...
    '本 manifest 不宣称中子/伽马响应已验证; 3D 完成 != 物理验证', ...
    'audit_complete=false 时报告首页必须写 3D_NOT_AUDITED, 不得写 3D 已验证'};

mpath = fullfile(dirN, [baseN '_geometry_manifest.json']);
tepc.io.writeJson(mpath, man);
man.manifest_path = mpath;
man.manifest_bytes = bytesOf(mpath);
man.manifest_sha256 = tepc.io.hashFile(mpath);
end

%% ==================== 局部函数 ====================

function r = newPartRow()
r = struct('part_id','','label','','material','','material_status','', ...
    'transport_role','','transport_mode','','transport_evidence','', ...
    'units_internal','SI','units_export','','unit_scale_from_m',NaN,'resolution_n',0, ...
    'vertices',0,'faces',0,'view','','camera',[],'matlab_release','', ...
    'source_config_sha256','','geometry_sha256','','sha256_source','', ...
    'topology','','electrode_topology','','sensitive_volume','', ...
    'check_mesh',[],'analytic_volume_m3',NaN,'analytic_area_m2',NaN, ...
    'path_stl','','path_obj','','path_ply','','bytes_stl',0,'bytes_obj',0,'bytes_ply',0, ...
    'sha256_stl','','sha256_obj','','sha256_ply','', ...
    'envelope_units',[NaN NaN NaN],'envelope_expected_units',[NaN NaN NaN], ...
    'envelope_rel_err',NaN,'envelope_tolerance',NaN,'envelope_ok',false);
end

function m = transportModeOf(P)
if isfield(P,'transport_mode'), m = char(P.transport_mode); else, m = 'not_used'; end
end

function s = provenanceStatus(auditComplete, cfgSha, geoSha)
% 缺任一 provenance 项 => 3D_NOT_AUDITED (不得显示"3D 已验证")。
if auditComplete && ~isempty(cfgSha) && ~isempty(geoSha)
    s = "PROVENANCE_PRESENT";
else
    s = "3D_NOT_AUDITED";
end
end

function e = analyticEnvelope(shape, n)
% 由**解析尺寸 + 网格构造参数**得到的期望包络 [m], 不读网格顶点。
% UV 环的角量化是构造参数决定的闭式量 (不是从顶点测出来的):
%   max_i sin(theta_i) = 1 (n 偶, theta=pi/2 存在), 否则 cos(pi/(2n));
%   max_j sin(phi_j)   = cos(delta), delta = pi*|4*round(n/4) - n| / (2n);
%   max_j cos(phi_j)   = 1 (j=0 总在环上)。
n = max(4, round(double(n)));
sT = 1;
if mod(n,2) ~= 0, sT = cos(pi/(2*n)); end
dP = pi*abs(4*round(n/4) - n)/(2*n);
sP = cos(dP);
switch lower(string(shape.type))
    case "sphere"
        r = shape.radius_m;
        e = [2*r*sT, 2*r*sT*sP, 2*r];             % z 有南北极点 => 精确 2r
    case "cylinder"
        r = shape.radius_m;
        e = [2*r, 2*r*sP, shape.height_m];
    case "box"
        e = 2*shape.half_m*[1 1 1];               % 平面体: 网格精确
    case "cone"
        % 期望包络 = 唯一构造式 (tepc.geometry.coneMesh) 按**声明尺寸**算出的顶点集包围盒。
        % 它不读回写出的文件字节 => 单位缩放/写盘错可检; 它与建网格同源 => 构造式自身的错
        % 不由这条检查负责 (那是 checkMesh 的解析体积/半径门的职责)。
        r = shape.radius_m;
        [Vc, ~] = tepc.geometry.coneMesh(r, shape.apex_m, shape.base_m, n);
        e = max(Vc, [], 1) - min(Vc, [], 1);
    otherwise
        error("tepc:geometry:BadShape","未知 shape.type=%s", string(shape.type));
end
end

function n = bytesOf(path)
d = dir(path);
if isempty(d), error("tepc:geometry:MissingArtifact","产物未落盘: %s", path); end
n = d.bytes;
end

function writeStlBinary(path, V, F, hdr)
% 二进制 STL: 80 字节头 + uint32 面数 + 每面 50 字节 (法向 3 float + 3 顶点 9 float
% + uint16 属性计数)。字节流自己拼 => "落盘字节 == 声明字节" 可被 sha256 审计。
fid = fopen(path, 'w', 'l');                     % 'l' = 小端字节序 (STL 规范要求)
if fid < 0, error("tepc:geometry:WriteFailed","无法写入 %s", path); end
clean = regexprep(char(hdr), '[\n\r]', ' ');
clean = clean(1:min(numel(clean), 80));
fprintf(fid, '%-80s', clean);
n = size(F,1);
fwrite(fid, uint32(n), 'uint32');
a1 = V(F(:,1),:); b1 = V(F(:,2),:); c1 = V(F(:,3),:);
nv = cross(b1-a1, c1-a1, 2);
nv = nv ./ max(sqrt(sum(nv.^2,2)), realmin);
rec = single([nv, a1, b1, c1]);                   % n x 12 single
payload = typecast(reshape(rec.', 1, []), 'uint8');      % n*48 字节
buf = zeros(n, 50, 'uint8');
buf(:, 1:48) = reshape(payload, 48, []).';
% buf(:,49:50) 保持 0 = attribute byte count
fwrite(fid, buf.', 'uint8');
fclose(fid);
end

function got = readStlEnvelope(path)
% 读回二进制 STL 的顶点并求 xyz 包络: 每面 12 float + 1 uint16 = 50 字节。
fid = fopen(path, 'r', 'l');
if fid < 0, error("tepc:geometry:ReadFailed","无法读取 %s", path); end
fseek(fid, 80, 'bof');
n = fread(fid, 1, 'uint32');
raw = fread(fid, inf, 'uint8');
fclose(fid);
per = 50;
if numel(raw) < n*per
    error("tepc:geometry:StlTruncated","%s 声明 %d 面, 实得 %d 字节 (< %d)", ...
        path, n, numel(raw), n*per);
end
b = reshape(raw(1:n*per), per, []).';             % n x 50 uint8
f = typecast(uint8(reshape(b(:,1:48).', 1, [])), 'single');
f = reshape(f, 12, []).';                         % n x 12: 法向 + 3 顶点
Vv = f(:, 4:12);                                  % 每面 9 列: v1xyz v2xyz v3xyz
gx = [1 4 7]; gy = [2 5 8]; gz = [3 6 9];         % 包络必须扫**全部三个顶点**
got = double([max(Vv(:,gx),[],'all')-min(Vv(:,gx),[],'all'), ...
       max(Vv(:,gy),[],'all')-min(Vv(:,gy),[],'all'), ...
       max(Vv(:,gz),[],'all')-min(Vv(:,gz),[],'all')]);   % single -> double 显式
end

function writeObj(path, V, F, id, row)
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0, error("tepc:geometry:WriteFailed","无法写入 %s", path); end
fprintf(fid, '# tepc OBJ (STL/OBJ 格式本身无单位; 单位见文件名与 manifest)\n');
fprintf(fid, '# part=%s units=%s scale_from_m=%g topology=%s config_sha256=%s\n', ...
    id, row.units_export, row.unit_scale_from_m, row.topology, row.source_config_sha256);
fprintf(fid, 'o %s\n', id);
fprintf(fid, 'v %.9g %.9g %.9g\n', V.');
fprintf(fid, 'f %d %d %d\n', F.');
fclose(fid);
end

function writePly(path, V, F, id, row)
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0, error("tepc:geometry:WriteFailed","无法写入 %s", path); end
fprintf(fid, 'ply\nformat ascii 1.0\n');
fprintf(fid, 'comment tepc PLY (单位只写在文件名与 manifest 里)\n');
fprintf(fid, 'comment part=%s units=%s scale_from_m=%g topology=%s\n', ...
    id, row.units_export, row.unit_scale_from_m, row.topology);
fprintf(fid, 'element vertex %d\n', size(V,1));
fprintf(fid, 'property float x\nproperty float y\nproperty float z\n');
fprintf(fid, 'element face %d\n', size(F,1));
fprintf(fid, 'property list uchar int vertex_indices\n');
fprintf(fid, 'end_header\n');
fprintf(fid, '%.9g %.9g %.9g\n', V.');
fprintf(fid, '3 %d %d %d\n', (F-1).');            % PLY 索引从 0 起
fclose(fid);
end
