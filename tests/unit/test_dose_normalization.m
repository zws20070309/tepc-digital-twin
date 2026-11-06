function tests = test_dose_normalization
%TEST_DOSE_NORMALIZATION 权重分层与剂量归一的预注册判据。
%   锁四件事:
%   1) 条件分布 (T1: f(y)/d(y)/yF/yD/Qbar/n_eff/逐 bin 权重和) 与源强无关 ——
%      改 source.fluence_m2 只能改宏观量, 一位都不能动形状与逐事件权重和。
%   2) 宏观量 (T3) 只在源归一链 (注量, 被照面积, 几何接受度, 作用概率) 全部有定义时
%      存在; 缺任一项 => NaN + 原因串, 绝不静默按 1 归一。
%   3) w_stat (逐事件统计权重) 与 k_norm (标量物理归一) 不可互换: 塞错槽位必须报错。
%   4) T2 (每初级历史的位点比能量) 改名前后数值逐位相同, 金基线谱形状逐位不变。
tests = functiontests(localfunctions);
end

% ==================== 1) 条件分布对注量不变, 宏观量按注量线性 ====================

function test_spectrum_invariant_while_macro_scales(tc)
% 主用例: 同一批事件、同一套 w_stat, 只把 fluence_m2 乘 10。
root = rootCase();
cfg0 = configCase(root);
cfgA = withNormalization(withFluence(cfg0, 1.0e6));
cfgB = withNormalization(withFluence(cfg0, 1.0e7));
R = tepc.config.resolve(cfgA);
[Qfun, ~] = tepc.analysis.qualityFactor(cfgA.analysis.qualityFactor, root);
E = eventsCase();
[A1, ~] = tepc.analysis.analyze(E, cfgA, R, Qfun);
[A2, ~] = tepc.analysis.analyze(E, cfgB, R, Qfun);

% --- T1: 归一形状 + 未归一的逐 bin 权重和, 全部逐位相同 ---
% sum_w/SW_valid 这一组是关键: 标量乘子在 f=p/dy 里会自己约掉, 只看形状抓不到
% "把 k_norm 乘进直方权重"的漏法; 未归一的权重和才是它的捕手。
bins = {'f','d','p','sum_w','sum_w2','sum_wy','sum_wy2','counts_raw','sigma_f', ...
    'edges','center','dy'};
for i = 1:numel(bins)
    same = isequal(A1.spectrum.(bins{i}), A2.spectrum.(bins{i}));
    tc.verifyTrue(same, sprintf('bin 量 %s 随 fluence 变了: 宏观归一漏进了 T1', bins{i}));
end
scalars = {'yF_exact','yD_exact','yF_binned','yD_binned','intFdy','intDdy','Qbar', ...
    'SW_valid','SW_inBins','nEff','underflowWeight','overflowWeight','zeroDepCount', ...
    'counts_inRange'};
for i = 1:numel(scalars)
    bitwise(tc, A1.spectrum.(scalars{i}), A2.spectrum.(scalars{i}), ['spectrum.' scalars{i}]);
end
bitwise(tc, A1.dose.Qbar, A2.dose.Qbar, 'dose.Qbar');
bitwise(tc, A1.dose.z_mean_per_history_Gy, A2.dose.z_mean_per_history_Gy, 'T2 z_mean');
bitwise(tc, A1.dose.z_mean_given_valid_Gy, A2.dose.z_mean_given_valid_Gy, 'T2 条件均值');
bitwise(tc, A1.dose.z_var_given_valid_Gy2, A2.dose.z_var_given_valid_Gy2, 'T2 方差');
bitwise(tc, A1.dose.D_tissue_Gy, A2.dose.D_tissue_Gy, 'B 链累计 (与源无关)');
bitwise(tc, A1.dose.D_gas_Gy, A2.dose.D_gas_Gy, 'A 链累计 (与源无关)');
bitwise(tc, A1.dose.n_eff_stat, A2.dose.n_eff_stat, 'n_eff_stat');

% --- T3: 宏观量按注量精确线性 ---
tc.verifyTrue(isfinite(A1.dose.k_norm) && isfinite(A2.dose.k_norm), ...
    '两份配置的源归一链都必须完整, 否则本判据无从比较');
