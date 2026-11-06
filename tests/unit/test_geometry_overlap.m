function tests = test_geometry_overlap
%TEST_GEOMETRY_OVERLAP 两两干涉算子的直接契约与几何判据测试。
%   算子此前只被 GUI 按钮间接调用, 没有任何测试直接打它 —— 两处崩溃修好之后
%   "能返回 rep"这件事本身是没有锁的。这里按可复算的方式钉住: 命中/间隙/体积三类
%   数值判据各一个已知答案的合成用例, 加上参数契约与"设计共面"开关。
%   约定: 只有 test 开头且单入参 tc 的局部函数会被收为用例。

tests = functiontests(localfunctions);
end

%% ==================== 用例 ====================

function test_transverse_box_overlap_is_detected(tc)
A = boxPart('A', [0 0 0], [1 1 1]);
B = boxPart('B', [0.25 0.20 0.15], [1 1 1]);
rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
s = rep.summary;
tc.verifyGreaterThan(s.n_face_intersecting, 0, ...
    sprintf('两个错开 (0.25,0.20,0.15) m 的单位立方体必有面-面相交, 实得 %d', ...
    s.n_face_intersecting));
tc.verifyGreaterThan(s.n_penetrating, 0, '穿透对数必须 > 0');
tc.verifyEqual(char(string(rep.verdict)), 'PENETRATION', ...
    sprintf('判定必须是 PENETRATION, 实得 %s', char(string(rep.verdict))));
tc.verifyGreaterThan(s.max_penetration_overall_m, 0.1, ...
    sprintf('三轴最小重叠 = min(0.25,0.20,0.15) = 0.15 m, 实得 %.4f', ...
    s.max_penetration_overall_m));
end

function test_axis_aligned_box_overlap_is_detected(tc)
% 只在 x 向错开、y/z 完全相同的两个立方体: 真实重叠 0.25 m。
% segTri 在 |a|<1e-30 处早退 (面片与坐标平面共面), 这条因此是**已知红**,
% 它把"退化几何下 face-hit 静默为 0"这个缺陷钉在套件里而不是留在注释里。
A = boxPart('A', [0 0 0], [1 1 1]);
B = boxPart('B', [0.25 0 0], [1 1 1]);
rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
s = rep.summary;
tc.verifyGreaterThan(s.n_aabb_overlapping, 0, 'AABB 必须相接 (这条应当一直绿)');
tc.verifyGreaterThan(s.n_face_intersecting, 0, ...
    sprintf(['共面退化用例: 两立方体重叠 0.25 m, face-hit 实得 %d ' ...
        '(segTri 在 |a|<1e-30 早退) —— 轴对齐零件的真实干涉会被漏报'], ...
        s.n_face_intersecting));
end

function test_disjoint_boxes_report_the_gap(tc)
A = boxPart('A', [0 0 0], [1 1 1]);
B = boxPart('B', [3.5 0 0], [1 1 1]);      % 间隙 = 3.5 - 1 - 1 = 1.5 m
rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
s = rep.summary;
tc.verifyEqual(s.n_face_intersecting, 0, '分离的零件不得报面-面相交');
tc.verifyEqual(s.n_with_duplicate_volume, 0, '分离的零件不得报重复体积');
tc.verifyEqual(s.min_gap_overall_m, 1.5, 'RelTol', 1e-3, ...
    sprintf('最小间隙应为 1.5 m, 实得 %.6f', s.min_gap_overall_m));
end

function test_nested_box_duplicate_volume_equals_inner_volume(tc)
A = boxPart('outer', [0 0 0], [2 2 2]);     % 8x8x8 -> V = 512
B = boxPart('inner', [0 0 0], [0.5 0.5 0.5]);
rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
pr = rep.pairs(1);
tc.verifyEqual(pr.overlap_volume_m3, 1.0, 'RelTol', 5e-2, ...
    sprintf('内层盒 (1x1x1) 完全被包含时重复体积应约为 1 m^3, 实得 %.6f', ...
    pr.overlap_volume_m3));
tc.verifyFalse(pr.expected_coincident, ...
    '未声明 coincident_with 的包含关系必须按"意外重复体积"报, 不能自动放过');
end

