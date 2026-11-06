function tests = test_run_threshold_disclosure
%TEST_RUN_THRESHOLD_DISCLOSURE 阈下截断披露字段的账本与语义锁。
%   发布矩只覆盖"过阈且测量有效"的事件群, 而真值谱原先建在同一群上, 于是截断偏差
%   在字段层面是结构性不可见的 (两边一起变小, 相减为零)。本文件锁三件事:
%     1) 披露字段齐全且口径写进 summary, 不靠读者推断;
%     2) 偏差值与三个**分别发布**的字段互相自洽 (任一处接错即红);
%     3) 有阈下损失时发布 y_F 必须**高于**全历史真值 (被排除的是低 y 事件)。
%   第 3 条是物理方向判据而不是恒等式复述: 若哪天截断改成保留低 y 事件, 它会反过来报警。
tests = functiontests(localfunctions);
end

function s = cachedSummary(tc)
persistent R0
if isempty(R0)
    root = tepc.io.projectRoot();
    cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
    cfg.uq.enabled = false;
    R0 = tepc.run.execute(cfg, 'N', 250, 'Seed', 12345);
end
s = R0.summary;
end

function test_disclosure_fields_present(tc)
s = cachedSummary(tc);
need = {'threshold_lost_count', 'threshold_lost_fraction', 'n_published_moments', ...
    'n_truth_all', 'yF_truth_all_keV_um', 'yD_truth_all_keV_um', ...
    'threshold_truncation_bias_rel_yF', 'threshold_truncation_bias_rel_yD', ...
    'published_moment_population'};
miss = need(~ismember(need, fieldnames(s)'));
tc.verifyEmpty(miss, sprintf('summary 缺少阈下披露字段: %s', strjoin(miss, ', ')));
tc.verifyTrue(contains(string(s.published_moment_population), '有效'), ...
    'published_moment_population 没有说明矩建在哪个事件群上');
end

function test_populations_are_consistent(tc)
s = cachedSummary(tc);
tc.verifyGreaterThanOrEqual(s.n_published_moments, 0);
tc.verifyLessThanOrEqual(s.n_published_moments, s.nEvents, '有效事件数不可能超过历史数');
tc.verifyLessThanOrEqual(s.n_truth_all, s.nEvents, '全历史真值群不可能大于历史数');
tc.verifyEqual(s.threshold_lost_fraction, s.threshold_lost_count/s.nEvents, 'RelTol', 1e-12, ...
    'threshold_lost_fraction 与 count/N 不一致');
tc.verifyTrue(all(isfinite([s.yF_truth_all_keV_um, s.yD_truth_all_keV_um])), ...
    '全历史真值矩非有限');
tc.verifyGreaterThan(s.yD_truth_all_keV_um, s.yF_truth_all_keV_um, ...
    '同一群上 y_D 必须大于 y_F (否则剂量加权接错)');
end

function test_bias_matches_published_fields(tc)
s = cachedSummary(tc);
pred = s.yF_keV_um / s.yF_truth_all_keV_um - 1;
tc.verifyLessThan(abs(s.threshold_truncation_bias_rel_yF - pred), 1e-9, sprintf( ...
    '发布的偏差 %.10g 与 (yF_keV_um/yF_truth_all - 1)=%.10g 不一致: 三字段有一处接错', ...
    s.threshold_truncation_bias_rel_yF, pred));
end

function test_bias_sign_follows_truncation(tc)
s = cachedSummary(tc);
if s.threshold_lost_count == 0
    tc.verifyEqual(s.threshold_truncation_bias_rel_yF, 0, 'AbsTol', 1e-9, ...
        '无阈下损失时偏差应为零');
    tc.verifyTrue(true, '本次运行无阈下损失, 方向判据不适用');
    return
end
tc.verifyGreaterThan(s.threshold_truncation_bias_rel_yF, 0, sprintf( ...
    '有 %d 个阈下事件被排除, 发布 y_F 却不高於全历史真值 (偏差 %.4g): 截断方向或群定义变了', ...
    s.threshold_lost_count, s.threshold_truncation_bias_rel_yF));
end
