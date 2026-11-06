function map = solveElectrostatic(a_m, b_m, hv_V, opts)
%SOLVEELECTROSTATIC 2-D 轴对称静电有限元求解 (PDE Toolbox), 产出场图结构。
%   map = solveElectrostatic(a_m, b_m, hv_V)
%     -> 同轴极限几何 (子午面矩形 r∈[a,b], z∈[0,b]), 网格层级 2
%   map = solveElectrostatic(a_m, b_m, hv_V, opts)   opts 全部可选:
%     geometry            'coax' | 'sphereWire'   缺省 'coax'
%     gridLevel           1|2|3                   缺省 2 (层级每 +1: nDiv 翻倍、hmin 减半)
%     wireHalfLenFactor   阳极丝半长 / b          缺省 0.9, 仅 sphereWire 用
%     nPath               径向采样路径点数        缺省 400
%     valueStatus         struct, 形如 struct('a_m',"MEASURED") 的取值状态覆写
%     valueSource         struct, 同形的来源标注 (自由文本)
%     savePath            非空则 save 成 .mat (供 field.mode='fem_map' 消费)
%
% 方程与离散
%   createpde('electromagnetic','electrostatic-axisymmetric') 在子午面 (r,z) 上解
%     div(eps*grad V) = 0, 弱形式自带 2*pi*r 轴对称权重, 即
%     d/dr(r*dV/dr) + r*d2V/dz2 = 0; 不需要 (也无法) 用通用标量模型写 c='r' ——
%     实测 R2025a 的 specifyCoefficients 的 'c' 只接受 double 或 function_handle,
%     传字符表达式报 MATLAB:invalidType。
%   边界: 阳极面 V=hv_V, 阴极面 V=0 (electromagneticBC 'Voltage'); 其余边界
%     (同轴极限的两个 z 端面 / 球-丝几何的自转轴 r=0) 不加 BC = 自然零通量条件,
%     与轴对称镜面条件一致。
%   网格: generateMesh('Hmax',(b-a)/nDiv,'Hmin',hmin,'Hgrad',hgrad,
%         'Hedge',{阳极边号, hmin})。Hedge 把阳极边界上的单元尺寸钉在 hmin, 再由
%     Hgrad 向外放大; 缺了它整个域被 Hmax 支配, 而对数式电位降几乎全落在阳极附近的
%     几个单元里 —— 实测同一 nDiv 下阳极通量相对误差差一个量级。
%   单位: 全 SI (m, V, V/m); x 轴 = 柱坐标径向 r, y 轴 = 沿阳极丝的轴向 z。
%
% 本机实测的 API 约束 (R2025a + PDE, 每条都在本机上跑过; 按记忆猜签名会踩空)
%   * pde.ElectromagneticModel 的方法表里没有 applyBoundaryCondition, 也没有
%     evaluate/interpolate; BC 只能 electromagneticBC(em,'Edge',ids,'Voltage',v)。
%     'Value'/'g'/'Condition','Dirichlet' 这些写法全部报 MATLAB:TooManyInputs。
%   * solve 前必须 em.VacuumPermittivity = 8.8541878128e-12; 不给则
%     pde:ElectromagneticModel:missingVacuumPermittivity。而
%     electromagneticProperties 不接受 'VacuumPermittivity' 名值对 (只认
%     Face/Cell/RelativePermittivity/RelativePermeability/Conductivity)。
%   * 求值走结果对象方法: interpolateElectricPotential(res,rq,zq) 与
%     interpolateElectricField(res,rq,zq) (模型对象上没有这两个方法); 后者返回
%     pde.FEStruct, 轴对称分量名 .x (径向) / .y (轴向), .Ex/.Ey 是同值别名;
%     .Magnitude 对插值结果实测是 0x0 空数组, 所以幅值自己用 hypot 算。
%   * decsg 的矩形/多边形列必须是 [3; N; x1..xN; y1..yN] (N 段封闭折线);
%     [3; x; y; w; h] 形式报 pdelib:decsg:NonintegerPolygonPoints。
%     布尔集公式: decsg(GD,'(C*H)-W',{'C','H','W'}), 且不同形状的列要补齐同高。
%   * 几何边号 = decsg 输出矩阵的列号; 归属用第 2/3 行 (起点/终点 x) 与第 4/5 行
%     (起点/终点 y) 按坐标判, 不依赖列顺序。
%   * electromagneticBC 的 'Edge' 列表给**行向量** (见 meridionalGeometry 里的 edgeIds):
%     pde 求解前检查把所有 BC 记录的 RegionID 横向串联, 阳极/阴极两组长度不同的列
%     向量会让它抛 MATLAB:catenate:dimensionMismatch, 报错点在 em.solve 内部。
%   * pde.FEMesh 没有 Edges/NumCells 属性; 单元数用 size(Mesh.Elements,2),
%     最大/最小单元尺寸用 Mesh.MaxElementSize / Mesh.MinElementSize。
%   * license('test','PDE_Toolbox') 返回 1, 而 ver 里的产品名是
%     'Partial Differential Equation Toolbox' (按 'PDE Toolbox' 查 ver 查不到)。
%
% 阳极面奇异性 —— 为什么收敛判据不作用于逐点值
%   丝状阳极表面的场按 E(r)=V/(r*ln(b/a)) 发散 (柱对称 1/r 奇点; 同心球壳阳极是
%   1/r^2), sphereWire 的丝端角点另叠加一个楔形边奇点。P1 元下逐点 max|E| 随
%   h_min 收缩持续上移 (~1/h_min), 没有一致收敛极限; 拿它做网格无关性判据等于
%   要求一个发散量收敛, 只会得到一串永远不达标的红灯。因此这里同时输出
%     逐点诊断: integral.anodePeakEmag (随层级变, 只报告不作判据)
%     积分量:   integral.fluxAnode    = int r*E_r dz  (阳极侧面通量/2pi, V*m)
%               integral.lineIntEmag  = int |E| dr    (径向场线积分, V)
%               integral.phiwDiff     = phi_w(2a) - phi_w(b/2)  (权重势差, 无量纲)
%   三者都有良定义的连续极限, 网格收敛核对只对它们做 (tepc.detector.fieldConvergence)。
%   逐点值本身的可信区间用"离奇点足够远"的子域表达: analytic.maxRelDev* 只在
%   r >= 2a 上取, 且与闭式解对照。
%
% 返回 map (字段名即消费方契约, 见 tepc.detector.fieldOf)
%   schema='tepc-fieldmap-v1'; a_m b_m hv_V kind geometry gridLevel nDiv hmin_m
%   hmax_m h_rel (=hmax_m/(b_m-a_m)) hOverA (=hmax_m/a_m) nNodes nCells nDof
%   nodeR nodeZ V Er Ez       (节点量: 子午面坐标、电位、场强径向/轴向分量)
%   path    struct(r_m z_m V Er Ez Emag phiw)   径向采样路径上的插值场
%   bcEnd   struct(r_a V_a r_b V_b)             两个电极面的 Dirichlet 精确值
%   integral struct(...)                        见上
%   analytic struct(r_m V Er maxRelDevV maxRelDevEr farFromR K_cyl interpretation)
%                同轴闭式对照 V(r)=hv_V*ln(b/r)/ln(b/a), E(r)=hv_V/(r*ln(b/a))
%   fingerprint  sha256(a,b,hv_V,gridLevel,geometry) 的 64 位小写 hex
%   evidence     struct(版本/许可/耗时/网格参数/参数取值状态表/说明)
%
% 错误标识符
%   tepc:field:BadRadii        0<a<b 不成立 (与 fieldModel 同一契约)
%   tepc:field:BadGeometry     geometry 不在 {coax, sphereWire}
%   tepc:field:BadGridLevel    gridLevel 非 1..3 的整数
%   tepc:field:BadWireFactor   wireHalfLenFactor 不在 (0,1)
%   tepc:field:BadPathPoints   nPath 非 >=25 的整数
%   tepc:field:BadValueStatus  value_status 不在 {MEASURED,REFERENCE,ASSUMED}
%   tepc:field:SolveFailed     PDE 建模/求解/求值失败 (带出原始标识符与消息)