function test_declared_coincident_pair_is_excluded_from_unexpected(tc)
% 算子头部声明: 设计共面的对"从意外干涉结论里剔除, 但仍然照常计算与报告数值"。
% 这里就按这两句各自钉一条: 剔除 (n_*_unexpected 必须为 0) 与 照算 (体积必须是数)。
A = boxPart('A', [0 0 0], [1 1 1]);
B = boxPart('B', [0.25 0.20 0.15], [1 1 1]);
B.coincident_with = 'A';
rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
pr = rep.pairs(1);
s = rep.summary;
tc.verifyTrue(pr.expected_coincident, '声明了 coincident_with 的对必须被识别为设计共面');
tc.verifyEqual(s.n_penetrating_unexpected, 0, ...
    sprintf('设计共面的穿透对仍被算进"意外"计数: %d', s.n_penetrating_unexpected));
tc.verifyEqual(s.n_face_intersecting_unexpected, 0, ...
    sprintf('设计共面的相交对仍被算进"意外"计数: %d', s.n_face_intersecting_unexpected));
tc.verifyTrue(isfinite(pr.overlap_volume_m3) && pr.overlap_volume_m3 > 0, ...
    sprintf(['头部声明"数值照常计算与报告", 但该对 overlap_volume_m3 实得 %s ' ...
        '(status=%s) —— 重复体积根本没算'], ...
        mat2str(pr.overlap_volume_m3), char(string(pr.overlap_volume_status))));
end

function test_convex_clip_volume_is_hand_computable(tc)
% 凸-凸半空间裁剪的体积必须能被手算复核: 轴对齐盒两两错开的交集就是另一个长方体。
cases = [0.25 0.20 0.15, 5.8275;      % (2-.25)(2-.20)(2-.15) = 1.75*1.80*1.85
         0.25 0.00 0.00, 7.0;         % (2-.25)*2*2
         3.50 0.00 0.00, 0.0;          % AABB 已隔开 => 交集必为空
         2.00 0.00 0.00, 0.0];         % 面贴合: 零厚度不是重复体积
for k = 1:size(cases, 1)
    A = boxPart('A', [0 0 0], [1 1 1]);
    B = boxPart('B', cases(k, 1:3), [1 1 1]);
    rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
    pr = rep.pairs(1);
    tag = sprintf('偏移 (%.2f,%.2f,%.2f)', cases(k, 1), cases(k, 2), cases(k, 3));
    tc.verifyTrue(isfinite(pr.overlap_volume_m3), ...
        sprintf('%s: 凸-凸对的体积不该留 NaN (status=%s)', tag, ...
        char(string(pr.overlap_volume_status))));
    want = cases(k, 4);
    if want > 0
        tc.verifyEqual(pr.overlap_volume_m3, want, 'RelTol', 1e-9, ...
            sprintf('%s: 交集体积应等于手算值 %g, 实得 %.12g', tag, want, pr.overlap_volume_m3));
    else
        tc.verifyEqual(pr.overlap_volume_m3, 0, 'AbsTol', 1e-9, ...
            sprintf('%s: 不该有重复体积, 实得 %.3g (status=%s)', tag, ...
            pr.overlap_volume_m3, char(string(pr.overlap_volume_status))));
    end
    tc.verifyFalse(startsWith(char(string(pr.overlap_volume_status)), 'not_computed'), ...
        sprintf('%s: 可算的对被标成 %s', tag, char(string(pr.overlap_volume_status))));
end
end

function test_axis_aligned_pair_reports_coplanar_contact(tc)
% 只在 x 向错开、y/z 完全相同的两立方体: 边界交集是正面积的重合面片 (共面类), 线段法对它
% 先天失效, 必须靠面内 2D 面积求交记成接触, 否则"共面退化"就是漏报。
A = boxPart('A', [0 0 0], [1 1 1]);
B = boxPart('B', [0.25 0 0], [1 1 1]);
rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
pr = rep.pairs(1);
tc.verifyGreaterThan(pr.coplanar_contact_pairs, 0, ...
    sprintf('共面重合面片的条数必须 > 0, 实得 %d', pr.coplanar_contact_pairs));
