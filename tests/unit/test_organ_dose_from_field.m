function tests = test_organ_dose_from_field
%TEST_ORGAN_DOSE_FROM_FIELD 大气中子谱 × ICRP 116 系数 -> 皮肤/眼晶状体剂量谱的数值锁与反例腿。
%   十一个用例:
%     baselines              四组剂量率钉在登记值上 (改系数表/改能谱表/改卷积都会红);
%                            另含外推段的三条锁: 指数的 dphi/dE 口径 + n=4..12 窗长扫描的极差、
%                            指定指数时"只动外推段、实测两段逐位不变"的开关差分、系数表末点之外的注量天花板
%     siteOrdering           四站剂量率随海拔同序, 且拉萨/广州比与通量比同量级
%     segments               三段 basis 闭集、行数、群宽为正、段间不重叠也不留缝
%     spectrumConsistency    两张谱表的口径锁: 锚定求积式 + 网格同一性 + 接缝两侧读数比
%     lowSegmentSwitch       开关差分: 三档必须给不同低能段, 而直读段/外推段一位都不许动
%     thermalCutoff          热中子端确实被消费: belowStart 抬高一档低能段必须掉一截
%     coeffPerturbation      反例腿: 单点改坏系数表必须把剂量顶起来 (证明数值锁真连着那张表)
%     invalidInputs          七类坏输入的错名逐个钉住 (站点/几何/分段端点/档位/坏表/缺表/群界)
%     equivDoseAndWRLink     当量剂量 (Sv) 数值锁 + 几何散布实测 + "改 w_R 表只动 H 不动 D" 配对反例
%     figureNoOverlap        出图几何锁: 坐标区外沿(含 x 轴标签)与脚注上沿必须留 >=2px 间隙
%     figureReserveIsMeasured 两侧差分: 脚注字号 4->14 布局下沿必须抬高 (防预留高度写死)
%   写文件时踩到的语言事实 (都在这里防一手):
%     * isscalar('lens_of_eye') 是 false —— 名称型入参按"字符向量或 string 标量"校验。
%     * 两张表的注释行是中文, fileread 在中文 Windows 上按 GBK 解会乱码, 但数据行是纯 ASCII,
%       所以按 startsWith('#') 丢掉注释后逐字段 str2double 仍然正确。
%     * cellfun 出来的元胞数组不 vertcat 摊平, 列索引等于没索引 (见 spectrumColumn 里的注释)。

tests = functiontests(localfunctions);
end

function test_baselines(tc)
% 登记值 = 本函数对仓库当前两份数字化表在 R2025a 下的实测输出 (2026-10-10, _工作底稿/z773_probe.log)。
% 容差 1e-4 相对: 计算是确定性的, 放宽只为容错插值实现的差异, 收到足以抓住单点数据改动。
r = tepc.analysis.organDoseFromField();
chk(tc, 3584.666381, r.dose_rate_pGy_h.digitized, 'skin/female/ISO 直读段');
tc.verifyEqual(r.dose_rate_pGy_h.low, 229.618247, 'RelTol', 1e-4, 'skin/female/ISO 低能反演段');
tc.verifyEqual(r.dose_rate_pGy_h.extrapolated, 1617.069467, 'RelTol', 1e-4, '外推段');
tc.verifyEqual(r.dose_rate_pGy_h.total, 5431.354095, 'RelTol', 1e-4, 'skin/female/ISO 合计');
tc.verifyEqual(height(r.groups), 134, '三段行数应为 30+79+25');
tc.verifyEqual(r.meta.tail_power_law_p, 1.42286163, 'RelTol', 1e-6, '尾部幂律指数');
tc.verifyEqual(r.meta.segment_boundary_MeV, 0.998117, 'AbsTol', 1e-9, ...
    'A/B 分界必须是反演表自己的群界, 不是数字化段首群心');
q = tepc.analysis.organDoseFromField('organ', 'lens_of_eye', 'phantom', 'both');
tc.verifyEqual(q.dose_rate_pGy_h.digitized, 4083.498578, 'RelTol', 1e-4, 'lens/both/ISO 直读段');
tc.verifyEqual(q.dose_rate_pGy_h.low, 204.110320, 'RelTol', 1e-4, 'lens/both/ISO 低能段');
tc.verifyEqual(q.dose_rate_pGy_h.total, 5364.524409, 'RelTol', 1e-4, 'lens/both/ISO 合计');
tc.verifyEqual(q.meta.coeff_geometry_variants, 5, ...
    '晶状体表今天只有 5 个几何档 (AP/PA/LAT/ROT/ISO)');
m = tepc.analysis.organDoseFromField('phantom', 'male');
tc.verifyEqual(m.dose_rate_pGy_h.digitized, 3632.159548, 'RelTol', 1e-4, 'skin/male 直读段');
g = tepc.analysis.organDoseFromField('geometry', 'ROT');
tc.verifyEqual(g.dose_rate_pGy_h.digitized, 3620.376, 'RelTol', 1e-4, 'skin/female/ROT 直读段');
y = tepc.analysis.organDoseFromField('site', "Yangbajing");
tc.verifyEqual(y.dose_rate_pGy_h.digitized, 4517.837529, 'RelTol', 1e-4, '羊八井 直读段');
l = tepc.analysis.organDoseFromField('site', "Lanzhou");
tc.verifyEqual(l.dose_rate_pGy_h.digitized, 863.005663, 'RelTol', 1e-4, '兰州 直读段');
z = tepc.analysis.organDoseFromField('site', "Guangzhou");
tc.verifyEqual(z.dose_rate_pGy_h.digitized, 303.040710, 'RelTol', 1e-4, '广州 直读段');

% --- 外推段按"族"发货的三条锁 (登记值取自 _工作底稿/z836_tailprobe.log 10-10 08:40 那次输出) ---
% (a) 指数的口径与窗长敏感性: 拟合对象是表的 dphi/dE 列, 而指数对窗长极不稳,
%     所以窗口扫描随结果一起发出去 —— 没有这一行, 单一指数看起来像物理常数。
tc.verifyEqual(r.meta.tail_index_source, "fitted", '默认指数必须是拟合来的');
tc.verifyEqual(r.meta.tail_window_n, 4:12, '窗口扫描必须覆盖 n=4..12');
tc.verifyEqual(r.meta.tail_window_p, ...
    [1.415590 1.212111 1.422862 1.504231 1.460848 1.557185 1.598027 1.587001 1.621596], ...
    'RelTol', 1e-5, '逐档拟合指数');
