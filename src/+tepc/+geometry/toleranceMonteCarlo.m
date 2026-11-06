function out = toleranceMonteCarlo(cfg, N, rs, varargin)
%TOLERANCEMONTECARLO 几何公差的蒙卡敏感度 (解析/轴对称快速通道), 随机流由调用方显式传入。
%
%   out = toleranceMonteCarlo(cfg, N, rs)
%   out = toleranceMonteCarlo(cfg, N, rs, 'Tolerance', T, 'Outputs', qnames)
%   out = toleranceMonteCarlo(cfg, N, rs, 'Channel','fem_axisymmetric', 'Expensive', true, ...
%                             'MaxFemSamples', 32)
%
% 输入
%   cfg  已装载的配置 (tepc.config.load 的产物或同构 struct)。
%   N    样本数 (>=1)。
%   rs   RandStream: **全部**随机数只从这一个流取。同 seed => 逐位可复现; 本函数不碰
%        rng/globalStream, 也不另建第二条流。tepc.config.resolve 内部为增益建的
%        RandStream('Threefry','Seed',1) 是固定种子流, 不消耗 rs, 不影响复现性。
%
% 选项 (Name-Value)
%   'Tolerance'      公差表, 默认 toleranceDefaults() (全部标 ASSUMED)。struct 数组或
%                    cell, 每项: name, dist ('normal'|'uniform'), mean/sd 或 lo/hi,
%                    units, status, note
%   'Outputs'        要评的解析量, 默认全部: V_m3, S_m2, lbar_gas_m, capacitance_F,
%                    gain_integral_V, G_mean, min_anode_cathode_gap_m
%   'Channel'        'analytic' (默认) | 'fem_axisymmetric' | 'fem_3d'
%   'Expensive'      false (默认)。算力纪律开关: 任何"每样本一次有限元"的路径都必须显式
%                    Expensive=true 才允许进入, 否则报错而不是悄悄变慢。
%   'MaxFemSamples'  FEM 通道最多解多少个样本, 默认 32; 其余样本该量记 NaN + 原因。
%   'SampleSolver'   调用方自带的每样本求解句柄 (function handle), 同样要求 Expensive=true。
%   'BudgetSeconds'  预算秒数, 默认 600。用前几个样本的实测耗时外推 N 样本总时长。
%   'AllowOverBudget' false (默认): 预估超预算时**在开跑前**报错, 不跑一半再死。
%   'FemHmaxOverB' / 'FemHgrad'  FEM 网格参数 (默认 1/25 与 1.2), 从几何推不写死绝对尺寸。
%
% 每个样本重算什么
%   V/S/lbar     闭式: 球按椭球 (Knud Thomsen 面积近似, 对球精确), 有限圆柱按椭圆截面
%                (Ramanujan II 周长, 对圆精确), lbar = 4V/S (凸体 + 各向同性直线场的
%                Cauchy 定理, 与 buildGeometry 同一定义)。名义点上与 resolve 逐量核对,
%                差超过 1e-9 直接报错 (两份几何公式分叉是可失败的, 不是装饰)。
%   解析电容      同心球壳 C = 4*pi*eps0*a*b/(b-a); 长同轴 C = 2*pi*eps0*L/ln(b/a)。
%                端部边缘效应未计; 偏心/球度下的电容没有可用闭式 (见下)。
%   增益积分      int_a^r0 E dr 走 tepc.detector.fieldModel (全项目唯一场实现), r0 取
%                resolve 的 R.r0_m (雪崩起点单一来源), G_mean 取 resolve 的 R.G_mean
%                (含 avalanche 的钳位) —— 本函数不复算增益公式, 不留第二份实现。
%   最小间隙      阳极到阴极的最小距离 (球度取最短半轴, 再减偏心量): 平行位移下是精确几何量。
%
% 未建模的格子 = NaN, 不是 0
%   偏心: 电容与增益在本通道未建模。能断言的只有"同心构型下 C(delta) 是 delta 的偶函数,
%     故一阶导精确为零"这一条对称性结论, 二阶项要场解 (FEM 通道)。球度同理。
%     敏感度表这些格子给 NaN + not_modeled_* 状态。给 0 会被下游读成"该公差不敏感"。
%
% 消费标注 (防止 0 被误读)
%   每个被扰动量标 consumed_by_transport / not_consumed_by_transport /
%   consumed_by_detector_field / in_config, 并把"输运链今天吃什么"逐条列在
%   out.transport_consumption。球度与偏心在配置里**没有对应字段** (发货几何严格球、严格
%   同心), 因此它们对输运量的影响属模型缺口, 而不是"测出来不敏感"。
%
% 错误标识符: tepc:uq:BadStream / ToleranceBadArgs / ToleranceBadOption / ToleranceBadN /
%   ToleranceBadTable / ToleranceUnknownOutput / ToleranceExpensiveNotConfirmed /
%   ToleranceChannelNotAvailable / ToleranceOverBudget / ToleranceChannelDivergence

%% ---------------- 0. 参数 ----------------
op = struct('Tolerance', [], 'Outputs', [], 'Channel', 'analytic', 'Expensive', false, ...
    'MaxFemSamples', 32, 'SampleSolver', [], 'BudgetSeconds', 600, ...
    'AllowOverBudget', false, 'FemHmaxOverB', 1/25, 'FemHgrad', 1.2);
if nargin < 3 || isempty(rs)
    error("tepc:uq:BadStream", "必须显式传入 RandStream: 同 seed 位精确可复现是这块的硬要求");
end
if ~isa(rs, 'RandStream')
    error("tepc:uq:BadStream", "rs 必须是 RandStream 对象 (实得 %s)", class(rs));
