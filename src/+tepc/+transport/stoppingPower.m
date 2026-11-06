function T = stoppingPower(cfg, particle)
%STOPPINGPOWER 生成阻止本领表（模型计算, 域受限, 全程可追溯）。
%   物理模型 (登记于 docs/reference_register.csv):
%   - 质子/重离子: Bethe 阻止本领 (ICRU 49 形式, 无壳层/密度修正) + Barkas
%     有效电荷 **绝对量** q̄ = z*(1-exp(-125*beta*z^(-2/3))) (z=1 的质子参考须按拼接腿
%     单独处理, 见下方 heavy 分支注释); 重离子按 E/A 缩放 (ASSUMED)。
%   - 电子: ICRU 37 碰撞阻止 (Møller 项 F(tau)), 忽略辐射损失 (<10 MeV <1%)。
%   - 混合气体: Bragg 加法规则 (质量分数加权), 元素 I 值 (ICRU 37):
%     H=19.2, C=78, N=82, O=95 eV; lnI_mix = sum(f_i*(Z/A)_i*lnI_i)/sum(f_i*(Z/A)_i)。
%   - 锚点: PSTAR 液态水 10 MeV 质子电子阻止 45.67 MeV cm2/g (单元测试锁定,
%     本实现给 45.95, +0.61%)。绝对标度按 REFERENCE(~5%)/低能段 ASSUMED 管理。
%   返回 T: .E [MeV 对数栅格] .S_mass [MeV cm2/g] .meta (成分/常数/域/状态)。

if nargin < 2, particle = "proton"; end
gas = cfg.gas;
comp = gas.composition_molfrac;

% --- 元素质量分数与 Z/A、I ---
el = containers.Map('KeyType','char','ValueType','any');
el('H')  = struct('Z',1,'A',1.008, 'I_eV',19.2);
el('C')  = struct('Z',6,'A',12.011,'I_eV',78.0);
el('N')  = struct('Z',7,'A',14.007,'I_eV',82.0);
el('O')  = struct('Z',8,'A',15.999,'I_eV',95.0);
el('Ar') = struct('Z',18,'A',39.948,'I_eV',305.0);

massByEl = containers.Map; totalM = 0;
ks = fieldnames(comp);
for i = 1:numel(ks)
    Mi = moleculeMass(ks{i}, el);
    totalM = totalM + comp.(ks{i}) * Mi;
    toks = regexp(ks{i}, "([A-Z][a-z]?)(\d*\.?\d*)", "tokens");
    for j = 1:numel(toks)
        e = char(toks{j}{1}); cnt = str2double(toks{j}{2}); if isnan(cnt)||cnt==0, cnt = 1; end
        if isKey(massByEl,e), massByEl(e) = massByEl(e) + comp.(ks{i})*cnt*el(e).A;
        else, massByEl(e) = comp.(ks{i})*cnt*el(e).A; end
    end
end
fe = keys(massByEl); fsum = 0; ZA = 0; lnI = 0;
emf = struct();
for i = 1:numel(fe)
    fi = massByEl(fe{i})/totalM; fsum = fsum + fi;
    zai = el(fe{i}).Z/el(fe{i}).A;
    ZA  = ZA + fi*zai;
    lnI = lnI + fi*zai*log(el(fe{i}).I_eV);
    emf.(fe{i}) = fi;
end
if abs(fsum-1) > 1e-6, error("tepc:stopping:Composition","元素质量分数和 != 1"); end
I_eV = exp(lnI/ZA);
iStatus = "Bragg加法(元素ICRU37 I值)";
% 化合物 I 覆盖: Bragg 加法与实测化合物 I 可差 1-5% (ICRU 37);
% 有文献化合物值时必须覆盖(如液态水 75 eV)。
if isfield(gas,'I_eV_override') && ~isempty(gas.I_eV_override)
    I_eV = gas.I_eV_override;
    iStatus = sprintf("化合物覆盖 I=%.1f eV (来源登记册)", I_eV);
