function tests = test_validation_gof_chord
%TEST_VALIDATION_GOF_CHORD 弦长分布对闭式 CDF 的拟合优度检验 (KS/AD) 与其可信性。
%
% 均值落在 3u_stat 里只说明"一阶矩对", 换一条同样均值、形状完全不同的分布也能过;
% 这里锁的是**整条分布**的判据, 并且同时锁住判据自身的三件事:
%   1) 参照分布来自同一闭式的逆 CDF, 不经过 sampleChord —— 否则抽样器的错会被自己抵消;
%   2) 判据可失败 (错模式/整体偏移必须拒绝), p 值有 MC 下限但不是 0;
%   3) p 值经过校准: 从同一闭式反复抽样时, 拒绝率与 p 值均值都应在名义水平附近。
tests = functiontests(localfunctions);
end

%% ==================== (a) 两条模式的实测弦样不拒绝 ====================

function test_external_chords_match_closed_form_cdf(tc)
[o, L] = gofOfMode("isotropic_external");
txt = sprintf('%s: D=%.5f pKS=%.4f A2=%.3f pAD=%.4f (alpha=%.2f)', ...
    o.mode, o.ksStat, o.ksP, o.adStat, o.adP, o.alpha);
tc.verifyGreaterThan(o.ksP, o.alpha, ['各向同性外源弦 KS 被拒绝 ' txt]);
tc.verifyGreaterThan(o.adP, o.alpha, ['各向同性外源弦 AD 被拒绝 ' txt]);
tc.verifyLessThan(abs(o.meanZ), 3, '均值应落在 3 倍标准误内');
% 4V/S 口径: 外源均值闭式必须与几何解析值同一条 (两条口径不许各说各话)
g = buildSphere();
tc.verifyEqual(o.meanExact, 4*g.R_m/3, 'RelTol', 1e-12);
tc.verifyEqual(o.meanExact, tepc.geometry.meanChordLength(g), 'RelTol', 1e-9, ...
    '检验用的均值闭式与几何侧 4V/S 不一致: 两条真相源');
tc.verifyEqual(numel(L), o.nInput, '样本量在进检验前被改动');
end

function test_internal_chords_match_closed_form_cdf(tc)
[o, ~] = gofOfMode("internal_isotropic");
txt = sprintf('%s: D=%.5f pKS=%.4f A2=%.3f pAD=%.4f', ...
    o.mode, o.ksStat, o.ksP, o.adStat, o.adP);
tc.verifyGreaterThan(o.ksP, o.alpha, ['体内各向同性源 KS 被拒绝 ' txt]);
tc.verifyGreaterThan(o.adP, o.alpha, ['体内各向同性源 AD 被拒绝 ' txt]);
tc.verifyLessThan(abs(o.meanZ), 3, '均值应落在 3 倍标准误内');
g = buildSphere();
tc.verifyEqual(o.meanExact, 0.75*g.R_m, 'RelTol', 1e-12);
end

%% ==================== (b) 判据可失败 ====================

function test_wrong_mode_negative_control_rejects(tc)
% 内源弦样拿去比外源 CDF: 两条闭式均值差 16% 且形状不同, 必须拒绝。
g = buildSphere();
rs = RandStream('Threefry', 'Seed', 7);
L = tepc.geometry.sampleChord(g, 2e4, "internal_isotropic", rs);
o = tepc.validation.gofChord(L, g.R_m, "isotropic_external", 'MC', 200);
tc.verifyTrue(o.rejectKs, sprintf('错模式没被 KS 拒绝: pKS=%.5f', o.ksP));
tc.verifyTrue(o.rejectAd, sprintf('错模式没被 AD 拒绝: pAD=%.5f', o.adP));
end

