function [rho, meta] = gasDensity(pressure_Pa, temperature_K, molfrac, Z)
%GASDENSITY 理想/近理想气体密度 rho = p*M/(Z*R*T)。
%   molfrac: struct 字段=组分名(元素或分子式), 值=摩尔分数。
%   摩尔质量用元素周期表标准原子量(2021 CIAAW, 常规材料)计算。
%   返回 rho [kg/m^3] 与 meta(摩尔质量等)。

if nargin < 4, Z = 1.0; end
M_atom = containers.Map;
M_atom('H') = 1.008;  M_atom('C') = 12.011; M_atom('N') = 14.007;
M_atom('O') = 15.999; M_atom('Ar') = 39.948; M_atom('He') = 4.0026;

comp = molfrac;
s = 0; M = 0.0;
ks = fieldnames(comp);
for i = 1:numel(ks)
    s = s + comp.(ks{i});
end
if abs(s - 1) > 1e-6
    error("tepc:gas:CompositionSum","组分摩尔分数之和 = %.9f, 必须=1", s);
end
for i = 1:numel(ks)
    formula = string(ks{i});
    Mi = formulaMass(formula, M_atom);
    M = M + comp.(ks{i}) * Mi;
end
M = M / 1000; % g/mol -> kg/mol
R = 8.31446261815324; % J/(mol K), CODATA 2018
rho = pressure_Pa * M ./ (Z * R * temperature_K);
meta = struct('molarMass_kg_per_mol', M, 'R', R, 'composition', comp, 'Z', Z, ...
    'temperature_K', temperature_K, 'pressure_Pa', pressure_Pa);
end

function M = formulaMass(formula, M_atom)
%FORMULAMASS 解析简单化学式如 CH4, CO2, N2, C3H8 (元素+数字)。
tok = regexp(char(formula), "([A-Z][a-z]?)(\d*\.?\d*)", "tokens");
if isempty(tok)
    error("tepc:gas:BadFormula","无法解析化学式 %s", formula);
end
M = 0.0;
for i = 1:numel(tok)
    el = string(tok{i}{1}); cnt = tok{i}{2};
    if isempty(cnt), cnt = "1"; end
    if ~isKey(M_atom, char(el))
        error("tepc:gas:UnknownElement","未知元素 %s", el);
    end
    M = M + M_atom(char(el)) * str2double(cnt);
end
end