end

% --- 能量栅格 ---
switch particle
    case "proton",   E = logspace(-2, 2, 241);    % 10 keV - 100 MeV
    case "electron", E = logspace(-2, 1, 181);    % 10 keV - 10 MeV
    otherwise
        tok = regexp(char(particle), "^heavy_([A-Z][a-z]?)$", "tokens", "once");
        if isempty(tok)
            error("tepc:stopping:BadParticle","未知粒子类型 %s", char(particle));
        end
        E = logspace(-2, 2, 241);
end

switch particle
    case "proton"
        S = betheHeavy(E, 1, 938.272, ZA, I_eV);
        S = spliceLowE(E, S, ZA, I_eV);        % 低能锚定拼接, 消除 Bethe 低能塌陷
        status = "REFERENCE(>=1MeV,实测<=2.9%)/ASSUMED(80keV-1MeV 锚定拼接,实测<=17.8%)/ASSUMED(<80keV,实测<=25.7%)";
    case "electron"
        S = betheElectron(E, ZA, I_eV);
        status = "REFERENCE(>=10keV,~3-5%)";
    otherwise
        tok = regexp(char(particle), "^heavy_([A-Z][a-z]?)$", "tokens", "once");
        Zi = el(tok{1}).Z; Ai = el(tok{1}).A;
        % 重离子 = 质子参考表按每核子能量取样 x 有效电荷标度 (ASSUMED: 无 SRIM/ICRU 重离子表)
        EperNuc = E / Ai;
        Sp = betheHeavy(EperNuc, 1, 938.272, ZA, I_eV);
        Sp = spliceLowE(EperNuc, Sp, ZA, I_eV);
        b2n = max(1 - 1./(1+EperNuc/938.272).^2, 1e-12);
        bn  = sqrt(b2n);
        % 必须是逐点除法 "./": 写成 "/" 会被 MATLAB 当作 mrdivide, 返回
        % 最小二乘解标量 (实测该标量^2 = 0.517), 使整条重离子曲线被一个
        % 与能量无关的常数缩放 —— 低能端偏 2.8 倍, 高能端偏 0.52 倍。
        % 有效电荷是绝对量 q̄ = Zi*(1-exp(-125*beta*Zi^(-2/3))), 不是"电荷份额":
        % 漏乘前置 Zi 会让离子/质子比在高 beta 端趋于 1 而不是 Zi^2 (碳低 36 倍、氧低 64 倍),
        % 且偏差与能量无关, 均值/形状类判据都发现不了, 只有拿 Zi^2 标度本身当基准才抓得住。
        % 分母在**两条腿上都取 q̄(1)=1-exp(-125*beta)**, 即始终按同族解析式之比来定义:
        %   理由 1 (退化一致性): Zi=1 时比值必须恒等于 1 —— heavy_H 与 proton 是同一粒子。
        %     取 1 的话实测 heavy_H/proton 在 10/20.8/50 keV-u = 0.19/0.32/0.52, 同粒子两张表。
        %   理由 2 (低速极限): beta->0 时比值 -> Zi^(2/3) (碳 3.30, Lindhard-Scharff 同速标度)。
        %     取 1 则 -> (125*beta)^2*Zi^(2/3) -> 0, 等于"1 keV/u 的碳比裸质子损失还低 10 倍"。
        %   理由 3 (射程有定义): 取 1 时低能端 S ∝ E^1.45, 射程积分 ∫dE/S 在 E->0 **发散**,
        %     发布射程改由表下限这个人为常数决定 (实测下限 10->1->0.1->0.01 keV 时
        %     284 keV 碳射程 = 20->63->176->478 um, 翻 24 倍); 取本式的 S ∝ E^0.45 积分收敛
        %     (同一扫描给 2.0->2.3->2.4->2.5 um)。
        % 注: 锚定实测质子腿本身不含这个压低 (50 keV 处拼接腿 664, 裸 Bethe 596, Bethe*q̄(1)^2=313),
        %     所以除掉它**不是**"把质子的压低算两次", 而是把"实测质子的绝对标定"当参考形状、
        %     把离子-质子比交给同族解析式 —— 这两件事分开承担, 各自可测 (见 z490_*.log)。
        qbarIon = Zi .* (1 - exp(-125*bn*Zi^(-2/3)));
        qbarRef = 1 - exp(-125*bn);
        zr  = qbarIon ./ qbarRef;
        % Sp 已与 E(i)/Ai 逐点对齐 => 直接点乘, 不得用总能量 E 去插值每核子表
        S   = Sp .* zr.^2;
        status = sprintf("ASSUMED(%s: 质子拼接表×有效电荷比, 无 SRIM/ICRU 重离子表)", tok{1});
