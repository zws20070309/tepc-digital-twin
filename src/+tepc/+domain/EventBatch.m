classdef EventBatch
%EVENTBATCH 事件级数据契约, 结构数组(SoA)承载的值对象。
%   运行循环直接对 E.ev.<field>(k) 批量写入以避免逐次拷贝;
%   validate() 在落盘前执行 schema 级检查(缺字段/NaN/重复主键/负能量即停)。

properties (SetAccess = public)
    ev = struct()
    n  = 0
end

methods (Static)
    function E = preallocate(n)
        E = tepc.domain.EventBatch();   % 包内全限定名, 避免名称解析问题
        z = zeros(n,1);
        E.ev.eventID       = z; E.ev.eventID(:) = 0;
        E.ev.primaryClass  = zeros(n,1,'uint8');
        E.ev.E0_MeV        = z;
        E.ev.EdepGas_keV   = z;
        E.ev.EdepWall_keV  = z;
        E.ev.gasPath_um    = z;
        E.ev.t0_s          = z;
        E.ev.weight        = ones(n,1);
        E.ev.charge_C      = z;  E.ev.charge_C(:) = NaN;   % 缺失=NaN(浮点)
        E.ev.peak_V        = z;  E.ev.peak_V(:)   = NaN;
        E.ev.adc_code      = ones(n,1,'int32'); E.ev.adc_code(:) = int32(-1); % 整数缺失=保留码
        E.ev.flags         = zeros(n,1,'uint32');
        E.ev.parent_event_id = z; E.ev.parent_event_id(:) = 0;
        E.ev.model_id      = zeros(n,1,'uint16');
        E.ev.lbar_tissue_um = z;  E.ev.lbar_tissue_um(:) = NaN;
        E.ev.y_keV_per_um  = z;   E.ev.y_keV_per_um(:)  = NaN;
        E.ev.Eescape_keV   = z;
        E.ev.Esecondary_keV = z;                       % 送入输运的次级带电粒子初始能
        E.ev.epsilon_meas_keV = z; E.ev.epsilon_meas_keV(:) = NaN;  % 仪器反演授予能
        E.ev.adc_range     = ones(n,1,'uint8');
        E.ev.t_trigger_s   = z;
        E.ev.r0_m          = z;  E.ev.r0_m(:) = NaN;
        % 中子弹性道标签: 1=H 2=C 3=O, 0=本事件没有核反应道 (光子分支或纯电子事件)。
        E.ev.channelId     = zeros(n,1,'uint8');
        E.n = n;
    end

    function F = schema()
        F = {'eventID','uint64-ish';'primaryClass','uint8';'E0_MeV','double'; ...
             'EdepGas_keV','double';'EdepWall_keV','double';'gasPath_um','double'; ...
             't0_s','double';'weight','double';'charge_C','double';'peak_V','double'; ...
             'adc_code','int32';'flags','uint32';'parent_event_id','uint64-ish'; ...
             'model_id','uint16';'lbar_tissue_um','double';'y_keV_per_um','double'; ...
             'Eescape_keV','double';'Esecondary_keV','double';'epsilon_meas_keV','double'; ...
             'adc_range','uint8';'t_trigger_s','double';'r0_m','double'; ...
             'channelId','uint8'};
    end
end

methods
    function E = setEvent(E, k, primary, ledger, q, instr)
        % 一次写入一个事件的各层数据 (transport truth -> detector -> DAQ)
        E.ev.eventID(k)      = primary.eventID;
        E.ev.primaryClass(k) = primary.class;
        E.ev.E0_MeV(k)       = primary.E0_MeV;
        E.ev.EdepGas_keV(k)  = ledger.EdepGas_keV;
        E.ev.EdepWall_keV(k) = ledger.EdepWall_keV;
        E.ev.gasPath_um(k)   = ledger.gasPath_um;
        E.ev.t0_s(k)         = primary.t0_s;
        E.ev.weight(k)       = primary.weight;
        E.ev.charge_C(k)     = q.charge_C;
        E.ev.peak_V(k)       = instr.peak_V;
        E.ev.adc_code(k)     = instr.adc_code;
        E.ev.flags(k)        = instr.flags;
        E.ev.model_id(k)     = primary.model_id;
    end

    function T = toTable(E)
        T = struct2table(E.ev);
    end

    function problems = validate(E, opts)
        % Schema 级校验: 违反即返回问题列表(调用方决定 stop)。
        if nargin < 2, opts = struct('stopOnError', true); end
        problems = {};
        f = E.ev;
        req = tepc.domain.EventBatch.schema();
        for i = 1:size(req,1)
            if ~isfield(f, req{i,1})
                problems{end+1} = sprintf("缺少必需字段 %s", req{i,1}); %#ok<AGROW>
            end
        end
        if ~isempty(problems)
            if opts.stopOnError, error("tepc:events:Schema", "%s", strjoin(problems, "; ")); end
            return;
        end
        if any(diff(sort(f.eventID)) == 0)
            problems{end+1} = "eventID 存在重复主键"; %#ok<AGROW>
        end
        if any(f.EdepGas_keV < 0 | ~isfinite(f.EdepGas_keV))
            problems{end+1} = "EdepGas_keV 存在负值/NaN"; %#ok<AGROW>
        end
        if any(f.weight < 0 | ~isfinite(f.weight))
            problems{end+1} = "weight 存在负值/NaN"; %#ok<AGROW>
        end
        if any(f.t0_s < 0)
            problems{end+1} = "t0_s 存在负时间"; %#ok<AGROW>
        end
        if opts.stopOnError && ~isempty(problems)
            error("tepc:events:Schema", "%s", strjoin(problems, "; "));
        end
    end
end
end
