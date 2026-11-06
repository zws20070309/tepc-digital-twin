function out = clipVolume(V, F, varargin)
%CLIPVOLUME 半空间精确剖切 (显示层算子): 逐三角形裁剪 + 割线回路缝合 + 盖面三角化。
%
%   out = clipVolume(V, F)                                 默认保留 x >= 0
%   out = clipVolume(V, F, 'Plane', [nx ny nz px py pz])   法向 + 面上一元点, SI [m]
%   out = clipVolume(V, F, 'Keep', 'against')              保留法向的反侧
%   out = clipVolume(V, F, 'Cap', 'none'|'auto'|'force')   不补盖 / 自动 / 强行补
%   out = clipVolume(V, F, 'Tol', 1e-12, 'PartID', 'wall') 相对容差与零件名
%
% 只用于显示层: 返回值自带 display_only = true 与 audit.* 全 false 标志, 函数体内没有
% 任何写盘通道, 也不接受 spec 句柄 —— 体积/面积/弦长的审计口径一律不经过这里。
%
% 算法 (精确到浮点, 不做体素近似)
%   1. 顶点有向距离 sd = dot(V - p, n_hat)。按 |sd| <= tol 归一到平面, 得三态
%      (pos / zero / neg); 用三态而不是两态是为了不在容差带内产出退化三角形。
%      退化约定 (闭口与体积断言都从这里推出):
%        (a) sd = 0 的顶点算"在平面上", 归保留侧 (保留半空间是 sd >= 0);
%        (b) 割线只由"严格跨平面"的边 (sa*sb < 0) 产生交点 —— 与 0 相连的边不算;
%        (c) 三条顶点全为 0 的面整体躺在割平面上, 丢弃 (它就是割面的一部分, 由盖面
%            覆盖; 留着会把同一张盖面铺两遍, 表现为非流形边);
%        (d) 截线穿过原顶点时, 该顶点两侧的原网格边在保留侧只被用一次, 于是它以开边
%            的身份自然进回路 (见第 5 步), 不需要为退化另写分支。
%   2. 交点按"典则无向边 (min,max) 只算一次"生成: 第 k 条典则边的交点存在 pv(k,:), 而
%      它的顶点号就是 nvIn + k, 两者同序 (Vc = [V; pv])。相邻两面共用同一条割边时拿到
%      同一行、同一个号、同一串位, 割线两侧天然缝合; 逐面各自插值的话, t 与 1-t 两种
%      写法会在最后 1 ulp 上分叉, 缝合就断了, 表现为成片非流形边。
%   3. 逐三角形裁剪: 沿环游顺序走三条边, 输出"保留侧顶点 + 边-平面交点"序列。三角形
%      与半空间的交要么是三角形要么是凸四边形 (凸集之交仍凸), 所以扇形细分 (四边形 ->
%      2 面) 恒成立, 这里不需要一般多边形三角化。
%   4. 溶解割线上的共线劈点: 网格自己的对角线会把割线上的一段直边劈成 2~3 小边, 劈点
%      严格落在两角点连线上。侧壁沿割线多留一个顶点, 盖面就必须多切一刀才能闭口, 于是
%      "正方形盖面 = 2 面"这一类面数断言与闭口断言互相矛盾。这里把劈点两侧的两张面片
%      沿其公共边拼成一张 (区域逐位不变, 面积/体积/绕序都不变), 使侧壁的割线边集与盖面
%      的边集一一对应。统计量 n_cut_contour_edges 按溶解"之前"的段数报 (它才是网格边与
%      平面相交的段数), 溶解后的回路边数在 cap.n_contour_edges。
%   5. 开边里两端都在平面上的构成割线, 串成回路 (割线顶点度数应为 2), 串不通即
%      broken_chain 并如实上报; 两端不都在平面上的开边是输入网格自带的洞, 单独计数。
%      回路投到 (e1, e2, n) 右手基的二维, 由带符号面积定绕序 (盖面外法向必须背离保留体),
%      凸回路走扇形 O(n), 非凸简单回路走耳切 O(n^2); 自交回路不补盖。三角化必须通过
%      三项自证 (面数 = n-2、面积可加、每个三角形重心在多边形内) 才算 exact, 否则整条
%      回路拒盖 (宁可报未闭口, 也不拿一张越界的盖面把洞糊上)。
%   6. 多回路先判嵌套: 一条回路的代表点落在另一条内部 => 环形截面 (管壁), 填内环会把孔
%      补成实体, 故 auto 档拒盖并报 status = 'nested...'; 互不相交的回路逐块补盖 (多连
%      通实体), status = 'disjoint'。force 档允许填内环, 但 nested 一律压住 exact。
%
% 容差: tol = Tol * L, L = 包围盒最大边长 (L = 0 时取 1), 默认 Tol = 1e-12。判据一律取
% 相对量, 米制 (L ~ 3e-2) 与无量纲 (L ~ 2) 下同一表达式都成立。
%
% 返回 out (长度一律 SI [m], 面积 [m^2], 体积 [m^3]):
%   out.V / out.F                裁剪并补盖后的网格 (F 为 double 索引)
%   out.display_only 恒 true / out.units 'SI' / out.part_id
%   out.plane [nx ny nz c] / out.keep / out.cap_mode / out.tol_rel / out.tol_m / out.scale_m
%   out.stats.n_faces_input, n_faces_kept_asis, n_faces_split, n_faces_dropped,
%          n_verts_after, n_faces_after, n_cap_faces, n_cut_contour_edges,
%          n_boundary_edges_before_cap, n_boundary_edges_offplane, plane_misses_part,
%          empty_after, closed_after, nonmanifold_edges_after, zero_area_faces_after,
%          signed_volume_after_m3, surface_area_after_m2
%   out.cap.loops, nested, disjoint, broken_chain, n_faces, area_m2_total, exact,
%          convex, simple, status, n_contour_edges, n_edges_offplane,
%          per_loop{k} = struct(n_verts, area_m2, n_faces, capped, convex, simple,
%                               tri_centroids_m, tri_areas_m2)
%   out.guarantee.cap_exact, cap_closed, exact_geometry, caveat, winding_note
%   out.audit.participates_in_V_S_lbar, writes_back_into_parts_table,
%          writes_geometry_manifest, consumed_by_checkMesh, consumed_by_exportGeometry,
%          consumed_by_meshSpec, consumed_by_sampleChord, consumed_by_fieldModel
%
% 错误标识符: tepc:geometry:ClipBadArgs / ClipBadOption / ClipBadPlane / ClipBadKeep /
%   ClipBadCap / ClipBadTol / ClipBadPartID / ClipBadMesh

    %% ---------------- 0. 选项 ----------------
    op = struct('Plane', [], 'Keep', 'normal', 'Cap', 'auto', 'Tol', 1e-12, 'PartID', '');
    fnames = fieldnames(op);
    if mod(numel(varargin), 2) ~= 0
        error('tepc:geometry:ClipBadArgs', ...
            'clipVolume 的选项必须成对给出 (名称, 值), 实得 %d 个', numel(varargin));
    end
    for i = 1:2:numel(varargin)
        raw = varargin{i};
        if ~(ischar(raw) || (isstring(raw) && numel(raw) == 1))
            error('tepc:geometry:ClipBadArgs', '第 %d 个选项名必须是字符或字符串标量', i);
        end
        nm = char(string(raw));
        k = find(strncmpi(fnames, nm, numel(nm)), 1);
        if isempty(k)
            error('tepc:geometry:ClipBadOption', '未知选项 %s (可用: %s)', ...
                nm, strjoin(fnames(:).', ' '));
        end
        if i + 1 > numel(varargin)
            error('tepc:geometry:ClipBadArgs', '选项 %s 缺少取值', fnames{k});
        end
        op.(fnames{k}) = varargin{i + 1};
    end

    keep = lower(char(string(op.Keep)));
    if ~(strcmp(keep, 'normal') || strcmp(keep, 'against'))
        error('tepc:geometry:ClipBadKeep', 'Keep 只能是 normal 或 against (实得 %s)', ...
            char(string(op.Keep)));
    end
    capMode = lower(char(string(op.Cap)));
    if ~(strcmp(capMode, 'auto') || strcmp(capMode, 'none') || strcmp(capMode, 'force'))
        error('tepc:geometry:ClipBadCap', 'Cap 只能是 auto / none / force (实得 %s)', ...
            char(string(op.Cap)));
    end
    tolRel = op.Tol;
    if ~(isnumeric(tolRel) && isreal(tolRel) && numel(tolRel) == 1 && ...
            isfinite(tolRel) && tolRel > 0)
        error('tepc:geometry:ClipBadTol', 'Tol 必须是正的有限实标量 (实得 %s)', ...
            describe(tolRel));
    end
    partId = op.PartID;
    if ~(ischar(partId) || (isstring(partId) && numel(partId) == 1))
        error('tepc:geometry:ClipBadPartID', 'PartID 只能是字符或字符串标量');
    end
    partId = char(string(partId));

    %% ---------------- 1. 网格自检与尺度 ----------------
    % 校验顺序: 选项与网格都先过, 最后才解析平面。早先 planeOf 排在 Keep/Cap/Tol 与
    % 网格自检之前, 于是"只给坏 Keep"或"只给坏网格"的调用一律被 ClipBadPlane 抢先报走,
    % 调用方拿不到真正的错因 (空 Plane 是这些用例的共同表象, 不是它们的错误)。
    [V, F] = checkMeshIn(V, F);
    n = planeOf(op.Plane);
    c = dot(n, double(reshape(op.Plane(4:6), 1, 3)));      % 平面方程 dot(x,n) = c
    if strcmp(keep, 'against')
        % 翻法向而不是翻比较号: 后面所有代码只需认"保留 dot(x,n) >= c"这一条。
        n = -n;
        c = -c;
    end
    nvIn = size(V, 1);
    nfIn = size(F, 1);
    if nvIn == 0 || nfIn == 0
        out = emptyResult(n, c, capMode, partId, double(tolRel));
        return
    end
    L = max(max(V, [], 1) - min(V, [], 1));
    if ~(L > 0)
        L = 1;
    end
    tol = double(tolRel) * L;
    inSign = signOf(signedVolume(V, F));        % 输入网格自身的绕序约定

    %% ---------------- 2. 三态距离与典则割边表 ----------------
    % 约定 (退化配置一律按这一条处理, 后面的闭口/体积断言都从它推出):
    %   (i)  有向距离 |sd| <= tol 的顶点吸附成 sd = 0, 称为"在平面上";
    %   (ii) 在平面上的顶点归入保留侧 (保留半空间是 sd >= 0), 因此含 sd = 0 顶点的面
    %        不会因为"没有严格正顶点"而被丢掉, 除非它整体躺在平面上;
    %   (iii) 三条顶点全为 0 的面整体躺在平面上 -> 丢弃: 它就是割面的一部分, 由盖面
    %        覆盖, 留着会让同一张盖面被铺两遍并产生非流形边; 这一条只在"确实切开了"
    %        时成立, 整件共面 (allOnPlane) 时无洞可盖, 按 (ii) 全部保留;
    %   (iv) 割线只由"严格跨平面"的边 (sa*sb < 0) 与裁剪后网格里的"两端都在平面上的
    %        开边"两部分组成。后者天然吃掉截线穿过原顶点、原面的整条边躺在平面上这两档
    %        退化: 那些边在保留侧只被用一次, 度数为 1, 直接被 chainLoops 收进回路。
    sd = V * n.' - c;
    sd(abs(sd) <= tol) = 0;
    % 整个零件的顶点全在割平面上 (零厚度件与切面重合): 没有任何"穿过", 也就没有需要盖的
    % 洞。保留半空间是 sd >= 0, 按约定 (ii) 它整体属于保留侧, 于是下面逐面裁剪要把共面
    % 面片原样保留; 若仍按"共面面片归盖面"丢弃, 结果会是 0 面 —— 零件凭空消失。
    allOnPlane = ~any(sd(:) ~= 0);
    [ei, ej, pv, cutIx] = cutPoints(F, sd, V);
    nVerts = nvIn + size(pv, 1);
    Vc = [V; pv];
    % 顶点号 = nvIn + 典则边行号, 与 ei/ej/pv 三者同序 (见 cutPoints 的注释): 这里不再
    % 用 (min,max) 键去查表, 因为早先的实现把"逐 hit 生成的 pv"当成"逐典则边生成的 pv"
    % 来编号, 于是一条割边拿到的是另一条割边的坐标 (球 n=128 偏距切: size(ei)=1164 而
    % size(pv)=3492, 后一半顶点号指向错点) => 回路长出不存在的折点, 盖面体错 8.6e-2。

    %% ---------------- 3. 逐三角形裁剪 ----------------
    faceOut = cell(nfIn, 1);
    nKept = 0;
    nSplit = 0;
    nDrop = 0;
    for m = 1:nfIn
        tri = F(m, :);
        s = sd(tri);
        if ~any(s ~= 0)
            if allOnPlane
                faceOut{m} = tri(:);             % 整件共面: 无洞可盖, 按保留侧原样收面
                nKept = nKept + 1;
            else
                nDrop = nDrop + 1;               % 整张面躺在割平面上: 归盖面, 这里丢弃
            end
            continue
        end
        if ~any(s < 0)
            faceOut{m} = tri(:);                 % 整面保留 (含 sd = 0 的共面顶点)
            nKept = nKept + 1;
            continue
        end
        if ~any(s > 0)
            nDrop = nDrop + 1;                   % 整面丢弃 (含 [0 0 -] 这类退化面)
            continue
        end
        pts = zeros(4, 1);
        np = 0;
        for e = 1:3
            if s(e) >= 0
                np = np + 1;
                pts(np) = tri(e);
            end
            if cutIx(m, e) > 0
                np = np + 1;
                pts(np) = cutIx(m, e);
            end
        end
        if np < 3
            nDrop = nDrop + 1;
            continue
        end
        faceOut{m} = pts(1:np);
        nSplit = nSplit + 1;
    end

    %% ---------------- 4. 溶解割线共线点 + 压顶点表 + 扇形细分 ----------------
    % 盖面的三角形必须与侧壁的开边一一对应才能闭口。网格自己的对角线会把割线上的一段
    % 直边劈成 2~3 个小边 (劈点严格落在两角点连线上), 于是侧壁沿割线多出一些共线顶点:
    % 盖面若按劈点铺, 面数就不是真实角点数的 n-2; 若按角点铺, 劈点两侧的小边无人覆盖 =>
    % 永远不闭口。这里在压顶点表之前把劈点从侧壁里溶解掉: 该点两侧的面片沿一条公共边
    % 相接, 合成一张面片, 并集区域逐位不变 (共线 => 面积、体积都不变), 只是割线边数少 1。
    [faceOut, nCutSeg] = dissolveCollinear(faceOut, Vc, n, c, tol);
    used = false(nVerts, 1);
    for m = 1:nfIn
        p = faceOut{m};
        if ~isempty(p)
            used(p) = true;
        end
    end
    reid = zeros(nVerts, 1);
    reid(used) = 1:nnz(used);
    Vo = Vc(used, :);
    Fo = facesFromPolygons(Vo, faceOut, reid, tol, L);
    st = struct();
    st.n_faces_input = nfIn;
    st.n_faces_kept_asis = nKept;
    st.n_faces_split = nSplit;
    st.n_faces_dropped = nDrop;
    st.n_verts_after = size(Vo, 1);
    st.empty_after = isempty(Fo);
    st.plane_misses_part = ~(any(sd > 0) && any(sd < 0));

    %% ---------------- 5. 割线回路与盖面 ----------------
    [uE, deg] = edgeDegrees(Fo);
    st.n_boundary_edges_before_cap = nnz(deg == 1);
    st.n_faces_after = size(Fo, 1);
    if isempty(Vo)
        onPl = logical([]);
    else
        onPl = abs(Vo * n.' - c) <= tol;
    end
    if allOnPlane
        % 整件共面时没有任何"被割出来的闭曲线": 它自身的开边两端也都在平面上, 若交给
        % chainLoops 会被当成切口并再盖一张同位置的共面盖面 (重复面 + 非流形边)。
        [loops, broken, nOff] = deal({}, 0, 0);
    else
        [loops, broken, nOff] = chainLoops(uE, deg, size(Vo, 1), onPl);
    end
    st.n_boundary_edges_offplane = nOff;
    cap = buildCap(Vo, loops, n, inSign, tol, L, capMode);
    cap.info.n_edges_offplane = nOff;
    if broken > 0
        % 有开边串不成闭环 (输入非流形或自带洞): 一律不声称闭口, 也不声称盖面精确。
        cap.info.broken_chain = true;
        cap.info.exact = false;
        cap.refused = true;
        if strcmp(cap.info.status, 'no_contour')
            cap.info.status = 'broken_chain';
        else
            cap.info.status = [cap.info.status '+broken_chain'];
        end
    end

    Ff = [Fo; cap.faces];
    ar = faceAreas(Vo, Ff);
    good = ar > epsArea(tol, L);
    nCapRaw = size(cap.faces, 1);
    Ff = Ff(good, :);
    % 盖面数按"留在结果里"的口径报: 零面积面已经在上面被剔掉, 若还按补盖时的原始数报,
    % n_faces_after 与各分项就对不上了。
    if nCapRaw > 0
        st.n_cap_faces = nnz(good(size(Fo, 1) + 1 : end));
    else
        st.n_cap_faces = 0;
    end
    st.n_cut_contour_edges = nCutSeg;
    st.closed_after = isClosed(Ff, size(Vo, 1)) && ~cap.refused;
    st.nonmanifold_edges_after = nNonManifold(Ff);
    st.zero_area_faces_after = nnz(~good);
    if isempty(Ff)
        st.signed_volume_after_m3 = 0;
        st.surface_area_after_m2 = 0;
    else
        st.signed_volume_after_m3 = signedVolume(Vo, Ff);
        st.surface_area_after_m2 = sum(ar(good));
    end

    %% ---------------- 6. 组装 ----------------
    out = struct();
    out.V = Vo;
    out.F = double(Ff);
    out.display_only = true;
    out.units = 'SI';
    out.part_id = partId;
    out.plane = [n, c];
    out.keep = keep;
    out.cap_mode = capMode;
    out.tol_rel = double(tolRel);
    out.tol_m = tol;
    out.scale_m = L;
    out.stats = st;
    out.cap = cap.info;
    out.guarantee = guaranteeText(cap, st, inSign);
    out.audit = auditFlags();
end

%% ==================== 局部函数: 输入检查 ====================

function s = describe(x)
if isempty(x)
    s = '空';
elseif isnumeric(x) && numel(x) == 1
    s = sprintf('%.6g', x);
else
    s = sprintf('%s %dx%d', class(x), size(x, 1), size(x, 2));
end
end

function n = planeOf(P)
if ~(isnumeric(P) && isreal(P) && numel(P) == 6 && all(isfinite(P(:))))
    error('tepc:geometry:ClipBadPlane', ...
        'Plane 必须是 6 元有限实向量 [nx ny nz px py pz] (实得 %s)', describe(P));
end
n = double(reshape(P(1:3), 1, 3));
nn = norm(n);
if ~(nn > 0)
    error('tepc:geometry:ClipBadPlane', '平面法向不能是零向量');
end
n = n / nn;
end

function [V, F] = checkMeshIn(V, F)
if ~isnumeric(V) || ~isreal(V) || size(V, 2) ~= 3 || ~all(isfinite(V(:)))
    error('tepc:geometry:ClipBadMesh', 'V 必须是 Nx3 有限实数矩阵 (实得 %s)', ...
        shapeOf(V));
end
V = double(V);
if size(V, 1) == 0
    F = zeros(0, 3);
    return
end
if ~isnumeric(F) || ~isreal(F) || size(F, 2) ~= 3
    error('tepc:geometry:ClipBadMesh', 'F 必须是 Mx3 整数矩阵 (实得 %s)', shapeOf(F));
end
F = double(F);
if size(F, 1) == 0
    return
end
if any(F(:) ~= floor(F(:))) || any(F(:) < 1) || any(F(:) > size(V, 1))
    error('tepc:geometry:ClipBadMesh', 'F 含非整数或越界索引 (允许范围 1..%d)', ...
        size(V, 1));
end
end

function s = shapeOf(x)
if isempty(x)
    s = [class(x) ' 0x0'];
else
    s = sprintf('%s %dx%d', class(x), size(x, 1), size(x, 2));
end
end

%% ==================== 局部函数: 裁剪 ====================

function [ei, ej, pv, cutIx] = cutPoints(F, sd, V)
% 严格跨平面 (sa*sb < 0) 的典则无向边集合, 以及每条边与平面的交点。
%
% 输出契约 (行序就是顶点号序, 这是这里的核心):
%   ei, ej 各占一行 = 一条典则无向边 (ei < ej); pv 的第 k 行就是第 k 条边的交点;
%   主程序给它的顶点号是 nvIn + k, 而 Vc = [V; pv] 的第 nvIn + k 行正是 pv(k, :)。
%   早先的写法把交点按"逐 hit 实例"生成 (每条无向边在三条槽位的循环展开里出现 6 次),
%   却按"去重后的典则边"发号, 两套行数不同 (球 n=128: 3492 行坐标 vs 1164 条边),
%   于是一半的号指向别的边的坐标 —— 回路在平面上乱走, 偏距切的体积误差到了 1e-1。
%
% 共享顶点的逐位一致性: 交点一律按 (min, max) 取向插值 t = s_i/(s_i - s_j), 两面共用
% 同一条割边时取到同一行 pv、同一个号、同一串位 (逐面各自插值会在最后 1 ulp 上分叉,
% 表现为成片非流形边)。Keep='against' 只是把 n、c 一起取反, s 变号而 t 不变 =>
% 两支用同一批交点坐标, 所以两支体积之和回到机器精度。
nvIn = size(V, 1);
nfIn = size(F, 1);
a = [F(:, 1); F(:, 2); F(:, 3)];
b = [F(:, 2); F(:, 3); F(:, 1)];
sa = sd(a);
sb = sd(b);
hit = sa .* sb < 0;
cutIx = zeros(nfIn, 3);
if ~any(hit)
    ei = zeros(0, 1);
    ej = ei;
    pv = zeros(0, 3);
    return
end
[edg, ~, ic] = unique([min(a(hit), b(hit)), max(a(hit), b(hit))], 'rows', 'stable');
ei = edg(:, 1);
ej = edg(:, 2);
si = sd(ei);
sj = sd(ej);
t = si ./ (si - sj);
pv = V(ei, :) + t .* (V(ej, :) - V(ei, :));
% 槽位序: a、b 的前 nfIn 个元素是槽位 1 (边 1->2), 接着槽位 2、槽位 3, 故按列 reshape
% 得到的 (m, e) 就是"面 m 的第 e 条边" (与主程序裁剪游走的 e -> (e, e+1) 同义)。
idcol = zeros(3 * nfIn, 1);
idcol(hit) = nvIn + ic;
cutIx = reshape(idcol, nfIn, 3);
end

function [uE, deg] = edgeDegrees(F)
% 无向边重数: 闭合三角网格每条边恰被 2 面共用, 重数 1 = 开边, >2 = 非流形。
if isempty(F)
    uE = zeros(0, 2);
    deg = zeros(0, 1);
    return
end
E = sort([F(:, [1 2]); F(:, [2 3]); F(:, [3 1])], 2);
[uE, ~, ic] = unique(E, 'rows');
deg = accumarray(ic, 1, [size(uE, 1) 1]);
end

function F = facesFromPolygons(Vo, faceOut, reid, tol, L)
% 保留多边形 (3 或 4 顶点) 扇形细分; 退化面 (重复顶点或零面积) 在这里就被丢掉, 免得
% 污染 zero_area_faces_after 的统计。
lst = zeros(0, 3);
for m = 1:numel(faceOut)
    p = faceOut{m};
    if isempty(p)
        continue
    end
    q = reid(p);
    nq = numel(q);
    for t = 2:nq - 1
        f = [q(1) q(t) q(t + 1)];
        if f(1) == f(2) || f(2) == f(3) || f(1) == f(3)
            continue
        end
        if faceArea1(Vo, f) <= epsArea(tol, L)
            continue
        end
        lst(end + 1, :) = f; %#ok<AGROW>
    end
end
F = lst;
end

function a = faceArea1(V, f)
p = V(f(1), :);
q = V(f(2), :);
r = V(f(3), :);
a = 0.5 * norm(cross(q - p, r - p));
end

function [faceOut, nSeg] = dissolveCollinear(faceOut, Vc, n, c, tol)
% 溶解割线上的共线劈点。返回新的面片表与"裁剪直接产生的割线段数" nSeg (合并前统计)。
% 每次 dissolveOne 只处理一个劈点并重算开边, 直到没有可溶的点为止: 每溶掉一个点,
% 面片顶点总数减 2 (两张面各少一个顶点, 合成一张), 所以轮数有上界。
nSeg = countCutSegments(faceOut, Vc, n, c, tol);
nRound = 2 * numel(faceOut) + 8;
for it = 1:nRound
    [faceOut, done] = dissolveOne(faceOut, Vc, n, c, tol);
    if done
        return
    end
end
end

function [faceOut, done] = dissolveOne(faceOut, Vc, n, c, tol)
% 找一对开边 (u,v),(v,w) 使 v 严格落在 u、w 的连线上 (相对共线判据 1e-9), 然后把带
% 这两条开边的两张面片沿它们共用的边 (v,x) 拼成一张: A 的链 x..u 接 B 的链 w..x, v 被
% 删掉, 新开边 (u,w) 与原两条边的并集共线 => 并集区域逐位不变 (面积、体积、外法向都不
% 变), 只是割线少一个边界顶点。拼出的多边形以 x 开头: 它的每条边都整个落在 A 或 B 里,
% 而 A、B 都是凸的 (三角形被半空间截出的交仍是凸多边形) 且都含 x, 所以从 x 出发的扇形
% 恒在并集内 => 扇形细分不需要一般多边形三角化。
% 两条开边同属一张面片时 (v 的前后邻就是 u、w) 直接删掉 v, 区域同样不变。
% 判据取相对量: 球网格 (n=96/128) 的割线上相邻三点转角约 1e-2 弧度, 比 1e-9 大七个
% 数量级, 不会被误当成劈点。
done = true;
[ea, eb, ep, cnt] = polyEdgeList(faceOut);
op = cnt == 1;
if ~any(op)
    return
end
onPl = abs(Vc * n.' - c) <= tol;
oe = [ea(op), eb(op)];
vlist = [oe(:, 1); oe(:, 2)];
other = [oe(:, 2); oe(:, 1)];                  % 与 vlist 同序: 该开边的另一端
pol = [ep(op); ep(op)];                        % 与 vlist 同序: 该开边所属面片
[uv, ~, iv] = unique(vlist);
nd = accumarray(iv, 1, [numel(uv) 1]);
cand = find(nd == 2 & onPl(uv));               % 恰被两条开边用到的平面点
epsLin = 1e-9;
for g = 1:numel(cand)
    v = uv(cand(g));
    r1 = find(iv == cand(g), 2);
    u = other(r1(1));
    w = other(r1(2));
    A = pol(r1(1));
    B = pol(r1(2));
    if u == w
        continue
    end
    d1 = Vc(u, :) - Vc(v, :);
    d2 = Vc(w, :) - Vc(v, :);
    n1 = norm(d1);
    n2 = norm(d2);
    if ~(n1 > 0 && n2 > 0) || d1 * d2.' >= 0
        continue                              % 重合或回折: 不是劈点
    end
    if norm(cross(d1, d2)) > epsLin * n1 * n2
        continue                              % 不共线
    end
    if A == B
        pa = faceOut{A};
        k = find(pa == v, 1);
        q = pa([1:k - 1, k + 1:numel(pa)]);
        if numel(q) >= 3
            faceOut{A} = q(:);
        else
            faceOut{A} = {};
        end
        done = false;
        return
    end
    pa = faceOut{A};
    pb = faceOut{B};
    na = numel(pa);
    nb = numel(pb);
    ka = find(pa == v, 1);
    kb = find(pb == v, 1);
    if isempty(ka) || isempty(kb) || na < 3 || nb < 3
        continue
    end
    % 面片内 v 的前后邻 (环游序)。两面公共的那个 = 共用边 (v,x) 的另一端 x; 剩下两个
    % 必须正好是两条开边的另一端 u、w, 否则这里就不是一个可溶的劈点。
    aPrev = pa(mod(ka - 2, na) + 1);
    aNext = pa(mod(ka, na) + 1);
    bPrev = pb(mod(kb - 2, nb) + 1);
    bNext = pb(mod(kb, nb) + 1);
    chainA = pa(mod((ka:ka + na - 2), na) + 1);    % 去掉 v 后 A 的链: aNext .. aPrev
    chainB = pb(mod((kb:kb + nb - 2), nb) + 1);    % 去掉 v 后 B 的链: bNext .. bPrev
    if aNext == bNext
        continue                              % 共用边被两面取成同向: 非流形, 不动
    end
    if aNext == bPrev && isequal(sort([aPrev, bNext]), sort([u, w]))
        merged = [chainA(:); chainB(1:end - 1)];   % x..u 接 w..x
    elseif aPrev == bNext && isequal(sort([aNext, bPrev]), sort([u, w]))
        merged = [chainB(:); chainA(1:end - 1)];   % x..w 接 u..x
    else
        continue
    end
    if numel(merged) < 3 || any(merged(1:end - 1) == merged(2:end))
        continue                              % 相邻重复顶点: 退化, 交给零面积过滤
    end
    faceOut{A} = merged;
    faceOut{B} = {};
    done = false;
    return
end
end

function [ea, eb, ep, cnt] = polyEdgeList(faceOut)
% 面片表的全部有向边 (按面内环游顺序), 典则无向键的重数, 以及边 -> 面号 的对照。
ea = zeros(0, 1);
eb = ea;
ep = ea;
for m = 1:numel(faceOut)
    p = faceOut{m};
    if isempty(p)
        continue
    end
    np = numel(p);
    if np < 3
        continue
    end
    ea = [ea; p(:)]; %#ok<AGROW>
    eb = [eb; p(mod((0:np - 1) + 1, np) + 1)]; %#ok<AGROW>
    ep = [ep; repmat(m, np, 1)]; %#ok<AGROW>
end
if isempty(ea)
    cnt = zeros(0, 1);
    return
end
[~, ~, ic] = unique([min([ea eb], [], 2), max([ea eb], [], 2)], 'rows');
cnt = accumarray(ic, 1, [size(ea, 1) 1]);
cnt = cnt(ic);                              % 回到与 ea/eb 同长的重数向量
end

function nSeg = countCutSegments(faceOut, Vc, n, c, tol)
% 裁剪直接产生的割线段数: 开边里两端都落在平面上的那些 (溶解前统计)。
[ea, eb, ~, cnt] = polyEdgeList(faceOut);
op = cnt == 1;
if ~any(op)
    nSeg = 0;
    return
end
onPl = abs(Vc * n.' - c) <= tol;
nSeg = nnz(onPl(ea(op)) & onPl(eb(op)));
end

function e = epsArea(tol, L)
% 零面积判据: 长度尺度取 max(tol, eps*L), 面积阈值取它的平方再留 8 倍余量。
h = max([tol, eps * L, 1e-300]);
e = 8 * h * h;
end

%% ==================== 局部函数: 回路与盖面 ====================

function [loops, broken, nOff] = chainLoops(uE, deg, nV, onPl)
% 开边里两端都在平面上的构成割线; 其余开边是输入网格自带的洞 (nOff 计数)。
loops = {};
broken = 0;
nOff = 0;
if isempty(uE)
    return
end
bE = uE(deg == 1, :);
if isempty(bE)
    return
end
both = onPl(bE(:, 1)) & onPl(bE(:, 2));
nOff = nnz(~both);
bE = bE(both, :);
if isempty(bE)
    return
end
adj = sparse([bE(:, 1); bE(:, 2)], [bE(:, 2); bE(:, 1)], 1, nV, nV);
adj = min(adj + adj.', 1);                  % 二值化: 同一条割边重复登记不放大度数
dvec = full(sum(adj, 2));
vx = find(dvec > 0);
rem = false(nV, 1);
rem(vx) = true;
for s0 = 1:numel(vx)
    start = vx(s0);
    if ~rem(start)
        continue
    end
    if dvec(start) ~= 2
        broken = broken + 1;
        rem(start) = false;
        continue
    end
    loop = start;
    prev = 0;
    cur = start;
    rem(cur) = false;
    ok = false;
    guard = 0;
    while guard <= numel(vx) + 2
        guard = guard + 1;
        nb = find(adj(cur, :) > 0);
        nxt = 0;
        for w = 1:numel(nb)
            q = nb(w);
            if q == prev
                continue
            end
            if rem(q) || q == start
                nxt = q;
                break
            end
        end
        if nxt == 0
            break
        end
        if nxt == start
            ok = numel(loop) >= 3;
            break
        end
        loop(end + 1) = nxt; %#ok<AGROW>
        prev = cur;
        cur = nxt;
        rem(cur) = false;
    end
    if ok
        loops{end + 1} = loop(:); %#ok<AGROW>
    else
        broken = broken + 1;
    end
end
end

function cap = buildCap(V, loops, n, inSign, tol, L, capMode)
% 逐回路: 定绕序 -> 三角化 -> 按 Cap 档决定是否真的补面。
cap = newCapStruct();
nL = numel(loops);
cap.info.loops = nL;
if nL == 0
    cap.info.status = 'no_contour';
    cap.info.exact = true;
    return
end
[e1, e2] = planeBasis(n);
P2 = cell(nL, 1);
area2 = zeros(nL, 1);
for k = 1:nL
    P = V(loops{k}, :);
    P2{k} = [P * e1.' P * e2.'];              % (e1,e2,n) 右手基下的二维坐标
    area2(k) = polyArea2(P2{k});
end
nested = false;
for k = 1:nL
    for j = 1:nL
        if j ~= k && pointInPoly(P2{k}(1, :), P2{j})
            nested = true;
        end
    end
end
convexAll = true;
simpleAll = true;
exactAll = true;
brokenAny = false;
refused = nested && ~strcmp(capMode, 'force');
if strcmp(capMode, 'none')
    refused = true;
end
faces = zeros(0, 3);
totArea = 0;
nEdgeTot = 0;
triFailAny = false;
% 盖面外法向要背离保留体: 输入外绕 (inSign>0) 时取 -n, 即二维带符号面积必须为负
wantSign = -inSign;
for k = 1:nL
    ix = loops{k}(:);
    nEdgeTot = nEdgeTot + numel(ix);              % 割线段数: 合并共线点之前计数
    nRaw = numel(ix);
    A0 = area2(k);
    Pk = P2{k};
    loc = (1:nRaw)';                              % 与 ix/Pk 同序的回路内行号
    if ~(abs(A0) > 0)
        exactAll = false;
        brokenAny = true;
        continue
    end
    if sign(A0) ~= wantSign
        ix = flipud(ix);                          % 回路反序 = 盖面翻面
        Pk = flipud(Pk);
        loc = flipud(loc);
    end
    % 共线折点合并 (必须在定序之后、分类与三角化之前):
    % 网格把每张四边面拆成两个三角形, 于是割线沿原网格的一条直边被拆成 2~3 段, 中间那些
    % 交点在几何上不是角点。留着它们的后果是 polyIsConvex 因为某处叉积恰为 0 而判非凸,
    % 一个真正的正方形也要走耳切, 且三角化面数不再等于 n-2 => 精确性断言失效。
    [Pk, ix, loc] = dropCollinear(Pk, ix, loc, L);
    nVx = size(Pk, 1);
    A = wantSign * polyArea2(Pk);                 % 定序 + 合并后的带符号面积 (应为正)
    if nVx < 3 || ~(A > 0)
        exactAll = false;
        brokenAny = true;
        continue
    end
    [tri, ex, cv, sp] = triangulateLoop(Pk, wantSign, tol, L);
    convexAll = convexAll && cv;
    simpleAll = simpleAll && sp;
    exactAll = exactAll && ex;
    if ~ex
        % 三角化没能给出可验证的精确划分 (自交回路、耳切中途断链): 宁可不补盖, 让闭口
        % 断言如实失败, 也不要用一张越界的盖面把洞糊上。
        triFailAny = true;
        tri = zeros(0, 3);
    end
    one = struct();
    one.n_verts = nVx;
    one.n_verts_raw = nRaw;
    one.area_m2 = A;
    one.capped = ~refused && ~isempty(tri);
    one.convex = cv;
    one.simple = sp;
    one.n_faces = size(tri, 1);
    if ~one.capped
        one.tri_centroids_m = zeros(0, 3);
        one.tri_areas_m2 = zeros(0, 1);
    else
        f3 = [ix(tri(:, 1)) ix(tri(:, 2)) ix(tri(:, 3))];
        one.tri_centroids_m = (V(f3(:, 1), :) + V(f3(:, 2), :) + V(f3(:, 3), :)) / 3;
        one.tri_areas_m2 = faceAreas(V, f3);
        faces = [faces; f3]; %#ok<AGROW>
        totArea = totArea + A;
    end
    cap.info.per_loop{k} = one;
end
cap.faces = faces;
cap.refused = refused || triFailAny;
cap.n_contour_edges = nEdgeTot;
cap.info.n_faces = size(faces, 1);
cap.info.area_m2_total = totArea;
cap.info.nested = nested;
cap.info.disjoint = nL > 1 && ~nested;
cap.info.broken_chain = brokenAny;
cap.info.convex = convexAll;
cap.info.simple = simpleAll;
% force 档只是"允许把内环也填上", 不改变几何事实: 环形截面被两条同向盖面补完后, 孔被
% 重算了一遍, 有向体积不再等于实体体积 => nested 一律压住 exact。
cap.info.exact = exactAll && ~refused && ~brokenAny && ~triFailAny && ~nested;
if strcmp(capMode, 'none')
    cap.info.status = 'skipped_cap_none';
elseif nested
    if strcmp(capMode, 'force')
        cap.info.status = 'nested_capped_by_force';
    else
        cap.info.status = 'nested_contours_cap_refused';
    end
elseif brokenAny
    cap.info.status = 'broken_chain';
elseif nL > 1
    cap.info.status = 'disjoint';
else
    cap.info.status = 'single';
end
if triFailAny
    % 追加而不是覆盖: 上层用 status 里的 'nested'/'disjoint' 字样分辨回路构型。
    cap.info.status = [cap.info.status '+tri_rejected'];
end
end

function [Pk, ix, loc] = dropCollinear(Pk, ix, loc, L)
% 删掉回路上"跟前邻、后邻严格共线且同向"的中间点, 三者的行序始终保持一致。
% 判据取相对量: |cross(e_prev, e_next)| <= 1e-9 * |e_prev| * |e_next| 等价于转角偏离
% 180 度不到 1e-9 弧度, 对应的面积损失 ~1e-9 相对量, 远小于任何被断言的误差。
% 反向 (dot < 0) 的共线是"回折", 属于自接触退化, 不合并, 交给 polyIsSimple 去挡。
% 球网格 n=96/128 的割线相邻三点转角约 1e-2 弧度, 比阈值大 7 个数量级 => 不会被误删。
epsLin = 1e-9;
np = size(Pk, 1);
pass = 0;
while np >= 4 && pass < np + 2
    pass = pass + 1;
    keep = true(np, 1);
    for i = 1:np
        j = mod(i, np) + 1;
        h = mod(i - 2, np) + 1;
        e1 = Pk(i, :) - Pk(h, :);
        e2 = Pk(j, :) - Pk(i, :);
        n1 = e1 * e1.';
        n2 = e2 * e2.';
        if n1 <= 0
            continue                          % 重合点由下一轮以前邻的角度删掉
        end
        if n2 <= 0
            keep(i) = false;                  % i 与后继重合: 删 i
            continue
        end
        if (e1 * e2.') > 0 && abs(cross2(e1, e2)) <= epsLin * sqrt(n1 * n2)
            keep(i) = false;
        end
    end
    if all(keep)
        break
    end
    Pk = Pk(keep, :);
    ix = ix(keep);
    loc = loc(keep);
    np = size(Pk, 1);
end
end

function c = newCapStruct()
c = struct('faces', zeros(0, 3), 'refused', false, 'n_contour_edges', 0, 'info', []);
c.info = struct();
c.info.loops = 0;
c.info.nested = false;
c.info.disjoint = false;
c.info.broken_chain = false;
c.info.n_faces = 0;
c.info.area_m2_total = 0;
c.info.exact = false;
c.info.convex = true;
c.info.simple = true;
c.info.status = '';
c.info.per_loop = {};
c.info.n_contour_edges = 0;
c.info.n_edges_offplane = 0;
end

function [tri, exact, convex, simple] = triangulateLoop(P2, wantSign, tol, L)
% 凸回路 -> 扇形 O(n); 非凸简单回路 -> 耳切 O(n^2); 自交回路 -> 不补, exact = false。
% exact 不是"跑完了"的意思, 而是 checkTriangulation 三项自证全过: 面数 = n-2、三角形
% 面积之和 = 多边形面积、每个三角形的重心都在多边形内。任一不过即返回空表, 由调用方
% 拒盖 (宁可留开边如实报未闭口, 也不拿一张越界的盖面把洞糊上)。
nVx = size(P2, 1);
convex = polyIsConvex(P2);
simple = convex || polyIsSimple(P2, tol, L);
tri = zeros(0, 3);
exact = false;
if nVx < 3 || ~simple
    return
end
if nVx == 3
    tri = [1 2 3];
elseif convex
    for t = 2:nVx - 1
        tri(end + 1, :) = [1 t t + 1]; %#ok<AGROW>
    end
else
    tri = earClip(P2, wantSign, L);
end
exact = checkTriangulation(P2, tri, L);
if ~exact
    tri = zeros(0, 3);
end
end

function ok = checkTriangulation(P, tri, L)
% 划分自证: 数量、面积可加、重心不越界。零面积三角形也算不过 (它意味着退化划分)。
n = size(P, 1);
ok = size(tri, 1) == n - 2;
if ~ok
    return
end
Ap = abs(polyArea2(P));
if ~(Ap > 0)
    ok = false;
    return
end
tolA = 1e-9 * Ap + 8 * eps * L * L;
sa = 0;
for t = 1:size(tri, 1)
    a = P(tri(t, 1), :);
    b = P(tri(t, 2), :);
    c = P(tri(t, 3), :);
    at = 0.5 * abs(cross2(b - a, c - a));
    if ~(at > 0) || ~pointInPoly((a + b + c) / 3, P)
        ok = false;
        return
    end
    sa = sa + at;
end
ok = abs(sa - Ap) <= tolA;
end

function tri = earClip(P, orient, L)
% 耳切。A/B/C = (前邻, 候选顶点, 后邻), orient = 回路二维带符号面积的符号。
% 凸顶点判据是 orient * cross2(B - A, C - B) > 0。
% 早先这里算的是 cross2(A - B, C - B), 而 cross2(A-B, C-B) = -cross2(B-A, C-B), 符号
% 整个反了: 于是所有凸顶点被当成"优角"拒掉, 只有真正的优角顶点被当成耳切下去 —— 切出的
% 三角形落在多边形外侧 (L 形截面实测到重心 (1.1667,1.1667) 与 (1.5,1.3333), 都在 L 之
% 外), 而且优角有限, 切完就没"耳"可切, 于是 3 面后提前退出 (应为 n-2 = 4 面)。
% 每轮必然删掉一个顶点, 因此循环最多 nVx-2 轮, 不再需要 guard 计数来兜住停滞; 真出现
% 找不到耳 (自交/贴边退化) 时立即退出并把短表交给 checkTriangulation 判死。
nVx = size(P, 1);
alive = true(nVx, 1);
tri = zeros(nVx - 2, 3);
t = 0;
sc = max(max(P, [], 1) - min(P, [], 1));
if ~(sc > 0)
    sc = 1;
end
eTol = 1e-12 * sc * sc;
while nnz(alive) > 2
    cur = find(alive);
    m = numel(cur);
    rvx = false(nVx, 1);                        % 本轮的优角集合 (第 2 档判据要用)
    for q = 1:m
        ip = cur(mod(q - 2, m) + 1);
        ii = cur(q);
        ij = cur(mod(q, m) + 1);
        if orient * cross2(P(ii, :) - P(ip, :), P(ij, :) - P(ii, :)) <= 0
            rvx(ii) = true;
        end
    end
    ear = 0;
    qPick = 0;
    for tier = 1:2
        % 第 1 档: 三角形内含或贴边任一活点就不切 (最保守);
        % 第 2 档: 只要没有优角顶点严格落在里面就算耳 —— 简单多边形在这一档必有耳可切
        % (Two-Ears 定理), 于是凸包上的"贴边共线点"不会把整条链卡死。
        for q = 1:m
            ip = cur(mod(q - 2, m) + 1);
            ii = cur(q);
            ij = cur(mod(q, m) + 1);
            if rvx(ii)
                continue                      % 优角顶点不是耳
            end
            bad = false;
            for r = 1:m
                ir = cur(r);
                if ir == ip || ir == ii || ir == ij
                    continue
                end
                if tier == 2 && ~rvx(ir)
                    continue
                end
                if tier == 1
                    inT = pointInTri(P(ir, :), P(ip, :), P(ii, :), P(ij, :), eTol, true);
                else
                    inT = pointInTri(P(ir, :), P(ip, :), P(ii, :), P(ij, :), eTol, false);
                end
                if inT
                    bad = true;
                    break
                end
            end
            if ~bad
                ear = ii;
                qPick = q;
                break
            end
        end
        if ear > 0
            break
        end
    end
    if ear == 0
        break
    end
    ip = cur(mod(qPick - 2, m) + 1);
    ij = cur(mod(qPick, m) + 1);
    t = t + 1;
    tri(t, :) = [ip ear ij];
    alive(ear) = false;
end
tri = tri(1:t, :);
end

function z = cross2(u, v)
z = u(1) * v(2) - u(2) * v(1);
end

function a = polyArea2(P)
% 鞋带公式: 二维带符号面积。
nVx = size(P, 1);
a = 0;
for i = 1:nVx
    j = mod(i, nVx) + 1;
    a = a + (P(i, 1) * P(j, 2) - P(j, 1) * P(i, 2));
end
a = 0.5 * a;
end

function tf = polyIsConvex(P)
nVx = size(P, 1);
tf = false;
if nVx < 3
    return
end
z = zeros(nVx, 1);
for i = 1:nVx
    a = P(mod(i - 2, nVx) + 1, :);
    b = P(i, :);
    cc = P(mod(i, nVx) + 1, :);
    z(i) = cross2(b - a, cc - b);
end
tf = all(z > 0) || all(z < 0);
end

function tf = polyIsSimple(P, tol, L)
% 两两段真相交测试 (相邻边只在公共顶点相接, 故跳过), 用包围盒预筛。
nVx = size(P, 1);
tf = true;
h = max([tol * L, sqrt(eps) * L, 1e-300]);
for i = 1:nVx - 2
    p1 = P(i, :);
    p2 = P(mod(i, nVx) + 1, :);
    for j = i + 2:nVx
        if i == 1 && j == nVx
            continue
        end
        q1 = P(j, :);
        q2 = P(mod(j, nVx) + 1, :);
        spanX = abs(p1(1) - p2(1)) + abs(q1(1) - q2(1));
        spanY = abs(p1(2) - p2(2)) + abs(q1(2) - q2(2));
        if any(max(max(p1, p2), max(q1, q2)) - min(min(p1, p2), min(q1, q2)) > ...
                [h + spanX, h + spanY])
            continue
        end
        if segsProper(p1, p2, q1, q2)
            tf = false;
            return
        end
    end
end
end

function tf = segsProper(p1, p2, q1, q2)
d1 = cross2(p2 - p1, q1 - p1);
d2 = cross2(p2 - p1, q2 - p1);
d3 = cross2(q2 - q1, p1 - q1);
d4 = cross2(q2 - q1, p2 - q1);
tf = (d1 * d2 < 0) && (d3 * d4 < 0);
end

function tf = pointInTri(p, a, b, cc, eTol, incl)
% 三个叉积同号即在内侧。incl = true 时把"正好落在某条边上"也算内含 (容差 eTol 是面积
% 量级), 用来把这种贴边耳判死; incl = false 时只认严格内含。
s1 = cross2(b - a, p - a);
s2 = cross2(cc - b, p - b);
s3 = cross2(a - cc, p - cc);
if incl
    tf = (s1 >= -eTol && s2 >= -eTol && s3 >= -eTol) || ...
         (s1 <= eTol && s2 <= eTol && s3 <= eTol);
else
    tf = (s1 > eTol && s2 > eTol && s3 > eTol) || ...
         (s1 < -eTol && s2 < -eTol && s3 < -eTol);
end
end

function tf = pointInPoly(pt, P)
% 射线法 (奇偶)。它只用于"是否存在嵌套", 不作盖面判据。
nVx = size(P, 1);
tf = false;
j = nVx;
for i = 1:nVx
    yi = P(i, 2);
    yj = P(j, 2);
    if (yi > pt(2)) ~= (yj > pt(2))
        xint = P(i, 1) + (pt(2) - yi) * (P(j, 1) - P(i, 1)) / (yj - yi);
        if pt(1) < xint
            tf = ~tf;
        end
    end
    j = i;
end
end

function [e1, e2] = planeBasis(n)
% 与 n 正交的单位基, (e1, e2, n) 右手。取与 n 最不平行的坐标轴做参考向量。
[~, k] = min(abs(n));
u = zeros(1, 3);
u(k) = 1;
e1 = u - (u * n.') * n;
e1 = e1 / norm(e1);
e2 = cross(n, e1);
e2 = e2 / norm(e2);
end

%% ==================== 局部函数: 网格量 ====================

function ar = faceAreas(V, F)
% 列向量: 调用方拿它当行索引的布尔掩码。
if isempty(F) || size(V, 1) == 0
    ar = zeros(0, 1);
    return
end
p = V(F(:, 1), :);
q = V(F(:, 2), :);
r = V(F(:, 3), :);
ar = 0.5 * sqrt(sum(cross(q - p, r - p, 2).^2, 2));
end

function v = signedVolume(V, F)
% 散度定理: V = sum dot(p, cross(q,r))/6, 对闭合网格与原点选取无关。
if isempty(F) || size(V, 1) == 0
    v = 0;
    return
end
p = V(F(:, 1), :);
q = V(F(:, 2), :);
r = V(F(:, 3), :);
v = sum(dot(p, cross(q, r, 2), 2)) / 6;
end

function s = signOf(v)
if v >= 0
    s = 1;
else
    s = -1;
end
end

function tf = isClosed(F, nV)
if isempty(F) || nV == 0
    tf = ~isempty(F);
    return
end
[~, deg] = edgeDegrees(F);
tf = all(deg == 2);
end

function k = nNonManifold(F)
[~, deg] = edgeDegrees(F);
k = nnz(deg > 2);
end

%% ==================== 局部函数: 文案与标志 ====================

function g = guaranteeText(cap, st, inSign)
g = struct();
g.cap_exact = logical(cap.info.exact);
g.cap_closed = logical(st.closed_after);
g.exact_geometry = logical(cap.info.exact && st.closed_after);
note = {'盖面是割线回路的二维精确三角化, 其误差与网格疏密无关'};
switch cap.info.status
    case 'nested_contours_cap_refused'
        note = {note{:}, '环形截面 (嵌套回路) 已检出并拒盖: 填内环会把孔补成实体'};
    case 'nested_capped_by_force'
        note = {note{:}, '环形截面按 force 档强行补盖: 孔被重算一遍, exact 保持 false'};
    case 'skipped_cap_none'
        note = {note{:}, '按 Cap=none 档跳过补盖: 网格留有开边'};
    case 'broken_chain'
        note = {note{:}, '割线开边串不成闭环: 输入网格非流形或自带洞'};
    otherwise
        if cap.info.loops > 1
            note = {note{:}, '多条互不相交的回路: 逐块补盖'};
        end
end
if ~logical(st.closed_after)
    note = {note{:}, '结果未闭口, 其有向体积与面积不得进任何审计口径'};
end
g.caveat = strjoin(string(note), '; ');
if inSign > 0
    g.winding_note = '输入按外绕约定, 盖面外法向取 -n';
else
    g.winding_note = '输入按内绕约定, 盖面外法向取 +n (与侧壁绕序一致)';
end
end

function a = auditFlags()
a = struct();
a.participates_in_V_S_lbar = false;
a.writes_back_into_parts_table = false;
a.writes_geometry_manifest = false;
a.consumed_by_checkMesh = false;
a.consumed_by_exportGeometry = false;
a.consumed_by_meshSpec = false;
a.consumed_by_sampleChord = false;
a.consumed_by_fieldModel = false;
end

function out = emptyResult(n, c, capMode, partId, tolRel)
out = struct();
out.V = zeros(0, 3);
out.F = zeros(0, 3);
out.display_only = true;
out.units = 'SI';
out.part_id = partId;
out.plane = [n, c];
out.keep = 'normal';
out.cap_mode = capMode;
out.tol_rel = tolRel;
out.tol_m = 0;
out.scale_m = 0;
st = struct();
st.n_faces_input = 0;
st.n_faces_kept_asis = 0;
st.n_faces_split = 0;
st.n_faces_dropped = 0;
st.n_verts_after = 0;
st.n_faces_after = 0;
st.n_cap_faces = 0;
st.n_cut_contour_edges = 0;
st.n_boundary_edges_before_cap = 0;
st.n_boundary_edges_offplane = 0;
st.plane_misses_part = true;
st.empty_after = true;
st.closed_after = true;
st.nonmanifold_edges_after = 0;
st.zero_area_faces_after = 0;
st.signed_volume_after_m3 = 0;
st.surface_area_after_m2 = 0;
out.stats = st;
c0 = newCapStruct();
c0.info.loops = 0;
c0.info.status = 'empty_part';
c0.info.exact = true;
out.cap = c0.info;
g = struct();
g.cap_exact = true;
g.cap_closed = true;
g.exact_geometry = true;
g.caveat = '空网格: 没有可剖切的三角形';
g.winding_note = '空网格: 绕序无定义';
out.guarantee = g;
out.audit = auditFlags();
end
