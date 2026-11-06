function [E, state] = AnalyticAdapter(cfg, geom, tables, rs, N, firstID, state, varargin)
%ANALYTICADAPTER 解析/经验事件生成器（纯 MATLAB 主线）。
%   每个 history = 一次带电粒子能量沉积事件(条件于相互作用), 权重=1。
%   支持源: mono_neutron(弹性 H/C/O 反冲), mono_gamma(康普顿/光电分支),
%           mixed(按 classPrior 混合)。
%   分层模型声明:
%     - 反冲核运动学: 两体弹性精确; CM 各向同性 H 精确 / C,O ASSUMED。
%     - CSDA 直线输运 + Bohr 涨落; 壁效应打 WALL_LOSS/ESCAPE 标志(账本闭合)。
%     - gamma: 质量衰减系数与光电分支为 ASSUMED 演示值(仅影响零沉积份额)。
%   本适配器不宣称中子/伽马输运保真度, 结果只构成解析/经验基线。
%
%   账本可审计性: E0_MeV = 初级粒子能量; Esecondary_keV = 送入 CSDA 输运的
%   次级带电粒子初始动能。逐事件能量守恒断言为
%     Esecondary_keV == EdepGas_keV + EdepWall_keV + Eescape_keV   (由门禁/单测核对)。
%   单位必须是 keV 对 keV: 早先这里写的是 "Esecondary*1e3 == …", 那个 1e3 是错的 ——
%   列名已经带 _keV, 再乘 1000 就把等式两边错开三个量级。实测 (同 seed 12345,
%   四腿 H/C/O/MIX 各 4000 事件, 共 16000 事件): 按 keV 口径的最大绝对残差
%   2.3e-13 keV, 按 *1e3 口径是 1.0e6 —— 差别不是统计的, 是单位。
%   tables: struct('proton',Tp,'electron',Te,'heavy_C',Tc,'heavy_O',To)
%   state:  struct('tNext', 下一事件到达时刻) — 分块续跑用。
%   xopts (可选): 逐事件输运的覆盖项, 只接受 'rho_wall_g_cm3' (数值) 与 'straggle'
%     (逻辑标量, 逐事件 Bohr 涨落开关, 给实测探针做同 seed 配对腿用) 两项 (原样转给
%     tepc.transport.csdaTransport; 其余键名直接报错, 因为拼错的覆盖项会被下游
%     isfield 判为"未给"而静默失效 —— 一个本该改变结果的不确定度分量就此归零)。
%     不给时壁密度按 csdaTransport 的默认口径取 (常数注册表)。壁厚不在此列:
%     它的唯一来源是 geom.wallThickness_m, 再开一条覆盖路会给出两个真相。
%   返回 E: EventBatch; state 更新后的 tNext。

F = tepc.domain.Flags();
xopts = checkXopts(varargin{:});
ev = tepc.domain.EventBatch.preallocate(N);
srcType = lower(string(cfg.source.type));
[rho_g, ~] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, cfg.gas.temperature_K, ...
    cfg.gas.composition_molfrac, cfg.gas.compressibility_Z);
seed = seedof(cfg);
rate = cfg.source.rate_cps;
if ~(rate > 0), error("tepc:transport:BadRate","source.rate_cps 必须为正"); end

% 混合场的类别先验
% 类别标签**不能**用共享流一次性抽 N 个 —— 那样"哪些事件是中子"
% 取决于分块边界, 与本函数下面宣称、且 analyze/续跑都依赖的"抽样只依赖
% (seed,eventID)"直接矛盾。mixed 时改为在每事件子流里抽 1 个 (见主循环)。
usePrior = false;
if srcType == "mixed"
    if ~isfield(cfg.source,'classPrior'), error("tepc:transport:Prior","mixed 源需要 classPrior"); end
    pr = cfg.source.classPrior;
    cls = ones(N,1);                       % 占位, 主循环内按事件覆写
    usePrior = true;
else
    switch srcType
        case "mono_neutron", cls = ones(N,1);
        case "mono_gamma",   cls = 2*ones(N,1);
        otherwise
            error("tepc:transport:BadSource","未知源类型 %s", char(srcType));
    end
end

isPoisson = strcmpi(cfg.source.arrivalModel, "poisson");
if isfield(state,'tNext'), tCur = state.tNext; else, tCur = 0; end