tc.verifyEqual(A2.dose.k_norm, 10*A1.dose.k_norm, 'RelTol', 1e-12, 'k_norm 必须按注量线性');
tc.verifyEqual(A2.dose.D_macro_Gy, 10*A1.dose.D_macro_Gy, 'RelTol', 1e-12, ...
    'D_macro_Gy 必须按注量线性');
tc.verifyEqual(A2.dose.H_macro_Sv, 10*A1.dose.H_macro_Sv, 'RelTol', 1e-12);
tc.verifyEqual(A1.dose.D_macro_Gy, A1.dose.k_norm*A1.dose.z_mean_per_history_Gy, ...
    'RelTol', 1e-12, 'D_macro_Gy = k_norm*z_mean_per_history_Gy (只乘 T2, 不乘 T1)');
end

function test_leak_into_weights_would_go_red(tc)
% "喂错就红"自检 (防判据恒真): 手动把归一因子乘进直方权重, 上一用的两类断言必须
% 分别变红。两种漏法的可见性不同, 所以两类观测量都不得省:
%   (i) 标量漏法: 乘子在 f=p/dy 里约掉 (只剩舍入差), 只有**未归一的权重和**能抓到;
%   (ii) 形状漏法 (按 y 分段乘): f/d/yF/Qbar 必变。
lb = 0.3539106921268359;
edges = logspace(log10(0.01), log10(500), 121);
eps_ = epsVectorCase();
w = ones(size(eps_));
y = eps_/lb;
S0 = tepc.analysis.buildSpectrum(eps_, lb, w, edges, struct());
S1 = tepc.analysis.buildSpectrum(eps_, lb, w*12.5, edges, struct());
relF = max(abs(S1.f(:) - S0.f(:)))/max(abs(S0.f(:)));
tc.verifyLessThan(relF, 1e-12, ...
    '标量乘子会被 f 的归一约掉: 这条正是"只看形状会漏检"的证据, 因此下一条不可省');
tc.verifyFalse(isequal(S0.sum_w, S1.sum_w), ...
    '未归一的逐 bin 权重和必须对标量乘子敏感 —— 它是标量漏法的唯一捕手');
tc.verifyFalse(isequal(S0.SW_valid, S1.SW_valid), 'SW_valid 必须对标量乘子敏感');
mask = y > median(y);
S2 = tepc.analysis.buildSpectrum(eps_, lb, w.*(1 + 0.5*mask), edges, struct());
tc.verifyFalse(isequal(S0.f, S2.f), '形状漏法必须让 f 变红');
tc.verifyFalse(isequal(S0.d, S2.d), '形状漏法必须让 d 变红');
tc.verifyFalse(isequal(S0.yF_exact, S2.yF_exact), '形状漏法必须让 yF 变红');
tc.verifyFalse(isequal(S0.Qbar, S2.Qbar), '形状漏法必须让 Qbar 变红');
end

% ==================== 2) 源归一链不完整: NaN + 原因, 绝不按 1 ====================

function test_incomplete_chain_gives_nan_not_one(tc)
root = rootCase();
cfg = configCase(root);
[g, rho, mass] = geomCase(root);
ev = evSmallCase();
base = tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], struct());

c1 = cfg;
c2 = withNormalization(cfg);
c2.source.normalization = struct('status', 'NOT_AVAILABLE');
c3 = withFluence(cfg, NaN);
c4 = withNormalization(cfg, 'source_area_m2', [], 'status', 'NOT_AVAILABLE');
c5 = withNormalization(cfg, 'status', 'NOT_AVAILABLE');
cases = mkCases(c1, c2, c3, c4, c5);
want = ["source_normalization_undefined", "source_normalization_undefined", ...
    "source_normalization_undefined", "source_normalization_undefined", ...
    "source_normalization_status_not_declared"];

