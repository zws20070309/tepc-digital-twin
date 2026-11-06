function rep = overlapCheck(parts, varargin)
%OVERLAPCHECK 零件表的两两干涉审计: AABB 粗筛 + 面-面相交 + 最小间隙 + 穿透深度 + 重复体积。
%
%   rep = overlapCheck(P, 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9)
%   rep = overlapCheck(spec, 'GapMin_m', g, 'PenetrationTol_m', t, 'GridBins', 32)
%
% 输入
%   parts   零件表: meshSpec 产的 spec / spec.parts / 同构 struct 数组 / cell。零件字段:
%             part_id, transport_role (enter_mc|passive), transport_mode, display_only,
%             V (Nx3 [m]), F (Mx3), shape (type/radius_m/height_m/half_m),
%             star_centre_m, coincident_with
%           有 V/F 走网格路线; 只有 shape 走解析路线 (闭式间隙与交集体积); 两者都没有的
%           零件如实标 no_geometry, 不当 0 用。
%
% 必传阈值 (判据参数; 不传即报错, 代码里不留字面量默认值)
%   'GapMin_m'          允许的最小间隙 [m]: 小于它判 GAP_BELOW_LIMIT。
%   'PenetrationTol_m'  穿透容差 [m]: 穿透深度大于它判 PENETRATION。
%
% 可选
%   'AabbPad_m'         AABB 膨胀量 [m], 默认 0 (保守加宽, 不是判据阈值)。
%   'GridBins'          面-面粗筛网格的分箱上限, 默认 48 (面少时自动少分)。
%   'MaxFacesPerPart'   每零件参与判定的面数上限, 默认 Inf。抽样是固定步长 (确定性,
%                       无随机数), 抽了就在 rep 里标 faces_subsampled。
%   'MaxCandidatePairs' 单对零件的候选面-面对上限, 默认 200000; 超出即标
%                       not_fully_evaluated (宁可明说没算完, 不假装算完)。
%   'MaxReportedHits'   每对零件留存的相交记录条数上限, 默认 200 (计数不受它限制)。
%   'MaxGapSamples'     间隙计算每侧最多采样的顶点数, 默认 4000。
%   'SkipDisplayOnly'   true 时 display_only 零件完全不进两两判定, 默认 false。
%
% 四类量的算法与精度分档 (逐对带 method/exact 标记, 不看说明也能判)
%   面-面相交  三角面 AABB 装均匀网格粗筛 -> "双向平面跨越"向量判据刷掉绝大多数假候选
%              -> 存活候选做**线段-三角形相交** (A 的三条边对 B 三角形 + 反向) 精判。
%              同平面 (共面) 的面片对线段法先天失效 (交线躺在两面片自身平面里), 改判为
%              **面内 2D 面积求交**: 重合面积为正即记一次相交并计入 coplanar_contact_pairs;
%              贴边/贴点 (面积低于阈) 不记。平行但不共面的面片对既非相交也非接触, 不记。
%   最小间隙   同心解析对 (球-球 / 同轴等高端差圆柱) 给闭式; 其余为"顶点到对面三角形网格
%              最近距离"采样 + 两侧交替投影局部优化 => **近似** (残差同量级于网格弦偏差,
%              且未做全局最近点对证明)。AABB 已隔开且下界超过 GapMin_m 的对直接给下界并
%              标 resolved_above_threshold (下界足以判定, 不假装是精确值, 也省算力)。
%   穿透深度   对每个相交面对, 取"两侧顶点到对方三角形局部平面的侵入量"的较小者, 再对
%              所有面对取最大 => **局部平面近似**; 接触片相对曲率半径不可忽略时低估。
%              共面接触面的局部侵入量恒为 0 (两面片不互穿), 这类对的重叠程度看重复体积。
%   重复体积   分四条可计算的路, 逐条给状态串: (1) 解析闭式 (球-球含内含/相切、同轴圆柱、
%              同心同尺寸实体); (2) 两侧 AABB 不相交 => 交集必为空 => 精确 0; (3) 边界零接触
%              且一方全部顶点严格在另一方内部 (凸体用半空间, 非凸闭合网格用立体角环绕数)
%              => 内含, 体积取内体网格自身的散度定理和; (4) 两侧都是凸多面体 => 用两侧全部
%              面平面做 Sutherland-Hodgman 半空间裁剪, 交集凸多面体的散度定理体积 (精确到
%              网格离散化本身)。抽样过面、非凸又无闭式、超预算的一律落显式 not_computed_*。
%
% role 分组与"0 不能被读成不敏感"
%   rep.by_role 按 transport_role 分栏, 每栏带 consumed_by_transport /
%   not_consumed_by_transport / consumed_by_detector_field 与 reading_guard: 输运链不消费
%   的实体 (世界体包络、源锥、位点标记, 以及只进探测器场的阳极) 其"0 相交 / 0 敏感度"只
%   说明它不在输运几何里, 不说明它不重要。设计上共面的零件对 (coincident_with) 单列在
%   rep.expected_coincident_pairs 并从"意外干涉"结论里剔除, 但仍然照常计算与报告数值。
%
% 单位: 全部 SI [m]。错误标识符: tepc:geometry:OverlapBadArgs / OverlapBadOption /
%   OverlapMissingThreshold / OverlapBadThreshold / OverlapNoParts

%% ---------------- 0. 参数 ----------------
op = struct('GapMin_m', [], 'PenetrationTol_m', [], 'AabbPad_m', 0, 'GridBins', 48, ...
    'MaxFacesPerPart', Inf, 'MaxCandidatePairs', 200000, 'MaxReportedHits', 200, ...
    'MaxGapSamples', 4000, 'SkipDisplayOnly', false);
if mod(numel(varargin), 2) ~= 0
    error("tepc:geometry:OverlapBadArgs", "overlapCheck 的选项必须成对给出 (名称, 值)");
end
for i = 1:2:numel(varargin)
    nm = char(string(varargin{i}));
    if ~isfield(op, nm)
        % 字面串相邻拼接 ("a" ..."b") 在本机词法器里不是合法拼接, 续行只在二元运算符
        % 与逗号之后成立; 可选名清单用 [] 显式拼接 (char 数组不支持 +)。
        valid = ['GapMin_m PenetrationTol_m AabbPad_m GridBins MaxFacesPerPart ' ...
            'MaxCandidatePairs MaxReportedHits MaxGapSamples SkipDisplayOnly'];
        error("tepc:geometry:OverlapBadOption", "未知选项 %s (可用: %s)", nm, valid);
    end
    op.(nm) = varargin{i+1};
end
if isempty(op.GapMin_m) || isempty(op.PenetrationTol_m)
    error("tepc:geometry:OverlapMissingThreshold", ...
        "GapMin_m 与 PenetrationTol_m 必须显式传入: 间隙下限与穿透容差是判据, 不在代码里留默认值");
end
gapMin = numScalar(op.GapMin_m, 'GapMin_m');
penTol = numScalar(op.PenetrationTol_m, 'PenetrationTol_m');
if ~(gapMin > 0)
    error("tepc:geometry:OverlapBadThreshold", "GapMin_m 必须为正的有限标量 (实得 %g)", gapMin);
end
if ~(penTol >= 0)
    error("tepc:geometry:OverlapBadThreshold", "PenetrationTol_m 必须为非负有限标量 (实得 %g)", penTol);
end
pad = numScalar(op.AabbPad_m, 'AabbPad_m');
if ~(pad >= 0)
    error("tepc:geometry:OverlapBadThreshold", "AabbPad_m 必须为非负有限标量 (实得 %g)", pad);
end
nbMax = max(2, round(double(op.GridBins)));

%% ---------------- 1. 零件表 ----------------
P = normalizeParts(parts);
if logical(op.SkipDisplayOnly)
    keepK = ~[P.display_only];
    if nnz(keepK) < 2
        error("tepc:geometry:OverlapNoParts", "SkipDisplayOnly 后不足 2 个零件");
    end
    P = P(keepK);
end
np = numel(P);
if np < 2
    error("tepc:geometry:OverlapNoParts", "两两干涉核查至少需要 2 个零件 (实得 %d)", np);
end

%% ---------------- 2. 逐零件几何 ----------------
% 派生字段 (n_faces / aabb / grid / ...) 是逐零件往 G 上加的: MATLAB 给结构体数组的一个
% 元素加字段会给**所有**元素加上该字段, 于是第二轮再执行 G(k) = P(k) (P 只有基础字段集)
% 就是"在不同结构体之间进行下标赋值"。这里一次性整表拷入, 循环里只增改字段。
G = P;
for k = 1:np
    [V, F] = limitedMesh(P(k).V, P(k).F, op.MaxFacesPerPart);
    G(k).V = V;
    G(k).F = F;
    G(k).n_faces = size(F, 1);
    G(k).n_faces_full = size(P(k).F, 1);
    G(k).faces_subsampled = size(F, 1) < size(P(k).F, 1);
    G(k).analytic = analyticOf(G(k).shape);
    if ~isempty(V) && ~isempty(F)
        bb = [min(V, [], 1); max(V, [], 1)];
        G(k).aabb = [bb(1,:) - pad, bb(2,:) + pad];
        G(k).geom_kind = 'mesh';
    elseif G(k).analytic.kind ~= "none"
        bb = analyticBBox(G(k).analytic);
        G(k).aabb = [bb(1,:) - pad, bb(2,:) + pad];
        G(k).geom_kind = 'analytic_only';
    else
        G(k).aabb = [NaN NaN NaN NaN NaN NaN];
        G(k).geom_kind = 'no_geometry';
    end
    if ~isempty(F)
        G(k).grid = buildGrid(V, F, nbMax);
    else
        G(k).grid = emptyGrid();
    end
    % 实体性质 (体积判定的前提): 闭合性、半空间表示、凸性、自身散度定理体积。逐零件算一次,
    % 逐对复用; 判定失败的零件只会被降级成 not_computed_*, 不会被当成凸体去裁剪。
    [planes, closed, convex, mvol, gnote] = solidMeshInfo(V, F);
    G(k).planes = planes;
    G(k).closed = closed;
    G(k).convex = convex;
    G(k).mesh_volume_m3 = mvol;
    G(k).geom_note = gnote;