function test_shifted_sample_rejects_and_p_has_mc_floor(tc)
% 整体平移 (支撑集被破坏) 也必须拒绝; 同时 p 值下限是 1/(1+MC) 而不是 0 ——
% 这条锁住"p=0 不可能出现"的报告口径, 免得读者把最小 p 当成"绝对排除"。
g = buildSphere();
rs = RandStream('Threefry', 'Seed', 11);
L = tepc.geometry.sampleChord(g, 4000, "isotropic_external", rs);
L2 = L + 0.05*g.R_m;
o = tepc.validation.gofChord(L2, g.R_m, "isotropic_external", 'MC', 200);
tc.verifyTrue(o.reject, sprintf('平移后的样本未被拒绝: pKS=%.5f pAD=%.5f', o.ksP, o.adP));
floorP = 1/(1 + 200);
% 落在 1/(1+MC) 这一格上才是"参照里没有一个统计量比观测更极端"。用**等式**而不是"下限之上":
% 后者 (>= 1/(1+MC)) 由 p 的构造式保证, 永远为真, 测不到任何回归。
tc.verifyEqual(o.ksP, floorP, 'AbsTol', 0, ...
    sprintf('KS p 不在 MC 下限那一格 (%.6f): 参照或分母写法变了', floorP));
tc.verifyEqual(o.adP, floorP, 'AbsTol', 0, ...
    sprintf('AD p 不在 MC 下限那一格 (%.6f)', floorP));
end

function test_ks_statistic_matches_hand_computed_value(tc)
% 三个点的小样本, D_n 可以手算: R=1 => F(l) = (l/2)^2, x=[0.5 1 1.5] 给 F=[0.0625 .25 .5625]。
%   D+ = max(i/n - F_i) = 1 - 0.5625 = 0.4375;  D- = max(F_i - (i-1)/n) = 0.0625;  D = 0.4375。
% 双侧两项的下标错位方向若写反, 只剩被支配项 (这里会得到 0.1042, 甚至可能是负数)。
% 参照走同一条式子, 所以 p 值看不出这个错 —— 只有把 D_n 钉到可手算的数字上才拦得住。
o = tepc.validation.gofChord([0.5; 1; 1.5], 1, "isotropic_external", 'MC', 100);
tc.verifyEqual(o.ksStat, 0.4375, 'AbsTol', 1e-15, ...
    sprintf('D_n 与手算值 0.4375 不符 (实得 %.6f): 双侧 KS 的下标方向错了', o.ksStat));
tc.verifyGreaterThanOrEqual(o.ksStat, 0);
tc.verifyLessThanOrEqual(o.ksStat, 1);
tc.verifyGreaterThanOrEqual(o.adStat, 0);
end

function test_test_side_formula_agrees_with_function_reference(tc)
% 测试自己按闭式逆 CDF 造一批样本喂进去: 若函数内部参照用的不是同一条闭式,
% 统计量会被系统性抬高而拒绝。这条把"两处公式必须同一条"钉住。
g = buildSphere();
rs = RandStream('philox', 'Seed', 3);
u = rand(rs, 2000, 1);
x = 2*g.R_m*sqrt(u);
o = tepc.validation.gofChord(x, g.R_m, "isotropic_external", 'MC', 200, 'MaxN', 2000);
tc.verifyFalse(o.reject, sprintf('同闭式造的样本被自己的参照拒绝: pKS=%.4f pAD=%.4f', ...
    o.ksP, o.adP));
end

%% ==================== (c) 校准与可复现 ====================

function test_p_values_are_calibrated(tc)
% 20 批独立同闭式样本: 名义 alpha=0.05 时拒绝率不应显著偏离, p 值均值不应偏向两端。
% 全部固定种子 => 这一条是确定性的, 不会随机翻绿。
g = buildSphere();
rs = RandStream('philox', 'Seed', 991);
nB = 20;
p = zeros(nB, 1);
for k = 1:nB
    u = rand(rs, 1200, 1);
    ok = tepc.validation.gofChord(2*g.R_m*sqrt(u), g.R_m, "isotropic_external", ...
        'MC', 150, 'Seed', 1000 + k, 'MaxN', 1200);
    p(k) = ok.ksP;
end
frac = mean(p < 0.05);
tc.verifyLessThanOrEqual(frac, 0.25, ...
    sprintf('p 值校准崩了: %d 批里拒绝率 %.2f (名义 0.05)', nB, frac));
tc.verifyGreaterThan(mean(p), 0.25, ...
    sprintf('p 值系统性偏小 (均值 %.3f): 参照分布比样本窄', mean(p)));