if nargin < 4 || isempty(opts), opts = struct(); end
if ~(isnumeric(a_m) && isscalar(a_m) && a_m > 0) || ~(isnumeric(b_m) && isscalar(b_m) && b_m > a_m)
    error("tepc:field:BadRadii", "需要 0 < a (%.3e) < b (%.3e)", a_m, b_m);
end
EPS0 = 8.8541878128e-12;      % F/m; EM 模型要求显式真空介电常数才能给出 SI 量纲的 E
gv = @(nm, dflt) getOpt(opts, nm, dflt);
geomRaw = gv('geometry', 'coax');
% 规范名保留大小写 ('sphereWire' 是驼峰), 比较才用 lower: 直接 lower() 后再与
% 驼峰词表比会让 'sphereWire' 自己被判成非法值。
switch lower(strtrim(char(string(geomRaw))))
    case 'coax',        geom = "coax";
    case 'spherewire',  geom = "sphereWire";
    otherwise
        error("tepc:field:BadGeometry", ...
            "opts.geometry 只能是 'coax' (同轴极限) 或 'sphereWire' (球腔+中心丝), 实得 '%s'", ...
            char(string(geomRaw)));
end
levRaw = gv('gridLevel', 2);
if ~(isnumeric(levRaw) && isscalar(levRaw) && isfinite(levRaw) && ...
        levRaw == floor(levRaw) && levRaw >= 1 && levRaw <= 3)
    error("tepc:field:BadGridLevel", ...
        "opts.gridLevel 只能是 1..3 的整数 (每 +1: nDiv 翻倍、hmin 减半), 实得 %s", ...
        mat2str(levRaw));