end

%% ---------------- 3. 两两判定 ----------------
aabbHit = false(np, np);
hitMatrix = zeros(np, np);
gapMatrix = nan(np, np);
penMatrix = nan(np, np);
volMatrix = nan(np, np);
volStatus = repmat({''}, np, np);
gapMethod = repmat({''}, np, np);
pairs = repmat(newPairRow(), 1, 0);
for i = 1:np-1
    for j = i+1:np
        pr = checkPair(G(i), G(j), i, j, gapMin, penTol, op, nbMax);
        pairs(end+1) = pr; %#ok<AGROW>
        aabbHit(i,j) = pr.aabb_overlap;
        aabbHit(j,i) = pr.aabb_overlap;
        hitMatrix(i,j) = pr.n_face_hits;
        hitMatrix(j,i) = pr.n_face_hits;
        gapMatrix(i,j) = pr.min_gap_m;
        gapMatrix(j,i) = pr.min_gap_m;
        penMatrix(i,j) = pr.penetration_depth_m;
        penMatrix(j,i) = pr.penetration_depth_m;
        volMatrix(i,j) = pr.overlap_volume_m3;
        volMatrix(j,i) = pr.overlap_volume_m3;
        volStatus{i,j} = pr.overlap_volume_status;
        volStatus{j,i} = pr.overlap_volume_status;
        gapMethod{i,j} = pr.gap_method;
        gapMethod{j,i} = pr.gap_method;
    end
end

%% ---------------- 4. 报告 ----------------
rep = struct();
rep.units = 'SI';
rep.n_parts = np;
rep.part_ids = {G.part_id};
rep.transport_role = {G.transport_role};
rep.transport_mode = {G.transport_mode};
rep.display_only = logical([G.display_only]);
rep.geom_kind = {G.geom_kind};
rep.n_faces = [G.n_faces];
rep.faces_subsampled = logical([G.faces_subsampled]);
rep.thresholds = struct('gap_min_m', gapMin, 'penetration_tol_m', penTol, ...
    'aabb_pad_m', pad);
rep.aabb = vertcat(G.aabb);
rep.aabb_overlap_matrix = aabbHit;
rep.face_hit_matrix = hitMatrix;
rep.min_gap_matrix = gapMatrix;
rep.penetration_matrix = penMatrix;
rep.overlap_volume_matrix = volMatrix;
rep.overlap_volume_status = volStatus;
rep.gap_method = gapMethod;
rep.pairs = pairs;
rep.expected_coincident_pairs = pairs([pairs.expected_coincident]);
rep.summary = summarizePairs(pairs, gapMin, penTol);
rep.by_role = groupByRole(P, pairs);
rep.verdict = verdictOf(rep.summary);
rep.method = struct( ...
    'face_intersection', 'uniform_face_aabb_grid + two_way_plane_side_filter + segment_triangle + coplanar_polygon_overlap', ...
    'min_gap', 'closed_form_for_concentric_analytic + sampled_vertex_to_face + alternating_projection', ...
    'penetration_depth', 'local_plane_intrusion_over_hit_pairs', ...
    'overlap_volume', 'closed_form_analytic_or_aabb_disjoint_or_contained_inner_volume_or_convex_halfspace_clip');
rep.approximations = { ...
    '最小间隙: 非解析对用顶点到对面三角形的采样 + 交替投影, 近似值 (残差同量级于网格弦偏差), 无全局最优性保证', ...
    '最小间隙: AABB 已隔开且下界超过 GapMin_m 的对给的是下界而不是精确值 (resolved_above_threshold)', ...
    '穿透深度: 以相交处两个三角面的局部平面度量侵入量, 接触片不可忽略时低估', ...
    '面-面相交: 共面 (同平面) 面片对按面内 2D 面积求交判定, 重合面积低于 1e-12*尺度^2 的贴边/贴点不记', ...
    '面-面相交: 平行但不共面的面片对不算接触, 两实体的贴合由间隙判据 (min_gap_m) 反映', ...
    '重复体积: 内含与凸-凸裁剪给的是"网格实体"的体积, 与解析曲面之间的差是网格弦偏差 (离散化本身)', ...
    '重复体积: 非凸且无闭式的对一律 not_computed_*, 不拿体素交并或抽样体积冒充'};
rep.note = ['本函数只做几何核查, 不改任何几何: 零件表按值读, 输出矩阵的行列与 ' ...
    'rep.part_ids 同序。display_only 零件默认仍参与两两计算 (它们之间的干涉确实存在), ' ...
    '但结论按 role 分栏单列; 设计上共面的零件对 (coincident_with) 也照常算, 只是不混进 ' ...
    '意外干涉的结论。任何"没算完"都落成 not_fully_evaluated 并影响 verdict。'];
end

%% ==================== 局部函数 ====================

function v = numScalar(x, nm)
v = double(x);
if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
    error("tepc:geometry:OverlapBadThreshold", "%s 必须是有限数值标量", nm);
end
end

function P = normalizeParts(parts)
% 接受 spec / spec.parts / struct 数组 / cell。role 缺失标 unknown 而不猜 enter_mc:
% 猜成"进 MC"会让一个无人消费的零件拿到"通过"结论。
if isstruct(parts) && ~isempty(parts) && isfield(parts, 'parts') && ~isfield(parts, 'V')
    parts = parts.parts;
end
if iscell(parts)
    np = numel(parts);
    P = repmat(freshPart(), 1, np);
    for k = 1:np
        if ~isstruct(parts{k})
            error("tepc:geometry:OverlapNoParts", "cell 零件表第 %d 项不是结构体", k);
        end
        P(k) = fillPart(parts{k}, k);
    end
elseif isstruct(parts)
    np = numel(parts);
    P = repmat(freshPart(), 1, np);
    for k = 1:np
        P(k) = fillPart(parts(k), k);
    end
else
    error("tepc:geometry:OverlapNoParts", "零件表必须是结构体数组或 cell");
end
end

function p = freshPart()
p = struct('part_id', '', 'transport_role', 'unknown', 'transport_mode', 'unknown', ...
    'display_only', false, 'V', zeros(0,3), 'F', zeros(0,3), 'shape', [], ...
    'centre', [0 0 0], 'coincident_with', '', 'idx', 0);
end

function p = fillPart(s, k)
p = freshPart();
p.idx = k;
p.part_id = charOr(s, 'part_id', sprintf('part_%d', k));
p.transport_role = lower(charOr(s, 'transport_role', charOr(s, 'role', 'unknown')));
p.transport_mode = lower(charOr(s, 'transport_mode', transportModeOfId(p.part_id)));
p.display_only = logicalField(s, 'display_only');
p.V = matField(s, 'V');
p.F = matField(s, 'F');
p.shape = fieldOrEmpty(s, 'shape');
c = matField(s, 'star_centre_m');
if isempty(c), c = matField(s, 'centre'); end
if isempty(c), c = [0 0 0]; end
p.centre = c(1:3);
p.coincident_with = charOr(s, 'coincident_with', '');
end

function v = charOr(s, nm, d)
if isfield(s, nm) && ~isempty(s.(nm)) && (ischar(s.(nm)) || isstring(s.(nm)))
    v = strtrim(char(string(s.(nm))));
else
    v = d;
end
end

function v = fieldOrEmpty(s, nm)
v = [];
if isfield(s, nm), v = s.(nm); end
end

function v = logicalField(s, nm)
v = false;
if isfield(s, nm) && ~isempty(s.(nm)), v = logical(s.(nm)); end
end

function m = matField(s, nm)
m = [];
if isfield(s, nm) && ~isempty(s.(nm)) && isnumeric(s.(nm)), m = double(s.(nm)); end
end

function m = transportModeOfId(id)
% 与 meshSpec.m 的局部函数 transportModeOf(id) 同表 (那份跨文件取不到, 此处按 id 复制):
% gas_cavity -> mc_chord_and_csda, wall -> energy_loss_table, anode -> field_model_only,
% 其余 -> not_used。
switch lower(char(id))
    case 'gas_cavity', m = 'mc_chord_and_csda';
    case 'wall',       m = 'energy_loss_table';
    case 'anode',      m = 'field_model_only';
    otherwise,         m = 'not_used';
end
end

function [V, F] = limitedMesh(V, F, maxFaces)
% 确定性面抽样 (固定步长, 无随机数): 只用于把成本压进预算, 抽了就在零件行上标出来。
if ~isnumeric(V) || isempty(V) || size(V, 2) ~= 3
    V = zeros(0, 3);
else
    V = double(V);
end
if isempty(V) || ~isnumeric(F) || isempty(F) || size(F, 2) ~= 3
    F = zeros(0, 3);
    return
end
F = double(F);
M = size(F, 1);
maxFaces = double(maxFaces);
if isfinite(maxFaces) && M > maxFaces
    stride = ceil(M/maxFaces);
    F = F(1:stride:end, :);
    used = unique(F(:));
    loc = zeros(size(V,1), 1);
    loc(used) = 1:numel(used);
    V = V(used, :);
    F = loc(F);
end
end

function a = analyticOf(shape)
% 解析体描述 (闭式间隙/交集体积用)。不认识或缺尺寸 -> kind = "none" (调用方据此降级)。
a = struct('kind', "none", 'r', NaN, 'hz', NaN, 'half', NaN);
if isempty(shape) || ~isstruct(shape) || ~isfield(shape, 'type')
    return
end
try
    tp = lower(string(shape.type));
    switch tp
        case "sphere"
            a.kind = "sphere";
            a.r = double(shape.radius_m);
        case "cylinder"
            a.kind = "cylinder";
            a.r = double(shape.radius_m);
            a.hz = abs(double(shape.height_m))/2;
        case "box"
            a.kind = "box";
            a.half = double(shape.half_m);
    end
