function tests = test_geometry_clip
%TEST_GEOMETRY_CLIP 显示层真实剖切 (clipVolume) 的数值与隔离契约。
%
% 覆盖:
%   * 球沿中心切 = 半球体积 (网格自身对称性给出机器精度; 与解析值的偏差另计);
%   * 球沿偏距 d 切 = 球冠闭式 pi*h^2*(3r-h)/3, 容差按"网格自身的离散误差"标定;
%   * 多面体 (立方体) 的斜截与正截: 平面体网格无离散误差 => 相对误差到 1e-12;
%   * 单连通**非凸**截面: 耳切盖面精确 (极角排序 + 形心扇形在这一档会错);
%   * 多回路: 嵌套 (环形截面) 必须"检出并拒盖", 互不相交则逐回路补盖并如实标注;
%   * 显示层隔离: 本函数不写盘、不吃 spec、审计消费者一律不调用它 (源码扫描 +
%     剖切前后 V/S/lbar 与零件表逐位不变)。
% 解析值全部手算写在注释里; 网格构造是本地独立实现 (不复用 meshSpec 的句柄), 以便
% 对账时两边不是同一段代码。
tests = functiontests(localfunctions);
end

%% ==================== 本地网格构造 (与 meshSpec 分开实现) ====================

function [V, F] = uvSphereMesh(r, n)
% 去重 UV 球: 北极 1 + 纬圈 (n-1) x 经度 n + 南极 1。极点单一顶点、经度取模不留接缝列
% => 闭合流形。n 取偶数时该点阵关于 x = 0 严格镜像对称 (phi -> pi - phi 映网格点到
% 网格点), 这是 test_clip_sphere_centre 能用机器精度判据的前提。
idxPoleN = 1;
idxPoleS = 2 + (n-1)*n;
th = pi*(1:n-1)/n;
ph = 2*pi*(0:n-1)/n;
PH = repmat(ph(:), 1, n-1);
TH = repmat(th(:).', n, 1);
st = sin(TH);
ring = [reshape(r*st.*cos(PH), [], 1), reshape(r*st.*sin(PH), [], 1), ...
        reshape(r*cos(TH), [], 1)];
V = [[0 0 r]; ring; [0 0 -r]];
v = @(i,j) 1 + (i-1)*n + mod(j, n) + 1;   % 环顶点从索引 2 起 (1 是北极); 写成 2+...+1
% 会让最后一个环顶点与南极同号, 极点处开裂成非流形 (剖切测试的前提就没了)
F = zeros(2*n*(n-1), 3);
k = 0;
for j = 0:n-1
    k = k + 1; F(k,:) = [idxPoleN v(1,j) v(1,j+1)];
    k = k + 1; F(k,:) = [idxPoleS v(n-1,j+1) v(n-1,j)];
end
for i = 1:n-2
    for j = 0:n-1
        a = v(i,j); b = v(i+1,j); c = v(i+1,j+1); d = v(i,j+1);
        k = k + 1; F(k,:) = [a b c];
        k = k + 1; F(k,:) = [a c d];
    end
end
F = F(1:k, :);
F = orientOutwardMesh(V, F);
end

function [V, F] = cubeMesh(h, centre)
if nargin < 2, centre = [0 0 0]; end
V = h*[1 -1  1; 1  1  1; -1 1  1; -1 -1  1; ...
       1 -1 -1; 1  1 -1; -1 1 -1; -1 -1 -1] + repmat(centre, 8, 1);
F = [1 2 3; 1 3 4; 6 5 8; 6 8 7; ...
     1 5 6; 1 6 2; 2 6 7; 2 7 3; ...
     3 7 8; 3 8 4; 4 8 5; 4 5 1];
F = orientOutwardMesh(V, F);
end

function [V, F] = lPrismMesh()
% L 形棱柱: 截面 (0,0)(2,0)(2,1)(1,1)(1,2)(0,2) —— 单连通但**非凸**, z 方向 [0,1]。
% 解析量手算: 截面面积 = 2*2 - 1*1 = 3; 体积 = 3*1 = 3; 沿 z = 0.5 切 => 各 1.5。
P = [0 0; 2 0; 2 1; 1 1; 1 2; 0 2];
m = size(P, 1);
V = [P, zeros(m,1); P, ones(m,1)];              % 底 1..m, 顶 m+1..2m
F = zeros(4*m, 3);
k = 0;
for i = 2:m-1                                    % 底面扇 (顶点 1 对 L 形可见全部)
    k = k + 1; F(k,:) = [1 i+1 i];
    k = k + 1; F(k,:) = [m+1 m+i m+i+1];         % 顶面扇 (反向)
end
for i = 1:m
    j = mod(i, m) + 1;
    k = k + 1; F(k,:) = [i j m+j];
    k = k + 1; F(k,:) = [i m+j m+i];
end
F = F(1:k, :);
F = orientOutwardMesh(V, F);
end

function [V, F] = tubeMesh(Ro, Ri, H, n)
% 圆管 (同轴方孔的替代): 外圆柱面 + 内圆柱面 + 上下环带 (每格一个梯形 quad)。
% 解析体积 = pi*(Ro^2 - Ri^2)*H; 沿垂直轴向的平面切 => 截面是**环形** => 两条嵌套回路。
ph = 2*pi*(0:n-1)/n;
co = Ro*[cos(ph(:)) sin(ph(:))];
ci = Ri*[cos(ph(:)) sin(ph(:))];
V = [co, zeros(n,1); co, H*ones(n,1); ci, zeros(n,1); ci, H*ones(n,1)];
ob = @(j) mod(j-1, n) + 1;                       % 外底
ot = @(j) n + mod(j-1, n) + 1;                   % 外顶
ib = @(j) 2*n + mod(j-1, n) + 1;                 % 内底
it = @(j) 3*n + mod(j-1, n) + 1;                 % 内顶
F = zeros(8*n, 3);
k = 0;
for j = 1:n
    a = ob(j); b = ob(j+1); c = ot(j+1); d = ot(j);
    e = ib(j); f = ib(j+1); g = it(j+1); h = it(j);
    k = k+1; F(k,:) = [a b c];  k = k+1; F(k,:) = [a c d];    % 外壁 (朝外)
    k = k+1; F(k,:) = [e h g];  k = k+1; F(k,:) = [e g f];    % 内壁 (朝孔心 = 朝内)
    k = k+1; F(k,:) = [a e f];  k = k+1; F(k,:) = [a f b];    % 底环带
    k = k+1; F(k,:) = [d c g];  k = k+1; F(k,:) = [d g h];    % 顶环带
end
F = F(1:k, :);
F = orientOutwardMesh(V, F);
end

function [V, F] = twoCubeMesh()
% 两个分离的立方体装进同一张网格 (多连通实体): 两块都**跨在** x = 0 平面上, 但沿 y
% 分开 => 割线是两条互不相交的方形回路。用来验"多回路但可逐块精确补盖"这一档,
% 与嵌套档区分开。解析量: 每块体积 1, 保留 x>=0 的一侧 = 1 (手算)。
[V1, F1] = cubeMesh(0.5, [0 -2 0]);
V2 = V1 + repmat([0 4 0], size(V1, 1), 1);
F2 = F1 + size(V1, 1);
V = [V1; V2];
F = [F1; F2];
end

function F = orientOutwardMesh(V, F)
a = V(F(:,1),:); b = V(F(:,2),:); c = V(F(:,3),:);
vol = sum(a(:,1).*(b(:,2).*c(:,3) - b(:,3).*c(:,2)) + ...
        a(:,2).*(b(:,3).*c(:,1) - b(:,1).*c(:,3)) + ...
        a(:,3).*(b(:,1).*c(:,2) - b(:,2).*c(:,1)))/6;
if vol < 0
    F = F(:,[1 3 2]);
end
end

function v = volOf(V, F)
a = V(F(:,1),:); b = V(F(:,2),:); c = V(F(:,3),:);
v = sum(a(:,1).*(b(:,2).*c(:,3) - b(:,3).*c(:,2)) + ...
      a(:,2).*(b(:,3).*c(:,1) - b(:,1).*c(:,3)) + ...
      a(:,3).*(b(:,1).*c(:,2) - b(:,2).*c(:,1)))/6;
end

function a = areaOf(V, F)
p = V(F(:,1),:); q = V(F(:,2),:); r = V(F(:,3),:);
a = sum(0.5*sqrt(sum(cross(q - p, r - p, 2).^2, 2)));
end

function k = edgeCount(F)
E = sort([F(:,[1 2]); F(:,[2 3]); F(:,[3 1])], 2);
[U, ~, ic] = unique(E, 'rows');
k = accumarray(ic, 1, [size(U,1) 1]);
end

%% ==================== 1. 球: 中心切与偏距切 ====================

function test_sphere_centre_cut_is_half_volume(tc)
r = 1.0;  n = 96;
[V, F] = uvSphereMesh(r, n);
Vm = volOf(V, F);
Va = 4/3*pi*r^3;                                 % 手算 4.188790204786391
tc.verifyTrue(all(edgeCount(F) == 2), '输入球网格必须闭口流形 (否则剖切测试无意义)');
% 网格自身的体积离散误差 (内接多面体, 从下方收敛; n=96 时二阶量级 ~2e-4)
eMesh = abs(Vm - Va)/Va;
tc.verifyLessThan(eMesh, 1e-3, sprintf('n=%d 球网格体积误差 %.3e 应 < 1e-3', n, eMesh));
out = tepc.geometry.clipVolume(V, F, 'Plane', [1 0 0 0 0 0], 'PartID', 'test_sphere');
tc.verifyTrue(out.display_only, '裁剪结果必须自标 display_only = true');
tc.verifyEqual(out.stats.plane_misses_part, false);
tc.verifyEqual(out.cap.loops, 1);
tc.verifyTrue(out.cap.exact, sprintf('单回路盖面应 exact, 实得 status=%s', out.cap.status));
tc.verifyTrue(out.stats.closed_after, '补盖后必须闭口');
tc.verifyEqual(out.stats.nonmanifold_edges_after, 0);
tc.verifyEqual(out.stats.zero_area_faces_after, 0);
% 中心切的两支体积之和必须等于原网格体积: 两支共用同一张盖面多边形, 侧面之和就是
% 原网格 => 这一条是**机器精度**的判据。
half = Vm/2;
outB = tepc.geometry.clipVolume(V, F, 'Plane', [1 0 0 0 0 0], 'Keep', 'against');
tc.verifyEqual(out.stats.signed_volume_after_m3 + outB.stats.signed_volume_after_m3, ...
    Vm, 'RelTol', 1e-12, '两侧的体积之和必须等于原体积 (盖面不重不漏)');
tc.verifyEqual(outB.stats.n_cap_faces, out.stats.n_cap_faces, '两侧的盖面数必须相同');
% 但"半球 = 整球网格体积/2"只能到 1e-4: 点阵关于 x = 0 镜像对称, 而**每个四边形带
% 被拆成的对角线方向在镜像下换了一条** (网格手性相反 => 镜像后的剖分不同), 所以两支
% 各自的体积差 5.6e-6 相对量。这是网格剖分的固有不对称, 不是裁剪误差。
tc.verifyEqual(out.stats.signed_volume_after_m3, half, 'RelTol', 1e-4, ...
    sprintf('半球网格体积 %.15g 与整球/2 %.15g 的相对偏差超出 1e-4', ...
    out.stats.signed_volume_after_m3, half));
% 与解析半球体积的偏差由网格离散误差支配, 用**实测**的 eMesh 作标尺 (放大 1.5 倍留余量)
relAnalytic = abs(out.stats.signed_volume_after_m3 - Va/2)/(Va/2);
tc.verifyLessThanOrEqual(relAnalytic, 1.5*eMesh, ...
    sprintf('剖切相对误差 %.3e 超过网格自身误差 %.3e 的 1.5 倍 => 剖切本身引入了误差', ...
    relAnalytic, eMesh));
tc.verifyLessThan(relAnalytic, 1e-3, '对解析半球的相对误差必须 < 1e-3');
fprintf('[clip] 球 n=%d: 网格体积误差 %.3e, 中心切对解析半球的误差 %.3e, 盖面 %d 面\n', ...
    n, eMesh, relAnalytic, out.stats.n_cap_faces);
end

function test_sphere_offset_cut_matches_analytic_cap(tc)
% 球冠闭式: V(h) = pi*h^2*(3r - h)/3, h = r - d (d = 球心到截面的有向距离, 保留远侧)。
% 手算校验点: d=0 -> pi*r^3 (半球 = 2/3 pi r^3 的 1.5 倍? 不: pi*1*(3-1)/3 = 2.0944 = 半球)
r = 25.4e-3;                                     % 与气腔同量级, 顺便验米制下的尺度
[V, F] = uvSphereMesh(r, 128);
Vm = volOf(V, F);
eMesh = abs(Vm - 4/3*pi*r^3)/(4/3*pi*r^3);
ds = [-0.75 -0.25 0.0 0.25 0.6 0.95]*r;
prev = inf;
for k = 1:numel(ds)
    d = ds(k);
    out = tepc.geometry.clipVolume(V, F, 'Plane', [1 0 0 d 0 0], 'Keep', 'normal');
    h = r - d;
    Va = pi*h^2*(3*r - h)/3;
    if d >= r
        tc.verifyTrue(out.stats.empty_after, '截面在球外时应当切空');
        continue
    end
    tc.verifyTrue(out.stats.closed_after, sprintf('d=%.4e 处补盖后必须闭口', d));
    tc.verifyEqual(out.cap.loops, 1, sprintf('d=%.4e 的截面应是单回路', d));
    err = abs(out.stats.signed_volume_after_m3 - Va)/Va;
    % 判据按**绝对**体积误差给: 内接多面体在这个零件尺度上不可消除的误差下限就是
    % eMesh*Vs (整球相对误差 × 整球体积)。旧写法拿"相对球冠体积"的比值去卡 1.5*eMesh,
    % 而薄冠的 Va 可以只有球体积的 0.2% —— 同一个绝对误差除上去被放大 ~500 倍,
    % 于是 d/r>=0.6 处测到的其实是"冠越薄越不合格", 与剖切质量无关。
    errAbs = abs(out.stats.signed_volume_after_m3 - Va);
    boundAbs = 1.5 * eMesh * (4/3*pi*r^3);
    tc.verifyLessThanOrEqual(errAbs, boundAbs, ...
        sprintf(['d/r=%.2f: 球冠体积绝对误差 %.3e m^3 > 1.5×网格自身绝对误差 %.3e m^3 ' ...
            '(相对值 %.3e / 相对整球 %.3e)'], d/r, errAbs, boundAbs, err, errAbs/(4/3*pi*r^3)));
    tc.verifyTrue(out.cap.exact || abs(d) > r*0.99);
    tc.verifyLessThan(out.stats.signed_volume_after_m3, prev + 1e-30, ...
        '保留侧体积必须随 d 单调下降');
    prev = out.stats.signed_volume_after_m3;
    if k == 1
        fprintf('[clip] 球冠 R=%.3e: 网格误差 %.3e, d=0.75R 相对误差 %.3e\n', ...
            r, eMesh, err);
    end
end
% 相切与相离: d = r 应切空, d = -r 应整块保留
oIn = tepc.geometry.clipVolume(V, F, 'Plane', [1 0 0 -r 0 0]);
tc.verifyTrue(oIn.stats.plane_misses_part, '平面与球相切于背面 => 应报"未切入"');
tc.verifyEqual(oIn.stats.signed_volume_after_m3, Vm, 'RelTol', 1e-12);
% 负控: 把 d/r=0.6 的解析参考挪动 2%, 绝对判据必须咬住。没有这一条, "按绝对误差给阈值"
% 完全可以被调成一个恒真式而看不出来。
o6 = tepc.geometry.clipVolume(V, F, 'Plane', [1 0 0 0.6*r 0 0], 'Keep', 'normal');
Va6 = pi*(0.4*r)^2*(3*r - 0.4*r)/3;
tc.verifyGreaterThan(abs(o6.stats.signed_volume_after_m3 - Va6*1.02), boundAbs, ...
    sprintf('负控失效: 参考值挪 2%% (%.3e) 仍不超过阈值 (%.3e) —— 阈值太松', ...
    abs(o6.stats.signed_volume_after_m3 - Va6*1.02), boundAbs));
end

%% ==================== 2. 多面体: 无离散误差, 判据可下到机器精度 ====================

function test_polyhedron_cuts_are_exact(tc)
h = 1.0;
[V, F] = cubeMesh(h);
Vc = 8;                                          % 手算 (2h)^3 = 8
tc.verifyEqual(volOf(V, F), Vc, 'RelTol', 1e-14, '立方体网格体积必须精确等于 8');
% (a) 正截: 保留 z >= 0.5 -> 2*2*0.5 = 2 (手算), 盖面是正方形 (4 边 -> 2 个三角形)
o1 = tepc.geometry.clipVolume(V, F, 'Plane', [0 0 1 0 0 0.5]);
tc.verifyEqual(o1.stats.signed_volume_after_m3, 2, 'AbsTol', 1e-13);
tc.verifyEqual(o1.cap.loops, 1);
tc.verifyEqual(o1.stats.n_cap_faces, 2, '正方形盖面 = 2 个三角形 (手算)');
tc.verifyTrue(o1.stats.closed_after);
tc.verifyEqual(o1.guarantee.cap_exact, true);
% (b) 斜截: 过中心的平面 x + y + z = 0 => 严格一半 = 4 (立方体关于该平面对称)
nrm = [1 1 1]/sqrt(3);
o2 = tepc.geometry.clipVolume(V, F, 'Plane', [nrm 0 0 0]);
tc.verifyEqual(o2.stats.signed_volume_after_m3, Vc/2, 'AbsTol', 1e-13, ...
    '斜截过中心时截得的三棱角柱体积 = 4 (手算)');
tc.verifyEqual(o2.cap.loops, 1);
tc.verifyEqual(o2.stats.n_cap_faces, 4, '正六边形盖面 = n-2 = 4 个三角形 (手算)');
% (c) 斜截不过中心: x + y + z = 1 => 截去一个小角, 保留侧体积 = 8 - 1/6*(1)^3*? 手算
%     平面 x+y+z=1 与立方体 [-1,1]^3: 距最远顶点 (1,1,1) 的距离 = (3-1)/sqrt(3);
%     该侧截得的是一个三棱锥 (三个互相垂直的棱长均为 2-1= ... ) -> 用互补支核对更稳:
o3 = tepc.geometry.clipVolume(V, F, 'Plane', [nrm 1 0 0]);
o3b = tepc.geometry.clipVolume(V, F, 'Plane', [nrm 1 0 0], 'Keep', 'against');
tc.verifyEqual(o3.stats.signed_volume_after_m3 + o3b.stats.signed_volume_after_m3, ...
    Vc, 'AbsTol', 1e-13, '斜截两支体积之和 = 立方体体积');
tc.verifyGreaterThan(o3.stats.signed_volume_after_m3, 0);
tc.verifyTrue(o3.stats.closed_after && o3b.stats.closed_after);
% 互补两支: 去掉各自盖面后的侧面积之和 = 原网格全面积 (面积可加); 两侧共用同一张盖面。
tc.verifyEqual(o3.stats.surface_area_after_m2 - o3.cap.area_m2_total + ...
    o3b.stats.surface_area_after_m2 - o3b.cap.area_m2_total, 24, 'RelTol', 1e-12, ...
    '两侧侧面积之和 = 立方体全面积 6*2^2 = 24 (手算); 两支侧面积相等只在等分面上才成立');
tc.verifyEqual(o3.cap.area_m2_total, o3b.cap.area_m2_total, 'RelTol', 1e-12, ...
    '同一截面的两侧共用一张盖面, 面积必须相同');
end

%% ==================== 3. 单连通非凸截面 ====================

function test_nonconvex_single_loop_cap_is_exact(tc)
[V, F] = lPrismMesh();
tc.verifyEqual(volOf(V, F), 3, 'RelTol', 1e-13, 'L 棱柱体积手算 = 3');
tc.verifyTrue(all(edgeCount(F) == 2), '输入必须闭口流形');
out = tepc.geometry.clipVolume(V, F, 'Plane', [0 0 1 0 0 0.5]);
tc.verifyEqual(out.cap.loops, 1);
tc.verifyFalse(out.cap.convex, 'L 形截面必须被认成非凸 (凸性检测失效就等于自欺)');
tc.verifyTrue(out.cap.simple, '单连通简单多边形');
tc.verifyTrue(out.cap.exact, '非凸但单连通: 耳切法必须判 exact (扇形法在这一档不可信)');
tc.verifyEqual(out.stats.signed_volume_after_m3, 1.5, 'AbsTol', 1e-13, ...
    '沿 z=0.5 切下半支: 体积 = 截面 3 x 高 0.5 = 1.5 (手算)');
tc.verifyTrue(out.stats.closed_after);
tc.verifyEqual(out.stats.nonmanifold_edges_after, 0);
% 盖面必须是截面的一次精确划分: 面积和 = 3, 且每个三角形的重心都落在 L 形内部
capA = out.cap.per_loop{1}.area_m2;
tc.verifyEqual(capA, 3, 'RelTol', 1e-13);
triA = 0;
TC = out.cap.per_loop{1}.tri_centroids_m;
TA = out.cap.per_loop{1}.tri_areas_m2;
P = [0 0; 2 0; 2 1; 1 1; 1 2; 0 2];
for t = 1:size(TC, 1)
    c = TC(t, :);
    triA = triA + TA(t);
    tc.verifyTrue(pointInL([c(1) c(2)], P), ...
        sprintf('盖面三角形重心 (%.3f,%.3f) 落在 L 形之外 => 盖面划分越界', c(1), c(2)));
end
tc.verifyGreaterThanOrEqual(size(TC, 1), 4);
tc.verifyEqual(triA, 3, 'RelTol', 1e-12, '盖面三角形面积之和必须正好等于截面面积');
tc.verifyEqual(out.cap.per_loop{1}.n_faces, 4, '六顶点多边形三角化 = n-2 = 4 (手算)');
tc.verifyEqual(out.cap.area_m2_total, 3, 'RelTol', 1e-12);
% 再切一刀 (x = 1.5): 保留 x >= 1.5 的一侧 —— 截面是 [1.5,2] x [0,1] 的矩形 (面积 0.5),
% 高 1 => 体积 0.5 (手算)。这一刀同时验"截面被凹口切短"的形状。
out2 = tepc.geometry.clipVolume(V, F, 'Plane', [1 0 0 1.5 0 0]);
tc.verifyTrue(out2.stats.closed_after);
tc.verifyEqual(out2.cap.loops, 1);
tc.verifyEqual(out2.stats.signed_volume_after_m3, 0.5, 'AbsTol', 1e-13);
end

function tf = pointInL(pt, P)
n = size(P, 1);
tf = false;
j = n;
for i = 1:n
    if (P(i,2) > pt(2)) ~= (P(j,2) > pt(2))
        xint = P(i,1) + (pt(2) - P(i,2))*(P(j,1) - P(i,1))/(P(j,2) - P(i,2));
        if pt(1) < xint, tf = ~tf; end
    end
    j = i;
end
end

%% ==================== 4. 多回路: 嵌套拒盖 / 不相交补盖 ====================

function test_nested_multi_loop_is_detected_not_capped(tc)
[V, F] = tubeMesh(2.0, 1.0, 1.0, 48);
volAn = pi*(4 - 1)*1;                             % 手算 pi*(Ro^2-Ri^2)*H = 3 pi
tc.verifyEqual(volOf(V, F), volAn, 'RelTol', 5e-3, '圆管网格体积对解析值 (48 段离散)');
tc.verifyTrue(all(edgeCount(F) == 2), '输入圆管必须闭口流形');
out = tepc.geometry.clipVolume(V, F, 'Plane', [0 0 1 0 0 0.5]);
tc.verifyEqual(out.cap.loops, 2, '环形截面必须数出 2 条回路');
tc.verifyTrue(out.cap.nested, '两条回路必须判为嵌套 (内环在外环之内)');
tc.verifyEqual(out.cap.n_faces, 0, '嵌套时必须拒盖 —— 填内环会把孔补成实体');
tc.verifyFalse(out.cap.exact);
tc.verifyFalse(out.stats.closed_after, '拒盖后必然留有开边, 不得谎报闭口');
tc.verifySubstring(out.cap.status, 'nested');
tc.verifySubstring(out.guarantee.caveat, '嵌套');
tc.verifyEqual(out.stats.n_cut_contour_edges, 4*48, '割线 = 内外两壁 x 每列 (立边 + 对角边) = 192 条');
% 显式 force 才允许填内环, 且必须把 exact 留在 false (两条回路同向补盖 = 把孔重算一遍)
of = tepc.geometry.clipVolume(V, F, 'Plane', [0 0 1 0 0 0.5], 'Cap', 'force');
tc.verifyGreaterThan(of.cap.n_faces, 0, 'force 档必须真的补出盖面');
tc.verifyFalse(of.cap.exact, 'force 补了内环也不能声称精确');
tc.verifySubstring(of.cap.status, 'nested');
fprintf('[clip] 环形截面: loops=%d nested=%d 拒盖面数=%d; force 档盖面=%d 面\n', ...
    out.cap.loops, out.cap.nested, out.cap.n_faces, of.cap.n_faces);
end

function test_disjoint_multi_loop_is_capped_and_reported(tc)
[V, F] = twoCubeMesh();
tc.verifyEqual(volOf(V, F), 2, 'RelTol', 1e-13, '两个边长 1 的立方体 = 2 (手算)');
out = tepc.geometry.clipVolume(V, F, 'Plane', [1 0 0 0 0 0]);
tc.verifyEqual(out.cap.loops, 2, '两块都被切 => 两条回路');
tc.verifyFalse(out.cap.nested, '两块分离 => 回路互不相交, 不得判成嵌套');
tc.verifySubstring(out.cap.status, 'disjoint');
tc.verifyEqual(out.cap.n_faces, 4, '两个正方形盖面 = 2 x 2 个三角形');
tc.verifyTrue(out.stats.closed_after);
tc.verifyTrue(out.cap.exact, '互不相交的多回路逐块耳切仍然精确, 应报 exact');
tc.verifyEqual(out.stats.signed_volume_after_m3, 1, 'AbsTol', 1e-13, ...
    '保留 x>=0 的一侧 = 右边整个立方体 = 1 (手算)');
end

%% ==================== 5. 退化与错误路径 ====================

function test_bad_inputs_are_rejected(tc)
[V, F] = cubeMesh(1);
tc.verifyError(@() tepc.geometry.clipVolume(V, F, 'Plane', [1 0 0 0 0]), ...
    'tepc:geometry:ClipBadPlane');
tc.verifyError(@() tepc.geometry.clipVolume(V, F, 'Plane', [0 0 0 0 0 0]), ...
    'tepc:geometry:ClipBadPlane');
tc.verifyError(@() tepc.geometry.clipVolume(V, F, 'Keep', 'sideways'), ...
    'tepc:geometry:ClipBadKeep');
tc.verifyError(@() tepc.geometry.clipVolume(V, F, 'Cap', 'yes'), ...
    'tepc:geometry:ClipBadCap');
% Tol 的非法取值期望 **具体** 标识符 tepc:geometry:ClipBadTol, 而不是笼统的 ClipBadOption:
%   (1) ClipBadOption 在本函数里只表示"选项名不认识" (下面 'Nope' 那条就是它), 名字合法
%       而取值非法时另有各自的具体 ID (ClipBadKeep / ClipBadCap / ClipBadPlane / ClipBadTol);
%       若把 Tol 的取值错误也归到 ClipBadOption, 这两条断言就变成同一条, 任何"把所有选项
%       错误一律塞进 ClipBadOption"的实现都能通过, 判别力丢失。
%   (2) 调用方按家族捕获用通配 'tepc:geometry:ClipBad*' 即可, 具体 ID 不损失任何信息,
%       反过来则不行 —— 这与 MATLAB 自身 (如 SignalSpecification / InvalidArgument 加限定符)
%       的错误标识符分层惯例一致。
tc.verifyError(@() tepc.geometry.clipVolume(V, F, 'Tol', -1), ...
    'tepc:geometry:ClipBadTol');
tc.verifyError(@() tepc.geometry.clipVolume(V, F, 'Nope', 1), ...
    'tepc:geometry:ClipBadOption');
tc.verifyError(@() tepc.geometry.clipVolume(V, F, 'Tol'), ...
    'tepc:geometry:ClipBadArgs');
Fbad = F; Fbad(1,1) = size(V,1) + 1;
tc.verifyError(@() tepc.geometry.clipVolume(V, Fbad), 'tepc:geometry:ClipBadMesh');
Vbad = V; Vbad(2,3) = NaN;
tc.verifyError(@() tepc.geometry.clipVolume(Vbad, F), 'tepc:geometry:ClipBadMesh');
tc.verifyError(@() tepc.geometry.clipVolume(V, F(:,1:2)), 'tepc:geometry:ClipBadMesh');
% 顶点正好落在平面上 (退化配置): 必须仍然闭口且体积精确, 且不产出零面积三角形
Vp = V; Fp = F;
[V2, F2] = planeThroughVertices(Vp, Fp);
o = tepc.geometry.clipVolume(V2, F2, 'Plane', [1 0 0 0 0 0]);
tc.verifyTrue(o.stats.closed_after, '截线穿过原顶点时也必须补成闭口');
tc.verifyEqual(o.stats.zero_area_faces_after, 0);
tc.verifyEqual(o.stats.signed_volume_after_m3, 4, 'AbsTol', 1e-13, ...
    'x>=0 半立方体 = 4 (手算), 顶点共面不得破坏体积');
end

function [V2, F2] = planeThroughVertices(V, F)
% 把立方体沿 x 平移成 [-0.5, 1.5]^3 再旋转 45 deg: 使 x = 0 平面正好穿过 4 个原顶点。
a = pi/4;
R = [cos(a) -sin(a) 0; sin(a) cos(a) 0; 0 0 1];
V2 = V*R.';
F2 = F;
end

%% ==================== 6. 显示层隔离 (结构性) ====================

function test_no_audit_consumer_calls_clip(tc)
% "剖切只进显示层"必须靠结构而不是靠自觉:
%   (a) clipVolume 自己不许写盘, 也不许吃 spec (没有"写回零件表"的参数路径);
%   (b) 一切算 V/S/lbar 或产 manifest 的文件不得调用 clipVolume / clipMesh;
%   (c) 扫描器本身必须会响 (注入对照) 且不会被注释/字面量骗到 (负对照)。
root = tepc.io.projectRoot();
clipPath = which('tepc.geometry.clipVolume');
tc.verifyFalse(isempty(clipPath));
clipCode = codeOnlyText(fileread(clipPath));
writeTok = {'fopen', 'fwrite', 'fprintf', 'save', 'copyfile', 'delete', 'movefile', ...
    'writetable', 'csvwrite', 'writeline', 'mkdir'};
for k = 1:numel(writeTok)
    tc.verifyFalse(contains(clipCode, [writeTok{k} '(']), ...
        sprintf('clipVolume 的代码里出现了 %s(): 显示层算子不得写盘', writeTok{k}));
end
tc.verifyFalse(contains(clipCode, 'spec.parts'), ...
    'clipVolume 不得触碰 spec.parts (没有写回零件表的通道才算结构保证)');
tc.verifyTrue(contains(clipCode, 'display_only'), ...
    '返回值必须自带 display_only 标志 (否则隔离声明只是注释)');

auditFiles = {'tepc.geometry.meshSpec', 'tepc.geometry.checkMesh', ...
    'tepc.geometry.exportGeometry', 'tepc.geometry.buildGeometry', ...
    'tepc.geometry.meanChordLength', 'tepc.geometry.sampleChord', ...
    'tepc.geometry.siteConsistency', 'tepc.geometry.gasDensity', ...
    'tepc.geometry.electrode', 'tepc.detector.fieldModel', ...
    'tepc.validation.runGate', 'tepc.geometry.traceSpec'};
nScan = 0;
for k = 1:numel(auditFiles)
    p = which(char(auditFiles{k}));
    if isempty(p), continue; end
    nScan = nScan + 1;
    code = codeOnlyText(fileread(p));
    tc.verifyFalse(contains(code, 'clipVolume('), ...
        sprintf('%s 调用了 clipVolume: 审计/输运路径不得消费显示层剖切产物', auditFiles{k}));
end
tc.verifyGreaterThanOrEqual(nScan, 10, ...
    sprintf('只解析到 %d 个审计消费者的路径, 扫描很可能是空转', nScan));
% 几何包里"剖切算子"只能有一个实现: 两个并行实现会给出两套不一致的盖面/闭口口径,
% 显示层与任何调用方都无法判断哪一份是准的。
gdir = fileparts(clipPath);
clipFiles = dir(fullfile(gdir, 'clip*.m'));
tc.verifyEqual(numel(clipFiles), 1, sprintf('几何包里有 %d 个 clip* 实现 (只允许 1 个): %s', ...
    numel(clipFiles), strjoin({clipFiles.name}', ' ')));

% 扫描器对照: 注释与字符串里提到 clipVolume 不算违规, 真调用必须抓到
tf = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
neg = sprintf(['function x = fakeSpec()\n', ...
    '%% 这里说明本文件不调用 clipVolume(), 只在文档里提一句\n', ...
    'x = ''审计量来自 meshSpec 全网格, 与 clipMesh 无关'';\n', ...
    'y = 1;   %% clipVolume(V,F)\nend\n']);
tc.verifyFalse(contains(codeOnlyText(neg), 'clipVolume('), ...
    '扫描器把注释/字面量里的 clipVolume 当成了调用 (会误伤文档)');
tc.verifyTrue(contains(codeOnlyText(neg), 'fakeSpec'), '扫描器把代码也删了 (负对照失效)');
for k = 1:2
    p = fullfile(tf.Folder, sprintf('injected_%d.m', k));
    if k == 1
        txt = sprintf('function V = f(V,F)\n  [a,b] = clipVolume(V, F);\nend\n');
    else
        txt = sprintf('function V = g(V,F)\n  V = tepc.geometry.clipVolume(V, F).V;\nend\n');
    end
    fid = fopen(p, 'w', 'n', 'UTF-8');
    fwrite(fid, txt, 'char');
    fclose(fid);
    c = codeOnlyText(fileread(p));
    tc.verifyTrue(contains(c, 'clipVolume('), ...
        sprintf('注入的第 %d 种真调用没被抓到 => 这条门是空的', k));
end
tc.verifyEqual(numel(dir(fullfile(tf.Folder, 'injected_*.m'))), 2);
end

function code = codeOnlyText(txt)
%CODEONLYTEXT 剥掉字符串字面量与注释, 只留代码 (源码扫描用)。
%   顺序不能反: 先剥字符串再剥注释, 否则字符串里的 % 会被当成注释起点而吞掉行尾。
%   MATLAB 正则的 . 匹配换行, 所以字符类里必须显式排除换行 ([^'\n] / [^%\n])。
Q = char(39);
txt = regexprep(txt, [Q '[^' Q '\n]*' Q], ' ');        % '...' 字面量
txt = regexprep(txt, '"[^"\n]*"', ' ');                % "..." 字面量
txt = regexprep(txt, '(?m)%[^\n]*', '');               % 行注释与 ... 续行注释
code = txt;
end

function test_clip_never_moves_an_audit_number(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
R = tepc.config.resolve(cfg);
spec = tepc.geometry.meshSpec(cfg, R);
V0 = spec.V_m3;  S0 = spec.S_m2;  L0 = spec.lbar_gas_m;
partsV = {spec.parts.V};
partsF = {spec.parts.F};
M0 = tepc.geometry.checkMesh(spec);
% 每个零件都真剖一刀 (含源锥与盒状世界体), 结果丢弃, 只看 spec 有没有被动过
nParts = numel(spec.parts);
for k = 1:nParts
    if isempty(spec.parts(k).V), continue; end
    o = tepc.geometry.clipVolume(spec.parts(k).V, spec.parts(k).F, ...
        'Plane', [1 0 0 0 0 0], 'PartID', spec.parts(k).part_id);
    tc.verifyTrue(o.display_only, spec.parts(k).part_id);
    tc.verifyFalse(o.audit.participates_in_V_S_lbar, spec.parts(k).part_id);
    tc.verifyFalse(o.audit.writes_back_into_parts_table, spec.parts(k).part_id);
    tc.verifyFalse(o.audit.writes_geometry_manifest, spec.parts(k).part_id);
    tc.verifyFalse(o.audit.consumed_by_checkMesh, spec.parts(k).part_id);
    tc.verifyFalse(o.audit.consumed_by_exportGeometry, spec.parts(k).part_id);
    tc.verifyFalse(o.audit.consumed_by_meshSpec, spec.parts(k).part_id);
    tc.verifyFalse(o.audit.consumed_by_sampleChord, spec.parts(k).part_id);
    tc.verifyEqual(o.units, 'SI');
    tc.verifyEqual(size(o.F, 2), 3);
    tc.verifyTrue(all(o.F(:) >= 1) && all(o.F(:) <= size(o.V,1)));
end
tc.verifyEqual(spec.V_m3, V0, 'AbsTol', 0, '剖切之后 V_m3 必须逐位不变');
tc.verifyEqual(spec.S_m2, S0, 'AbsTol', 0);
tc.verifyEqual(spec.lbar_gas_m, L0, 'AbsTol', 0);
for k = 1:nParts
    tc.verifyTrue(isequal(spec.parts(k).V, partsV{k}), ...
        sprintf('零件 %s 的网格顶点被剖切改写了', spec.parts(k).part_id));
    tc.verifyTrue(isequal(spec.parts(k).F, partsF{k}), ...
        sprintf('零件 %s 的网格面被剖切改写了', spec.parts(k).part_id));
end
M1 = tepc.geometry.checkMesh(spec);
tc.verifyEqual(M1.parts(1).volume_m3, M0.parts(1).volume_m3, 'AbsTol', 0);
tc.verifyEqual(M1.parts(1).area_m2, M0.parts(1).area_m2, 'AbsTol', 0);
tc.verifyEqual(M1.min_skin_gap_m, M0.min_skin_gap_m, 'AbsTol', 0);
tc.verifyEqual(M1.max_radius_err_rel, M0.max_radius_err_rel, 'AbsTol', 0);
tc.verifyEqual(numel(M1.parts), numel(M0.parts));
% 重算一份 spec 再比内容: **不能**用 isequal(spec_new, spec) 当判据 —— spec 里带着
% buildPartMesh 这个函数句柄字段, 两次构造的句柄按 MATLAB 的句柄语义永不相等 (实测:
% 差异只在 buildPartMesh / cylinderLength_m 的 NaN 与 parts(1).shape 的字段顺序上,
% 与剖切无关)。这里比的是审计量的内容: 解析量 + 每个零件的网格与闭式量。
spec2 = tepc.geometry.meshSpec(cfg, R);
tc.verifyEqual(spec2.V_m3, spec.V_m3, 'AbsTol', 0);
tc.verifyEqual(spec2.S_m2, spec.S_m2, 'AbsTol', 0);
tc.verifyEqual(spec2.lbar_gas_m, spec.lbar_gas_m, 'AbsTol', 0);
tc.verifyEqual([spec2.parts.analyticVolume_m3], [spec.parts.analyticVolume_m3]);
for k = 1:nParts
    tc.verifyTrue(isequal(spec2.parts(k).V, spec.parts(k).V), ...
        sprintf('重算的 spec 与剖切后的零件 %s 网格顶点不再相同', spec.parts(k).part_id));
    tc.verifyTrue(isequal(spec2.parts(k).F, spec.parts(k).F), ...
        sprintf('重算的 spec 与剖切后的零件 %s 网格面不再相同', spec.parts(k).part_id));
    tc.verifyEqual(spec2.parts(k).analyticVolume_m3, spec.parts(k).analyticVolume_m3, 'AbsTol', 0);
    tc.verifyEqual(spec2.parts(k).analyticArea_m2, spec.parts(k).analyticArea_m2, 'AbsTol', 0);
end
end