tc.verifyLessThan(mean(p), 0.85, ...
    sprintf('p 值系统性偏大 (均值 %.3f): 参照分布比样本宽', mean(p)));
end

function test_closed_forms_match_their_pdf_by_quadrature(tc)
% 闭式 CDF 必须与**另一份独立表示**一致: pdf (外源由撞击参数均匀性导出, 内源是 sampleChord
% 头注里那条倒抛物线) 数值积分回来就是 CDF。只信函数内部那一个 lambda 等于自己验自己。
R = 1; l = linspace(0, 2*R, 40001).';
pExt = l/(2*R^2);
pInt = (3/(4*R^3))*(R^2 - l.^2/4);
Fe = cumtrapz(l, pExt);
Fi = cumtrapz(l, pInt);
tc.verifyEqual(Fe(end), 1, 'AbsTol', 1e-9, '外源 pdf 积不到 1: pdf 与支撑不匹配');
tc.verifyEqual(Fi(end), 1, 'AbsTol', 1e-9, '内源 pdf 积不到 1: pdf 与支撑不匹配');
q = [0.25 0.5 0.75 1.0 1.5 1.9].';
tc.verifyEqual(interp1(l, Fe, q), (q/(2*R)).^2, 'AbsTol', 1e-6);
tc.verifyEqual(interp1(l, Fi, q), 1.5*(q/(2*R)) - 0.5*(q/(2*R)).^3, 'AbsTol', 1e-4);
% 两条闭式的均值 (4R/3 与 3R/4) 也从 pdf 积分回来, 与 gofChord 报的 meanExact 同一条
tc.verifyEqual(trapz(l, l.*pExt), 4*R/3, 'AbsTol', 1e-6);
tc.verifyEqual(trapz(l, l.*pInt), 3*R/4, 'AbsTol', 1e-6);
end

function test_internal_reference_is_calibrated_too(tc)
% 内源模式的逆 CDF 是三次方程的三角解, 与外源的 sqrt 完全不同一条式子; 外源那个校准用例
% 覆盖不到它。根取错 -> 参照与样本不同分布 -> p 值立刻系统性偏掉, 所以这里按同一条闭式
% 造 20 批样本看拒绝率与 p 值均值。
g = buildSphere();
rs = RandStream('philox', 'Seed', 77);
nB = 20;
p = zeros(nB, 1);
for k = 1:nB
    u = rand(rs, 1200, 1);
    t = 2*cos(acos(-u)/3 - 2*pi/3);
    ok = tepc.validation.gofChord(2*g.R_m*t, g.R_m, "internal_isotropic", ...
        'MC', 150, 'Seed', 2000 + k, 'MaxN', 1200);
    p(k) = ok.ksP;
end
tc.verifyLessThanOrEqual(mean(p < 0.05), 0.25, ...
    sprintf('内源参照没校准: %d 批里拒绝了 %.0f%%', nB, 100*mean(p < 0.05)));
tc.verifyGreaterThan(mean(p), 0.25, sprintf('内源 p 值系统性偏小 (均值 %.3f)', mean(p)));
tc.verifyLessThan(mean(p), 0.85, sprintf('内源 p 值系统性偏大 (均值 %.3f)', mean(p)));
end

function test_same_inputs_give_bitwise_same_outputs(tc)
g = buildSphere();
rs = RandStream('Threefry', 'Seed', 5);
L = tepc.geometry.sampleChord(g, 3000, "isotropic_external", rs);
a = tepc.validation.gofChord(L, g.R_m, "isotropic_external", 'MC', 150);
b = tepc.validation.gofChord(L, g.R_m, "isotropic_external", 'MC', 150);
tc.verifyEqual(a.ksStat, b.ksStat, 'AbsTol', 0);
tc.verifyEqual(a.adStat, b.adStat, 'AbsTol', 0);
tc.verifyEqual(a.ksP, b.ksP, 'AbsTol', 0);
tc.verifyEqual(a.adP, b.adP, 'AbsTol', 0);
tc.verifyEqual(a.referenceSeedStream, b.referenceSeedStream, '参照流标识不一致');
end