end
T = struct('E', E, 'S_mass', S, 'particle', char(particle), ...
    'I_eV', I_eV, 'ZA', ZA, 'status', status, ...
    'elementMassFrac', emf, 'I_status', iStatus, ...
    'model', "Bethe(ICRU49/37)+Bragg+有效电荷+低能锚定拼接", ...
    'anchors', "S(1MeV)=Bethe连续; S(80keV)=820 MeV cm2/g(水 Bragg 峰, ICRU49/PSTAR); 形状指数 -0.441/+0.45", ...
    'densityEffect', false, 'shellCorrection', "低能段由锚定拼接隐式代替");
% 预计算 log 栅格 (stopAt 的 O(1) 插值用)
T.lgEtab = log(E(:)); T.lgStab = log(S(:)); T.d1tab = T.lgEtab(2) - T.lgEtab(1);
% --- 参考数据契约: 表必须带来源/域/单位/哈希 ---
% 措辞说明: 本表由**本实现自己算出**
% (Bethe+Bragg+有效电荷+低能锚定拼接), 不是 NIST/ICRU 表格对象的插值; 仓库内的外部依据是
% 2 个阻止本领点锚点 + 官方 NIST PSTAR 液态水 88 点表 (A 级, 10 keV-100 MeV, 逐点 S 与
% CSDA/投影射程双列)。本表已与那张表逐点对过账 (2026-10-10, z855_anchorlegs.log):
% >=1 MeV 最大 2.9%、80 keV-1 MeV 最大 17.8%、<80 keV 最大 25.7% (最差在 10 keV 端点)。
% 过账不等于同源: 整个表的状态仍是 ASSUMED/REFERENCE 混合, 且"在插值域内"绝不等于"对标过实测数据"。
T.units = "S_mass: MeV cm^2/g; E: MeV (每核子或全能量, 见 particle)";
T.domain_MeV = [E(1), E(end)];
T.assumed_below_MeV = 1.0;      % <1 MeV 落在锚定拼接带 (实测 <=17.8%, <80keV <=25.7%)
T.derivation = "本实现自算 Bethe(ICRU49/37)+Bragg+有效电荷+低能锚定拼接 (非表格插值)";
T.ref_data_source = "config/reference/stopping_anchors.csv (2 点) + pstar_water_proton_range.csv (88 点, A 级 NIST PSTAR 原表)";
T.ref_data_url = "https://physics.nist.gov/PhysRefData/Star/Text/PSTAR.html";
T.sha256 = tepc.io.hashText(tepc.io.canonicalJson(struct('E', E, 'S', S)));
end

