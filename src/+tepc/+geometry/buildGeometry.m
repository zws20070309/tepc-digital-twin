function g = buildGeometry(cfg)
%BUILDGEOMETRY 构建几何对象（球/圆柱/平板），导出体积、表面积与解析平均弦长。
%   依据: Cauchy 定理——凸体在各向同性场中的平均弦长 lbar = 4V/S (ICRU 36)。
%   球: 4V/S = 4R/3 = 2d/3。圆柱只在方向分布满足条件时用解析式,
%   有限圆柱为凸体, 4V/S = 2RH/(H+R) 仍成立(由 sampleChord 的 MC 自检验证)。

t = string(cfg.geometry.type);
R = cfg.geometry.gasRadius_mm * 1e-3;      % m
% 阳极**形状**由电极拓扑给出 (唯一映射 tepc.geometry.electrode), 不再由敏感体积猜。
% 旧实现按 type 猜: sphere => centerSphere, 而场却是圆柱 => 图与场自相矛盾。
% 本函数只取 anodeType; 拓扑是否合法由 validate/resolve 判 (buildGeometry 也可被
% 单元测试直接调, 故这里对"校验层已拒绝的几何"保留历史值而不抛错)。
el = tepc.geometry.electrode(cfg);
switch t
    case "sphere"
        V = 4/3*pi*R^3; S = 4*pi*R^2;
        lbar = 4*V/S;                       % = 4R/3
        an = 'INVALID';                     % 拓扑不合法时**明写** INVALID, 不再猜
        if el.valid, an = el.anodeType; end
        anode = struct('type',an,'radius_m',cfg.geometry.anodeRadius_um*1e-6);
        bboxR = R;
    case "cylinder_endless"
        V = Inf; S = Inf; lbar = NaN;       % 凸性极限: 4V/S -> 2R (由 MC 验证)
        anode = struct('type','axialWire','radius_m',cfg.geometry.anodeRadius_um*1e-6);
        bboxR = R;
    case "cylinder_finite"
        if ~isfield(cfg.geometry,'cylinderLength_mm') || isempty(cfg.geometry.cylinderLength_mm)
            error("tepc:geometry:MissingLength","cylinder_finite 需要 cylinderLength_mm");
        end
        H = cfg.geometry.cylinderLength_mm*1e-3;
        V = pi*R^2*H; S = 2*pi*R*H + 2*pi*R^2;
        lbar = 4*V/S;                       % = 2RH/(H+R)
        an = 'axialWire';  if el.valid, an = el.anodeType; end
        anode = struct('type',an,'radius_m',cfg.geometry.anodeRadius_um*1e-6);
        bboxR = sqrt(R^2 + (H/2)^2);
    case "slab"
        if ~isfield(cfg.geometry,'cylinderLength_mm') || isempty(cfg.geometry.cylinderLength_mm)
            error("tepc:geometry:MissingLength","slab 需要 cylinderLength_mm 作为厚度");
        end
        D = cfg.geometry.cylinderLength_mm*1e-3; L = 2*R; % 以半径字段作半宽
        V = L^2*D; S = 2*L^2 + 4*L*D;
        lbar = 4*V/S;                       % 大板极限 -> 2D
        anode = struct('type','none','radius_m',NaN);   % 平板无中心阳极 => 校验层已拒绝
        bboxR = sqrt((L/2)^2*2 + (D/2)^2);
    otherwise
        error("tepc:geometry:UnknownType","未知几何类型 %s", t);
end

g = struct();
g.type = t;
g.R_m = R;
g.wallThickness_m = cfg.geometry.wallThickness_mm*1e-3;
g.wallMaterial = cfg.geometry.wallMaterial;
g.V_m3 = V; g.S_m2 = S;
g.lbar_gas_m = lbar;                        % 气腔平均弦长
g.anode = anode;
g.bboxR_m = bboxR;
if isfield(cfg,'site') && isfield(cfg.site,'targetDiameter_um')
    g.site.d_tissue_m = cfg.site.targetDiameter_um*1e-6;
    g.site.lbar_tissue_m = 2*g.site.d_tissue_m/3;  % 球形位点 lbar = 2d/3
    g.site.rho_tissue = cfg.site.tissueDensity_kg_m3;
end
end