for i = 1:numel(cases)
    D = tepc.analysis.doseChain(ev, g, cases(i).cfg, rho, mass, [], struct());
    nm = char(cases(i).name);
    tc.verifyTrue(isnan(D.k_norm), sprintf('%s: k_norm 必须是 NaN', nm));
    tc.verifyTrue(isnan(D.D_macro_Gy), sprintf('%s: 宏观剂量必须是 NaN 而非数字', nm));
    tc.verifyTrue(isnan(D.H_macro_Sv), sprintf('%s: H_macro 必须随 T3 一起为 NaN', nm));
    tc.verifyTrue(isnan(D.H_micro_Sv), ...
        sprintf('%s: 旧字段 H_micro_Sv 不得继续给被放大 1e5 倍的 Sv 数', nm));
    % "按 1 硬算"的后果是 D_macro 恰好等于每历史值: 这条断言专抓它
    tc.verifyFalse(isequal(D.D_macro_Gy, D.z_mean_per_history_Gy), ...
        sprintf('%s: 缺位因子被当成 1 用了 (D_macro == z_mean)', nm));
    r = string(D.D_macro_reason);
    tc.verifySubstring(r, want(i), sprintf('%s: 原因串不对, 实得 %s', nm, r));
    tc.verifySubstring(join(string(D.dose_note), " | "), want(i), ...
        sprintf('%s: 原因没进 dose_note, 报告层读不到', nm));
    % T1/T2 不被源状态污染
    bitwise(tc, D.D_tissue_Gy, base.D_tissue_Gy, [nm ' B链累计']);
    bitwise(tc, D.z_mean_per_history_Gy, base.z_mean_per_history_Gy, [nm ' T2']);
    bitwise(tc, D.z_var_given_valid_Gy2, base.z_var_given_valid_Gy2, [nm ' T2 方差']);
    bitwise(tc, D.Qbar, base.Qbar, [nm ' Qbar']);
end
end

function test_claimed_available_but_incomplete_is_rejected(tc)
root = rootCase();
cfg = configCase(root);
[g, rho, mass] = geomCase(root);
ev = evSmallCase();
% "标了可用却拿默认值硬算" 必须是停 (与 CONFIG_INVALID 同判据), 不给 NaN 也不给 1
lie = withNormalization(cfg, 'interaction_probability', []);
lie.source.normalization.status = 'REFERENCE';
tc.verifyError(@() tepc.analysis.doseChain(ev, g, lie, rho, mass, [], struct()), ...
    'tepc:norm:StatusMismatch');
bad = withNormalization(cfg, 'status', 'GUESS');
tc.verifyError(@() tepc.analysis.doseChain(ev, g, bad, rho, mass, [], struct()), ...
    'tepc:norm:BadStatus');
zero = withNormalization(cfg, 'source_area_m2', 0);
tc.verifyError(@() tepc.analysis.doseChain(ev, g, zero, rho, mass, [], struct()), ...
    'tepc:norm:BadFactor');
hist = withNormalization(cfg, 'n_primary_histories', 999);
tc.verifyError(@() tepc.analysis.doseChain(ev, g, hist, rho, mass, [], struct()), ...
    'tepc:norm:HistoryMismatch');
% 立体角与接受度是同一条几何因子的两条来源: 折算后必须同值, 不一致必须停
sa = withNormalization(cfg, 'acceptance_fraction', []);
sa.source.normalization.solid_angle_sr = 2*pi*0.5;
D1 = tepc.analysis.doseChain(ev, g, sa, rho, mass, [], struct());
D2 = tepc.analysis.doseChain(ev, g, withNormalization(cfg), rho, mass, [], struct());
tc.verifyEqual(D1.k_norm, D2.k_norm, 'RelTol', 1e-12, ...
    'solid_angle_sr/(2*pi) 与 acceptance_fraction 必须给同一个 k_norm');
tc.verifyEqual(D1.D_macro_Gy, D2.D_macro_Gy, 'RelTol', 1e-12);
conf = withNormalization(cfg);
conf.source.normalization.solid_angle_sr = 1.0;
tc.verifyError(@() tepc.analysis.doseChain(ev, g, conf, rho, mass, [], struct()), ...
    'tepc:norm:GeoConflict');
end

% ==================== 3) w_stat 与 k_norm 槽位不可互换 ====================