catch
    a.kind = "none";
end
if a.kind == "sphere" && ~(a.r > 0), a.kind = "none"; end
if a.kind == "cylinder" && ~(a.r > 0 && a.hz > 0), a.kind = "none"; end
if a.kind == "box" && ~(a.half > 0), a.kind = "none"; end
end

function bb = analyticBBox(a)
switch a.kind
    case "sphere",   bb = [-a.r -a.r -a.r; a.r a.r a.r];
    case "cylinder", bb = [-a.r -a.r -a.hz; a.r a.r a.hz];
    case "box",      bb = [-a.half -a.half -a.half; a.half a.half a.half];
    otherwise,       bb = [NaN NaN NaN; NaN NaN NaN];
end
end

function pr = newPairRow()
pr = struct('i', 0, 'j', 0, 'id_i', '', 'id_j', '', 'role_i', '', 'role_j', '', ...
    'display_only_any', false, 'expected_coincident', false, 'aabb_overlap', false, ...
    'aabb_separation_m', NaN, 'n_candidate_pairs', 0, 'n_tested_pairs', 0, ...
    'n_face_hits', 0, 'coplanar_contact_pairs', 0, 'n_penetrating_pairs', 0, ...
    'not_fully_evaluated', false, 'min_gap_m', NaN, 'gap_method', '', 'gap_exact', false, ...
    'gap_resolved_above_threshold', false, 'penetration_depth_m', NaN, ...
    'overlap_volume_m3', NaN, 'overlap_volume_status', '', 'flagged', false, ...
    'faces_subsampled', false);
pr.hits = {};
pr.flags = {};
end

function pr = checkPair(A, B, i, j, gapMin, penTol, op, nbMax)
pr = newPairRow();
pr.i = i;
pr.j = j;
pr.id_i = A.part_id;
pr.id_j = B.part_id;
pr.role_i = A.transport_role;
pr.role_j = B.transport_role;
pr.display_only_any = A.display_only || B.display_only;
pr.faces_subsampled = A.faces_subsampled || B.faces_subsampled;
pr.expected_coincident = pairIsExpectedCoincident(A, B);

if strcmp(A.geom_kind, 'no_geometry') || strcmp(B.geom_kind, 'no_geometry')
    pr.gap_method = 'not_computed_missing_geometry';
    pr.overlap_volume_status = 'not_computed_missing_geometry';
    pr.not_fully_evaluated = true;
    pr.flags{end+1} = 'NO_GEOMETRY'; %#ok<AGROW>
    pr.flagged = true;
    return
end

[ov, sep] = aabbRel(A.aabb, B.aabb);
pr.aabb_overlap = ov;
pr.aabb_separation_m = sep;

% --- 最小间隙 ---
[gap, gmethod, gexact, gresolved] = pairGap(A, B, sep, gapMin, op);
pr.min_gap_m = gap;
pr.gap_method = gmethod;
pr.gap_exact = gexact;
pr.gap_resolved_above_threshold = gresolved;

% --- 面-面相交 (与间隙判据互相独立: 间隙走下界捷径时相交判定照样要跑) ---
if ov && ~isempty(A.F) && ~isempty(B.F)
    [nHits, nCand, nTested, nCopro, nPen, hits, trunc] = faceIntersections(A, B, op, nbMax);
    pr.n_face_hits = nHits;
    pr.n_candidate_pairs = nCand;
    pr.n_tested_pairs = nTested;
    pr.coplanar_contact_pairs = nCopro;
    pr.n_penetrating_pairs = nPen;
    pr.hits = hits(1:min(numel(hits), double(op.MaxReportedHits)));
    pr.not_fully_evaluated = trunc;
    dep = 0;
    for s = 1:numel(pr.hits)
        dep = max(dep, pr.hits{s}.depth_m);
    end
    pr.penetration_depth_m = dep;
elseif ov
    pr.not_fully_evaluated = true;             % 盒子相接但没有可比对的网格
    pr.flags{end+1} = 'NOT_FULLY_EVALUATED'; %#ok<AGROW>
    pr.flagged = true;
end

% --- 重复体积 ---
% 体积判据要看面-面结论: 只有边界零接触 (既无穿插也无共面贴合) 才可能判"内含";
% 没跑完相交判定 (not_fully_evaluated) 时不得宣称零接触。
boundaryClear = pr.n_face_hits == 0 && pr.coplanar_contact_pairs == 0 && ...
    ~pr.not_fully_evaluated;
[vol, vstat] = overlapVolume(A, B, pr.expected_coincident, boundaryClear, ov);
pr.overlap_volume_m3 = vol;
pr.overlap_volume_status = vstat;

% --- 标志位: 设计上共面的对不混进"意外干涉", 但数值照实报 ---
contact = pr.n_face_hits > 0 || pr.coplanar_contact_pairs > 0;
if contact
    if pr.expected_coincident
        pr.flags{end+1} = 'EXPECTED_COINCIDENT_CONTACT'; %#ok<AGROW>
    else
        pr.flags{end+1} = 'FACE_INTERSECTION'; %#ok<AGROW>
        pr.flagged = true;
    end
end
if isfinite(pr.min_gap_m) && pr.min_gap_m < gapMin && ~pr.expected_coincident
    pr.flags{end+1} = 'GAP_BELOW_LIMIT'; %#ok<AGROW>
    pr.flagged = true;
end
if isfinite(pr.penetration_depth_m) && pr.penetration_depth_m > penTol
    pr.flags{end+1} = 'PENETRATION'; %#ok<AGROW>
    pr.flagged = true;
end
if isfinite(vol) && vol > 0
    if pr.expected_coincident
        pr.flags{end+1} = 'EXPECTED_COINCIDENT_DUPLICATE_VOLUME'; %#ok<AGROW>
    else
        pr.flags{end+1} = 'DUPLICATE_VOLUME'; %#ok<AGROW>
        pr.flagged = true;
    end
end
if pr.not_fully_evaluated
    pr.flags{end+1} = 'NOT_FULLY_EVALUATED'; %#ok<AGROW>
    pr.flagged = true;
end
end

function tf = pairIsExpectedCoincident(A, B)
% meshSpec 用 coincident_with 明写"与谁共面" (阴极与气腔共面是物理事实)。
tf = (~isempty(A.coincident_with) && any(strcmpi(A.coincident_with, B.part_id))) || ...
     (~isempty(B.coincident_with) && any(strcmpi(B.coincident_with, A.part_id)));
end

function [ov, sep] = aabbRel(a, b)
% ov = 两个 AABB 是否相接; sep = 不相接时的最小欧氏间距 (>=0, 沿轴分解), 相接时 0。
lo1 = a(1:3); hi1 = a(4:6);
lo2 = b(1:3); hi2 = b(4:6);
if ~all(isfinite([lo1 hi1 lo2 hi2]))
    ov = true;
    sep = 0;
    return
end
ov = all(lo1 <= hi2 & lo2 <= hi1);
if ov
    sep = 0;
else
    gapAx = max(0, max(lo2 - hi1, lo1 - hi2));
    sep = norm(gapAx);
end
end

function [gap, method, exact, resolved] = pairGap(A, B, sep, gapMin, op)
exact = false;
resolved = false;
gap = NaN;
% (a) 同心解析对: 闭式且精确
[g0, ok] = analyticGap(A, B);
if ok
    gap = g0;
    method = 'closed_form_concentric_analytic';
    exact = true;
    return
end
% (b) AABB 下界已越过阈值: 不抽样 (下界足以判定, 但它是下界不是精确值)
if sep > 0
    gap = sep;
    method = 'aabb_separation_lower_bound';
    resolved = gap > gapMin;
    return
end
% (c) 网格采样 + 交替投影 (近似)
if ~isempty(A.F) && ~isempty(B.F) && ~isempty(A.V) && ~isempty(B.V)
    [gap, iters] = sampledGap(A, B, op);
    method = sprintf('sampled_vertex_to_face_plus_alternating_projection_%d_iter', iters);
    return
end
method = 'not_computed_no_mesh_pair';
end

function [g, ok] = analyticGap(A, B)
% 只对"两侧都是解析体且同心/同轴"的对给闭式:
%   球-球: 内含时 |ra-rb|-d, 相离/相切时 max(0, d-ra-rb) (d = 球心距);
%   同轴等高圆柱: min(半径差, 半高差) —— 只看侧壁会漏掉端盖更近的情况。
g = NaN;
ok = false;
aa = A.analytic;
bb = B.analytic;
if aa.kind == "none" || bb.kind == "none", return; end
d = norm(A.centre - B.centre);
tolc = 1e-12*max(1, max(abs([A.centre B.centre])));
sameCentre = d <= tolc;
if aa.kind == "sphere" && bb.kind == "sphere"
    if d + min(aa.r, bb.r) <= max(aa.r, bb.r)
        g = abs(aa.r - bb.r) - d;
    else
        g = max(0, d - aa.r - bb.r);
    end
    ok = true;
elseif aa.kind == "cylinder" && bb.kind == "cylinder" && sameCentre
    g = min(abs(aa.r - bb.r), abs(aa.hz - bb.hz));
    ok = true;
end
end

function [g, iters] = sampledGap(A, B, op)
% 顶点到对面三角网格的最近距离 (两侧取小) + 交替投影局部优化。
% 近似的两个来源都写进 gap_method 或注释: (1) 只在顶点里采样, 真最近点可以在面内部,
% 残差同量级于网格弦偏差; (2) 交替投影是局部下降, 不保证全局最优。
nA = size(A.V, 1);
nB = size(B.V, 1);
stA = max(1, ceil(nA/max(1, double(op.MaxGapSamples))));
stB = max(1, ceil(nB/max(1, double(op.MaxGapSamples))));
VA = A.V(1:stA:end, :);
VB = B.V(1:stB:end, :);
dA = nearestFaceDist(VA, B);
dB = nearestFaceDist(VB, A);
[gA, rA] = min(dA);
[gB, rB] = min(dB);
if gA <= gB
    [g, iters] = refineGap(VA(rA, :), B, A);