end
if mod(numel(varargin), 2) ~= 0
    error("tepc:uq:ToleranceBadArgs", "toleranceMonteCarlo 的选项必须成对给出 (名称, 值)");
end
for i = 1:2:numel(varargin)
    nm = char(string(varargin{i}));
    if ~isfield(op, nm)
        % 字面串相邻拼接 ("a" ..."b") 在参数位置不是合法拼接, 续行只在二元运算符与逗号
        % 之后成立; 可选名清单用 [] 显式拼接 (char 数组不支持 +)。
        valid = ['Tolerance Outputs Channel Expensive MaxFemSamples ' ...
            'SampleSolver BudgetSeconds AllowOverBudget FemHmaxOverB FemHgrad'];
        error("tepc:uq:ToleranceBadOption", "未知选项 %s (可用: %s)", nm, valid);
    end
    op.(nm) = varargin{i+1};
end
N = double(N);
if ~isscalar(N) || ~isfinite(N) || N < 1 || N ~= round(N)
    error("tepc:uq:ToleranceBadN", "N 必须是正整数样本数 (实得 %g)", N);
end
if isempty(op.Tolerance)
    T = toleranceDefaults();
else
    T = normTolerance(op.Tolerance);
end
d = numel(T);
qAll = defaultOutputs();
if isempty(op.Outputs)
    qNames = qAll;
else
    qNames = lower(string(op.Outputs));
    qNames = qNames(:);
    bad = ~ismember(qNames, qAll);
    if any(bad)
        error("tepc:uq:ToleranceUnknownOutput", "未知解析量 %s (可用: %s)", ...
            strjoin(qNames(bad), ', '), strjoin(qAll, ', '));
    end
end
nq = numel(qNames);
expensive = logical(op.Expensive);
chan = lower(char(string(op.Channel)));
if ~(strcmp(chan, 'analytic') || strcmp(chan, 'fem_axisymmetric') || strcmp(chan, 'fem_3d'))
    error("tepc:uq:ToleranceChannelNotAvailable", ...
        "Channel 只允许 analytic|fem_axisymmetric|fem_3d (实得 %s)", chan);
end
wantFem = ~strcmp(chan, 'analytic') || ~isempty(op.SampleSolver);
if wantFem && ~expensive
    error("tepc:uq:ToleranceExpensiveNotConfirmed", ...
        "每样本一次有限元求解必须先显式给 Expensive=true (算力纪律: 不静默接受昂贵通道)");
end
if strcmp(chan, 'fem_3d')
    % 3-D 逐样本求解在本机没有实测成本与精度依据, 交付口径只到 2-D 截面/轴对称:
    % 与其给一条"能跑但没人知道多慢多准"的路, 不如显式拒绝。
    error("tepc:uq:ToleranceChannelNotAvailable", ...
        "fem_3d 通道未提供: 本机没有 3-D 逐样本求解的实测成本与精度依据, 蒙卡只允许 2-D 截面通道");
end

%% ---------------- 1. 名义基准与通道一致性核对 ----------------
R0 = tepc.config.resolve(cfg);
b_m = double(R0.geom.R_m);
t_m = double(R0.geom.wallThickness_m);
a_m = double(R0.field.a);
hv_V = double(R0.field.hv_V);
gt = lower(string(R0.geom.type));
localGeomOk = gt == "sphere" || gt == "cylinder_finite";
H_m = NaN;
if gt == "cylinder_finite"
    H_m = double(cfg.geometry.cylinderLength_mm)*1e-3;      % mm -> m
end
kind = lower(string(R0.electrode.fieldKind));
Lan_m = 2*b_m;                        % 丝长: 球腔取 2R, 有限圆柱取腔长 (meshSpec 同一约定)
if gt == "cylinder_finite", Lan_m = H_m; end
eps0 = eps0Vacuum();

nom = struct();
nom.V_m3 = R0.geom.V_m3;
nom.S_m2 = R0.geom.S_m2;
nom.lbar_gas_m = R0.geom.lbar_gas_m;
nom.capacitance_F = capacitance(kind, a_m, b_m, Lan_m, eps0);
fm0 = tepc.detector.fieldModel(a_m, b_m, hv_V, char(kind));
nom.gain_integral_V = fm0.intE(a_m, R0.r0_m);
nom.G_mean = R0.G_mean;
nom.min_anode_cathode_gap_m = b_m - a_m;
nom.r0_m = R0.r0_m;
nom.fieldKind = char(kind);
nom.geometryType = char(gt);
nom.anodeLength_m = Lan_m;

identity = struct('max_rel', NaN);
if localGeomOk
    Ln = localGeom(gt, b_m, H_m, 0);
    identity.V_rel = abs(Ln.V - nom.V_m3)/abs(nom.V_m3);
    identity.S_rel = abs(Ln.S - nom.S_m2)/abs(nom.S_m2);
    identity.lbar_rel = abs(Ln.lbar - nom.lbar_gas_m)/abs(nom.lbar_gas_m);
    identity.max_rel = max([identity.V_rel identity.S_rel identity.lbar_rel]);
    if ~(identity.max_rel < 1e-9)
        error("tepc:uq:ToleranceChannelDivergence", ...
            ['解析通道与 buildGeometry 的名义值分叉: 最大相对差 %.3e (V/S/lbar 分别 ' ...
            '%.3e %.3e %.3e)。球度通道要求同一份几何定义, 先对齐公式再来跑蒙卡'], ...
            identity.max_rel, identity.V_rel, identity.S_rel, identity.lbar_rel);
    end
    identity.note = '名义点上本通道与 buildGeometry 的 V/S/lbar 相对差 <1e-9 (实测)';
else
    identity.note = 'geometry.type 非 sphere/cylinder_finite: V/S/lbar 直接取 resolve 值, 球度未建模';
