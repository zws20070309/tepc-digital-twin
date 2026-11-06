function [V, F] = coneMesh(r, apex, base, n)
%CONEMESH 圆锥展示网格的唯一构造式: 顶点 + 底面 n 边形 + 底面圆心, 闭口。
%   [V,F] = tepc.geometry.coneMesh(r, apex, base, n)
%   轴 = 底心指向顶点, 可以是任意方向 (源方向现在由配置供数)。
%
%   为什么单独成文件: meshSpec 建网格、exportGeometry 由**声明尺寸**推期望包络, 两边需要
%   同一个构造式。此前 exportGeometry 自己抄了一份顶点算法, 于是"一份几何两处实现" ——
%   而复制品与原件同错, 既拦不住构造式本身的错, 又违反 meshSpec 头注的单一实现纪律。
%   现在期望值 = 本函数按声明尺寸算出的顶点集的包围盒: 它不读回写出的文件字节, 所以
%   单位缩放/写盘错仍然可检; 它不独立于构造式, 所以构造式自身的错交给 checkMesh 的
%   解析体积/半径门去拦 (不是这条检查的职责)。
%
%   顶点顺序: 局部系里顶点总在底面的"+u"侧, 所以绕序只需一套; 整体手性由调用方按
%   有向体积统一翻转。n 偶或奇都不影响"u=+z 时 e1=x, e2=y"这一点, 因此默认工况下
%   顶点与本函数改动前逐位相同。
%   错误标识符: tepc:geometry:DegenerateCone (顶点与底心重合/非有限, 由测试实测可触发);
%               tepc:geometry:BadConeAxis 是护栏而非活路径 —— 参考轴按 |u 分量| 选,
%               两条分支给出的 |e1| 下界分别约 0.436 与 0.9, 有限非零 u 下投影不可能为零。

ax = double(apex(:)).' - double(base(:)).';
L = norm(ax);
if ~(isfinite(L) && L > 0)
    error("tepc:geometry:DegenerateCone", ...
        "锥顶与锥底重合或含非有限值 (|apex-base|=%.3g): 无法定轴", L);
end
u = ax / L;
n = max(4, round(double(n)));
[e1, e2] = coneFrame(u);
ph = 2*pi*(0:n-1)/n;
ring = repmat(double(base(:)).', n, 1) + (r*cos(ph(:)))*e1 + (r*sin(ph(:)))*e2;
V = [double(apex(:)).'; double(base(:)).'; ring];
% 有符号零归一: 0*(-1) 给 -0, 它与 +0 逐位相等 (isequal 为真, 差为 0), 但 %.17g 会写成
% "-0", 于是只改符号零不改任何坐标的网格也会挪动内容哈希。这里在构造式出口归一, 让
% 哈希只对真正的坐标变化敏感; x+0 对一切有限值恒等, 只把 -0 变成 +0。
V = V + 0;

cA = 1; cB = 2;
F = zeros(2*n, 3);
k = 0;
for j = 1:n
    a = 2 + mod(j-1, n) + 1;
    b = 2 + mod(j, n) + 1;
    k = k+1; F(k,:) = [cA b a];                    % 侧壁
    k = k+1; F(k,:) = [cB a b];                    % 底盖
end
F = F(1:k,:);
end

function [e1, e2] = coneFrame(u)
% 与 u 正交的单位基 (e1,e2,u) 右手系。参考轴取与 u 夹角最小的坐标轴的反面, 避免
% "投影后近零再归一"的数值退化; u=+z 时给出 e1=x, e2=y。
if abs(u(1)) < 0.9
    tmp = [1 0 0];
else
    tmp = [0 1 0];
end
e1 = tmp - dot(tmp, u)*u;
n1 = norm(e1);
if ~(n1 > 0 && isfinite(n1))
    error("tepc:geometry:BadConeAxis", "无法为轴 %s 构造正交基", mat2str(u));
end
e1 = e1 / n1;
e2 = cross(u, e1);
end