tc.verifyEqual(r.meta.tail_window_spread, 0.40948506, 'RelTol', 1e-5, ...
    'n=4..12 的指数极差: 这条就是"外推段不能当点值"的直接证据');
tc.verifyTrue(contains(string(r.meta.tail_index_convention), "减 1"), ...
    '指数口径必须写明它是 dphi/dE 的斜率 (每单位 lethargy 要减 1)');

% (b) 开关差分: 指定指数只许动 C 段, 实测两段一位都不许变; C 的五个族端点逐个钉住。
A0 = r.dose_rate_pGy_h.digitized; B0 = r.dose_rate_pGy_h.low;
bandP  = [1.19400 2.00000 2.30000 2.70000 3.00000];
bandC  = [2121.573353 898.628100 696.947621 520.427656 430.711708];
for ib = 1:numel(bandP)
    qb = tepc.analysis.organDoseFromField('tailIndex', bandP(ib));
    tc.verifyEqual(qb.dose_rate_pGy_h.digitized, A0, ...
        sprintf('tailIndex=%.3f 不许动直读段', bandP(ib)));
    tc.verifyEqual(qb.dose_rate_pGy_h.low, B0, ...
        sprintf('tailIndex=%.3f 不许动低能反演段', bandP(ib)));
    tc.verifyEqual(qb.dose_rate_pGy_h.extrapolated, bandC(ib), 'RelTol', 1e-4, ...
        sprintf('tailIndex=%.3f 的外推段', bandP(ib)));
    tc.verifyEqual(height(qb.groups), 134, '换指数不改行数');
end

% (c) 第二层天花板: aboveEnd 是系数表末点钉的, 同幂律在其上还挂着算不出剂量的注量。
tc.verifyEqual(r.meta.coef_energy_max_MeV, 1e4, '系数表末点');
tc.verifyEqual(r.meta.fluence_extrapolated_cm2_h, 7.877868, 'RelTol', 1e-5, '已计分的外推段注量');
tc.verifyEqual(r.meta.fluence_beyond_coef_max_cm2_h, 3.074035, 'RelTol', 1e-5, ...
    'aboveEnd 之上无系数可乘的那段注量');
tc.verifyGreaterThan(r.meta.fluence_beyond_coef_max_cm2_h / r.meta.fluence_extrapolated_cm2_h, 0.30, ...
    '天花板披露的份额必须被记住 (>30%): 收窄 aboveEnd 或改幂律都会动它, 不许悄悄变成一句空话');

% ---- 皮肤/晶状体口径锁 ----
% 这六条披露字符串此前**没有任何锁**: 删掉一句、或把"单向偏下"写成"±35%"都不会红,
% 而这正是审查要防的"披露退化成装饰"。判据一律两侧写 (必须含 X, 必须不含 Y)。
% 射程换算的实测数取自 _工作底稿/z855_anchorlegs.log。
m = r.meta;
tc.verifyTrue(contains(string(m.skin_definition), "C.12/C.27") && ...
    contains(string(m.skin_definition), "不是 Hp(0.07)"), ...
    '皮肤口径必须写明系数的表号与"不是 Hp(0.07)"这一句');
sv = string(m.skin_voxel_bias);
tc.verifyTrue(contains(sv, "35") && contains(sv, "10-14 MeV") && contains(sv, "不可乘出修正值"), ...
    '皮肤体素偏差必须同时给出 35% 上界、适用能带 (10-14 MeV) 与"不可乘出修正值"');
% 两侧都要在: "单向偏下" 说出方向, "不是 ±35%" 显式否掉对称读法。
% 反例腿只能判"对称写法"本身, 不能判 ±35 这个子串 —— 否定句里合法地出现它。
tc.verifyTrue(contains(sv, "单向偏下") && contains(sv, "不是 ±35%"), ...
    '35% 必须写成单向偏下界并显式否定对称 ±35%: 少任何一半都把"只会低估"这个信息丢掉');
ln = string(m.lens_definition);
tc.verifyTrue(contains(ln, "混合出处") && contains(ln, "4 MeV") && contains(ln, "没有 LLAT/RLAT"), ...
    '晶状体口径必须写明 4 MeV 以下换源模型与"只有五个几何档"');
tc.verifyTrue(contains(string(m.no_neutron_hp007), "Hp(0.07)") && ...
    contains(string(m.no_neutron_hp007), "中子"), '必须保留"中子没有 Hp(0.07) 表"这条否定');
pc = string(m.phantom_caveat);
tc.verifyTrue(contains(pc, "未量化假设") && contains(pc, "在可及来源中未找到"), ...
    '体模人种差异必须写成未量化假设并带"可及来源"限定; 不得写成"没有公开定量值"这种比检索能力更强的断言');
% 反例腿: 那两条来自编码损坏件、我复算不出的百分比不许被写回披露里
tc.verifyFalse(any(cellfun(@(t) contains(pc, t), {'17%', '36%', '33%'})), ...
    'phantom_caveat 不得出现无法在本仓数据层复现的百分比 (17%/36%/33% 来自数字层损坏的转载件)');
cc = string(m.corrigenda_check);
tc.verifyTrue(contains(cc, "A.1/A.2/B.7/B.10/G.2") && contains(cc, "未被官方勘误波及") && ...
    contains(cc, "sha256"), ...
    '勘误核对必须写出被波及的表号、结论与本体的 sha256; 只留一句"已核对勘误"等于没有证据');
tc.verifyTrue(contains(cc, "不等于数值已由独立来源证明"), ...
    '必须保住"未被波及 != 已独立证明"这半句, 否则读者会把它当成升格依据');
gc = string(m.geometry_caveat);
tc.verifyTrue(contains(gc, "AP") && contains(gc, "PA") && contains(gc, "混着模型出处切换"), ...
    '几何口径必须保住 AP/PA 交叉与"低能端混着源模型切换"这两半');
end