end
lev = double(levRaw);
wfRaw = gv('wireHalfLenFactor', 0.9);
if ~(isnumeric(wfRaw) && isscalar(wfRaw) && isfinite(wfRaw) && wfRaw > 0 && wfRaw < 1)
    error("tepc:field:BadWireFactor", ...
        "opts.wireHalfLenFactor 必须在 (0,1): 取 1 时丝端与球壳壁重合, 域退化为零厚间隙, 实得 %s", ...
        mat2str(wfRaw));
end
nP = gv('nPath', 400);
if ~(isnumeric(nP) && isscalar(nP) && isfinite(nP) && nP >= 25 && nP == floor(nP))
    error("tepc:field:BadPathPoints", "opts.nPath 必须是 >=25 的整数, 实得 %s", mat2str(nP));
end

a = double(a_m); b = double(b_m); V = double(hv_V);
nDiv = 16*2^(lev - 1);        % 径向等分数 16 / 32 / 64
hmin = a*(4/nDiv);            % 阳极侧最小单元尺寸 a/4, a/8, a/16
hgrad = 1.25 - 0.05*lev;      % 逐级收紧: 1.20 / 1.15 / 1.10
L = b;                        % 同轴极限子午面矩形高度 (取腔半径量级)
zw = double(wfRaw)*b;         % sphereWire 的丝半长

% ---- 子午面几何与电极边号 ----
[gd, es] = meridionalGeometry(geom, a, b, L, zw);

tAll = tic;
try
    em = createpde('electromagnetic', 'electrostatic-axisymmetric');
    geometryFromEdges(em, gd);
    em.VacuumPermittivity = EPS0;
    electromagneticProperties(em, 'RelativePermittivity', 1);
    electromagneticBC(em, 'Edge', es.anode, 'Voltage', V);
    electromagneticBC(em, 'Edge', es.cathode, 'Voltage', 0);
    tM = tic;
    generateMesh(em, 'Hmax', (b - a)/nDiv, 'Hmin', hmin, 'Hgrad', hgrad, ...
        'Hedge', {es.anode, hmin});
    meshTime = toc(tM);
    tS = tic;
    res = em.solve();
    solveTime = toc(tS);
    nds = em.Mesh.Nodes;
    nodV = double(res.ElectricPotential(:));
    nodE = res.ElectricField;
    nodEr = double(nodE.x(:));
    nodEz = double(nodE.y(:));
    % 径向采样路径: 对数间隔, 端点 r=b*(1-1e-3) 留在开区间内 (b 上的值由 bcEnd 给)
    rPath = geomspace(a, b*(1 - 1e-3), double(nP)).';
    zPath = es.zProbe*ones(size(rPath));
    pV = double(interpolateElectricPotential(res, rPath, zPath));
    pE = interpolateElectricField(res, rPath, zPath);
    pEr = double(pE.x(:));
    pEz = double(pE.y(:));
    za = linspace(es.zAnodeLo, es.zAnodeHi, 1200).';
    Ea = interpolateElectricField(res, a*ones(size(za)), za);
