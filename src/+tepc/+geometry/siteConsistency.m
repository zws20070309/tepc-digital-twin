function out = siteConsistency(geom, rho_g, meta)
%SITECONSISTENCY 气体-组织质量厚度映射的一致性核算。
%   映射关系: rho_g * lbar_g = rho_t * lbar_t, 球形位点 lbar_t = 2*d_t/3。
%   因此 d_t_eq = 1.5 * rho_g * lbar_g / rho_t。
%   该检查量化: 请求的位点直径 d_t 与当前温压下实际可达的 d_t_eq 是否一致。
%   返回 out.d_t_eq_m / out.pressure_for_target_Pa / out.issues。

if ~isfield(geom,'site') || ~isfield(geom.site,'d_tissue_m')
    error("tepc:geometry:NoSite","几何对象缺少 site 信息");
end
lbar_g = geom.lbar_gas_m;
if isnan(lbar_g) || ~isfinite(lbar_g)
    error("tepc:geometry:NoLbar","气腔平均弦长不可用");
end
rho_t = geom.site.rho_tissue;
d_req = geom.site.d_tissue_m;

mass_thickness = rho_g * lbar_g;              % kg/m^2
lbar_t_eq = mass_thickness / rho_t;           % m
d_t_eq = 1.5 * lbar_t_eq;                     % 球形位点 (lbar_t = 2d/3 => d = 1.5*lbar)
% 达到目标位点所需压强: rho_g = rho_t*(2 d/3)/lbar_g, p = rho_g*Z*R*T/M
p_req = (rho_t * (2*d_req/3) / lbar_g) * meta.Z * meta.R * meta.temperature_K ...
        / meta.molarMass_kg_per_mol;

rel = abs(d_t_eq - d_req)/d_req;
out = struct();
out.d_t_eq_m = d_t_eq;
out.pressure_for_target_Pa = p_req;
out.mass_thickness_gas_kg_m2 = mass_thickness;
out.lbar_t_eq_m = lbar_t_eq;
out.relative_mismatch = rel;
out.issues = {};
if rel > tepc.config.constants('site.mismatchRelTol')
    out.issues{end+1} = struct('level',"warn", 'code',"SITE_PRESSURE_MISMATCH", ...
        'message', sprintf(['请求位点 d_t=%.3f um 与当前温压下的等效位点 d_t_eq=%.3f um ' ...
        '不一致, 相对差 %.1f%% (阈值 %g%%)。质量厚度映射要求压强约 %.0f Pa。'], ...
        d_req*1e6, d_t_eq*1e6, 100*rel, 100*tepc.config.constants('site.mismatchRelTol'), p_req));
end
end
