function out = convergence(cfg, varargin)
%CONVERGENCE LHS 抽样数收敛阶梯 + 几何理想化的模型形式项 (纯 MATLAB, 不依赖外部输运)。
%   out = tepc.uq.convergence(cfg)                     用默认阶梯 [8 16 32 64]
%   out = tepc.uq.convergence(cfg, 'Samples', [8 16 32 64 128 256 512], ...
%                             'NEvPerSample', 300, 'Seed', 1234)
%
% 两块内容各自独立:
%   1) ladder: 逐级重跑 tepc.uq.propagateMC (同一 Seed 起点)。记录两件事:
%        u_yF_rel(N)  = sd/|mean| 是变异系数, 与 N **无关** (相邻比参照 1);
%        se_yF_rel(N) = sd/(sqrt(N)*|mean|) 是均值标准误的相对形式, 才服从 1/sqrt(N)
%                       律 (相邻比参照 sqrt(N_prev/N))。
%      拿 CV 去核对 sqrt(N_prev/N) 是概念错误: 每翻一倍必然"偏离" 0.707, 阶梯永远报异常。
%      比值只作方向性核对: 标准差自身的相对抽样噪声约 1/sqrt(2(N-1)) (正态母体, 大 n
%      才成立, N=8 一级就有 ~27%), 故 within_slack 取两级噪声独立合成的 2 倍作容差。
%      可比性说明: 每级同一 Seed 且逐样本物理子流固定 => 同分布可比; 但 LHS 分层是
%      randperm(N)/N, 大 N 的层集合不包含小 N 的层 => 这不是嵌套的公共随机数配对。
%   2) model_form: 把球腔换成"等体积 + 等径高 (H=2R)"的圆柱腔时的平均弦长之比。
%      凸体各向同性弦长的 Cauchy 定理 lbar = 4V/S 给闭式:
%          球   lbar = 4R/3
%          等径高圆柱 V=2πr^3, S=6πr^2 => lbar = 4r/3, 等体积 r = R*(2/3)^(1/3)
%      于是比值恰为 (2/3)^(1/3) = 0.873580... (相对差 12.64%)。
%      **这是弦长口径的模型形式差, 不是 y_F 的模型形式差**: 把 12.6% 直接当作
%      y_F 的模型形式项需要逐事件输运重跑, 本函数不做那步外推。
%
% 出参:
%   out.ladder        表: N, yF_mean, u_yF_rel (CV), se_yF_rel (均值标准误),
%                     u_level_ratio (CV 相邻比, 参照 1), expected_ratio/observed_ratio
%                     (对 se 而言, 参照 sqrt(N_prev/N)), noise_ref, within_slack
%   out.model_form    struct: lbar_sphere_m / lbar_cylinder_m / ratio / rel_gap /
%                     closed_form_ratio / basis (说明它是什么、不是什么)
%   out.total_samples 阶梯消耗的 LHS 样本总数 (成本护栏用)
%
% 错误标识符:
%   tepc:uq:BadSamples   Samples 不是递增正整数向量
%   tepc:uq:TooExpensive 阶梯成本超过 CostCap

args = struct('Samples', [8 16 32 64], 'NEvPerSample', 150, 'Seed', 1234, ...
    'CostCap', 4096);
if mod(numel(varargin), 2) ~= 0
    error("tepc:uq:Args", "Name-Value 参数必须成对");
end
for i = 1:2:numel(varargin)
    nm = char(varargin{i});
    if ~isfield(args, nm)
        error("tepc:uq:Args", "未知参数 %s (允许 Samples/NEvPerSample/Seed/CostCap)", nm);
    end
    args.(nm) = varargin{i+1};