catch ME
    % 把原始出错位置带进消息: PDE 的 API 形状约束多, 只给标识符定位不到是哪一次调用。
    stk = ME.stack;
    where = '位置未知';
    for q = 1:numel(stk)
        [~, nm] = fileparts(stk(q).file);
        where = sprintf('%s 第 %d 行 (%s.m)', nm, stk(q).line, nm);
        if strcmp(stk(q).name, 'solveElectrostatic'), break; end
    end
    error("tepc:field:SolveFailed", ...
        "PDE 轴对称静电求解失败 (%s; 原始标识符 %s): %s", where, ME.identifier, ME.message);
end
pEm = hypot(pEr, pEz);
phiw = pV/V;
fluxSide = double(Ea.x(:));
fluxAnode = trapz(za, a*fluxSide);         % 通量/2pi [V*m]: int r*E_r dz, r=a
lineInt = trapz(rPath, pEm);               % int|E|dr [V]
peakAnode = max(abs(fluxSide));            % 逐点诊断 (发散量)
if numel(rPath) < 2 || ~all(diff(rPath) > 0)
    error("tepc:field:SolveFailed", "径向采样路径必须严格递增, 实得 %d 点", numel(rPath));
end
if ~all(isfinite(pV)) || ~all(isfinite(pEm)) || ~all(isfinite(nodV))
    error("tepc:field:SolveFailed", ...
        "解出的电位/场强含非有限值 (节点 %d/%d, 路径 %d/%d)", ...
        sum(isfinite(nodV)), numel(nodV), sum(isfinite(pEm)), numel(pEm));
end
if ~(abs(phiw(1) - 1) < 1e-9) || ~all(phiw >= -eps)
    error("tepc:field:SolveFailed", ...
        "阳极面电位边界条件未被满足: phi_w(a)=%.12g (要求 1)", phiw(1));
end
i2 = find(rPath >= 2*a, 1);                % 2a: 奇点邻域外缘 (也是增益区外缘)
i3 = find(rPath >= b/2, 1);                % b/2: 灵敏体积中点
if isempty(i2) || isempty(i3) || i3 <= i2
    error("tepc:field:SolveFailed", ...
        "采样路径必须同时覆盖 2a=%.3e 与 b/2=%.3e (实得 %.3e..%.3e)", ...
        2*a, b/2, rPath(1), rPath(end));
end
phiwDiff = phiw(i2) - phiw(i3);

% ---- 同轴闭式对照 (只在 r>=2a 的"离奇点远"子域上取最大相对偏差) ----
Kc = 1/log(b/a);
anaV = V*Kc*log(b./rPath);
anaE = V*Kc./rPath;
far = rPath >= 2*a;
devV = max(abs(pV(far)./anaV(far) - 1));
devE = max(abs(pEr(far)./anaE(far) - 1));
if geom == "coax"
    interpTxt = char("求解离散误差: 同轴极限几何的闭式解就是该边值问题的精确解, " + ...
        "该偏差只含有限元离散误差, 随网格加密应下降");
    fluxIdeal = V*L*Kc;
else
    interpTxt = char("物理差异: 球腔+中心丝的真实边值问题与理想同轴公式之差, " + ...
        "含丝端效应与球面阴极形状效应, 不是求解器误差");
    fluxIdeal = V*2*zw*Kc;
end