function test_weight_and_norm_slots_are_not_interchangeable(tc)
root = rootCase();
cfg = configCase(root);
[g, rho, mass] = geomCase(root);
ev = evSmallCase();
% k_norm 只能由源归一链派生, 不接受外部塞入的数值
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('k_norm', 12.5)), 'tepc:dose:KNormSlotRejected');
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('k_norm', [1; 1; 1])), 'tepc:dose:KNormSlotRejected');
% 旧权重槽位名必须停, 而不是悄悄当 w_stat 用
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('weight', [1; 1; 1])), 'tepc:dose:LegacyWeightSlotRejected');
% 标量塞进逐事件槽位 = 形状上的典型误用
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('w_stat', 2.0)), 'tepc:dose:WeightSlotMismatch');
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('w_stat_pub', 3.0)), 'tepc:dose:WeightSlotMismatch');
% 逐事件数组塞进 norm 槽位; norm 必须带 status/k_norm 字段
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('norm', [1; 1; 1])), 'tepc:dose:NormSlotType');
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('norm', struct('k_norm', 1))), 'tepc:dose:NormSlotType');
% 两个发布权重源同时给且不一致
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], ...
    struct('w_stat_pub', [1; 1; 1], 'weight_pub', [1; 1; 0])), ...
    'tepc:dose:WeightDoubleSource');
% 谱侧: 标量归一因子塞进直方权重槽位被拒 (长度不一致)
tc.verifyError(@() tepc.analysis.buildSpectrum([1; 2; 3], 1.0, 12.5, [0.1 1 10]), ...
    'tepc:spectrum:Shape');
% 正确用法: w_stat 走 ev.w_stat / opts.w_stat 两条路必须同值
ev2 = ev;                ev2.w_stat = [1; 1; 2];
ev3 = rmfield(ev, 'weight');  ev3.w_stat = [1; 1; 2];
Dw1 = tepc.analysis.doseChain(ev2, g, cfg, rho, mass, [], struct());
Dw2 = tepc.analysis.doseChain(ev3, g, cfg, rho, mass, [], struct());
Dw3 = tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], struct('w_stat', [1; 1; 2]));
tc.verifyEqual(Dw1.D_tissue_Gy, Dw2.D_tissue_Gy, 'RelTol', 0, 'AbsTol', 0);
tc.verifyEqual(Dw1.D_tissue_Gy, Dw3.D_tissue_Gy, 'RelTol', 0, 'AbsTol', 0);
Db = tepc.analysis.doseChain(ev, g, cfg, rho, mass, [], struct('w_stat', [1; 1; 1]));
tc.verifyEqual(Dw1.D_tissue_Gy, 1.5*Db.D_tissue_Gy, 'RelTol', 1e-12, ...
    'w_stat=[1;1;2] 的分子 (10+20+60)/(10+20+30)=1.5 必须原样进入 B 链');
tc.verifyError(@() tepc.analysis.doseChain(rmfield(ev, 'weight'), g, cfg, rho, mass, [], ...
    struct()), 'tepc:dose:NoWeight');
end

% ==================== 4) 金基线: 改前实测的谱形状与剂量数值逐位复现 ====================

function test_golden_spectrum_shape_unchanged(tc)
% 下面这些数是**改动前**的同一用例实测值 (%.17g 全精度), 断言逐位不变:
% 分层与改名不允许顺手改变算法。改前该用例的 B 链累计量曾被读作 1.37e5 Gy 量级
% (10 000 事件的实跑), 那是"每事件授予能 ÷ 微位点质量"的累计值, 不是宏观剂量。
root = rootCase();
cfg = configCase(root);
R = tepc.config.resolve(cfg);
[Qfun, ~] = tepc.analysis.qualityFactor(cfg.analysis.qualityFactor, root);
E = eventsCase();
[A, ~] = tepc.analysis.analyze(E, cfg, R, Qfun);
S = A.spectrum;  D = A.dose;
got = {S.yF_exact, S.yD_exact, S.intFdy, S.intDdy, S.yF_binned, S.yD_binned, S.Qbar, ...
    S.nEff, S.SW_valid, D.D_tissue_Gy, D.D_tissue_per_event_Gy, D.D_tissue_closed_Gy, ...
    D.D_gas_Gy, D.D_gas_per_event_Gy, D.massSite_kg};