end

%% ---------------- 2. 抽样 ----------------
U = tepc.uq.lhs(N, d, rs);
X = zeros(N, d);
for j = 1:d
    X(:, j) = drawVar(T(j), U(:, j));
end

%% ---------------- 3. 预算闸 (实测单样本耗时外推, 超预算就不开跑) ----------------
nWarm = min(N, 3);
tWarm = zeros(1, nWarm);
for s = 1:nWarm
    tw = tic;
    evalSample(cfg, T, X(s, :), qNames, kind, eps0, b_m, t_m, a_m, hv_V, H_m, gt, ...
        localGeomOk, Lan_m);
    tWarm(s) = toc(tw);
end
perSample = max(median(tWarm(:)), eps);
budget = double(op.BudgetSeconds);
if ~isscalar(budget) || ~isfinite(budget) || ~(budget > 0)
    error("tepc:uq:ToleranceBadOption", "BudgetSeconds 必须是正有限标量");
end
predAnalytic = N*perSample;
nFem = 0;
femPer = 0;
femExtra = 0;
femPerMeasured = false;
if wantFem
    nFem = min(max(1, round(double(op.MaxFemSamples))), N);
    if isempty(op.SampleSolver)
        femPer = femProbe(a_m, b_m, hv_V, R0.r0_m, eps0, op);
        femPerMeasured = femPer > 0;
    end
    femExtra = nFem*femPer;
end
predTotal = predAnalytic + femExtra;
if ~logical(op.AllowOverBudget) && predTotal > budget
    error("tepc:uq:ToleranceOverBudget", ...
        ['预估 %.1f s 超预算 %.1f s: 解析通道 %.4f s/样本 x %d, FEM 额外 %.3f s/样本 x %d。' ...
        '确认要跑请加大 BudgetSeconds 且 AllowOverBudget=true'], ...
        predTotal, budget, perSample, N, femPer, nFem);
end

%% ---------------- 4. 主循环 ----------------
Q = nan(N, nq);
qStatus = repmat({''}, N, 1);
failed = {};
for s = 1:N
    try
        [vals, st] = evalSample(cfg, T, X(s, :), qNames, kind, eps0, b_m, t_m, a_m, ...
            hv_V, H_m, gt, localGeomOk, Lan_m);
        Q(s, :) = vals;
        qStatus{s} = st;
    catch e
        failed{end+1} = struct('sample', s, 'id', e.identifier, 'msg', e.message); %#ok<AGROW>
    end
end

%% ---------------- 5. FEM 通道 (只有显式 Expensive=true 才走到这里) ----------------
% 逐样本用**该样本扰动后的半径**建模, 不是名义几何; 未解的样本该量保持 NaN。
femQ = nan(N, 3);
femStatus = repmat({''}, N, 1);
femSel = zeros(0, 1);
if wantFem && nFem > 0
    if isempty(op.SampleSolver)
        femSel = unique(round(linspace(1, N, nFem)));
    else
        femSel = (1:min(nFem, N)).';
    end
    for t = 1:numel(femSel)
        s = femSel(t);
        [aF, bF] = perturbedRadii(T, X(s, :), a_m, b_m);
        if isempty(op.SampleSolver)
            [fc, fg, frel, fstat] = femSample(aF, bF, hv_V, R0.r0_m, eps0, op);
        else
            [fc, fg, frel, fstat] = op.SampleSolver(X(s, :));
        end
        femQ(s, :) = [fc fg frel];
        femStatus{s} = fstat;
    end
end

%% ---------------- 6. 敏感度表 ----------------
sens = repmat(emptySensRow(), 1, 0);
for j = 1:d
    for k = 1:nq
        row = emptySensRow();
        row.variable = T(j).name;
        row.units_in = T(j).units;
        row.dist = T(j).dist;
        row.sd_input = sdOf(T(j));
        row.quantity = char(qNames(k));
        y = Q(:, k);
        ok = isfinite(y);
        row.n_evaluated = nnz(ok);
        row.mean = mean(y, 'omitnan');
        row.sd = std(y, 'omitnan');
        row.ci95 = ci95(y);
        if isfinite(row.mean) && abs(row.mean) > 0
            row.cv_rel = row.sd/abs(row.mean);
        else
            row.cv_rel = NaN;
        end
        row.spearman = spearmanCol(X(ok, j), y(ok));
        [dv, dstatus] = finiteDiff(cfg, T, j, k, qNames, kind, eps0, b_m, t_m, a_m, hv_V, ...
            H_m, gt, localGeomOk, Lan_m, row.sd_input);
        row.derivative_at_nominal = dv;
        row.first_order_sd_contribution = abs(dv)*row.sd_input;
        row.modeled = isfinite(dv) && nnz(ok) > 0;
        row.status = sprintf('%s (%s -> %s, dist %s)', dstatus, T(j).name, ...
            row.quantity, T(j).dist);
        row.consumed_by_transport = consumptionOf(T(j).name, 'transport');
        row.not_consumed_by_transport = ~row.consumed_by_transport;
        row.consumed_by_detector_field = consumptionOf(T(j).name, 'field');
        row.in_config = inConfigOf(T(j).name);
        row.reading_guard = guardText(row);
        sens(end+1) = row; %#ok<AGROW,SAGROW>
    end
end
if wantFem && nFem > 0
    sens = appendFemRows(sens, T, femQ, femStatus, X, femSel);
end

