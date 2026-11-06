function [rho_g_cm3, src] = wallDensity(opts)
%WALLDENSITY 壁密度 (A-150 名义值) 在**输运侧**的唯一取数点。
%   诚实边界: 这条常数在仓库里还有第二个读者 —— +geometry/meshSpec.m 直接
%   constants('transport.a150.density_g_cm3') 取同一值写进几何清单, geometry/materials.json
%   的 a150 条也自述为"同值镜像"。三处相等由 tests/unit/test_wall_density_single_source.m
%   锁住 (改一处即红), 但"把两处来源合成一处"仍是未闭合项, 所以这里不称"全仓库唯一读者"。
%   [rho, src] = tepc.transport.wallDensity(opts)
%   opts 里给了 rho_wall_g_cm3 就用它 (来源记为 caller_override), 否则读常数注册表
%   条目 transport.a150.density_g_cm3 (来源记为 config)。src 字段:
%   kind / const_id / path / value_g_cm3 / units / reader。
%
%   单位口径: 返回值一律 g/cm3 —— 阻止本领按 MeV cm2/g 登记, 壁内射程步长
%   dR = dE/(S*rho) 只有 rho 用 g/cm3 时量纲才闭合; 若来源改按 SI(kg/m3) 登记,
%   换算系数是 1e-3 (1 g/cm3 = 1e3 kg/m3)。注册表条目的 id 自带 _g_cm3 后缀,
%   所以这里不做任何换算。
%   量级窗口与几何侧材料表对 density_g_cm3 的窗口同界: 把 kg/m3 写进 g/cm3 字段
%   (1124 之类) 在这里被拒, 而不是让壁射程缩小一千倍后在结果里隐身。
%
%   错误标识符: tepc:csda:BadWallDensity  密度不是 (1e-6, 25) g/cm3 内的有限标量。

if nargin < 1, opts = struct(); end
if isstruct(opts) && isscalar(opts) && isfield(opts, 'rho_wall_g_cm3') && ...
        ~isempty(opts.rho_wall_g_cm3)
    rho_g_cm3 = double(opts.rho_wall_g_cm3);
    src = struct('kind', 'caller_override', 'const_id', '', ...
        'path', '', 'value_g_cm3', rho_g_cm3, 'units', 'g/cm^3', ...
        'reader', 'opts.rho_wall_g_cm3');
else
    rho_g_cm3 = double(tepc.config.constants('transport.a150.density_g_cm3'));
    src = struct('kind', 'config', 'const_id', 'transport.a150.density_g_cm3', ...
        'path', 'docs/constants.json', 'value_g_cm3', rho_g_cm3, ...
        'units', 'g/cm^3', 'reader', 'tepc.config.constants');
end
if ~(isscalar(rho_g_cm3) && isfinite(rho_g_cm3) && rho_g_cm3 > 1e-6 && rho_g_cm3 < 25)
    error("tepc:csda:BadWallDensity", ...
        "壁密度须为 (1e-6, 25) g/cm3 内的有限标量, 实得 %.6g: 疑为单位口径错 (kg/m3 须乘 1e-3)", ...
        rho_g_cm3);
end
end