for k = 1:N
    eid = firstID + k - 1;
    % 每-事件 Threefry 子流: 抽样只依赖 (seed, eventID),
    % 与分块大小/续跑/并行无关 —— 可复现性按事件锚定。
    % seed 取自 cfg.provenance.seed (execute 在 'Seed' 覆盖时必须同步写回 cfg,
    % 否则所记 seed 与发布谱无关)。
    rsE = RandStream('Threefry', 'Seed', seed);
    rsE.Substream = eid;
    if usePrior
        % 类别标签也在**本事件子流**上抽: 分块大小不再影响谁是中子/谁是光子
        cls(k) = sampleClass([pr.neutron, pr.gamma], 1, rsE);
    end
    switch cls(k)
        case 1, thisType = "mono_neutron";
        case 2, thisType = "mono_gamma";
    end
    flags = uint32(0);
    EdepGas = 0; EdepWall = 0; gasPath = 0; Eesc = 0;
    Esec_keV = 0;
    % 每事件先复位道标签: ch 只在 mono_neutron 分支里赋值, 不复位会让光子事件
    % 沿用上一条中子事件的陈旧标签 (MATLAB 循环变量的这一族缺陷)。
    ch = "";
    switch thisType
        case "mono_neutron"
            E_n = cfg.source.energy_MeV;
            % internal_isotropic: 作用点体积均匀+方向各向同性, 弦过该点。用 IUR 弦再沿弦均匀
            % 会把边缘推向腔壁 (P(r>0.9R)=0.379 vs 0.271, 2e6 样本复算) —— 均匀注量下应体积均匀。
            [~, Pin, Pout] = tepc.geometry.sampleChord(geom, 1, "internal_isotropic", rsE);
            dirn = (Pout(:,1) - Pin(:,1))/norm(Pout(:,1) - Pin(:,1));  % 入射方向
            ch = pickChannel(cfg, rsE);         % 通道加权(截面 ASSUMED)
            nc = tepc.transport.nuclearChannel(E_n, ch, dirn, rsE);
            P0 = tepc.transport.birthPoint(geom, cfg, Pin, Pout, rsE);   % 诞生点: 默认落在弦上
            switch ch
                case "elastic_H",  T = tables.proton;   z = 1;
                case "elastic_C",  T = tables.heavy_C;  z = 6;
                case "elastic_O",  T = tables.heavy_O;  z = 8;
            end
            led = tepc.transport.csdaTransport(T, P0, nc.recoil.dir, ...
                nc.recoil.E_MeV, geom, rho_g, rsE, withZ(xopts, z));
            EdepGas = led.EdepGas_keV; EdepWall = led.EdepWall_keV;
            Eesc    = led.Eescape_keV;
            gasPath = led.gasPath_m*1e6;        % um
            flags = bitor(flags, led.flags);
            Esec_keV = nc.recoil.E_MeV*1e3;
            E0 = E_n;
        case "mono_gamma"
            E_g = cfg.source.energy_MeV;
            % 光子穿过气腔: 弦抽样 + 作用点按**整条线路的累积光学厚度**抽样。
            % 线路分三段: 入射壁 -> 气腔 -> 出射壁。原先只看气腔弦 (pInt=1-exp(-mu*Lc1)),
            % 于是"光子在壁里作用"这一整类事件不存在 —— 而 1000 Pa 下壁比气容易作用约 9.4e3 倍
            % (同一张 μ/ρ 下壁比气容易作用约 9.4e3 倍), 丢掉它就是丢掉伽马道的主响应项。
            [~, Pin, Pout] = tepc.geometry.sampleChord(geom, 1, "isotropic_external", rsE);
            dirg = (Pout(:,1) - Pin(:,1))/norm(Pout(:,1) - Pin(:,1));
            Lc1 = norm(Pout(:,1) - Pin(:,1));
            mu_rho = valof(cfg.source.gamma_massatt_cm2_g);      % ASSUMED (XCOM 量级)
            mu = mu_rho * rho_g/1000 * 100;               % 1/m
            if ~(mu > 0)
                error("tepc:transport:BadMu","gamma_massatt 必须为正标量");
            end
            [rhoWallGcm3, ~] = tepc.transport.wallDensity(xopts);
            muW = mu_rho * rhoWallGcm3 * 100;  % 1/m, 与输运侧同一张 μ/ρ、同一个密度取数点
            Rout_g = geom.R_m + geom.wallThickness_m;
            Lw1 = backDistToSphere(Pin(:, 1), dirg, Rout_g);
            Lw2 = fwdDistToSphere(Pout(:, 1), dirg, Rout_g);
            tauTot = muW*Lw1 + mu*Lc1 + muW*Lw2;
            E0 = E_g;
            u1 = rand(rsE);
            if u1 >= 1 - exp(-tauTot)
                flags = bitor(flags, F.ZERO_DEP);         % 整条线路无相互作用
            else
                tauAct = -log(max(1 - u1, realmin));      % 作用点处的累积光学厚度
                bornInWall = false;
                if tauAct <= muW*Lw1
                    bornInWall = true;
                    Pint = Pin(:, 1) - dirg*(Lw1 - tauAct/muW);
                elseif tauAct <= muW*Lw1 + mu*Lc1
                    bornInWall = false;
                    Pint = Pin(:, 1) + dirg*((tauAct - muW*Lw1)/mu);
                else
                    bornInWall = true;
                    Pint = Pout(:, 1) + dirg*((tauAct - muW*Lw1 - mu*Lc1)/muW);
                end
                if rand(rsE) < valof(cfg.source.gamma_photoelectric_frac)  % ASSUMED
                    if bornInWall
                        % 壁内光电: 光电子向前出射 (662 keV 下强前向, 这里按入射方向取, 是
                        % ASSUMED 的各向同性近似之外的一个明确假设), 必须输运 —— 否则壁腿为零。
                        led = tepc.transport.csdaTransport(tables.electron, Pint, dirg, ...
                            E_g, geom, rho_g, rsE, withZ(xopts, 1));
                        EdepGas = led.EdepGas_keV; EdepWall = led.EdepWall_keV;
                        Eesc    = led.Eescape_keV;
                        gasPath = led.gasPath_m*1e6;
                        flags = bitor(flags, led.flags);
                        Esec_keV = E_g*1e3;
                    else
                        % 气腔内光电仍按点全沉积: 这是另一条已登记的缺陷 (逐过程数据缺位),
                        % 不在本次改动里顺手改掉, 免得把两件事的效应混在一个数上。
                        EdepGas = E_g*1e3;                % 全沉积(荧光忽略)
                        gasPath = ((tauAct - muW*Lw1)/mu)*1e6;
                        Esec_keV = E_g*1e3;
                    end
                    if bornInWall, flags = bitor(flags, F.SECONDARY_FROM_WALL); end
                else
                    [Ee, Eg2, cosT] = tepc.transport.comptonKN(E_g, 1, rsE);
                    % 反冲电子方向由动量守恒 p_e = p_in - p_out 给出 (非各向同性)
                    sinT = sqrt(max(1 - cosT^2, 0));
                    ph = 2*pi*rand(rsE);
                    uZ = [0; 0; 1];
                    [e1, e2] = perpBasis(dirg);
                    pin_v  = E_g*dirg;
                    pdir_q = cosT*uZ + sinT*(cos(ph)*e1 + sin(ph)*e2);
                    pout_v = Eg2*alignIn(pdir_q, dirg, e1, e2, uZ);
                    pe = pin_v - pout_v;
                    if norm(pe) <= 0
                        flags = bitor(flags, F.ZERO_DEP);
                    else
                        led = tepc.transport.csdaTransport(tables.electron, Pint, ...
                            pe/norm(pe), Ee, geom, rho_g, rsE, withZ(xopts, 1));
                        EdepGas = led.EdepGas_keV; EdepWall = led.EdepWall_keV;
                        Eesc    = led.Eescape_keV;
                        gasPath = led.gasPath_m*1e6;
                        flags = bitor(flags, led.flags);
                        Esec_keV = Ee*1e3;
                    end
                    if bornInWall, flags = bitor(flags, F.SECONDARY_FROM_WALL); end
                end
            end
    end
    if EdepGas <= 0 && EdepWall <= 0 && Eesc <= 0
        flags = bitor(flags, F.ZERO_DEP);
    end
    if isPoisson
        t0k = tCur; tCur = tCur + (-log(max(rand(rsE), realmin)))/rate;
    else
        t0k = (eid - 1)/rate;                    % 全局事件序号: 跨块不重复时间戳
    end
    ev.ev.eventID(k)        = eid;
    ev.ev.primaryClass(k)   = cls(k);
    ev.ev.E0_MeV(k)         = E0;
    ev.ev.Esecondary_keV(k) = Esec_keV;
    ev.ev.EdepGas_keV(k)    = EdepGas;
    ev.ev.EdepWall_keV(k)   = EdepWall;
    ev.ev.Eescape_keV(k)    = Eesc;
    ev.ev.gasPath_um(k)     = gasPath;
    ev.ev.t0_s(k)           = t0k;
    ev.ev.weight(k)         = 1;
    ev.ev.flags(k)          = flags;
    ev.ev.model_id(k)       = uint16(1);        % 1 = AnalyticAdapter
    % 核种道标签落列 (1=H 2=C 3=O, 0=本事件无核反应道)。之所以要显式存而不是事后
    % 从 Esecondary_keV 反推: 反冲能支持集判据只有单向纯度 —— 高于碳上限必为氢,
    % 低于它则三种混在一起, 碳/氧在混合谱里不可分 (实测见 D-07 的证据产物)。
    switch ch
        case "elastic_H", ev.ev.channelId(k) = uint8(1);
        case "elastic_C", ev.ev.channelId(k) = uint8(2);
        case "elastic_O", ev.ev.channelId(k) = uint8(3);
        otherwise,        ev.ev.channelId(k) = uint8(0);
    end