%% ---------------- 7. 组装 ----------------
out = struct();
out.n_samples = N;
out.n_ok = N - numel(failed);
out.n_failed = numel(failed);
out.failed = failed;
out.variables = {T.name};
out.tolerance = T;
out.samples = X;
out.outputs = Q;
out.output_status = qStatus;
out.output_names = cellstr(qNames);
out.nominal = nom;
out.identity_check = identity;
out.channel = chan;
out.expensive = expensive;
out.fem = struct('requested', wantFem, 'n_solved', nnz(isfinite(femQ(:,1))), ...
    'max_samples', nFem, 'rows', femSel, 'solver', solverName(op), ...
    'cap_rel_err_vs_closed_form', mean(femQ(:,3), 'omitnan'), ...
    'status', femSummary(femStatus));
out.channel_note = channelNote(chan, wantFem, gt);
out.cost = struct('per_sample_analytic_s', perSample, 'n_warm_up', nWarm, ...
    'fem_per_sample_s', femPer, 'fem_per_sample_measured', femPerMeasured, ...
    'n_fem_probed', nFem, 'predicted_total_s', predTotal, ...
    'budget_s', budget, 'over_budget', predTotal > budget, ...
    'allow_over_budget', logical(op.AllowOverBudget));
out.sensitivity = sens;
out.by_consumption = groupSens(sens);
out.summary = summaryQuantities(qNames, Q);
out.transport_consumption = transportConsumption();
out.random_source = struct('type', rs.Type, 'seed', rs.Seed, ...
    'sampler', 'tepc.uq.lhs + tepc.uq.norminv');
out.reproducibility = ['全部随机数只取自传入的 RandStream, 因此同一 (类型, seed) 的流输出逐位' ...
    '相同; 本函数不调用 rng 也不建第二条流。增益链内部的 RandStream(Threefry,Seed=1) 是' ...
    '固定种子流, 不从 rs 取数, 因此不消耗流位。'];
out.notes = { ...
    '默认解析/轴对称通道: 每样本只做闭式与一次 resolve, 无网格无 FEM (算力纪律的默认档)', ...
    '未建模的格子给 NaN + 原因, 不给 0: 0 会被下游读成该量不敏感', ...
    '球度与偏心在配置里没有对应字段 (发货几何严格球、严格同心), 对输运量属模型缺口', ...
    sprintf('电容闭式 (%s 拓扑): 端部边缘效应未计入', char(kind)), ...
    sprintf('丝长取 %.6e m (球腔 2R / 有限圆柱取 cylinderLength_mm, ASSUMED 约定)', Lan_m), ...
    sprintf('预算闸实测: 解析通道 %.4f s/样本, 预估总时长 %.1f s (预算 %.0f s)', ...
    perSample, predTotal, budget)};
end

%% ==================== 局部函数 ====================

function e = eps0Vacuum()
% 真空介电常数 [F/m], CODATA 2018。docs/constants.json 的作用域声明只登记散落的
% ASSUMED/经验常数 (定义常数与 CODATA 值刻意不进表), 所以这里是本地定义而不是查表。
e = 8.8541878128e-12;
end

function v = solverName(op)
if isempty(op.SampleSolver)
    v = 'builtin_fem_axisymmetric_2d';
else
    v = 'caller_supplied_sample_solver';
end
end

function [a, b] = perturbedRadii(T, x, a0, b0)
% FEM 通道用的该样本半径 (与 evalSample 同一套映射, 不留第二份换算)。
a = a0*(1 + valueOf(T, x, 'anode_radius_rel'));
b = b0*(1 + valueOf(T, x, 'gas_radius_rel'));
end

function T = toleranceDefaults()
% 默认公差表: 全部 ASSUMED —— 没有图纸/工艺单之前这些只是机加常识量级, 不是本装置的实测
% 公差。正式不确定度评定必须由调用方传 'Tolerance' 覆盖。
T = [mkTol('wall_thickness_rel', 'normal', 0, 0.01, NaN, NaN, '-', 'ASSUMED', ...
        '壁厚相对偏差 (进 csdaTransport/wallEscape 的射程与剩余能量劈分)'), ...
     mkTol('gas_radius_rel', 'normal', 0, 0.005, NaN, NaN, '-', 'ASSUMED', ...
        '气腔半径相对偏差 (进 V/S/lbar/弦长与场)'), ...
     mkTol('anode_radius_rel', 'normal', 0, 0.02, NaN, NaN, '-', 'ASSUMED', ...
        '阳极半径相对偏差 (进 fieldModel/增益, 不进输运几何)'), ...
     mkTol('sphericity_rel', 'normal', 0, 0.002, NaN, NaN, '-', 'ASSUMED', ...
        '球度: 半轴 (1+s, 1-s/2, 1-s/2) 的单自由度模型, 平均半径不变 => 体积二阶变化'), ...
     mkTol('anode_eccentricity_m', 'uniform', NaN, NaN, 0, 25e-6, 'm', 'ASSUMED', ...
        '阳极中心相对腔心的偏心量 (配置里无此字段, 只影响本地几何量与需要场解的量)')];
end

function t = mkTol(name, dist, mu, sd, lo, hi, units, status, note)
t = struct('name', name, 'dist', dist, 'mean', mu, 'sd', sd, 'lo', lo, 'hi', hi, ...
    'units', units, 'status', status, 'note', note);
end

function T = normTolerance(in)
% 接受 struct 数组或 cell of struct; 补齐缺字段并校验分布参数。
if iscell(in)
    T = repmat(freshTol(), 1, numel(in));
    for k = 1:numel(in)
        T(k) = fillTol(in{k});
    end
else
    T = repmat(freshTol(), 1, numel(in));
    for k = 1:numel(in)
        T(k) = fillTol(in(k));
    end
end
if isempty(T)
    error("tepc:uq:ToleranceBadTable", "公差表为空: 没有可抽样的量");
end
end

function t = freshTol()
t = struct('name', '', 'dist', 'normal', 'mean', 0, 'sd', NaN, 'lo', NaN, 'hi', NaN, ...
    'units', '-', 'status', 'ASSUMED', 'note', '');
