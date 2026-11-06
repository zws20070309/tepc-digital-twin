function writeEventsH5(path, E, attrs)
%WRITEEVENTSH5 事件级 HDF5 (固定 schema), gzip 分块 + 根属性。
%   数据集: /events/<字段>; 缺失值: 浮点 NaN, 整数用保留码 (-1)。
%   schema 与 EventBatch.schema() 逐字段一致 (由单测锁定, 不再凭空造 NaN 列)。
%   attrs: struct(schema_version, matlab_release, config_sha256, created_utc,
%                 units_system, run_status, seed, ...)
%   E: EventBatch (先 validate, 不通过即停)。

E.validate();
if isfile(path), delete(path); end   % 幂等重写

% EventBatch 字段名 -> HDF5 数据集名
map = { 'eventID','event_id','uint64';
        'primaryClass','primary_class','uint8';
        'E0_MeV','E0_MeV','double';
        'EdepGas_keV','EdepGas_keV','double';
        'EdepWall_keV','EdepWall_keV','double';
        'Eescape_keV','Eescape_keV','double';
        'Esecondary_keV','Esecondary_keV','double';
        'gasPath_um','gasPath_um','double';
        'r0_m','r0_m','double';
        'epsilon_meas_keV','epsilon_meas_keV','double';
        'lbar_tissue_um','lbar_tissue_um','double';
        'y_keV_per_um','y_keV_per_um','double';
        'weight','weight','double';
        't0_s','t0_s','double';
        't_trigger_s','t_trigger_s','double';
        'charge_C','charge_C','double';
        'peak_V','peak_V','double';
        'adc_code','adc_code','int32';
        'adc_range','adc_range','uint8';
        'flags','flags','uint32';
        'parent_event_id','parent_event_id','uint64';
        'model_id','model_id','uint16';
        'channelId','channel_id','uint8' };

n = E.n;
for i = 1:size(map, 1)
    fn = map{i,1}; ds = map{i,2}; dt = map{i,3};
    if ~isfield(E.ev, fn)
        error("tepc:io:MissingField","EventBatch 缺少 %s (schema 与写出器不同步)", fn);
    end
    col = E.ev.(fn);
    if numel(col) == 1 && n ~= 1
        col = repmat(col, n, 1);          % 常量列展开, 保证逐事件对齐
    end
    data = cast(col(:), dt);
    if numel(data) ~= n
        error("tepc:io:SizeMismatch","%s 长度 %d != 事件数 %d", fn, numel(data), n);
    end
    sz = [n, 1];
    h5create(path, ['/events/' ds], sz, 'DataType', dt, 'ChunkSize', ...
        [min(10000, max(n,1)), 1], 'Deflate', 5);
    if n > 0
        h5write(path, ['/events/' ds], data);
    end
end
% 根属性
attn = fieldnames(attrs);
for i = 1:numel(attn)
    val = attrs.(attn{i});
    if ischar(val) || isstring(val)
        h5writeatt(path, '/', attn{i}, char(val));
    elseif islogical(val)
        h5writeatt(path, '/', attn{i}, double(val));
    elseif isnumeric(val) && isscalar(val)
        h5writeatt(path, '/', attn{i}, double(val));
    else
        h5writeatt(path, '/', attn{i}, char(string(val)));
    end
end
end
