function out = propagateMC(cfg, N, varargin)
%PROPAGATEMC 不确定度传播: LHS + 正态 copula 联合抽样,
%   每个样本重跑"完整但同一"的物理+仪器链, 得到 yF/yD/Qbar/D_site 的分布。
%
%   变量映射 (全部真正施加, 未识别的名字直接报错而不是静默忽略):
%     W_rel        -> 气体 W 值 (影响电离对数)
%     fano         -> 电离对涨落方差因子
%     gainScale    -> **物理**增益 (Diethorn deltaV), 而反演仍用名义 G_mean:
%                     真实仪器正是这样 —— 刻度测的是电荷, 把电荷换成能量要假设 G,
%                     G 的不确定度因此是真实的系统项 (TEPC 最大项之一)。
%     stopScale    -> 阻止本领表整体缩放 (输运/沉积能)
%     pressure_rel -> 气体压强 (密度 -> 质量厚度 -> 等效位点 -> y 分母)
%     adcCal_rel   -> 刻度斜率偏差 (码->电荷)
%     threshold_rel-> 触发阈值相对偏差 (electronics.trigger.threshold_V)
%     noise_rel    -> 成形噪声幅度 (ctx.noiseScale)
%     deadTime_rel -> 死时间常数相对偏差 (统一 DAQ 状态机消费)
%   清单的唯一真相源是 tepc.uq.mappedVariables(); 本注释与预算表、与配置默认值三者
%   的一致性由 tests/unit/test_uq_budget_inertness.m 核对 (表低估/高估代码都判红)。
%
%   公共随机数: 所有样本用同一 (seed, eventID) 子流, 样本间差异只来自参数,
%   不来自抽样噪声 —— 这是配对扰动, 否则 tornado 会被 MC 噪声淹没。
%   Name-Value: 'Seed', 'NEvPerSample', 'ProgressFcn' 三个, 其它名字报 tepc:uq:Args
%   'ProgressFcn' = f(k, N) 在每完成一个样本后调用一次。逐样本心跳是必需的而不是装饰:
%   本阶段整段只在入口写一次进度, 32 样本在争用机上实测 512 s 无任何落盘, 于是
%   "连续 300 s 无推进 = 卡住" 这条外部判据会把一个正常在算的作业判成失效,
%   界面进度条也会停在同一个百分比 8 分钟。默认空 = 不调用, 行为与旧版逐位一致。

args = struct('Seed', 24680, 'NEvPerSample', 1500, 'ProgressFcn', []);
if mod(numel(varargin), 2) ~= 0
    error("tepc:uq:Args","Name-Value 参数必须成对");
end
for i = 1:2:numel(varargin)
    nm = char(varargin{i});
    if ~isfield(args, nm)
        error("tepc:uq:Args","未知参数 %s (允许 Seed/NEvPerSample/ProgressFcn)", nm);
    end
    args.(nm) = varargin{i+1};
end

vn = fieldnames(cfg.uq.variables);
d = numel(vn);
if d == 0, error("tepc:uq:NoVars","cfg.uq.variables 为空"); end
% 白名单必须在**抽样之前**整体校验。paramMap 的同类检查位于逐样本 try 之内, 未实现
% 映射的名字因此被记成"这个样本失败了"并吞掉 —— 配置错误伪装成 N/N 次偶然失败,
% 调用方只看到 y_F 全 NaN (实测: 测试期望 tepc:uq:UnknownVariable 却"未引发任何异常")。
mp = mappedNames();
unmapped = vn(~ismember(vn, mp));
if ~isempty(unmapped)
    error("tepc:uq:UnknownVariable", ...
        "uq.variables 含未实现映射的变量 %s (可用: %s)", ...
        strjoin(unmapped, ', '), strjoin(string(mp), ', '));
end
rs = RandStream('Threefry', 'Seed', args.Seed);
U = tepc.uq.lhs(N, d, rs);

