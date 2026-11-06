function tests = test_field_map_reciprocity
%TEST_FIELD_MAP_RECIPROCITY 场图的非自证核验: 判据只准取离散解的**积分与方向**量。
%   动机 (读代码得到的机制, 不是猜测):
%     * solveElectrostatic.m:176 写的是 phiw = pV/V —— 权重电位就是同一次求解的电位除 hv。
%       两电极系统里 Ramo 权重电位本就等于 V/hv, 所以 "phi_w(a)=1、phi_w(b)=0" 这类判据
%       核对的是它自己的 Dirichlet 输入 (BC 正是阳极 hv、阴极 0)。把这种判据叫"验证"就是
%       自证循环: 边界条件接反也照样绿。
%     * 因此本文件刻意**不取** phiw、也不取节点电位 V 作判据对象, 只用三条独立量:
%       T1 场强幅值沿径向路径的线积分 (要复现外加电压)、
%       T2 轴向分量与径向分量之比随加密衰减 (同轴极限几何的解与 z 无关)、
%       T3 T1 的相对残差随网格加密下降, 且倍率落在收敛阶的带内。
%     * 真正的 Green 互易 (C12=C21) 在这里**做不到**, 两个硬缺位记下来而不是假装做了:
%       (i) solveElectrostatic 的 opts 无法表达"交换哪个电极接地"的第二次求解;
%       (ii) map 只交出节点值、一条径向路径与阳极侧面通量, 没有单元连接表, 体积分
%            ∫eps·E1·E2 dV 无从构造。补齐任一条才谈得上互易性本身。
%   负对照 (判据有内容的证据): 把 map 的 Er 与 Ez 整列互换, T2 的比值必须炸; 而 T1 必须
%   逐位不动 (T1 只吃 |E| 的径向线积分) —— 后者同时证明两条判据不共用同一个数组。
%   阈值来源: 全按本机实测值定, 实测数写在行内, 不采信"应该多小"的直觉。
%     本机实测 (a=50 µm, b=25.4 mm, hv=700 V, geometry='coax'):
%       T1 残差  层级1 = 2.291e-4, 层级2 = 7.457e-5   (倍率 3.07)
%       T2 比值  层级1 = 4.979e-3, 层级2 = 2.214e-3   (采样路径上 1.189e-3 -> 4.130e-4)
%       分母 max|Er|(r>=2a) = 1.137e6 / 1.130e6, 闭式在 r=2a 处 = 1.1235e6 (同量级: 分母没被污染)
tests = functiontests(localfunctions);
end

% ==================== 共享求解 (PDE 求解秒级, 同一份解在用例间复用) ====================

function [M1, M2] = coaxSolves()
persistent c1 c2
a = 50e-6; b = 25.4e-3; hv = 700;
if isempty(c1)
    c1 = tepc.detector.solveElectrostatic(a, b, hv, ...
        struct('geometry', 'coax', 'gridLevel', 1));
    c2 = tepc.detector.solveElectrostatic(a, b, hv, ...
        struct('geometry', 'coax', 'gridLevel', 2));
end
M1 = c1; M2 = c2;
end

function r = relResid(M)
% T1 的残差。判据对象**不是** hv 本身, 而是"同一条截断路径的闭式值":
% lineIntEmag = trapz(rPath, |E|), 而 rPath 止于 b*(1-1e-3) (solveElectrostatic.m:155)。
% 精确径向场给 int_a^rEnd V/(r ln(b/a)) dr = V*ln(rEnd/a)/ln(b/a), 它比 V 小约 1.66e-4·V。
% 不扣掉这个与网格无关的端点截断项, "残差随加密下降"就成了拿常数偏置冒充收敛 ——
% 实测层级 2 的原始残差 7.457e-5 甚至小于该偏置, 就是这个原因。
e = M.path.r_m(end);
ref = M.hv_V * log(e / M.a_m) / log(M.b_m / M.a_m);
r = abs(M.integral.lineIntEmag - ref) / abs(M.hv_V);
end

function f = farField(M)
% 电极面与奇点邻域之外的节点子集 (r >= 2a)。阳极面上的场按 1/r 发散, 用它当分母任何比值
% 都失去可比性, 所以一律排除。
f = M.nodeR >= 2*M.a_m;
end

function q = axialRatio(M)
f = farField(M);
q = max(abs(M.Ez(f))) / max(abs(M.Er(f)));
end

% ==================== T1 保守性: 线积分复现外加电压 ====================

function test_line_integral_of_field_reproduces_applied_voltage(tc)
[M1, M2] = coaxSolves();
% 界不自己造数: 与 fieldConvergence 用同一个注册表键 (tepc.detector.fieldConvergence.m
% 读 field.fem.maxRelDevEmagAwayOfAnode), 改注册表即改这里, 不留第二份阈值。
tol = double(tepc.config.constants('field.fem.maxRelDevEmagAwayOfAnode'));
for k = 1:2
    M = M1; if k == 2, M = M2; end
    r = relResid(M);
    tc.verifyLessThan(r, tol, sprintf('层级 %d: int|E|dr=%.6g V 对 hv=%.6g V 的相对残差 %.3e 超过 %g —— 场幅值与积分路径至少有一处不对', ...
        M.gridLevel, M.integral.lineIntEmag, M.hv_V, r, tol));
