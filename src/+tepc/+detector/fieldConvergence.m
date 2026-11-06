function C = fieldConvergence(a_m, b_m, hv_V, opts)
%FIELDCONVERGENCE 场图的网格收敛研究: 只对积分量判收敛。
%   C = fieldConvergence(a_m, b_m, hv_V)              缺省 'coax', 层级 [1 2 3]
%   C = fieldConvergence(___,opts)  opts 可选字段:
%     geometry   'coax' | 'sphereWire'   缺省 'coax'
%     levels     层级向量                缺省 [1 2 3] (至少 2 级)
%     valueStatus/valueSource/nPath      透传给 tepc.detector.solveElectrostatic
%
% 为什么只判积分量
%   丝状阳极表面的 E 按 1/r 发散 (球壳阳极 1/r^2), P1 元下逐点 max|E| 随 h_min
%   收缩单调上移, 没有网格无关极限; 把收敛门禁用在它上面等于要求一个发散量收敛。
%   积分量 (阳极通量 int r*E_r dz、径向场线积分 int|E|dr、权重势差
%   phi_w(2a)-phi_w(b/2)) 都有良定义的连续极限, 才是"网格加密后结果还变不变"的
%   可判据形式。逐点值另用"离奇点远"子域上的闭式相对偏差来表达可信区间
%   (levels.maxRelDevEr, 只在 r >= 2a 上取)。
%
% 门禁 (两个预注册阈值都从 docs/constants.json 读, 代码里不留镜像值)
%   tepc.config.constants('field.fem.convergenceMaxRelDelta')
%     相邻层级积分量的最大相对变化上界。
%   tepc.config.constants('field.fem.maxRelDevEmagAwayOfAnode')
%     最细一层上 |E| 对同轴闭式解的最大相对偏差上界, 只在 r >= 2a 子域取。
%     该阈值只对 geometry='coax' 作为**求解器误差**判据: 同轴极限几何的闭式解
%     就是该边值问题的精确解。sphereWire 下同一个数变成"真实边值问题与理想
%     同轴公式的物理差", 与网格无关, 因此只报告不判门禁 (见 C.gate)。
%
% 返回 C
%   C.levels   struct 数组, 每级: gridLevel nDiv h_m h_rel nCells nDof meshTime_s
%              solveTime_s fluxAnode lineIntEmag phiwDiff anodePeakEmag
%              maxRelDevV maxRelDevEr intE_a_10a intE_a_10b_rel
%   C.delta    struct 数组 (len = numel(levels)-1): 每个积分量相对上一级的相对变化
%   C.hRatio   各级 h_max 相对第一级的比值
%   C.gate     struct: convergenceMaxRelDelta / maxRelDevEmagAwayOfAnode 的取值、
%              实测最大相对变化、最细层实测偏差、两个判据各自是否适用与是否通过
%   C.passed   逻辑标量: 全部适用判据都通过
%   C.map      最细一层的完整场图 (供 field.mode='fem_map' 直接用)
%   C.notes    cellstr: 口径说明 (含积分量与逐点量的差别、奇异性处理)
%
% 错误标识符: 透传 tepc:field:* (solveElectrostatic 的入参校验), 另加
%   tepc:field:BadLevels   levels 少于 2 级或含非 1..3 的整数

if nargin < 4 || isempty(opts), opts = struct(); end
nv = getfield2(opts, 'levels', [1 2 3]);
nv = double(nv(:));
if numel(nv) < 2 || any(nv ~= floor(nv)) || any(nv < 1 | nv > 3)
    error("tepc:field:BadLevels", "opts.levels 至少 2 个、取值 1..3 的整数, 实得 %s", mat2str(nv));
end
tolConv = tepc.config.constants('field.fem.convergenceMaxRelDelta');
tolDev  = tepc.config.constants('field.fem.maxRelDevEmagAwayOfAnode');

so = rmfield2(opts, 'levels');
maps = cell(numel(nv), 1);
for i = 1:numel(nv)
    so.gridLevel = nv(i);
    maps{i} = tepc.detector.solveElectrostatic(a_m, b_m, hv_V, so);
end
finest = maps{end};
L = repmat(struct('gridLevel', 0, 'nDiv', 0, 'h_m', 0, 'h_rel', 0, 'nCells', 0, ...
    'nDof', 0, 'meshTime_s', 0, 'solveTime_s', 0, 'fluxAnode', 0, 'lineIntEmag', 0, ...
    'phiwDiff', 0, 'anodePeakEmag', 0, 'maxRelDevV', 0, 'maxRelDevEr', 0, ...
    'intE_a_10a', 0, 'intE_a_10a_rel', 0), 1, numel(nv));
