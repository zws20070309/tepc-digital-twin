function tests = test_transport
%TEST_TRANSPORT 阻止本领锚点/KN 守恒/弹性运动学/CSDA 账本。
%   物理锚点: PSTAR/ESTAR 水锚点、Klein-Nishina 反冲电子平均能量的解析矩、
%   重离子 = 质子表 x 有效电荷平方、Bohr 涨落必须双侧 (均值无偏)。
tests = functiontests(localfunctions);
end

function test_pstar_anchor_water(tc)
% PSTAR 液态水 10 MeV 质子电子阻止 45.67 MeV cm2/g (ICRU49, 检索见 reference_register)
cfg = struct('gas', struct('composition_molfrac', struct('H2O',1), 'I_eV_override', 75.0));
Tw = tepc.transport.stoppingPower(cfg, "proton");
S10 = tepc.transport.stopAt(Tw, 10.0);
tc.verifyLessThan(abs(S10-45.67)/45.67, 0.01, 'Bethe 应在 PSTAR 锚点 1% 内');
end

function test_estar_anchor_electron(tc)
cfg = struct('gas', struct('composition_molfrac', struct('H2O',1), 'I_eV_override', 75.0));
Te = tepc.transport.stoppingPower(cfg, "electron");
S1 = tepc.transport.stopAt(Te, 1.0);
% 容差 1.5% 是有意收紧的: 旧值 5% 对"对数项漏 1/2"(实测 +4.3%) 两种状态都放行,
% 等于没有判据; 现在 +0.67% 通过而 +4.3% 会被抓住。
tc.verifyLessThan(abs(S1-1.86)/1.86, 0.015, '电子碰撞阻止应在 ESTAR 1 MeV 值 1.5% 内');
end

function test_stopping_tables_finite_positive_everywhere(tc)
% 全能量域必须为有限正数: 原实现用总能量插值每核子表, E>100/A 段整片 NaN
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
names = ["proton","electron","heavy_C","heavy_O"];
for i = 1:numel(names)
    T = tepc.transport.stoppingPower(cfg, names(i));
    tc.verifyTrue(all(isfinite(T.S_mass)), sprintf('%s 表含 NaN/Inf', names(i)));
    tc.verifyTrue(all(T.S_mass > 0), sprintf('%s 表必须全为正值', names(i)));
    tc.verifyTrue(all(diff(T.E) > 0), sprintf('%s 能量栅格必须递增', names(i)));
    S = tepc.transport.stopAt(T, T.E);                    % 逐栅格点回读
    tc.verifyTrue(all(isfinite(S)) && all(S > 0), ...
        sprintf('%s 表端与 stopAt 不一致或含 NaN', names(i)));
end
% 重离子表必须覆盖到 100 MeV (原缺陷在 E>100/A 之后失效)
Tc = tepc.transport.stoppingPower(cfg, "heavy_C");
tc.verifyEqual(Tc.E(1), 1e-2, 'RelTol', 1e-12);
tc.verifyEqual(Tc.E(end), 1e2, 'RelTol', 1e-9);
tc.verifyFalse(any(isnan(Tc.S_mass(Tc.E > 100/12.011))), 'E>100/A 段不得为 NaN');
end

function test_heavy_ion_scales_as_proton_times_zeff2(tc)
% 重离子 = 质子参考表按每核子能量取样 x (qbar_ion/qbar_proton)^2, 两条腿都用同一个分母。
% qbar = Z*(1-exp(-125*beta*Z^(-2/3))) 是**绝对**有效电荷: 漏乘前置 Z 会让比值在高 beta
% 端趋于 1 而不是 Z^2 (碳低 36 倍、氧低 64 倍), 且偏差与能量无关, 均值/形状判据抓不到。
% 为什么低能拼接腿也要除 (而不是"实测质子 q̄=1 所以不除") —— 三条与实现无关的判据:
%   (1) 退化一致性: Zi=1 时必须恒等于质子表 (heavy_H 与 proton 是同一粒子);
%   (2) 低速极限: beta->0 时比值 -> Z^(2/3) (Lindhard-Scharff 同速标度), 不趋于 0;
%   (3) 射程有定义: 不除时低能端 S ∝ E^1.45, ∫dE/S 在 E->0 发散, 发布射程改由表下限这个
%       人为常数决定 (独立复算见 _工作底稿/z490_qbar_arnold_recompute.log: 20->63->176->478 um)。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
Tp = tepc.transport.stoppingPower(cfg, "proton");
spBench = struct('heavy_C', struct('A',12.011,'Z',6), 'heavy_O', struct('A',15.999,'Z',8));
mech2 = 938.272;
Etest = logspace(log10(0.25), log10(50), 12);
for nm = ["heavy_C","heavy_O"]
    T = tepc.transport.stoppingPower(cfg, nm);
    A = spBench.(char(nm)).A; Z = spBench.(char(nm)).Z;
    worst = 0;
    for k = 1:numel(Etest)
        E = Etest(k);
        Ep = E/A;                                       % 每核子能量
        b = sqrt(max(1 - 1/(1 + Ep/mech2)^2, 0));
        qbar  = Z*(1 - exp(-125*b*Z^(-2/3)));
        qbarP = 1 - exp(-125*b);                        % 参考质子 (两条腿同一个口径)
        ref = tepc.transport.stopAt(Tp, Ep)*(qbar/qbarP)^2;
        got = tepc.transport.stopAt(T, E);
        worst = max(worst, abs(got/ref - 1));
    end
    tc.verifyLessThan(worst, 0.02, sprintf('%s 未按 质子表 x (qbar_ion/qbar_p)^2 标度', char(nm)));
end
% 判据 (1) 退化一致性: Zi=1 时 (qbar/qbarP)^2 恒等于 1 => heavy_H 在总能量 E 处必须**逐点等于**
% 质子表在 E/A_H 处取样。这一条专门抓"把分母换成 1": 那样 heavy_H/proton 在 10 keV/u 处只剩
% 0.19, 等于让氢自己压低 5 倍。
Th = tepc.transport.stoppingPower(cfg, "heavy_H");
for Echk = [0.0208 0.05 0.284 1.0 8.0]      % 下界取 0.0208: 再小 E/1.008 会落到质子表域外
    tc.verifyEqual(tepc.transport.stopAt(Th, Echk), tepc.transport.stopAt(Tp, Echk/1.008), ...
        'RelTol', 1e-4, sprintf( ...
        ['heavy_H != proton (E=%.3g MeV): 分母不再是同一个 qbar(1)。容差 1e-4 是 log-log ' ...
            '插值栅格本底 (241 点/4 数量级), 而"分母取 1"的错误给的是 0.19 倍 —— 差 5 个数量级'], Echk));
