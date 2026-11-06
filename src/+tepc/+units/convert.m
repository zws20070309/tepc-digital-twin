function out = convert(value, fromUnit, toUnit)
%CONVERT 单位换算（仿真内部固定单位制的锚点）。
%   内部工作单位: 能量 keV, 长度 um(微剂量学)/m(几何), 质量 kg, 剂量 Gy。
%   每个换算因子都有独立出处（CODATA 2018 / 定义常数），是单位测试的锚点。

persistent F FAM
if isempty(F)
    F = containers.Map;
    F('keV')        = 1.602176634e-16;        % J, CODATA 2018 精确定义
    F('MeV')        = 1.602176634e-13;        % J
    F('J')          = 1.0;
    F('keV_per_um') = 1.602176634e-10;        % J/m = 1.602e-16 J / 1e-6 m
    F('J_per_m')    = 1.0;
    F('Pa')         = 1.0;
    F('bar')        = 1.0e5;
    F('Torr')       = 101325/760;             % Pa, 定义值
    F('mmHg')       = 101325/760;             % 常规 mmHg 与 Torr 等同（数量级锚定）
    F('C')          = 1.0;
    F('e')          = 1.602176634e-19;        % C, CODATA 2018 精确定义
    F('Gy')         = 1.0;                    % J/kg
    F('kg')         = 1.0;
    F('um')         = 1e-6;                   % m
    F('mm')         = 1e-3;
    F('cm')         = 1e-2;
    F('m')          = 1.0;

    FAM = containers.Map;
    FAM('energy')  = ["keV","MeV","J"];
    FAM('lineal')  = ["keV_per_um","J_per_m"];
    FAM('pressure')= ["Pa","bar","Torr","mmHg"];
    FAM('charge')  = ["C","e"];
    FAM('dose')    = ["Gy"];
    FAM('mass')    = ["kg"];
    FAM('length')  = ["um","mm","cm","m"];
end

fu = string(fromUnit); tu = string(toUnit);
if ~isKey(F, char(fu)) || ~isKey(F, char(tu))
    error("tepc:units:UnknownUnit","未知单位: %s 或 %s", fu, tu);
end
famF = familyOf(fu, FAM); famT = familyOf(tu, FAM);
if famF ~= famT
    error("tepc:units:DimensionMismatch","量纲不匹配: %s(%s) <-> %s(%s)", fu, famF, tu, famT);
end
out = value .* F(char(fu)) ./ F(char(tu));
end

function fam = familyOf(u, FAM)
ks = keys(FAM); fam = "";
for i = 1:numel(ks)
    if any(FAM(ks{i}) == string(u))
        fam = string(ks{i}); return;
    end
end
end
