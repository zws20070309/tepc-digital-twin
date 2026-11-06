function out = organDoseFromField(varargin)
%ORGANDOSEFROMFIELD 外部大气中子场 -> 皮肤/眼晶状体剂量谱: 注量谱 × ICRP 116 注量-剂量转换系数。
%
% 与 tepc.analysis.doseChain 的分工: doseChain 是 TEPC 微剂量链 (单个微位点的比能量, 事件口径);
% 本函数是辐射防护口径的器官剂量 —— 给定入射中子注量谱, 乘 ICRP 116 的注量->器官吸收剂量
% 转换系数, 得到该器官剂量率随能量的分布。两者不共用任何乘子。
%
% 数据 (三张数字化表, 归属登记在 config/reference_slots.json 的 unclaimed_anchor_files):
%   config/reference/lhasa_neutron_spectrum_digitized.csv            图 3(b) 直读 dphi/dE, E>=1 MeV
%   config/reference/lhasa_neutron_spectrum_fullrange_digitized.csv  图 3(a) 109 群逐群注量反演, 到热中子端
%   config/reference/icrp116_neutron_skin_lens_coefficients.csv      ICRP 116 C.12 / C.27 / F.3
%   两图谱表是**同一个解谱结果的两种呈现**: 图 3(b) 的 30 个点逐点等于图 3(a) 里 E>=1 MeV 的 30 群
%   (能群中心逐点相对偏移 <=0.32%), 所以按能区取两张表不是混两个解。
%
% 能区分三段, groups.basis 逐行记来源方法:
%   digitized_anchored   0.99812 MeV .. 1 GeV   图 3(b) 直读形状 + 正文通量群宽口径锚定
%   digitized_inverted   表首 .. 0.99812 MeV    图 3(a) 每群注量 / 本图自己的群宽 反演
%   extrapolated_above   1 GeV .. aboveEnd      数字化段末尾幂律外推 (解谱上限 1 GeV 截断了剂量)
% A/B 的分界取图 3(a) 网格自己的群界 0.998117 MeV (也是正文"1 MeV 以上"那句话的落点):
% B 段只收 edge_hi <= 分界的行, A 段首群下界也改成同一个数 —— 不重叠也不留缝。
% 旧版把 B 段写成"通量取第一群值不变的上界估算", 既漏掉热中子段 (它占拉萨总注量的 18%),
% 又因为分界用群心而不是群界而与 A 段首群重叠计了一遍; 两条都在本次改掉。
%
% name-value:
%   .site        'Lhasa'(默认) | 'Yangbajing' | 'Lanzhou' | 'Guangzhou'
%   .organ       'skin'(默认) | 'lens_of_eye'
%   .phantom     'female'(默认) | 'male' (skin) | 'both' (lens_of_eye 只有这一档)
%   .geometry    'ISO'(默认) | 'AP' | 'PA' | 'LLAT' | 'RLAT' | 'LAT' | 'ROT'
%   .lowSegment  'inverted'(默认, 图 3(a) 反演实测) | 'upper_bound'(第一群平铺的上界估算) | 'none'
%                开关是给"分段口径变了必须改变结果"这类差分判据用的, 不是给用户选口味的
%   .belowStart  低能段最低能量 [MeV], 默认 0 (= 用到表首); 'upper_bound' 档下 0 退成 1e-2
%   .aboveEnd    外推段最高能量 [MeV], 默认 1e4 (= 系数表末点; 再高没有 ICRP 系数可乘)
%   .tailPoints  拟合尾部幂律指数所用末点数, 默认 6
%   .tailIndex   直接指定幂律指数 (默认 NaN=按 .tailPoints 拟合)。指数对窗长很敏感,
%                所以 meta.tail_window_p 把 n=4..12 的拟合值一起发货; 指定它是为了让
%                "外推段随指数动、实测两段一位都不许动"这条差分判据能跑, 不是给用户换口径
%                口径: 该指数是 **dphi/dE (每 MeV)** 的斜率, 不是每群值 (每单位 lethargy 要减 1)
%   .spectrumPath / .lowSpectrumPath / .coeffPath / .wRTablePath  换开数据表 (反例腿用)
%   .geometryScan 默认 true: 把该器官该体模在表内全部几何档各算一遍并给散布
%
% out.groups               table, 逐群: 注量率/系数/吸收剂量率/w_R/当量剂量率/basis
% out.dose_rate_pGy_h      吸收剂量率 struct: low / digitized / extrapolated / total [pGy/h]
% out.dose_rate_nGy_h      同上 [nGy/h]
% out.equiv_dose_rate_pSv_h / _nSv_h  当量剂量率 (逐能量乘 ICRP 103 中子 w_R) [pSv/h]/[nSv/h]
% out.dose_averaged_wR     H/D 比值 —— 随谱形状与几何档变, 不是常数
% out.fluence_cm2_h        三段与合计注量率 [cm^-2 h^-1] —— 直接看截断份额
% out.geometry_sensitivity 各几何档的 D/H (测量范围 = low+digitized, 另给 digitized 单段) 与散布
% out.meta                 站点/海拔/复算通量/幂律指数/分界/接缝比值/口径定义与不确定说明
%
% 聚合量的字段名按**能区角色** (low/digitized/extrapolated) 而不是按方法命名: .lowSegment 换档时
% 字段名不变, 只有 groups.basis 跟着换 —— 否则差分判据要比的两个数各自叫什么取决于入参。