end
N = double(args.Samples(:)');
if isempty(N) || any(~isfinite(N)) || any(N ~= floor(N)) || any(N < 2) ...
        || any(diff(N) <= 0)
    error("tepc:uq:BadSamples", ...
        "Samples 必须是 >=2 的严格递增整数向量, 实得 %s", mat2str(args.Samples));
end
tot = sum(N);
if tot > args.CostCap
    error("tepc:uq:TooExpensive", ...
        "阶梯共 %d 个 LHS 样本, 超过 CostCap=%d: 用 'CostCap' 提高上限或缩短阶梯", ...
        tot, args.CostCap);
end

% ---------------- 1) 收敛阶梯 ----------------
rows = struct('N', {}, 'yF_mean', {}, 'u_yF_rel', {}, 'se_yF_rel', {}, ...
    'u_level_ratio', {}, 'expected_ratio', {}, 'observed_ratio', {}, ...
    'noise_ref', {}, 'within_slack', {});
uPrev = NaN;
sePrev = NaN;
for k = 1:numel(N)
    o = tepc.uq.propagateMC(cfg, N(k), 'Seed', args.Seed, ...
        'NEvPerSample', args.NEvPerSample);
    u = o.summary.u_yF_rel;
    row = struct();
    row.N = N(k);
    row.yF_mean = o.summary.yF_mean;
    row.u_yF_rel = u;
    se = u / sqrt(N(k));                       % 均值标准误 (相对形式)
    row.se_yF_rel = se;
    if k == 1
        row.u_level_ratio = NaN;               % CV 的参照是 1, 但第一级无前项
        row.expected_ratio = NaN;
        row.observed_ratio = NaN;
    else
        row.u_level_ratio = u / max(uPrev, eps);
        row.expected_ratio = sqrt(N(k-1) / N(k));
        row.observed_ratio = se / max(sePrev, eps);
    end
    % 标准差自身的相对抽样噪声 (正态母体): 决定"偏离 1/sqrt(N) 多少算异常"
    row.noise_ref = 1 / sqrt(2 * (N(k) - 1));
    if k == 1
        row.within_slack = true;
    else
        % 两级各自的标准差估计都有 ~noise_ref 的相对噪声, 比值的不确定度取两者之和的
        % 2 倍 (≈95% 覆盖)。拿 1/sqrt(N) 律当硬门禁会在小 N 上必然误报。
        tol = 2 * sqrt(row.noise_ref^2 + 1 / (2 * (N(k-1) - 1)));
        row.within_slack = abs(row.observed_ratio - row.expected_ratio) ...
            <= tol * row.expected_ratio;
    end
    rows(end+1) = row; %#ok<AGROW>
    uPrev = u;
    sePrev = se;
end
out.ladder = rows;
out.total_samples = tot;

% ---------------- 2) 模型形式项 (弦长口径) ----------------
R = 1.0;                                   % 取单位半径: 比值无量纲, 与真实腔半径无关
gs = struct('type', "sphere", 'R_m', R);
lcyl = R * (2/3)^(1/3);                    % 等体积、H=2r 的圆柱半径
% bboxR_m 是圆柱的角点半径: sqrt(r^2 + (H/2)^2) = sqrt(r^2 + r^2) = r*sqrt(2)
gc = struct('type', "cylinder_finite", 'R_m', lcyl, 'bboxR_m', lcyl*sqrt(2));
lS = tepc.geometry.meanChordLength(gs);
lC = tepc.geometry.meanChordLength(gc);
mf = struct();
mf.lbar_sphere_m = lS;
mf.lbar_cylinder_m = lC;
mf.ratio = lC / lS;
mf.rel_gap = abs(mf.ratio - 1);
mf.closed_form_ratio = (2/3)^(1/3);
mf.basis = ["lbar = 4V/S (Cauchy, 凸体 + 各向同性均匀直线场); 球 4R/3, 等径高圆柱 4r/3"; ...
    "本项是几何理想化造成的**平均弦长**相对差, 不是 y_F 的模型形式项"; ...
    "换算到 y_F 需要逐事件输运重跑, 本函数不做该外推"];

% y_F 随 1/lbar 的方向性核对 (只作 sanity, 不当结论): 弦长变短 => 同一沉积长度的
% 授予能除以更短的径迹 => y 变大。阶梯与模型形式两块互不依赖, 任一块失败另一块仍成立。
out.model_form = mf;
out.settings = struct('seed', args.Seed, 'nEv_per_sample', args.NEvPerSample);
end
