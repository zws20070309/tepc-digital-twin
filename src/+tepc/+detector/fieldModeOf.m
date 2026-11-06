function mode = fieldModeOf(field)
%FIELDMODEOF field 结构体里的场来源模式, 缺省 'analytic' (历史行为)。
%   词表 analytic | fem_map, 与 config schema 的 field.mode 值域同一套。
%     analytic  E(r)=V*K/r^(p-1) 闭式 (tepc.detector.fieldModel)
%     fem_map   2-D 轴对称有限元场图 (tepc.detector.solveElectrostatic 产出)
%   模式只回答"场从哪里来"; 电极拓扑 (柱对称/球壳) 仍只由 field.kind 经
%   tepc.detector.fieldKindOf 给出, 两个开关各管一件事, 不许互相顶替 —— 历史上
%   geometry.fieldGeometry 与 electrodeTopology 并存时曾把球壳场静默降级成圆柱场。
%   未知值必须报错而不是"当作解析场": 接受但静默忽略的开关等于假开关。
%
%   错误标识符
%     tepc:field:BadMode   field.mode 不在 {analytic, fem_map} 内

if ~isfield(field, 'mode') || isempty(field.mode)
    mode = 'analytic';
    return;
end
m = lower(strtrim(char(string(field.mode))));
if ~any(string(m) == ["analytic", "fem_map"])
    error("tepc:field:BadMode", ...
        "field.mode 只能是 'analytic' 或 'fem_map', 实得 '%s'。球腔+中心丝的真实场用 " + ...
        "'fem_map' 并提供 tepc.detector.solveElectrostatic 产出的场图 (field.map 或 field.mapFile)。", ...
        char(string(field.mode)));
end
mode = m;
end