function test_stride_subsampling_bounds_reference_and_keeps_mean(tc)
g = buildSphere();
rs = RandStream('Threefry', 'Seed', 13);
L = tepc.geometry.sampleChord(g, 20000, "isotropic_external", rs);
o = tepc.validation.gofChord(L, g.R_m, "isotropic_external", 'MC', 150, 'MaxN', 4000);
tc.verifyEqual(o.nInput, 20000, 'AbsTol', 0);
tc.verifyEqual(o.nUsed, 4000, 'AbsTol', 0);
tc.verifyEqual(o.stride, 5, 'AbsTol', 0);
tc.verifyEqual(o.meanMeasured, mean(L(:)), 'RelTol', 0, '均值口径应当用全样本而非子样');
small = tepc.validation.gofChord(L(1:800), g.R_m, "isotropic_external", 'MC', 150);
tc.verifyEqual(small.stride, 1, 'AbsTol', 0, '样本未超 MaxN 时不该降采样');
tc.verifyEqual(small.nUsed, 800, 'AbsTol', 0);
% "定步长降采样"的前提是样本可交换, 这条前提本身要可核: 子样均值与全样本均值的偏离应在子样
% 标准误内。哪天 sampleChord 改成先排序或按层拼接, 定步长就变成按分位数取点, 统计量被压到
% 最小值、p 恒为 1, 判据会静默失效 —— 这一条就是那块的哨兵。
se = std(L)/sqrt(o.nUsed);
tc.verifyLessThanOrEqual(abs(o.meanMeasured - mean(L(1:o.stride:end))), 4*se, ...
    '定步长子样均值偏离全样本过多: 样本已不可交换, 降采样口径失效');
end

function test_ad_correction_formula_field_matches_stated_n(tc)
g = buildSphere();
rs = RandStream('Threefry', 'Seed', 17);
L = tepc.geometry.sampleChord(g, 5000, "isotropic_external", rs);
o = tepc.validation.gofChord(L, g.R_m, "isotropic_external", 'MC', 150, 'MaxN', 2000);
want = o.adStat*(1 + 0.75/o.nUsed + 2.25/o.nUsed^2);
tc.verifyEqual(o.adStatCorrected, want, 'RelTol', 1e-12);
tc.verifyGreaterThan(o.adStat, 0, 'AD 统计量应为正');
end

%% ==================== (d) 入口校验 ====================

function test_input_validation_rejects_bad_arguments(tc)
g = buildSphere();
x = linspace(0.01, 0.02, 10).';
tc.verifyError(@() tepc.validation.gofChord(x, 0, "isotropic_external"), ...
    'tepc:validation:BadGoFSphereRadius');
tc.verifyError(@() tepc.validation.gofChord(x, NaN, "isotropic_external"), ...
    'tepc:validation:BadGoFSphereRadius');
tc.verifyError(@() tepc.validation.gofChord(x(1:2), g.R_m, "isotropic_external"), ...
    'tepc:validation:BadGoFSample');
tc.verifyError(@() tepc.validation.gofChord(x, g.R_m, "anisotropic"), ...
    'tepc:validation:BadGoFMode');
tc.verifyError(@() tepc.validation.gofChord(x, g.R_m, "isotropic_external", 'MC', 50), ...
    'tepc:validation:BadGoFOption');
tc.verifyError(@() tepc.validation.gofChord(x, g.R_m, "isotropic_external", 'Alpha', 0), ...
    'tepc:validation:BadGoFOption');
tc.verifyError(@() tepc.validation.gofChord(x, g.R_m, "isotropic_external", 'MaxN', 'big'), ...
    'tepc:validation:BadGoFOption');
end

%% ==================== 辅助 (不得以 test 开头) ====================

function [o, L] = gofOfMode(mode)
g = buildSphere();
rs = RandStream('Threefry', 'Seed', 42);
L = tepc.geometry.sampleChord(g, 2e4, mode, rs);
o = tepc.validation.gofChord(L, g.R_m, mode, 'MC', 300);
end

function g = buildSphere()
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
g = tepc.geometry.buildGeometry(cfg);
end