function test_siteOrdering(tc)
sites = ["Guangzhou", "Lanzhou", "Lhasa", "Yangbajing"];
d = zeros(size(sites)); f = d;
for i = 1:numel(sites)
    x = tepc.analysis.organDoseFromField('site', sites(i), 'geometryScan', false);
    d(i) = x.dose_rate_pGy_h.digitized;
    f(i) = x.meta.published_flux_cm2_h;
end
tc.verifyTrue(all(diff(d) > 0), sprintf('剂量率未随海拔单调上升: %s', mat2str(d)));
tc.verifyTrue(all(diff(f) > 0), '正文通量列未随海拔单调 (夹具或表被改坏)');
ratioD = d(3) / d(1);  ratioF = f(3) / f(1);
tc.verifyTrue(abs(ratioD / ratioF - 1) < 0.5, ...
    sprintf('拉萨/广州 剂量比 %.4g 与通量比 %.4g 差得过多', ratioD, ratioF));
end

function test_segments(tc)
r = tepc.analysis.organDoseFromField();
g = r.groups;
tc.verifyTrue(isequal(unique(g.basis), ...
    ["digitized_anchored"; "digitized_inverted"; "extrapolated_above"]), ...
    'basis 取值集合被改动 (闭集, 加一段要同步这里的判据)');
want = struct('digitized_inverted', 79, 'digitized_anchored', 30, 'extrapolated_above', 25);
fld = fieldnames(want);
for i = 1:numel(fld)
    m = g.basis == string(fld{i});
    tc.verifyEqual(sum(m), want.(fld{i}), sprintf('%s 段行数', fld{i}));
    E = g.energy_MeV(m);
    tc.verifyTrue(all(diff(E) > 0), sprintf('%s 段能量非单调', fld{i}));
    tc.verifyTrue(all(g.width_MeV(m) > 0), sprintf('%s 段存在非正群宽', fld{i}));
    tc.verifyTrue(all(g.dose_rate_pGy_h(m) > 0), sprintf('%s 段存在非正剂量', fld{i}));
    tc.verifyTrue(all(g.edge_lo_MeV(m) < E) && all(g.edge_hi_MeV(m) > E), ...
        sprintf('%s 段群界没有夹住群心', fld{i}));
    % 群宽必须等于自己那行的群界差: 之前外推段首行的群界是线性外推的负数而群宽是另一个数,
    % 于是 groups 表里 width 与 edge_hi-edge_lo 不自洽 —— 逐行钉死, 免得再漂回去。
    tc.verifyTrue(all(abs(g.width_MeV(m) - (g.edge_hi_MeV(m) - g.edge_lo_MeV(m))) ...
        < 1e-9 * g.width_MeV(m)), sprintf('%s 段 width 与群界差不一致', fld{i}));
end
lo = g(g.basis == "digitized_inverted", :);
di = g(g.basis == "digitized_anchored", :);
hi = g(g.basis == "extrapolated_above", :);
% 段间接缝: 前一段的最后群界必须**正好**是后一段的第一群界 —— 不重叠也不留缝。
% 旧版用群心当分界, 数字化段首群的外推下界 (0.9276) 比反演段的群界 (0.9981) 低 7%,
% 那段注量被计了两遍; 这条就是把那种重叠钉成硬红。
tc.verifyEqual(max(lo.edge_hi_MeV), min(di.edge_lo_MeV), 'AbsTol', 1e-9, '低能段与直读段之间有缝或重叠');
tc.verifyEqual(max(di.edge_hi_MeV), min(hi.edge_lo_MeV), 'AbsTol', 1e-9, '直读段与外推段之间有缝或重叠');
tc.verifyTrue(max(lo.energy_MeV) < min(di.energy_MeV), '低能段群心越过分界');
share = r.dose_rate_pGy_h.extrapolated / r.dose_rate_pGy_h.digitized;
tc.verifyTrue(share > 0.05 && share < 1.0, ...
    sprintf('外推段份额 %.3f 出了预期区间: 尾部斜率或系数表被改动', share));
end

function test_spectrumConsistency(tc)
% 两张谱表的口径锁。三条都是"改错任何一边就红", 不是自我确认:
%   1) 锚定求积式与消费方同式 => 直读段复算通量对正文值的偏差必须在 1e-6 量级。
%      旧表按梯形积分锚定, 同一偏差是 +2.8%/+3.7%/+8.3%/+0.5% —— 换回旧口径这条立刻红。
%   2) 网格同一性: 图 3(b) 的 30 个点逐点等于图 3(a) 中 E>=1 MeV 的 30 群 => 拼接是同一解的分段。
%   3) 接缝两侧同一能量的读数比 ≈ 1 (两条通道独立数字化、独立锚定, 所以它不是恒等式)。
sites = ["Lhasa", "Yangbajing", "Lanzhou", "Guangzhou"];
root = tepc.io.projectRoot();
dPath = fullfile(root, 'config', 'reference', 'lhasa_neutron_spectrum_digitized.csv');
fPath = fullfile(root, 'config', 'reference', 'lhasa_neutron_spectrum_fullrange_digitized.csv');
Ed = spectrumColumn(dPath, 'energy_MeV', 'Lhasa');
Ef = spectrumColumn(fPath, 'energy_MeV', 'Lhasa');
sub = Ef(Ef >= 1.0);
tc.verifyEqual(numel(sub), numel(Ed), '图3(a) 里 E>=1 MeV 的群数应正好等于图3(b) 的点数');
dev = abs(sub(1:numel(Ed)) ./ Ed - 1);
tc.verifyTrue(max(dev) < 0.005, ...
    sprintf('两图能群中心最大偏移 %.5f: 图 3(b) 不再是图 3(a) 的高能子集, 拼接前提没了', max(dev)));
for i = 1:numel(sites)
    x = tepc.analysis.organDoseFromField('site', sites(i), 'geometryScan', false);
    tc.verifyTrue(abs(x.meta.flux_check_rel) < 1e-6, sprintf( ...
        '%s 直读段复算通量对正文偏 %.4g: 锚定口径与消费方求积式不一致', ...
        sites(i), x.meta.flux_check_rel));
    tc.verifyTrue(x.meta.overlap_dphi_ratio > 0.95 && x.meta.overlap_dphi_ratio < 1.10, ...
        sprintf('%s 两通道在 1.117/1.119 MeV 的读数比 %.4f 出了 [0.95,1.10]', ...
        sites(i), x.meta.overlap_dphi_ratio));
    tc.verifyTrue(x.meta.overlap_center_offset < 0.005, ...
        sprintf('%s 接缝对照群不是同一群 (中心偏移 %.5f)', ...
        sites(i), x.meta.overlap_center_offset));
