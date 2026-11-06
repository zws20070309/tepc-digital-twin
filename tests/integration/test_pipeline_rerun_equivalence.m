function tests = test_pipeline_rerun_equivalence
%TEST_PIPELINE_RERUN_EQUIVALENCE 集成: 需要**多次完整 run** 的等价性判据。
%   为什么从 test_pipeline.m 里搬出来 (实测, 不是审美):
%   test_pipeline.m 11 条用例单文件墙钟实测 858.1 s (2026-09-30, 见
%   docs/performance_tiers.md 同档位的 min 834 / med 889), 而全树认证的预算是
%   按"文件"粒度记账的 —— 单文件越胖, 一次预算内能收口的文件越少, 越容易在
%   跑到一半时被停掉 (NOT_CERTIFIED/BUDGET_STOPPED)。这两条用例合计要付
%   6 次 tepc.run.execute, 是整个文件里固定开销 (实测每次 run 约 28.9 s) 最密的地方,
%   所以把它们单独成文件: 两个文件的耗时因此可分别计时, 判据本身一字未改。
%   刻意**不**合并两条用例共用一次 run —— 那会削弱"换 seed 必须改变发布谱"与
%   "续跑位精确"各自独立的断言, 属于降低覆盖而不是省时。
tests = functiontests(localfunctions);
end

function test_reproducibility(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
R1 = tepc.run.execute(cfg, 'N', 600, 'Seed', 777);
R2 = tepc.run.execute(cfg, 'N', 600, 'Seed', 777);
tc.verifyEqual(R1.analysis.spectrum.yF_exact, R2.analysis.spectrum.yF_exact);
tc.verifyEqual(R1.analysis.spectrum.counts_weight, R2.analysis.spectrum.counts_weight);
tc.verifyEqual(R1.summary.instr_bias_yF, R2.summary.instr_bias_yF, ...
    '刻度偏差也须逐位可复现');
tc.verifyEqual(R1.analysis.dose.D_tissue_Gy, R2.analysis.dose.D_tissue_Gy);
R3 = tepc.run.execute(cfg, 'N', 600, 'Seed', 778);
% verifyNotEqual 不接受 'AbsTol' 等名值参 (实测抛 MATLAB:narginchk:tooManyInputs)
% -> 写成显式判据, 并把"变了多少"说清楚: 换 seed 必须让发布量真正改变。
dYF = abs(R3.analysis.spectrum.yF_exact - R1.analysis.spectrum.yF_exact);
tc.verifyGreaterThan(dYF, 1e-12, '换 seed 必须改变发布谱 (否则 seed 未真正进入抽样)');
tc.verifyGreaterThan(dYF/R1.analysis.spectrum.yF_exact, 1e-9, '相对变化须远大于数值噪声');
dBias = abs(R3.summary.instr_bias_yF - R1.summary.instr_bias_yF);
tc.verifyGreaterThan(dBias, 1e-12, '刻度偏差也须随 seed 改变');
end

function test_resume_bit_exact(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
rd3 = fullfile(tempdir, sprintf('tepc_resume_%d', randi(1e9)));
R1 = tepc.run.execute(cfg, 'N', 2000, 'Seed', 777);
tepc.run.execute(cfg, 'N', 1000, 'Seed', 777, 'RunDir', rd3);
R3 = tepc.run.execute(cfg, 'N', 2000, 'Seed', 777, 'RunDir', rd3, 'Resume', true);
tc.verifyEqual(R3.summary.resumed_from, 1000);
tc.verifyEqual(R3.summary.nEvents, 2000);
tc.verifyEqual(R3.analysis.spectrum.yF_exact, R1.analysis.spectrum.yF_exact, ...
    '续跑应位精确重建同 seed 全跑');
tc.verifyEqual(R3.analysis.spectrum.yD_exact, R1.analysis.spectrum.yD_exact);
rmdir(rd3, 's');
end