map = struct();
map.schema = 'tepc-fieldmap-v1';
map.a_m = a; map.b_m = b; map.hv_V = V; map.kind = 'cylinder';
map.geometry = char(geom);
map.gridLevel = lev; map.nDiv = nDiv; map.hmin_m = hmin; map.hgrad = hgrad;
map.hmax_m = double(em.Mesh.MaxElementSize);
map.h_rel = map.hmax_m/(b - a);
map.hOverA = map.hmax_m/a;
map.nNodes = size(nds, 2); map.nCells = size(em.Mesh.Elements, 2);
map.nDof = numel(nodV);
map.nodeR = double(nds(1, :).'); map.nodeZ = double(nds(2, :).');
map.V = nodV; map.Er = nodEr; map.Ez = nodEz;
map.path = struct('r_m', rPath, 'z_m', zPath, 'V', pV, 'Er', pEr, 'Ez', pEz, ...
    'Emag', pEm, 'phiw', phiw);
map.bcEnd = struct('r_a', a, 'V_a', V, 'r_b', b, 'V_b', 0);
map.integral = struct('fluxAnode', fluxAnode, 'lineIntEmag', lineInt, ...
    'phiwDiff', phiwDiff, 'anodePeakEmag', peakAnode, ...
    'rRef2a', rPath(i2), 'rRefHalfB', rPath(i3), ...
    'zAnode_lo', es.zAnodeLo, 'zAnode_hi', es.zAnodeHi, ...
    'nFluxPoints', numel(za), 'fluxAnodeIdealCoax', fluxIdeal);
map.analytic = struct('r_m', rPath, 'V', anaV, 'Er', anaE, ...
    'maxRelDevV', devV, 'maxRelDevEr', devE, 'farFromR', 2*a, ...
    'K_cyl', Kc, 'interpretation', interpTxt);
map.fingerprint = tepc.detector.fieldMapFingerprint(a, b, V, lev, char(geom));
map.evidence = buildEvidence(a, b, V, lev, char(geom), nDiv, hmin, hgrad, ...
    map.hmax_m, map.nNodes, map.nCells, map.nDof, meshTime, solveTime, toc(tAll), ...
    opts, numel(za), double(nP), zw);
if isfield(opts, 'savePath') && ~isempty(opts.savePath)
    sp = char(string(opts.savePath));
    save(sp, 'map');
    map.evidence.saved_to = sp;
    map.evidence.saved_sha256 = tepc.io.hashFile(sp);
end
end

% ==================== 局部实现 ====================

function [gd, es] = meridionalGeometry(geom, a, b, L, zw)
%MERIDIONALGEOMETRY 子午面 (r,z) 几何与电极边号。
%   边号 = decsg 输出矩阵的列号。归属只按坐标判: 实测矩形几何里列序是
%   阳极边=1, z=L 边=2, 阴极边=3, z=0 边=4; 球-丝几何里圆弧被自转轴与丝端切成
%   多段 (实测 7 条边: 丝侧面 1, 丝端盖 2/3, 自转轴 4/5, 球壳弧 6/7),
%   因此不能把边号写死。
tol = 1e-9*b;
if geom == "coax"
    % 矩形 [a,b]x[0,L]: 阳极 = r=a 竖边, 阴极 = r=b 竖边, 两端面自然零通量。
    gd = decsg(rectGD([a; a; b; b], [0; L; L; 0]));
    es.anode = 1; es.cathode = 3;
    es.zProbe = L/2;                  % 中面: 离两端面最远, 场最接近纯径向
    es.zAnodeLo = 0; es.zAnodeHi = L;