end
end

function test_lowSegmentSwitch(tc)
% 开关差分: 低能段三档必须给出**不同**的低能剂量, 而直读段与外推段一位都不许动。
% 只测"三档不一样"不够 —— 要同时钉住另两段恒定, 否则换档把整条链改了一遍也算"通过"。
inv = tepc.analysis.organDoseFromField('lowSegment', 'inverted', 'geometryScan', false);
ub = tepc.analysis.organDoseFromField('lowSegment', 'upper_bound', 'geometryScan', false);
no = tepc.analysis.organDoseFromField('lowSegment', 'none', 'geometryScan', false);
tc.verifyEqual(string(unique(inv.groups.basis(inv.groups.basis ~= "digitized_anchored" ...
    & inv.groups.basis ~= "extrapolated_above"))), "digitized_inverted", ...
    'inverted 档的 basis 标签');
tc.verifyEqual(string(unique(ub.groups.basis(ub.groups.basis ~= "digitized_anchored" ...
    & ub.groups.basis ~= "extrapolated_above"))), "upper_bound_below", 'upper_bound 档的 basis 标签');
tc.verifyEqual(no.dose_rate_pGy_h.low, 0, 'AbsTol', 0, 'none 档不该给低能段任何剂量');
tc.verifyEqual(height(no.groups), 55, 'none 档只剩 30+25 行');
% 另两段逐位相同 (RelTol 0 / AbsTol 0): 换低能档不该波及 1 MeV 以上。
tc.verifyEqual(ub.dose_rate_pGy_h.digitized, inv.dose_rate_pGy_h.digitized, ...
    'RelTol', 0, 'AbsTol', 0, '换低能档动了直读段吸收剂量');
tc.verifyEqual(no.equiv_dose_rate_pSv_h.extrapolated, inv.equiv_dose_rate_pSv_h.extrapolated, ...
    'RelTol', 0, 'AbsTol', 0, '换低能档动了外推段当量剂量');
% 实测反演段比"第一群平铺的上界"更大 (拉萨 D 229.6 vs 114.9, H 3309 vs 2192):
% 平铺把 0.1~1 MeV 那段蒸发峰的注量摊薄了, 所以它连下界都不如反演值 —— 阈值留一倍余量。
tc.verifyGreaterThan(inv.dose_rate_pGy_h.low, 1.5 * ub.dose_rate_pGy_h.low, ...
    sprintf('反演段 D %.6g 没比上界档 %.6g 大 1.5 倍: 低能表没被消费', ...
    inv.dose_rate_pGy_h.low, ub.dose_rate_pGy_h.low));
tc.verifyGreaterThan(inv.equiv_dose_rate_pSv_h.low, 1.25 * ub.equiv_dose_rate_pSv_h.low, ...
    sprintf('反演段 H %.6g 没比上界档 %.6g 大 1.25 倍', ...
    inv.equiv_dose_rate_pSv_h.low, ub.equiv_dose_rate_pSv_h.low));
end

function test_thermalCutoff(tc)
% 热端反例腿: belowStart 从表首一路抬高, 低能段的行数与剂量必须一路掉。
% 这条防的是"低能表读进来了但热中子那几十群没进求和" —— 份额锁 (low>0) 对此是瞎的。
cuts = [0 1e-6 1e-3 1e-1];
dv = zeros(size(cuts)); hv = dv; nv = dv;
for i = 1:numel(cuts)
    x = tepc.analysis.organDoseFromField('belowStart', cuts(i), 'geometryScan', false);
    dv(i) = x.dose_rate_pGy_h.low; hv(i) = x.equiv_dose_rate_pSv_h.low;
    nv(i) = x.meta.low_rows;
end
tc.verifyTrue(all(diff(nv) < 0), sprintf('低能行数没有随 belowStart 单调减少: %s', mat2str(nv)));
tc.verifyTrue(all(diff(dv) < 0), sprintf('低能段剂量没有随 belowStart 单调减少: %s', mat2str(dv)));
tc.verifyTrue(all(diff(hv) < 0), '低能段当量剂量没有随 belowStart 单调减少');
% 1 eV 以下那段 (热峰) 单独切掉要看得见: 实测 229.618 -> 205.799 pGy/h。
tc.verifyGreaterThan(dv(1) - dv(2), 5, ...
    sprintf('切掉 E<1e-6 MeV 只动了 %.4g pGy/h: 热中子群没有真的进求和', dv(1) - dv(2)));
end

function test_coeffPerturbation(tc)
% 反例腿方向 = "改坏数据必须改结果"。同时跑一份逐行等价的替身表, 证明这个口子本身不引入偏差。
root = tepc.io.projectRoot();
src = fullfile(root, 'config', 'reference', 'icrp116_neutron_skin_lens_coefficients.csv');
[hdr, body] = asciiRows(src);
keep = false(size(body));
for i = 1:numel(body)
    f = strsplit(body{i}, ',');
    keep(i) = strcmp(f{1}, 'skin') && strcmp(f{2}, 'female') && ...
              strcmp(f{4}, 'neutron') && strcmp(f{6}, 'ISO');
end
sub = body(keep);
tc.verifyEqual(numel(sub), 68, '替身表应正好取到 skin/female/ISO 的 68 个能量点');
base = fullfile(tempdir, 'tepc_coeff_base.csv');
mut = fullfile(tempdir, 'tepc_coeff_mut.csv');
writeCsv(base, hdr, sub, 1);
writeCsv(mut, hdr, sub, 10);
r0 = tepc.analysis.organDoseFromField();
rb = tepc.analysis.organDoseFromField('coeffPath', base);
rm = tepc.analysis.organDoseFromField('coeffPath', mut);
tc.verifyEqual(rb.dose_rate_pGy_h.digitized, r0.dose_rate_pGy_h.digitized, ...
    'RelTol', 1e-9, '替身表未改动时必须与原表同值');
