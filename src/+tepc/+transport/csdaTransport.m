function out = csdaTransport(T, P0, dirv, E0_MeV, geom, rho_g, rs, opts)
%CSDATRANSPORT 带电粒子直线 CSDA 输运穿过球形气腔（解析基线）。
%   步进: 自适应 ds (单步平均 dE <= 2%E0 且 ds <= 剩余出腔距离), 中点法积分 S(E)。
%   每步 Bohr 涨落(腔内步): dE = <dE> + N(0, Omega), 双侧、截断于 [0, E];
%     不得用 abs(randn) —— 那会把涨落变成单边正偏 (实测 +8~9%)。
%   截断 [0, E] 本身也是整流器, 其偏置已实测且很小: 同一条 [0;0;0]->[1;0;0] 弦上比
%     有涨落/无涨落的 EdepGas 均值, 每点 3000 例 (临时/验证脚本/z76_log.txt):
%       E0=0.08 MeV  偏差 -1.78e-3 (MC 标准误 1.22e-3, |bias|/se=1.5)
%       E0=0.30 MeV  偏差 -2.95e-3 (MC 标准误 2.15e-3, |bias|/se=1.4)
%       E0=1.00 MeV  偏差 -1.2e-14 (质子贯穿气腔, 截断几乎不触发)
%     不超过 0.3% 且与零统计不可区分, 符号还是**负的** (上截断 dE<=E 同样在削高值)。
%     据此把 test_csda_straggling_is_two_sided 的均值地板从 5% 收到 2%: 仍远大于实测,
%     但不再把"截断偏置到底多大"糊在一个没根据的宽容差里。
%   出腔后剩余能量: 厚壁全阻止, 超厚程部分记 ESCAPE。
%   账本: E0 = EdepGas + EdepWall + Eescape (停在腔内时后两项=0)。
%   E < 表下限时残能就地沉积并打 OUT_OF_RANGE 标志。
%   opts.straggle(true)/z(1)/wallThickness_m。壁密度由 tepc.transport.wallDensity 取
%     (常数注册表是唯一来源, 本文件不留数值镜像); opts.rho_wall_g_cm3 是显式覆盖。
%   出参带 rhoWall_g_cm3 与 rhoWallSource(kind/const_id/path/value_g_cm3/units/reader):
%     本事件用的壁密度是多少、从哪个来源取, 随结果一起交出去。

F = tepc.domain.Flags();
if nargin < 8, opts = struct(); end
if ~isfield(opts,'straggle'), opts.straggle = true; end
if ~isfield(opts,'z'),        opts.z = 1; end
[wallRhoGcm3, wallRhoSrc] = tepc.transport.wallDensity(opts);
opts.rho_wall_g_cm3 = wallRhoGcm3;             % 覆盖项与本事件实得值同源
if ~isfield(opts,'wallThickness_m'), opts.wallThickness_m = geom.wallThickness_m; end

if string(geom.type) ~= "sphere"
    % 下面的输运把 geom.R_m 当球半径用: 非球腔下 |P0|>R 且外向时 dExit<0 会让步长塌到
    % hmin 并被判成"已在边界", 整条能量记成壁/逸出、gasPath≈0 —— 静默出错数而不是报错。
    % 这条守卫原先只在 sampleInVolume 里 (中子腿), 光子腿从来没有; 放这里两腿同盖,
    % 也让 config/validate.m 与 GUI 那句"运行时会以 transport:Geom 拒绝"逐字为真。
    error("tepc:transport:Geom", ...
        "解析输运链 (CSDA→壁) 只对 sphere 闭合, 实得 geometry.type=%s", char(geom.type));
end
R = geom.R_m;
P0 = P0(:); dirv = dirv(:)/norm(dirv);
E = E0_MeV;
EdepGas = 0.0; EdepWall = 0.0; Eescape = 0.0; pathInGas = 0.0;
flags = uint32(0);
hmin = 1e-9;                                  % m
broke = false;
nSteps = 0;
% Bohr 涨落系数的唯一来源是常数注册表 transport.bohr.coeffMeV2cm2PerG。
% 在循环外读一次: 注册表查询不能进每步热路径 (本循环上限 2e5 步), 而字面量留在代码里
% 又会造成"注册表改了、代码没改"的双真相 —— 读一次同时解掉这两头。
bCoeff = double(tepc.config.constants('transport.bohr.coeffMeV2cm2PerG'));

