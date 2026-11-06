function tests = test_field_electrostatic_gate
%TEST_FIELD_ELECTROSTATIC_GATE 静电场精度门禁的咬合力与解析场的逐位回归锁。
%   覆盖 tepc.field.solveElectrostatic / tepc.field.fieldMap 两条此前无测试的路径:
%     (1) 门禁: 六条判据的阈值必须来自 docs/constants.json (代码里不留字面量), 每条
%         判据都得有**非零实测值**且落在阈值内; 同一套判据在粗网格上必须抛
%         tepc:field:AccuracyGateFailed (负对照, 证明它不是装饰)。
%     (2) 解析路径 (field.mode="analytic" 的缺省产物): 闭式采样容器的每个数组按
%         uint64 字节流做 SHA-256, 与下面硬编码的基准逐位比对 —— 1 ulp 的变化就会
%         改哈希。负对照在测试内故意把最后一个元素加一个 eps, 证明比对真的会红。
%     (3) mesh_dof 口径: 标位 2-D 静电每节点 1 个自由度, dof 必须等于节点数,
%         两倍的数只能出现在"两次独立求解之和"那个字段上。
tests = functiontests(localfunctions);
end

% ==================== 基准数据 (由驱动脚本在同一台机器上实测) ====================
function [names, hashes, spots] = anaBaseline()
% 解析采样容器 (a_m=12.5e-6, b_m=12.7e-3, V0_V=700, mode=planar, force_analytic=1)
% 的逐位基准。哈希 = SHA-256(每个元素的 8 字节小端 uint64 拼成的字节流)。
names = {'nodes', 'potential', 'ex', 'ey', 'weighting_potential', 'wx', 'wy'};
hashes = strings(7, 1);
hashes(1) = "0bf4a3255e5bb4375027b3e75d16d40489d170e009ffa3fa098f2f2b847ce395";
hashes(2) = "09cd76e0bedae4e90cecde6ae81fe57d5cbce84c51fe40327df40966c4a5a29b";
hashes(3) = "5237f70f98a6a492df39d58d1b6d89c70db8b8437bde5337e943fdd8a41aa680";
hashes(4) = "a94abffc28f06901902a66c8e07e762d515434f2c6488a7d3819d2d50452313c";
hashes(5) = "d7fe737dc7d6bacec22228f1201096ddda59ef218d284278ae1e6bcfec94b63a";
hashes(6) = "65ff80f0b64338efa29af6893516414357dffb77eb5d7cd85194ad5c7367d7da";
hashes(7) = "ce8ff2e85de64e502df0fbd997b2f84b068885ffd19869f05d64e1b403802e25";
% 每个数组首/末元素的 num2hex: 哈希对上而这里对不上, 说明字节序或长度口径变了。
spots = strings(7, 2);
spots(1, :) = ["3eea36e2eb1c432d", "bf55bffc9a07442d"];
spots(2, :) = ["4085e00000000000", "8000000000000000"];
spots(3, :) = ["415edaad152b9405", "40beed428a55089f"];
spots(4, :) = ["0000000000000000", "c08a0119b39fa3eb"];
spots(5, :) = ["3ff0000000000000", "0000000000000000"];
spots(6, :) = ["40c691513fc24061", "40269ee8fd513694"];
spots(7, :) = ["0000000000000000", "bff3053184d83d61"];
end

function F = anaMap()
persistent cache
if isempty(cache)
    o = struct('a_m', 12.5e-6, 'b_m', 12.7e-3, 'V0_V', 700, 'force_analytic', 1);
    cache = tepc.field.solveElectrostatic(o);
end
F = cache;
end

function F = fineMap()
persistent cache
if isempty(cache)
    o = struct('a_m', 50e-6, 'b_m', 25.4e-3, 'V0_V', 700, 'gate', 'report');
    cache = tepc.field.solveElectrostatic(o);
end
F = cache;
end