end

function t = fillTol(s)
t = freshTol();
if ~isstruct(s) || ~isfield(s, 'name') || isempty(s.name)
    error("tepc:uq:ToleranceBadTable", "公差表每项都必须有 name 字段");
end
t.name = char(string(s.name));
t.dist = lower(charOr(s, 'dist', 'normal'));
t.mean = doubleOr(s, 'mean', 0);
t.sd = doubleOr(s, 'sd', NaN);
t.lo = doubleOr(s, 'lo', NaN);
t.hi = doubleOr(s, 'hi', NaN);
t.units = charOr(s, 'units', '-');
t.status = charOr(s, 'status', 'ASSUMED');
t.note = charOr(s, 'note', '');
switch t.dist
    case 'normal'
        if ~(t.sd > 0) || ~isfinite(t.mean)
            error("tepc:uq:ToleranceBadTable", "%s: normal 分布需要有限 mean 与正的 sd", t.name);
        end
    case 'uniform'
        if ~(isfinite(t.lo) && isfinite(t.hi) && t.hi > t.lo)
            error("tepc:uq:ToleranceBadTable", "%s: uniform 分布需要有限的 lo < hi", t.name);
        end
    otherwise
        error("tepc:uq:ToleranceBadTable", "%s: dist 只允许 normal 或 uniform (实得 %s)", ...
            t.name, t.dist);
end
end

function v = charOr(s, nm, d)
if isfield(s, nm) && ~isempty(s.(nm)), v = char(string(s.(nm))); else, v = d; end
end

function v = doubleOr(s, nm, d)
if isfield(s, nm) && ~isempty(s.(nm)), v = double(s.(nm)); else, v = d; end
end

function q = defaultOutputs()
q = ["V_m3"; "S_m2"; "lbar_gas_m"; "capacitance_F"; "gain_integral_V"; "G_mean"; ...
     "min_anode_cathode_gap_m"];
end

function x = drawVar(t, u)
switch t.dist
    case 'normal',  x = t.mean + t.sd*tepc.uq.norminv(u);
    case 'uniform', x = t.lo + u*(t.hi - t.lo);
    otherwise,      x = NaN;
end
end

function s = sdOf(t)
if strcmp(t.dist, 'normal')
    s = t.sd;
else
    s = (t.hi - t.lo)/sqrt(12);
end
end

function c = centerOf(t)
if strcmp(t.dist, 'normal')
    c = t.mean;
else
    c = (t.lo + t.hi)/2;
end
end

function x = nominalVector(T)
x = zeros(1, numel(T));
for j = 1:numel(T)
    x(j) = centerOf(T(j));
end
end

function [vals, status] = evalSample(cfg, T, x, qNames, kind, eps0, b0, t0, a0, hv, ...
    H, gt, localGeomOk, Lan)
% 单样本: 抽到的公差量 -> 解析量。x 是 1xd 抽样值 (与 T 同序)。
nv = numel(qNames);
vals = nan(1, nv);
st = strings(1, nv);
w = valueOf(T, x, 'wall_thickness_rel');
g = valueOf(T, x, 'gas_radius_rel');
an = valueOf(T, x, 'anode_radius_rel');
sp = valueOf(T, x, 'sphericity_rel');
ec = valueOf(T, x, 'anode_eccentricity_m');
b = b0*(1 + g);
t = t0*(1 + w);
a = a0*(1 + an);
if ~(isfinite(b) && isfinite(a) && isfinite(t) && b > a && a > 0 && t > 0)
    status = 'rejected_out_of_domain';
    return
end
% 有 cfg 字段的量走 resolve (场/增益/雪崩起点只有一份实现); 球度与偏心走本地闭式。
cfgk = cfg;
cfgk.geometry.gasRadius_mm = b*1e3;
cfgk.geometry.wallThickness_mm = t*1e3;
cfgk.geometry.anodeRadius_um = a*1e6;
Rk = tepc.config.resolve(cfgk);
if localGeomOk
    L = localGeom(gt, b, H, sp);
    rmin = L.rmin;
    Vv = L.V;
    Sv = L.S;
    lb = L.lbar;
else
    Vv = Rk.geom.V_m3;
    Sv = Rk.geom.S_m2;
    lb = Rk.geom.lbar_gas_m;
    rmin = b;
end
C = capacitance(kind, a, b, Lan, eps0);
fm = tepc.detector.fieldModel(a, b, hv, char(kind));
gi = fm.intE(a, Rk.r0_m);
gap = rmin - a - ec;
for k = 1:nv
    switch qNames(k)
        case "V_m3",                    vals(k) = Vv;   st(k) = "closed_form_local";
        case "S_m2",                    vals(k) = Sv;   st(k) = "closed_form_local";
        case "lbar_gas_m",              vals(k) = lb;   st(k) = "closed_form_4V_over_S";
        case "capacitance_F",           vals(k) = C;    st(k) = "concentric_closed_form";
        case "gain_integral_V",         vals(k) = gi;   st(k) = "fieldModel_intE_a_r0";
        case "G_mean",                  vals(k) = Rk.G_mean; st(k) = "resolve_avalanche";
        case "min_anode_cathode_gap_m", vals(k) = gap;  st(k) = "closed_form_offset";
        otherwise
            vals(k) = NaN;
            st(k) = "unknown_output";
    end
end
status = char(strjoin(st, ' | '));
end

function v = valueOf(T, x, nm)
% 未出现在公差表里的旋钮按名义值 (相对量 0, 偏心 0) —— 不是 NaN: 没抽样不等于不知道。
v = 0;
j = find(strcmp({T.name}, nm), 1);
if ~isempty(j) && isfinite(x(j))
    v = x(j);