for i = 1:numel(nv)
    mp = maps{i};
    L(i).gridLevel = mp.gridLevel;
    L(i).nDiv = mp.nDiv;
    L(i).h_m = mp.hmax_m;
    L(i).h_rel = mp.h_rel;
    L(i).nCells = mp.nCells;
    L(i).nDof = mp.nDof;
    L(i).meshTime_s = mp.evidence.mesh_time_s;
    L(i).solveTime_s = mp.evidence.solve_time_s;
    L(i).fluxAnode = mp.integral.fluxAnode;
    L(i).lineIntEmag = mp.integral.lineIntEmag;
    L(i).phiwDiff = mp.integral.phiwDiff;
    L(i).anodePeakEmag = mp.integral.anodePeakEmag;
    L(i).maxRelDevV = mp.analytic.maxRelDevV;
    L(i).maxRelDevEr = mp.analytic.maxRelDevEr;
    % 增益真正用的那个积分: int_a^{10a} E dr 用"电位差"取 (与 fieldOf 的 intE 同口径),
    % 再与闭式 V*K*ln(10) 比 —— 这是"换成场图后增益会变多少"的直接答案。
    L(i).intE_a_10a = mp.path.V(1) - interp1(mp.path.r_m, mp.path.V, 10*mp.a_m, 'linear');
    L(i).intE_a_10a_rel = L(i).intE_a_10a/(mp.hv_V*mp.analytic.K_cyl*log(10)) - 1;
end
D = repmat(struct('fromLevel', 0, 'toLevel', 0, 'fluxAnode', 0, 'lineIntEmag', 0, ...
    'phiwDiff', 0), 1, max(0, numel(nv) - 1));
for i = 2:numel(nv)
    D(i-1).fromLevel = L(i-1).gridLevel;
    D(i-1).toLevel = L(i).gridLevel;
    D(i-1).fluxAnode = relChange(L(i).fluxAnode, L(i-1).fluxAnode);
    D(i-1).lineIntEmag = relChange(L(i).lineIntEmag, L(i-1).lineIntEmag);
    D(i-1).phiwDiff = relChange(L(i).phiwDiff, L(i-1).phiwDiff);
end
maxDelta = 0;
if numel(D) > 0
    maxDelta = max([D.fluxAnode, D.lineIntEmag, D.phiwDiff]);
end
isCoax = strcmp(lower(char(string(getfield2(opts, 'geometry', 'coax')))), 'coax');
devFinest = L(end).maxRelDevEr;

C = struct();
C.levels = L;
C.delta = D;
C.hRatio = [L(:).h_m].'/L(1).h_m;
C.map = finest;
C.gate = struct();
C.gate.convergenceMaxRelDelta = tolConv;
C.gate.maxRelDevEmagAwayOfAnode = tolDev;
C.gate.maxObservedRelDelta = maxDelta;
C.gate.maxObservedRelDevEmag = devFinest;
C.gate.convergenceApplied = true;
C.gate.convergencePassed = maxDelta <= tolConv;
C.gate.deviationApplied = isCoax;
C.gate.deviationPassed = ~isCoax || devFinest <= tolDev;
C.gate.rFarFromAnode_m = 2*finest.a_m;
C.passed = C.gate.convergencePassed && C.gate.deviationPassed;
C.notes = { ...
    '积分量判据对象: fluxAnode=∫r·E_r dz (阳极侧面通量/2π), lineIntEmag=∫|E|dr (径向路径), phiwDiff=φ_w(2a)-φ_w(b/2)。', ...
    '逐点 anodePeakEmag 不参与判据: 丝状阳极面 E~1/r 发散 (球壳阳极 1/r²), 且球-丝几何的丝端角点另有楔形边奇点, P1 元下该值随 h_min 收缩持续上移, 无网格无关极限。', ...
    'maxRelDevEr 只在 r≥2a 子域上取; geometry=coax 时它是求解器离散误差 (闭式解即精确解), geometry=sphereWire 时它是真实边值问题与理想同轴公式的物理差, 故只报告不判门禁。', ...
    '各级采样路径是同一组对数间隔半径 (与网格无关), 因此跨层级的差只反映解本身, 不混入采样点漂移。'};
end

% ==================== 局部实现 ====================

function r = relChange(fine, coarse)
% 相对变化以**更细**的那一级为分母 (收敛序列里它是更接近极限的值)。
if fine == 0
    r = abs(fine - coarse);
else
    r = abs(fine - coarse)/abs(fine);
end
end

function v = getfield2(s, nm, dflt)
if isfield(s, nm) && ~isempty(s.(nm)), v = s.(nm); else, v = dflt; end
end

function s = rmfield2(s, nm)
if isfield(s, nm), s = rmfield(s, nm); end
end
