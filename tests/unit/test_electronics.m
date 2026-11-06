function tests = test_electronics
%TEST_ELECTRONICS 电子学验收。
%   锁定的不只是"自洽": 匹配 PZ 峰幅/CSA 面积对解析式, 双量程 ADC 的码域语义,
%   等效码对输入电压的线性+单调, 仪器链 ctx 的强制字段, 噪声方差对单边 PSD 积分,
%   电荷注入 -> ADC -> 反演的 keV 量纲往返。
tests = functiontests(localfunctions);
end

function test_peak_matched_pz(tc)
% 警告: 本条锁的是**已知缺陷模型**的解析幅度 (缺陷登记在 filters.m 的 c.pz 注释):
% 无分母的 FIR PZ 把 CSA 极点完全抵消 => 峰高按 (Q/Cf)*(tau_f/tau) 走, 峰位在 t≈0 而不是 tau
% (实跑: 峰 idx=2 = 0.02*tau, 下冲 -13.7%)。给 PZ 补恢复极点会让这个 ref 与峰位同时失效
% (实跑幅度掉约 150 倍: 阈下事件占满、谱为空, 5 条回归红), 必须与电压工作点
% (threshold_V / ADC 量程 / sigma_peak_V) 的重定**同批**修改, 不能单独动这一条。
% 已实测的正确形态: 峰位 1.01*tau (nRC=1) / 1.93*tau (nRC=2),
% 峰高 = K*(Q/Cf)/e = 0.33*Q/Cf, 下冲 0.5%~8%, 堆叠占用窗/FWHM = 1.9~5.1。
cfg = demoCfgE();
cfg.electronics.Rf_Ohm = 5e7; cfg.electronics.shaping_s = 2e-6;
cfg.electronics.sampleTime_s = 1e-9;
c = tepc.electronics.filters(cfg);
Q = 1e-13;
v = filter(c.combined{1}, c.combined{2}, [Q; zeros(30000,1)]);
pk = max(abs(v));
ref = (Q/cfg.electronics.Cf_F)*(cfg.electronics.Rf_Ohm*cfg.electronics.Cf_F/cfg.electronics.shaping_s);
tc.verifyLessThan(abs(pk-ref)/ref, 0.003, '匹配PZ 峰值 vs 解析 (Q/Cf)(tau_f/tau)');
end

function test_charge_conservation_csa(tc)
cfg = demoCfgE();
c = tepc.electronics.filters(cfg);
Q = 1e-13;
v1 = filter(c.csa{1}, c.csa{2}, [Q; zeros(2000000,1)]);
area = sum(v1)*c.Ts;
refA = (Q/cfg.electronics.Cf_F)*(cfg.electronics.Rf_Ohm*cfg.electronics.Cf_F);
tc.verifyLessThan(abs(area-refA)/refA, 0.001, 'CSA 面积 = (Q/Cf)·tau_f');
end

function test_linearity(tc)
cfg = demoCfgE();
c = tepc.electronics.filters(cfg);
p1 = max(abs(filter(c.combined{1}, c.combined{2}, [1e-13; zeros(30000,1)])));
p2 = max(abs(filter(c.combined{1}, c.combined{2}, [2e-13; zeros(30000,1)])));
tc.verifyLessThan(abs(p2 - 2*p1)/p1, 0.001);
end

function test_sos_sections_and_impulse_response(tc)
% filters 的 sos 必须是 2 列 {num,den}; [ {a,b},{c,d} ] 会把 cell 拍平 -> 破坏索引。
cfg = demoCfgE();
cfg.electronics.shaperOrder = 2;
c = tepc.electronics.filters(cfg);
tc.verifyEqual(size(c.sos, 2), 2, 'sos 必须是 2 列 cell (被拍平则 != 2)');
tc.verifyEqual(size(c.sos, 1), 3 + c.nRC, 'sos 节数 = CSA+PZ+CR+nRC');
tc.verifyEqual(c.nRC, 2);
for s = 1:size(c.sos, 1)
    tc.verifyTrue(isnumeric(c.sos{s,1}) && isnumeric(c.sos{s,2}), ...
        sprintf('sos{%d,*} 必须是数值向量', s));
    p = roots(c.sos{s,2});
    tc.verifyTrue(all(abs(p) < 1), sprintf('第 %d 节极点必须在单位圆内 (稳定)', s));
end
x = [1; zeros(numel(c.h)-1, 1)];
for s = 1:size(c.sos, 1)
    x = filter(c.sos{s,1}, c.sos{s,2}, x);
end
tc.verifyEqual(numel(c.h), c.Nwin, 'h 长度必须等于 Nwin');
tc.verifyLessThan(max(abs(x - c.h))/max(abs(c.h)), 1e-9, 'h 必须由 sos 级联得到');
tc.verifyEqual(c.hpeak, max(abs(c.h)), 'RelTol', 1e-12);
tc.verifyEqual(c.hsign, sign(c.h(c.hidx)));
% 级联与"节顺序"无关 (同一传递函数): 实测 Ts=1e-9/order=2 下反序级联 rel=1.2e-14,
% 而合并直接式 rel=3.9e-4 —— 偏差来自直接式, 不是级联。
xr = [1; zeros(numel(c.h)-1, 1)];
for s = size(c.sos,1):-1:1
    xr = filter(c.sos{s,1}, c.sos{s,2}, xr);
end
tc.verifyLessThan(max(abs(xr - c.h))/c.hpeak, 1e-10, 'sos 级联必须与节顺序无关');
% sos 与合并直接式一致 —— 只在直接式数值可信处核对 (发货 Ts=1e-8, 任意阶数):
%   实测 rel(order=1,Ts=1e-9)=4.5e-8, rel(order=2,Ts=1e-8)=1.4e-8,
%   rel(order=2,Ts=1e-9)=3.9e-4, rel(order=3,Ts=1e-9)=1.8    <- 直接式在此已失效
%   (filters.m 注释: Ts/RfCf 过小时展开成高阶直接式会数值分解)。
for ord = [1 2 3]
    c1 = demoCfgE(); c1.electronics.sampleTime_s = 1e-8; c1.electronics.shaperOrder = ord;
    cc = tepc.electronics.filters(c1);
    yd = filter(cc.combined{1}, cc.combined{2}, [1; zeros(numel(cc.h)-1, 1)]);
    tc.verifyLessThan(max(abs(yd - cc.h))/cc.hpeak, 1e-6, ...
        sprintf('发货 Ts=1e-8 下 order=%d 的 sos 与合并直接式必须一致', ord));
end
end

function test_filters_merged_direct_form_degrades_at_small_Ts(tc)
% 把"合并直接式在 Ts->0/高阶时数值失效"这件事本身钉住: 它不得被当成参考实现。
% 实测 rel(sos, direct): order=1 Ts=1e-9 -> 4.5e-8; order=2 -> 3.9e-4; order=3 -> 1.8
% 且 order=3/Ts=1e-9 的直接式分母极点已跑到单位圆外 (实测), 级联各节极点全在圆内。
cfg3 = demoCfgE(); cfg3.electronics.sampleTime_s = 1e-9; cfg3.electronics.shaperOrder = 3;
c3 = tepc.electronics.filters(cfg3);
yd = filter(c3.combined{1}, c3.combined{2}, [1; zeros(numel(c3.h)-1, 1)]);
tc.verifyGreaterThan(max(abs(yd - c3.h))/c3.hpeak, 1e-2, ...
    'order=3/Ts=1e-9 的直接式偏差必须可见 (否则本测试失去意义)');