% ---- 介质分段: 起点允许落在壁壳层内 (R < |P0| <= R+t), 此时壁段按**壁**的密度计费 ----
% 为什么必须分段而不是沿用整段气体口径: 实测同一段 1.5 mm 壁按气体口径掉 3.208e-06 MeV,
% 按壁口径掉 3.451e-01 MeV, 差 1.076e5 倍。而射线背离气腔时 dExit<0 会让步长塌到 hmin
% 并被 atBoundary 判成"已在边界", 整条能量记给壁且 gasPath≈0 —— 两种都是静默错号。
% 起点在装置外 (|P0| > R+t) 仍显式拒绝: 那种输入没有物理口径。
% 起点在腔内时本块整体跳过, 所以发货路径逐位不变 (负控见 test_transport)。
r0 = norm(P0);
Rout = R + opts.wallThickness_m;
if r0 > Rout * (1 + 1e-12)
    error("tepc:csda:OutsideGas", ...
        "带电粒子输运的起点必须在装置内: |P0|=%.6e m > R+t=%.6e m", r0, Rout);
end
if r0 > R * (1 + 1e-12)
    proj = -dot(P0, dirv);
    half2 = proj*proj - (dot(P0, P0) - R^2);              % 与气腔球面的判别式
    dEnter = Inf;                                          % Inf = 前方不入腔
    if half2 > 0 && proj > 0
        dEnter = proj - sqrt(half2);                       % 第一个正根 = 入腔距离
    end
    dOuter = proj + sqrt(max(proj*proj - (dot(P0, P0) - Rout^2), 0));   % 前方外边界
    Lwall = min(dEnter, max(dOuter, 0));
    if Lwall > 0
        [dEw, E, sWall] = mediumStep(T, E, Lwall, wallRhoGcm3);
        EdepWall = EdepWall + dEw;
        P0 = P0 + dirv*sWall;
    end
    if E <= 0
        flags = bitor(flags, F.WALL_LOSS);                 % 未到达气腔就被壁吸收
        broke = true;
    elseif norm(P0) >= Rout * (1 - 1e-9)
        Eescape = Eescape + E*1e3;                         % 从外壁离开装置, 未进腔
        flags = bitor(flags, F.ESCAPE);
        E = 0; broke = true;
    end
end

for it = 1:200000
    nSteps = it;
    if E <= T.E(1)
        EdepGas = EdepGas + E*1e3;            % 残能就地沉积 [keV]
        if E > 0, flags = bitor(flags, F.OUT_OF_RANGE); end
        E = 0; broke = true; break;
    end
    S = tepc.transport.stopAt(T, E);                        % 域内(下限已截), 域外会抛错
    let_MeV_per_m = S * (rho_g/1000) * 100;   % MeV cm2/g * g/cm3 = MeV/cm -> MeV/m
    b = 2*dot(P0, dirv); c = dot(P0,P0) - R^2;
    disc = b^2 - 4*c;
    if disc <= 0
        % 入口守卫已保证 |P0| <= R, 此时 c <= 0 而 disc = b^2 - 4c >= 0; 落到这里只剩
        % b = 0 且 c = 0 一种: 起点恰在腔壁上且方向与壁相切, 出腔距离为零。
        % 这不是"起点在外面"(那是入口守卫的活), 而是零厚度的退化弦, 单独说清免得误导排查。
        error("tepc:csda:OutsideGas", ...
            "起点在腔壁上且方向与壁相切 (出腔距离为零): 该几何下没有可输运的腔内路径");
    end
    dExit = (-b + sqrt(disc))/2;              % 沿 dirv 出腔距离 [m]
    hE = 0.02*E / max(let_MeV_per_m, 1e-15);
    h = min([hE, dExit, 0.05]);
    if h < hmin, h = hmin; end
    atBoundary = (h >= dExit - 1e-15);
    if atBoundary, h = dExit; end
    Em = max(E - 0.5*h*let_MeV_per_m, T.E(1));
    Sm = tepc.transport.stopAt(T, Em);
    dE_mean = Sm * (rho_g/1000) * 100 * h;    % MeV
    dE = dE_mean;
    if opts.straggle && ~atBoundary
        % Bohr 涨落: Omega^2 = bCoeff*(Z/A)*rho[g/cm3]*x[cm]*z^2 [MeV^2], bCoeff 取注册表。
        % 双侧 (围绕平均能损的高斯) 是物理要求: 单边 abs() 会把平均沉积推高 +8~9%
        % (判据见 test_transport.m::test_csda_straggling_is_two_sided)。
        % 到达边界那一步 (~atBoundary 为假) **刻意不加涨落**: 该步的 h 由"到腔壁的距离"定死,
        % 给它加涨落等于允许一次越过边界, 气/壁/逃逸三项的分配就与几何解耦了。代价必须说清:
        % 出口步的能量沉积因此是确定值, 气/壁分配在这一层里没有涨落 (不是漏接线)。
        Om = sqrt(bCoeff * T.ZA * (rho_g/1000) * (h*100) * opts.z^2);
        dE = dE_mean + randn(rs)*Om;          % 双侧涨落
        dE = min(max(dE, 0), E);              % 物理约束: 0 <= dE <= E
    end
    EdepGas = EdepGas + dE*1e3;
    pathInGas = pathInGas + h;
    if atBoundary
        Eres = max(E - dE_mean, 0);
        outW = wallEscape(T, Eres, opts);
        % 必须是累加而不是赋值: 起点在壁内时这里已经背着一段近壁沉积, 赋值会把它抹掉
        % (实测账本从 500 keV 掉到 70.8 keV)。发货路径下这两项此前恒为 0, 所以逐位不变。
        EdepWall = EdepWall + (Eres - outW)*1e3;      % MeV -> keV
        Eescape  = Eescape + outW*1e3;
        if Eres > 0,   flags = bitor(flags, F.WALL_LOSS); end
        if Eescape > 0, flags = bitor(flags, F.ESCAPE); end
        E = 0; broke = true; break;
    end
    E = E - dE;
    P0 = P0 + dirv*h;
    if E <= 0, E = 0; broke = true; break; end