end
end

function L = localGeom(gt, b, H, s)
% 球度模型: 半轴 (b*(1+s), b*(1-s/2), b*(1-s/2)) —— 平均半径不变, 体积按二阶变化
% (V/V0 = (1+s)(1-s/2)^2 = 1 - 3s^2/4 + s^3/4)。面积用 Knud Thomsen 近似 (p = 1.6075,
% 对球精确); 有限圆柱按椭圆截面, 周长用 Ramanujan II (对圆精确)。这两个近似都是公差
% 评定用的闭式, 不进审计链 (审计链的 V/S/lbar 仍由 buildGeometry/meshSpec 给)。
if gt == "sphere"
    ax = b*[1 + s, 1 - s/2, 1 - s/2];
    L.V = 4/3*pi*ax(1)*ax(2)*ax(3);
    p = 1.6075;
    L.S = 4*pi*((ax(1)^p*ax(2)^p + ax(1)^p*ax(3)^p + ax(2)^p*ax(3)^p)/3)^(1/p);
    L.rmin = min(ax);
else
    ax1 = b*(1 + s);
    ax2 = b*(1 - s/2);
    L.V = pi*ax1*ax2*H;
    per = pi*(3*(ax1 + ax2) - sqrt((3*ax1 + ax2)*(ax1 + 3*ax2)));
    L.S = 2*per*H + 2*pi*ax1*ax2;
    L.rmin = min(ax1, ax2);
end
L.lbar = 4*L.V/L.S;
end

function C = capacitance(kind, a, b, L, eps0)
% 同心闭式电容: 球壳 4*pi*eps0*a*b/(b-a); 长同轴 2*pi*eps0*L/ln(b/a) (无端部修正)。
if kind == "sphere"
    C = 4*pi*eps0*a*b/(b - a);
else
    C = 2*pi*eps0*L/log(b/a);
end
end

function [dv, status] = finiteDiff(cfg, T, j, k, qNames, kind, eps0, b0, t0, a0, hv, H, ...
    gt, localGeomOk, Lan, h)
% 名义点中心差分灵敏度。步长取该量的抽样标准差 (量纲一致, 不另设魔数)。
% 本通道覆盖不到的格子给 NaN + 原因, 绝不给 0。
dv = NaN;
nm = T(j).name;
q = qNames(k);
status = coveredStatus(nm, q, localGeomOk);
if ~isempty(status)
    return
end
if ~isfinite(h) || h <= 0
    status = 'no_step_size';
    return
end
x1 = nominalVector(T);
x2 = nominalVector(T);
x1(j) = centerOf(T(j)) + h;
x2(j) = centerOf(T(j)) - h;
[v1, ~] = evalSample(cfg, T, x1, qNames, kind, eps0, b0, t0, a0, hv, H, gt, localGeomOk, Lan);
[v2, ~] = evalSample(cfg, T, x2, qNames, kind, eps0, b0, t0, a0, hv, H, gt, localGeomOk, Lan);
if ~isfinite(v1(k)) || ~isfinite(v2(k))
    status = 'not_evaluated_nan_sample';
    return
end
dv = (v1(k) - v2(k))/(2*h);
status = 'central_difference_at_nominal';
end

function s = coveredStatus(nm, q, localGeomOk)
% 解析通道能不能对 (变量, 量) 这一格给数。给不出的每一格都写清为什么, 而不是留 0。
s = '';
needsField = q == "capacitance_F" || q == "gain_integral_V" || q == "G_mean";
if strcmp(nm, 'anode_eccentricity_m') && needsField
    s = 'not_modeled_first_order_zero_by_symmetry_need_field_solution';
elseif strcmp(nm, 'sphericity_rel') && needsField
    s = 'not_modeled_sphericity_needs_field_solution';
elseif ~localGeomOk && any(q == ["V_m3", "S_m2", "lbar_gas_m"]) ...
        && any(strcmp(nm, {'sphericity_rel', 'anode_eccentricity_m'}))
    s = 'not_modeled_geometry_type';
end
end

function r = emptySensRow()
r = struct('variable', '', 'units_in', '-', 'dist', '', 'sd_input', NaN, 'quantity', '', ...
    'n_evaluated', 0, 'mean', NaN, 'sd', NaN, 'ci95', [NaN NaN], 'cv_rel', NaN, ...
    'spearman', NaN, 'derivative_at_nominal', NaN, 'first_order_sd_contribution', NaN, ...
    'modeled', false, 'status', '', 'consumed_by_transport', false, ...
    'not_consumed_by_transport', true, 'consumed_by_detector_field', false, ...
    'in_config', true, 'reading_guard', '');
end

function ci = ci95(y)
y = sort(y(isfinite(y)));
n = numel(y);
if n < 2
    ci = [NaN NaN];
    return
end
i1 = max(1, min(n, floor(0.025*n) + 1));
i2 = max(1, min(n, ceil(0.975*n)));
ci = [y(i1), y(i2)];
end

function r = spearmanCol(a, b)
a = a(:);
b = b(:);
n = min(numel(a), numel(b));
if n < 3
    r = NaN;
    return
end
aa = a(1:n);
bb = b(1:n);
if ~all(isfinite(aa)) || ~all(isfinite(bb))
    r = NaN;
    return
end
C = corrcoef(rankTies(aa), rankTies(bb));
r = C(1, 2);
end

function rk = rankTies(x)
% 平均秩 (ties 必须取平均, 否则离散分布的秩相关有偏)。
[s, i] = sort(x, 'ascend');
n = numel(s);
rk = zeros(n, 1);
j = 1;
while j <= n
    k = j;
    while k < n && s(k+1) == s(j)
        k = k + 1;
    end
    rk(i(j:k)) = (j + k)/2;
    j = k + 1;