xr = [1; zeros(numel(c3.h)-1, 1)];
for s = size(c3.sos,1):-1:1
    xr = filter(c3.sos{s,1}, c3.sos{s,2}, xr);
end
tc.verifyLessThan(max(abs(xr - c3.h))/c3.hpeak, 1e-10, '同一条件下级联仍与节顺序无关');
tc.verifyFalse(all(abs(roots(c3.combined{2})) < 1), ...
    '直接式极点已越出单位圆 —— 偏差来源是直接式本身, 不是级联');
for s = 1:size(c3.sos,1)
    tc.verifyTrue(all(abs(roots(c3.sos{s,2})) < 1), sprintf('级联第 %d 节仍稳定', s));
end
tc.verifyTrue(isfinite(c3.hpeak) && c3.hpeak > 0, '级联峰幅不得因直接式失效而变 NaN');
end

function test_filters_numerically_stable_as_Ts_goes_to_zero(tc)
% Ts/RfCf < ~2e-8 时展开成高阶直接式会数值分解 (实测峰幅错 9.6e11 倍, 极点出圆)
cfgA = demoCfgE();
cfgA.electronics.shaping_s = 2e-6; cfgA.electronics.sampleTime_s = 1e-9;
cfgB = cfgA; cfgB.electronics.sampleTime_s = 1e-12;
cA = tepc.electronics.filters(cfgA);
cB = tepc.electronics.filters(cfgB);
tc.verifyTrue(isfinite(cB.hpeak) && cB.hpeak > 0, 'Ts->0 峰幅必须有限');
for s = 1:size(cB.sos, 1)
    tc.verifyTrue(all(abs(roots(cB.sos{s,2})) < 1), sprintf('Ts=1e-12 第 %d 节仍稳定', s));
end
% 物理: 匹配 PZ + 成形的峰幅 ~(Q/Cf)(tau_f/tau)(1-Ts/tau)^2, 与采样率几乎无关
tc.verifyLessThan(abs(cB.hpeak/cA.hpeak - 1), 0.02, '峰幅不得随 Ts 漂移');
end

function test_adc_monotone_within_each_range(tc)
% 新语义: 两量程各占码域 [0,2^bits-1], 由 RANGE2_ADC(512) 区分; 跨量程有意不连续
cfg = demoCfgE();
bits = cfg.electronics.adc.bits; FS = cfg.electronics.adc.fullScale_V;
g2 = cfg.electronics.adc.range2Gain; CODEMAX = 2^bits - 1;
tc.verifyGreaterThanOrEqual(g2, 2, '演示配置应启用第二量程');
vv = linspace(0, 4*g2*FS, 200001).';
[code, flags, meta] = tepc.electronics.adc(vv, cfg);
tc.verifyEqual(meta.LSB_V, FS/2^bits);
tc.verifyEqual(meta.fullScale_code, 2^bits, '满量程码 = 2^bits (不是 2^bits-1)');
tc.verifyEqual(meta.FS_V, FS);
tc.verifyEqual(meta.range2Gain, g2);
r1 = meta.range == 1; r2 = meta.range == 2;
tc.verifyEqual(nnz(r1 | r2), numel(vv), 'range 只能取 1/2');
tc.verifyTrue(all(diff(double(code(r1))) >= 0), '量程1 内码必须单调不减');
tc.verifyTrue(all(diff(double(code(r2))) >= 0), '量程2 内码必须单调不减');
tc.verifyTrue(all(code(r1) > int32(-1)) && all(code(r2) > int32(-1)), '码不得为负');
tc.verifyTrue(all(bitand(flags(r2), uint32(512)) > 0), '量程2 必须置 RANGE2_ADC');
tc.verifyTrue(all(bitand(flags(r1), uint32(512)) == 0), '量程1 不得置 RANGE2_ADC');
i1 = find(r1, 1, 'last'); i2 = find(r2, 1, 'first');
tc.verifyLessThan(abs(vv(i2) - FS)/FS, 1e-3, '量程切换点应在满量程处');
tc.verifyGreaterThan(double(code(i1)), 0.99*2^bits, '量程1 顶端应逼近码域上限');
tc.verifyGreaterThan(max(double(code(r2))), 0.99*2^bits, '量程2 也必须逼近码域上限');
tc.verifyLessThan(min(double(code(r2))), 2^bits/4, ...
    '量程2 从码域低端重新起算 (非码空间平移)');
% 超量程2: 封顶不外推
io = vv >= g2*FS*1.01;
tc.verifyTrue(all(double(code(io)) == CODEMAX), '超量程2 必须封顶为 2^bits-1');
tc.verifyTrue(all(bitand(flags(io), uint32(1)) > 0), '超量程2 必须置 OVERFLOW_ADC');

% ---- 装置工作点常数群的"同批"守卫 (量程侧) ----
% 配置里那句 "range2 = range2Gain*FS = 64 V, 覆盖 1 MeV 反冲质子峰约 35 V (G=136)" 此前只是注释:
% 单独改 HV / 电极几何 / deltaV / W / Rf / shaping 任何一边, 本文件上面所有 ADC 断言照样全绿,
% 而那句话会静默变成谎话 (与 test_false_trigger_rate 里阈值-sigma 那四条是同一族的另一半)。
% 覆盖面有一条边界要写清: 匹配 PZ 的峰幅 (q/Cf)·(Rf·Cf/τ) = q·Rf/τ, **Cf 在里面约掉了**,
% 所以这一条盯不住 Cf 的单独变化 —— Cf 由噪声那条链盯 (σ_peak_V 依赖 C_Σ, 见 test_false_trigger_rate)。
% 这里把整条链**算出来**再判: G_mean 由 resolve 按发货场几何给出, 与 Diethorn 闭式
% exp((ln2/dV)·(V/ln(b/a))·ln10) 逐位一致; 峰幅 = (N_pairs·e·G/Cf)·(tau_f/tau)。
gb = tepc.io.projectRoot();
c0 = tepc.config.load(fullfile(gb, 'config', 'defaults', 'demo_only.json'));
Rb = tepc.config.resolve(c0);
e0 = c0.electronics;
Npairs = 1e6 / c0.gas.W_eV.value;
vpk = (Npairs * 1.602176634e-19 * Rb.G_mean / e0.Cf_F) * ...
    (e0.Rf_Ohm * e0.Cf_F / e0.shaping_s);
tc.verifyEqual(Rb.G_mean, 136.013019, 'RelTol', 1e-6, ...
    sprintf('G_mean 离开发货工作点 (实得 %.6f): HV/几何/deltaV 任何一边单独动都会走到这里', Rb.G_mean));
tc.verifyEqual(vpk, 35.034868, 'RelTol', 1e-4, ...
    sprintf('1 MeV 反冲质子的整形峰幅不再是注释里的约 35 V (实得 %.6f V): Cf/Rf/shaping 与量程是一批定的数', vpk));
tc.verifyGreaterThan(vpk, FS, '峰幅必须确实超出量程1, 否则 32 倍第二量程是白加的');
tc.verifyLessThan(vpk, g2 * FS, '峰幅必须落在量程2 之内, 否则配置那句"覆盖"是假的');
tc.verifyGreaterThan(g2 * FS / vpk, 1.5, ...
    sprintf('量程2 对峰幅的余量只剩 %.3f 倍: 余量不得静默消失', g2 * FS / vpk));
end

function test_adc_bad_input_and_saturation_flags(tc)
cfg = demoCfgE();
bits = cfg.electronics.adc.bits; CODEMAX = int32(2^bits - 1);
vv = [NaN; Inf; -Inf; -1e-6; 0; cfg.electronics.adc.range2Gain*...
      cfg.electronics.adc.fullScale_V*1.01];