tc.verifyGreaterThan(rm.dose_rate_pGy_h.digitized, 1.05 * r0.dose_rate_pGy_h.digitized, ...
    sprintf('系数表 50-200 MeV 放大 10 倍后直读段剂量没动 (原 %.6g 新 %.6g): 数值锁没连着系数表', ...
    r0.dose_rate_pGy_h.digitized, rm.dose_rate_pGy_h.digitized));
% 低能段同样必须连着系数表 (热中子系数在 1e-9..1e-2 MeV 段被放大后也要动)。
tc.verifyGreaterThan(rm.dose_rate_pGy_h.low, 1.05 * r0.dose_rate_pGy_h.low, ...
    sprintf('系数放大后低能反演段没动 (原 %.6g 新 %.6g)', ...
    r0.dose_rate_pGy_h.low, rm.dose_rate_pGy_h.low));
end

function test_invalidInputs(tc)
tc.verifyError(@()tepc.analysis.organDoseFromField('site', 'Xian'), 'tepc:organDose:NoSite');
tc.verifyError(@()tepc.analysis.organDoseFromField('organ', 'lens_of_eye', ...
    'phantom', 'both', 'geometry', 'LLAT'), 'tepc:organDose:NoCoeff');
tc.verifyError(@()tepc.analysis.organDoseFromField('belowStart', 5), ...
    'tepc:organDose:SegmentOrder');
tc.verifyError(@()tepc.analysis.organDoseFromField('lowSegment', 'sideways'), ...
    'tepc:organDose:LowMode');
% 发散守卫在"用户直接指定指数"这条路上也必须生效: 否则指定一个 <=1 的指数就绕过了积分发散的判定。
tc.verifyError(@()tepc.analysis.organDoseFromField('tailIndex', 0.9), ...
    'tepc:organDose:TailDivergent');
% belowStart 落在分界与最后一个低能群心之间 => 一行都不剩, 必须是自己的错名而不是假绿。
tc.verifyError(@()tepc.analysis.organDoseFromField('belowStart', 0.99), ...
    'tepc:organDose:LowEmpty');
bad = fullfile(tempdir, 'tepc_bad_spectrum.csv');
writeLines(bad, {'site,altitude_m,energy_MeV', 'Lhasa,3634'});
tc.verifyError(@()tepc.analysis.organDoseFromField('spectrumPath', bad), ...
    'tepc:organDose:RaggedCsv');
tc.verifyError(@()tepc.analysis.organDoseFromField('spectrumPath', ...
    fullfile(tempdir, 'tepc_no_such_table.csv')), 'tepc:organDose:MissingTable');
gap = fullfile(tempdir, 'tepc_gap_spectrum.csv');
writeLines(gap, {specHdr(), 'Lhasa,3634,1.1,1.0,1.2,1,1,1,67.4,4', ...
    'Lhasa,3634,1.5,1.3,1.7,1,1,1,67.4,4', 'Lhasa,3634,2.0,1.7,2.2,1,1,1,67.4,4'});
tc.verifyError(@()tepc.analysis.organDoseFromField('spectrumPath', gap, ...
    'lowSegment', 'none', 'aboveEnd', 2.5), 'tepc:organDose:EdgeGap');
noc = fullfile(tempdir, 'tepc_edge_spectrum.csv');
writeLines(noc, {specHdr(), 'Lhasa,3634,1.1,1.2,1.4,1,1,1,67.4,4', ...
    'Lhasa,3634,1.5,1.4,1.7,1,1,1,67.4,4', 'Lhasa,3634,2.0,1.7,2.2,1,1,1,67.4,4'});
tc.verifyError(@()tepc.analysis.organDoseFromField('spectrumPath', noc, ...
    'lowSegment', 'none', 'aboveEnd', 2.5), 'tepc:organDose:EdgeOrder');
end

function test_equivDoseAndWRLink(tc)
% 当量剂量侧的数值锁 + "H 连着 w_R 表而 D 不连"的配对反例腿。
% 基线: 2026-10-10 R2025a 实测 (_工作底稿/z773_probe.log 第 1 节)。
r = tepc.analysis.organDoseFromField();
tc.verifyEqual(r.equiv_dose_rate_pSv_h.digitized, 21987.515720, 'RelTol', 1e-4, ...
    'skin/female/ISO 当量剂量 直读段');
tc.verifyEqual(r.equiv_dose_rate_pSv_h.low, 3309.282280, 'RelTol', 1e-4, ...
    'skin/female/ISO 当量剂量 低能反演段');
tc.verifyEqual(r.equiv_dose_rate_pSv_h.total, 29501.196091, 'RelTol', 1e-4, '合计');
tc.verifyEqual(r.dose_averaged_wR.digitized, 6.133769, 'RelTol', 1e-4, ...
    '直读段剂量加权 w_R (不是常数 20)');
tc.verifyEqual(r.dose_averaged_wR.low, 14.412105, 'RelTol', 1e-4, ...
    '低能段剂量加权 w_R: 热中子端回到 2.5, 峰在 ~1 MeV, 不是整段按 20 计');
q = tepc.analysis.organDoseFromField('organ', 'lens_of_eye', 'phantom', 'both');
tc.verifyEqual(q.equiv_dose_rate_pSv_h.digitized, 24431.743575, 'RelTol', 1e-4, ...
    'lens/both/ISO 当量剂量 直读段');
tc.verifyEqual(q.dose_averaged_wR.digitized, 5.983042, 'RelTol', 1e-4, 'lens 剂量加权 w_R');
% 几何散布必须是量出来的, 而且要分口径给: 含低能反演段与只算直读段是两个数。
gq = q.geometry_sensitivity;
iAP = find(gq.geometry == "AP", 1);  iISO = find(gq.geometry == "ISO", 1);
tc.verifyGreaterThan(numel(gq.geometry), 3, '几何档没扫全');
tc.verifyEqual(gq.dose_digitized_pGy_h(iAP) / gq.dose_digitized_pGy_h(iISO), 0.723799, ...
    'RelTol', 1e-3, '晶状体 AP/ISO 吸收剂量比 (只算直读段)');
tc.verifyEqual(gq.dose_pGy_h(iAP) / gq.dose_pGy_h(iISO), 0.805880, 'RelTol', 1e-3, ...
    '晶状体 AP/ISO 吸收剂量比 (含低能反演段)');
