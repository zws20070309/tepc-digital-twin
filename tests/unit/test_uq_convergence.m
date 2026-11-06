function tests = test_uq_convergence
%TEST_UQ_CONVERGENCE 抽样数收敛阶梯的接口契约 + 模型形式项的闭式核对。
%   模型形式项走 Cauchy 弦长定理, 有手算值可钉: 球 4R/3, 等体积等径高圆柱 4r/3 且
%   r = R(2/3)^(1/3) => 比值 (2/3)^(1/3) = 0.8735804647, 相对差 0.1264195353。
%   1/sqrt(N) 律在小 N 上不可当门禁 (标准差自身的相对抽样噪声 ~1/sqrt(2(N-1))), 所以
%   这里只钉"比值算对了、方向性记下来了", 不钉"u 必须单调下降"。
tests = functiontests(localfunctions);
end

function cfg = demoCfg()
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
end

%% ==================== 1. 模型形式项必须有手算值可核 ====================

function test_model_form_matches_cauchy_closed_form(tc)
out = tepc.uq.convergence(demoCfg(), 'Samples', [2 4], 'NEvPerSample', 8);
mf = out.model_form;
want = (2/3)^(1/3);
tc.verifyEqual(mf.ratio, want, 'RelTol', 1e-12, ...
    sprintf('弦长比应等于 (2/3)^(1/3)=%.10f, 实得 %.10f', want, mf.ratio));
tc.verifyEqual(mf.closed_form_ratio, want, 'RelTol', 1e-15);
tc.verifyEqual(mf.rel_gap, 1 - want, 'AbsTol', 1e-12, ...
    sprintf('相对差应约 0.1264195, 实得 %.7f', mf.rel_gap));
% 球的 4V/S 手算核对 (R=1 => 4/3), 且必须与几何层的独立实现同值
tc.verifyEqual(mf.lbar_sphere_m, 4/3, 'RelTol', 1e-12);
tc.verifyEqual(mf.lbar_cylinder_m, 4/3 * want, 'RelTol', 1e-12, ...
    '圆柱侧应等于 4r/3, r = R(2/3)^(1/3)');
tc.verifyGreaterThan(mf.lbar_cylinder_m, 0);
tc.verifyLessThan(mf.lbar_cylinder_m, mf.lbar_sphere_m, ...
    '等体积下圆柱的平均弦长必须更短 (表面积更大)');
end

function test_model_form_states_what_it_is_not(tc)
% 这条钉的是措辞边界: 弦长比不是 y_F 的模型形式项, 未来谁把它当 y_F 用就会红。
out = tepc.uq.convergence(demoCfg(), 'Samples', [2 4], 'NEvPerSample', 8);
b = strjoin(string(out.model_form.basis), " | ");
tc.verifyTrue(contains(b, "不是 y_F"), ...
    sprintf('basis 里必须明说本项不是 y_F 的模型形式项, 实得 %s', b));
tc.verifyTrue(contains(b, "Cauchy"), '要给出弦长定理的适用条件 (凸体 + 各向同性直线场)');
end

%% ==================== 2. 阶梯的比值与噪声参照 ====================

function test_ladder_reports_ratios_and_noise(tc)
Ns = [4 8 16];
out = tepc.uq.convergence(demoCfg(), 'Samples', Ns, 'NEvPerSample', 20, 'Seed', 77);
L = out.ladder;
tc.verifyEqual(numel(L), 3);
tc.verifyEqual([L.N], Ns);
tc.verifyTrue(all(isfinite([L.u_yF_rel])) && all([L.u_yF_rel] > 0), ...
    '每级的相对标准不确定度必须是有限正数');
tc.verifyTrue(isnan(L(1).expected_ratio), '第一级没有前项可比, 参照必须是 NaN 而不是 1');
tc.verifyEqual(L(2).expected_ratio, sqrt(4/8), 'RelTol', 1e-12);
tc.verifyEqual(L(3).expected_ratio, sqrt(8/16), 'RelTol', 1e-12);
tc.verifyTrue(isnan(L(1).observed_ratio), '第一级没有前项可比, 实得比必须是 NaN');
% NaN 参与 RelTol 比较会整体判假, 所以逐级单独比而不是拼成向量比
% observed_ratio 现在是**标准误**的相邻比; u_level_ratio 才是 CV 的相邻比 (参照 1)
tc.verifyEqual(L(2).observed_ratio, (L(2).se_yF_rel / L(1).se_yF_rel), 'RelTol', 1e-12);
tc.verifyEqual(L(3).observed_ratio, (L(3).se_yF_rel / L(2).se_yF_rel), 'RelTol', 1e-12);
tc.verifyEqual(L(2).u_level_ratio, L(2).u_yF_rel / L(1).u_yF_rel, 'RelTol', 1e-12);
tc.verifyTrue(isnan(L(1).u_level_ratio), '第一级 CV 比没有前项, 必须是 NaN');
for k = 2:numel(L)
    tc.verifyEqual(L(k).se_yF_rel, L(k).u_yF_rel / sqrt(L(k).N), 'RelTol', 1e-12, ...
        sprintf('第 %d 级 se 不等于 u/sqrt(N)', k));
end
% 噪声参照 = 1/sqrt(2(N-1)): 这是"为什么不能拿渐近律当小 N 门禁"的定量依据
tc.verifyEqual(L(2).noise_ref, 1/sqrt(2*7), 'RelTol', 1e-12);
tc.verifyTrue(all(arrayfun(@(k) abs(L(k).noise_ref - 1/sqrt(2*(Ns(k)-1))) < 1e-12, ...
    1:numel(Ns))), 'noise_ref 与正态母体标准差估计的相对噪声不同式');
tc.verifyTrue(isa([L.within_slack], 'logical') || ...
        all(arrayfun(@(k) islogical(L(k).within_slack), 1:numel(Ns))), ...
    'within_slack 必须是逻辑量, 不能是字符串标记');
tc.verifyEqual(out.total_samples, 28);
end

%% ==================== 3. 负控: 参数与成本护栏 ====================

function test_argument_and_cost_guards(tc)
cfg = demoCfg();
tc.verifyError(@() tepc.uq.convergence(cfg, 'Samples', [4 2]), 'tepc:uq:BadSamples', ...
    '非递增阶梯必须被拒');
tc.verifyError(@() tepc.uq.convergence(cfg, 'Samples', [2.5 4]), 'tepc:uq:BadSamples', ...
    '非整数样本数必须被拒');
tc.verifyError(@() tepc.uq.convergence(cfg, 'Samples', [2 4], 'CostCap', 3), ...
    'tepc:uq:TooExpensive', '成本护栏必须能拦住阶梯 (否则 CI 里会跑出几十分钟的用例)');
tc.verifyError(@() tepc.uq.convergence(cfg, 'Samplez', [2 4]), 'tepc:uq:Args', ...
    '拼错的参数名不得被静默忽略');
tc.verifyError(@() tepc.uq.convergence(cfg, 'Seed'), 'tepc:uq:Args', ...
    '落单的 Name-Value 必须被拒');
end