function F = coarseMap()
persistent cache
if isempty(cache)
    o = struct('a_m', 50e-6, 'b_m', 25.4e-3, 'V0_V', 700, 'gate', 'report', ...
        'hmax', (25.4e-3 - 50e-6)/3, 'hmin', 50e-6, 'hgrad', 1.6, ...
        'hedge_factor', 1, 'refineRatio', 1.6);
    cache = tepc.field.solveElectrostatic(o);
end
F = cache;
end

function h = bitHash(A)
% 每个 double 元素按 uint64 位型展开成 8 个字节, 拼接后取 SHA-256 (64 位小写 hex)。
% 用位型而不是数值求和: 求和对 ±ulp 的抵消不敏感, 位型对任何一个比特的翻转都敏感。
B = typecast(double(A(:)), 'uint64');
C = dec2hex(typecast(B, 'uint8'));
h = tepc.io.hashText(strjoin(cellstr(C), ''));
end

% ==================== (1) 解析路径逐位回归锁 ====================

function test_analytic_container_is_bit_identical_to_baseline(tc)
F = anaMap();
tc.verifyEqual(string(F.field_mode), "analytic");
tc.verifyTrue(F.isAnalytic);
tc.verifyTrue(F.usable_for_production, '主动选择的解析容器才是产物');
tc.verifyEqual(string(F.status), "force_analytic_only");
[names, hashes, spots] = anaBaseline();
for i = 1:numel(names)
    A = F.(names{i});
    h = bitHash(A);
    tc.verifyEqual(string(h), hashes(i), ...
        sprintf('%s 的位型哈希与基准不同: 解析路径被改动 (%d 个元素)', names{i}, numel(A)));
    tc.verifyEqual(string(num2hex(A(1))), spots(i, 1), ...
        sprintf('%s 首元素的位型变了', names{i}));
    tc.verifyEqual(string(num2hex(A(end))), spots(i, 2), ...
        sprintf('%s 末元素的位型变了', names{i}));
end
fprintf('[wp2] 解析容器逐位基准: %d 个数组 / %d 个 double 元素, 全部一致\n', ...
    numel(names), numel(F.potential)*numel(names));
end

function test_bit_lock_fails_on_single_ulp_perturbation(tc)
% 负对照: 上一条用例的锁必须在**故意**改动 1 ulp 时变红。不删断言、不放宽容差,
% 而是把同一套比较跑在被扰动的数据上, 证明它真的能分辨。
F = anaMap();
[names, hashes] = anaBaseline();
nCaught = 0;
for i = 1:numel(names)
    A = F.(names{i});
    A2 = A;
    A2(end) = A2(end) + eps(A2(end));          % 1 ulp, 且只在最后一个元素上
    tc.verifyFalse(isequal(A2, A), '扰动必须让数组不相等');
    h2 = bitHash(A2);
    mismatch = ~strcmp(h2, hashes(i));
    tc.verifyTrue(mismatch, ...
        sprintf('1 ulp 扰动 (%s) 未被位型哈希捕获: 该锁是装饰', names{i}));
    nCaught = nCaught + mismatch;
end
tc.verifyEqual(nCaught, numel(names), '每个数组的扰动都必须被捕获');
% 未扰动的原值必须仍然等于基准 —— 否则上面的"捕获"只是因为数据本来就不对。
for i = 1:numel(names)
    tc.verifyTrue(strcmp(bitHash(F.(names{i})), hashes(i)), ...
        sprintf('%s 未扰动时就不等于基准, 负对照无效', names{i}));
end
end

% ==================== (2) 门禁咬合力 ====================

function test_gate_criteria_pass_with_measured_values(tc)
F = fineMap();
g = F.gate;
tc.verifyTrue(isfield(g, 'n_criteria') && g.n_criteria == 6, ...
    '门禁判据条数变化必须在这里显式改测试');
