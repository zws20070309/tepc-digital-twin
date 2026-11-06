function M = checkMesh(spec)
%CHECKMESH 网格质量门禁 (闭合性 / 流形性 / 法向朝向 / 尺寸一致性)。
%
%   M = checkMesh(spec)   % 只吃 meshSpec 产的 spec, 不重新构造几何
%
% 逐项门禁 (每一项都必须**可失败**, 否则不是门禁):
%   closed                 每个零件的表面闭合 (每条无向边恰被 2 个面共用)
%   nonmanifold_edges      非流形边总数 = 0
%   zero_area_faces        零面积(退化)三角形数 = 0
%   normals_consistent_outward  逐面法向与 (面心 - 星心) 同号 (一致朝外)
%   min_skin_gap_m         壳层内/外皮之间的最小径向间隙 > 1e-6 m
%   max_radius_err_rel / wall_thickness_err_rel <= 1e-3 (0.1%)
%   meshSpec_duplicate_vertices  **对 meshSpec 产物实测**的重复顶点数
%   convexhull_note        为什么不用 sphere(n)/convexHull 直接网格: 本机实测数字
%
% 两条**环境事实**决定了这里的做法 (本机实测, 不静默降级):
%   1) "用 convexHull 凸包 或 uniquetol 焊接 + 丢弃退化面" 这条路在本机走不通: R2025a 实测
%      `convexHull(P)` 对 double 输入不存在 (只有 delaunayTriangulation(...).convexHull
%      类方法), 且 sphere(n) 点阵含重复极点与接缝列 => 直接 triangulation(...) 会打印
%      "检测到重复数据点并已将其删除"。故 meshSpec 的网格**从源头不产生重复顶点**
%      (极点只留 1 个、经度按模取列、极区用三角扇), "焊接"被"不产生重复"替代; 本函数
%      用实测重复顶点数把它钉成可失败的判据, 并在 convexhull_note 里给出把 sphere(n)
%      按 surf 四边形直接三角化后的实测零面积/非流形/开边数。
%   2) polyVolume / faceAreas / totalArea 三个 triangulation 方法在本机
%      R2025a **不存在** (@triangulation 目录实测无此文件, methods() 亦无)。这里用同
%      一数学的闭式实现: 有向体积 = sum(dot(v1,cross(v2,v3)))/6 (散度定理, 与
%      polyVolume 同式), 面积 = |cross(v2-v1,v3-v1)|/2。freeBoundary 可用, 保留为闭合
%      性的**第二判据** (仅在无重复顶点时调用, 以免触发上面那条警告)。
%
% 单位: 输入 SI (米); 阈值要么是相对量(无量纲) 要么是米。

if ~isfield(spec,'parts') || isempty(spec.parts)
    error("tepc:geometry:BadSpec","checkMesh 需要 meshSpec 产的 spec (含 parts 表)");
end

TOL_GAP_M = 1e-6;                            % 内外皮不得交叉
TOL_DIM   = 1e-3;                            % 内径/壁厚抽样测量误差 <= 0.1%

P = spec.parts;
out = repmat(newPartRow(), 1, numel(P));
totNonmanifold = 0;
totZeroArea = 0;
totDup = 0;
allClosed = true;
allNormals = true;
maxRadErr = 0;
minGap = Inf;
gapApplied = false;