gs = r.geometry_sensitivity;
tc.verifyEqual(gs.dose_spread_rel, 0.101516, 'RelTol', 5e-3, '皮肤几何极差相对 ISO (含低能段)');
% 配对反例: 换一张 w_R 表 —— H 必须动, D 必须一动不动。
% 改哪一格是有讲究的: 连续性自检会把任何破坏断点取值的改动当场拦下 (试过把第 2 段振幅
% 17 改成 34, 结果是守卫先报错 —— 那是守卫在做事, 不是反例腿失效)。
% 第 1 段的 exponent_divisor 是唯一"改得动又不断边界"的格子: 在 E=1 处 ln(1*E)=0,
% 该段取值恒为 2.5+18.2=20.7, 与除数无关 => 两个断点都不动, 而 E<1 MeV 的 w_R 明显变。
root = tepc.io.projectRoot();
src = fullfile(root, 'config', 'reference', 'icrp103_neutron_wR_branches.csv');
raw = strsplit(strtrim(fileread(src)), newline);
mut = fullfile(tempdir, 'tepc_wR_mut_for_dose.csv');
fid = fopen(mut, 'w');
if fid < 0, error("tepc:test:CannotWrite", "写不出临时 w_R 表"); end
nHit = 0;
for i = 1:numel(raw)
    t = strtrim(raw{i});
    if isempty(t), continue; end
    if contains(t, '1,0,1,2.5,18.2,1,6'), nHit = nHit + 1; end
    fprintf(fid, '%s', [strrep(t, '1,0,1,2.5,18.2,1,6', '1,0,1,2.5,18.2,1,3') newline]);
end
fclose(fid);
tc.verifyEqual(nHit, 1, "夹具没在 w_R 表里找到第 1 段那一行, 反例腿会假过");
rd = tepc.analysis.organDoseFromField('wRTablePath', mut);
tc.verifyEqual(rd.dose_rate_pGy_h.total, r.dose_rate_pGy_h.total, 'RelTol', 0, 'AbsTol', 0, ...
    '换 w_R 表绝不该动吸收剂量');
% 阈值按实测效应量定, 不凭愿望: 见 z773_probe.log 第 9 节给出的低能段实际跌幅。
tc.verifyLessThan(rd.equiv_dose_rate_pSv_h.low, 0.985 * r.equiv_dose_rate_pSv_h.low, ...
    sprintf('第 1 段除数 6->3 后低能段当量剂量没动 (%.6g -> %.6g): H 没连着 w_R 表', ...
    r.equiv_dose_rate_pSv_h.low, rd.equiv_dose_rate_pSv_h.low));
% 反向配对: 直读段 (E>=0.998 MeV) 只用第 2/3 段, 改第 1 段不该波及它
tc.verifyEqual(rd.equiv_dose_rate_pSv_h.digitized, r.equiv_dose_rate_pSv_h.digitized, ...
    'RelTol', 0, 'AbsTol', 0, '改第 1 段却动了直读段的当量剂量: 分段归属写错了');
end

function test_figureNoOverlap(tc)
% 出图的文字重叠锁: 量出来的几何判据, 不看像素也不靠人眼。
fig = tepc.analysis.organDoseFigure();
cleanup = onCleanup(@() close(fig)); %#ok<NASGU>
% 隐藏 figure 上 findobj 只会拿到 GraphicsPlaceholder, 读不到 Position —— 必须先兑现。
fig.Visible = 'on'; drawnow; pause(0.3);
allh = findall(fig);
ax = allh(arrayfun(@(h) isa(h, 'matlab.graphics.axis.Axes'), allh));
ann = allh(arrayfun(@(h) isa(h, 'matlab.graphics.shape.TextBox'), allh));
tc.verifyEqual(numel(ax), 2, sprintf('子图数=%d, 应为 2', numel(ax)));
tc.verifyEqual(numel(ann), 1, '脚注没生成');
top = ann.Position(2) + ann.Position(4);
op = zeros(4, numel(ax));
for j = 1:numel(ax)
    op(:, j) = ax(j).OuterPosition(:);
end
ob = min(op(2, :));                    % 只取各坐标区外沿的 bottom, 不能 min 整个拼接向量
figH = fig.Position(4);
gapPx = ob * figH - top * figH;
gapMsg = sprintf('坐标区外沿最低 %.1f px 与脚注上沿 %.1f px 之间只剩 %.1f px 间隙, 文字会重叠', ...
    ob * figH, top * figH, gapPx);
tc.verifyGreaterThan(gapPx, 2, gapMsg);
% 脚注必须把**两层天花板**都讲出来: 曲线断在 1 GeV (解谱上限), 但真正"算不出剂量"的边界是
% ICRP 116 系数表末点 —— 它之上还挂着一段同幂律的注量, 没有系数可乘。只说前者, 这张图就在
% 替数据暗示 aboveEnd 之上仍有剂量。数字必须与卷积侧同源, 不许在图里写常数。
rr = tepc.analysis.organDoseFromField();
needPct = sprintf('%.1f%%', 100 * rr.meta.fluence_beyond_coef_max_cm2_h / ...
    rr.meta.fluence_extrapolated_cm2_h);
needE   = sprintf('%.3g MeV', rr.meta.coef_energy_max_MeV);
fjoin = strings(0, 1);
for q = 1:numel(ann)
    sq = ann(q).String;
    if iscell(sq), sq = strjoin(cellstr(sq), ' | '); end
    fjoin(end+1, 1) = string(strjoin(cellstr(sq), ' ')); %#ok<AGROW>
end
ftxt = strjoin(fjoin, ' || ');
tc.verifyTrue(contains(ftxt, '第二层天花板'), ...
    sprintf('脚注缺"第二层天花板"那一句 (脚注前 300 字: %s)', char(ftxt(1:min(300, numel(ftxt))))));
tc.verifyTrue(contains(ftxt, needE), ...
    sprintf('脚注没写出系数表末点的实际能量 %s: 换成常数或改了边界都不会红', needE));
tc.verifyTrue(contains(ftxt, needPct), ...
    sprintf('脚注没写出未计分注量占已计分外推段的实际份额 %s: 这句必须与 meta 同源', needPct));