end
state = struct('tNext', tCur);
E = ev;
end

function o = withZ(base, z)
% 逐事件输运选项: 在调用方覆盖项上贴本支线的电荷数 z。
% straggle 不在这里设 —— csdaTransport 的默认就是 true, 与本轮改动前逐位一致。
o = base;
o.z = z;
end

function x = checkXopts(varargin)
% CHECKXOPTS 只放行白名单里的覆盖项, 其余键名一律拒绝。
%   拼错的覆盖项 (rho_wall_g_cm33 之类) 会被下游 isfield 判为"未给", 于是一个本该
%   改变结果的不确定度分量静默归零 —— 这类惰性在 adcCal_rel/stopScale 上已经付出过
%   代价, 因此在入口处按白名单硬性拦截, 而不是靠事后看数值没变来发现。
%   两项口径不同, 取值校验也得分开:
%     rho_wall_g_cm3  正有限数值标量 (壁密度覆盖, UQ 侧在用)
%     straggle        **逻辑标量** (逐事件 Bohr 涨落开关, 给实测探针做配对腿用)
%   straggle 不能套用"正有限数值"那条判据: 那条判据会把 false 拒掉而把 true 当 1 收下,
%   于是这个开关只剩"能开不能关" —— 一个半死的旋钮比没有旋钮更糟, 因为它看着像有。
%   配置里没有 straggle 这一项, 它的唯一来源就是这个实参 (缺省仍由 csdaTransport 兜 true),
%   所以不存在"配置与实参两个真相"; 但它也不许从配置文件读进来 —— 那是新增一条保真轴,
%   要按 docs/performance_tiers.md 的裁决流程走, 不是在这儿顺手接一根线。
allow = ["rho_wall_g_cm3", "straggle"];
if numel(varargin) > 1
    error("tepc:transport:TooManyArgs", ...
        "AnalyticAdapter 只接受一个 xopts 结构体, 实得 %d 个额外参数", numel(varargin));