p = inputParser;
p.addParameter('site', 'Lhasa', @isNameScalar);
p.addParameter('organ', 'skin', @isNameScalar);
p.addParameter('phantom', 'female', @isNameScalar);
p.addParameter('geometry', 'ISO', @isNameScalar);
p.addParameter('lowSegment', 'inverted', @isNameScalar);
p.addParameter('belowStart', 0, @(x) isnumeric(x) && isscalar(x) && x >= 0);
p.addParameter('aboveEnd', 1e4, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('tailPoints', 6, @(x) isnumeric(x) && isscalar(x) && x >= 3);
% 尾部指数默认由数字化段自己拟合; 开放成入参不是为了"换个好看的数", 而是让**外推段可以按族发货**:
% 拟合值对窗长很敏感 (meta.tail_window_p 里逐档给出), 单一指数把一条噪声很大的斜率当成了物理。
p.addParameter('tailIndex', NaN, @(x) isnumeric(x) && isscalar(x));
% 三张数据表的路径默认取仓库内的数字化表; 开放成入参是为了让"改坏表必须改结果"这条
% 反例腿能跑起来 —— 没有这个口子, 数值锁就只能靠整棵树的文件, 篡改单点无法被测出。
p.addParameter('spectrumPath', '', @(s) ischar(s) || isstring(s));
p.addParameter('lowSpectrumPath', '', @(s) ischar(s) || isstring(s));
p.addParameter('coeffPath', '', @(s) ischar(s) || isstring(s));
p.addParameter('wRTablePath', '', @(s) ischar(s) || isstring(s));
p.addParameter('geometryScan', true, @(x) islogical(x) || isscalar(x));
p.parse(varargin{:});
o = p.Results;
lowMode = lower(string(o.lowSegment));
% 档位自己报错而不是靠 inputParser 的校验函数: 后者抛出的错误 ID 是框架内定的,
% 测试钉不住具体名字, 拼错档位时判据就退化成"报了个什么错都行"。
if ~any(lowMode == ["inverted", "upper_bound", "none"])
    error("tepc:organDose:LowMode", ...
        "低能档只认 inverted / upper_bound / none, 收到 %s", string(o.lowSegment));
end
root = tepc.io.projectRoot();
spFile = char(o.spectrumPath);
if isempty(spFile)
    spFile = fullfile(root, 'config', 'reference', 'lhasa_neutron_spectrum_digitized.csv');
end
loFile = char(o.lowSpectrumPath);
if isempty(loFile)
    loFile = fullfile(root, 'config', 'reference', ...
        'lhasa_neutron_spectrum_fullrange_digitized.csv');
end
coFile = char(o.coeffPath);
if isempty(coFile)
    coFile = fullfile(root, 'config', 'reference', 'icrp116_neutron_skin_lens_coefficients.csv');
end
wrFile = char(o.wRTablePath);

[Es, phis, eLo, eHi, pubFlux, alt] = readSpectrum(spFile, string(o.site));
[Ec, Cc, nGeom] = readCoefficients(coFile, string(o.organ), string(o.phantom), string(o.geometry));

w = eHi - eLo;
if any(w <= 0) || any(diff(Es) <= 0)
    error("tepc:organDose:GroupOrder", "能群非单调或群界重叠");
end
if Es(1) <= o.belowStart || Es(end) >= o.aboveEnd
    error("tepc:organDose:SegmentOrder", ...
        "分段端点必须落在数字化段之外 (数字化 %.4g..%.4g, belowStart=%.4g aboveEnd=%.4g)", ...
        Es(1), Es(end), o.belowStart, o.aboveEnd);
end
boundary = eLo(1);              % A/B 分界: 数字化表首群的群界 (与反演表同一网格)

% --- A 段: 图 3(b) 直读 + 群宽口径锚定 ---
cA = interpCoeff(Es, Ec, Cc);
dA = phis .* cA .* w * 3600;             % [cm^-2 s^-1 MeV^-1]*[pGy cm^2]*[MeV]*[s h^-1] = pGy/h

% --- B 段: 1 MeV 以下 ---
nLow = 0;
overlapRatio = NaN; overlapE = [NaN NaN]; overlapOff = NaN;
switch lowMode
    case "inverted"
        [El, phiL, eLoL, eHiL] = readSpectrum(loFile, string(o.site));
        % 两条通道的吻合度只能在**同一能量**上比: 数字化段首群 (1.119 MeV) 在反演表里
        % 找最接近的一群 (1.117 MeV)。拿分界两侧相邻行比的话比的是谱自身的坡度 (实测 1.23),
        % 那不是通道一致性。
        [ovOff, ovJ] = min(abs(log(El ./ Es(1))));
        if El(ovJ) < 1
            overlapRatio = NaN; overlapE = [NaN NaN]; overlapOff = NaN;
        else
            overlapRatio = phiL(ovJ) / phis(1);
            overlapE = [El(ovJ) Es(1)];
            overlapOff = ovOff;
        end
        keep = eHiL <= boundary + 1e-12 & El >= o.belowStart;
        if ~any(keep)
            error("tepc:organDose:LowEmpty", ...
                "反演表在分界 %.6g MeV 以下、belowStart %.6g 以上没有行 (分界被改动?)", ...
                boundary, o.belowStart);
        end
        Eb = El(keep);  phiB = phiL(keep);
        eLoB = eLoL(keep);  eHiB = eHiL(keep);
        basisB = "digitized_inverted";
    case "upper_bound"
        % 保留旧口径作差分对照: 通量取数字化段第一群值平铺, 群界仍钉在分界上不与 A 段重叠。
        % 网格由 tileGrid 铺 (25 个群 = 26 个界点), 最后一行的 edge_hi 正好等于分界。
        lo0 = double(o.belowStart);
        if lo0 <= 0, lo0 = 1e-2; end
        [Eb, eLoB, eHiB] = tileGrid(lo0, boundary, 25);
        phiB = repmat(phis(1), size(Eb));
        basisB = "upper_bound_below";
    otherwise
        Eb = zeros(0, 1);  phiB = Eb;  eLoB = Eb;  eHiB = Eb;
        basisB = "no_low_segment";
end
wb = eHiB - eLoB;
cB = interpCoeff(Eb, Ec, Cc);
dB = phiB .* cB .* wb * 3600;
nLow = numel(Eb);

% --- C 段: 高能幂律外推 ---
% 指数的口径 (容易读错, 所以写进 meta 也写在这里): 拟合对象 phis 是表的 **dphi/dE 列 (每 MeV 微分)**,
% 所以 pTail 是 dphi/dE 的指数; 换算成"每单位 lethargy"(= E·dphi/dE) 的指数要减 1。
% 拿 pTail 去和文献里的 ~2.2-2.7 (每 MeV) 直接比是对的, 和"每群值"的指数比会差一个幂次。
np = min(double(o.tailPoints), numel(Es));
if isnan(double(o.tailIndex))
    qTail = polyfit(log(Es(end-np+1:end)), log(phis(end-np+1:end)), 1);
    pTail = -qTail(1);                     % 只取斜率: polyfit 返回 [斜率 截距] 两个数
    tailSource = "fitted";
else
    pTail = double(o.tailIndex);
    tailSource = "user";
end
% 窗长扫描: 同一张表用 n=4..12 各拟合一次, 让"指数有多不稳"随结果一起发货而不是靠人重算。
nScan = 4:min(12, numel(Es));
pScan = zeros(1, numel(nScan));
for q = 1:numel(nScan)
    kFit = double(nScan(q));
    sFit = polyfit(log(Es(end-kFit+1:end)), log(phis(end-kFit+1:end)), 1);
    pScan(q) = -sFit(1);                 % polyfit 返回 [斜率 截距] 两个数, 直接取负会撞尺寸不匹配
end
if pTail <= 1
    error("tepc:organDose:TailDivergent", ...
        "尾部幂律指数 p=%.4f <= 1: 1 GeV 以上注量积分发散, 外推不成立", pTail);
end
% 外推段从数字化段的**上群界**起铺 (不是最后一个群心): 群心到上群界那一段 (1000.01..1048.83)
% 已经被 A 段末群计过一次, 从群心起铺就把它计两遍。网格用 26 个界点 + 群心取几何中点,
% 于是每行都满足 edge_lo < E < edge_hi 且 width == edge_hi - edge_lo, 首群也不再需要特例。
[Ee, eLoE, eHiE] = tileGrid(eHi(end), o.aboveEnd, 25);
we = eHiE - eLoE;
phiC = phis(end) * (Ee ./ Es(end)).^(-pTail);
cC = interpCoeff(Ee, Ec, Cc);
dC = phiC .* cC .* we * 3600;
% 系数表末点之上还算得出**注量**但算不出剂量 (interpCoeff 越界必须报错, 不静默外推)。
% 这一段有多少注量被"表到头"截掉, 是外推段的第二层天花板, 必须随结果一起报出来而不是只写一句理由。
unscoredTop = 1e5;                       % MeV, 到 100 GeV
if unscoredTop > o.aboveEnd
    [Eu, eLoU, eHiU] = tileGrid(o.aboveEnd, unscoredTop, 25);
    fU = sum(phis(end) * (Eu ./ Es(end)).^(-pTail) .* (eHiU - eLoU)) * 3600;
else
    fU = NaN;
end

% --- 当量剂量: 逐能量乘 ICRP 103 中子 w_R(E) (式 2.8) ---
% 不乘一个常数: 本谱的剂量主要落在 100 MeV-1 GeV, 那里 w_R 只有 2.5-5,
% 而 <1 MeV 段 w_R 接近 20 —— 用常数会把两段的相对权重整个排错。
wrA = wRof(Es, wrFile); wrB = wRof(Eb, wrFile); wrC = wRof(Ee, wrFile);
hA = dA .* wrA; hB = dB .* wrB; hC = dC .* wrC;

g = [mkGroup(Es, eLo, eHi, w, phis, cA, dA, wrA, hA, "digitized_anchored", string(o.site), o); ...
     mkGroup(Eb, eLoB, eHiB, wb, phiB, cB, dB, wrB, hB, basisB, string(o.site), o); ...
     mkGroup(Ee, eLoE, eHiE, we, phiC, cC, dC, wrC, hC, "extrapolated_above", string(o.site), o)];

fA = sum(phis .* w) * 3600; fB = sum(phiB .* wb) * 3600; fC = sum(phiC .* we) * 3600;
sA = sum(dA); sB = sum(dB); sC = sum(dC);
tA = sum(hA); tB = sum(hB); tC = sum(hC);
out = struct();
out.groups = g;
out.site = string(o.site); out.organ = string(o.organ);
out.phantom = string(o.phantom); out.geometry = string(o.geometry);
out.low_segment_mode = lowMode;
out.dose_rate_pGy_h = struct('low', sB, 'digitized', sA, 'extrapolated', sC, ...
    'total', sA + sB + sC);
out.dose_rate_nGy_h = struct('low', sB/1e3, 'digitized', sA/1e3, 'extrapolated', sC/1e3, ...
    'total', (sA + sB + sC)/1e3);
out.equiv_dose_rate_pSv_h = struct('low', tB, 'digitized', tA, 'extrapolated', tC, ...
    'total', tA + tB + tC);
out.equiv_dose_rate_nSv_h = struct('low', tB/1e3, 'digitized', tA/1e3, 'extrapolated', tC/1e3, ...
    'total', (tA + tB + tC)/1e3);
% 剂量加权 w_R: H/D 的比值, 只在"这一段的谱形状"下有意义, 不是常数也不该当常数用。
out.dose_averaged_wR = struct( ...
    'low', tB / max(sB, realmin), 'digitized', tA / max(sA, realmin), ...
    'extrapolated', tC / max(sC, realmin), ...
    'total', (tA + tB + tC) / max(sA + sB + sC, realmin));
out.fluence_cm2_h = struct('low', fB, 'digitized', fA, 'extrapolated', fC, ...
    'total', fA + fB + fC);

% 分界两侧的谱台阶 (B 段末行 vs A 段首行): 谱在 1~2 MeV 是上升的, 这个比值按构造就大于 1,
% 它只用来盯"分界没被挪到谱的拐点上去", 不是两条通道的一致性证据。
% 通道一致性另给: meta.overlap_dphi_ratio (同一能量 1.117/1.119 MeV 上两表读数之比, 实测 1.04-1.05)。
if nLow >= 1
    stepRatio = phiB(end) / phis(1);
    stepE = [Eb(end) Es(1)];
else
    stepRatio = NaN; stepE = [NaN NaN];
end
if nLow > 0
    lowSpan = [Eb(1) Eb(end)];
else
    lowSpan = [NaN NaN];      % lowSegment='none' 时没有低能行, 空数组取首末会当场报错
end

out.geometry_sensitivity = struct();
if logical(o.geometryScan)
    % 把表里该器官该体模**全部可用几何档**都算一遍: "取 ISO 合理"必须是量出来的散布,
    % 不能是散文里的断言。晶状体侧 AP 比 ISO 低约 27%, 不扫就会把朝向当成无关量。
    % 扫的是测量范围 (low+digitized): 低能段现在是实测, 而热中子的几何响应最敏感
    % (穿不透头部 => 朝向差成倍), 只扫 A 段会把这部分误差整个漏掉。
    geos = string(availableGeometries(coFile, string(o.organ), string(o.phantom)));
    Dg = zeros(1, numel(geos)); Hg = Dg; Dm = Dg; Hm = Dg;
    for i = 1:numel(geos)
        [Eg, Cg] = readCoefficients(coFile, string(o.organ), string(o.phantom), geos(i));
        cg = interpCoeff(Es, Eg, Cg);
        Dm(i) = sum(phis .* cg .* w) * 3600;
        Hm(i) = sum(phis .* cg .* w .* wrA) * 3600;
        if nLow > 0
            cl = interpCoeff(Eb, Eg, Cg);
            Dg(i) = Dm(i) + sum(phiB .* cl .* wb) * 3600;
            Hg(i) = Hm(i) + sum(phiB .* cl .* wb .* wrB) * 3600;
        else
            Dg(i) = Dm(i); Hg(i) = Hm(i);
        end
    end
    j = find(geos == string(o.geometry), 1);
    out.geometry_sensitivity = struct('geometry', geos, ...
        'dose_pGy_h', Dg, 'equiv_pSv_h', Hg, ...
        'dose_digitized_pGy_h', Dm, 'equiv_digitized_pSv_h', Hm, ...
        'requested_index', j, ...
        'dose_rel_requested', Dg / Dg(j) - 1, 'equiv_rel_requested', Hg / Hg(j) - 1, ...
        'dose_spread_rel', (max(Dg) - min(Dg)) / Dg(j));
end
out.meta = struct( ...
    'altitude_m', alt, ...
    'published_flux_cm2_h', pubFlux(1), ...
    'recomputed_flux_cm2_h', fA, ...
    'flux_check_rel', fA/pubFlux(1) - 1, ...
    'digitized_range_MeV', [Es(1) Es(end)], ...
    'segment_boundary_MeV', boundary, ...
    'low_segment_mode', lowMode, ...
    'low_rows', nLow, ...
    'low_span_MeV', lowSpan, ...
    'boundary_step_ratio', stepRatio, ...
    'boundary_step_energies_MeV', stepE, ...
    'overlap_dphi_ratio', overlapRatio, ...
    'overlap_energies_MeV', overlapE, ...
    'overlap_center_offset', overlapOff, ...
    'tail_power_law_p', pTail, 'tail_fit_points', np, ...
    'tail_index_source', tailSource, ...
    'tail_index_convention', "p 是 dphi/dE (每 MeV 微分) 的指数 (拟合对象就是表的 dphi_dE 列); 换成每单位 lethargy (E·dphi/dE) 要减 1, 本值对应 0.42 量级的每十年衰减", ...
    'tail_window_n', nScan, 'tail_window_p', pScan, ...
    'tail_window_spread', max(pScan) - min(pScan), ...
    'coef_energy_max_MeV', Ec(end), ...
    'fluence_extrapolated_cm2_h', fC, ...
    'fluence_beyond_coef_max_cm2_h', fU, ...
    'high_ceiling_note', sprintf("外推段上界 aboveEnd=%.3g MeV 由系数表末点钉住; 同一幂律在 aboveEnd..%.3g MeV 还挂着 %.3f cm^-2 h^-1 注量 (= 已算外推段的 %.1f%%), 无系数不可计分", ...
        o.aboveEnd, unscoredTop, fU, 100 * fU / max(fC, realmin)), ...
    'coeff_energy_points', numel(Ec), 'coeff_geometry_variants', nGeom, ...
    'coeff_units', "pGy*cm2 (器官吸收剂量/注量, ICRP 116 表头单位)", ...
    'spectrum_provenance', "A 段=图 3(b) 矢量折线顶点直读 dphi/dE; B 段=图 3(a) 109 群每群注量/本图群宽反演; 等级 B (未与作者解谱表逐点比对)", ...
    'grid_identity', "图 3(b) 的 30 个点逐点等于图 3(a) 中 E>=1 MeV 的 30 群 (中心相对偏移 <=0.32%) => 两张表同一个解谱结果, 按能区拼接不是混两个解", ...
    'anchor_convention', "锚定口径 = Σ(dphi/dE × 群宽) (与本函数的求积同式) 在正文窗口 1 MeV-1 GeV 上等于正文通量; 旧表按梯形积分锚定,  shipped 值在本函数口径下偏高 2.8-8.3%", ...
    'low_uncertainty', "反演逐点只能信到 ±20-40%: 与图 3(b) 直读在同 30 群的逐群注量之比中位 1.04, 极值 0.65-1.41, 且比值模式四站逐位相同 => 偏差来自群宽重建而不是读数噪声; 积分量级 (对正文 ±1%) 可用, 单群形状不可当高精度用", ...
    'quantity_meaning', "D 是器官吸收剂量 (Gy); H = D 逐能量乘 ICRP 103 中子 w_R(E) 得当量剂量 (Sv)", ...
    'skin_definition', "ICRP 116 C.12/C.27 是全皮肤体素平均的 H_skin 侧系数, 不是 Hp(0.07) 的 0.07 mm 浅层量 (日文原版 ¶108, 印面 30-31)", ...
    'skin_voxel_bias', "体模皮肤体素厚 2.137 mm(男)/1.775 mm(女) 大于标称皮肤 1.6 mm(标准男)/1.3 mm(标准女); 原句判据是**CSDA 射程夹在两厚之间**的粒子, 按 NIST PSTAR 水射程换算对应次级带电粒子动能 ~10-14 MeV (10 MeV=1.23 mm, 12.5=1.832, 15=2.539 mm), 入射中子只要 >~14 MeV 就能造出该带次级 => 这条上界压在剂量主体上, 不是热中子段的边角话; 表值最多低估实际值 35% —— 单向偏下, 不是 ±35%, 且系数已是体素平均结果无法反解落在带内的次级份额, 所以只能当上界引用不可乘出修正值 (¶109, 句跨 p69-p70)", ...
    'lens_definition', "ICRP 116 F.3 是整个晶状体的平均吸收剂量; 该表只有 AP/PA/LAT/ROT/ISO 五个几何档, 没有 LLAT/RLAT; 且 F.3 是**混合出处**: AP/LAT/ROT 在 4 MeV 以下取 Manger 等(2011) 的 UF-ORNL 体模+様式化眼 (MCNPX 2.6.0, 0.001 eV-10 MeV) 结果, 其余几何与更高能量取标准体模**男+女平均** (付属書F ¶F15, 日文原版 p254; 体素尺寸男 2.137x2.137x8 mm3 女 1.775x1.775x4.84 mm3 见 ¶F4 p248)", ...
    'no_neutron_hp007', "ICRP 116 付属書 G 的局所皮肤当量剂量只给了 10 keV-10 MeV 电子与 6.5-10 MeV α 粒子, 中子没有 Hp(0.07) 表 —— 不得把 H_skin 当 Hp(0.07) 用 (¶110, 日文原版 p70)", ...
    'corrigenda_check', "ICRP 116 官方勘误 (件 ICRP_P116_en_corrigenda.pdf, 7 页, sha256=f62c12848dcc7b15acdb87b3984bc2f384465ba5573799a822be6d6ef821d475) 只更正 A.1/A.2/B.7/B.10/G.2, 本仓用的 C.12/C.27/F.3 不在其内 => 抄录件未被官方勘误波及; 但该件页码脚为 ICRP Publication 129 p133-134, 来源页序异常; 未列入勘误不等于数值已由独立来源证明", ...
    'phantom_caveat', "ICRP 116 系数由西方参考体模算出, ICRP 自己说明参考人基于高加索人种 (程梦云 2015 转述; 该件 CNKI 导出件的数字层编码损坏, 只有中文可读, 所以其中任何百分比都不引用)。人种/体模差异对**皮肤与眼晶体在可及来源中未找到定量值**: 可达的唯一中国人种体模中子剂量换算表 (Liu/Qiu, arXiv:1512.00449 = J. Nucl. Sci. Technol. 54(9):921, CRAM/CRAF 两体模, 6 个几何档, 1e-8-20 MeV) 只发表了胃与肺, 全文 skin 与 lens 各出现 0 次。另有一条**题名正对口但取不到**的中文线索: 丁逸仙, 《基于人体模型的中子通量-剂量转换系数模拟研究》硕士学位论文, 成都理工大学, 2014 (本仓无件; CNKI 返回安全验证页, 万方是 JS 空壳, 2026-10-10 再检索仍无可行全文), 所以「是否已发表皮肤/晶状体定量值」只能回答**未定**, 不能回答「不存在」。故本条按**未量化假设**处理: 不给修正系数、不乘修正数, 也不得声称两类体模在皮肤/晶状体上等价", ...
    'geometry_caveat', "AP 与 PA 的晶状体响应在 50 MeV 处交叉: 低能段 AP 远大于 PA (热中子穿不过头部), 高能段反过来 (级联次级在出射侧堆积) —— 朝向对眼睛是一等误差源; 实测 AP/ISO 吸收剂量比 数字化段 0.724, 含反演低能段 0.806。但 4 MeV 以下 AP/LAT/ROT 三列换了源模型 (様式化眼装进 UF-ORNL, 而 ISO/PA 是体模男+女平均), 所以**低能端的几何对比混着模型出处切换, 不能读成同一体模下的纯几何差**; 两模型在 ~20 MeV 以下吻合良好 (¶F14), 故此混源是温和的、不是系数表断裂", ...
    'truncation_note', "解谱上限 1 GeV 之上是幂律外推, 份额见 dose_rate_pGy_h.extrapolated; 1 MeV 以下是图 3(a) 反演的实测 (digitized_inverted), 不再是上界估算 —— 热中子段占拉萨总注量约 18 成, 旧口径整段丢掉");
end

% ---------------------------------------------------------------- 数据读取
function [E, phi, eLo, eHi, pubFlux, alt] = readSpectrum(path, wantSite)
wantSite = char(wantSite);
T = readCsvNoComment(path);
hdr = strsplit(strtrim(T{1}), ',');
body = dataRows(T, numel(hdr));
iSite = colIdx(hdr, 'site');       iAlt = colIdx(hdr, 'altitude_m');
iE = colIdx(hdr, 'energy_MeV');    iPhi = colIdx(hdr, 'dphi_dE_anchored_cm2_s_MeV');
iLo = colIdx(hdr, 'edge_lo_MeV');  iHi = colIdx(hdr, 'edge_hi_MeV');
iPub = colIdx(hdr, 'published_flux_cm2_h');
keep = strcmp(body(:, iSite), wantSite);
if ~any(keep)
    error("tepc:organDose:NoSite", "能谱表里没有站点 %s (可用: %s)", ...
        wantSite, strjoin(unique(body(:, iSite))', ', '));
end
M = cellfun(@str2double, body(keep, :), 'UniformOutput', false);
E = [M{:, iE}]'; phi = [M{:, iPhi}]';
eLo = [M{:, iLo}]'; eHi = [M{:, iHi}]';
pubFlux = [M{:, iPub}]'; alt = M{1, iAlt};
if numel(E) < 3
    error("tepc:organDose:TooFewGroups", "%s 只有 %d 群", wantSite, numel(E));
end
if any(~isfinite(E)) || any(E <= 0) || any(~isfinite(phi)) || any(phi <= 0)
    error("tepc:organDose:BadSpectrum", "%s 能谱含非正值/非数值", wantSite);
end
if any(abs(pubFlux - pubFlux(1)) > 1e-9)
    error("tepc:organDose:FluxNotScalar", "%s 的正文通量在站内不一致", wantSite);
end
% 群界一律取表自己的 edge_lo/edge_hi, 不再由群心重建: 反演表的群界是图 3(a) 顶点几何中点
% (作者的解谱网格边界), 而"群心线性外推首末界"在 1 MeV 处给的 0.9276 比真实群界 0.9981 低 7%,
% 用它当 A/B 分界会把同一群注量计两遍。
if any(diff(E) <= 0)
    error("tepc:organDose:GroupOrder", "%s 能群非单调", wantSite);
end
if any(eHi <= eLo) || any(eLo(1) >= E(1)) || any(eHi(end) <= E(end)) ...
        || any(E <= eLo | E >= eHi)
    error("tepc:organDose:EdgeOrder", "%s 群界没夹住群心或有非正群宽", wantSite);
end
% 判据按相对量: 表里群界是 6 位有效数字写出的, 热中子端 1e-8 MeV 的舍入就有 ~1e-5 的绝对偏差。
tolEdge = 1e-4 * max([abs(eHi(1:end-1)); abs(eLo(2:end))]);
if any(abs(eLo(2:end) - eHi(1:end-1)) > tolEdge)
    error("tepc:organDose:EdgeGap", "%s 相邻群界不衔接 (缺口或重叠)", wantSite);
end
end

function [Ec, Cc, nGeom] = readCoefficients(path, organ, phantom, geom)
organ = char(organ); phantom = char(phantom); geom = char(geom);
T = readCsvNoComment(path);
hdr = strsplit(strtrim(T{1}), ',');
body = dataRows(T, numel(hdr));
iO = colIdx(hdr, 'organ');   iP = colIdx(hdr, 'phantom'); iG = colIdx(hdr, 'geometry');
iE = colIdx(hdr, 'energy_MeV'); iC = colIdx(hdr, 'coeff_pGy_cm2'); iR = colIdx(hdr, 'radiation');
availG = unique(body(strcmp(body(:, iO), organ) & strcmp(body(:, iP), phantom) ...
    & strcmp(body(:, iR), 'neutron'), iG));
keep = strcmp(body(:, iO), organ) & strcmp(body(:, iP), phantom) ...
    & strcmp(body(:, iR), 'neutron') & strcmp(body(:, iG), geom);
if ~any(keep)
    error("tepc:organDose:NoCoeff", "%s/%s 中子 %s 无行; 该组合可用几何: %s", ...
        organ, phantom, geom, strjoin(availG', ', '));
end
M = cellfun(@str2double, body(keep, :), 'UniformOutput', false);
Ec = [M{:, iE}]'; Cc = [M{:, iC}]';
[Ec, ix] = sort(Ec); Cc = Cc(ix);
nGeom = numel(availG);
if any(~isfinite(Cc)) || any(Cc <= 0) || any(diff(Ec) <= 0)
    error("tepc:organDose:BadCoeff", "%s/%s/%s 系数含非正值或能量不单调", organ, phantom, geom);
end
end

function c = interpCoeff(E, Ec, Cc)
% 双对数线性内插; 越界即报错, 不就近取值 (外推段自己负责给形状)。
if isempty(E)
    c = zeros(0, 1); return
end
if E(1) < Ec(1) || E(end) > Ec(end)
    error("tepc:organDose:CoeffRange", "能量 %.4g..%.4g 超出系数表 %.4g..%.4g", ...
        E(1), E(end), Ec(1), Ec(end));
end
c = exp(interp1(log(Ec), log(Cc), log(E), 'linear'));
end

% ---------------------------------------------------------------- 小工具
function tf = isNameScalar(s)
% 名称型入参: 允许 string 标量或字符向量。isscalar 对 char 是"单个字符", 用它会把
% 'lens_of_eye' 这类合法字符向量判成非法。
tf = (isstring(s) && isscalar(s) && strlength(s) > 0) || (ischar(s) && isrow(s) && ~isempty(s));
end

function T = readCsvNoComment(path)
if ~isfile(path)
    error("tepc:organDose:MissingTable", "数据表不存在: %s", path);
end
raw = strsplit(strtrim(fileread(path)), newline);
keep = cellfun(@(s) ~(isempty(strtrim(s)) || startsWith(strtrim(s), '#')), raw, ...
    'UniformOutput', true);
raw = raw(keep);
if numel(raw) < 2
    error("tepc:organDose:EmptyTable", "%s 没有数据行", path);
end
T = raw(:);
end

function rows = dataRows(T, nCol)
parts = cellfun(@(s) strtrim(strsplit(s, ',')), T(2:end), 'UniformOutput', false);
bad = cellfun(@numel, parts) ~= nCol;
if any(bad)
    error("tepc:organDose:RaggedCsv", "%d 行列数与表头 (%d 列) 不符", sum(bad), nCol);
end
% 必须摊成二维元胞: 留着"每格再套一格"的形状时, rows(:,k) 取的是整列嵌套格,
% 列索引等于没索引, 后面的 strcmp/unique 都会因错误原因失败。
rows = vertcat(parts{:});
end

function i = colIdx(hdr, name)
i = find(strcmp(hdr, name), 1);
if isempty(i)
    error("tepc:organDose:NoColumn", "表头里没有列 %s", name);
end
end

function [E, eLo, eHi] = tileGrid(a, b, n)
% 在 [a, b] 上铺 n 个能群: n+1 个界点按几何序列取, 群心取相邻界点的几何中点。
% 于是每行都满足 edge_lo < E < edge_hi 且 width == edge_hi - edge_lo, 段与段共用端点时不会重叠 ——
% "由群心线性外推首末界"的做法在粗对数网格上会把界推到隔壁段去 (1 MeV 处推出 0.9276 而真实群界
% 是 0.9981; 1 GeV 处首群下界甚至推成负数), 同一群的注量就被计了两遍。
nodes = geomspaceSafe(a, b, n + 1);
E = sqrt(nodes(2:end) .* nodes(1:end-1));
eLo = nodes(1:end-1);  eHi = nodes(2:end);
end

function v = geomspaceSafe(a, b, n)
v = logspace(log10(a), log10(b), n)';
end

function g = mkGroup(E, eLo, eHi, w, phi, c, d, wr, h, basis, site, o)
n = numel(E);
if numel(w) ~= n || numel(phi) ~= n || numel(c) ~= n || numel(d) ~= n ...
        || numel(wr) ~= n || numel(h) ~= n || numel(eLo) ~= n || numel(eHi) ~= n
    error("tepc:organDose:GroupShape", ...
        "%s 段尺寸不一致: E=%d w=%d phi=%d c=%d d=%d wr=%d h=%d eLo=%d eHi=%d", ...
        basis, numel(E), numel(w), numel(phi), numel(c), numel(d), numel(wr), numel(h), ...
        numel(eLo), numel(eHi));
end
g = table(repmat(site, n, 1), repmat(string(o.organ), n, 1), repmat(string(o.phantom), n, 1), ...
    repmat(string(o.geometry), n, 1), E, eLo, eHi, w, phi, c, d, wr, h, repmat(basis, n, 1), ...
    'VariableNames', {'site', 'organ', 'phantom', 'geometry', 'energy_MeV', ...
    'edge_lo_MeV', 'edge_hi_MeV', 'width_MeV', 'dphi_dE_cm2_s_MeV', ...
    'coeff_pGy_cm2', 'dose_rate_pGy_h', 'wR_neutron', 'equiv_dose_rate_pSv_h', 'basis'});
end

function w = wRof(E, wrFile)
% 空串 = 用仓库里的 w_R 分段表; 给了路径就用它 (反例腿要能把这张表单独换掉)。
if isempty(E)
    w = zeros(0, 1); return
end
if isempty(wrFile)
    w = tepc.analysis.radiationWeighting(E);
else
    w = tepc.analysis.radiationWeighting(E, 'tablePath', wrFile);
end
end

function geos = availableGeometries(path, organ, phantom)
T = readCsvNoComment(path);
hdr = strsplit(strtrim(T{1}), ',');
body = dataRows(T, numel(hdr));
iO = colIdx(hdr, 'organ'); iP = colIdx(hdr, 'phantom');
iG = colIdx(hdr, 'geometry'); iR = colIdx(hdr, 'radiation');
m = strcmp(body(:, iO), char(organ)) & strcmp(body(:, iP), char(phantom)) ...
    & strcmp(body(:, iR), 'neutron');
geos = sort(unique(body(m, iG)));
geos = geos(:)';        % 统一成行: unique 对列元胞返回列, 与 zeros(1,numel) 的散布向量不同形
end