end
% 判据 (2) 低速极限: 发货 1 MeV 中子的 C/O 反冲全在 E/A <= 23.6 keV/u 这段, 比值必须落在
% [Z^(2/3), Z^2] 带内 (下限取 0.8 倍余量)。"漏乘前置 Z"给约 1 (红), "分母取 1"在 10 keV/u
% 给 0.93 (红)。
Tc = tepc.transport.stoppingPower(cfg, "heavy_C");
for EpQ = [0.0100 0.0208 0.0236]
    rr = tepc.transport.stopAt(Tc, EpQ*12.011)/tepc.transport.stopAt(Tp, EpQ);
    tc.verifyGreaterThan(rr, 0.8*6^(2/3), sprintf( ...
        'E/A=%.1f keV/u 比值 %.3f 低于屏蔽极限 0.8*Z^(2/3)=%.3f', EpQ*1000, rr, 0.8*6^(2/3)));
    tc.verifyLessThan(rr, 6^2*1.02, sprintf('E/A=%.1f keV/u 比值 %.3f 超过剥离极限 Z^2', EpQ*1000, rr));
end
% 两个解析极限给出量级边界, 与实现无关:
%   beta -> 1: 完全剥离, qbar -> Z      => S_ion/S_p -> Z^2   (碳 36)
%   beta -> 0: 全屏蔽,   qbar -> 125*beta*Z^(1/3) => 比值 -> Z^(2/3) (碳 3.30)
% 高 beta 端取每核子 8 MeV (碳总能量 96.1 MeV, 仍在 [0.01,100] MeV 表域内;
% 10 MeV/u 需 120.1 MeV 已越域, 禁止外推所以不能取)。
Tc = tepc.transport.stoppingPower(cfg, "heavy_C");
EpHi = 8.0;
SC = tepc.transport.stopAt(Tc, EpHi*12.011);
SP = tepc.transport.stopAt(Tp, EpHi);
bH = sqrt(max(1-1/(1+EpHi/938.272)^2,0));
rRef = (6*(1 - exp(-125*bH*6^(-2/3)))/(1 - exp(-125*bH)))^2;
rHi = SC/SP;
tc.verifyLessThan(abs(rHi/rRef - 1), 0.02, '高 beta 端与绝对有效电荷平方比一致');
tc.verifyGreaterThan(rHi, 0.8*6^2, '高 beta 端须接近剥离极限 Z^2=36 (把份额当电荷会得约 1)');
tc.verifyLessThan(rHi, 6^2*1.05, '比值不得超过剥离极限 Z^2');
% 低 beta 端 (每核子 20.8 keV) 必须落在 [Z^(2/3), Z^2] 带内: 屏蔽端极限是 Z^(2/3)=3.30,
% 剥离端是 Z^2=36 (实跑 5.60)。常数缩放缺陷 (把 zr 的除法写成 mrdivide) 会让 rHi/rLo 约等于 1
% —— 最后一条抓它; 把分母换成 1 会让它掉到 1.79 并被上一条下限抓走 (见上方判据 (2))。
rLo = tepc.transport.stopAt(Tc, 0.25)/tepc.transport.stopAt(Tp, 0.25/12.011);
tc.verifyGreaterThan(rLo, 6^(2/3)*0.9, '低 beta 比值不得低于屏蔽极限 0.9*Z^(2/3)');
tc.verifyLessThan(rLo, 6^2, '低 beta 比值必须低于剥离极限 Z^2');
tc.verifyGreaterThan(rHi/rLo, 2, '标度须随 beta 强变化 (常数缩放会得到约 1)');
end

function test_birth_point_lies_on_sampled_chord(tc)
% 反冲核诞生点必须是**同一条事件抽到的那条路径上的点**。
% 旧实现把刚抽好的 Pin/Pout 丢掉, 另在球内均匀重采样 —— 同一事件里"作用点"与
% "入射路径"互相无关。中子腿的弦现在来自 internal_isotropic: Pin 就是体积均匀的作用点,
% 弦过它 ⇒ 耦合由构造成立, 且边缘分布不被改坏 (边缘判据见下一条用例)。
% 这里锁三件事, 全部与实现内部无关:
%   (1) 默认模式必须真的是 chord (只读配置缺省值, 不许"代码改了默认没换");
%   (2) chord 模式给的所有点都在弦上 (到直线垂距到机器零) 且在腔内;
%   (3) volume 对照模式确实**不在**弦上 —— 否则开关是装饰, (2) 可能恒成立。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
tc.verifyFalse(isfield(cfg,'transport') && isfield(cfg.transport,'birthPoint'), ...
    'config/defaults 里已经写了 transport.birthPoint: 默认口径被钉死, 缺省分支不再被走');
R0 = tepc.config.resolve(cfg);
geom = R0.geom;
cc = cfg; cc.transport.birthPoint = "chord";
cv = cfg; cv.transport.birthPoint = "volume";
rs = RandStream('Threefry', 'Seed', 4243);
N = 300;
dmax = 0; nOut = 0; dvol = 0; ddef = 0;
for k = 1:N
    [~, Pin, Pout] = tepc.geometry.sampleChord(geom, 1, "isotropic_external", rs);
    e = (Pout - Pin)/max(norm(Pout - Pin), eps);
    Pc = tepc.transport.birthPoint(geom, cc, Pin, Pout, rs);
    d  = Pc - Pin;
    dmax = max(dmax, norm(d - dot(d, e)*e));
    if norm(Pc) > geom.R_m*(1 + 1e-12), nOut = nOut + 1; end
    Pv = tepc.transport.birthPoint(geom, cv, Pin, Pout, rs);
    dv = Pv - Pin;
    dvol = max(dvol, norm(dv - dot(dv, e)*e));
    % 缺省分支必须**真的被喂一次**: 上面两条都显式传了 cc/cv, 只断言"config 里没这个键"
    % 并不能锁住缺省值 —— 把 birthPoint.m 的 mode 初值改成 "volume" 时那两条照样全绿。
    Pd = tepc.transport.birthPoint(geom, cfg, Pin, Pout, rs);
    dd = Pd - Pin;
    ddef = max(ddef, norm(dd - dot(dd, e)*e));
end
tc.verifyEqual(ddef, 0, 'AbsTol', 1e-15*geom.R_m, sprintf( ...
    '不传 transport.birthPoint 时诞生点不在弦上 (最大垂距 %.3e m): 缺省值不是 chord', ddef));
tc.verifyEqual(dmax, 0, 'AbsTol', 1e-15*geom.R_m, ...
    sprintf('chord 模式有诞生点离开弦 (最大垂距 %.3e m, 腔半径 %.3e m)', dmax, geom.R_m));
tc.verifyEqual(nOut, 0, sprintf('有 %d 个诞生点落在腔外: 弦上的点必须在腔内', nOut));
tc.verifyGreaterThan(dvol, 1e-3*geom.R_m, sprintf( ...
    'volume 对照模式的垂距只有 %.3e m: 两条路径没区别, 开关是装饰', dvol));