want = {42.982669180478709, 49.138396137805657, 1.0, 1.0001320256982966, ...
    42.988343997391922, 49.21363438660012, 13.524286764097811, 400, 400, ...
    12445.260739247084, 31.11315184811771, 12445.260739247087, ...
    1.3590845027701702e-06, 3.3977112569254256e-09, 7.8334567487747608e-17};
nms = {'yF_exact','yD_exact','intFdy','intDdy','yF_binned','yD_binned','Qbar','nEff', ...
    'SW_valid','D_tissue_Gy','D_tissue_per_event_Gy','D_tissue_closed_Gy','D_gas_Gy', ...
    'D_gas_per_event_Gy','massSite_kg'};
for i = 1:numel(got)
    bitwise(tc, got{i}, want{i}, ['golden ' nms{i}]);
end
fb = [81 84 86 89 91 94 96 99];
fexp = [0.0078089037809225886, 0.014895525529318042, 0.017412763405204239, ...
    0.023724956346062628, 0.019810218024374233, 0.016929067156885195, ...
    0.020698681717031566, 0.0053927789051300698];
dexp = [0.0025820436948703748, 0.0064551092371759357, 0.0090371529320464258, ...
    0.016137773092939664, 0.016137773092940025, 0.018074305864092814, ...
    0.026465947872421052, 0.0090371529320462992];
for i = 1:numel(fb)
    bitwise(tc, S.f(fb(i)), fexp(i), sprintf('f(bin %d)', fb(i)));
    bitwise(tc, S.d(fb(i)), dexp(i), sprintf('d(bin %d)', fb(i)));
end
% 改名只改名: T2 与旧每事件字段逐位同值; 定义核对式仍在 1e-12 内
bitwise(tc, D.z_mean_per_history_Gy, D.D_tissue_per_event_Gy, 'T2 == 旧 per_event 字段');
tc.verifyLessThan(abs(D.z_closed_per_history_Gy/D.z_mean_per_history_Gy - 1), 1e-12, ...
    '位点自洽时几何/单位定义核对式必须仍在 1e-12 内');
tc.verifyTrue(isnan(D.D_macro_Gy), 'demo_only.json 未带源归一链: T3 必须不可用');
end

% ==================== 5) 诚实账本 ====================

function test_bookkeeping_accompanies_every_dose(tc)
root = rootCase();
cfg = withNormalization(configCase(root));
R = tepc.config.resolve(cfg);
[Qfun, ~] = tepc.analysis.qualityFactor(cfg.analysis.qualityFactor, root);
F = tepc.domain.Flags();
E = eventsCase();
% 3 个零沉积 + 2 个被死时间拒收 (权重清零, 标志同步) —— 账本必须逐条数出来
fDead = F.DEADTIME_REJECTED;
E.ev.EdepGas_keV([1 2 3]) = 0;
E.ev.weight([5 7]) = 0;
E.ev.flags([5 7]) = fDead;
[A, ~] = tepc.analysis.analyze(E, cfg, R, Qfun);
n = E.n;
bk = A.dose.book;
tc.verifyEqual(bk.N_recorded_events, n, '记录事件数');
tc.verifyEqual(bk.N_primary_histories, n, '未登记 n_primary_histories 时按记录历史数');
tc.verifyEqual(string(bk.N_primary_histories_source), "n_recorded_histories");
tc.verifyEqual(bk.N_zero_deposition, 3, '零沉积事件数必须由剂量链自己数出来');
tc.verifyEqual(bk.N_zero_stat_weight, 2, 'w_stat 被清零的事件数');
tc.verifyEqual(bk.N_valid, n - 5, '有效事件 = 全部 - 零沉积 - 零权重');
tc.verifyEqual(bk.N_valid + bk.N_zero_deposition + bk.N_zero_stat_weight, n);
tc.verifyEqual(bk.valid_fraction, (n-5)/n, 'RelTol', 1e-12);
tc.verifyEqual(bk.zero_deposition_fraction, 3/n, 'RelTol', 1e-12);
tc.verifyGreaterThan(bk.w_stat_sum_valid, 0);
tc.verifyEqual(bk.w_stat_sum_all, sum(E.ev.weight), 'RelTol', 1e-12);
tc.verifyEqual(bk.n_eff_stat, bk.w_stat_sum_valid, 'RelTol', 1e-12, ...
    '权重全为 1 时 n_eff 必须等于有效事件数');