end
end

function sens = appendFemRows(sens, T, femQ, femStatus, X, femSel)
% FEM 通道的行只对真解过的样本统计, n_evaluated 明示覆盖度 (不拿 0 冒充"算了且没影响")。
names = {'fem_capacitance_per_length_F_per_m', 'fem_gain_integral_V', ...
    'fem_cap_rel_err_vs_closed_form'};
for c = 1:3
    for j = 1:numel(T)
        row = emptySensRow();
        row.variable = T(j).name;
        row.units_in = T(j).units;
        row.dist = T(j).dist;
        row.sd_input = sdOf(T(j));
        row.quantity = names{c};
        row.n_evaluated = nnz(isfinite(femQ(:, c)));
        row.mean = mean(femQ(:, c), 'omitnan');
        row.sd = std(femQ(:, c), 'omitnan');
        if isfinite(row.mean) && abs(row.mean) > 0
            row.cv_rel = row.sd/abs(row.mean);
        end
        row.spearman = spearmanCol(X(femSel, j), femQ(femSel, c));
        row.modeled = row.n_evaluated > 1;
        row.status = sprintf('fem_axisymmetric_2d, %d of %d rows solved', ...
            row.n_evaluated, numel(femStatus));
        row.consumed_by_transport = consumptionOf(T(j).name, 'transport');
        row.not_consumed_by_transport = ~row.consumed_by_transport;
        row.consumed_by_detector_field = consumptionOf(T(j).name, 'field');
        row.in_config = inConfigOf(T(j).name);
        row.reading_guard = guardText(row);
        sens(end+1) = row; %#ok<AGROW,SAGROW>
    end
end
end

function tf = consumptionOf(nm, what)
% 现输运链吃哪些几何量 (逐条按 meshSpec 的 transport_mode 语义回查):
%   gas radius   -> V/S/lbar/弦长 (enter_mc)
%   wall thick   -> csdaTransport/wallEscape 的射程与剩余能量劈分 (energy_loss_table)
%   anode radius -> 只进 fieldModel/avalanche (探测器层), 不进输运
%   sphericity / eccentricity -> 配置里没有字段, 哪儿都不进
switch lower(nm)
    case 'gas_radius_rel',      tf = strcmp(what, 'transport');
    case 'wall_thickness_rel',  tf = strcmp(what, 'transport');
    case 'anode_radius_rel',    tf = strcmp(what, 'field');
    otherwise,                  tf = false;
end
end

function tf = inConfigOf(nm)
tf = ~any(strcmp(nm, {'sphericity_rel', 'anode_eccentricity_m'}));
end

function g = guardText(r)
if r.consumed_by_transport
    g = '本行进输运链: 敏感度非零即真实影响输出谱。';
elseif r.consumed_by_detector_field
    g = '本行不进输运链但进场与增益: 输运侧的 0 只说明它不在输运几何里, 灵敏度看探测器链。';
elseif ~r.in_config
    g = ['配置里没有这个字段 (发货几何严格球、严格同心): 本行是模型缺口, ' ...
        '不得读成该公差已证不敏感'];
elseif ~r.modeled
    g = '本通道未建模: 值为 NaN 而不是 0, 需要场解 (FEM 通道) 才能给符号与量级';
else
    g = '已建模, 但输运链不消费它';
end
end

function st = femSummary(femStatus)
c = femStatus(~cellfun('isempty', femStatus));
if isempty(c)
    st = 'not_requested';
else
    st = strjoin(unique(c), ' | ');
end
end

function grp = groupSens(sens)
% 按"输运链是否消费 / 是否建模 / 是否在配置里"分栏。0 与 NaN 分开摆, 防止混读。
keys = {'consumed_by_transport', 'not_consumed_by_transport', 'not_modeled', 'not_in_config'};
grp = struct();
for g = 1:numel(keys)
    kk = keys{g};
    switch kk
        case 'consumed_by_transport',      sel = [sens.consumed_by_transport];
        case 'not_consumed_by_transport',  sel = [sens.not_consumed_by_transport];
        case 'not_modeled',                sel = ~[sens.modeled];
        otherwise,                         sel = ~[sens.in_config];
    end
    grp.(kk).variables = unique({sens(sel).variable});
    grp.(kk).n_rows = nnz(sel);
    grp.(kk).n_nan_cells = sum(~[sens(sel).modeled]);
end
grp.not_consumed_by_transport.warning = ['本栏的 0 或 NaN 只说明输运链不消费该量, 不能读成' ...
    '"该公差不重要": 阳极半径走场与增益, 球度与偏心是模型缺口'];
end

function s = summaryQuantities(qNames, Q)
s = repmat(struct('quantity', '', 'mean', NaN, 'sd', NaN, 'cv_rel', NaN, 'min', NaN, ...
    'max', NaN, 'n_evaluated', 0), 1, numel(qNames));
for k = 1:numel(qNames)
    y = Q(:, k);
    s(k).quantity = char(qNames(k));
    s(k).mean = mean(y, 'omitnan');
    s(k).sd = std(y, 'omitnan');
    if isfinite(s(k).mean) && abs(s(k).mean) > 0
        s(k).cv_rel = s(k).sd/abs(s(k).mean);
    end
    if any(isfinite(y))
        s(k).min = min(y(:));
        s(k).max = max(y(:));
    end
    s(k).n_evaluated = nnz(isfinite(y));
end
end

function t = transportConsumption()
% "输运链今天到底吃什么"逐条列出: 报告可直接引用, 也解释为什么某些格子的敏感度是 0/NaN。
t = struct();
t.consumed_entities = { ...
    'gas_cavity: R_m/V_m3/S_m2/lbar_gas_m 进 sampleChord 与 csdaTransport', ...
    'wall: 壁厚与 rho_wall 进 csdaTransport/wallEscape 的射程与能量劈分', ...
    'anode: 半径只进 fieldModel 与 avalanche, 不进输运几何'};