for k = 1:numel(P)
    V = double(P(k).V); F = double(P(k).F);
    r = out(k);
    r.part_id = P(k).part_id;
    r.units = char(string(spec.units));
    r.n_vertices = size(V,1);
    r.n_faces = size(F,1);
    if isempty(V) || isempty(F)
        r.closed = false;
        out(k) = r; allClosed = false;
        continue;
    end

    % --- 重复顶点: 从源头就不该有 (见文件头环境事实 1) ---
    r.duplicate_vertices = countExactDuplicateRows(V);
    totDup = totDup + r.duplicate_vertices;

    % --- 零面积三角形 ---
    ar = faceAreasLocal(V,F);
    r.zero_area_faces = sum(ar <= 0);
    totZeroArea = totZeroArea + r.zero_area_faces;

    % --- 边流形性 + 闭合性 (与 freeBoundary 同判据) ---
    cnt = edgeCounts(F);
    r.nonmanifold_edges = sum(cnt ~= 2);
    r.closed = all(cnt == 2);
    totNonmanifold = totNonmanifold + r.nonmanifold_edges;
    allClosed = allClosed && r.closed;

    % --- freeBoundary: 第二意见 (无重复顶点时才调用, 避免 triangulation 删点警告) ---
    if r.duplicate_vertices == 0 && r.zero_area_faces == 0
        try
            T = triangulation(F, V);
            r.free_boundary_edges = size(T.freeBoundary(), 1);
        catch
            r.free_boundary_edges = NaN;      % 不可用就如实标 NaN, 不静默当 0
        end
    end

    % --- 法向一致朝外: dot(n_f, centroid_f - star_centre) > 0 ---
    c = double(P(k).star_centre_m(:)).';
    nf = faceNormalsLocal(V,F);
    cf = [(V(F(:,1),1)+V(F(:,2),1)+V(F(:,3),1))/3, ...
          (V(F(:,1),2)+V(F(:,2),2)+V(F(:,3),2))/3, ...
          (V(F(:,1),3)+V(F(:,2),3)+V(F(:,3),3))/3];
    s = sum(nf .* (cf - repmat(c, size(cf,1), 1)), 2);
    r.normals_outward = all(s > 0);
    r.wrong_handed_faces = sum(s <= 0);
    allNormals = allNormals && r.normals_outward;

    % --- 网格体积/面积 vs 解析闭式 (meshSpec 的 analyticVolume/analyticArea) ---
    r.volume_m3 = meshVolume(V,F);
    r.area_m2 = sum(ar);
    r.analyticVolume_m3 = P(k).analyticVolume_m3;
    r.analyticArea_m2 = P(k).analyticArea_m2;
    if isfinite(r.analyticVolume_m3) && r.analyticVolume_m3 > 0
        r.volume_rel_err = abs(r.volume_m3 - r.analyticVolume_m3)/r.analyticVolume_m3;
        r.characteristic_radius_m = charRadius(P(k).shape, r.volume_m3);
        r.nominal_radius_m = nominalRadius(P(k).shape);
        if isfinite(r.nominal_radius_m) && r.nominal_radius_m > 0
            r.radius_err_rel = abs(r.characteristic_radius_m - r.nominal_radius_m) ...
                / r.nominal_radius_m;
            % 展示件 (世界体/源锥) 不进"内径 0.1%"尺寸门: 它们不是被测量件
            if ~logical(P(k).display_only)
                maxRadErr = max(maxRadErr, r.radius_err_rel);
            end
        end
    end
    out(k) = r;
end

% --- 壳层内外皮最小径向间隙: 壁(外皮) vs 气腔/阴极(内皮) ---
% 阴极与气腔共面是**物理事实** (壁的内表面就是灵敏体积边界), 不参与间隙门;
% 间隙门查的是同一个壁壳的两张皮: gas_cavity(=内皮) 与 wall(=外皮)。
iw = find(strcmpi({P.part_id},'wall'),1);
ig = find(strcmpi({P.part_id},'gas_cavity'),1);
if ~isempty(iw) && ~isempty(ig)
    minGap = skinGapM(P(iw).V, P(ig).V, P(iw).shape, P(ig).shape);
    gapApplied = true;
end

% --- 壁厚测量误差: 外皮特征半径 - 内皮特征半径, 对比配置壁厚 ---
thErr = NaN;
if ~isempty(iw) && ~isempty(ig)
    rOut = charRadius(P(iw).shape, out(iw).volume_m3);
    rIn  = charRadius(P(ig).shape, out(ig).volume_m3);
    tNom = spec.wallOuterRadius_m - spec.gasRadius_m;
    thErr = abs((rOut - rIn) - tNom)/tNom;
end