% 非法值必须报错, 不许静默退回某条腿 (锁的是 error identifier, 不是消息文字)
bad = cfg; bad.transport.birthPoint = "surface";
try
    tepc.transport.birthPoint(geom, bad, [0;0;0], [geom.R_m;0;0], rs);
    tc.verifyFail('surface 模式没有被拒绝');
catch err
    tc.verifyTrue(contains(string(err.identifier), 'BadBirthMode'), ...
        sprintf('surface 被拒绝了, 但错误 identifier 不是 BadBirthMode: %s', err.identifier));
end
% 非球腔必须在运行时被拒: config/validate.m 的 TRANSPORT_GEOM_SPHERE_ONLY 警告与 GUI 上
% 同一句话都承诺"运行时会以 tepc:transport:Geom 拒绝"。这条守卫原先住在 sampleInVolume 里
% (每个中子事件必撞), 诞生点默认改走弦后被绕过 ⇒ csdaTransport 会拿 geom.R_m 当球半径,
% 把有限圆柱静默按内切球出数。把守卫搬回 birthPoint 入口, 这里钉住它。
gc = geom; gc.type = "cylinder_finite";
tc.verifyError(@() tepc.transport.birthPoint(gc, cfg, [0;0;0], [geom.R_m;0;0], rs), ...
    'tepc:transport:Geom');
end
function test_birth_point_measure_is_volume_uniform(tc)
% 这条锁的是**度量**, 不是耦合 —— 上一版落弦写成 P0 = Pin + u*(Pout-Pin) 时, 诞生点确实
% "在弦上", 但那是"对 IUR 弦再取均匀", 把作用点的径向分布推向腔壁: 实测
% P(r>0.9R)=0.379, 而体积均匀应当是 1-0.9^3=0.271 (2e6 样本独立复算)。均匀注量下
% "发生了作用"的点必须体积均匀, 所以那版虽然"修好了耦合"却改错了度量, y_F 被带偏 -8.6%。
% 判据两条独立来源: ① chord 模式对 internal_isotropic 弦必须逐点等于 Pin (耦合), 且其
% 径向分布与体积均匀闭式一致 (5σ 内); ② 反例腿: 同一批弦上"沿弦取均匀点"必须明显偏离
% 闭式 —— 否则这条锁是恒绿的, 抓不到把度量改坏的那一类回归。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
R0 = tepc.config.resolve(cfg);
geom = R0.geom;
cc = cfg; cc.transport.birthPoint = "chord";
rs = RandStream('Threefry', 'Seed', 4245);
M = 20000;
r09 = 0.9 * geom.R_m;
nPin = 0; nAlong = 0; dmax = 0;
for k = 1:M
    [~, Pin, Pout] = tepc.geometry.sampleChord(geom, 1, "internal_isotropic", rs);
    Pc = tepc.transport.birthPoint(geom, cc, Pin, Pout, rs);
    dmax = max(dmax, norm(Pc - Pin(:)));
    if norm(Pc) > r09, nPin = nPin + 1; end
    u = rand(rs,1);
    if norm(Pin(:) + u*(Pout(:) - Pin(:))) > r09, nAlong = nAlong + 1; end
end
pRef = 1 - 0.9^3;
se = sqrt(pRef*(1-pRef)/M);
p1 = nPin/M; p2 = nAlong/M;
tc.verifyEqual(dmax, 0, 'AbsTol', 1e-15*geom.R_m, sprintf( ...
    'chord 模式不再等于抽样器给的体内点 (最大偏离 %.3e m): 耦合被改回"另取一点"', dmax));
tc.verifyLessThan(abs(p1 - pRef), 5*se, sprintf( ...
    '诞生点径向分布偏离体积均匀: P(r>0.9R)=%.4f, 闭式 %.4f, 5σ=%.4f —— 度量被改坏 (壁偏)', ...
    p1, pRef, 5*se));
tc.verifyGreaterThan(p2 - pRef, 10*se, sprintf( ...
    '反例腿失效: "沿弦取均匀点"的 P(r>0.9R)=%.4f 没有显著偏离闭式 %.4f (差 %.0f σ)  上面那条体积均匀判据是恒绿装饰, 抓不到壁偏回归', p2, pRef, (p2-pRef)/se));
fprintf(['[birth-measure] P(r>0.9R) chord=%.4f 沿弦均匀=%.4f 闭式=%.4f 5sigma=%.4f' newline], ...
    p1, p2, pRef, 5*se);
end


function test_stopping_domain_guard(tc)
% 阻止本领表的域守卫 (域外必须抛错, flag 模式返回 NaN)。这一段曾被上一次编辑
% 误并进 test_birth_point_lies_on_sampled_chord 的函数体里, 使本用例从套件里消失
% —— 用例数没涨、绿色却照常, 是"静默丢用例"的现成例子。
cfg = struct('gas', struct('composition_molfrac', struct('H2O',1)));
Tw = tepc.transport.stoppingPower(cfg, "proton");
tc.verifyError(@() tepc.transport.stopAt(Tw, 200.0), 'tepc:stopping:OutOfRange');
tc.verifyError(@() tepc.transport.stopAt(Tw, 1e-4), 'tepc:stopping:OutOfRange');
[S, inD] = tepc.transport.stopAt(Tw, [1.0 200.0], struct('mode',"flag"));
tc.verifyEqual(inD, [true; false]);
tc.verifyTrue(isnan(S(2)), 'flag 模式域外返回 NaN');
tc.verifyTrue(isfinite(S(1)));
tc.verifyError(@() tepc.transport.stopAt(Tw, 1.0, struct('mode',"nope")), ...
    'tepc:stopping:BadMode');
tc.verifyError(@() tepc.transport.stoppingPower(cfg, "muon"), 'tepc:stopping:BadParticle');
end

function test_bragg_curve_shape(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
Tp = tepc.transport.stoppingPower(cfg, "proton");
% 峰应在 80 keV 附近且高于两侧
Spk = tepc.transport.stopAt(Tp, 0.08);
tc.verifyGreaterThan(Spk, tepc.transport.stopAt(Tp, 0.3));
tc.verifyGreaterThan(Spk, tepc.transport.stopAt(Tp, 0.03));
tc.verifyGreaterThan(Spk, tepc.transport.stopAt(Tp, 1.0)*2.5, '峰值应显著高于 1 MeV');
end

function test_compton_kn_mean_electron_energy(tc)
% 单色 662 keV: 反冲电子平均能量必须匹配 Klein-Nishina 解析矩。
%   d(sigma)/dE' ~ [r + 1/r - sin^2(theta)] (Klein-Nishina 的 r^2 与态密度
%   Jacobian dE'/dcos = alpha*E'^2/E0 精确相消); 保留 r^2 会把均值压低到 0.156 MeV。
rs = RandStream('Threefry','Seed',5);
mec2 = 0.510998950; E0 = 0.6617;
N = 200000;
[Ee, Eg, ct] = tepc.transport.comptonKN(E0, N, rs);
tc.verifyEqual(numel(Ee), N);
tc.verifyLessThan(max(abs(ct - (1 - mec2*(1./Eg - 1/E0)))), 1e-9, 'KN 角-能关系精确');
tc.verifyLessThan(max(abs(Ee + Eg - E0)), 1e-12, '能量守恒');
tc.verifyGreaterThanOrEqual(min(Ee), 0);
eEdge = 2*E0^2/(mec2 + 2*E0);                     % 康普顿边 (最大反冲电子能)
tc.verifyLessThanOrEqual(max(Ee), eEdge + 1e-9, '反冲电子能不得超过康普顿边');
tc.verifyGreaterThan(max(Ee), 0.9*eEdge, '抽样应覆盖到康普顿边附近');
meanEeRef = knMeanElectronEnergy(E0, mec2);             % 解析闭式 (见本地函数)
se = std(Ee)/sqrt(numel(Ee));
tc.verifyLessThan(abs(mean(Ee) - meanEeRef), max(0.02*meanEeRef, 5*se), ...
    sprintf('<Ee>=%.4f MeV 应匹配 KN 解析矩 %.4f MeV', mean(Ee), meanEeRef));
