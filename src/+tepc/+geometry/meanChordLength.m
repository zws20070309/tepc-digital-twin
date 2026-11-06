function lbar = meanChordLength(geom)
%MEANCHORDLENGTH 解析平均弦长（凸体, 各向同性均匀直线场, Cauchy 定理: lbar=4V/S）。
%   球: 4R/3。有限圆柱: 2RH/(H+R)。大板: 2D(极限)。无限圆柱返回 2R（凸性极限,
%   由 sampleChord 的 1e6 射线 MC 自检复核, 见 tests/unit/test_chord_length.m）。

switch string(geom.type)
    case "sphere"
        lbar = 4*geom.R_m/3;
    case "cylinder_endless"
        lbar = 2*geom.R_m;                  % 4V/S 的 H->Inf 极限
    case "cylinder_finite"
        R = geom.R_m; H = 2*sqrt(max(geom.bboxR_m^2 - R^2, 0));
        lbar = 2*R*H/(H+R);
    otherwise                               % slab 与其他: 直接用 buildGeometry 结果
        lbar = geom.lbar_gas_m;
end
end