else
    [g, iters] = refineGap(VB(rB, :), A, B);
end
g = min(g, min(gA, gB));
end

function dmin = nearestFaceDist(Q, Gk)
% Q 每点到 Gk 网格的最近距离 (面按均匀网格粗筛后逐面精算)。
m = size(Q, 1);
dmin = inf(m, 1);
for t = 1:m
    dmin(t) = nearestFaceFromPoint(Q(t, :), Gk);
end
end

function [d, fidx] = nearestFaceFromPoint(q, Gk)
cand = cellQueryNear(Gk.grid, q, 8);
nf = size(Gk.F, 1);
if isempty(cand)
    % 兜底: 桶里一直找不到面 (点远在网格之外) 时做**有界**全表扫, 而不是无声返回 inf。
    cand = 1:ceil(nf/2000);
end
d = inf;
fidx = 1;
if nf == 0
    return
end
[d, ks] = pointToFaceSet(q, Gk.V, Gk.F, cand);
fidx = cand(ks);
end

function [dmin, kbest] = pointToFaceSet(q, V, F, cand)
dmin = inf;
kbest = 1;
for s = 1:numel(cand)
    f = F(cand(s), :);
    d = norm(closestPointOnFace(q, V, f) - q);
    if d < dmin
        dmin = d;
        kbest = s;
    end
end
end

function p = closestPointOnFace(q, V, f)
% 点到三角形的最近点 (Ericson 区域法, 7 个 Voronoi 区)。
a = V(f(1), :);
b = V(f(2), :);
c = V(f(3), :);
ab = b - a;
ac = c - a;
pq = a - q;
d1 = dot(ab, pq);
d2 = dot(ac, pq);
if d1 <= 0 && d2 <= 0, p = a; return; end
bp = q - b;
d3 = dot(ab, bp);
d4 = dot(ac, bp);
if d3 >= 0 && d4 <= d3, p = b; return; end
vc = d1*d4 - d3*d2;
if vc <= 0 && d1 >= 0 && d3 <= 0
    p = a + (d1/(d1 - d3))*ab;
    return
end
cp = q - c;
d5 = dot(ab, cp);
d6 = dot(ac, cp);
if d6 >= 0 && d5 <= d6, p = c; return; end
vb = d5*d2 - d6*d1;
if vb <= 0 && d2 >= 0 && d6 <= 0
    p = a + (d2/(d2 - d6))*ac;
    return
end
va = d3*d6 - d5*d4;
if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0
    p = b + ((d4 - d3)/((d4 - d3) + (d5 - d6)))*(c - b);
    return
end
denom = 1/(va + vb + vc);
p = a + (vb*denom)*ab + (vc*denom)*ac;
end

function [g, iters] = refineGap(q, G1, G2)
% 交替投影: q (在 G1 上或附近) -> G2 上最近点 -> 该点到 G1 的最近点 -> 迭代。
if isempty(G1.F) || isempty(G2.F)
    g = NaN;
    iters = 0;
    return
end
[d0, ~] = nearestFaceFromPoint(q, G2);
g = d0;
p = q;
iters = 0;
for it = 1:12
    [d1, fB] = nearestFaceFromPoint(p, G2);
    cB = closestPointOnFace(p, G2.V, G2.F(fB, :));
    [d2, fA] = nearestFaceFromPoint(cB, G1);
    cA = closestPointOnFace(cB, G1.V, G1.F(fA, :));
    gNew = norm(cA - cB);
    iters = it;
    if ~isfinite(gNew), break; end
    improved = gNew < g*(1 - 1e-12);
    g = min(g, gNew);
    p = cA;
    if ~improved, break; end
end
end

function [nHits, nCand, nTested, nCopro, nPen, hits, truncated] = faceIntersections(A, B, op, nbMax) %#ok<INUSD>
% 面-面相交。候选来自 A 的面网格 (B 的面按其 AABB 落在哪些格里查), 精判用双向平面跨越
% 筛 + 线段-三角形相交; 近共面对单独计数。
hits = {};
nHits = 0;
nCopro = 0;
nPen = 0;
truncated = false;
gA = A.grid;
feB = B.grid.fe;
if isempty(gA.bins) || isempty(feB)
    nCand = 0;
    nTested = 0;
    return
end
ia = zeros(0,1);
ib = zeros(0,1);
for t = 1:size(B.F, 1)
    c = cellQueryBox(gA, feB(t, :));
    if isempty(c), continue; end
    for s = 1:numel(c)
        lst = gA.bins{c(s)};
        if isempty(lst), continue; end
        ia = [ia; lst(:)]; %#ok<AGROW>
        ib = [ib; repmat(t, numel(lst), 1)]; %#ok<AGROW>
    end
end
% 同一对面可能同时落在多个共享格子里 -> 按 (i,j) 键去重 (索引键, 不做浮点比较)。
[~, uix] = unique((ia - 1)*size(B.F, 1) + ib);
ia = ia(uix);
ib = ib(uix);
nCand = numel(ia);
nTested = nCand;
if nCand == 0, return; end
if nCand > double(op.MaxCandidatePairs)
    ia = ia(1:op.MaxCandidatePairs);
    ib = ib(1:op.MaxCandidatePairs);
    nTested = numel(ia);
    truncated = true;
end
a1 = A.V(A.F(ia,1),:); a2 = A.V(A.F(ia,2),:); a3 = A.V(A.F(ia,3),:);
b1 = B.V(B.F(ib,1),:); b2 = B.V(B.F(ib,2),:); b3 = B.V(B.F(ib,3),:);
nA = cross(a2 - a1, a3 - a1, 2);
nA = nA./max(sqrt(sum(nA.^2,2)), realmin);
nB = cross(b2 - b1, b3 - b1, 2);
nB = nB./max(sqrt(sum(nB.^2,2)), realmin);
epsA = epsLen(A);
epsB = epsLen(B);
sA1 = sum((b1 - a1).*nA, 2); sA2 = sum((b2 - a1).*nA, 2); sA3 = sum((b3 - a1).*nA, 2);
sB1 = sum((a1 - b1).*nB, 2); sB2 = sum((a2 - b1).*nB, 2); sB3 = sum((a3 - b1).*nB, 2);
crossA = ~(allPos(sA1,sA2,sA3,epsA) | allNeg(sA1,sA2,sA3,epsA));
crossB = ~(allPos(sB1,sB2,sB3,epsB) | allNeg(sB1,sB2,sB3,epsB));
coplanar = abs(sum(nA.*nB, 2)) > 1 - 1e-9 & abs(sA1) <= epsA & abs(sB1) <= epsB;
sel = find(crossA & crossB & ~coplanar);
% 共面类候选以前整类丢弃 (线段-三角形法对"交线躺在两面片自身平面内"的情形先天失效,
% segTri 的 |a| < 1e-30 早退就是它的表现), 于是轴对齐零件的共面穿插被静默漏报。现在这一类
% 改判为面内 2D 面积求交: 覆盖输入 = **两面片同平面且重合面积为正**的一切情形 (轴对齐盒、
% 棱柱、任意平面上的三角剖分都在内), 不按盒子形状特判; 重合面积低于阈 (贴边/贴点) 不记。
scLen = max([1e12*epsA, 1e12*epsB, 1e-9]);
tol2 = 1e-12*scLen;
areaTol = 1e-12*scLen^2;
ipc = find(coplanar);
nCopro = 0;
for r0 = 1:numel(ipc)
    r = ipc(r0);
    [ok, ph, ar] = coplanarTriOverlap(a1(r, :), a2(r, :), a3(r, :), ...
        b1(r, :), b2(r, :), b3(r, :), nA(r, :), tol2, areaTol);
    if ~ok
        continue
    end
    nCopro = nCopro + 1;
    nHits = nHits + 1;
    dep = intrusionDepth(a1(r, :), a2(r, :), a3(r, :), b1(r, :), b2(r, :), b3(r, :), ...
        nA(r, :), nB(r, :), A.centre, B.centre);
    if dep > 0, nPen = nPen + 1; end
    hits{end+1} = struct('face_i', ia(r), 'face_j', ib(r), 'point_m', ph, 'depth_m', dep, ...
        'contact_area_m2', ar, 'kind', 'coplanar'); %#ok<AGROW>
end
for s = 1:numel(sel)
    r = sel(s);
    [hit, ph] = triTriSegmentTest(a1(r,:), a2(r,:), a3(r,:), b1(r,:), b2(r,:), b3(r,:));
    if ~hit
        continue
    end
    nHits = nHits + 1;
    dep = intrusionDepth(a1(r,:), a2(r,:), a3(r,:), b1(r,:), b2(r,:), b3(r,:), ...
        nA(r,:), nB(r,:), A.centre, B.centre);
    if dep > 0, nPen = nPen + 1; end
    hits{end+1} = struct('face_i', ia(r), 'face_j', ib(r), 'point_m', ph, 'depth_m', dep, ...
        'contact_area_m2', 0, 'kind', 'transversal'); %#ok<AGROW>
end
end

function e = epsLen(Gk)
sc = 1;
if ~isempty(Gk.V)
    sc = max(norm(max(Gk.V) - min(Gk.V)), realmin);
end
e = 1e-12*sc;
end

function tf = allPos(a,b,c, e)
tf = a >= -e & b >= -e & c >= -e & (a > e | b > e | c > e);
end

function tf = allNeg(a,b,c, e)
tf = a <= e & b <= e & c <= e & (a < -e | b < -e | c < -e);
end