% 662 keV 的 KN 解析矩 (独立核对值): 0.2525 MeV
tc.verifyLessThan(abs(meanEeRef - 0.2525), 0.002, '解析矩自身须与登记值一致');
% 判别力: 被积函数残留 r.^2 (历史缺陷) 会把均值压到 ~0.156 MeV
meanR2 = knMeanElectronEnergyR2Bug(E0, mec2);
tc.verifyGreaterThan(abs(mean(Ee) - meanR2), 0.2*meanR2, ...
    '抽样不得仍带 r^2 权 (那会把均值压低 38%)');
% 另一能量处再核一次 (排除"只在 662 keV 巧合")
[Ee2, ~, ~] = tepc.transport.comptonKN(2.0, 100000, RandStream('Threefry','Seed',6));
ref2 = knMeanElectronEnergy(2.0, mec2);
tc.verifyLessThan(abs(mean(Ee2) - ref2)/ref2, 0.02, '2 MeV 处均值亦须匹配解析矩');
end

function test_elastic_kinematics_ledger(tc)
rs = RandStream('Threefry','Seed',9);
for ch = ["elastic_H","elastic_C","elastic_O"]
    nc = tepc.transport.nuclearChannel(1.0, ch, [0;0;1], rs);
    tc.verifyLessThan(abs(nc.recoil.E_MeV + nc.E_n_prime_MeV - 1.0), 1e-12, ...
        sprintf('%s 两体账本精确闭合', ch));
end
% H: 各向同性 CM -> E_R 严格均匀 [0,E_n], 均值 E_n/2
nS = 20000; acc = 0;
for i = 1:nS
    ncH = tepc.transport.nuclearChannel(1.0, "elastic_H", [0;0;1], rs);
    acc = acc + ncH.recoil.E_MeV;
end
meanER = acc/nS;
tc.verifyLessThan(abs(meanER - 0.5), 5*(1/sqrt(12))/sqrt(nS), 'H 反冲均值 E_n/2');
ncC = tepc.transport.nuclearChannel(1.0, "elastic_C", [0;0;1], rs);
tc.verifyLessThan(ncC.recoil.E_MeV, 4*12/169 + 1e-12, 'C 反冲不超过运动学上限');
end

function test_csda_ledger_closure(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
geom = tepc.geometry.buildGeometry(cfg);
[rho,~] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, cfg.gas.temperature_K, ...
    cfg.gas.composition_molfrac, 1.0);
Tp = tepc.transport.stoppingPower(cfg, "proton");
rs = RandStream('Threefry','Seed',11);
for E0 = [0.02, 0.05, 1.0]
    led = tepc.transport.csdaTransport(Tp, [0;0;0], [1;0;0], E0, geom, rho, rs, ...
        struct('straggle',true));
    tot = led.EdepGas_keV + led.EdepWall_keV + led.Eescape_keV;
    tc.verifyLessThan(abs(tot - E0*1e3), 0.005*E0*1e3 + 0.05, ...
        sprintf('E0=%.0f keV 能量账本闭合', E0*1e3));
    tc.verifyTrue(isfield(led, 'nSteps') && led.nSteps > 0, 'nSteps 必须回报');
end
% 壁效应标志必须用 Flags 常量 (WALL_LOSS=16, ESCAPE=32)。
% 发货几何是 3 mm A-150 (名义密度 1.124 g/cm3) —— 1 MeV 质子在其中的射程约 70 um,
% 被壁完全吸收, 因此"应穿出薄壁"这个前提对发货配置根本不成立 (实测 Eescape=0)。
% 原断言把"薄壁"当成发货事实, 是测试期望错; 但 ESCAPE 分支确实必须可达, 于是这里
% 用两个人造壁厚分别钉住两条分支。
led = tepc.transport.csdaTransport(Tp, [0;0;0], [1;0;0], 1.0, geom, rho, ...
    RandStream('Threefry','Seed',3), struct('straggle',false));
tc.verifyGreaterThan(led.EdepWall_keV, 0, '出腔剩余能量须在壁内沉积 (才有标志可核)');
tc.verifyEqual(led.Eescape_keV, 0, 'AbsTol', 1e-9, '3 mm 厚壁必须完全吸收 1 MeV 质子');
tc.verifyTrue(bitand(led.flags, uint32(16)) > 0, '壁内沉积须置 WALL_LOSS(16)');
tc.verifyFalse(bitand(led.flags, uint32(32)) > 0, '未逸出不得置 ESCAPE(32)');
thin = struct('straggle',false,'wallThickness_m',1e-6);
ledT = tepc.transport.csdaTransport(Tp, [0;0;0], [1;0;0], 1.0, geom, rho, ...
    RandStream('Threefry','Seed',3), thin);
tc.verifyGreaterThan(ledT.Eescape_keV, 0, '1 um 薄壁必须让大部分能量逸出 (ESCAPE 分支可达)');
tc.verifyTrue(bitand(ledT.flags, uint32(32)) > 0, '逸出须置 ESCAPE(32)');
tc.verifyTrue(bitand(ledT.flags, uint32(16)) > 0, '薄壁仍有壁内沉积 => 两标志同时置位');
tc.verifyLessThan(abs(ledT.EdepGas_keV + ledT.EdepWall_keV + ledT.Eescape_keV - 1e3), 1e-6, ...
    '薄壁分支的账本同样必须逐事件闭合');
% 起点落在壁壳层内时按**介质分段**处理: 壁段按壁密度计费、腔段按气体计费。
% 这条锁钉的是分段之后的三件事: 腔内路径不得超过 2R (分段前实测超出量恰等于壁段长)、
% 账本逐事件闭合 (加"="而不是"+="的近壁沉积覆盖缺陷, 实测会让 500 keV 只剩 70.8 keV)、
% 三种朝向都有确定口径 (朝心穿腔 / 朝外在逸出 / 切向不入腔)。
Rg = geom.R_m;  tw = geom.wallThickness_m;
Pwall = [Rg + tw/2; 0; 0];
Te = tepc.transport.stoppingPower(cfg, "electron");
ledW1 = tepc.transport.csdaTransport(Te, Pwall, [-1;0;0], 0.5, geom, rho, ...
    RandStream('Threefry','Seed',7), struct('straggle',false));