[code, flags, ~] = tepc.electronics.adc(vv, cfg);
tc.verifyTrue(all(code(1:3) == CODEMAX), 'NaN/Inf 必须封顶为码域上限');
tc.verifyTrue(all(bitand(flags(1:3), uint32(256)) > 0), 'NaN/Inf 必须置 OUT_OF_RANGE');
tc.verifyTrue(all(bitand(flags(1:3), uint32(1)) > 0), 'NaN/Inf 必须同时置 OVERFLOW_ADC');
tc.verifyEqual(double(code(4)), 0, '负输入必须截底为 0 (不回绕)');
tc.verifyTrue(bitand(flags(4), uint32(256)) > 0, '负输入必须置 OUT_OF_RANGE');
tc.verifyEqual(double(code(5)), 0);
tc.verifyEqual(double(code(6)), double(CODEMAX), '超量程2 必须封顶');
tc.verifyTrue(bitand(flags(6), uint32(1)) > 0, '超量程2 必须置 OVERFLOW_ADC');
tc.verifyTrue(bitand(flags(5), uint32(256)) == 0, '0 V 合法输入不得置域外');
% cfg 必填: 量程 2 上限 = range2Gain × fullScale_V 只能来自配置, 少传参数的调用
% 若拿到另一套仪器参数会静默削顶反冲质子峰。
tc.verifyError(@() tepc.electronics.adc(0.5), 'MATLAB:minrhs', ...
    '少传 cfg 仍然能跑: 说明兜底参数还在, 仪器参数又有了两处来源');
