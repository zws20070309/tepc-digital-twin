function E = readEventsH5(path)
%READEVENTSH5 读回 events.h5 为 EventBatch, 并执行 schema 校验(读取即停策略)。
%   文件缺任一必需数据集即报错 —— 不得由 preallocate 凭空造 NaN 列掩盖缺失。
dmap = {'eventID','event_id'; 'primaryClass','primary_class'; 'E0_MeV','E0_MeV'; ...
    'EdepGas_keV','EdepGas_keV'; 'EdepWall_keV','EdepWall_keV'; ...
    'Eescape_keV','Eescape_keV'; 'Esecondary_keV','Esecondary_keV'; ...
    'gasPath_um','gasPath_um'; 'r0_m','r0_m'; ...
    'epsilon_meas_keV','epsilon_meas_keV'; 'lbar_tissue_um','lbar_tissue_um'; ...
    'y_keV_per_um','y_keV_per_um'; 'weight','weight'; 't0_s','t0_s'; ...
    't_trigger_s','t_trigger_s'; 'charge_C','charge_C'; 'peak_V','peak_V'; ...
    'adc_code','adc_code'; 'adc_range','adc_range'; 'flags','flags'; ...
    'parent_event_id','parent_event_id'; 'model_id','model_id'; ...
    'channelId','channel_id'};
info = h5info(path, '/events');
names = {info.Datasets.Name};
E = tepc.domain.EventBatch.preallocate(0);
n = size(h5read(path, '/events/event_id'), 1);
E = tepc.domain.EventBatch.preallocate(n);
for i = 1:size(dmap,1)
    fld = dmap{i,1}; ds = dmap{i,2};
    if ~any(strcmp(ds, names))
        error("tepc:io:SchemaMissing","events.h5 缺少必需数据集 %s", ds);
    end
    v = h5read(path, ['/events/' ds]);
    want = E.ev.(fld);
    if isnumeric(want) && ~islogical(want) && ~isempty(want)
        v = cast(v(:), class(want(1)));          % 保持与内存 schema 同类型
    else
        v = v(:);
    end
    E.ev.(fld) = v;
end
E.validate();
end