tc.verifyLessThanOrEqual(ledW1.gasPath_m, 2*Rg + 1e-12, sprintf( ...
    '壁内朝心起点的腔内路径 %.6e m 超过腔直径 %.6e m: 壁段又被按气体计了', ...
    ledW1.gasPath_m, 2*Rg));
tc.verifyEqual(ledW1.gasPath_m, 2*Rg, 'AbsTol', 1e-9, ...
    '入腔后应贯穿整条直径: 腔内路径不等于 2R 说明分段点算错');
tc.verifyLessThan(abs(ledW1.EdepGas_keV + ledW1.EdepWall_keV + ledW1.Eescape_keV - 500), 1e-9, ...
    sprintf('壁内朝心的账本差 %.3e keV: 近壁沉积被覆盖或漏记', ...
    ledW1.EdepGas_keV + ledW1.EdepWall_keV + ledW1.Eescape_keV - 500));
tc.verifyGreaterThan(ledW1.EdepWall_keV, 100, ...
    '500 keV 电子穿过 1.5 mm A-150 应掉上百 keV; 实得过小说明壁段没按壁密度计费');
ledW2 = tepc.transport.csdaTransport(Te, Pwall, [1;0;0], 0.5, geom, rho, ...
    RandStream('Threefry','Seed',7), struct('straggle',false));
tc.verifyEqual(ledW2.gasPath_m, 0, 'AbsTol', 1e-12, ...
    '壁内朝外的粒子不该有任何腔内路径 (分段前会塌成"已在边界")');
tc.verifyLessThan(abs(ledW2.EdepGas_keV + ledW2.EdepWall_keV + ledW2.Eescape_keV - 500), 1e-9, ...
    '壁内朝外的账本必须闭合');
tc.verifyTrue(bitand(ledW2.flags, uint32(32)) > 0, '未进腔而从外壁离开须置 ESCAPE(32)');
ledW3 = tepc.transport.csdaTransport(Te, Pwall, [0;1;0], 0.5, geom, rho, ...
    RandStream('Threefry','Seed',7), struct('straggle',false));
tc.verifyEqual(ledW3.gasPath_m, 0, 'AbsTol', 1e-12, '切向起点不应进入气腔');
tc.verifyLessThan(abs(ledW3.EdepGas_keV + ledW3.EdepWall_keV + ledW3.Eescape_keV - 500), 1e-9, ...
    '切向的账本必须闭合');
% 近外壁产生者被壁吸收: 0.5 MeV 电子在 A-150 里的射程小于剩余壁厚 ⇒ 根本进不了腔
ledW4 = tepc.transport.csdaTransport(Te, [Rg + 0.95*tw; 0; 0], [-1;0;0], 0.5, geom, rho, ...
    RandStream('Threefry','Seed',7), struct('straggle',false));
tc.verifyEqual(ledW4.gasPath_m, 0, 'AbsTol', 1e-12, ...
    '从近外壁产生、向内的 0.5 MeV 电子射程不足以穿过剩余壁厚, 不得出现腔内路径');
tc.verifyTrue(bitand(ledW4.flags, uint32(16)) > 0, '被壁吸收须置 WALL_LOSS(16)');
% 装置之外仍然拒绝
tc.verifyError(@() tepc.transport.csdaTransport(Te, [Rg + tw + 1e-3; 0; 0], [-1;0;0], 0.5, ...
    geom, rho, RandStream('Threefry','Seed',7), struct()), 'tepc:csda:OutsideGas', ...
    '起点在装置外必须显式拒绝, 不能靠分段把无口径的输入硬算出一个数');
ledIn = tepc.transport.csdaTransport(Te, [0;0;0], [1;0;0], 0.5, geom, rho, ...
    RandStream('Threefry','Seed',7), struct('straggle',false));
tc.verifyLessThanOrEqual(ledIn.gasPath_m, 2*Rg + 1e-12, sprintf( ...
    '腔内起点的 gasPath %.6e m 超过腔直径 %.6e m: 有非气体段被按气体计了', ...
    ledIn.gasPath_m, 2*Rg));
tc.verifyEqual(ledIn.gasPath_m, Rg, 'AbsTol', 1e-12, ...
    '腔心起点的腔内路径必须等于 R: 不等于说明分段改动动了发货路径');
end

function test_csda_straggling_is_two_sided(tc)
% Bohr 涨落必须是双侧 (dE = <dE> + randn*Omega): 原实现用 abs(randn) 单边,
% 使平均沉积系统性偏高 +8~9%。此处同一条几何路径上比较 有涨落/无涨落。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
geom = tepc.geometry.buildGeometry(cfg);
[rho,~] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, cfg.gas.temperature_K, ...
    cfg.gas.composition_molfrac, 1.0);
Tp = tepc.transport.stoppingPower(cfg, "proton");
E0 = 0.08;                                   % Bragg 峰附近: 涨落/均值比最大
det = tepc.transport.csdaTransport(Tp, [0;0;0], [1;0;0], E0, geom, rho, ...
    RandStream('Threefry','Seed',2), struct('straggle',false));
det2 = tepc.transport.csdaTransport(Tp, [0;0;0], [1;0;0], E0, geom, rho, ...
    RandStream('Threefry','Seed',999), struct('straggle',false));
tc.verifyEqual(det.EdepGas_keV, det2.EdepGas_keV, '无涨落基准必须与 RNG 无关 (确定性)');
tc.verifyEqual(det.Eescape_keV, 0, 'AbsTol', 1e-9, '剩余 ~60 keV 质子不得穿过厚壁');
tc.verifyGreaterThan(det.EdepWall_keV, 0, '基准应在壁内停住 (才有气/壁分配可比)');
rs = RandStream('Threefry','Seed',2);
N = 400;
vals = zeros(N,1);
for k = 1:N
    led = tepc.transport.csdaTransport(Tp, [0;0;0], [1;0;0], E0, geom, rho, rs, ...
        struct('straggle',true));
    % 只能比"气腔沉积": 三项之和由账本恒等式钉死为 E0 (实测 max|tot-E0*1e3|=4.3e-14),
    % 拿它去比无涨落基准 (21.03 keV) 得到一个与涨落双侧性无关的 3.8 倍 (原断言)。
    vals(k) = led.EdepGas_keV;
    tc.verifyLessThan(abs((led.EdepGas_keV + led.EdepWall_keV + led.Eescape_keV) ...
        - E0*1e3), 1e-9*E0*1e3 + 1e-6, '逐事件账本必须闭合');