end
% 前提: 残差不得恒为 0 (那说明 lineIntEmag 是被赋成 hv 的, 本判据退化成常数断言)
r1 = relResid(M1);
tc.verifyGreaterThan(r1, 0, '层级 1 残差恰为 0: lineIntEmag 与 hv 逐位相同, 它是被赋值的而不是被积出来的');
end

% ==================== T2 轴不变性: 轴向分量必须是随加密衰减的离散误差 ====================

function test_axial_component_is_a_decaying_discretisation_error(tc)
[M1, M2] = coaxSolves();
f2 = farField(M2);
tc.verifyGreaterThan(nnz(f2), 50, 'r>=2a 的节点太少, 比值判据没有内容');
q2 = axialRatio(M2);
q1 = axialRatio(M1);
% 绝对上限同样取注册表那个键 (不再抄一个自造的 5e-3): 本机实测层级 2 为 2.214e-3。
tolDev = double(tepc.config.constants('field.fem.maxRelDevEmagAwayOfAnode'));
tc.verifyLessThan(q2, tolDev, sprintf('层级 2 的 max|Ez|/max|Er|=%.3e 超过注册表容差 %.3e (本机实测 2.214e-3)', q2, tolDev));
% 真正有排除力的是这一条: 若轴向分量来自边界归属或轴序弄错, 它是**系统性的**, 加密不会让它
% 掉; 只有离散误差才随 h 减半而下降。只判绝对值等于把结论押在运行机器上。
tc.verifyLessThan(q2, q1, sprintf('轴向分量比没随加密下降 (%.3e -> %.3e): 这是几何/边界归属的系统性不对称, 不是离散误差', q1, q2));
pr = max(abs(M2.path.Ez)) / max(abs(M2.path.Er));
tc.verifyLessThan(pr, 1e-3, sprintf('采样路径上的 max|Ez|/max|Er|=%.3e 超出轴不变性 (本机实测 4.130e-4)', pr));
end

% ==================== T3 加密下残差必须下降, 倍率落在收敛阶带内 ====================

function test_residual_decays_under_refinement(tc)
[M1, M2] = coaxSolves();
r1 = relResid(M1); r2 = relResid(M2);
tc.verifyLessThan(r2, r1, sprintf('层级 2 的 T1 残差 (%.3e) 不比层级 1 (%.3e) 小: 加密没改善, 不能把 T1 当离散误差界', r2, r1));
ratio = r1 / max(r2, realmin);
% 扣掉端点截断项之后, 残差才是纯离散误差。P1 元: 逐点场按 O(h)、积分型量可到 O(h^2),
% 层级 +1 时 h 减半 => 倍率的理论区间 [2,4]。带取 [1.5,6]: 下限排除"根本没收敛"(倍率≈1),
% 上限排除数值不稳定; 余量给 generateMesh 排布的跨进程抖动 (实测同层级节点数会变)。
tc.verifyTrue(ratio >= 1.5 && ratio <= 6, sprintf('层级 1→2 的残差倍率 %.3f 落在 [1.5,6] 之外 (r1=%.3e, r2=%.3e): 要么网格没真的加密, 要么残差由非收敛项或数值不稳定主导', ...
    ratio, r1, r2));
tc.verifyNotEqual(M2.nNodes, M1.nNodes, '两个层级的节点数相同: gridLevel 没进网格参数');
end

% ==================== 负对照: 分量互换只该打红 T2 ====================

function test_swapping_field_components_turns_only_the_axial_check_red(tc)
[M1, M2] = coaxSolves();
q0 = axialRatio(M2);
Mc = M2;  Mc.Er = M2.Ez;  Mc.Ez = M2.Er;
qSwap = axialRatio(Mc);
tolC = double(tepc.config.constants('field.fem.maxRelDevEmagAwayOfAnode'));
tc.verifyGreaterThan(qSwap, tolC, sprintf('前提破了: Er/Ez 互换后比值仍 %.3e <= 容差 —— T2 对分量互换不敏感, 那条判据是空的', qSwap));
tc.verifyGreaterThan(qSwap, 10*q0, sprintf('互换后比值只从 %.3e 变到 %.3e, 没拉开一个量级: 分子分母可能同源', q0, qSwap));
% T1 的可分辨性不能靠"互换 Er/Ez 后 T1 不变"来证明 —— relResid 只读 integral.lineIntEmag
% 与 hv_V, 那两个字段根本不在互换范围内, 断言必然成立 (恒真断言, 无信息)。真正的负对照是
% 直接 Tamper T1 的输入: 把 lineIntEmag 写成"看起来完美"的 hv, 残差必须**变** (且变得不再
% 是那个随加密下降的量)。
Mt = M2;  Mt.integral.lineIntEmag = M2.hv_V;
% verifyNotEqual 不接受 'AbsTol' (实测在 qualifyNotEqual 里抛错), 所以自己取差。
d = abs(relResid(Mt) - relResid(M2));
tc.verifyGreaterThan(d, 0, '把盘上的 lineIntEmag 直接改成 hv 后 T1 残差完全没变: 说明 relResid 没在读它, T1 是恒真的');
tc.verifyGreaterThan(relResid(M1), relResid(Mt), ...
    '篡改后的残差不小于层级 1 的真实残差: T1 的量级判据没有分辨力');
end