M = struct();
M.units = char(string(spec.units));
M.closed = allClosed;
M.nonmanifold_edges = totNonmanifold;
M.zero_area_faces = totZeroArea;
M.duplicate_vertices = totDup;
M.meshSpec_duplicate_vertices = totDup;      % 对 meshSpec 产物实测, 不是写死的 0
M.normals_consistent_outward = allNormals;
M.min_skin_gap_m = minGap;
M.skin_gap_required_m = TOL_GAP_M;
M.skin_gap_ok = (~gapApplied) || (minGap > TOL_GAP_M);
M.max_radius_err_rel = maxRadErr;
M.wall_thickness_err_rel = thErr;
M.dimension_tolerance_rel = TOL_DIM;
M.dimension_err_ok = (maxRadErr <= TOL_DIM) && (isnan(thErr) || thErr <= TOL_DIM);
M.parts = out;
M.n_parts = numel(P);
M.geometryType = char(string(spec.geometryType));
M.fieldTopology = char(string(spec.fieldTopology));
M.electrodeTopology = char(string(spec.electrodeTopology));
M.displayResolution_n = spec.displayResolution_n;
M.convexhull_note = convexHullNote(spec);
M.ok = M.closed && M.nonmanifold_edges == 0 && M.zero_area_faces == 0 && ...
    M.normals_consistent_outward && M.skin_gap_ok && M.dimension_err_ok && ...
    M.duplicate_vertices == 0;
end

%% ==================== 局部函数 ====================

function r = newPartRow()
r = struct('part_id','','units','SI','n_vertices',0,'n_faces',0, ...
    'closed',false,'nonmanifold_edges',0,'zero_area_faces',0, ...
    'duplicate_vertices',0,'normals_outward',false,'wrong_handed_faces',0, ...
    'free_boundary_edges',NaN,'volume_m3',NaN,'area_m2',NaN, ...
    'analyticVolume_m3',NaN,'analyticArea_m2',NaN,'volume_rel_err',NaN, ...
    'characteristic_radius_m',NaN,'nominal_radius_m',NaN,'radius_err_rel',NaN);
end

function ar = faceAreasLocal(V,F)
a = V(F(:,1),:); b = V(F(:,2),:); c = V(F(:,3),:);
ar = 0.5*sqrt(sum(cross(b-a, c-a, 2).^2, 2));
end

function n = faceNormalsLocal(V,F)
a = V(F(:,1),:); b = V(F(:,2),:); c = V(F(:,3),:);
n = cross(b-a, c-a, 2);
n = n ./ max(sqrt(sum(n.^2,2)), realmin);
end

function v = meshVolume(V,F)
% 散度定理有向体积: V = sum_i dot(v1_i, cross(v2_i, v3_i)) / 6。
% 与本机不存在的 triangulation.polyVolume 同式; 外向绕序时为正。
a = V(F(:,1),:); b = V(F(:,2),:); c = V(F(:,3),:);
v = sum(a(:,1).*(b(:,2).*c(:,3) - b(:,3).*c(:,2)) + ...
      a(:,2).*(b(:,3).*c(:,1) - b(:,1).*c(:,3)) + ...
      a(:,3).*(b(:,1).*c(:,2) - b(:,2).*c(:,1)))/6;
end

function cnt = edgeCounts(F)
% 无向边重数: 流形闭口曲面 <=> 每条边恰出现 2 次。出现 1 次 = 开边, >2 次 = 非流形。
E = sort([F(:,[1 2]); F(:,[2 3]); F(:,[3 1])], 2);
[edges, ~, ic] = unique(E, 'rows');
cnt = histcounts(ic, 0.5:size(edges,1)+0.5).';
end

function n = countExactDuplicateRows(V)
[~, ia] = unique(V, 'rows');
n = size(V,1) - numel(ia);
end

function r = charRadius(shape, vol)
% 由网格体积反解"特征半径" —— 全是 meshSpec.analyticVolume 的解析反函数:
% 球 (3V/4pi)^(1/3); 圆柱 sqrt(V/(pi h)); 盒 (V/8)^(1/3); 圆锥 sqrt(3V/(pi h))。
switch lower(string(shape.type))
    case "sphere",   r = (3*vol/(4*pi)).^(1/3);
    case "cylinder", r = sqrt(vol/(pi*shape.height_m));
    case "box",      r = (vol/8).^(1/3);
    case "cone",     r = sqrt(3*vol/(pi*shape.height_m));
    otherwise,       r = NaN;