tc.verifyTrue(contains(ftxt, "无系数可乘"), '脚注必须明说那段注量无系数可乘');
tc.verifyFalse(contains(ftxt, "全谱剂量") && ~contains(ftxt, "不是全谱剂量"), ...
    '脚注不得出现不带"不是"限定的"全谱剂量"');
lbl = strings(1, numel(ax));
for j = 1:numel(ax)
    lbl(j) = string(ax(j).XLabel.String);
end
tc.verifyTrue(all(lbl ~= ""), sprintf('有子图缺 x 轴标签: %s', strjoin(lbl, '|')));
% 刻度标签个数必须等于刻度位置个数: 多给一个标签 MATLAB 不报错, 只是把标签整体挪一格,
% 于是轴末端 10^4 的位置被念成 10^2 (10-10 看 PNG 时抓到过一次)。
for j = 1:numel(ax)
    tl = ax(j).XTickLabel;
    tc.verifyEqual(numel(tl), numel(ax(j).XTick), sprintf( ...
        '%d 号子图 XTickLabel 有 %d 个但 XTick 有 %d 个: 刻度会被整体错位', ...
        j, numel(tl), numel(ax(j).XTick)));
end
% 图例条目不得重复: 反演段用 HandleVisibility='off' 画, 若句柄是从 Children(1) 回取的,
% 拿到的会是上一条可见线, 图例就多出一条同名 Lhasa (同样是看 PNG 抓到的)。
lgs = findall(fig, 'Type', 'legend');
tc.verifyGreaterThan(numel(lgs), 0, '一张图例都没有');
for k = 1:numel(lgs)
    ss = string(lgs(k).String);
    tc.verifyEqual(numel(unique(ss)), numel(ss), sprintf('图例有重复条目: %s', strjoin(ss, ' | ')));
end
iL = panelWithYLabel(ax, 'd\Phi');
iR = panelWithYLabel(ax, '剂量率');
tc.verifyFalse(isempty(iL), '没有入射注量面板');
tc.verifyFalse(isempty(iR), '没有逐群剂量面板');
% 要按**图形类型**数, 不能直接数 allchild: 坐标轴的 XLabel/YLabel/ZLabel 与 Legend 是恒在的
% 对象, 把它们算进去会把"低能段整段没画"这种真缺陷掩盖成绿 (4 条线+标签就够越过门槛)。
% 反演段是 HandleVisibility='off' 画的 (图例只留一条通用条目), 它只在 allchild 里出现,
% 而 Axes 上没有 AllChildren 属性 (那是 Figure 的) —— 用 allchild() 函数取。
n1 = countType(ax(iL), 'line');
n2 = countType(ax(iR), 'patch');
% 左面板: 四站直读线 + 四站反演段 = 8 条; 少于 8 就是低能段没进图。
tc.verifyGreaterThan(n1, 7, sprintf('入射谱面板折线只有 %d 条 (应 >=8: 四站直读+四站反演); 实到类型 %s', ...
    n1, strjoin(objectTypes(ax(iL)), '|')));
% 右面板: 每个 basis 段是**一个** patch 对象 (X/Y 给 4×n 顶点 => n 个面一个对象)。
% 光数对象个数没有判别力 (底色矩形也是 patch), 所以再加一条几何判据: 右面板画出来的横坐标
% 最小值必须真的探到 1e-3 MeV 以下 —— 低能段没画就绝不可能满足它。
tc.verifyGreaterThan(n2, 2, sprintf('剂量面板 patch 只有 %d 个 (三段应各一个); 实到类型 %s', ...
    n2, strjoin(objectTypes(ax(iR)), '|')));
xmn = rightPanelMinLog10(ax(iR));
tc.verifyLessThan(xmn, -3, sprintf( ...
    '剂量面板横坐标最小 log10(E)=%.3f: 低能段没有在剂量面板里画出来 (应 < -3)', xmn));
end

function test_figureReserveIsMeasured(tc)
% 两侧差分: 脚注字号调大必须抬高布局下沿, 调小必须降低 —— 只测一个方向不能排除"写死"。
% 这条判据防的是: 预留高度被硬编码成一个常数, 换字号/换语言后脚注压住坐标轴。
figS = tepc.analysis.organDoseFigure([], struct(), 'footnoteFs', 4);
figL = tepc.analysis.organDoseFigure([], struct(), 'footnoteFs', 14);
cS = onCleanup(@() close(figS)); cL = onCleanup(@() close(figL)); %#ok<NASGU>
figS.Visible = 'on'; figL.Visible = 'on'; drawnow; pause(0.3);
bS = lowestOuterBottom(figS);
bL = lowestOuterBottom(figL);
msg = sprintf('脚注字号 4->14 后布局下沿只从 %.4f 动到 %.4f: 预留高度没跟着文字量走, 是写死的', bS, bL);
tc.verifyGreaterThan(bL, bS + 0.02, msg);
annS = firstTextBox(figS); annL = firstTextBox(figL);
tc.verifyLessThan(annS.Position(4), annL.Position(4), '脚注带高度没随字号变');

% opts 通道单独钉一条: organDoseWith 里用 a(end+1)=fn{i} 追加元胞会让**任何非空 opts** 直接崩
% ("无法将 char 转换为 cell"), 而空 opts 走不到那一行 —— 也就是说这张图"可换器官/换档位"的接口
% 从来没被执行过。下面这次调用本身就是那条接口的存在性证明, 后两条断言证明参数真的传到了卷积函数。
figO = tepc.analysis.organDoseFigure("Lhasa", struct('organ', 'lens_of_eye', ...
    'phantom', 'both', 'lowSegment', 'upper_bound'));
cO = onCleanup(@() close(figO)); %#ok<NASGU>
figO.Visible = 'on'; drawnow; pause(0.3);
allO = findall(figO);
axO = allO(arrayfun(@(h) isa(h, 'matlab.graphics.axis.Axes'), allO));
tstr = strings(1, numel(axO));
for j = 1:numel(axO)
    tstr(j) = string(axO(j).Title.String);
end
tc.verifyTrue(any(contains(tstr, 'lens_of_eye')), ...
    sprintf('opts 里的 organ 没进到子图标题: %s', strjoin(tstr, ' | ')));