function S = spliceLowE(E, S_bethe, ~, ~)
%SPLICELOWE 低能锚定拼接 (质子):
%   E >= 1 MeV             : Bethe 原值(对官方 PSTAR 88 点逐点实测最大 2.9%, 中位 0.6%)。
%   80 keV <= E < 1 MeV    : S = S1M * (E/1MeV)^(-0.441), 锚定 S(80keV)=峰。
%   E < 80 keV             : S = S_peak * (E/80keV)^(+0.45) (Varelas-Biersack 低能斜率)。
%   峰值 = 820 MeV cm2/g(水, ICRU49/PSTAR Bragg 峰) 按材料 Bethe@1MeV 与水的比值迁移。
%   对官方 PSTAR 88 点表的实测残差形状 (z855_anchorlegs.log, 2026-10-10):
%     <80 keV 全为负, 最差 -25.7% 在 10 keV 端点; 80keV-1MeV 全为负为主 (3 点为正),
%     最差 -17.8% 在 0.225 MeV —— 两个锚点之间, 是对数直线内插的中段曲率, 不是标定倍数错;
%     >=1 MeV 全为正, 最大 +2.90% 在 1.25 MeV (拼接交界之上), 带内最小 +0.004%。
%   注意: 这条腿是**实测形状**, 不含 betheHeavy(z=1) 里那个 (1-exp(-125*beta))^2 压低
%   (50 keV: 本腿 664 / 裸 Bethe 596 / Bethe*压低 313)。重离子分支仍除以该压低因子,
%   理由与量化证据见上方 heavy 分支的注释 (退化一致性 + 低速 Z^(2/3) 极限 + 射程积分收敛)。
S1M      = exp(interp1(log(E), log(S_bethe), log(1.0), 'linear'));
S1M_water = betheHeavy(1.0, 1, 938.272, 0.5551, 75.0);   % 液态水锚(I=75 eV, ICRU37)
Speak    = 820 * (S1M/S1M_water);                        % 峰值按材料迁移(ASSUMED)
idxMid = E >= 0.08 & E < 1.0;
idxLo  = E < 0.08;
S = S_bethe;
S(idxMid) = S1M .* (E(idxMid)/1.0).^(-0.441);
S(idxLo)  = Speak .* (E(idxLo)/0.08).^(0.45);
S = max(S, 1e-6);
end

function S = betheHeavy(E, z, M_MeV, ZA, I_eV)
% BETHEHEAVY 重带电粒子 Bethe (ICRU 49 形式, z_eff 修正)。E [MeV], S [MeV cm2/g]
K  = 0.307075;                    % MeV cm2/g, 4*pi*Na*re^2*me*c^2
me = 0.510998950;                 % MeV
g  = 1 + E/M_MeV;
b2 = 1 - 1./g.^2;
b2 = max(b2, 1e-12);
Tmax = 2*me*b2.*g.^2 ./ (1 + 2*g*me/M_MeV + (me/M_MeV)^2);
beta = sqrt(b2);
zeff2 = (1 - exp(-125*beta*z^(-2/3))).^2;
S = K * ZA * zeff2 ./ b2 .* ( 0.5*log(2*me*b2.*g.^2 .* Tmax ./ (I_eV*1e-6)^2) - b2 );
S = max(S, 1e-6);
end

function S = betheElectron(E, ZA, I_eV)
% BETHEELECTRON 电子碰撞阻止 (ICRU 37 形式, tau=E/mec2, 忽略密度效应)。
K  = 0.307075; me = 0.510998950;
tau = E/me;
g = 1 + tau; b2 = 1 - 1./g.^2;
F = 1 - b2 + (tau.^2/8 - (2*tau+1)*log(2)) ./ (tau+1).^2;
S = (K/2) * ZA ./ b2 .* ( log( me^2*tau.^2.*(tau+2)/2 ./ (I_eV*1e-6).^2 ) + F );
S = max(S, 1e-6);
end

function M = moleculeMass(name, el)
toks = regexp(name, "([A-Z][a-z]?)(\d*\.?\d*)", "tokens");
M = 0;
for i = 1:numel(toks)
    e = char(toks{i}{1}); cnt = str2double(toks{i}{2}); if isnan(cnt)||cnt==0, cnt=1; end
    M = M + cnt*el(e).A;
end
end