end
end

function r = nominalRadius(shape)
if isfield(shape,'radius_m') && isfinite(shape.radius_m), r = shape.radius_m;
elseif isfield(shape,'half_m'), r = shape.half_m;
else, r = NaN;
end
end

function g = skinGapM(Vouter, Vinner, shapeOut, shapeIn)
% 最小径向间隙 = 外皮最小径向坐标 - 内皮最大径向坐标 (正 = 两皮不交叉)。
% 球壳用 |P|; 圆柱壳用 sqrt(x^2+y^2) (侧壁与端面顶点的该坐标都等于半径)。
g = min(radialCoord(Vouter, shapeOut)) - max(radialCoord(Vinner, shapeIn));
end

function r = radialCoord(V, shape)
if lower(string(shape.type)) == "cylinder"
    r = sqrt(V(:,1).^2 + V(:,2).^2);
else
    r = sqrt(sum(V.^2, 2));
end
end

function s = convexHullNote(spec)
% 把"为什么不用 sphere(n)/convexHull 直接网格"从断言变成**实测数字**。
n = 32;
if isfield(spec,'displayResolution_n') && ~isempty(spec.displayResolution_n)
    n = spec.displayResolution_n;
end
[X,Y,Z] = sphere(n);
Pr = [X(:) Y(:) Z(:)];
dRaw = countExactDuplicateRows(Pr);
Fn = naiveSurfFaces(size(X,1));              % 朴素的 surf 四边形拆三角
nz = 0; nm = 0; fb = 0;
if size(Fn,1) > 0
    nz = sum(faceAreasLocal(Pr, Fn) <= 0);
    cnt = edgeCounts(Fn);
    nm = sum(cnt ~= 2);
    fb = sum(cnt == 1);
end
dd = 0; za = 0; nmw = 0;
for k = 1:numel(spec.parts)
    V = double(spec.parts(k).V); F = double(spec.parts(k).F);
    if isempty(V) || isempty(F), continue; end
    dd = dd + countExactDuplicateRows(V);
    za = za + sum(faceAreasLocal(V,F) <= 0);
    nmw = nmw + sum(edgeCounts(F) ~= 2);
end
s = sprintf(['sphere(%d) 点阵实测含 %d 个重复顶点 (两极各 %d 重 + ' ...
    'phi=0 与 phi=2pi 接缝列), 按 surf 四边形直接拆三角得 %d 面: 零面积三角形 %d 个、' ...
    '非流形边 %d 条、freeBoundary 开边 %d 条 => 同时不满足"闭合 / 零面积=0 / ' ...
    '无非流形边"。本机 R2025a 另实测: convexHull(P) 对 double 输入不存在 (只有 ' ...
    'delaunayTriangulation(...).convexHull 类方法), 且 triangulation 的 polyVolume/' ...
    'faceAreas/totalArea 方法亦不存在 => 本文件用散度定理与叉积闭式实现同式。' ...
    'meshSpec 的网格从源头去重 (极点单一顶点 + 经度取模 + 极区三角扇): 实测重复顶点 %d、' ...
    '零面积三角形 %d、非流形边 %d。'], ...
    n, dRaw, n+1, size(Fn,1), nz, nm, fb, dd, za, nmw);
end

function F = naiveSurfFaces(nrow)
% surf(X,Y,Z) 的原生四边形网格 -> 每四边形 2 三角 (含重复极点与接缝列的拓扑)。
if nrow < 2, F = zeros(0,3); return; end
Q = zeros(2*(nrow-1)^2, 3);
k = 0;
for i = 1:nrow-1
    for j = 1:nrow-1
        v1 = (i-1)*nrow + j; v2 = v1 + 1; v3 = v1 + nrow + 1; v4 = v1 + nrow;
        k = k+1; Q(k,:) = [v1 v2 v3];
        k = k+1; Q(k,:) = [v1 v3 v4];
    end
end
F = Q(1:k,:);
end