else
    % 子午面半盘 {r^2+z^2 <= b^2, r >= 0} 挖掉丝截面 {0 <= r <= a, |z| <= zw}。
    % 丝矩形从 r=0 起笔 (轴对称模型的子午坐标 r 不得为负): 它的左边线与自转轴重合,
    % decsg 会把轴与圆弧在那一点切开 —— 实测输出 7 条边, 且与"让矩形向左越过轴线"
    % 的旧写法子午面积同一量级 (相对差 4e-8), 也没有触发 pdelib:decsg:ReusedPointPolygon
    % (那条报错来自多边形自身有重复顶点, 与跟轴共线无关)。
    % 切完剩下的两条 r=0 轴段 (zw <= |z| <= b) 既非阳极也非阴极: 轴对称静电里
    % 自转轴上的零径向通量是自然边界条件, 给它加 Dirichlet 反而是错的。
    gd = decsg([circGD(0, 0, b), rectGD([0; 0; b; b], [-b; b; b; -b]), ...
        rectGD([0; 0; a; a], [-zw; zw; zw; -zw])], '(C*H)-W', {'C', 'H', 'W'});
    x1 = gd(2, :); x2 = gd(3, :); y1 = gd(4, :); y2 = gd(5, :);
    onAn  = abs(x1 - a) < tol & abs(x2 - a) < tol;
    onCap = (abs(y1 - zw) < tol & abs(y2 - zw) < tol) | ...
            (abs(y1 + zw) < tol & abs(y2 + zw) < tol);
    onCap = onCap & max(abs(x1), abs(x2)) < a*1.5;
    onCat = abs(hypot(x1, y1) - b) < tol & abs(hypot(x2, y2) - b) < tol;
    es.anode = edgeIds(onAn | onCap);
    es.cathode = edgeIds(onCat);
    if isempty(es.anode) || isempty(es.cathode) || any(ismember(es.cathode, es.anode))
        error("tepc:field:BadGeometry", ...
            "球腔+中心丝几何未识出互斥的电极边界 (阳极 %d 条, 阴极 %d 条)", ...
            numel(es.anode), numel(es.cathode));
    end
    es.zProbe = 0;                    % 赤道面 (对称面), 与理想同轴公式直接可比
    es.zAnodeLo = -zw; es.zAnodeHi = zw;
end
end

function ids = edgeIds(mask)
%EDGEIDS 布尔边掩码 -> 行向量边号 (find 的空返回是 0x1, 非空返回跟随输入形状)。
%   必须是行向量: electromagneticBC 把 Edge 列表原样存进 BC 记录, 而 pde 的求解前
%   检查用 regionsWithAssignment = [self.BCAssignments.RegionID] 横向串联所有记录
%   (findElectromagneticBC 第 57 行)。阳极 3 条与阴极 2 条若都是列向量, 这个串联就
%   抛 MATLAB:catenate:dimensionMismatch, 且报错点在 em.solve 内部, 看着像几何或
%   装配失败。行数相同的两个列向量能拼上, 所以这条约束只在多电极组时咬人。
ids = find(mask);
ids = ids(:).';
end

function col = rectGD(xs, ys)
% 矩形/多边形 GD 列: [3; N; x1..xN; y1..yN], N 段封闭折线 (10 行)。
col = [3; 4; xs(:); ys(:)];
end

function col = circGD(x, y, r)
% 圆 GD 列 [1; x; y; r] 补零到 10 行: decsg 的 GD 是同一矩阵的列, 必须等高。
col = [1; x; y; r; zeros(6, 1)];
end

function v = geomspace(lo, hi, n)
% 对数间隔采样: 电位按 ln r 下降, 每十倍程取同样多样本才能同时覆盖奇点邻域与远端。
v = lo*(hi/lo).^((0:n-1)/(n - 1));
end

function e = buildEvidence(a, b, V, lev, geom, nDiv, hmin, hgrad, hmax, nNodes, ...
    nCells, nDof, tm, ts, tt, opts, nFlux, nPath, zw)
%BUILDEVIDENCE 溯源信息: 版本、许可、耗时、网格参数、每个输入参数的取值状态。
e = struct();
e.matlab_version = version();
e.matlab_release = version('-release');
e.matlab_arch = computer;
vv = ver();
k = find(strcmp({vv.Name}, 'Partial Differential Equation Toolbox'), 1);
if isempty(k)
    k = find(contains(lower({vv.Name}), 'partial differential'), 1);
end
if isempty(k)
    e.pde_product = 'not-listed-by-ver';
    e.pde_version = '';
else
    e.pde_product = vv(k).Name;
    e.pde_version = vv(k).Version;
end
e.license_feature = 'PDE_Toolbox';
e.license_available = logical(license('test', 'PDE_Toolbox'));
e.license_note = char("license('test','PDE_Toolbox') 的即时检查结果; " ...
    + "无许可时求解抛 pde:* 异常并被映射成 tepc:field:SolveFailed, 不静默降级到解析场");