t.not_consumed = { ...
    'world_envelope', 'source_cone', 'equivalent_site_realized', ...
    'equivalent_site_requested', 'cathode (与气腔共面的同一张皮)'};
t.tolerances_without_config_field = {'sphericity_rel', 'anode_eccentricity_m'};
t.note = ['发货几何模型是严格球 (或严格同轴圆柱) 且严格同心: 球度与偏心在 cfg 里没有字段, ' ...
    '因此它们对输运量没有任何通路 —— 敏感度必须写 not_modeled 而不是 0。'];
end

function n = channelNote(chan, wantFem, gt)
% 用 sprintf 而不是 [] 里的字符并置: 并置只在矩阵上下文成立, 写成 sprintf 后这条
% 消息的每个片段都是独立完整的字符串, 不依赖上下文规则。
if ~wantFem
    n = ['本次通道 = analytic (闭式 + 一次 resolve/样本), Expensive 未开: 任何每样本 FEM ' ...
        '路径都在参数校验处被拒, 不进入主循环。'];
else
    n = sprintf(['本次通道 = fem_axisymmetric (二维截面 general-form 静电, 已显式 ' ...
        'Expensive=true), 覆盖样本数受 MaxFemSamples 限制, 未解的样本该量记 NaN; 三维通道' ...
        '未提供。注意几何类型 %s 的球壳场在二维截面上不是同一个边值问题, 该通道的电容只对' ...
        '同轴圆柱拓扑有意义。'], char(gt));
end
end

%% ---------------- 有限元通道 (只有显式 Expensive=true 才会走到这里) ----------------

function per = femProbe(a, b, hv, r0, eps0, op)
% 用一次名义求解实测二维通道的单样本耗时 (预算外推用), 同时兼作通道自检。
if ~license('test', 'PDE_Toolbox')
    per = 0;
    return
end
tw = tic;
[~, ~, ~, st] = femSample(a, b, hv, r0, eps0, op);
per = toc(tw);
if startsWith(string(st), "not_available")
    per = 0;
end
end

function [capPerLen, gainInt, capRelErr, status] = femSample(a, b, hv, r0, eps0, op)
% 2-D 截面 general-form 静电求解 (createpde + decsg 两圆): 给单位长度电容 (能量法) 与
% 增益积分 (电位差, 静电场下与路径无关)。整段 try/catch: 任一环节不可用就如实标状态,
% 绝不返回 0 冒充"算过了"。
capPerLen = NaN;
gainInt = NaN;
capRelErr = NaN;
status = '';
if ~license('test', 'PDE_Toolbox')
    status = 'not_available_no_pde_license';
    return
end
try
    gm = decsg([1 1; 0 0; 0 0; b a]);           % 外圆 = 阴极, 内圆 = 内边界 (阳极)
    m = createpde();
    geometryFromEdges(m, gm);
    m.specifyCoefficients('m', 0, 'd', 0, 'c', 1, 'a', 0, 'f', 0);
    m.applyBoundaryCondition('dirichlet', 'Edge', 1:4, 'u', 0);
    m.applyBoundaryCondition('dirichlet', 'Edge', 5:8, 'u', hv, 'InternalBC', true);
    m.generateMesh('Hmax', double(op.FemHmaxOverB)*b, 'Hmin', a, 'Hgrad', op.FemHgrad);
    res = m.solvepde();
    u = res.NodalSolution(:);
    gx = res.GradientSolution(1, :);
    gy = res.GradientSolution(2, :);
    Mesh = m.Mesh;
    el = Mesh.Elements;
    nd = Mesh.Nodes;
    x1 = nd(1, el(2,:));
    y1 = nd(2, el(2,:));
    x2 = nd(1, el(3,:));
    y2 = nd(2, el(3,:));
    x3 = nd(1, el(4,:));
    y3 = nd(2, el(4,:));
    area = 0.5*abs(x1*(y2 - y3) + x2*(y3 - y1) + x3*(y1 - y2));
    g2 = 0.5*((gx(el(2,:)).^2 + gy(el(2,:)).^2) + (gx(el(3,:)).^2 + gy(el(3,:)).^2) + ...
              (gx(el(4,:)).^2 + gy(el(4,:)).^2));
    W = sum(g2.*area);                          % int |grad u|^2 dA (二维, 单位长度)
    capPerLen = eps0*W/(hv^2);
    [ur0, howq] = potentialAt(res, Mesh, u, r0, 0);
    gainInt = hv - ur0;                         % u(a) = hv, u(r0) = ur0
    capRelErr = capPerLen/(2*pi*eps0/log(b/a)) - 1;
    status = sprintf('fem_solved_energy_method_r0_query_%s_cap_rel_err_%.2e', ...
        howq, capRelErr);
catch e
    status = sprintf('fem_failed_%s', e.identifier);
end
end

function [uu, how] = potentialAt(res, Mesh, u, xq, yq)
% 先试 res.interpolate; 不可用就退回最近节点 (误差量级 O(Hmax), 已在 status 里注明用的哪种)。
uu = NaN;
how = 'nearest_node';
try
    ir = res.interpolate(xq, yq);
    if isstruct(ir) && isfield(ir, 'NodalSolution') && ~isempty(ir.NodalSolution)
        uu = ir.NodalSolution(1);
        how = 'interpolate';
        return
    end
catch
end
d2 = (Mesh.Nodes(1,:) - xq).^2 + (Mesh.Nodes(2,:) - yq).^2;
[~, k] = min(d2);
uu = u(k);
end