tc.verifyEqual(string(bk.source_normalization_status), "AVAILABLE");
tc.verifyEqual(A.liveFrac, 1 - 2/n, 'RelTol', 1e-12, '活份额必须与拒收账本同源自洽');
tc.verifyEqual(A.N_valid, bk.N_valid);
tc.verifyEqual(A.N_primary, bk.N_primary_histories);
tc.verifyEqual(A.n_zero_deposition, bk.N_zero_deposition);
tc.verifySubstring(join(string(A.dose_note), " | "), "N_hist*m_site");
tc.verifySubstring(join(string(A.dose_note), " | "), "绝不进 k_norm");
tc.verifyGreaterThan(numel(A.dose.legacy_fields), 3, '账本必须点名仍保留的旧字段');
tc.verifySubstring(join(string(A.dose.legacy_fields), " | "), "execute.m");
end

function test_dose_line_marks_macro_unavailable_instead_of_number(tc)
% 显示层: T3 不可用时打印状态与原因, 不许出现一个看起来合法的"绝对剂量"数字;
% 同时旧的分列标注回归锁 (每事件 vs 累计) 必须继续成立。
s = struct('D_gas_per_event_Gy', 1.47e-9, 'D_gas_Gy', 1.47e-5, ...
    'D_tissue_per_event_Gy', 13.67, 'D_tissue_Gy', 136715, 'nEvents', 1e4);
txt = string(tepc.report.doseLine(s));
tc.verifySubstring(txt, "1.367e+01 Gy/事件", '每事件值仍须按 Gy/事件 标注');
tc.verifySubstring(txt, "累计 1.470e-05");
tc.verifyFalse(contains(txt, "1.367e+05 Gy/事件"), '累计值不得被标成每事件');
tc.verifySubstring(txt, "宏观剂量");
tc.verifySubstring(txt, "source_normalization_undefined");
tc.verifyFalse(contains(txt, "1.367e+05 Gy (源归一已定义)"));
s2 = s;
s2.z_mean_per_history_Gy = 13.67;
s2.D_macro_Gy = 1.709e5;
s2.D_macro_reason = "";
txt2 = string(tepc.report.doseLine(s2));
tc.verifySubstring(txt2, "1.709e+05 Gy (源归一已定义)");
tc.verifySubstring(txt2, "1.367e+01 Gy/历史");
end

% ==================== 5) 归一块的形状、键名与份额上界 ====================

function test_normalization_block_shape_and_keys_are_enforced(tc)
root = rootCase();
cfg = configCase(root);
[g, rho, mass] = geomCase(root);
ev = evSmallCase();
% 畸形块不得与"整段没写"同形: 那样 k_norm 静默变 NaN, 读者只会以为配置还没填
cellBlock = cfg;
cellBlock.source.normalization = {'status', 'REFERENCE'};
tc.verifyError(@() tepc.analysis.doseChain(ev, g, cellBlock, rho, mass, [], struct()), ...
    'tepc:norm:BadBlock');
arrBlock = withNormalization(cfg);
arrBlock.source.normalization = repmat(arrBlock.source.normalization, 1, 2);
tc.verifyError(@() tepc.analysis.doseChain(ev, g, arrBlock, rho, mass, [], struct()), ...
    'tepc:norm:BadBlock');
% 拼错的因子名: 正确键仍给全, 若未知键被忽略, 配置作者改的那一处就完全不起作用
typo = withNormalization(cfg);
typo.source.normalization.source_area_mm2 = 1e-4;
tc.verifyError(@() tepc.analysis.doseChain(ev, g, typo, rho, mass, [], struct()), ...
    'tepc:norm:UnknownKey');