end
tc.verifyGreaterThan(var(vals), 0, '开启涨落后沉积必须逐事件不同');
ref = det.EdepGas_keV;
tc.verifyGreaterThan(ref, 0);
seRel = std(vals)/mean(vals)/sqrt(N);
% 地板 0.02 不是拍的: 单独把 N 提到 3000 量过这个偏差本身 —— E0=0.08 处 -1.78e-3,
% E0=0.30 处 -2.95e-3 (都只有 ~1.5 倍 MC 标准误, 与零不可区分), 见 csdaTransport.m 头
% 注释与 临时/验证脚本/z76_log.txt。原来的 0.05 比测量值宽一个量级, 换不来可靠性。
tc.verifyLessThan(abs(mean(vals)/ref - 1), max(4*seRel, 0.02), ...
    sprintf('有涨落均值 (%.4g keV) 应等于无涨落基准 (%.4g keV); 单边涨落会偏 +8~9%% (4u_SE=%.3f, 实测截断偏置 <=3e-3)', ...
    mean(vals), ref, 4*seRel));
% 双侧性直接可见: 必须有相当比例的事件低于基准 (单边 abs(randn) 做不到)
tc.verifyGreaterThan(nnz(vals < ref)/N, 0.2, '涨落必须双侧 (一半左右事件应低于均值)');
tc.verifyGreaterThan(nnz(vals > ref)/N, 0.2, '涨落必须双侧 (一半左右事件应高于均值)');
end

% ---------------- 本地参照实现 ----------------
function m = knMeanElectronEnergy(E0, mec2)
% 由 Klein-Nishina 的 d(sigma)/dE' ~ [x + 1/x - 1 + cos^2(theta)] 闭式积分求
%   <E'> = E0 * int(x*g)/int(g),  <Ee> = E0 - <E'>,  x = E'/E0 in [1/(1+2a), 1]
%   cos(theta) = 1 - (1/x - 1)/alpha, alpha = E0/mec2
alpha = E0/mec2;
x0 = 1/(1 + 2*alpha); x1 = 1;
L = log(x1/x0); A = x1 - x0; B = (x1^2 - x0^2)/2; C = (x1^3 - x0^3)/3;
D2 = 1/x0 - 1/x1;
iC2 = A - (2/alpha)*(L - A) + (1/alpha^2)*(D2 - 2*L + A);      % int cos^2
Ig  = B + L - A + iC2;
iCx = B - (2/alpha)*(A - B) + (1/alpha^2)*(L - 2*A + B);       % int x*cos^2
Ixg = C + A - B + iCx;
m = E0 - E0*Ixg/Ig;
end

function m = knMeanElectronEnergyR2Bug(E0, mec2)
% 同一矩, 但被积函数保留 r.^2 (历史缺陷) -> 数值积分 (仅用于证明前者有判别力)
alpha = E0/mec2;
x = linspace(1/(1+2*alpha), 1, 200001).';
c = 1 - (1./x - 1)/alpha;
g = x.^2 .* (x + 1./x - 1 + c.^2);
m = E0 - E0*(trapz(x, x.*g)/trapz(x, g));
end

function test_csda_range_matches_pstar_water_integral(tc)
% 积分级 + 逐点级外部对标 (官方 NIST PSTAR 88 点表, 10 keV - 100 MeV, 液态水)。
%   两条腿各管各的, 都要有:
%   (a) 逐点 S: 约束整条曲线形状, 点锚定只约束单个穿越点;
%   (b) 积分射程: R(E)=∫dE/S 比 **csda_mm_water**, 但只在 E>=2 MeV 上做 ——
%       本实现只积 [0.01 MeV, E], NIST 的 CSDA 从 0 积起, 低能端少积的那一截会被
%       当成模型误差 (实测 <80 keV 段最大 82 %, 而同段逐点 S 只有 26 %)。
%   取数一律按**列名**: 第 2 列是投影射程、第 3 列才是 CSDA, 按位置取列一旦表加一列
%   就会静默换语义。
root = tepc.io.projectRoot();
f = fullfile(root, 'config', 'reference', 'pstar_water_proton_range.csv');
tc.verifyTrue(isfile(f), 'PSTAR 射程锚点表必须存在');
E    = pstarCol(f, 'energy_MeV');
Rcsd = pstarCol(f, 'csda_mm_water');
Rprj = pstarCol(f, 'range_mm_water');
Sobs = pstarCol(f, 'S_total_MeV_cm2_g');
tc.verifyEqual(numel(E), 88, '官方表必须 88 个能量点 (10 keV-100 MeV)');
tc.verifyTrue(all(diff(E) > 0), '能量列必须严格递增');
tc.verifyTrue(all(diff(Rcsd) > 0), 'CSDA 列必须对能量单调增 (数据自证)');
% 列身份自证: 两列在低能端必须明显不同, 否则"按名字取列"这条规矩没有可观测的后果
tc.verifyGreaterThan(abs(Rcsd(1)/Rprj(1) - 1), 0.2, ...
    '投影射程与 CSDA 在低能端必须可分辨 (若两列变得一样, 本用例的列名口径就失去保护)');
% 反例腿: 要一个不存在的列名必须报错, 不能静默给 NaN/0
tc.verifyError(@()pstarCol(f, 'csda_mm_water_x'), ...
    'tepc:transport:PstarColMissing', '列名不存在必须报错 (静默取空等于判据消失)');

cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
cfg.gas.composition_molfrac = struct('H2O', 1);
cfg.gas.I_eV_override = 75.0;
T = tepc.transport.stoppingPower(cfg, 'proton');
T.rho_g_cm3 = 1.0;

% (a) 逐点 S: 三带各用各的容差, 与 stoppingPower 声明的精度分级一致
bands = {0.0, 0.080, 0.30; 0.080, 1.0, 0.20; 1.0, Inf, 0.05};
for b = 1:size(bands, 1)
    lo = bands{b,1}; hi = bands{b,2}; tol = bands{b,3};
    m = E > lo & E <= hi;
    Sm = arrayfun(@(e) tepc.transport.stopAt(T, e), E(m));
    r = Sm(:)./Sobs(m) - 1;
    tc.verifyLessThanOrEqual(max(abs(r)), tol, sprintf( ...
        'S 逐点 (%.3g,%.3g] MeV n=%d 偏差 max %.2f%% 必须 <= %.0f%% (实测中位 %.2f%%)', ...
        lo, hi, nnz(m), 100*max(abs(r)), 100*tol, 100*median(r)));
end

% (b) 积分射程: E>=2 MeV, 比 CSDA 列。符号区间实测 -1.25%..+0.63%, 所以**不能**再断言同号
mR = E >= 2.0;
o = tepc.transport.csdaRange(T, E(mR));
tc.verifyEqual(o.n_truncated, 0, 'E>=2 MeV 全在表域内, 不该有任何截断点');
rel = o.range_mm(:)./Rcsd(mR) - 1;
tc.verifyLessThanOrEqual(max(abs(rel)), 0.02, ...
    sprintf('射程相对偏差 max %.2f%% (E>=2 MeV, n=%d, 比 csda_mm_water)', ...
    100*max(abs(rel)), nnz(mR)));