% 相关矩阵 (正定投影, 避免 chol 在非正定输入上直接崩)
Rcorr = eye(d);
if isfield(cfg.uq, 'correlations')
    fn = fieldnames(cfg.uq.correlations);
    for i = 1:numel(fn)
        nameStr = char(string(fn{i}));
        % 分隔符接受 '-' 与 ':'。注意 jsondecode 会把 JSON 字段名里的 '-' 改写成
        % '_', 所以经配置文件传入时要用 "变量A:变量B" 形式。
        pr = regexp(char(string(fn{i})), '[-:]', 'split');
        if numel(pr) ~= 2 || isempty(pr{1}) || isempty(pr{2})
            % jsondecode 会把 JSON 键里的 '-' 改写为 '_', 而变量名本身含 '_'
            % (如 W_rel)。因此再按"已声明变量名做最长前缀匹配"兜一次,
            % 使配置文件里的 "W_rel-fano" 也能被正确解析, 而不是崩在下标上。
            pr = splitByKnown(nameStr, vn);
        end
        if numel(pr) ~= 2 || isempty(pr{1}) || isempty(pr{2})
            error("tepc:uq:BadCorrName", ...
                "相关项 '%s' 无法解析为两个已声明变量 (可用: %s; 建议写成 变量A:变量B)", ...
                nameStr, strjoin(vn, ', '));
        end
        i1 = find(strcmp(vn, pr{1}), 1); i2 = find(strcmp(vn, pr{2}), 1);
        if isempty(i1) || isempty(i2)
            error("tepc:uq:UnknownVar", "相关项 '%s' 引用未声明变量 (可用: %s)", ...
                fn{i}, strjoin(vn, ', '));
        end
        if ~isempty(i1) && ~isempty(i2)
            rho = double(cfg.uq.correlations.(fn{i}));
            if ~(isfinite(rho) && abs(rho) < 1)
                error("tepc:uq:BadCorr","相关系数 %s = %g 非法", fn{i}, rho);
            end
            Rcorr(i1, i2) = rho; Rcorr(i2, i1) = rho;
        end
    end