% 注记键不放行, 且 jsondecode 把 _source 改名成 x_source (实测): 这条同时钉住
% "混进来的键必须拒"与"我们对解码形状的认识", 两者都不许静默通过
anno = withNormalization(cfg);
% 用 jsondecode 造这个块: MATLAB 的字段语法根本不允许 s._x = v (AddField:InvalidFieldName),
% 而 "_source" 这类注记键正是从 JSON 进来的 —— 走解码路径才等于真实配置路径。
anno.source.normalization = jsondecode(['{"status":"REFERENCE","source_area_m2":1e-4,' ...
    '"acceptance_fraction":0.5,"interaction_probability":0.25,' ...
    '"_source":"用例注记, 不参与取值"}']);
fnBefore = string(fieldnames(anno.source.normalization));
msgDec = "jsondecode 对 _source 的处理与预期不同 (实得键集 " + strjoin(fnBefore, ', ') + ...
    "): 本用例的前提要跟着重定";
tc.verifyTrue(any(fnBefore == "x_source") && ~any(fnBefore == "_source"), msgDec);
tc.verifyError(@() tepc.analysis.doseChain(ev, g, anno, rho, mass, [], struct()), ...
    'tepc:norm:UnknownKey', '解码后的注记键 (x_source) 必须被白名单拒掉, 不许当成缺位静默吞下');
end

function test_fraction_upper_bounds_are_enforced(tc)
% f_geo 按半空间 2*pi sr 归一、p_int 是概率: 上界 1 由定义给出, 不是经验阈值。
root = rootCase();
cfg = configCase(root);
[g, rho, mass] = geomCase(root);
ev = evSmallCase();
geo5 = withNormalization(cfg, 'acceptance_fraction', 5);
tc.verifyError(@() tepc.analysis.doseChain(ev, g, geo5, rho, mass, [], struct()), ...
    'tepc:norm:BadRange');
pint2 = withNormalization(cfg, 'interaction_probability', 2);
tc.verifyError(@() tepc.analysis.doseChain(ev, g, pint2, rho, mass, [], struct()), ...
    'tepc:norm:BadRange');
edge = withNormalization(cfg, 'acceptance_fraction', 1, 'interaction_probability', 1);
D = tepc.analysis.doseChain(ev, g, edge, rho, mass, [], struct());
tc.verifyFalse(isnan(D.k_norm), 'f_geo=p_int=1 的极限配置必须放行 (半空间 + 必然作用)');
tc.verifyEqual(D.k_norm, double(cfg.source.fluence_m2) * 1e-4, 'RelTol', 1e-12, ...
    '极限配置的 k_norm 必须退化成 Phi*A_eff (两个份额都取 1)');
end

function test_macro_reason_reaches_the_report_line(tc)
% 生产链必须把"为什么不可用"传到显示层: summary 不带 D_macro_reason 时 doseLine 只能
% 打印自己的兜底串, 于是"因子齐了但状态没声明"被误诊成"因子缺位" —— 读者会去补 A_eff,
% 而真正缺的是 status 那一行。
s = struct('D_gas_per_event_Gy', 1.47e-9, 'D_gas_Gy', 1.47e-5, ...
    'z_mean_per_history_Gy', 13.67, 'nEvents', 1e4, 'D_macro_Gy', NaN, ...
    'D_macro_reason', "source_normalization_status_not_declared");
txt = string(tepc.report.doseLine(s));
tc.verifySubstring(txt, "source_normalization_status_not_declared");
tc.verifyFalse(contains(txt, "source_normalization_undefined"), ...
    '真实原因被 doseLine 的兜底串顶掉了');
root = tepc.io.projectRoot();
% 真跑一次小样本: 锁的是"生产链把原因带到 summary, 再由 doseLine 打出来"这一整条路,
% 而不是 doseLine 自己的分支。发货配置没有 source.normalization 块 => 原因必须点名缺的
% 是哪几个因子, 否则读者只看到一句笼统的"未定义"。
cfgRun = configCase(root);
R = tepc.run.execute(cfgRun, 'N', 40, 'Seed', 4242);
tc.verifyTrue(isfield(R.summary, 'D_macro_reason'), ...
    'summary 里没有 D_macro_reason: 报告层只能打印 doseLine 的兜底原因');