% 判别力: 把 S 整体抬高 11% 必须让射程腿红 (实测 1.25% -> 11.03%, 2% 门)
Tb = T; Tb.S_mass = T.S_mass*1.11; Tb.lgStab = log(Tb.S_mass(:));
ob = tepc.transport.csdaRange(Tb, E(mR));
tc.verifyGreaterThan(max(abs(ob.range_mm(:)./Rcsd(mR) - 1)), 0.02, ...
    '射程锚定对阻止本领的整体偏移必须有判别力');
% 域外不得静默外推
oc = tepc.transport.csdaRange(T, 5000);
tc.verifyTrue(any(oc.truncated), '能量超出表上限必须标 truncated, 不得外推');
% 表下限那一格本身也必须可求: E == Emin 时积分栅格会塌成 1 个点, trapz 对标量直接报错
% ("维度参数必须是正整数"), 而参考表的首行往往就是那个下限值 (官方 PSTAR 88 点表首行 = 0.01 MeV)。
of = tepc.transport.csdaRange(T, T.domain_MeV(1));
tc.verifyTrue(isfield(of, 'range_mm') && all(isfinite(of.range_mm)) && all(of.range_mm > 0), ...
    'E 恰等于表域下限时必须给出有限正射程, 不得报错也不得给 0');
tc.verifyTrue(all(of.truncated), '下限那一格只积了残差段, 必须标 truncated');
of2 = tepc.transport.csdaRange(T, [T.domain_MeV(1)*0.5 T.domain_MeV(1)*(1-1e-12)]);
tc.verifyTrue(all(of2.truncated), '低于下限同样要标 truncated');
tc.verifyLessThan(of2.range_mm(1), of2.range_mm(2), '残差段射程必须随能量单调增');
% 容差必须比"贴近下限的步长"松一档以上: 残差段是 E/S(1) 的线性式, 用 1-1e-6 去贴却要求 1e-6
% 相对一致, 红的是这条判据自己的量级, 不是实现。
tc.verifyEqual(of2.range_mm(2), of.range_mm, 'RelTol', 1e-9, ...
    '下限两侧必须连续: 残差分支若排在积分之后, 这一格会直接报错而不是连续');
end

function test_channel_column_recorded_and_pure(tc)
% 核种道标签必须逐事件落列, 并与两体运动学的支持集一致。
%   纯度是构造性的: E_R 均匀于 [0, 4A/(A+1)^2*E_n], 碳的上限低于氢, 所以
%   "反冲能高于碳上限"的事件只可能是氢 —— 与 CM 各向同性那个 ASSUMED 无关。
%   这条同时也是"为什么必须存列"的证据: 反过来从能量推核种只有单向纯度,
%   碳/氧在混合谱里不可分, 不存列就永久丢掉了这个机理轴。
root = tepc.io.projectRoot();
cfg  = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
R    = tepc.config.resolve(cfg);
tables = struct('proton',   tepc.transport.stoppingPower(cfg, 'proton'), ...
                'electron', tepc.transport.stoppingPower(cfg, 'electron'), ...
                'heavy_C',  tepc.transport.stoppingPower(cfg, 'heavy_C'), ...
                'heavy_O',  tepc.transport.stoppingPower(cfg, 'heavy_O'));