end
ev0 = eig((Rcorr + Rcorr')/2);
if min(ev0) <= 1e-10
    Rcorr = Rcorr + eye(d) * (1e-6 - min(ev0));
    Rcorr = Rcorr ./ sqrt(diag(Rcorr) * diag(Rcorr)');   % 重新标准化为相关阵
end
L = chol(Rcorr, 'lower');
Z = randn(rs, N, d) * L.';              % 行向量约定: x = z*L' 才有 Cov = L*L'
Gc = (erf(Z / sqrt(2)) + 1) / 2;
% 秩变换必须**显式按样本维 (dim 1)**。MATLAB 的 sort 沿"第一个非单一维"排序:
% N=1 时 Gc 是 1×d, 不写维就沿 dim 2 排, 秩变成 1..d 而不是 1..N, 于是
% Uc=(rk-1+U)/N 最大到 d/N=9 -> norminv 直接抛 tepc:uq:BadP (实测 N=1 必崩)。
[~, rk] = sort(Gc, 1); [~, rk] = sort(rk, 1);
Uc = (rk - 1 + U) / N;                  % copula 秩 + LHS 分层边际

% 名义基准 (反演用名义 G; 物理侧才施加增益扰动)
root = tepc.io.projectRoot();
R0 = tepc.config.resolve(cfg);
[Qfun0, ~] = tepc.analysis.qualityFactor(cfg.analysis.qualityFactor, root);
c0 = tepc.electronics.filters(cfg);
[~, ms0] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',args.Seed+1), "sigma");
% 刻度只在**名义仪器状态**下做一次: 真实仪器是先标定后测量, 运行工况(压强/温/增益)
% 漂移是待传播的不确定度来源, 不该被"每样本重新标定"抵消掉。
ctxNom = struct('W_eV', cfg.gas.W_eV.value, 'fano', cfg.gas.fano.value, ...
    'field', R0.field, 'mob', R0.mob, 'seed', args.Seed, ...
    'G_mean', R0.G_mean, ...
    'theta', tepc.config.constants('detector.polya.theta'), 'r0_m', R0.r0_m, ...
    'coeffs', c0, 'noiseSigma', ms0.sigma_peak_V);
cal0 = tepc.calibration.injectCalibrate(cfg, ctxNom, int64(2e9));

yF = nan(N,1); yD = nan(N,1); Qb = nan(N,1); Dt = nan(N,1);
% 每个样本"是否越出已验证域"的披露 (空串 = 未越界); 只披露不剔除, 见 oneSample 内注释。
domNotes = strings(N,1);
Tin = nan(N, d); failed = {};
nEv = max(50, round(args.NEvPerSample));
yTr = nan(1, N);       % 同一样本的"真值谱" y_F (无仪器链) —— 用来把
                       % 统计/物理涨落 与 仪器反演偏差 分开

for k = 1:N
    try
        vals = nan(1, d);
        for j = 1:d
            vals(j) = drawVar(vn{j}, cfg.uq.variables.(vn{j}), Uc(k, j));
        end
        Tin(k, :) = vals;
        p = paramMap(vn, vals);
        [yF(k), yD(k), Qb(k), Dt(k), yTr(k), domNotes(k)] = oneSample(cfg, R0, Qfun0, c0, ms0, p, nEv, args.Seed, cal0);
    catch e
        failed{end+1} = struct('sample', k, 'id', e.identifier, 'msg', e.message); %#ok<AGROW>
    end
    if ~isempty(args.ProgressFcn)
        % 心跳是**可观测性**, 不能有能力打断物理: 回调里抛错 (GUI 句柄已销毁、
        % 落盘被占用等) 必须只丢掉这一次心跳。放在逐样本 try/catch 之外时, 一次回调
        % 抛错会掀掉整个样本循环, 让 uq.json 从"少一条进度"变成"整份不确定度没有产物"。
        try
            args.ProgressFcn(k, N);
        catch
        end
    end
end

okS = isfinite(yF);
summ = struct();
summ.nOk = nnz(okS); summ.nFailed = numel(failed);
summ.n_samples_out_of_domain = nnz(domNotes ~= "");
summ.sample_out_of_domain_codes = strjoin(unique(domNotes(domNotes ~= "")), " | ");
summ.yF_mean = mean(yF, 'omitnan'); summ.yF_sd = std(yF, 'omitnan');
summ.yD_mean = mean(yD, 'omitnan'); summ.yD_sd = std(yD, 'omitnan');
summ.Qbar_mean = mean(Qb, 'omitnan'); summ.Qbar_sd = std(Qb, 'omitnan');
summ.Dt_mean = mean(Dt, 'omitnan'); summ.Dt_sd = std(Dt, 'omitnan');
summ.yF_CI95 = quantileCI(yF, 0.025, 0.975);
summ.yD_CI95 = quantileCI(yD, 0.025, 0.975);
summ.u_yF_rel = summ.yF_sd / max(abs(summ.yF_mean), eps);
% 累计位点比能量的相对不确定度 (Dt = z_mean_per_history_Gy * N_hist, 即旧名
% D_tissue_Gy 的口径; 不是每历史的 T2 量, 字段名按累计写)。它此前只落在 uq.json 里,
% summary 不带 -> 报告与 GUI 的剂量页只有 yF 的误差棒, 剂量读数像确定值。
% N_hist 逐样本同一常数, 故此 CV 与每历史口径的 CV 数值相同, 但命名不占这个便宜。
summ.u_Dcum_rel = summ.Dt_sd / max(abs(summ.Dt_mean), eps);
summ.method = "LHS + 正态copula + 完整物理/仪器链重算 (公共随机数配对)";
% 成对真值 —— 没有它, "测量不确定度"与"物理不确定度"只是贴标签。
summ.yF_truth_mean = mean(yTr, 'omitnan');
summ.yF_truth_sd   = std(yTr, 'omitnan');
summ.instr_bias_mean = summ.yF_mean / max(abs(summ.yF_truth_mean), eps) - 1;
summ.instr_bias_sd   = std(yF - yTr, 'omitnan') / max(abs(summ.yF_mean), eps);
summ.scope = ["physics 侧扰动 W/fano/pressure/增益/阻止本领; measurement 侧扰动 " ...
    "ADC 刻度/阈值/噪声/死时间; 反演用名义刻度 (真实数据处理正是如此), " ...
    "因此 instr_bias_* 是仪器链的系统项而非误差"];

torn = struct();
for j = 1:d
    if nnz(okS) >= 3
        torn.(vn{j}) = spearman(Tin(okS, j), yF(okS));
    else
        torn.(vn{j}) = NaN;
    end
end

out = struct();
out.summary = summ; out.tornado = torn; out.nSamples = N;
out.variables = vn; out.inputs = Tin; out.yF = yF; out.yD = yD;
out.yF_truth = yTr;
out.Qbar = Qb; out.D_site = Dt; out.failed = failed;
out.seed = args.Seed;
% 相关矩阵外提 (旧实现只在内部用 copula 抽 LHS, 调用方拿不到任何相关性)。
%   corr_inputs  = 抽样得到的输入间 Spearman 矩阵 (copula 结构的实测体现);
%   corr_with_yF = 每个输入与 y_F 的 Spearman (即 tornado 的成对版本)。
if nnz(okS) >= 3
    yvCol = yF(okS);  yvCol = yvCol(:);           % 不管 yF 是行还是列, 统一成列
    Cf = rankCorr([Tin(okS, :), yvCol]);
    out.corr_inputs  = Cf(1:d, 1:d);
    out.corr_with_yF = Cf(d+1, 1:d);
else
    out.corr_inputs = nan(d, d);
    out.corr_with_yF = nan(1, d);
end
out.domNotes = domNotes;
out.nSamplesOutOfDomain = nnz(domNotes ~= "");
out.class = classOf(vn);            % 每个变量属于 physics / measurement
% 注意: ["a" "b"] 对**字符串字面量**是"两个元素", 不是"一条消息" —— 只有字符向量
% ['a' 'b'] 才是文本拼接。跨行长句必须用 + 拼, 否则维度不齐直接报错。
n1 = "每个样本重跑 输运->雪崩->Ramo波形->成形->ADC->刻度反演->谱/剂量 全链 " + ...
     "(含死时间与触发); 反演固定使用名义刻度 (真实数据处理正是如此); " + ...
     "physics 与 measurement 两类扰动都可单独开关, 见 cfg.uq.variables.<名>.class";
n2 = "口径披露: gainScale 是对 diethorn_deltaV 的相对扰动, 而 G=exp((ln2/dV)*intE) " + ...
     "=> G->G^(1+g), 所以 sd=3% 实际是 dG/G = ln(G)*3% (G=136 时约 14.7%), 不是'增益 ±3%'; " + ...
     "它与 adcCal_rel 在 y 上精确简并 (都等价于 y*(1+g)/b2 型缩放), 而 config 的 " + ...
     "uq.correlations 为空 => 两者按独立合成, 结果偏保守 (总不确定度偏大), 报告不得把它当独立证据。" + ...
     "抽样配置逐样本过 tepc.config.validate: 越界样本计入 nFailed -> uq_status=INCOMPLETE。";
n3 = "覆盖范围披露: 扰动变量表里没有源归一因子 —— Phi/A_eff/f_geo/p_int 目前是配置点值, " + ...
     "没有登记 sd, 因此 k_norm 是确定值, D_macro_Gy 与 H_macro_Sv (T3) 的不确定度不随本表传播; " + ...
     "u_Dcum_rel 是累计位点比能量的相对不确定度 (统计 + 参数), 不能当作 T3 的误差棒。";
out.note = [n1; n2; n3];
end

function C = rankCorr(X)
% 秩相关 (ties 用 average 秩)。返回 p x p 满矩阵, 由调用方切片。
R = zeros(size(X));
for j = 1:size(X, 2)
    R(:, j) = tiedRanks(X(:, j));
end
C = corrcoef(R);
end

function r = tiedRanks(x)
[~, ~, ic] = unique(x);
s = accumarray(ic, 1, [], @sum);            % 每个唯一值出现次数
cs = cumsum(s);
grpStart = cs - s + 1;
avg = (grpStart + cs)/2;                    % ties -> average 秩
[~, so] = sort(x, 'ascend');
r = zeros(size(x));
r(so) = avg(ic);
r = r(:);
end

function cls = classOf(vn)
% 变量分类: 分类写在变量的元数据里, 不另设第二处知识。
physics = ["W_rel","fano","stopScale","pressure_rel"];
cls = strings(1, numel(vn));
for i = 1:numel(vn)
    if any(vn{i} == physics)
        cls(i) = "physics";
    else
        cls(i) = "measurement";
    end
end
end

% ---------------- 单样本完整链 ----------------
function [yFk, yDk, Qk, Dk, yFkTruth, domNote] = oneSample(cfg, R0, Qfun0, c0, ms0, p, nEv, seed, cal0)
cfgk = cfg;
cfgk.gas.W_eV.value  = cfg.gas.W_eV.value  * (1 + p.W_rel);
cfgk.gas.fano.value  = p.fano;
cfgk.gas.pressure_Pa = cfg.gas.pressure_Pa * (1 + p.pressure_rel);
% 物理增益: G = exp(ln2/deltaV * ...), deltaV 除以 (1+gainScale) 才使 G 增大
cfgk.detector.diethorn_deltaV_V.value = ...
    cfg.detector.diethorn_deltaV_V.value / (1 + p.gainScale);
% measurement 侧旋钮真的接入 (旧实现里阈值/噪声/死时间既不在白名单也
% 不进链路, 于是"测量不确定度"只是嘴上说说)。
cfgk.electronics.trigger.threshold_V = ...
    cfg.electronics.trigger.threshold_V * (1 + p.threshold_rel);
cfgk.electronics.deadTime_s = cfg.electronics.deadTime_s * (1 + p.deadTime_rel);
cfgk.provenance.seed = seed;                       % 公共随机数锚
Rk = tepc.config.resolve(cfgk);

tables = struct( ...
    'proton',   scaleTable(tepc.transport.stoppingPower(cfgk, "proton"),   p.stopScale), ...
    'electron', scaleTable(tepc.transport.stoppingPower(cfgk, "electron"), p.stopScale), ...
    'heavy_C',  scaleTable(tepc.transport.stoppingPower(cfgk, "heavy_C"),  p.stopScale), ...
    'heavy_O',  scaleTable(tepc.transport.stoppingPower(cfgk, "heavy_O"),  p.stopScale));
% 抽样出的配置也过一遍与主运行同一套域校验 (旧实现 cfgk 从未 validate, "不确定度"里
% 混进了主运行会拒绝的仪器状态) —— 但**只披露, 不剔除**:
%   * 敏感性研究本来就要探到已验证域的边缘之外, 悄悄丢样本会让不确定度**低估**;
%   * 而"越界即拒"实测会让每个样本都被拒 -> y_F 全 NaN -> UQ 直接瘫掉 (9 个测试连锁红)。
% 所以数出有多少样本越界、都是哪些 code, 交给 summary/报告/门禁去降级。
issK = tepc.config.validate(cfgk);
domNote = "";
if ~isempty(issK)
    % issK 是 **cell of struct** (tepc.config.validate 的返回约定)。arrayfun 不拆 cell 的壳,
    % 它把 1×1 cell 本身传给函数, 于是 s.level 抛 MATLAB:structRefFromNonStruct;
    % 而这一行在逐样本 try 内, 结果是"每个样本都失败 -> y_F 全 NaN" (实测 5/5)。
    % 只有 cellfun 传的是 cell 内容。取 code 同理不能用 {badK.code} 点索引 cell。
    isErrK = cellfun(@(s) string(s.level) == "error", issK);
    if any(isErrK)
        codes = string(cellfun(@(s) string(s.code), issK(isErrK), 'UniformOutput', false));
        domNote = strjoin(unique(codes), ',');
    end
end

ctx = struct('W_eV', cfgk.gas.W_eV.value, 'fano', cfgk.gas.fano.value, ...
    'field', Rk.field, 'mob', Rk.mob, 'seed', seed, ...
    'G_mean', Rk.G_mean, 'theta', tepc.config.constants('detector.polya.theta'), ...
    'r0_m', Rk.r0_m, ...
    'coeffs', c0, 'noiseSigma', ms0.sigma_peak_V, ...
    'noiseScale', 1 + p.noise_rel);

[ev, ~] = tepc.transport.AnalyticAdapter(cfgk, Rk.geom, tables, ...
    RandStream('Threefry','Seed',seed), nEv, 1, struct('tNext', 0));
[~, instr] = tepc.electronics.simulate(ev.ev.EdepGas_keV, 1, cfgk, ...
    RandStream('Threefry','Seed',seed), ctx);
ev.ev.adc_code = instr.adc_code;
ev.ev.adc_range = instr.range;
ev.ev.flags = bitor(ev.ev.flags, instr.flags);
% 死时间 + pile-up: **逐字复刻** execute 的语义 (统一 DAQ + 拒收清零权重)。
% 两边不同步的话, UQ 评的是另一台仪器。
latUQ = c0.hidx * c0.Ts;
puW   = uqPileWindow(cfgk);
[tSrt, ordT] = sort(ev.ev.t0_s(:));
dqRes = tepc.electronics.daq(tSrt, latUQ, puW, cfgk.electronics.deadTime_s, ...
    cfgk.electronics.deadTimeMode, struct());
accUQ = false(numel(tSrt),1);  accUQ(ordT) = dqRes.accepted;
F0 = tepc.domain.Flags();
% 标志位必须与 execute **逐位一致**: 曾把堆叠也盖成 DEADTIME_REJECTED, 于是 UQ 的
% 拒收账本与主运行的账本不是同一台仪器。
addF = zeros(numel(tSrt), 1, 'uint32');
addF(dqRes.reason == "deadtime") = F0.DEADTIME_REJECTED;
addF(dqRes.reason == "pileup")   = F0.PILEUP;
ev.ev.flags(ordT) = bitor(ev.ev.flags(ordT), addF);
ev.ev.weight(~accUQ) = 0;

cal = cal0;
% 刻度斜率偏差: 代表"电荷-码标定本身的不确定度", 只作用于反演侧
cal.beta(2) = cal.beta(2) * (1 + p.adcCal_rel);
if numel(cal.beta) > 2, cal.beta(3) = cal.beta(3) * (1 + p.adcCal_rel); end
cal.domain_C = cal.domain_C / (1 + p.adcCal_rel);
xc = tepc.electronics.extCode(ev.ev.adc_code, ev.ev.adc_range, ...
    cfg.electronics.adc.bits, cfg.electronics.adc.range2Gain);
% 反演固定用**名义** G 与名义 W: 真实数据处理正是如此
phys = struct('W_eV', cfg.gas.W_eV.value, 'G', R0.G_mean);
[eps_meas, infl] = tepc.calibration.adcToEnergy(xc, cal, phys);
F = tepc.domain.Flags();
bad = bitor(infl, ev.ev.flags);
inv = bitand(bad, bitor(F.UNDER_THRESHOLD, bitor(F.OVERFLOW_ADC, F.OUT_OF_RANGE))) > 0;
eps_meas(inv) = NaN;
w = ev.ev.weight(:);  w(~isfinite(eps_meas)) = 0;
eps0 = eps_meas; eps0(~isfinite(eps0)) = 0;
S = tepc.analysis.buildSpectrum(eps0, Rk.lbar_tissue_um, w, Rk.edges, struct('Qfun', Qfun0));
Evs = ev.ev; Evs.weight = w; Evs.epsilon_meas_keV = eps0;
Evs.y_keV_per_um = eps0 / Rk.lbar_tissue_um;
D = tepc.analysis.doseChain(Evs, Rk.geom, cfgk, Rk.rho_g, Rk.massGas_kg, Qfun0, ...
    struct('eps_meas_keV', eps0, 'w_stat_pub', w));
yFk = S.yF_exact; yDk = S.yD_exact;
Qk = S.Qbar; if S.Qmissing, Qk = NaN; end
% 位点剂量取 T2 的诚实口径 (每初级历史的位点比能量) 再乘回记录历史数, 得到与本样本
% N 事件对应的累计量 —— Dt 累加器与 out.D_site 的口径 (累计位点比能量) 因此不变,
% 变的只是取值来源: 不再读 doseChain 的旧名 D_tissue_Gy。
Dk = D.z_mean_per_history_Gy * D.nHistories;
% 配对真值: 同一批事件、**同一套权重**, 但 y 用沉积能直接除以 lbar (不经仪器链)。
% 有了它, "仪器链带来的偏差"才能与"物理/统计涨落"分开陈述。
% w (不是 ev.ev.weight) 是关键: 阈值/溢出把 epsilon_meas 判为 NaN 的那些事件, 在
% analyze 的真值谱里同样被剔除。曾直接用未取掩码的权重, 于是这里的 instr_bias_*
% 把"阈值接受率"混进了"仪器反演偏差", 与报告里的 instr_bias_yF 不是同一个量。
epsTrue = ev.ev.EdepGas_keV(:);
wTrue = w;
St = tepc.analysis.buildSpectrum(epsTrue, Rk.lbar_tissue_um, wTrue, Rk.edges, struct());
yFkTruth = St.yF_exact;
end

function puW = uqPileWindow(cfgk)
% 占用窗的唯一真相源在 tepc.electronics.pulseOccupancy_s (UQ 必须与 execute 同窗,
% 否则两边评的是不同长度的脉冲)。
puW = tepc.electronics.pulseOccupancy_s(cfgk);
end


function T = scaleTable(T, s)
T.S_mass = T.S_mass * (1 + s);
T.lgStab = log(T.S_mass(:));
end

function f = mappedNames()
% 已实现映射的 UQ 变量名 —— 唯一真相源已提到 tepc.uq.mappedVariables (白名单校验、
% paramMap 与预算覆盖锁共用同一份)。本函数只是内部别名。
% cell() 不能把 string 数组转成 cellstr (MATLAB:invalidConversion), 必须走 cellstr。
f = cellstr(tepc.uq.mappedVariables());
end

function v = paramMap(nm, vals)
f = mappedNames();
v = struct();
for i = 1:numel(f)
    j = find(strcmp(nm, f{i}), 1);
    if isempty(j)
        v.(f{i}) = 0;                      % 未声明的变量按 0 (不扰动)
    else
        v.(f{i}) = vals(j);
        if ~isfinite(v.(f{i})), error("tepc:uq:NotFinite","%s 抽样非有限", f{i}); end
    end
end
if ~(v.fano > 0 && v.fano < 1), error("tepc:uq:BadFano","fano=%g 超出 (0,1)", v.fano); end
if ~(1 + v.gainScale > 0), error("tepc:uq:BadGain","gainScale=%g 非法", v.gainScale); end
end

function x = drawVar(nm, spec, u)
switch string(spec.dist)
    case "normal",  x = double(spec.mean) + double(spec.sd) * norminvQ(u);
    case "uniform", x = double(spec.lo) + u * (double(spec.hi) - double(spec.lo));
    case "fixed",   x = double(spec.value);
    otherwise, error("tepc:uq:BadDist","未知分布 %s (%s)", spec.dist, nm);
end
end

function s = firstOrderProxy() %#ok<DEFNU>
% 占位: 解析一阶传播从未真正实现, 旧版的 Quick 分支只返回一个凭空的数字。
% 这里显式保留"未实现"的事实而不是伪造结果。
    s = "未实现: 一阶(GUM)传播在本仓库没有可信灵敏度系数来源, 请使用蒙特卡洛";
end

function q = quantileCI(x, p1, p2)
x = x(~isnan(x)); x = sort(x); n = numel(x);
if n == 0, q = [NaN NaN]; return; end
q = [x(clampIdx(round(p1*n) + 1, n)), x(clampIdx(round(p2*n) + 1, n))];
end

function i = clampIdx(i, n)
i = max(1, min(n, i));                 % 小样本时 p2*n 会四舍五入到 n+1 -> 越界
end

function r = spearman(a, b)
a = a(:); b = b(:);
if numel(a) ~= numel(b)
    error("tepc:uq:SpearmanLen","秩相关两侧长度不一致 (%d vs %d)", numel(a), numel(b));
end
ra = ties_ranks(a); rb = ties_ranks(b);
cc = corrcoef(ra, rb);
r = cc(1, 2);
end

function rk = ties_ranks(a)
% 平均秩 (ties 必须取平均, 否则离散变量的秩相关有偏)
[s, i] = sort(a, 'ascend');
n = numel(s); rk = zeros(n,1);
j = 1;
while j <= n
    k = j;
    while k < n && s(k+1) == s(j), k = k + 1; end
    rk(i(j:k)) = (j + k)/2;
    j = k + 1;
end
end

function pr = splitByKnown(nameStr, vn)
% SPLITBYKNOWN 在已知变量名集合里做"最长前缀 + 剩余后缀"配对。
%   用于兜住 jsondecode 把 '-' 改写成 '_' 的情形 (变量名自身含 '_', 故不能简单
%   按 '_' 切分)。要求前缀与剩余部分都精确等于某个已声明变量名。
pr = {};
best = ''; bestRest = '';
for i = 1:numel(vn)
    a = char(string(vn{i}));
    if numel(nameStr) > numel(a) && strcmp(nameStr(1:numel(a)), a)
        rest = nameStr(numel(a)+1:end);
        if rest(1) == '_', rest = rest(2:end); end
        if any(strcmp(vn, rest)) && numel(a) > numel(best)
            best = a; bestRest = rest;
        end
    end
end
if ~isempty(best), pr = {best, bestRest}; end
end

function x = norminvQ(p)
% 标准正态分位数: 委托给 tepc.uq.norminv (单一真相源, 便于单测直接锁定)。
x = tepc.uq.norminv(p);
end