end
if ~broke
    error("tepc:csda:NoConvergence","CSDA 步进未收敛(%d 步)", it);
end

out = struct('EdepGas_keV', EdepGas, 'EdepWall_keV', EdepWall, ...
    'Eescape_keV', Eescape, 'gasPath_m', pathInGas, 'flags', flags, ...
    'nSteps', nSteps);
out.rhoWall_g_cm3 = wallRhoGcm3;                % 本事件壁能损/射程实际消费的密度
out.rhoWallSource = wallRhoSrc;                 % 它的出处: 报告读者据此核对, 不必翻代码
end

function v = wallEscape(T, Eres_MeV, opts)
% WALLESCAPE 厚壁近似: 剩余能量按壁内射程比例沉积/溢出(诊断量)。
if Eres_MeV <= 0, v = 0; return; end
E = Eres_MeV; Rcm = 0; h = Eres_MeV/10;
for k = 1:10
    Em = max(E - h/2, T.E(1));
    S = tepc.transport.stopAt(T, Em);
    Rcm = Rcm + h/(S*opts.rho_wall_g_cm3);    % cm
    E = E - h;
end
Rm = Rcm/100;                                 % m
if Rm <= opts.wallThickness_m
    v = 0;
else
    v = Eres_MeV * (1 - opts.wallThickness_m/Rm);
end
end

function [Edep_keV, Erem, dist_m] = mediumStep(T, E0_MeV, L_m, rhoGcm3)
% MEDIUMSTEP 在指定介质里沿直线最多走 L_m [m], 按平均能损记账, 返回 [沉积 keV, 剩余 MeV,
%   实际走过的 m]。10 个子步、每子步取"子步起点能量与预测终点能量的中点"处的阻止本领,
%   与 wallEscape 的中点积分同口径。
% 壁段**不加 Bohr 涨落**是有意选择: 涨落系数按气体体积效应给, 稠密介质里逐级能量损失
%   由平均阻止本领主导; 要加也得先有壁的 Omega^2 口径, 不在这里顺手借气体的数。
Edep_keV = 0; Erem = E0_MeV; dist_m = 0;
if L_m <= 0 || Erem <= 0, return; end
dh = L_m/10;                                   % [m]
for k = 1:10
    if Erem <= T.E(1)
        Edep_keV = Edep_keV + Erem*1e3;        % 表下限以下: 残能就地沉积
        Erem = 0;
        return
    end
    dEtop = dh*100 * tepc.transport.stopAt(T, Erem) * rhoGcm3;      % MeV
    Emid = max(Erem - 0.5*dEtop, T.E(1));
    dE = dh*100 * tepc.transport.stopAt(T, Emid) * rhoGcm3;         % MeV
    if dE >= Erem
        Edep_keV = Edep_keV + Erem*1e3;
        dist_m = dist_m + dh*(Erem/dE);
        Erem = 0;
        return
    end
    Erem = Erem - dE;
    Edep_keV = Edep_keV + dE*1e3;
    dist_m = dist_m + dh;
end
end