iR = panelWithYLabel(axO, '剂量率');
tc.verifyFalse(isempty(iR), 'opts 传进去以后找不到剂量面板');
xmn = rightPanelMinLog10(axO(iR));
tc.verifyTrue(xmn > -3, sprintf( ...
    'lowSegment=upper_bound 时剂量面板仍画到 log10(E)=%.3f: 开关没传到出图', xmn));
% 文案也要跟着档位走: 这一档画的是"平铺上界"而不是图 3(a) 反演, 脚注却写"反演段"就是让图替
% 数据说一句它没做的事 (10-10 看 z784_fig_ub.png 抓到的: 标题与第五条已改, 第一条漏了)。
txtO = string(firstTextBox(figO).String);
tc.verifyTrue(any(contains(txtO, '上界')), ...
    sprintf('upper_bound 档的脚注里没有"上界"字样: %s', strjoin(txtO, ' / ')));
tc.verifyFalse(any(contains(txtO, '低能反演段')), ...
    sprintf('upper_bound 档的脚注仍把低能段叫"反演段" (档位与文案脱钩): %s', strjoin(txtO, ' / ')));
% 默认档反向配对: 同一处文案在 inverted 档必须写"反演", 两档文案相同说明是写死的字符串。
figI = tepc.analysis.organDoseFigure("Lhasa", struct('lowSegment', 'inverted'));
cI = onCleanup(@() close(figI)); %#ok<NASGU>
figI.Visible = 'on'; drawnow; pause(0.3);
txtI = string(firstTextBox(figI).String);
tc.verifyTrue(any(contains(txtI, '低能反演段')), ...
    sprintf('inverted 档的脚注丢了"反演"字样, 两档文案变成同一句: %s', strjoin(txtI, ' / ')));
end

function i = panelWithYLabel(ax, key)
% 按 y 轴标签认面板: findall 返回的坐标区顺序与创建顺序相反, 按索引取会张冠李戴。
for j = 1:numel(ax)
    if contains(string(ax(j).YLabel.String), key)
        i = j; return
    end
end
i = [];
end

function t = objectTypes(ax)
% 坐标区里所有子对象(含 HandleVisibility='off' 的)的 Type 字符串, 去重排序。
% 按 Type 而不是按类名筛: 类名(matlab.graphics.chart.primitive.Line 之类)在不同版本/不同建图
% 入口下会变, Type 是图形对象自带的稳定标识; 失败消息里把它打出来, 下次一眼看出实际是什么。
ch = allchild(ax);
raw = cellfun(@(h) string(h.Type), num2cell(ch), 'UniformOutput', false);
t = sort(unique(string([raw{:}])));
end

function n = countType(ax, tname)
t = objectTypes(ax);
ch = allchild(ax);
raw = cellfun(@(h) string(h.Type), num2cell(ch), 'UniformOutput', false);
n = sum(strcmp(string([raw{:}]), tname));
end

function v = rightPanelMinLog10(ax)
% 右面板所有 patch 的横坐标最小值 (图里 x 已经是 log10(能量))。空面板给 +Inf 让它必然红。
ch = allchild(ax);
v = inf;
for i = 1:numel(ch)
    h = ch(i);
    if ~strcmp(h.Type, 'patch'), continue; end
    xd = h.XData;
    if isempty(xd), continue; end
    v = min(v, min(xd(:)));
end
end

function b = lowestOuterBottom(fig)
allh = findall(fig);
ax = allh(arrayfun(@(h) isa(h, 'matlab.graphics.axis.Axes'), allh));
v = inf(1, numel(ax));
for j = 1:numel(ax)
    v(j) = ax(j).OuterPosition(2);
end
b = min(v);
end

function h = firstTextBox(fig)
allh = findall(fig);
t = allh(arrayfun(@(x) isa(x, 'matlab.graphics.shape.TextBox'), allh));
if isempty(t), h = matlab.graphics.GraphicsPlaceholder; else, h = t(1); end
end

% ---------------------------------------------------------------- 夹具
function chk(tc, want, v, what)
tc.verifyEqual(v, want, 'RelTol', 1e-4, what);
end

function [hdr, rows] = asciiRows(path)
raw = strsplit(strtrim(fileread(path)), newline);
raw = raw(~cellfun(@(s) isempty(strtrim(s)) || startsWith(strtrim(s), '#'), raw));
hdr = strtrim(raw{1});
rows = strtrim(raw(2:end));
end

function h = specHdr()
% 表头串: 单引号 char 字面量之间的 + 是**逐元素加法** (不是拼接), 长度不等当场报
% sizeDimensionsMustMatch —— 用 string 的 + 才是拼接。
h = "site,altitude_m,energy_MeV,edge_lo_MeV,edge_hi_MeV,dphi_dE_raw_cm2_s_MeV," + ...
    "dphi_dE_anchored_cm2_s_MeV,anchor_scale,published_flux_cm2_h,source_pdf_page";
end

function v = spectrumColumn(path, name, site)
% 从谱表里按站点取一列 (数值)。元胞数组必须 vertcat 摊平, 否则 rows(:,k) 是嵌套格,
% 列索引等于没索引。
raw = strsplit(strtrim(fileread(path)), newline);
raw = raw(~cellfun(@(s) isempty(strtrim(s)) || startsWith(strtrim(s), '#'), raw));
hdr = strsplit(strtrim(raw{1}), ',');
iS = find(strcmp(hdr, 'site'), 1);
iC = find(strcmp(hdr, name), 1);
tc = cellfun(@(s) strtrim(strsplit(s, ',')), raw(2:end), 'UniformOutput', false);
M = vertcat(tc{:});
keep = strcmp(M(:, iS), site);
v = str2double(M(keep, iC));
end

function writeCsv(path, hdr, rows, mult)
% 只写 ASCII: 表头原样, 数据行的系数列 (第 7 列) 乘 mult。
L = {hdr};
for i = 1:numel(rows)
    f = strsplit(rows{i}, ',');
    f{7} = sprintf('%.10g', str2double(f{7}) * mult);
    L{end+1} = strjoin(f, ','); %#ok<AGROW>
end
writeLines(path, L);
end

function writeLines(path, L)
fid = fopen(path, 'w', 'n');
if fid < 0
    error("tepc:test:CannotWrite", "临时表写不出去: %s", path);
end
for i = 1:numel(L)
    fprintf(fid, '%s\n', L{i});
end
fclose(fid);
end