rs = RandStream('mt19937ar', 'Seed', 1);
N  = 1200;
[Eb, ~] = tepc.transport.AnalyticAdapter(cfg, R.geom, tables, rs, N, 1, struct('tNext', 0));
cid = Eb.ev.channelId;
tc.verifyEqual(class(cid), 'uint8', '道标签必须是 uint8 (与 HDF5 列型一致)');
tc.verifyEqual(numel(cid), N, '逐事件一列, 长度必须等于事件数');
tc.verifyTrue(all(ismember(cid, [0 1 2 3])), ...
    sprintf('出现未定义道码: %s', mat2str(unique(cid(:))')));
% 发货权重下三种核都会出现 (p_H/C/O 约 0.814/0.109/0.077, N=1200 下碳/氧的期望约 131/93)
for c = 1:3
    tc.verifyGreaterThan(sum(cid == c), 0, ...
        sprintf('道 %d 在发货混合里一次都没出现: 标签被压平了', c));
end
EmaxC_keV = 4*12/13^2 * cfg.source.energy_MeV * 1e3;
hi = Eb.ev.Esecondary_keV > EmaxC_keV;
tc.verifyGreaterThan(nnz(hi), 0, '没有事件落在碳上限之上: 这条纯度判据没被exercised');
tc.verifyTrue(all(cid(hi) == 1), ...
    sprintf('%d 条反冲能超碳上限却不是氢道', nnz(hi & cid ~= 1)));
% 光子分支没有核反应道: 必须是 0。不复位的话它会沿用上一条中子事件的标签。
cfgG = cfg; cfgG.source.type = "mono_gamma";
[Eg, ~] = tepc.transport.AnalyticAdapter(cfgG, R.geom, tables, rs, 200, 90001, struct('tNext', 0));
tc.verifyTrue(all(Eg.ev.channelId == 0), '光子事件必须记 0 道 (陈旧标签会伪装成中子事件)');
% 混合源腿: 光子事件必须记 0 —— 而且要紧跟在中子事件之后也记 0, 这才是
% 「每事件复位 ch」这条 init 的真判据 (不复位就会沿用上一条中子的道)。
cfgM = cfg;
cfgM.source.type = "mixed";
cfgM.source.classPrior = struct('neutron', 0.5, 'gamma', 0.5);
[Em, ~] = tepc.transport.AnalyticAdapter(cfgM, R.geom, tables, rs, 600, 77001, struct('tNext', 0));
isGamma = double(Em.ev.primaryClass) == 2;
isNeut  = double(Em.ev.primaryClass) == 1;
tc.verifyGreaterThan(nnz(isGamma), 0, '混合腿一条光子事件都没抽到: 本判据没被 exercised');
tc.verifyGreaterThan(nnz(isNeut), 0, '混合腿一条中子事件都没抽到');
tc.verifyTrue(all(Em.ev.channelId(isGamma) == 0), ...
    sprintf('%d 条光子事件带了核反应道标签 (ch 未复位)', nnz(isGamma & Em.ev.channelId ~= 0)));
tc.verifyTrue(all(ismember(Em.ev.channelId(isNeut), [1 2 3])), ...
    '中子事件道标签为 0: 混合腿里通道选择被跳过');
% 落盘往返: 列型与值都必须原样回来
f = fullfile(tempdir, sprintf('tepc_channel_%d.h5', feature('getpid')));
tidy = onCleanup(@() deleteIfExists(f));
tepc.io.writeEventsH5(f, Eb, struct('schema_version', 'test_channel_column'));
Er = tepc.io.readEventsH5(f);
tc.verifyEqual(class(Er.ev.channelId), 'uint8', '读回后道列型变了');
tc.verifyEqual(Er.ev.channelId, cid, '读回的道标签与写出不逐位相同');
% ---- 壁生次级腿 (伽马作用点改按"入射壁 -> 气腔 -> 出射壁"整条线路抽样) ----
% 四条判据各挡一种回归: 壁腿被删 / 账本被破 / 标志位漏给中子 / 气腿又变回主导。
[EgW, ~] = tepc.transport.AnalyticAdapter(cfgG, R.geom, tables, rs, 1500, 91001, ...
    struct('tNext', 0));
wF = bitand(EgW.ev.flags, uint32(8192)) > 0;
gasDep = EgW.ev.EdepGas_keV > 0;
resW = EgW.ev.Esecondary_keV - (EgW.ev.EdepGas_keV + EgW.ev.EdepWall_keV + EgW.ev.Eescape_keV);
tc.verifyGreaterThan(nnz(wF), 20, sprintf( ...
    ['1500 个 662 keV 光子事件里只有 %d 个作用点落在壁内: 预期约 110 (壁作用概率 ~7e-2), ' ...
     '这个数掉到 0 就是壁腿被删掉了'], nnz(wF)));
tc.verifyLessThan(max(abs(resW)), 1e-6, sprintf( ...
    '伽马腿逐事件账本最大残差 %.3e keV: 壁段/腔段/逸出三项没有穷尽次级能量', max(abs(resW))));
tc.verifyLessThanOrEqual(nnz(gasDep & ~wF), max(1, round(nnz(gasDep & wF)/100)), sprintf( ...
    ['气内作用产生沉积的事件 %d 条, 壁内作用产生沉积的 %d 条: 同一张 μ/ρ 下壁比气容易作用 ' ...
     '约 9.4e3 倍, 气腿不该接近壁腿'], nnz(gasDep & ~wF), nnz(gasDep & wF)));
tc.verifyFalse(any(bitand(Eb.ev.flags, uint32(8192)) > 0), ...
    'SECONDARY_FROM_WALL 出现在中子事件上: 该标志只由伽马腿置位');
% 幅值锁: 壁作用份额必须与"由发货常数算出的壁光学厚度"同量级 (3 倍带内)。
% 上一段只钉"壁标志条数 > 20", 那挡得住删分支, 挡不住把壁密度用成气体密度、
% 或把两侧壁算成四侧、μ 单位用错这类"数量级跑偏但仍非零"的错法。
nEvW = numel(EgW.ev.eventID);
fracWall = nnz(wF) / nEvW;
muRhoS = double(cfgG.source.gamma_massatt_cm2_g.value);
rhoWS = double(tepc.config.constants('transport.a150.density_g_cm3'));
pPred = 1 - exp(-muRhoS * rhoWS * 2 * (R.geom.wallThickness_m * 100));
% 预期本身要先落在合理区间, 否则这条带会被常量的意外改动静默拉宽成恒真。
tc.verifyTrue(pPred > 0.01 && pPred < 0.2, sprintf( ...
    '壁光学厚度给出的作用概率 %.4g 不在 (0.01,0.2) 内: 这条幅值锁的量程已失效', pPred));
tc.verifyTrue(fracWall > pPred/3 && fracWall < 3*pPred, sprintf( ...
    '实测壁作用份额 %.4g 与解析预期 %.4g 不同量级 (允许 3 倍带): 壁密度、壁程或 μ 的单位用错了', ...
    fracWall, pPred));
% 壁密度的覆盖项必须同时驱动"壁内作用产额"与"壁内输运"。采样侧若直接读注册表常数,
% 把 ρ_wall 当不确定度变量传播时只有输运在动而产额不动 —— 传播的是半个物理量。
% 三条判据各挡一种错法: 取数点不同源 / 产额对覆盖项零响应 / 响应方向反了。
[rhoBase, ~] = tepc.transport.wallDensity(struct());
multWall = [1 2 3];
cntWall = zeros(1, numel(multWall));
for k = 1:numel(multWall)
    rsWall = RandStream('Threefry', 'Seed', 91007);
    [Ewk, ~] = tepc.transport.AnalyticAdapter(cfgG, R.geom, tables, rsWall, 1500, 91007, ...
        struct('tNext', 0), struct('rho_wall_g_cm3', multWall(k)*rhoBase));
    cntWall(k) = nnz(bitand(Ewk.ev.flags, uint32(8192)) > 0);
end
rsNo = RandStream('Threefry', 'Seed', 91007);
[Eno, ~] = tepc.transport.AnalyticAdapter(cfgG, R.geom, tables, rsNo, 1500, 91007, struct('tNext', 0));
rsEq = RandStream('Threefry', 'Seed', 91007);
[Eqv, ~] = tepc.transport.AnalyticAdapter(cfgG, R.geom, tables, rsEq, 1500, 91007, ...
    struct('tNext', 0), struct('rho_wall_g_cm3', rhoBase));
tc.verifyEqual(Eqv.ev.EdepGas_keV, Eno.ev.EdepGas_keV, 'AbsTol', 0, ...
    '显式传入名义壁密度与不传给出不同的气腔沉积: 采样侧与输运侧的 ρ_wall 不是同一个取数点');
tc.verifyGreaterThan(min(diff(cntWall)), 0, sprintf( ...
    '壁内作用产额随 ρ_wall 覆盖项不严格增 (%s): 采样侧仍在读注册表常数, 壁厚/壁密度对伽马腿不可传播', ...
    mat2str(cntWall)));
tc.verifyTrue(cntWall(1) > 20, sprintf( ...
    '名义密度下壁作用产额只有 %d 条: 上面那条单调性判据会在近零集合上退化', cntWall(1)));
end

function deleteIfExists(f)
if isfile(f), delete(f); end
end

function v = pstarCol(path, name)
% 按列名取 PSTAR 表的一列 (不按位置)。列缺失必须报错, 不许静默给 NaN/0 ——
% 位置约定一旦错位, 门禁会拿投影射程去比 CSDA 结果, 报出的是记账口径不是物理。
raw = strsplit(strtrim(fileread(path)), newline);
raw = raw(~cellfun(@(s) isempty(strtrim(s)) || s(1) == '#', raw));
hdr = strsplit(strtrim(raw{1}), ',');
col = find(strcmp(hdr, name), 1);
if isempty(col)
    error("tepc:transport:PstarColMissing", "%s 没有列 %s (现有: %s)", ...
        path, name, strjoin(hdr, ','));
end
v = zeros(numel(raw)-1, 1);
for i = 2:numel(raw)
    fld = strsplit(strtrim(raw{i}), ',');
    if numel(fld) < col
        error("tepc:transport:PstarColCount", "%s 第 %d 行列数不足", path, i);
    end
    v(i-1) = str2double(fld{col});
end
if any(~isfinite(v)) || any(v <= 0)
    error("tepc:transport:PstarColValue", "%s 列 %s 含非正值/非数值", path, name);
end
end