end
x = struct();
if isempty(varargin), return; end
o = varargin{1};
if isempty(o), return; end
if ~isstruct(o) || ~isscalar(o)
    error("tepc:transport:BadXopts", ...
        "xopts 必须是标量 struct, 实得 %s %s", class(o), mat2str(size(o)));
end
bad = setdiff(string(fieldnames(o)), allow);
if ~isempty(bad)
    error("tepc:transport:UnknownXopt", ...
        "xopts 含未支持项 %s (只允许: %s)", strjoin(bad, ', '), strjoin(allow, ', '));
end
f = fieldnames(o);
for i = 1:numel(f)
    v = o.(f{i});
    if string(f{i}) == "straggle"
        % char/string 必须一起拒: logical('false') 是 1, 收下就等于把"关"执行成"开"。
        % 非标量也拒: 逐事件循环里 [false false] 会被 if 判成假而看起来像生效。
        if ~islogical(v) || ~isscalar(v)
            error("tepc:transport:BadXoptValue", ...
                "xopts.straggle 必须是逻辑标量 (true/false), 实得 %s %s", ...
                class(v), mat2str(size(v)));
        end
        x.straggle = v;
        continue
    end
    if ~(isnumeric(v) && isscalar(v) && isfinite(v) && v > 0)
        error("tepc:transport:BadXoptValue", ...
            "xopts.%s 必须为正的有限标量, 实得 %s", f{i}, mat2str(v));
    end
    x.(f{i}) = double(v);
end
end