function [hit, ph] = triTriSegmentTest(a1,a2,a3, b1,b2,b3)
% 线段-三角形相交判定: A 的三条边对 B 三角形, 再反向。这覆盖全部非共面相交情形
% (两三角形相交时交线至少穿过一方的两条边); 共面情形由 coplanar 分支单独计数。
ph = [NaN NaN NaN];
hit = false;
A12 = [a1; a2; a3];
A23 = [a2; a3; a1];
B12 = [b1; b2; b3];
B23 = [b2; b3; b1];
for k = 1:3
    [ok, p] = segTri(A12(k,:), A23(k,:), b1, b2, b3);
    if ok, hit = true; ph = p; return; end
end
for k = 1:3
    [ok, p] = segTri(B12(k,:), B23(k,:), a1, a2, a3);
    if ok, hit = true; ph = p; return; end
end
end

function [ok, p] = segTri(p1, p2, v1, v2, v3)
% Moller-Trumbore 线段与三角形 (容差在重心坐标上, 与尺度无关)。
ok = false;
p = [NaN NaN NaN];
d = p2 - p1;
e1 = v2 - v1;
e2 = v3 - v1;
h = cross(d, e2);
a = dot(e1, h);
if abs(a) < 1e-30, return; end
f = 1/a;
s = p1 - v1;
u = f*dot(s, h);
if u < -1e-9 || u > 1 + 1e-9, return; end
q = cross(s, e1);
v = f*dot(d, q);
if v < -1e-9 || u + v > 1 + 1e-9, return; end
t = f*dot(e2, q);
if t < -1e-9 || t > 1 + 1e-9, return; end
u = min(max(u, 0), 1);
v = min(max(v, 0), 1);
p = v1 + u*e1 + v*e2;
ok = true;
end

function dep = intrusionDepth(a1,a2,a3, b1,b2,b3, nA, nB, cA, cB)
% 局部平面近似的侵入量: 每侧顶点到对方三角形平面的深度取最大, 两侧取小 (不夸大)。
sA = outSign(nA, (a1 + a2 + a3)/3, cA);
sB = outSign(nB, (b1 + b2 + b3)/3, cB);
dA = max(-sB*[dot(a1 - b1, nB); dot(a2 - b1, nB); dot(a3 - b1, nB)]);
dB = max(-sA*[dot(b1 - a1, nA); dot(b2 - a1, nA); dot(b3 - a1, nA)]);
dep = max(0, min(dA, dB));
if ~isfinite(dep), dep = 0; end
end

function s = outSign(nf, faceCentre, starCentre)
% 返回 +1 表示 nf 已朝外 (面心相对星心的方向与 nf 同号), 否则 -1。
if norm(nf) < 1e-30
    s = 1;
    return
end
if dot(nf, faceCentre - starCentre) >= 0
    s = 1;
else
    s = -1;
end
end

function [vol, status] = overlapVolume(A, B, expected, boundaryClear, aabbOverlap)
% 重复体积的取数顺序: (1) 零件表自带解析体且有闭式就用闭式 (精确, 与网格离散化无关);
% (2) 闭式给不出的走网格路线 (AABB 隔开 -> 精确 0, 内含 -> 内体体积, 凸-凸 -> 半空间裁剪)。
% 两条路都给不出的落 not_computed_*, 原因写进状态串, 不留"NaN 但没说为什么"。
vol = NaN;
status = '';
fb = 'not_computed_no_closed_form';        % 网格路线也说不清时的兜底原因
aa = A.analytic;
bb = B.analytic;
if aa.kind == "none" || bb.kind == "none"
    fb = 'not_computed_not_analytic';
else
    d = norm(A.centre - B.centre);
    if expected && aa.kind == bb.kind && abs(aa.r - bb.r) <= 1e-15*max(1, aa.r) && d == 0
        % 同一实体被建成两张皮 (例如阴极与气腔): 数学上交集就是该实体本身
        vol = solidVolume(aa);
        status = 'identical_solids_coincident_by_design';
        return
    end
    if aa.kind == "sphere" && bb.kind == "sphere"
        [vol, status] = sphereSphereVol(aa.r, bb.r, d);
        if isfinite(vol) && vol < 0, vol = 0; end
        return
    elseif aa.kind == "cylinder" && bb.kind == "cylinder" && d == 0
        h = 2*min(aa.hz, bb.hz);
        vol = pi*min(aa.r, bb.r)^2*h;
        status = 'closed_form_concentric_cylinders';
        return
    end
    fb = 'not_computed_pair_kind';
end
tol = 1e-12*max([partScale(A), partScale(B), 1e-9]);
[vol, status] = meshSolidOverlap(A, B, aabbOverlap, boundaryClear, tol);
if isempty(status) || strcmp(status, 'not_computed_not_mesh')
    % 一侧根本没有网格可比对: 原因回落到"解析对无闭式", 不另造含糊说法
    vol = NaN;
    status = fb;
end
end

function s = partScale(Gk)
% 零件的长度尺度 [m] (包围盒对角线), 一切容差按它无量纲化; 无网格时退到解析包围盒。
s = 0;
if ~isempty(Gk.V)
    s = norm(max(Gk.V, [], 1) - min(Gk.V, [], 1));
elseif any(isfinite(Gk.aabb))
    s = norm(Gk.aabb(4:6) - Gk.aabb(1:3));
end
s = max(s, 1e-9);
end

function v = solidVolume(a)
switch a.kind
    case "sphere",   v = 4/3*pi*a.r^3;
    case "cylinder", v = pi*a.r^2*2*a.hz;
    case "box",      v = 8*a.half^3;
    otherwise,       v = NaN;
end
end

function [v, status] = sphereSphereVol(r1, r2, d)
if d >= r1 + r2
    v = 0;
    status = 'closed_form_spheres_disjoint_or_touching';
elseif d + min(r1, r2) <= max(r1, r2)
    v = 4/3*pi*min(r1, r2)^3;
    status = 'closed_form_sphere_inside_sphere';
else
    % 两球交集体积闭式: V = pi (r1+r2-d)^2 (d^2 + 2d(r1+r2) - 3(r1-r2)^2) / (12 d)
    v = pi*(r1 + r2 - d)^2*(d^2 + 2*d*(r1 + r2) - 3*(r1 - r2)^2)/(12*d);
    status = 'closed_form_sphere_sphere';
end
end

%% ---------------- 实体网格: 闭合性 / 半空间 / 凸性 / 体积 ----------------

function [planes, closed, convex, vol, note] = solidMeshInfo(V, F)
% 逐零件算一次, 逐对复用:
%   closed  每条无向边恰被两个三角形共用 => 闭合 2-流形 (体元积分与环绕数判据的前提);
%   planes  半空间表示 [n(3) d], n 为单位外法向, 实体 = {x : n*x <= d};
%   convex  闭合 且 每个顶点满足全部半空间 (O(面数 x 顶点数), 超预算即"未判定"而非"凸");
%   vol     散度定理有向四面体求和 |sum(a.(b x c))/6|, 内含对的重体积就用它。
% 退化 (零面积) 三角形给不出法向, 又必须留作约束, 所以带退化面的网格一律不建半空间。
planes = zeros(0, 4);
closed = false;
convex = false;
vol = NaN;
note = 'no_mesh';
if isempty(V) || isempty(F) || size(V, 2) ~= 3 || size(F, 2) ~= 3
    return
end
a = V(F(:, 1), :);
b = V(F(:, 2), :);
c = V(F(:, 3), :);
vol = abs(sum(dot(a, cross(b, c, 2), 2))/6);
ed = [F(:, [1 2]); F(:, [2 3]); F(:, [3 1])];
ed = sort(ed, 2);                         % 每条无向边规范化成 (小, 大), 否则正反两次出现算两条
[~, ~, ic] = unique(ed, 'rows');
cnt = accumarray(ic, 1);
closed = all(cnt == 2);
note = 'ok';
if ~closed
    note = 'not_closed';
    return
end
n = cross(b - a, c - a, 2);
nn = sqrt(sum(n.^2, 2));
if any(nn <= 0)
    note = 'degenerate_face';
    return
end
n = n./repmat(nn, 1, 3);
body = mean(V, 1);
sgn = sign(sum(n .* (((a + b + c)/3) - repmat(body, size(a, 1), 1)), 2));
sgn(sgn == 0) = 1;                        % 面心与体心同轴时按原向保留
n = n.*repmat(sgn, 1, 3);                 % 统一到外法向 (缠绕方向无关)
planes = [n, sum(n.*a, 2)];
sc = norm(max(V, [], 1) - min(V, [], 1));
if size(V, 1)*size(F, 1) > 2.5e6
    note = 'convexity_not_tested_budget';
    return
end
if allVerticesInHalfSpaces(V, planes, 1e-12*max(sc, 1e-9))
    convex = true;
else
    note = 'non_convex';
end
end

function tf = allVerticesInHalfSpaces(V, planes, tol)
% 全部顶点是否满足全部半空间 (凸性)。分块控内存 (临时矩阵 <= 2e6 个双精度), 首个违例即否。
tf = false;
if isempty(planes) || size(planes, 1) < 4
    return
end
nv = size(V, 1);
nPl = size(planes, 1);
blk = max(1, min(nPl, floor(2.0e6/nv)));
for k0 = 1:blk:nPl
    idx = k0:min(k0 + blk - 1, nPl);
    s = V*planes(idx, 1:3).' - repmat(reshape(planes(idx, 4), 1, []), nv, 1);
    if max(s(:)) > tol
        return
    end
end
tf = true;
end

function tf = pointsInsideConvex(P, planes, tol)
% 点集是否严格在凸体内部: 全部半空间都留 tol 的余量 (贴边不算内含)。
tf = false;
if isempty(planes) || size(planes, 1) < 4
    return
end
s = P*planes(:, 1:3).' - repmat(reshape(planes(:, 4), 1, []), size(P, 1), 1);
tf = all(s(:) < -tol);
end