tc.verifyGreaterThan(pr.n_face_hits, pr.coplanar_contact_pairs - 1, ...
    sprintf('共面接触必须计入 face-hit (否则 n_face_intersecting 恒 0), 实得 %d', pr.n_face_hits));
tc.verifyGreaterThan(maxContactArea(pr), 0, '相交记录里必须带共面接触面积');
end

function a = maxContactArea(pr)
% 相交记录里的最大共面接触面积 [m^2]。
a = 0;
for k = 1:numel(pr.hits)
    a = max(a, pr.hits{k}.contact_area_m2);
end
end

function test_nested_pair_is_orientation_independent(tc)
% 内含判据必须与"谁先谁后"无关, 且体积取自内体自身的散度定理和 (1x1x1 => 恰好 1 m^3)。
o = boxPart('outer', [0 0 0], [2 2 2]);
i = boxPart('inner', [0 0 0], [0.5 0.5 0.5]);
r1 = tepc.geometry.overlapCheck([o i], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
r2 = tepc.geometry.overlapCheck([i o], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
tc.verifyEqual(r1.pairs(1).overlap_volume_m3, 1.0, 'RelTol', 1e-9, ...
    sprintf('内体 1x1x1 的重复体积应恰为 1 m^3, 实得 %.12g', r1.pairs(1).overlap_volume_m3));
tc.verifyEqual(r2.pairs(1).overlap_volume_m3, 1.0, 'RelTol', 1e-9, ...
    sprintf('零件表换序后同一个数必须不变, 实得 %.12g', r2.pairs(1).overlap_volume_m3));
tc.verifyEqual(char(string(r1.pairs(1).overlap_volume_status)), 'contained_inner_volume', ...
    sprintf('内含对的状态应写明体积来源, 实得 %s', char(string(r1.pairs(1).overlap_volume_status))));
tc.verifyEqual(r1.summary.n_overlap_volume_contained_pairs, 1, ...
    '汇总里必须能数出内含对条数');
end

function test_containment_inside_nonconvex_outer_body(tc)
% 非凸外壳 (L 形棱柱) 里的内体: 半空间判据不可用, 只能靠立体角环绕数; 体积仍应是内体自身体积。
outer = lPrismPart('outer', [0 0 0], 1);
inner = boxPart('inner', [0.5 0.5 0.5], [0.2 0.2 0.2]);
rep = tepc.geometry.overlapCheck([outer inner], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
pr = rep.pairs(1);
tc.verifyTrue(isfinite(pr.overlap_volume_m3), ...
    sprintf('内含于非凸壳的对不该留 NaN (status=%s)', char(string(pr.overlap_volume_status))));
tc.verifyEqual(pr.overlap_volume_m3, 0.4^3, 'RelTol', 1e-9, ...
    sprintf('重复体积应为内体 0.4^3 = %.6g m^3, 实得 %.12g', 0.4^3, pr.overlap_volume_m3));
tc.verifyFalse(pr.expected_coincident, '未声明的内含必须按意外重复体积报');
end

function test_nonconvex_pair_status_is_explicit_not_computed(tc)
% 两个非凸实体的一般交集在这里确实算不出来: 状态必须是显式的 not_computed_* 而不是空串,
% 而且要进 n_overlap_volume_not_computed 计数 (不能假装算完)。
A = lPrismPart('A', [0 0 0], 1);
B = lPrismPart('B', [0.5 0.5 0], 1);
rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
pr = rep.pairs(1);
tc.verifyTrue(startsWith(char(string(pr.overlap_volume_status)), 'not_computed'), ...
    sprintf('算不出的对必须写显式原因, 实得 %s', char(string(pr.overlap_volume_status))));
tc.verifyTrue(isnan(pr.overlap_volume_m3), '算不出体积时不得给伪值');
tc.verifyEqual(rep.summary.n_overlap_volume_not_computed, 1, ...
    sprintf('未算体积的对必须被计数, 实得 %d', rep.summary.n_overlap_volume_not_computed));
end

function test_argument_contract(tc)
A = boxPart('A', [0 0 0], [1 1 1]);
B = boxPart('B', [0.2 0 0], [1 1 1]);
tc.verifyError(@() tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6), ...
    'tepc:geometry:OverlapMissingThreshold', '缺 PenetrationTol_m 必须拒绝而不是给默认判据');
tc.verifyError(@() tepc.geometry.overlapCheck([A B], 'GapMin_m', 0, 'PenetrationTol_m', 0), ...
    'tepc:geometry:OverlapBadThreshold', 'GapMin_m 必须为正');
tc.verifyError(@() tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, ...
    'PenetrationTol_m', 1e-9, 'NoSuchOption', 1), 'tepc:geometry:OverlapBadOption');
tc.verifyError(@() tepc.geometry.overlapCheck([A B], 'GapMin_m'), ...
    'tepc:geometry:OverlapBadArgs', '选项必须成对');
tc.verifyError(@() tepc.geometry.overlapCheck(A, 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9), ...
    'tepc:geometry:OverlapNoParts', '单零件无法做两两核查');
me = captureTooManyOutputs(@() tepc.geometry.overlapCheck([A B], ...
    'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9));
tc.verifyEqual(me, 'MATLAB:TooManyOutputs', ...
    sprintf('算子声明单输出, 双输出调用必须报 TooManyOutputs, 实得 %s', me));
end

function test_missing_fields_do_not_guess_transport_role(tc)
% role 缺失要标 unknown: 猜成"进 MC"会让一个没人消费的零件拿到"通过"结论。
A = struct('part_id', 'A', 'V', boxV([0 0 0], [1 1 1]), 'F', boxF());
B = struct('part_id', 'B', 'V', boxV([0.25 0 0], [1 1 1]), 'F', boxF());
rep = tepc.geometry.overlapCheck([A B], 'GapMin_m', 1e-6, 'PenetrationTol_m', 1e-9);
roles = string(rep.transport_role);
tc.verifyTrue(all(roles == "unknown"), ...
    sprintf('未给 transport_role 的零件必须标 unknown, 实得 %s', strjoin(roles, ',')));
end

%% ==================== 辅助 (0 参或以内联闭包代替) ====================

function p = lPrismPart(id, c, h)
% L 形棱柱 (非凸闭合网格): 底面是六点多边形 (0,0)(2,0)(2,1)(1,1)(1,2)(0,2), 沿 z 拉高 h。
P = [0 0; 2 0; 2 1; 1 1; 1 2; 0 2];
nb = size(P, 1);
V = [P, zeros(nb, 1); P, repmat(h, nb, 1)] + repmat(c, 2*nb, 1);
F = zeros(0, 3);
for k = 2:nb-1                      % 两端盖子: 从顶点 1 扇形剖分 (该 L 对顶点 1 星形)
    F = [F; [1 k+1 k]; [1+nb k+nb k+1+nb]]; %#ok<AGROW>
end
for k = 1:nb                         % 侧面: 每条底边一个四边形, 剖两个三角形
    k2 = mod(k, nb) + 1;
    F = [F; [k k2 k2+nb]; [k k2+nb k+nb]]; %#ok<AGROW>
end
p = struct('part_id', id, 'transport_role', 'enter_mc', 'transport_mode', ...
    'mc_chord_and_csda', 'display_only', false, 'V', V, 'F', F, ...
    'shape', [], 'centre', c, 'coincident_with', '', 'idx', 0);
end

function p = boxPart(id, c, h)
p = struct('part_id', id, 'transport_role', 'enter_mc', 'transport_mode', ...
    'mc_chord_and_csda', 'display_only', false, 'V', boxV(c, h), 'F', boxF(), ...
    'shape', [], 'centre', c, 'coincident_with', '', 'idx', 0);
end

function V = boxV(c, h)
U = [0 0 0; 1 0 0; 1 1 0; 0 1 0; 0 0 1; 1 0 1; 1 1 1; 0 1 1];
V = repmat(c, 8, 1) + (U * diag(2 .* h));
V = V - repmat(h, 8, 1);
end

function F = boxF()
F = [1 4 3; 1 3 2; 5 6 7; 5 7 8; 1 2 6; 1 6 5; ...
     4 8 7; 4 7 3; 1 5 8; 1 8 4; 2 3 7; 2 7 6];
end

function id = captureTooManyOutputs(f)
id = '';
try
    [a, b] = f();
    clear a b
catch e
    id = char(string(e.identifier));
end
end