e.analysis_type = 'electrostatic-axisymmetric';
e.solver = 'pde.ElectromagneticModel.solve (P1 三角元, 子午面带 2*pi*r 权重)';
e.mesh_time_s = tm;
e.solve_time_s = ts;
e.total_time_s = tt;
e.n_nodes = nNodes; e.n_cells = nCells; e.n_dof = nDof;
e.h_max_m = hmax; e.h_min_m = hmin; e.h_grad = hgrad; e.n_div = nDiv;
e.grid_level = lev; e.geometry = geom;
e.wire_half_length_m = zw;
e.n_flux_points = nFlux; e.n_path_points = nPath;
e.created_utc = char(datetime('now', 'TimeZone', 'UTC'));
e.singular_anode_note = char("阳极面 E~1/r 发散 (丝端角点另有楔形奇点), 逐点 max|E| " ...
    + "无网格无关极限; 收敛判据只作用于积分量");
e.parameter_status = paramStatus(a, b, V, lev, geom, hmin, hgrad, nPath, opts);
end

function rows = paramStatus(a, b, V, lev, geom, hmin, hgrad, nPath, opts)
%PARAMSTATUS 每个输入参数的取值状态表 (词表 MEASURED|REFERENCE|ASSUMED)。
%   缺省一律 ASSUMED: 求解器无从知道调用方手里的半径/电压来自图纸还是猜测, 把缺省
%   写成 MEASURED 就是伪造溯源。调用方用 opts.valueStatus / opts.valueSource 覆写。
%   状态词表与 docs/constants.json 的 status、config schema 的 status 同一套三词。
%   由网格层级导出的量 (hmin/hgrad/gridLevel) 是算法自身的规定, 记 REFERENCE 并把
%   定义写进 source —— 它可被复算, 但不来自实验。
dflt = {{'a_m',               a,     'm',                  'ASSUMED',   ''}, ...
        {'b_m',               b,      'm',                 'ASSUMED',   ''}, ...
        {'hv_V',              V,      'V',                 'ASSUMED',   ''}, ...
        {'geometry',           NaN,   '- (coax|sphereWire)', 'ASSUMED', geom}, ...
        {'gridLevel',          lev,   '- (1|2|3)',          'REFERENCE', 'solveElectrostatic 层级表: nDiv=16*2^(lev-1), hmin=a*4/nDiv'}, ...
        {'hmin_m',             hmin,  'm',                 'REFERENCE', '由 gridLevel 导出的数值护栏'}, ...
        {'hgrad',              hgrad, '-',                  'REFERENCE', '由 gridLevel 导出的数值护栏'}, ...
        {'nPath',              nPath, '-',                  'ASSUMED',   '采样分辨率'}};
rows = struct('name', {}, 'value', {}, 'units', {}, 'value_status', {}, 'source', {});
for i = 1:numel(dflt)
    d = dflt{i};
    [st, sr] = override(opts, d{1}, d{4}, d{5});
    rows(end+1) = struct('name', d{1}, 'value', d{2}, 'units', d{3}, ...
        'value_status', st, 'source', sr); %#ok<AGROW>
end
stc = {rows.value_status};
bad = false(1, numel(stc));
for i = 1:numel(stc)
    bad(i) = ~any(strcmp(stc{i}, {'MEASURED', 'REFERENCE', 'ASSUMED'}));
end
if any(bad)
    bi = find(bad);
    error("tepc:field:BadValueStatus", ...
        "opts.valueStatus 给参数 %s 写的状态 '%s' 不在词表 {MEASURED,REFERENCE,ASSUMED} 内", ...
        strjoin({rows(bi).name}, ','), strjoin(stc(bi), ','));
end
end

function [st, sr] = override(opts, nm, st, sr)
if isfield(opts, 'valueStatus') && isstruct(opts.valueStatus) && isfield(opts.valueStatus, nm)
    st = upper(strtrim(char(string(opts.valueStatus.(nm)))));
end
if isfield(opts, 'valueSource') && isstruct(opts.valueSource) && isfield(opts.valueSource, nm)
    sr = strtrim(char(string(opts.valueSource.(nm))));
end
end

function v = getOpt(opts, nm, dflt)
if isfield(opts, nm) && ~isempty(opts.(nm))
    v = opts.(nm);
else
    v = dflt;
end
end