function [inside, sure] = pointsInsideClosedMesh(P, V, F, tol)
% 点是否在闭合网格内部: 带符号立体角 (Gauss 映射) 的环绕数 w = sum(omega)/(4 pi)。
% 选它而不是射线奇偶性的理由: 射线法在"射线穿过边/顶点"处必须靠人为计数约定, 而这里的
% 零件全是轴对齐多面体, 沿任何坐标轴射出的射线都会成批地穿过共边与共顶点, 约定稍有偏差
% 就是成片同向误判; 立体角和对查询点连续 (点不在面上时), 没有这种离散退化, 唯一奇异是
% 查询点恰落在某三角形上 (num = den = 0), 该处显式置 sure = false 让调用方放弃结论。
% 代价 O(点数 x 面数), 逐点早退并有预算闸, 超预算只降级为 not_computed。
inside = false;
sure = false;
if isempty(F) || size(P, 1) == 0
    return
end
a0 = V(F(:, 1), :);
b0 = V(F(:, 2), :);
c0 = V(F(:, 3), :);
inside = true;
sure = true;
for k = 1:size(P, 1)
    a = a0 - repmat(P(k, :), size(F, 1), 1);
    b = b0 - repmat(P(k, :), size(F, 1), 1);
    c = c0 - repmat(P(k, :), size(F, 1), 1);
    la = sqrt(sum(a.^2, 2));
    lb = sqrt(sum(b.^2, 2));
    lc = sqrt(sum(c.^2, 2));
    den = la.*lb.*lc + dot(a, b, 2).*lc + dot(b, c, 2).*la + dot(c, a, 2).*lb;
    num = dot(a, cross(b, c, 2), 2);
    if any(hypot(num, den) <= tol^3)     % 查询点落在某个三角形上 -> 既非内也非外
        sure = false;
        inside = false;
        return
    end
    % 立体角 omega = 2*atan2(num, den) (Van Oosterom-Strackee), 闭合面的 sum(omega) = ±4*pi。
    % 少乘 2 会让内含点的环绕数变成 ±0.5, 恰好落进"模糊带"而误判为不含。
    w = sum(2*atan2(num, den))/(4*pi);
    if abs(w) < 0.9                       % 0.1~0.9 之间是"贴边"的模糊带, 不下结论
        sure = false;
        inside = false;
        return
    end
end
end

function [vol, status] = containedInnerVolume(Inner, Outer, tol)
% 内含: Inner 全部顶点严格在 Outer 内部 (边界接触已由调用方排除) => 交集 = Inner 自身,
% 体积直接取 Inner 网格的散度定理和, 不做体素或抽样。方向无关: 调用方两个朝向各试一次。
vol = NaN;
status = '';
if ~Inner.closed || ~Outer.closed || ~isfinite(Inner.mesh_volume_m3)
    return
end
if size(Inner.V, 1)*size(Outer.F, 1) > 3.0e5
    status = 'not_computed_containment_budget';
    return
end
if Outer.convex
    isin = pointsInsideConvex(Inner.V, Outer.planes, tol);
else
    [isin, sure] = pointsInsideClosedMesh(Inner.V, Outer.V, Outer.F, tol);
    isin = isin && sure;
end
if isin
    vol = Inner.mesh_volume_m3;
    status = 'contained_inner_volume';
end
end

function [vol, status] = meshSolidOverlap(A, B, aabbOverlap, boundaryClear, tol)
% 网格零件对的重复体积。三条能给出确定值的路, 其余落显式 not_computed_* (带原因):
%   1) AABB 已隔开 => A∩B 必空 => 精确 0 (只用同一份 AABB 里的保守事实, 不引入近似);
%   2) 内含 (无边界接触 + 一方顶点全在另一方内部) => 内体自身体积;
%   3) 凸-凸 => 把 A 的半空间交集再按 B 的半空间逐面裁剪, 得交集凸多面体, 散度定理给体积。
% 抽样过面的零件 (faces_subsampled) 的网格不再闭合, 半空间与环绕数都不成立, 一律不判。
vol = NaN;
status = '';
if ~strcmp(A.geom_kind, 'mesh') || ~strcmp(B.geom_kind, 'mesh')
    status = 'not_computed_not_mesh';
    return
end
if A.faces_subsampled || B.faces_subsampled
    status = 'not_computed_faces_subsampled';
    return
end
if ~A.closed || ~B.closed
    status = 'not_computed_mesh_not_closed';
    return
end
if ~aabbOverlap
    vol = 0;
    status = 'closed_form_aabb_disjoint';
    return
end
if boundaryClear
    [v1, s1] = containedInnerVolume(A, B, tol);
    if isfinite(v1)
        vol = v1;
        status = s1;
        return
    end
    [v2, s2] = containedInnerVolume(B, A, tol);
    if isfinite(v2)
        vol = v2;
        status = s2;
        return
    end
end
if A.convex && B.convex
    [vol, status] = convexClipVolume(A, B, tol);
    return
end
if ~(A.convex && B.convex)
    status = 'not_computed_not_convex_mesh';
else
    status = 'not_computed_convex_clip_budget';
end
end

function [vol, status] = convexClipVolume(A, B, tol)
% 凸-凸交集体积: 起点取一个必定罩住 A∩B 的长方体 (两侧 AABB 相交盒外扩 pad), 依次用 A、B
% 的全部面平面做 Sutherland-Hodgman 半空间裁剪。每个半空间裁完必须给"真正被切到"的面补
% 盖子 (见 clipOnePlane), 否则表面开口、散度定理求和报废 —— 只裁面不补盖是常见坑。
% 凸多面体被半空间裁完仍凸, 所以盖子与其余面环的扇形三角化都是精确的。
vol = NaN;
status = '';
pl = dedupePlanes([A.planes; B.planes], tol);
if size(pl, 1) > 128
    status = 'not_computed_convex_clip_budget';
    return
end
lo = max(A.aabb(1:3), B.aabb(1:3));
hi = min(A.aabb(4:6), B.aabb(4:6));
pad = max([0.05*max(hi - lo); 10*tol]);    % 贴合/零厚度时起点盒仍非退化, 交给裁剪去塌
poly = boxPolyhedron(lo - pad, hi + pad);
scB = norm(2*pad + (hi - lo));
areaTol = 1e-12*max(scB, 1e-9)^2;          % 低于此面积的面片是零厚度碎屑
for k = 1:size(pl, 1)
    poly = clipOnePlane(poly, pl(k, 1:3), pl(k, 4), tol);
    tot = 0;
    for q = 1:numel(poly)
        tot = tot + size(poly{q}, 1);
    end
    if tot > 20000
        status = 'not_computed_convex_clip_budget';
        return
    end
end
if isempty(poly)
    vol = 0;
    status = 'convex_clip_disjoint_or_touching';
    return
end
% 维度判据必须先于体积判据: 顶点只张成二维 (贴合面) 时留下的表面是开壳, 对开壳做
% 散度定理求和得到的是"以坐标原点为锥顶的锥体体积" —— 2x2 的贴合方给 4/3, 与重叠
% 体积毫无关系, 而它比下面的绝对噪声阈值大得多, 单靠体积阈值拦不住。
if isFlatDegenerate(poly, tol)
    vol = 0;
    status = 'convex_clip_disjoint_or_touching';
    return
end
vol = abs(polyVolume(poly));
if ~isfinite(vol) || vol <= 1e-11*max(scB, 1e-9)^3
    % 零厚度 (面贴合) 时留存的体积与"胀出 + 扇形项舍入噪声"不可分, 按无重复体积报
    vol = 0;
    status = 'convex_clip_disjoint_or_touching';
    return
end
status = 'convex_clip_intersection_polyhedron';
end

function tf = isFlatDegenerate(poly, tol)
% 顶点集是否张不满三维: 中心化后取奇异值 (降序), 最小奇异值低于"厚度容差"即判零厚度。
pts = vertcat(poly{:});
if size(pts, 1) < 4
    tf = true;
    return
end
s = svd(pts - mean(pts, 1));
% 两项都是长度 (米): 100*tol 是调用方贴合容差的量级, eps*s(1) 是该尺度下的浮点底。
% 不拿 s(3) 与 s(1) 的比值判: 那会让判据随尺度走 —— 2 m 级零件的真实薄穿透
% (厚度 ~1e-9 m, 恰好是 PenetrationTol_m) 会被误判成零厚度并自相矛盾地同时报穿透。
tf = numel(s) < 3 || s(3) <= max(100*tol, 1e3*eps*max(s(1), 1));
end

function p = dedupePlanes(planes, tol)
% 合并同一平面上重复三角形 (盒子的每个面都被对角剖成两三角形): 法向与偏距按 tol 量化取整
% 后去重, 同一键留第一条。量化只用于"找重复", 不参与任何体积判据。
if isempty(planes)
    p = planes;
    return
end
q = max(tol, 1e-15);
key = [round(planes(:, 1:3)/q), round(planes(:, 4)/q)];
[~, ix] = unique(key, 'rows');
p = planes(sort(ix), :);
end

function poly = clipOnePlane(poly, n, d, tol)
% 用一个半空间 (n*x <= d) 裁凸多面体: 先逐面环 S-H 裁剪, 再把被切面留在裁剪面上的那些边
% 连成环补成盖子。判定"被切"用面法向与裁剪面法向不平行 —— 与裁剪面平行的面本来就躺在边界
% 上 (共面贴合), 它不该产生盖子, 这正是轴对齐零件共面时既不漏盖也不重盖的关键。
capE = zeros(0, 6);
nxt = cell(0, 1);
for q = 1:numel(poly)
    P = clipLoop3(poly{q}, n, d, tol);
    if size(P, 1) < 3 || polyArea3(P) <= 1e-12*max(edgeLen3(P), 1e-9)^2
        continue
    end
    if abs(dot(faceNormal3(P), n)) <= 1 - 1e-9
        for k = 1:size(P, 1)
            k2 = mod(k, size(P, 1)) + 1;
            if abs(P(k, :)*n' - d) <= 10*tol && abs(P(k2, :)*n' - d) <= 10*tol
                capE = [capE; P(k, :), P(k2, :)]; %#ok<AGROW>
            end
        end
    end
    nxt{end+1} = P; %#ok<AGROW>
