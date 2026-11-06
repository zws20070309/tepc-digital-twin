function R = resolve(cfg)
%RESOLVER 派生物理量: 气体密度、平均弦长、位点一致性、增益、质量、谱 bin。
%   位点等效 (质量厚度映射 rho_g*lbar_g = rho_t*lbar_t) 只有两个自由度:
%   压强 与 位点直径。二者不能同时"请求"—— 因此本实现按 equivalenceMode 显式
%   决定谁是自变量:
%     "derived"   (默认): 位点由当前温压导出 => 发布谱报告真实实现的位点;
%     "requested":       保持请求位点, 但记录 SITE_PRESSURE_MISMATCH 并在门禁降级。
[rho_g, gmeta] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, cfg.gas.temperature_K, ...
    cfg.gas.composition_molfrac, cfg.gas.compressibility_Z);
geom = tepc.geometry.buildGeometry(cfg);
R = struct();
R.rho_g = rho_g; R.gasMeta = gmeta;
R.massGas_kg = rho_g * geom.V_m3;
% 位点一致性 (质量厚度映射)
sc = tepc.geometry.siteConsistency(geom, rho_g, gmeta);
mode = "derived";
if isfield(cfg,'site') && isfield(cfg.site,'equivalenceMode') && ~isempty(cfg.site.equivalenceMode)
    mode = lower(string(cfg.site.equivalenceMode));
end
d_req = geom.site.d_tissue_m;
if mode == "derived"
    % 原子地成对覆写 (d_t, lbar_t): 只改其一会破坏 lbar_t = 2 d_t/3,
    % 从而让 doseChain 的定义核对式失效 (该核对是几何定义的恒等式)。
    geom.site.d_tissue_m    = sc.d_t_eq_m;
    geom.site.lbar_tissue_m = sc.lbar_t_eq_m;
end
R.geom = geom;
R.siteMode = char(mode);
R.site_requested_d_tissue_m = d_req;
R.siteConsistency = sc;
R.lbar_tissue_um = geom.site.lbar_tissue_m * 1e6;
% 增益: 场类型只由电极拓扑导出 (tepc.geometry.electrode 是唯一映射)。
%   旧实现在此有一份局部 fieldKindOf, 其 centerSphere 分支是空操作 (两支都返回
%   'cylinder') => 中心球阳极静默使用圆柱场, E(r)/增益/Ramo 全错。
el = tepc.geometry.electrode(cfg);
if ~el.valid
    error(el.errId, "%s", el.reason);     % 拓扑缺失/不匹配/几何不支持: 一律拒绝, 不再猜默认值
end
R.electrode = el;
R.field = struct('a', cfg.geometry.anodeRadius_um*1e-6, 'b', cfg.geometry.gasRadius_mm*1e-3, ...
    'hv_V', cfg.field.hv_V, 'kind', el.fieldKind, 'topology', el.topology, ...
    'mode', cfgStr(cfg, {'field','mode'}, 'analytic'), ...
    'mapFile', cfgStr(cfg, {'field','mapFile'}, ''));
R.G_mean = tepc.detector.avalanche(R.field, ...
    struct('deltaV_V', cfg.detector.diethorn_deltaV_V.value), RandStream('Threefry','Seed',1)).G_mean;
% 谱 bin
if strcmp(cfg.analysis.binSpacing,"log")
    R.edges = logspace(log10(cfg.analysis.yMin_keV_um), log10(cfg.analysis.yMax_keV_um), ...
        cfg.analysis.nBins+1);
else
    R.edges = linspace(cfg.analysis.yMin_keV_um, cfg.analysis.yMax_keV_um, cfg.analysis.nBins+1);
end
% 载流子迁移率 (感应电流时序用; 低气压 ASSUMED, 1/p 缩放)
p0 = 101325.0;
mob0_e = 0.05;                    % m^2/(V s) @ 1 atm 量级的等效值 (ASSUMED)
mob0_i = 2.0e-4;                  % 离子迁移率 @ 1 atm (ASSUMED)
R.mob = struct( ...
    'mu_e_m2_Vs', getv(cfg,'mobility_e') + mob0_e*p0/max(cfg.gas.pressure_Pa,1), ...
    'mu_i_m2_Vs', getv(cfg,'mobility_i') + mob0_i*p0/max(cfg.gas.pressure_Pa,1));
if isfield(cfg,'mobility')
    if isfield(cfg.mobility,'electron_m2_Vs'), R.mob.mu_e_m2_Vs = cfg.mobility.electron_m2_Vs; end
    if isfield(cfg.mobility,'ion_m2_Vs'),      R.mob.mu_i_m2_Vs = cfg.mobility.ion_m2_Vs;      end
end
% 雪崩起始半径: 与 avalanche() 的有效电离半径取同一 ASSUMED 值 (10a), 保证
% 增益模型与感应电流模型对同一条雪崩轨迹一致。钳位系数同样来自注册表:
% 三处 (resolve / avalanche / validate 的增益门禁) 必须同值, 否则同一几何会算出三个 G。
R.r0_m = min(max(tepc.config.constants('detector.avalanche.rStartFactor')*R.field.a, ...
    R.field.a*tepc.config.constants('detector.avalanche.rStartClampLowerFracOfA')), ...
    R.field.b*tepc.config.constants('detector.avalanche.rStartClampUpperFracOfB'));
R.notes = { sprintf('rho_g=%.4e kg/m3, lbar_gas=%.2f mm, lbar_t=%.4f um (位点模式 %s)', ...
    rho_g, geom.lbar_gas_m*1e3, R.lbar_tissue_um, mode), ...
    sprintf('D_t_eq=%.3f um (请求 %.3f um, 相对差 %.1f%%)', ...
    sc.d_t_eq_m*1e6, cfg.site.targetDiameter_um, 100*sc.relative_mismatch), ...
    sprintf('G_mean=%.1f @ %.0f V (Diethorn deltaV=%.1f V, ASSUMED)', ...
    R.G_mean, cfg.field.hv_V, cfg.detector.diethorn_deltaV_V.value), ...
    sprintf('mu_e=%.3e mu_i=%.3e m2/Vs @ %.0f Pa (ASSUMED, 1/p 缩放)', ...
    R.mob.mu_e_m2_Vs, R.mob.mu_i_m2_Vs, cfg.gas.pressure_Pa)};
end

function v = getv(cfg, nm)
v = 0;
if isfield(cfg,'mobility') && isfield(cfg.mobility, nm) && ~isempty(cfg.mobility.(nm))
    v = double(cfg.mobility.(nm));
end
end

function s = cfgStr(cfg, parts, dflt)
%CFGSTR 取配置里的字符串字段, 缺失/空 -> 显式缺省值 (不猜)。
%   field.mode 的缺省是 'analytic' —— 即历史行为; 真正的值域校验在
%   tepc.detector.fieldModeOf 里做 (唯一的词表), 这里不重复一份词表。
s = dflt;
v = cfg;
try
    for i = 1:numel(parts)
        v = v.(parts{i});
    end
catch
    return;
end
if ~isempty(v) && (ischar(v) || isstring(v))
    s = strtrim(char(string(v)));
end
end