p = which('tepc.electronics.adc');
tc.verifyFalse(isempty(p), '取不到 adc.m 路径, 下面两条结构判据是空转');
fid = fopen(p, 'r', 'n', 'UTF-8');
tc.verifyTrue(fid > 0, 'adc.m 打不开, 下面两条结构判据是空转');
b = fread(fid, inf, 'char=>char');
fclose(fid);
% 只扫代码行: 兜底的来历写在注释里是必要的交代, 不该被自己的说明文字判红。
% 变量名避开 code —— 上面 ADC 的码数组就叫 code, 复用它会让后续判据拿文本比数值。
srcTxt = regexprep(b(:)', '(?m)^\s*%.*$', '');
tc.verifyFalse(isempty(strfind(srcTxt, 'function [code, flags, meta] = adc')), ...
    '读到的文本里没有 adc 的函数定义行: 文件读取已失效, 下面那条判据是空转');
tc.verifyTrue(isempty(strfind(srcTxt, 'defaultCfg')), ...
    'adc.m 的代码里又出现 defaultCfg: 量化参数回到两处来源');
% 配置里 range2Gain 为空或 <1 时旧实现静默取 1: 量程 2 塌回量程 1, 反冲质子峰被削顶而
% 返回值里不留任何痕迹。现在判错, 并且 meta 必须回报真正所用的倍数。
badVals = {{}, 0.5, NaN};
for jb = 1:numel(badVals)
    cb = cfg;
    cb.electronics.adc.range2Gain = badVals{jb};
    tc.verifyError(@() tepc.electronics.adc(0.5, cb), 'tepc:adc:BadRange2Gain');
end
[~, ~, mOk] = tepc.electronics.adc(0.5, cfg);
tc.verifyEqual(mOk.range2Gain, double(cfg.electronics.adc.range2Gain), 'AbsTol', 0, ...
    'meta 回报的倍数必须逐位等于配置值 (没被替换成别的东西)');
end

function test_extCode_linear_and_monotone(tc)
% 标定/反演都在"等效码"上做: 对输入电压线性且跨量程连续
cfg = demoCfgE();
bits = cfg.electronics.adc.bits; FS = cfg.electronics.adc.fullScale_V;
g2 = cfg.electronics.adc.range2Gain; LSB1 = FS/2^bits;
vv = linspace(0.05, 3*g2*FS/4, 200001).';
[code, ~, meta] = tepc.electronics.adc(vv, cfg);
xc = tepc.electronics.extCode(code, meta.range, bits, g2);
tc.verifyTrue(nnz(meta.range == 2) > 1000, '扫描必须跨过量程边界');
tc.verifyTrue(all(diff(xc) >= 0), '等效码必须对输入电压全域单调 (含量程边界)');
dev = max(abs(xc - vv/LSB1)./(vv/LSB1));
tc.verifyLessThan(dev, 0.01, '等效码须 ~ v/LSB1 (跨量程同一斜率)');
% 老网格看不见的尺度: 边界前后 5e-5 相对范围细扫
vb = linspace(FS*(1-5e-5), FS*(1+5e-5), 2001).';
[c2, ~, m2] = tepc.electronics.adc(vb, cfg);
x2 = tepc.electronics.extCode(c2, m2.range, bits, g2);
tc.verifyTrue(all(diff(x2) >= 0), '量程边界细扫必须仍单调 (判决与编码同一 INL 修正)');
tc.verifyGreaterThan(x2(end) - x2(1), 0, '细扫不得退化为常数');
% 未触发码与长度守卫
tc.verifyEqual(tepc.electronics.extCode(int32([-1; 5]), uint8([1; 2]), bits, g2), ...
    [-1; 5*g2], 'AbsTol', 1e-9);
tc.verifyError(@() tepc.electronics.extCode(int32([1 2 3]), uint8([1 2]), bits, g2), ...
    'tepc:adc:ExtCodeLen');
end

function test_simulate_requires_full_ctx(tc)
% ctx 缺任一必填字段必须抛 tepc:elec:BadCtx (值类/惰性计算的坑不得静默)
[cfg, ~, ctx] = elecCtx();
req = {'W_eV','fano','G_mean','theta','field','mob','coeffs','noiseSigma','seed','r0_m'};
rs = RandStream('Threefry', 'Seed', 3);
for i = 1:numel(req)
    f = req{i};
    bad = rmfield(ctx, f);
    tc.verifyError(@() tepc.electronics.simulate(50, 1, cfg, rs, bad), 'tepc:elec:BadCtx', ...
        sprintf('缺 %s 必须报 BadCtx', f));
end
okCtx = ctx;
tc.verifyEqual(numel(fieldnames(okCtx)) >= 10, true);
end

function test_simulate_instrument_chain_outputs(tc)
% 波形链真实输出: peak_V/t_trigger_s/range/r0_m 与码-能量单调性
[cfg, R, ctx] = elecCtx();
cfg0 = cfg; cfg0 = zeroNoise(cfg0);
cA = tepc.electronics.filters(cfg0);
ctx0 = ctx; ctx0.coeffs = cA;
rs = RandStream('Threefry', 'Seed', 17);
Edep = [50; 200];
M = 200;
[q, instr] = tepc.electronics.simulate(Edep(1)*ones(M,1), 5000, cfg0, rs, ctx0);
tc.verifyEqual(numel(q), M);
f = {'peak_V','adc_code','flags','t_trigger_s','range','r0_m'};
for i = 1:numel(f)
    tc.verifyTrue(isfield(instr, f{i}), sprintf('instr 必须含 %s', f{i}));
    tc.verifyEqual(numel(instr.(f{i})), M, sprintf('%s 长度必须等于事件数', f{i}));
end
tc.verifyTrue(all(instr.peak_V > 0), '峰值电压必须为正');
tc.verifyTrue(all(instr.t_trigger_s > 0) && ...
    all(instr.t_trigger_s <= cfg0.electronics.waveWindow_s*(1 + 1/cA.Nwin) + 1e-15), ...
    '触发时刻必须落在波形窗内 (argmax*Ts)');
tc.verifyTrue(all(instr.r0_m == R.r0_m), '起始半径须取 ctx.r0_m (=10a)');
tc.verifyTrue(all(ismember(instr.range, uint8([1 2]))), 'range 只能 1/2');
[q2, instr2] = tepc.electronics.simulate(Edep(2)*ones(M,1), 5000, cfg0, rs, ctx0);
x1 = tepc.electronics.extCode(instr.adc_code, instr.range, ...
    cfg0.electronics.adc.bits, cfg0.electronics.adc.range2Gain);
x2 = tepc.electronics.extCode(instr2.adc_code, instr2.range, ...
    cfg0.electronics.adc.bits, cfg0.electronics.adc.range2Gain);
ratio = mean(x2(x2 > 0))/mean(x1(x1 > 0));
% 物理锁: 等效码域内整链对沉积能线性 (4 倍能量 -> 4 倍等效码), 弹道亏损被同一
% 模型吸收; 涨落来自 Fano+Polya(theta=8) -> 均值标准误 ~2.4%
tc.verifyLessThan(abs(ratio/4 - 1), 0.15, '整链响应须对沉积能线性 (等效码域)');
tc.verifyGreaterThan(mean(instr2.peak_V)/mean(instr.peak_V), 2, '峰值须随能量上升');
end

function test_simulate_threshold_flag_is_deterministic_without_noise(tc)
% 数字化与触发**解耦** (设计决定, simulate.m 注释同处): ADC 始终对峰幅出码,
% 阈下事件只是打上 UNDER_THRESHOLD(2) 标志, 码依然有效。
% 为什么必须如此 (实测, 见 simulate.m:76-79): 旧语义把阈下码置为保留码 -1,
% 于是电荷注入刻度的低能端被"触发截断"系统性抬高 —— 1 keV 处反演偏高 7.96 倍,
% 拟合截距被拉到 -754 码, 发布量 instr_bias_yF = 0.7965; 解耦后同一配置给
% instr_bias_yF = 0.0191。故本用例断言的是新语义, 旧期望 (码必须为 -1) 是错的。
% 注意: EventBatch.preallocate 里的 int32(-1) 是"从未进入仪器链"的哨兵, 与此无关。
[cfg, ~, ctx] = elecCtx();
cfg = zeroNoise(cfg); ctx.coeffs = tepc.electronics.filters(cfg);
rs = RandStream('Threefry', 'Seed', 23);
thr = cfg.electronics.trigger.threshold_V;  bits = cfg.electronics.adc.bits;
LSB1 = cfg.electronics.adc.fullScale_V/2^bits;
eC = 1.602176634e-19;
% (a) 1 eV 沉积: 无噪声下峰幅为 0 -> 全部阈下, 但仍须交出**有效**码
[~, ins] = tepc.electronics.simulate(repmat(1e-3, 20, 1), 6000, cfg, rs, ctx);
tc.verifyTrue(all(bitand(ins.flags, uint32(2)) > 0), '1 eV 沉积必须全部阈下 (无噪声)');
tc.verifyTrue(all(ins.peak_V < thr), '阈下判据: 峰幅低于阈值');
tc.verifyTrue(all(ins.adc_code >= int32(0)) && all(ins.adc_code <= int32(2^bits-1)), ...
    '阈下事件的码必须是有效码域 [0,2^bits-1], 不得退回 -1 保留码');
% (b) 0.3 keV 沉积: 均峰 ~3.1e-3 V (约 25 LSB) 仍低于 0.02 V 阈值 -> 必出非零码
%     选 0.3 keV 而不是 1 keV: Polya(theta=8) 的 sd/mean = 0.316, 1 keV 的均峰
%     (1.04e-2 V) 距阈值只剩 1 倍, 实测数十个事件里就有右尾越阈的 (伪失败)。
[~, ins2] = tepc.electronics.simulate(repmat(0.3, 20, 1), 7000, cfg, rs, ctx);
tc.verifyTrue(all(ins2.peak_V < thr) && all(ins2.peak_V > 5*LSB1), ...
    '本例须同时满足"阈下"与"远高于 1 LSB"');
tc.verifyTrue(all(bitand(ins2.flags, uint32(2)) > 0), '阈下标志仍须逐事件打上');
tc.verifyTrue(all(ins2.adc_code > int32(0)), '阈下但高于 1 LSB 的峰必须出非零码');
tc.verifyTrue(all(ins2.flags == uint32(2)), '除 UNDER_THRESHOLD 外不得再有其它标志');
% (c) 最强锁: 码必须由同一条 ADC 独立于触发给出 (code == adc(peak_V))
[ck, ~, mk] = tepc.electronics.adc([ins.peak_V; ins2.peak_V], cfg);
tc.verifyEqual([ins.adc_code; ins2.adc_code], ck, '码必须等于 adc(peak_V): 数字化与触发无关');
tc.verifyEqual([ins.range; ins2.range], mk.range);
% (d) 阈下码必须真的能进刻度轴: 取一个"峰幅远低于阈值"的注入点, 用测量侧
%     (含 Fano+Polya 气体涨落) 的平均等效码去比对同一注入点刻度侧的码中位数。
%     两侧共用同一条链 (ctx.coeffs / r0 / 零电子噪声), 唯一差别就是气体涨落,
%     而 E[G·N] = 注入电荷 => 差异只应到蒙特卡洛误差量级。
%     旧语义 (阈下码 = -1) 在此会让测量侧均值变成 -1 -> 立刻被抓。
cal = tepc.calibration.injectCalibrate(cfg, ctx, int64(2e9));
pkPt = [cal.points.Q_C]*cal.V_per_C;
cand = find([cal.points.frac] > 0.9 & pkPt < 0.5*thr);
tc.verifyFalse(isempty(cand), '刻度扫描必须包含远低于触发阈值的注入点');
kSub = cand(end);                                   % 仍阈下、但码数最多的那一点
Qs = cal.points(kSub).Q_C;
Edep_s = Qs*ctx.W_eV/(1000*eC*ctx.G_mean);
tc.verifyLessThan(pkPt(kSub), thr, '对照点本身必须是阈下注入点');
[~, insD] = tepc.electronics.simulate(repmat(Edep_s, 600, 1), 9000, cfg, rs, ctx);
xD = tepc.electronics.extCode(insD.adc_code, insD.range, bits, cfg.electronics.adc.range2Gain);
tc.verifyGreaterThan(min(xD), 0, '阈下事件的等效码必须有效且非零 (不得为 -1 哨兵)');
xbar = mean(xD);
seRel = std(xD)/xbar/sqrt(numel(xD));
tc.verifyGreaterThan(seRel, 0, '样本必须有涨落 (否则本断言无判别力)');
tc.verifyLessThan(abs(xbar/cal.points(kSub).code_med - 1), max(4*seRel, 0.05), ...
    sprintf('阈下注入点: 测量侧平均码 %.4g vs 刻度侧 %.4g (4u_SE=%.3f)', ...
    xbar, cal.points(kSub).code_med, 4*seRel));
% 反演必须落在域内 (旧语义在此给 NaN + OUT_OF_RANGE)。量纲/截断用 2 倍硬上限兜住:
% 实测低能端整体线性拟合本身有 ~19% 系统偏差, 那不是本用例要锁的东西。
phys = struct('W_eV', cfg.gas.W_eV.value, 'G', ctx.G_mean);
[e_rt, fl] = tepc.calibration.adcToEnergy(xbar, cal, phys);
tc.verifyTrue(all(fl == uint32(0)), '阈下有效码反演不得判为域外');
tc.verifyTrue(isfinite(e_rt), '阈下有效码必须可反演');
tc.verifyLessThan(abs(e_rt/Edep_s - 1), 0.5, ...
    sprintf('反演 %.4g keV vs 注入 %.4g keV (旧语义: 7.96 倍; 量纲错: 1000 倍)', e_rt, Edep_s));
end

function test_noise_variance_matches_single_sided_psd(tc)
% 物理锁: 白噪声极限 var = en_w^2 * Fs/2 (单边 PSD 在 [0,Fs/2] 上的积分)
cfg = demoCfgE();
cfg.electronics.sampleTime_s = 1e-7;
cfg.electronics.noise.en_1f_amp_nV = 0;
cfg.electronics.noise.in_pA_per_rootHz = 0;
enw = cfg.electronics.noise.en_white_nV_per_rootHz*1e-9;
Fs = 1/cfg.electronics.sampleTime_s;
rs = RandStream('Threefry', 'Seed', 31);
for N = [4000 4001]
    [vn, meta] = tepc.electronics.noise(N, cfg, rs, "waveform");
    tc.verifyEqual(numel(vn), N, sprintf('N=%d: Hermitian 镜像长度必须严格等于 N', N));
    tc.verifyEqual(meta.N, N);
end
[vn, meta] = tepc.electronics.noise(4000, cfg, rs, "waveform");
refVar = enw^2*Fs/2;
tc.verifyLessThan(abs(meta.target_rms_V^2 - refVar)/refVar, 1e-9, ...
    'target 方差必须等于 en_w^2*Fs/2 (单边 PSD 积分)');
tc.verifyLessThan(abs(std(vn)^2 - refVar)/refVar, 1e-9, '时域方差必须按 PSD 积分归一');
tc.verifyTrue(all(isfinite(vn)) && isreal(vn), '噪声波形必须为有限实数');
end

function test_noise_1f_corner_comes_from_config(tc)
% 拐角必须读 electronics.noise.en_1f_corner_Hz (原实现硬编码)
cfg = demoCfgE();
cfg.electronics.sampleTime_s = 1e-7;
cfg.electronics.noise.in_pA_per_rootHz = 0;
rs = RandStream('Threefry', 'Seed', 41);
c1 = cfg; c1.electronics.noise.en_1f_corner_Hz = 10.0;
c2 = cfg; c2.electronics.noise.en_1f_corner_Hz = 1e4;
[~, m1] = tepc.electronics.noise(4096, c1, rs, "waveform");
[~, m2] = tepc.electronics.noise(4096, c2, rs, "waveform");
tc.verifyEqual(m1.f_corner_Hz, 10.0, 'meta 必须回报所用拐角');
tc.verifyEqual(m2.f_corner_Hz, 1e4);
tc.verifyNotEqual(m1.target_rms_V, m2.target_rms_V, ...
    '改拐角必须改变方差 -> 证明拐角取自配置');
c3 = cfg; c3.electronics.noise.en_1f_corner_Hz = 0;
tc.verifyError(@() tepc.electronics.noise(1024, c3, rs, "waveform"), 'tepc:noise:BadCorner');
tc.verifyError(@() tepc.electronics.noise(1024, cfg, rs, "bogus"), 'tepc:noise:BadMode');
[sm, ms] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',5), "sigma");
tc.verifyGreaterThan(sm, 0, '峰幅噪声标准差必须为正');
tc.verifyEqual(ms.mc_realizations, 200);
% 缺位是硬错误: 旧实现先给 fc = 100.0 再被配置覆盖, 字段漏配就静默拿到一套与任何发货
% 配置都无对照关系的 1/f 拐角。空值同样要拦, 否则 ~(NaN > 0) 那条只挡得住非正数。
c4 = cfg;
c4.electronics.noise = rmfield(c4.electronics.noise, 'en_1f_corner_Hz');
tc.verifyError(@() tepc.electronics.noise(1024, c4, rs, "waveform"), 'tepc:noise:NoCorner');
c5 = cfg;
c5.electronics.noise.en_1f_corner_Hz = [];
tc.verifyError(@() tepc.electronics.noise(1024, c5, rs, "waveform"), 'tepc:noise:NoCorner');
c6 = cfg;
c6.electronics.noise = rmfield(c6.electronics.noise, 'en_1f_corner_Hz');
tc.verifyError(@() tepc.electronics.noise(1024, c6, rs, "sigma"), 'tepc:noise:NoCorner');
end

function test_pileup_window_is_the_callers_width(tc)
% 本用例原为 test_trigger_pileup_field_guard: 验证 trigger.m 里 pileUpReject_s 的
% isfield 守卫。trigger.m 已删除 (阈值+迟滞武装状态机, 只有本测试调用它,
% 与 daq 的接受判据互相矛盾 => 第三套竞争实现; 迟滞判据本身仍由 simulate.m 的
% hysteresis_V 负责, 未丢失)。参数现在改由调用方显式交给 daq 的 width_s,
% "配置缺字段"这条分支不复存在 —— 迁移为: **只有窗口入参能改变 pile-up 判定**。
% 手算 (tau=10, 固定延迟 0, 到达 t=[0;15]):
%   t=0 : busy=-Inf 未占用 -> accepted, busy->0+10=10, 脉冲末->0+width
%   t=15: 15>=10 已脱离死时间; 若 15<width 判 pileup, 否则 accepted
%   width=30 -> [accepted pileup], nAccepted=1;  width=10 -> [accepted accepted], nAccepted=2
% 可 falsify 性: (a) 实现若把窗口写死 (trigger.m 原来的 3*shaping_s 默认, 或任何
% width<=tau 的硬编码) 两次调用会给出的 reason 完全相同 -> 第 3 条断言必红;
% (b) 实现若丢掉 pile-up 判据 (只留死时间) 宽窗那次也会是 accepted -> 第 1 条必红;
% (c) 实现若用死时间窗当占用窗 (width 取 tau 之外还反过来用 lastTrigEnd=busyUntil)
% 窄窗那次会变成 pileup -> 第 2 条必红。
o30 = tepc.electronics.daq([0;15], 0, 30, 10, "nonparalyzable");
o10 = tepc.electronics.daq([0;15], 0, 10, 10, "nonparalyzable");
tc.verifyEqual(o30.reason, string({'accepted';'pileup'}), '宽窗 (width>tau) 必须判 pileup');
tc.verifyEqual(o10.reason, string({'accepted';'accepted'}), 'width<=tau 时 busy 先开, pileup 不可能');
tc.verifyNotEqual(o30.reason, o10.reason, '窗口必须由入参决定, 不得写死');
tc.verifyEqual([o30.nAccepted o30.nPile o30.nDead], [1 1 0]);
tc.verifyEqual([o10.nAccepted o10.nPile o10.nDead], [2 0 0]);
% 原测试的另一半 ("缺字段不得抛错") 现在反过来是硬门: 窗口没有静默默认值。
% (daq.m 的窗口入参守卫只覆盖数值 0 与负数, 本用例因此只锁这两条。
%  实测 width_s=[] 时 daq:45 的 `~(width_s > 0)` 判据拿不到异常 —— `[] > 0` 是空
%  逻辑, if 空即 false —— 于是 lastTrigEnd 变成 [] 并被一路带下去: [] 这条分支
%  守卫不到, 不能在此断言。)
tc.verifyError(@() tepc.electronics.daq([0;15], 0, 0, 10, "nonparalyzable"), 'tepc:dq:BadWidth');
tc.verifyError(@() tepc.electronics.daq([0;15], 0, -1, 10, "nonparalyzable"), 'tepc:dq:BadWidth');
end

function test_calibration_roundtrip_is_keV(tc)
% 注入已知电荷 -> 与测量同一条正向链 -> ADC -> extCode -> adcToEnergy 往返
% (锁住 keV/eV 那个 1000 倍量纲错误; 容差按该注入点的蒙特卡洛误差给, 另加 10% 硬上限)
[cfg, R, ctx] = elecCtx();
cal = tepc.calibration.injectCalibrate(cfg, ctx, int64(2e9));
bits = cfg.electronics.adc.bits; g2 = cfg.electronics.adc.range2Gain;
eC = 1.602176634e-19;
tc.verifyEqual(cal.FS_code, 2^bits*g2, 'cal.FS_code 必须在等效码域 [0,2^bits*g2)');
tc.verifyTrue(isfield(cal,'points') && isfield(cal,'V_per_C') && isfield(cal,'threshold_V'), ...
    'injectCalibrate 必须返回 points/V_per_C/threshold_V');
tc.verifyEqual(cal.threshold_V, cfg.electronics.trigger.threshold_V);
tc.verifyGreaterThan(cal.V_per_C, 0);
tc.verifyGreaterThanOrEqual(numel(unique([cal.points.Q_C])), 5, '>=5 个注入点');
phys = struct('W_eV', cfg.gas.W_eV.value, 'G', R.G_mean);
rs = RandStream('Threefry', 'Seed', 101);
fr = [cal.points.frac];           % 该注入点"码落在有效域内"的样本占比
tc.verifyEqual(numel(fr), numel(cal.points), 'points.frac 必须逐点给出');
good = find(fr > 0.9);
tc.verifyGreaterThanOrEqual(numel(good), 3, '必须有 >=3 个近乎全有效的注入点');
% 数字化的低能端不得被触发截断 (与 test_simulate_threshold_flag_* 同一设计决定):
% 最低注入点的峰幅远低于阈值, 但仍须交出有效码并进入刻度。
pkLow = cal.points(1).Q_C*cal.V_per_C;
tc.verifyLessThan(pkLow, cal.threshold_V, '最低注入点峰幅必须远低于触发阈值');
tc.verifyGreaterThan(fr(1), 0.9, '阈下注入点必须仍贡献刻度码 (数字化与触发解耦)');
% 选点纪律 (实测教训, 两条都不是量纲缺陷的信号):
%   - 最低注入点 (2 LSB ~ 0.018 keV) 处于"单离子对"区: 电离对数取整让均值系统性偏高
%     一个量级 (实测反演 0.344 keV vs 注入 0.018 keV);
%   - 最高注入点 (98.5% 满量程) 的 Polya 右尾把均值码推出刻度域 (实测反演 NaN)。
% 真正要锁的是 adcToEnergy 的 keV/eV 量纲 (1000 倍) —— 用域中段 + 足够样本 + 按
% 蒙特卡洛误差给容差, 同时保留一条 10% 硬上限, 判别力比原来的 1% 更可靠。
Qall = [cal.points.Q_C];
EdepAll = Qall*ctx.W_eV/(1000*eC*ctx.G_mean);
use = (fr > 0.9) & (EdepAll >= 10) & (Qall <= 0.25*cal.domain_C(2));
sel = find(use);
tc.verifyGreaterThanOrEqual(numel(sel), 3, '域中段可用注入点须 >=3 个');
sel = sel(unique(round(linspace(1, numel(sel), 3))));
nChecked = 0;
for i = 1:numel(sel)
    k = sel(i);
    Q = cal.points(k).Q_C;
    Edep_keV = EdepAll(k);                             % 与标定同一换算
    [~, ins] = tepc.electronics.simulate(repmat(Edep_keV, 2000, 1), int64(3e6 + 1000*i), ...
        cfg, rs, ctx);
    xc = tepc.electronics.extCode(ins.adc_code, ins.range, bits, g2);
    % 逐事件剔除 (原实现用 any(...,1) 把整点一票否决: 一个饱和码就丢掉全部样本)
    bad = bitand(ins.flags, uint32(1 + 256)) > 0;
    ok = (xc > 0) & ~bad;
    tc.verifyGreaterThan(nnz(ok), 0.95*2000, sprintf('注入点 %d 有效样本过少', k));
    xm = mean(xc(ok));
    seRel = std(xc(ok))/xm/sqrt(nnz(ok));
    tc.verifyTrue(xm > 0 && xm < cal.FS_code, '均值码必须落在等效码域内');
    [e_rt, fl] = tepc.calibration.adcToEnergy(xm, cal, phys);
    tc.verifyTrue(isfinite(e_rt), sprintf('注入点 %d 反演失败 (域外?)', k));
    tc.verifyEqual(fl, uint32(0), '域内反演不得带 OUT_OF_RANGE 标志');
    tc.verifyLessThan(abs(e_rt - Edep_keV)/Edep_keV, max(4*seRel, 0.02), ...
        sprintf('往返误差: %.4g keV vs %.4g keV (4u_SE=%.4f)', e_rt, Edep_keV, 4*seRel));
    tc.verifyLessThan(abs(e_rt - Edep_keV)/Edep_keV, 0.1, ...
        '硬上限: keV/eV 的 1000 倍量纲错误必须被抓住');
    nChecked = nChecked + 1;
end
tc.verifyEqual(nChecked, 3);
end

function test_adc_to_energy_domain_rejection(tc)
% 域外/负码/越界码 -> NaN + OUT_OF_RANGE, 绝不外推
[cfg, R, ~] = elecCtx();
cal = struct('beta', [10; 1e10], 'cov', eye(2), 'sigma_res', 1, ...
    'domain_C', [1e-15 1e-13], 'quadratic', false, 'FS_code', 2^14*32);
phys = struct('W_eV', 31.1, 'G', R.G_mean);
[e1, f1] = tepc.calibration.adcToEnergy(int32(-1), cal, phys);
tc.verifyTrue(isnan(e1) && bitand(f1, uint32(256)) > 0, '保留码 -1 -> NaN+OUT_OF_RANGE');
[e2, f2] = tepc.calibration.adcToEnergy(int32(2^14*32), cal, phys);
tc.verifyTrue(isnan(e2) && bitand(f2, uint32(256)) > 0, '越满量程码 -> NaN+OUT_OF_RANGE');
[e3, f3] = tepc.calibration.adcToEnergy(int32(0), cal, phys);
tc.verifyTrue(isnan(e3) && bitand(f3, uint32(256)) > 0, '域下界之下 -> NaN+OUT_OF_RANGE');
% 域内一点的量纲: Q=W*N/e/G 关系必须给 keV
Q = 5e-14; code = cal.beta(1) + cal.beta(2)*Q;
[e4, f4] = tepc.calibration.adcToEnergy(code, cal, phys);
tc.verifyEqual(f4, uint32(0));
tc.verifyEqual(e4, Q*31.1/(1.602176634e-19*R.G_mean)/1000, 'RelTol', 1e-9);
end

function test_fit_charge_injection_guards(tc)
% 校验: 等长/有限/非负/>=5 不同注入点/每点足够重复
opts = struct('bits', 14);
Q = linspace(1e-15, 1e-13, 6).';
a1 = 1e17;                       % 码/库仑 —— 与真实刻度同量级 (injectCalibrate 实测 1.59e17)
y = a1*Q + 10;                   % 必须与 Q 同为列向量: 转置会让 [y; 1] 直接 vertcat 报错
tc.verifyEqual(size(y), size(Q), '测试数据方向错误会先于被测函数报错 (掩盖真实缺陷)');
tc.verifyError(@() tepc.calibration.fitChargeInjection(Q, y(1:4), opts), 'tepc:cal:Length');
tc.verifyError(@() tepc.calibration.fitChargeInjection([Q; NaN], [y; 1], opts), ...
    'tepc:cal:NotFinite');
tc.verifyError(@() tepc.calibration.fitChargeInjection([Q; Inf], [y; 1], opts), ...
    'tepc:cal:NotFinite');
tc.verifyError(@() tepc.calibration.fitChargeInjection(-Q, y, opts), 'tepc:cal:BadCharge');
tc.verifyError(@() tepc.calibration.fitChargeInjection(Q(1:4), y(1:4), opts), ...
    'tepc:cal:NTooSmall', '少于 5 个不同注入点必须拒绝');
tc.verifyError(@() tepc.calibration.fitChargeInjection(Q, y, opts), 'tepc:cal:NTooSmall', ...
    '每点重复样本不足必须拒绝');
% 合法数据: 6 点 x 5 次。信号跨度 (a1*(Qmax-Qmin)=9.9e3 码) 必须远大于噪声 (0.1 码),
% 否则斜率的蒙特卡洛误差本身就有 O(1) —— 原实现把两者写成同一个量级, 断言不可满足。
Qg = repelem(Q, 5); yg = a1*Qg + 10 + 0.1*randn(size(Qg));
cal = tepc.calibration.fitChargeInjection(Qg, yg, opts);
tc.verifyEqual(cal.FS_code, 2^14, 'FS_code = 2^bits (不是 2^bits-1)');
tc.verifyEqual(numel(cal.beta), 2);
tc.verifyLessThan(abs(cal.beta(2) - a1)/a1, 1e-3, '斜率须还原到 码/库仑 单位');
tc.verifyLessThan(abs(cal.beta(1) - 10), 1, '截距须还原到 码 单位');
tc.verifySize(cal.cov, [2 2]);
tc.verifyEqual(cal.quadratic, false);
% quadratic 路径 (原实现必抛尺寸错)
cal2 = tepc.calibration.fitChargeInjection(Qg, yg, struct('bits',14,'quadratic',true));
tc.verifyEqual(cal2.quadratic, true);
tc.verifySize(cal2.beta, [3 1]);
tc.verifySize(cal2.cov, [3 3]);
tc.verifyGreaterThan(cal2.Qref_C, 0);
res = yg - (cal2.beta(1) + cal2.beta(2)*Qg + cal2.beta(3)*Qg.^2);
tc.verifyLessThan(std(res), 1, '二次拟合残差应为亚码量级');
end

function test_ion_pair_single_sampler(tc)
% 单一涨落采样器: 禁止 Fano 与 Poisson 双重叠加
rs = RandStream('Threefry','Seed',3);
[N1,~] = tepc.detector.sampleIonPairs(100*ones(20000,1), 31.1, 0.2, rs);
tc.verifyLessThan(abs(var(N1) - 0.2*100e3/31.1)/(0.2*100e3/31.1), 0.05, ...
    '大均值分支: Var = F·mu (无二次叠加)');
[N2,~] = tepc.detector.sampleIonPairs(0.5*ones(20000,1), 31.1, 0.2, rs);
tc.verifyLessThan(abs(var(N2) - 0.5e3/31.1)/(0.5e3/31.1), 0.12, ...
    '小均值分支: Poisson Var = mu');
end

function test_ramo_conservation(tc)
ro = tepc.detector.ramoCurrent(1e-15, 100e-6, ...
    struct('a',50e-6,'b',0.0254,'hv_V',700), struct('Nt',20000));
tc.verifyLessThan(abs((ro.Q_electron_C + ro.Q_ion_C)/(-ro.q_C) - 1), 1e-9, ...
    'Shockley-Ramo: 电子+离子感应电荷 = -q');
end

function test_ramo_waveform_collection_and_guards(tc)
% 新函数: 逐采样区间注入电荷必须是"收集电荷之差", 总和不放大, 两支之和精确等于 q
cfg = demoCfgE();
field = struct('a',50e-6,'b',0.0254,'hv_V',700);
mob = struct('mu_e_m2_Vs',0.05*101325/1000, 'mu_i_m2_Vs',2e-4*101325/1000);
q = 1e-12; r0 = 5e-4;
wv = tepc.detector.ramoWaveform(q, r0, field, mob, cfg);
tc.verifyEqual(numel(wv.dq), round(cfg.electronics.waveWindow_s/cfg.electronics.sampleTime_s) + 1, ...
    'dq 长度 = 窗内采样区间数');
tc.verifyTrue(all(wv.dq >= 0), '收集电荷增量必须非负');
tc.verifyLessThanOrEqual(sum(wv.dq), q*(1+1e-9), '窗内收集电荷不得超过总电荷');
tc.verifyGreaterThan(sum(wv.dq), 0.5*q, '窗长应收集到大部分电荷 (否则弹道亏损过大)');
tc.verifyLessThan(abs((wv.Q_e_C + wv.Q_i_C)/q - 1), 1e-12, ...
    'Shockley-Ramo: 电子支+离子支终值 = q');
tc.verifyGreaterThan(wv.tau_e_s, 0);
tc.verifyLessThan(wv.tau_e_s, wv.tau_i_s, '电子漂移必须远快于离子');
tc.verifyEqual(wv.r0_m, r0);
tc.verifyError(@() tepc.detector.ramoWaveform(q, 0.03, field, mob, cfg), 'tepc:ramo:BadStart');
% 半径自非法由 fieldModel 单一真相源报 tepc:field:BadRadii 并向外传播;
% ramoWaveform 不再复制一份校验、也不把自己的标识符盖上去 (掩盖会丢来源)。
tc.verifyError(@() tepc.detector.ramoWaveform(q, r0, struct('a',50e-6,'b',40e-6,'hv_V',700), ...
    mob, cfg), 'tepc:field:BadRadii');
tc.verifyError(@() tepc.detector.ramoWaveform(q, r0, field, ...
    struct('mu_e_m2_Vs',0,'mu_i_m2_Vs',1e-4), cfg), 'tepc:ramo:BadMobility');
end

function test_diethorn_consistency(tc)
ga = tepc.detector.avalanche(struct('a',50e-6,'b',0.0254,'hv_V',700), ...
    struct('deltaV_V',36.5,'theta',8), RandStream('Threefry','Seed',1));
lnG = (log(2)/36.5)*(700/log(0.0254/50e-6))*log(10);
tc.verifyLessThan(abs(ga.G_mean - exp(lnG))/exp(lnG), 1e-9, 'Diethorn 闭式与实现一致');
end

% ---------------- 本地构造 ----------------
function cfg = demoCfgE()
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
cfg.electronics.Cf_F = 1e-12; cfg.electronics.sampleTime_s = 1e-9;
cfg.electronics.shaperOrder = 1;
end

function cfg = zeroNoise(cfg)
cfg.electronics.noise.en_white_nV_per_rootHz = 0;
cfg.electronics.noise.en_1f_amp_nV = 0;
cfg.electronics.noise.in_pA_per_rootHz = 0;
end

function [cfg, R, ctx] = elecCtx()
%ELECCCTX 构造 simulate 所需的完整 ctx (10 个必填字段, 与 execute 一致)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
cfg.electronics.Cf_F = 1e-12;
cfg.electronics.shaperOrder = 1;
R = tepc.config.resolve(cfg);
c = tepc.electronics.filters(cfg);
[~, msig] = tepc.electronics.noise(0, cfg, RandStream('Threefry','Seed',991), "sigma");
ctx = struct('W_eV', cfg.gas.W_eV.value, 'fano', cfg.gas.fano.value, ...
    'G_mean', R.G_mean, 'theta', 8, 'field', R.field, 'mob', R.mob, ...
    'coeffs', c, 'noiseSigma', msig.sigma_peak_V, 'seed', 4321, 'r0_m', R.r0_m);
end

function test_field_model_analytic_identities_both_geometries(tc)
% 场模型必须是静电学精确解, 且两种几何共用同一实现 (曾: 引擎硬编码圆柱、
% GUI 用球壳显示、四个模块各写一份 -> 同一仪器两种互相矛盾的场)。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
a = cfg.geometry.anodeRadius_um*1e-6; b = cfg.geometry.gasRadius_mm*1e-3; V = 700;
for kc = 1:2
    kind = ["cylinder","sphere"]; k = kind(kc);
    fm = tepc.detector.fieldModel(a, b, V, k);
    tc.verifyEqual(fm.phiw(a), 1, 'RelTol', 1e-12, sprintf('%s: phi_w(a)=1', k));
    tc.verifyEqual(fm.phiw(b), 0, 'AbsTol', 1e-12, sprintf('%s: phi_w(b)=0', k));
    tc.verifyTrue(fm.phiw(a) > fm.phiw(b), '权重势由阳极到阴极递减');
    tc.verifyEqual(fm.intE(a, b), V, 'RelTol', 1e-10, sprintf('%s: int_a^b E dr = V', k));
    tc.verifyEqual(fm.intE(a, sqrt(a*b)) + fm.intE(sqrt(a*b), b), V, 'RelTol', 1e-10, ...
        '区间可加');
    mu = 0.05; tend = fm.tCollect(sqrt(a*b), mu, b);
    tc.verifyEqual(fm.rOfT(sqrt(a*b), mu, +1, tend), b, 'RelTol', 1e-9, ...
        'r(t) 与 tCollect 必须互逆');
    tc.verifyGreaterThan(tend, 0, '收集时间必须为正有限');
    % 轨道闭式必须真的满足 dr/dt = +/- mu*E(r): 用**中心差分 + 只依赖 E** 的残差检验。
    % (rOfT 与 tCollect 互逆是同义反复 —— p/K/符号同时写错也照样互逆, 抓不出来。)
    % 步长必须按**各自方向**的收集时间取: 球壳向内 t_in 比向外 t_out 短 4 个量级,
    % 共用 t_out 的 1e-5 会让差分误差涨到 7% (实测, 是测试自己的缺陷)。
    r0d = sqrt(a*b);
    tOut = fm.tCollect(r0d, mu, b);   tIn = fm.tCollect(r0d, mu, a);
    for fr = [0.2 0.5 0.8]
        hh = tOut*1e-5; t1 = fr*tOut;
        spd = (fm.rOfT(r0d, mu, +1, t1+hh) - fm.rOfT(r0d, mu, +1, t1-hh))/(2*hh);
        tc.verifyEqual(spd, mu*fm.E(fm.rOfT(r0d, mu, +1, t1)), 'RelTol', 1e-3, ...
            sprintf('%s: 向外速度必须等于 +mu*E(r)', k));
        hh = tIn*1e-5; t1 = fr*tIn;
        spd = (fm.rOfT(r0d, mu, -1, t1+hh) - fm.rOfT(r0d, mu, -1, t1-hh))/(2*hh);
        tc.verifyEqual(-spd, mu*fm.E(fm.rOfT(r0d, mu, -1, t1)), 'RelTol', 1e-3, ...
            sprintf('%s: 向内速度必须等于 -mu*E(r)', k));
    end
end
% 圆柱解必须与解析式逐项一致 (回归保护: 迁移到 fieldModel 后不得改变历史行为)
fm = tepc.detector.fieldModel(a, b, V, 'cylinder');
r = linspace(a*2, b*0.99, 5);
tc.verifyEqual(fm.E(r), V./(r*log(b/a)), 'RelTol', 1e-12, '圆柱 E=V/(r ln(b/a))');
tc.verifyEqual(fm.phiw(r), log(r/b)/log(a/b), 'RelTol', 1e-12, '圆柱 phi_w 解析式');
fs = tepc.detector.fieldModel(a, b, V, 'sphere');
tc.verifyEqual(fs.E(r), V./(r.^2*(1/a - 1/b)), 'RelTol', 1e-12, '球壳 E=V/(r^2(1/a-1/b))');
% 必须写成 1./r: 断言比较的是逐点解析式, 而 r 是行向量。写成 1/r 会走 mrdivide,
% 实测抛 MATLAB:dimagree (曾在测试自身里埋着, 与被测代码无关)。
tc.verifyEqual(fs.phiw(r), (1./r - 1/b)/(1/a - 1/b), 'RelTol', 1e-12, '球壳 phi_w');
tc.verifyError(@() tepc.detector.fieldModel(a, b, V, 'slab'), 'tepc:field:BadKind');
tc.verifyError(@() tepc.detector.fieldModel(0, b, V, 'cylinder'), 'tepc:field:BadRadii');
end

function test_ramo_waveform_conserves_charge_both_geometries(tc)
% Shockley-Ramo: 电子支 + 离子支 = q, 且逐样本收集电荷之和 <= q、必须为实数。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
R = tepc.config.resolve(cfg);
q = 1e-15;
for kc = 1:2
    kind = ["cylinder","sphere"]; fld = R.field; fld.kind = kind(kc);
    wv = tepc.detector.ramoWaveform(q, 10*fld.a, fld, R.mob, cfg);
    tc.verifyTrue(isreal(wv.dq), sprintf('%s: dq 不得被复数污染 (钳位须在开根之前)', kind(kc)));
    tc.verifyEqual(wv.Q_e_C + wv.Q_i_C, q, 'RelTol', 1e-12, '感应电荷份额之和 = q');
    tc.verifyTrue(all(wv.dq >= 0), '逐样本收集电荷非负 (单调收集)');
    frac = sum(wv.dq)/q;
    tc.verifyTrue(frac > 0 && frac <= 1, sprintf('窗口内收集份额 %.4f 必须落在 (0,1]', frac));
    % 基准必须是**手算闭式**。曾写成与 fieldModel 自己比对 (fldModelPhi 调的就是
    % 同一个 fm.phiw) —— 同义反复, 场模型怎么错都测不出来。
    if kind(kc) == "cylinder"
        phiRef = log(fld.b/wv.r0_m)/log(fld.b/fld.a);
    else
        phiRef = (1/wv.r0_m - 1/fld.b)/(1/fld.a - 1/fld.b);
    end
    tc.verifyEqual(wv.phi_w, phiRef, 'RelTol', 1e-12, ...
        sprintf('%s: phi_w(r0) 必须等于手算闭式', kind(kc)));
end
% 圆柱窗口份额必须与重构前实测值 0.8023 一致 (无回归)
wv = tepc.detector.ramoWaveform(q, 10*R.field.a, R.field, R.mob, cfg);
tc.verifyEqual(sum(wv.dq)/q, 0.80232, 'RelTol', 2e-4, ...
    '弹道亏损份额不得因场模型重构而改变');
end