end
poly = nxt;
if isempty(capE)
    return
end
loop = chainEdges(capE, 100*tol);
if size(loop, 1) < 3
    return
end
if dot(cross(loop(2, :) - loop(1, :), loop(3, :) - loop(1, :)), n) < 0
    loop = loop(end:-1:1, :);               % 盖子的外法向必须指向被裁掉的那侧 (+n)
end
poly{end+1} = loop;
end

function loop = chainEdges(E, tol)
% 把落在裁剪面上的有向边首尾连成一个环 (允许反向接)。
loop = E(1, 1:3);
used = false(size(E, 1), 1);
used(1) = true;
loop(end+1, :) = E(1, 4:6);
for it = 1:size(E, 1)
    tail = loop(end, :);
    hit = false;
    for k = 2:size(E, 1)
        if used(k)
            continue
        end
        if norm(E(k, 1:3) - tail) <= tol
            loop(end+1, :) = E(k, 4:6); used(k) = true; hit = true; break
        end
        if norm(E(k, 4:6) - tail) <= tol
            loop(end+1, :) = E(k, 1:3); used(k) = true; hit = true; break
        end
    end
    if ~hit || norm(loop(end, :) - loop(1, :)) <= tol
        break
    end
end
if size(loop, 1) >= 3 && norm(loop(end, :) - loop(1, :)) <= tol
    loop = loop(1:end-1, :);                % 闭合点不重复存
else
    loop = zeros(0, 3);
end
end

function nn = faceNormal3(P)
% 面环的单位法向 (扇形叉积和)。
if size(P, 1) < 3
    nn = [0 0 0];
    return
end
cr = cross(P(2:end-1, :) - repmat(P(1, :), size(P, 1) - 2, 1), ...
    P(3:end, :) - repmat(P(1, :), size(P, 1) - 2, 1));
v = sum(cr, 1);
nn = v/max(norm(v), realmin);
end

function L = edgeLen3(P)
% 面环的最长边 [m], 用作面积阈的长度尺度。
L = 0;
for k = 1:size(P, 1)
    L = max(L, norm(P(k, :) - P(mod(k, size(P, 1)) + 1, :)));
end
end

function poly = boxPolyhedron(lo, hi)
% 起点长方体的 6 个外侧面环, 逐面用环向法向与外法向点积校正定向。
V = [lo(1) lo(2) lo(3); hi(1) lo(2) lo(3); hi(1) hi(2) lo(3); lo(1) hi(2) lo(3); ...
     lo(1) lo(2) hi(3); hi(1) lo(2) hi(3); hi(1) hi(2) hi(3); lo(1) hi(2) hi(3)];
L = [1 2 6 5; 2 3 7 6; 3 4 8 7; 4 1 5 8; 5 6 7 8; 1 4 3 2];
nOut = [0 0 -1; 1 0 0; 0 1 0; -1 0 0; 0 0 1; 0 -1 0];
poly = cell(1, 6);
for k = 1:6
    P = V(L(k, :), :);
    if dot(cross(P(2, :) - P(1, :), P(3, :) - P(1, :)), nOut(k, :)) < 0
        P = P(end:-1:1, :);
    end
    poly{k} = P;
end
end

function P = clipLoop3(P, n, d, tol)
% 单条闭合环对一个半空间的裁剪。
q = P*n' - d;
in = q <= tol;
m = size(P, 1);
out = zeros(0, 3);
for k = 1:m
    k2 = mod(k, m) + 1;
    f1 = q(k);
    f2 = q(k2);
    i1 = in(k);
    i2 = in(k2);
    if i1
        out(end+1, :) = P(k, :); %#ok<AGROW>
    end
    if i1 ~= i2 && f1 ~= f2
        t = f1/(f1 - f2);
        t = min(max(t, 0), 1);
        out(end+1, :) = P(k, :) + t*(P(k2, :) - P(k, :)); %#ok<AGROW>
    end
end
P = dropDupRows(out, tol);
end

function P = dropDupRows(P, tol)
% 丢掉相邻重复点 (裁剪在"顶点正好落在裁剪面上"时会产生), 含首尾闭合的重复。
if size(P, 1) < 2
    return
end
keep = true(size(P, 1), 1);
for k = 1:size(P, 1)
    k2 = mod(k, size(P, 1)) + 1;
    if norm(P(k, :) - P(k2, :)) <= tol
        keep(k2) = false;
    end
end
P = P(keep, :);
if size(P, 1) < 3
    P = zeros(0, 3);
end
end

function ar = polyArea3(P)
% 平面多边形的面积: 对第一条边做扇形叉积求和 (凸多边形精确)。
if size(P, 1) < 3
    ar = 0;
    return
end
cr = cross(P(2:end-1, :) - repmat(P(1, :), size(P, 1) - 2, 1), ...
    P(3:end, :) - repmat(P(1, :), size(P, 1) - 2, 1));
ar = norm(sum(cr, 1))/2;
end

function v = polyVolume(poly)
% 散度定理: V = sum over 面 (扇形三角化) 的 a.(b x c)/6。环向保持自起点盒的外定向。
v = 0;
for k = 1:numel(poly)
    P = poly{k};
    for q = 3:size(P, 1)
        v = v + dot(P(1, :), cross(P(q-1, :), P(q, :)))/6;
    end
end
end

%% ---------------- 共面三角形求交 (面内 2D) ----------------

function [hit, point, area] = coplanarTriOverlap(a1, a2, a3, b1, b2, b3, nrm, tol, areaTol)
% 两个共面三角形的面积求交: 投到面内 2D 基, 把 A 三角形按 B 的三条边半平面依次裁 (两边都
% 凸 => 交集是凸多边形), 面积超过 areaTol 才判"确有重合面片"。线段-三角法在这里必然失效
% (交线躺在两个面片自身的平面里), 所以这一类候选过去被整类丢掉。
hit = false;
point = [NaN NaN NaN];
area = 0;
[eu, ev] = planeBasis(nrm);
A2 = [a1; a2; a3]*[eu(:) ev(:)];
B2 = [b1; b2; b3]*[eu(:) ev(:)];
if signedArea2(B2) < 0
    B2 = B2([2 1 3], :);                  % 裁剪三角形取逆时针, 内侧即 cross(e, x-e1) >= 0
end
P = A2;
for k = 1:3
    if size(P, 1) < 3
        return
    end
    e1 = B2(k, :);
    e2 = B2(mod(k, 3) + 1, :);
    dv = e2 - e1;
    n = size(P, 1);
    f = zeros(n, 1);
    for s = 1:n
        f(s) = dv(1)*(P(s, 2) - e1(2)) - dv(2)*(P(s, 1) - e1(1));
    end
    in = f >= -tol;
    Q = zeros(0, 2);
    for s = 1:n
        s2 = mod(s, n) + 1;
        if in(s)
            Q(end+1, :) = P(s, :); %#ok<AGROW>
        end
        if in(s) ~= in(s2) && f(s) ~= f(s2)
            t = f(s)/(f(s) - f(s2));
            t = min(max(t, 0), 1);
            Q(end+1, :) = P(s, :) + t*(P(s2, :) - P(s, :)); %#ok<AGROW>
        end
    end
    Q = dropDupRows2(Q, tol);
    P = Q;
end
if size(P, 1) < 3
    return
end
area = abs(signedArea2(P));
if area <= areaTol
    return
end
cc = mean(P, 1);
point = cc(1)*eu + cc(2)*ev;
hit = true;
end

function [eu, ev] = planeBasis(n)
t = [1 0 0];
if abs(n(1)) > 0.9
    t = [0 1 0];
end
eu = cross(n, t);
eu = eu/max(norm(eu), realmin);
ev = cross(n, eu);
end

function a = signedArea2(P)
% 鞋带公式 (定向), 2D 多边形。
x = P(:, 1);
y = P(:, 2);
a = sum(x.*circshift(y, -1) - circshift(x, -1).*y)/2;
end

function P = dropDupRows2(P, tol)
if size(P, 1) < 2
    return
end
keep = true(size(P, 1), 1);
for k = 1:size(P, 1)
    k2 = mod(k, size(P, 1)) + 1;
    if norm(P(k, :) - P(k2, :)) <= tol
        keep(k2) = false;
    end
end
P = P(keep, :);
if size(P, 1) < 3
    P = zeros(0, 2);
end
end


%% ---------------- 均匀网格 (面 AABB 装桶) ----------------

function g = emptyGrid()
g = struct('lo', [0 0 0], 'd', [1 1 1], 'nb', 0, 'nFe', 0);
g.bins = {};
g.fe = zeros(0,6);
end

function g = buildGrid(V, F, nbMax)
% 面 AABB 装进均匀网格; 一个面登记进它 AABB 覆盖的所有格子 (面很小 => 通常 1-4 格)。
g = emptyGrid();
if isempty(F) || isempty(V)
    return
end
fe = faceAabb(V, F);
lo = min(fe(:,1:3), [], 1);
hi = max(fe(:,4:6), [], 1);
span = hi - lo;
span(span <= 0) = 1;
nb = min(nbMax, max(2, ceil(numel(F)^(1/3)*1.6)));
d = span/nb;
cells = cell(nb^3, 1);
tot = 0;
for r = 1:size(fe, 1)
    c1 = max(1, min(nb, floor((fe(r,1:3) - lo)./d) + 1));
    c2 = max(c1, min(nb, floor((fe(r,4:6) - lo)./d)));
    lin = cellBoxLin(c1, c2, nb);
    for s = 1:numel(lin)
        cells{lin(s)}(end+1) = r; %#ok<AGROW>
    end
    tot = tot + numel(lin);