rs = string(R.summary.D_macro_reason);
tc.verifyTrue(startsWith(rs, "source_normalization_undefined"), ...
    sprintf('发货配置无归一块, 原因串应以 source_normalization_undefined 开头, 实得 %s', rs));
tc.verifySubstring(rs, "source_area_m2");
tc.verifySubstring(char(tepc.report.doseLine(R.summary)), "source_area_m2", ...
    '剂量行没带上真实原因');
end

% ==================== 本地构造 (首参不是 tc, 名字不以 test_ 开头) ====================

function bitwise(tcase, got, want, nm)
% 逐位相等判据: RelTol/AbsTol 均取 0, 任何一比特不同都算红。
tcase.verifyEqual(got, want, 'RelTol', 0, 'AbsTol', 0, sprintf('%s 不是逐位相同', nm));
end

function cfg = configCase(root)
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
end

function cfg = withFluence(cfg, flu)
cfg.source.fluence_m2 = flu;
end

function cfg = withNormalization(cfg, varargin)
% 完整源归一链: Phi 取 cfg.source.fluence_m2, 其余因子在此给定。
% 默认 A_eff=1e-4 m^2, f_geo=0.5, p_int=0.25, status=REFERENCE。
% varargin 成对: 字段名 + 值; 传 [] 表示该字段缺位 (模拟 JSON null)。
dflt = struct('status', 'REFERENCE', 'source_area_m2', 1e-4, ...
    'acceptance_fraction', 0.5, 'solid_angle_sr', [], ...
    'interaction_probability', 0.25, 'n_primary_histories', []);
for i = 1:2:numel(varargin)
    dflt.(varargin{i}) = varargin{i+1};
end
nm = fieldnames(dflt);
nb = struct();
for i = 1:numel(nm)
    if ~isempty(dflt.(nm{i}))
        nb.(nm{i}) = dflt.(nm{i});
    end
end
cfg.source.normalization = nb;
end

function cases = mkCases(varargin)
% struct 数组预分配后逐项填 (不用 struct('cfg',cfg,...): 值本身是 struct 时会字段展开)
names = ["no_normalization_block", "explicit_NOT_AVAILABLE", "fluence_nan", ...
    "area_field_empty", "factors_complete_but_status_off"];
cases = repmat(struct('name', "", 'cfg', []), 1, numel(varargin));
for i = 1:numel(varargin)
    cases(i).name = names(i);
    cases(i).cfg = varargin{i};
end
end

function [g, rho, mass] = geomCase(root)
cfg = configCase(root);
g = tepc.geometry.buildGeometry(cfg);
[rho, ~] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, cfg.gas.temperature_K, ...
    cfg.gas.composition_molfrac, 1.0);
mass = rho*g.V_m3;
end

function ev = evSmallCase()
% 3 条历史: eps=[10;20;30] keV, y=eps/lbar 且 lbar=2d/3 (与位点定义自洽), 权重全 1。
d_t = 2e-6;
eps = [10; 20; 30];
ev = struct('EdepGas_keV', eps, 'y_keV_per_um', eps/(d_t*2/3*1e6), ...
    'weight', ones(3,1), 'flags', [0; 0; 0]);
end

function e = epsVectorCase()
rs = RandStream('Threefry', 'Seed', 11);
e = 0.2 + 9.8*rand(rs, 5000, 1);
end

function E = eventsCase()
% 与金基线抓数时同一配方: N=400, Threefry 种子 7, 权重全 1, 不走标定链。
N = 400;
E = tepc.domain.EventBatch.preallocate(N);
rs = RandStream('Threefry', 'Seed', 7);
E.ev.eventID        = (1:N)';
E.ev.EdepGas_keV    = 5 + 20*rand(rs, N, 1);
E.ev.gasPath_um     = 100 + 50*rand(rs, N, 1);
E.ev.t0_s           = (0:N-1)'*0.01;
E.ev.weight         = ones(N, 1);
E.ev.flags          = zeros(N, 1, 'uint32');
E.ev.model_id       = uint16(ones(N, 1));
E.ev.Esecondary_keV = E.ev.EdepGas_keV;
end

function r = rootCase()
r = tepc.io.projectRoot();
end