function v = valof(x)
% VALOF 配置里的 {value,status,_source} 结构解包为标量 (兼容裸标量写法)。
if isstruct(x)
    if ~isfield(x,'value') || isempty(x.value)
        error("tepc:transport:NullParam","配置项为 null 且无 value 字段");
    end
    v = double(x.value);
else
    v = double(x);
end
end

function s = seedof(cfg)
s = 12345;
if isfield(cfg,'provenance') && isfield(cfg.provenance,'seed') && ~isempty(cfg.provenance.seed)
    s = cfg.provenance.seed;
end
if ~(isscalar(s) && isfinite(s) && s >= 0)
    error("tepc:transport:BadSeed","provenance.seed 必须是非负有限标量, 实得 %s", mat2str(s));
end
s = uint32(round(s));
end

function [e1, e2] = perpBasis(d)
d = d(:)/norm(d);
uZ = [0;0;1];
if abs(dot(d,uZ)) > 0.99, uZ = [1;0;0]; end
e1 = cross(uZ, d); e1 = e1/norm(e1);
e2 = cross(d, e1); e2 = e2/norm(e2);
end

function v = alignIn(loc, d, e1, e2, uZ) %#ok<INUSL>
% 把"以入射方向为 z 轴"的局部向量变到世界系: loc = cz*uZ + cx*e1 + cy*e2
v = loc(3)*d + loc(1)*e1 + loc(2)*e2;
end

function s = backDistToSphere(P, dir, rho)
% 沿 -dir 方向退到半径 rho 球面的距离 (P 在球内时唯一正根)。
% |P - s*dir|² = rho²  =>  s² - 2a s + c = 0, a = P.dir, c = |P|²-rho²;  c<0 时取 s = a+sqrt(a²-c)。
a = dot(P(:), dir(:)); c = dot(P(:), P(:)) - rho^2;
s = a + sqrt(max(a*a - c, 0));
end

function s = fwdDistToSphere(P, dir, rho)
% 沿 +dir 方向走到半径 rho 球面的距离 (P 在球内时唯一正根): t² + 2a t + c = 0 的正根。
a = dot(P(:), dir(:)); c = dot(P(:), P(:)) - rho^2;
s = -a + sqrt(max(a*a - c, 0));
end

function c = pickChannel(cfg, rs)
% PICKCHANNEL 通道抽样: 权重 = 数密度份额 × 截面(ASSUMED) × 用户权重。
comp = cfg.gas.composition_molfrac;
nFrac = numberFractions(comp);                % per-element number fractions
sig = cfg.source.channelSigma_barn;           % struct H/C/O, ASSUMED
wH = cfg.source.neutronChannels.elastic_H * get0(nFrac,'H') * valof(sig.H);
wC = cfg.source.neutronChannels.elastic_C * get0(nFrac,'C') * valof(sig.C);
wO = cfg.source.neutronChannels.elastic_O * get0(nFrac,'O') * valof(sig.O);
w = [wH, wC, wO];
if any(~isfinite(w)) || sum(w) <= 0
    error("tepc:transport:BadChannel","通道权重非法: %s", mat2str(w));
end
w = w/sum(w);
u = rand(rs);
if u < w(1), c = "elastic_H";
elseif u < w(1)+w(2), c = "elastic_C";
else, c = "elastic_O";
end
end

function v = get0(s, k)
if isfield(s,k), v = s.(k); else, v = 0; end
end

function nf = numberFractions(comp)
% NUMBERFRACTIONS 各元素原子数份额(用于中子作用权重)。
atoms = containers.Map;
tot = 0;
ks = fieldnames(comp);
for i = 1:numel(ks)
    toks = regexp(ks{i}, "([A-Z][a-z]?)(\d*\.?\d*)", "tokens");
    for j = 1:numel(toks)
        e = char(toks{j}{1}); cnt = str2double(toks{j}{2});
        if isnan(cnt)||cnt==0, cnt = 1; end
        if isKey(atoms,e), atoms(e) = atoms(e) + comp.(ks{i})*cnt;
        else, atoms(e) = comp.(ks{i})*cnt; end
    end
end
ke = keys(atoms);
for i = 1:numel(ke), tot = tot + atoms(ke{i}); end
nf = struct();
for i = 1:numel(ke), nf.(ke{i}) = atoms(ke{i})/tot; end
end

function c = sampleClass(p, N, rs)
u = rand(rs,N,1);
c = ones(N,1);
c(u > p(1)/(p(1)+p(2))) = 2;
end