end
g = struct('lo', lo, 'd', d, 'nb', nb, 'nFe', tot);
g.bins = cells;
g.fe = fe;
end

function lin = cellBoxLin(c1, c2, nb)
% 格子盒 [c1 c2] 的线性格号 (x 最快)。
ix = c1(1):c2(1);
iy = c1(2):c2(2);
iz = c1(3):c2(3);
lin = zeros(numel(ix)*numel(iy)*numel(iz), 1);
k = 0;
for a = iz
    for b = iy
        for cc = ix
            k = k + 1;
            lin(k) = (a-1)*nb*nb + (b-1)*nb + cc;
        end
    end
end
lin = lin(1:k);
end

function c = cellQueryBox(g, x6)
% 一个 AABB [lo hi] 覆盖的格子号。
c = [];
if isempty(g.bins) || g.nb <= 0, return; end
nb = g.nb;
d = g.d;
lo = g.lo;
i1 = max(1, min(nb, floor((x6(1:3) - lo)./d) + 1));
i2 = max(1, min(nb, floor((x6(4:6) - lo)./d) + 1));
i2 = max(i1, i2);
lin = cellBoxLin(i1, i2, nb);
lin = lin(lin >= 1 & lin <= numel(g.bins));
out = zeros(0,1);
for s = 1:numel(lin)
    v = g.bins{lin(s)};
    if ~isempty(v), out = [out; v(:)]; end %#ok<AGROW>
end
c = unique(out);
end

function c = cellQueryNear(g, q, maxRings)
% 点查询: 先查所在格, 空了就一圈圈扩到找到面为止 (避免"空桶 => 全表扫"的退化)。
c = [];
if isempty(g.bins) || g.nb <= 0, return; end
nb = g.nb;
d = g.d;
lo = g.lo;
i0 = max(1, min(nb, floor((q(1:3) - lo)./d) + 1));
for ring = 0:maxRings
    i1 = max(1, i0 - ring);
    i2 = min(nb, i0 + ring);
    lin = cellBoxLin(i1, i2, nb);
    lin = lin(lin >= 1 & lin <= numel(g.bins));
    out = zeros(0,1);
    for s = 1:numel(lin)
        v = g.bins{lin(s)};
        if ~isempty(v), out = [out; v(:)]; end %#ok<AGROW>
    end
    if ~isempty(out)
        c = unique(out);
        return
    end
end
end

function fe = faceAabb(V, F)
a = V(F(:,1),:);
b = V(F(:,2),:);
c = V(F(:,3),:);
% 逐面 AABB: min/max 的"两数组"形式没有第三/第四参数 (维度只在单参数形式里存在), 这里
% 按列两两取三元 min/max, 得 [xmin ymin zmin xmax ymax zmax]。
mn = min(min(a, b), c);
mx = max(max(a, b), c);
fe = [mn, mx];
end

%% ---------------- 分组与结论 ----------------

function s = summarizePairs(pairs, gapMin, penTol)
s = struct();
exp = [pairs.expected_coincident];
unexp = ~exp;
s.n_pairs = numel(pairs);
s.n_expected_coincident_pairs = nnz(exp);
s.n_aabb_overlapping = sum([pairs.aabb_overlap]);
s.n_aabb_overlapping_unexpected = sum([pairs.aabb_overlap] & unexp);
s.n_face_intersecting = sum([pairs.n_face_hits] > 0);
s.n_face_intersecting_unexpected = sum([pairs.n_face_hits] > 0 & unexp);
s.n_coplanar_contact = sum([pairs.coplanar_contact_pairs] > 0);
s.n_penetrating = sum([pairs.penetration_depth_m] > penTol);
s.n_penetrating_unexpected = sum([pairs.penetration_depth_m] > penTol & unexp);
s.n_below_gap_min = sum(isfinite([pairs.min_gap_m]) & [pairs.min_gap_m] < gapMin);
s.n_below_gap_min_unexpected = sum(isfinite([pairs.min_gap_m]) & ...
    [pairs.min_gap_m] < gapMin & unexp);
s.n_with_duplicate_volume = sum(isfinite([pairs.overlap_volume_m3]) & ...
    [pairs.overlap_volume_m3] > 0);
s.n_with_duplicate_volume_unexpected = sum(isfinite([pairs.overlap_volume_m3]) & ...
    [pairs.overlap_volume_m3] > 0 & unexp);
s.n_overlap_volume_not_computed = sum(countPrefix({pairs.overlap_volume_status}, 'not_computed'));
s.n_overlap_volume_contained_pairs = sum(strcmp({pairs.overlap_volume_status}, 'contained_inner_volume'));
s.n_overlap_volume_convex_clip_pairs = sum(countPrefix({pairs.overlap_volume_status}, 'convex_clip'));
s.n_not_fully_evaluated = sum([pairs.not_fully_evaluated]);
s.n_gap_approximate = sum(~[pairs.gap_exact]);
s.min_gap_overall_m = minOrNaN([pairs.min_gap_m]);
s.max_penetration_overall_m = maxOrNaN([pairs.penetration_depth_m]);
s.max_overlap_volume_overall_m3 = maxOrNaN([pairs.overlap_volume_m3]);
s.n_face_pairs_tested_total = sum([pairs.n_tested_pairs]);
end

function v = countPrefix(cellArr, pref)
% 统计 cell 里以 pref 开头的条目 (不用 strncmpc 同名遮蔽内建函数)。
v = false(numel(cellArr), 1);
for k = 1:numel(cellArr)
    s = char(cellArr{k});
    v(k) = numel(s) >= numel(pref) && strcmp(s(1:numel(pref)), pref);
end
end

function v = minOrNaN(x)
x = x(isfinite(x));
if isempty(x), v = NaN; else, v = min(x); end
end

function v = maxOrNaN(x)
x = x(isfinite(x));
if isempty(x), v = NaN; else, v = max(x); end
end

function grp = groupByRole(P, pairs)
% 按 transport_role 分栏。每栏的 not_consumed_by_transport + reading_guard 是这块的要点:
% 输运链不消费的实体, 它的"0 相交 / 0 敏感度"只说明它不在输运几何里, 不是"不重要"。
roles = unique(lower(string({P.transport_role})));
grp = repmat(emptyGroup(), 1, numel(roles));
for r = 1:numel(roles)
    rr = string(roles(r));
    isMem = lower(string({P.transport_role})) == rr;
    idx = find(isMem);
    modes = unique(lower(string({P(isMem).transport_mode})));
    consumed = any(ismember(modes, ["mc_chord_and_csda", "energy_loss_table"])) || ...
               any(lower(string({P(isMem).transport_role})) == "enter_mc");
    sel = pairTouches(pairs, idx);
    grp(r).role = char(rr);
    grp(r).n_parts = nnz(isMem);
    grp(r).part_ids = {P(isMem).part_id};
    grp(r).transport_modes = cellstr(modes);
    grp(r).consumed_by_transport = consumed;
    grp(r).not_consumed_by_transport = ~consumed;
    grp(r).consumed_by_detector_field = any(ismember(modes, "field_model_only"));
    grp(r).n_pairs = numel(sel);
    grp(r).n_aabb_overlapping = sum([sel.aabb_overlap]);
    grp(r).n_face_hits = sum([sel.n_face_hits]);
    grp(r).n_expected_coincident_pairs = sum([sel.expected_coincident]);
    grp(r).n_coplanar_contact = sum([sel.coplanar_contact_pairs]);
    grp(r).n_flagged = sum([sel.flagged]);
    grp(r).min_gap_m = minOrNaN([sel.min_gap_m]);
    grp(r).max_penetration_m = maxOrNaN([sel.penetration_depth_m]);
    grp(r).max_overlap_volume_m3 = maxOrNaN([sel.overlap_volume_m3]);
    if consumed
        grp(r).reading_guard = '本组被输运链消费: 0 相交是有意义的通过判据。';
    else
        grp(r).reading_guard = ['本组不被输运链消费: 0 相交 / 0 敏感度只说明它不在输运几何里, ' ...
            '不得读成"该实体对结果不敏感"; 它的敏感性要由它真正服务的链 (场/显示/合同位) 另评。'];
    end
end
end

function g = emptyGroup()
g = struct('role', '', 'n_parts', 0, 'n_pairs', 0, 'n_aabb_overlapping', 0, ...
    'n_face_hits', 0, 'n_expected_coincident_pairs', 0, 'n_coplanar_contact', 0, ...
    'n_flagged', 0, 'consumed_by_transport', false, 'not_consumed_by_transport', true, ...
    'consumed_by_detector_field', false, 'min_gap_m', NaN, 'max_penetration_m', NaN, ...
    'max_overlap_volume_m3', NaN, 'reading_guard', '');
g.part_ids = {};
g.transport_modes = {};
end

function sel = pairTouches(pairs, idx)
if isempty(pairs)
    sel = pairs;
    return
end
tf = ismember([pairs.i], idx) | ismember([pairs.j], idx);
sel = pairs(tf);
end

function v = verdictOf(s)
% 结论分档, 且明写为什么没到 OK: 任何"没算完"都不许伪装成"通过"。
% 设计上共面的对不进入意外干涉判据, 只进 expected 计数。
if s.n_penetrating_unexpected > 0
    v = 'PENETRATION';
elseif s.n_face_intersecting_unexpected > 0
    v = 'FACE_INTERSECTION';
elseif s.n_below_gap_min_unexpected > 0
    v = 'GAP_BELOW_LIMIT';
elseif s.n_with_duplicate_volume_unexpected > 0
    v = 'DUPLICATE_VOLUME';
elseif s.n_not_fully_evaluated > 0
    v = 'PARTIAL_NOT_FULLY_EVALUATED';
elseif s.n_expected_coincident_pairs > 0
    v = 'OK_ONLY_EXPECTED_COINCIDENT_CONTACT';
else
    v = 'OK';
end
end