tc.verifyTrue(g.charge_ok);
tc.verifyTrue(g.field_ok);
tc.verifyTrue(g.potential_ok);
tc.verifyTrue(g.weighting_ok, '权重电位解与闭式的窗内偏差超阈: 第二次求解不可信');
tc.verifyTrue(g.two_solve_ok, '两次独立求解的电容量互差超阈: 网格/节点序被静默改动');
tc.verifyTrue(g.delta_ok);
tc.verifyTrue(g.passed, sprintf('精度门禁未通过: %s', g.failed));
tc.verifyTrue(F.usable_for_production);
% 每条判据都得有**非零**实测值: 恒为 0 的比较项没有判别力 (解析容器才会那样记账)。
meas = [abs(g.charge_residual), g.field_max_rel_dev, g.potential_max_rel_dev, ...
    g.weighting_max_rel_dev, g.two_solve_agreement, g.max_rel_delta];
thr = [g.charge_threshold_rel, g.field_threshold_rel, g.potential_threshold_rel, ...
    g.weighting_threshold_rel, g.two_solve_threshold_rel, g.delta_threshold_rel];
tc.verifyTrue(all(isfinite(meas)) && all(meas > 0), '判据实测值必须是有限正数');
tc.verifyTrue(all(meas <= thr), '判据实测值必须落在阈值内');
fprintf('[wp2] 门禁实测 charge=%.3e field=%.3e potential=%.3e weighting=%.3e two_solve=%.3e delta=%.3e\n', ...
    meas(1), meas(2), meas(3), meas(4), meas(5), meas(6));
fprintf('[wp2] 门禁阈值        charge=%.3e field=%.3e potential=%.3e weighting=%.3e two_solve=%.3e delta=%.3e\n', ...
    thr(1), thr(2), thr(3), thr(4), thr(5), thr(6));
end

function test_gate_thresholds_come_from_the_registry(tc)
F = fineMap();
g = F.gate;
tc.verifyEqual(g.charge_threshold_rel, tepc.config.constants('field.fem.maxRelDevCharge'), 'RelTol', 0);
tc.verifyEqual(g.field_threshold_rel, tepc.config.constants('field.fem.maxRelDevEmagResolved'), 'RelTol', 0);
tc.verifyEqual(g.potential_threshold_rel, tepc.config.constants('field.fem.maxRelDevPotentialResolved'), 'RelTol', 0);
tc.verifyEqual(g.weighting_threshold_rel, tepc.config.constants('field.fem.maxRelDevPotentialResolved'), 'RelTol', 0, ...
    '权重电位与电位是同一口径 (窗内逐点 |V_num-V_ana|/V0), 必须共用注册表里的同一个阈值');
tc.verifyEqual(g.two_solve_threshold_rel, tepc.config.constants('field.fem.maxRelDevCharge'), 'RelTol', 0);
tc.verifyEqual(g.delta_threshold_rel, tepc.config.constants('field.fem.maxRelDeltaIntegral'), 'RelTol', 0);
end

function test_weighting_route_is_gated_not_just_recorded(tc)
F = fineMap();
w = F.charge_check.weighting;
c = F.charge_check.charge;
tc.verifyTrue(w.gated, '权重读数只记录不判门禁 = 报告里有数但没人负责');
tc.verifyTrue(w.ok);
tc.verifyEqual(w.threshold_rel, tepc.config.constants('field.fem.maxRelDevCharge'), 'RelTol', 0);
agree = F.charge_check.two_solve_agreement;
tc.verifyEqual(agree, abs(w.value_F/c.value_F - 1), 'RelTol', 0, ...
    '两次独立求解的互差必须等于两条读数的相对差');
tc.verifyEqual(F.gate.two_solve_agreement, agree, 'RelTol', 0);
fprintf('[wp2] 两次求解互差 = %.6e (电位解 %.9e F, 权重解 %.9e F)\n', ...
    agree, c.value_F, w.value_F);
end

function test_coarse_mesh_trips_the_gate_with_named_error(tc)
% 负对照: 同一套判据、同一入口, 只把网格放粗到未分辨 -> 必须抛错而不是带病历出门。
o = struct('a_m', 50e-6, 'b_m', 25.4e-3, 'V0_V', 700, 'gate', 'error', ...
    'hmax', (25.4e-3 - 50e-6)/3, 'hmin', 50e-6, 'hgrad', 1.6, ...
    'hedge_factor', 1, 'refineRatio', 1.6);
