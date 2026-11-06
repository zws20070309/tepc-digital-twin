classdef (Abstract) TransportAdapter
%TRANSPORTADAPTER 输运适配器统一接口（只替换输运层, 其余链路不变）。
%   所有适配器按 chunk 生成事件(EventBatch), 不直接写图/文件, 便于 GUI/批处理/续跑。
%   纯 MATLAB 主线只走解析路线 AnalyticAdapter; Geant4/FLUKA/MCNP 未实现,
%   本接口保留为它们的扩展点。

methods (Abstract, Static)
    E  = generateChunk(cfg, geom, tables, rs, N, firstID, state)
    s  = name()
    st = requires()
end
end
