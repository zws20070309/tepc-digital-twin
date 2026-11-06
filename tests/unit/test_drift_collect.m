function tests = test_drift_collect
%TEST_DRIFT_COLLECT 一维漂移-收集诊断 (L1) 的行为锁。
%   动机: driftCollect 不在事件计算链上 (它只报"量级"), 此前全仓零调用方, 于是它
%   修过的两个静默缺陷没有任何东西防止回退:
%     (1) 温度曾硬编码 293.15 K —— 改 cfg.gas.temperature_K 时扩散量一毫米不动;
%     (2) 场曾硬编码同轴圆柱 E=V/(r ln(b/a)) —— 与 sphere 几何自相矛盾。
%   这里把两条做成可失败的判据, 并补上守卫与单调性; 不声称它与任何实测漂移时间符合
%   (输运参数是 ASSUMED, 没有 Magboltz 表)。
tests = functiontests(localfunctions);
end

function out = runOne(~, T, eta, kind, hv)
% 附着系数在 gasTbl 里 (不在 opts), 所以造 eta 要改气体表。
g = gas();
g.eta_attach = eta;
f = fld(kind, hv);
out = tepc.detector.driftCollect(cluster(), f, g, stream(), struct('temperature_K', T));
end

function test_temperature_is_actually_consumed(tc)
% 温度只进 Einstein 关系 D = vd*kB*T/(e*E), 不进迁移率 —— 所以正确的行为是:
% 扩散宽度按 sqrt(T) 精确缩放, 而收集时间逐位不变。这两半一起才排掉"温度被忽略"
% 与"温度被当成迁移率参数"两种错法。
o250 = runOne(tc, 250, 0, 'cylinder', 2000);
o350 = runOne(tc, 350, 0, 'cylinder', 2000);
tc.verifyGreaterThan(o350.sigma_long_m, o250.sigma_long_m, ...
    sprintf('T 250->350 K 扩散宽度没变大 (%.3e -> %.3e): 温度又被硬编码顶掉了', ...
    o250.sigma_long_m, o350.sigma_long_m));
tc.verifyEqual(o350.sigma_long_m / o250.sigma_long_m, sqrt(350/250), 'RelTol', 1e-12, ...
    sprintf('扩散宽度不按 sqrt(T) 缩放 (实得比值 %.15g, 应为 %.15g)', ...
    o350.sigma_long_m / o250.sigma_long_m, sqrt(350/250)));
tc.verifyEqual(o350.t_collect_s, o250.t_collect_s, 'AbsTol', 0, ...
    sprintf('收集时间随温度变了 (%.17g vs %.17g): 温度渗进了不该渗的迁移率/场', ...
    o250.t_collect_s, o350.t_collect_s));
end

function test_temperature_guard_is_early_and_loud(tc)
% 缺温度必须报错而不是回到 293.15 K 的默认值 (静默用错温度是物理错误)。
g = gas(); f = fld('cylinder', 2000);
tc.verifyError(@() tepc.detector.driftCollect(cluster(), f, g, stream(), struct()), ...
    'tepc:drift:MissingTemperature', '没有 temperature_K 时必须抛, 不许用硬编码默认值');
o = struct('temperature_K', []);
tc.verifyError(@() tepc.detector.driftCollect(cluster(), f, g, stream(), o), ...
    'tepc:drift:MissingTemperature', '空值温度同样要抛 (JSON null 经 jsondecode 就是 [])');
o = struct('temperature_K', 100);
tc.verifyError(@() tepc.detector.driftCollect(cluster(), f, g, stream(), o), ...
    'tepc:drift:BadTemperature', '100 K 超出气体模型适用域 [200,400] K, 必须拒');
end

function test_attachment_is_monotone_and_unit_at_zero(tc)
% 无附着时存活份额必须恰为 1 (任何偏离都说明每步乘的不是 exp(-eta*ds));
% eta 增大必须单调下降。
s0 = runOne(tc, 293, 0, 'cylinder', 2000);
tc.verifyEqual(s0.survival, 1, 'AbsTol', 0, ...
    sprintf('eta=0 的存活份额不是 1 (实得 %.17g)', s0.survival));
s1 = runOne(tc, 293, 1e3, 'cylinder', 2000);
s2 = runOne(tc, 293, 1e4, 'cylinder', 2000);
tc.verifyTrue(s1.survival < s0.survival && s2.survival < s1.survival, sprintf( ...
    '附着增强存活不降 (1 / %.3e / %.3e): 附着项没接进权重', s1.survival, s2.survival));
end

function test_field_kind_is_consumed_not_hardcoded_cylinder(tc)
% 同一 a/b/HV 下 cylinder 与 sphere 的场分布不同, 收集时间必须不同 ——
% 这条直接钉死"硬编码圆柱"的回退。
oc = runOne(tc, 293, 0, 'cylinder', 2000);
os = runOne(tc, 293, 0, 'sphere',   2000);
tc.verifyNotEqual(oc.t_collect_s, os.t_collect_s, sprintf( ...
    'cylinder 与 sphere 给出同一收集时间 (%.17g): 场类型入参没被消费', oc.t_collect_s));
% note 是 string 标量 (不是 char): 对它做 (1:7) 线性索引会得回整串, 所以判前缀。
tc.verifyTrue(startsWith(string(os.note), "ASSUMED"), ...
    sprintf('输出没带 ASSUMED 标注 (实得 "%s"): 输运参数无实测表, 不得被读成已标定', ...
    string(os.note)));
end

function test_is_deterministic_and_does_not_consume_the_stream(tc)
% 形参 rs 在函数体里不被消费: 两次调用必须逐位同, 且流的状态不因调用而变。
% 这条同时把"将来偷偷用 rs 抽样"变成可见的失败, 而不是让诊断结果随调用顺序漂移。
a = runOne(tc, 293, 0, 'cylinder', 2000);
b = runOne(tc, 293, 0, 'cylinder', 2000);
tc.verifyTrue(isequal(a, b), '同输入两次调用结果不同: 诊断量不再是纯函数');
rs = stream();
sBefore = rs.State;
tepc.detector.driftCollect(cluster(), fld('cylinder', 2000), gas(), rs, ...
    struct('temperature_K', 293));
tc.verifyTrue(isequal(rs.State, sBefore), ...
    'driftCollect 消耗了传入的随机流: 它会在诊断里扰动别处的抽样序列');
end

% ==================== helpers (都有输出参数, 不被静态计数当用例) ====================

function c = cluster()
c = struct('r0', 1.0e-3, 'N0', 1000, 't0', 0);   % 从 1 mm 处向阳极漂移
end

function f = fld(kind, hv)
f = struct('a', 50e-6, 'b', 15e-3, 'hv_V', hv, 'kind', kind);
end

function g = gas()
% ASSUMED 量级参数 (无 Magboltz 表): N 取 STP 数密度, 饱和漂移与特征场按 P10 量级。
g = struct('vd_max', 6e4, 'vd_half_Ed', 3e-23, 'eta_attach', 0, 'N_density', 2.5e25);
end

function rs = stream()
rs = RandStream('Threefry', 'Seed', 7);
end