ME = captureError(@() tepc.field.solveElectrostatic(o));
tc.verifyEqual(ME.identifier, 'tepc:field:AccuracyGateFailed', ...
    sprintf('粗网格未触发门禁 (实得 %s): 门禁没有咬合力', ME.identifier));
cg = coarseMap();
tc.verifyFalse(cg.gate.passed, 'gate=report 的同一组参数必须判不过');
tc.verifyFalse(cg.usable_for_production);
% 错误消息必须带上实测值与阈值, 否则失败了也没法定位。
msg = ME.message;
tc.verifySubstring(msg, "门禁");
tc.verifySubstring(msg, string(cg.gate.failed), ...
    '抛出的消息必须逐条带上未通过的判据与读数');
tc.verifyMatches(msg, '\d\.\d{3}e[+-]\d{2,3}', ...
    '错误消息里必须出现科学计数的实测值/阈值');
fprintf('[wp2] AccuracyGateFailed 消息: %s\n', msg);
end

function test_ungated_container_is_refused_by_fieldMap(tc)
% 门禁失败的容器必须打不开消费路径 (fieldMap 见 usable_for_production=false 即抛)。
cg = coarseMap();
xyz = cg.nodes(1:min(5, size(cg.nodes, 1)), :);
ME = captureError(@() tepc.field.fieldMap(cg, xyz));
tc.verifyEqual(ME.identifier, 'tepc:field:MapGateFailed', ...
    sprintf('未过门禁的场图仍被 fieldMap 接受 (实得 %s): 半对的场图能流进下游', ME.identifier));
end

% ==================== (3) 网格自由度口径 ====================

function test_mesh_dof_is_one_per_node(tc)
F = fineMap();
tc.verifyEqual(F.mesh_dof, F.mesh_nodes, 'RelTol', 0, ...
    '标位 2-D 静电每节点 1 个自由度: dof 必须等于节点数');
tc.verifyEqual(F.mesh_dof, numel(F.potential), 'RelTol', 0, ...
    'mesh_dof 必须等于解向量的长度 (PDE Toolbox 的 NodalSolution 长度即 DofCount)');
tc.verifyEqual(F.dof_potential, F.mesh_dof, 'RelTol', 0);
tc.verifyEqual(F.dof_weighting, F.mesh_dof, 'RelTol', 0);
tc.verifyEqual(F.mesh_dof_two_solves, 2*F.mesh_dof, 'RelTol', 0, ...
    '两倍的数只允许出现在"两次独立求解之和"这个字段上');
tc.verifyEqual(F.mesh_dof / F.mesh_nodes, 1, 'RelTol', 0);
lv = F.convergence.levels;
tc.verifyTrue(numel(lv) >= 3);
for k = 1:numel(lv)
    tc.verifyEqual(lv(k).dof, lv(k).nodes, 'RelTol', 0, sprintf('第 %d 层 dof != 节点数', k));
end
fprintf('[wp2] 最细层: dof=%d nodes=%d elements=%d two_solves=%d\n', ...
    F.mesh_dof, F.mesh_nodes, F.mesh_elements, F.mesh_dof_two_solves);
end

function test_analytic_container_reports_dof_and_no_gate_credit(tc)
F = anaMap();
tc.verifyEqual(F.mesh_dof, F.mesh_nodes, 'RelTol', 0);
tc.verifyEqual(F.mesh_dof, numel(F.potential), 'RelTol', 0);
% 解析容器没有网格序列: 判据必须记成"未评估"而不是"通过"。
tc.verifyEqual(string(F.gate.status), "not_evaluated");
tc.verifyFalse(F.gate.passed);
tc.verifyTrue(isnan(F.analytic_field_max_rel_dev), '未评估的判据不得给 0 (会被读成通过)');
end

% ==================== 工具 ====================

function ME = captureError(fh)
try
    fh();
    ME = MException('tepc:tests:NoError', '预期抛错但正常返回');
catch e
    ME = e;
end
end
