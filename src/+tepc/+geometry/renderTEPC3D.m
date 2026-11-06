function h = renderTEPC3D(spec, varargin)
%RENDERTEPC3D TEPC 三维证据图 (爆炸 / 剖切 / 叠加三视图)。
%
%   fig = renderTEPC3D(spec)                                   % 默认离屏 classic 图
%   fig = renderTEPC3D(spec, 'View','section', 'Units','mm')   % 最小调用
%   axh = renderTEPC3D(spec, 'Host','axes', 'Parent', ax)      % 嵌进 uifigure 的 UIAxes
%   renderTEPC3D(spec, 'View','overlay', 'Traces', tr)         % 叠加输运层给的轨迹
%
% Name/Value
%   'View'      'exploded' | 'section' | 'overlay'   (默认 'section')
%   'Host'      'figure' (默认, 自建离屏 classic figure) | 'axes' (画进 Parent)
%   'Parent'    Host='axes' 时的目标坐标区句柄 (GUI 的 UIAxes 走这条路径)
%   'Units'     'mm' (默认) | 'um' —— **只影响显示坐标与轴标签**, spec 内部始终是米
%   'Resolution' 展示网格 n (默认 spec.displayResolution_n; 网格由 spec.buildPartMesh
%               这个**唯一构造入口**重建, 本函数不含任何几何公式)
%   'Traces'    输运层给的轨迹 struct 数组 (见 tepc.geometry.traceSpec); 仅 overlay 用
%   'CutPlane'  剖切面方程文字 (默认 'x = 0'), 只进标题/manifest, **不删任何网格**
%   'Visible'   'off'(默认, 证据图) | 'on'
%   'UserDataExtra'  附加进每个图形对象 UserData 的字段 (struct, 可含 config_sha256)
%
% 本文件逐条落实的三条渲染规则:
%   1) **无随机数、无抽样器**: 全文不出现 rand/randn/randperm/rng/shuffle, 不调用
%      sampleChord / csdaTransport / 任何 transport 函数。轨迹只能由**输运层**
%      (tepc.geometry.traceSpec) 生成后经 'Traces'/spec.traces 传进来。
%   2) **不删网格做剖切**: section/overlay 靠透明度 + 标题里写明的切平面表达,
%      因此面积/体积审计量 (V/S/lbar) 与 exploded 视图完全同源。
%   3) **标题/图例同时打印 敏感体积 与 电极拓扑/场类型 + 单位**: "球形敏感体积 + 圆柱
%      电场"若不分别标注就是真实的语义错配 (两者可以不同)。
%
% 渲染器选择: 默认自建 `figure('Visible','off','Renderer','opengl')`。
%   uifigure **没有** Renderer 属性, painters 会把 FaceAlpha 画成不透明且忽略
%   lighting/camlight => 透明壳层与光照证据图必须走 opengl 经典图。
%   Host='axes' 时不改宿主图渲染器 (GUI 的 uifigure 由调用方负责), 只做 3D 绘制。
%
% 返回: Host='figure' -> 图句柄 (调用方 exportgraphics/PNG); Host='axes' -> 坐标区句柄。
% 每个图形对象的 UserData 挂 part_id/material/transport_role/fieldTopology/
% electrodeTopology/geometryType/units/sourceConfigSha256。

p = inputParser;
p.addParameter('View', 'section', @(v) ischar(v) || isstring(v));
p.addParameter('Host', 'figure', @(v) ischar(v) || isstring(v));
p.addParameter('Parent', []);
p.addParameter('Units', 'mm', @(v) ischar(v) || isstring(v));
p.addParameter('Resolution', []);
p.addParameter('Traces', []);
p.addParameter('CutPlane', 'x = 0');
p.addParameter('Visible', 'off');
p.addParameter('Camera', [35 25]);                 % 固定视角, 证据图可复现
p.addParameter('UserDataExtra', struct());
p.parse(varargin{:});
a = p.Results;

viewKind   = lower(char(string(a.View)));
hostKind   = lower(char(string(a.Host)));
unitKind   = lower(char(string(a.Units)));
nRes       = a.Resolution;
if isempty(nRes), nRes = spec.displayResolution_n; end

%% 显示层单位换算 (spec 内部 SI; 1 m = 1e3 mm = 1e6 um, 系数写死在此)
switch unitKind
    case "mm", uFac = 1e3;  uLab = 'mm';
    case "um", uFac = 1e6;  uLab = 'um';
    case "m",  uFac = 1.0;  uLab = 'm';            % 也允许 (STL 导出用), 图上仍标注
    otherwise
        error("tepc:geometry:BadUnits", "renderTEPC3D 的 Units 只允许 mm|um|m (实得 %s)", unitKind);
end
switch viewKind
    case {'exploded','section','overlay'},
    otherwise
        error("tepc:geometry:BadView", ...
            "View 只允许 exploded|section|overlay (三视图), 实得 %s", viewKind);
end

%% 宿主: 离屏经典图 (opengl) 或调用方给的坐标区
ownFigure = strcmp(hostKind, 'figure');
if ownFigure
    fig = figure('Visible', char(string(a.Visible)), 'Renderer', 'opengl', ...
        'Color', 'w', 'Position', [40 40 980 760]);
    ax = axes('Parent', fig);
else
    ax = a.Parent;
    if ~isgraphics(ax), error("tepc:geometry:NoParent","Host='axes' 需要 Parent 坐标区句柄"); end
    fig = ancestor(ax,'figure');
end
cla(ax); hold(ax,'on'); grid(ax,'off');

%% 顶栏文字: 三样东西必须在同一处出现 (单位 / 敏感体积 / 电极拓扑与场)
%   分两行而不是拼成一行: 单行实测渲染宽 1077 px 而画幅只有 980 px, 超出画幅的部分会被裁掉,
%   被裁掉的正是"场类型/切平面不删网格"这类图自己无法自证的口径。两行同属一个 Title 对象,
%   三样东西仍然"在同一处出现"。
topoLine = sprintf('sensitive volume: %s | electrodeTopology: %s | field kind: %s', ...
    char(spec.geometryType), char(spec.electrodeTopology), char(spec.fieldTopology));
tailLine = sprintf('TEPC 3D [%s] — units / %s', viewKind, uLab);
switch viewKind
    case "section"
        tailLine = sprintf('%s | cut plane: %s (transparency only, no mesh deleted)', ...
            tailLine, char(string(a.CutPlane)));
    case "overlay"
        tailLine = sprintf('%s | cut plane: %s', tailLine, char(string(a.CutPlane)));
end
title(ax, {tailLine, topoLine}, 'Interpreter', 'none');
xlabel(ax, sprintf('x / %s', uLab)); ylabel(ax, sprintf('y / %s', uLab));
zlabel(ax, sprintf('z / %s', uLab));

%% 等比例 (缺 axis equal => 球画成椭球)
axis(ax,'equal');
axis(ax,'vis3d');

%% 零件绘制
showOffset = strcmp(viewKind, 'exploded');
drawField  = ~strcmp(viewKind, 'exploded');         % 爆炸图是机械图, 不叠场
hs = [];                                            % 返回给调用方的图形句柄清单
names = {};
env = zeros(0,3);
col = partColors();
for k = 1:numel(spec.parts)
    P = spec.parts(k);
    id = char(P.part_id);
    shp = P.shape;
    if showOffset && isfield(spec.offsets, id)
        off = double(spec.offsets.(id)) * uFac;
    else
        off = [0 0 0];
    end
    % 网格: 默认直接用 spec 里存好的展示网格; 只有当调用方要求别的分辨率时才用
    % spec.buildPartMesh (meshSpec 里唯一的那份构造代码) 重建 —— 本函数不含几何公式。
    if nRes == spec.displayResolution_n || ~isfield(spec, 'buildPartMesh')
        V = double(P.V);
        F = double(P.F);
    else
        mm = spec.buildPartMesh(shp, nRes);
        V = double(mm.V);
        F = double(mm.F);
    end
    if isempty(V) || isempty(F)
        continue
    end
    XYZ = V*uFac + repmat(off, size(V,1), 1);             % 米 -> 显示单位 (显式系数)
    env = [env; XYZ];                                     %#ok<AGROW>

    alphaVal = alphaForView(id, viewKind);
    colVal = colFor(col, id);
    showEdge = drawEdgeOverlay(id, viewKind);
    hp = patch(ax, 'Faces', F, 'Vertices', XYZ, ...
        'FaceColor', colVal, 'FaceAlpha', alphaVal, ...
        'EdgeColor', edgeColorFor(id, viewKind), ...
        'LineWidth', 0.8, ...
        'DisplayName', legendFor(P, uLab, spec), ...
        'HitTest', 'off');
    ud = struct('part_id', id, 'material', char(P.material), ...
        'material_status', char(P.materialStatus), ...
        'transport_role', char(P.transport_role), ...
        'transport_evidence', char(P.transport_evidence), ...
        'units', 'SI', 'display_units', uLab, 'unit_factor_from_m', uFac, ...
        'geometryType', char(spec.geometryType), ...
        'electrodeTopology', char(spec.electrodeTopology), ...
        'fieldTopology', char(spec.fieldTopology), ...
        'anodeType', char(spec.anodeType), ...
        'resolution_n', nRes, ...
        'sourceConfigSha256', char(spec.sourceConfigSha256), ...
        'geometrySha256', char(spec.geometrySha256), ...
        'sha256Source', char(spec.sha256Source), ...
        'schematic_traces', logical(spec.schematicTraces));
    if ~isempty(a.UserDataExtra)
        fn = fieldnames(a.UserDataExtra);
        for i = 1:numel(fn), ud.(fn{i}) = a.UserDataExtra.(fn{i}); end
    end
    set(hp, 'UserData', ud);
    hs(end+1) = hp; %#ok<AGROW>
    names{end+1} = get(hp,'DisplayName'); %#ok<AGROW>
    if showEdge
        % 共面皮只多画一层**描边**: 不新增面片 (ud.edge_overlay=true), 这样
        % "剖切不删网格"的面数审计仍是零件表面数之和。
        he = patch(ax, 'Faces', F, 'Vertices', XYZ, 'FaceColor','none', ...
            'EdgeColor',[0.15 0.15 0.15],'LineWidth',0.4,'HandleVisibility','off');
        udEdge = ud; udEdge.edge_overlay = true;
        set(he,'UserData',udEdge);
        hs(end+1) = he; %#ok<AGROW>
    end
end

%% 场线 / 等势面: 只画 spec.field 里**解析算好**的东西 (本函数不求解场)
if drawField
    aF = spec.field;
    for k = 1:numel(aF.lines)
        pl = plot3(ax, aF.lines{k}(:,1)*uFac, aF.lines{k}(:,2)*uFac, aF.lines{k}(:,3)*uFac, ...
            'Color', [0.85 0.55 0.0], 'LineWidth', 1.1, ...
            'DisplayName', sprintf('E-field line (analytic, %s, clipped to (%.3g,%.3g) m)', ...
            char(aF.kind), aF.clip_m(1), aF.clip_m(2)));
        set(pl,'UserData', userDataField(spec, aF, uFac, nRes));
        hs(end+1) = pl; %#ok<AGROW>
        names{end+1} = get(pl,'DisplayName'); %#ok<AGROW>
    end
    for k = 1:numel(aF.rIso_m)
        ishs = struct('type',string(aF.kind), ...
            'radius_m',aF.rIso_m(k), ...
            'height_m', double(aF.b_m)*2*(string(aF.kind)=="cylinder"), ...
            'half_m', aF.rIso_m(k), 'apex_m',[0 0 0], 'base_m',[0 0 0]);
        if string(aF.kind) == "cylinder"
            mi = spec.buildPartMesh(ishs, max(24, round(nRes/2)));
        else
            mi = spec.buildPartMesh(struct('type',"sphere",'radius_m',aF.rIso_m(k), ...
                'height_m',NaN), max(24, round(nRes/2)));
        end
        pl = patch(ax, 'Faces', mi.F, 'Vertices', mi.V*uFac, 'FaceColor', [0 0.45 0.75], ...
            'FaceAlpha', 0.10, 'EdgeColor', [0 0.45 0.75], 'LineWidth', 0.4, ...
            'DisplayName', sprintf('weight-field surface phi_w=%.2f (analytic)', aF.phiLevels(k)));
        set(pl,'UserData', userDataField(spec, aF, uFac, nRes));
        hs(end+1) = pl; %#ok<AGROW>
        names{end+1} = get(pl,'DisplayName'); %#ok<AGROW>
    end
end

%% 轨迹叠加 (overlay): 只消费外部传入的线段, 无则明确标注 NOT_VISUALIZED
if strcmp(viewKind, 'overlay')
    tr = a.Traces;
    if isempty(tr) && isfield(spec,'traces'), tr = spec.traces; end
    nTr = 0;
    if ~isempty(tr)
        for k = 1:numel(tr)
            pts = double(tr(k).points_m)*uFac;             %#ok<AGROW>
            if size(pts,1) < 2, continue; end
            pl = plot3(ax, pts(:,1), pts(:,2), pts(:,3), '-', 'Color', [0.10 0.10 0.10], ...
                'LineWidth', 1.4, 'DisplayName', traceName(tr(k), uLab));
            ud = userDataField(spec, spec.field, uFac, nRes);
            ud.kind = 'trace';
            if isfield(tr(k),'eventID'),      ud.eventID = tr(k).eventID;      end
            if isfield(tr(k),'seed'),         ud.seed = tr(k).seed;            end
            if isfield(tr(k),'schematic'),    ud.schematic = logical(tr(k).schematic); end
            if isfield(tr(k),'gasPath_um'),   ud.gasPath_um = tr(k).gasPath_um; end
            set(pl,'UserData',ud);
            hs(end+1) = pl; %#ok<AGROW>
            names{end+1} = get(pl,'DisplayName'); %#ok<AGROW>
            nTr = nTr + 1;
        end
    end
    schem = true;
    if ~isempty(tr) && numel(tr) > 0 && isfield(tr(1),'schematic'), schem = logical(tr(1).schematic); end
    if nTr == 0
        txt = sprintf(['overlay: NOT_VISUALIZED — 没有传入轨迹 (EventBatch 无 step 级数据); ' ...
            '解析基线的可用证据只有 seed+eventID 的弦端点 (tepc.geometry.traceSpec)']);
    elseif schem
        txt = sprintf('overlay: 示意轨迹 (SCHEMATIC — NOT 输运真值), n=%d', nTr);
    else
        txt = sprintf('overlay: 输运层轨迹 (n=%d), 非 step 级真值时同样须标 SCHEMATIC', nTr);
    end
    ann = text(ax, 0.02, 0.02, txt, 'Units','normalized', 'Color',[0.65 0 0], ...
        'FontWeight','bold', 'BackgroundColor', [1 1 1], 'EdgeColor', [0.65 0 0], ...
        'Interpreter','none');
    set(ann,'UserData', struct('kind','watermark','schematic',schem,'n_traces',nTr, ...
        'fieldTopology',char(spec.fieldTopology),'units','SI','display_units',uLab));
    hs(end+1) = ann; %#ok<AGROW>
end

%% 视角 / 光照 / 图例 (固定: 证据图可逐字节复核)
view(ax, double(a.Camera(:)).');
if ownFigure
    try
        camlight(ax, 'headlight');
        lighting(ax, 'gouraud');
    catch
        % uifigure 的 UIAxes 在某些后端不支持 camlight: 证据图仍可用 (仅少高光),
        % 这里不静默 —— 把状态写进 UserData 供测试/审计读取。
        set(ax, 'UserData', struct('camlight','UNSUPPORTED_ON_HOST'));
    end
else
    try
        lighting(ax,'gouraud'); camlight(ax,'headlight');
    catch
        set(ax, 'UserData', struct('camlight','UNSUPPORTED_ON_HOST'));
    end
end
if isempty(env)
    error("tepc:geometry:NothingToDraw","零件表为空, 无法出图 (不返回空图冒充成功)");
end
lo = min(env,[],1); hi = max(env,[],1);
pad = 0.03*max(hi-lo, eps);
axis(ax, [lo(1)-pad(1) hi(1)+pad(2), lo(2)-pad(2) hi(2)+pad(2), lo(3)-pad(3) hi(3)+pad(3)]);
lg = legend(ax, 'show');
% 图例条目里是枚举标识符 (transport_role 的 enter_mc / mc_choice 等), TeX 会把 '_'
% 排成下标, 读者照图抄回代码的名字就是错的; 图例里没有需要排版的宏, 所以整条走 none。
lg.Interpreter = 'none';
lg.Location = 'southoutside';
lg.NumColumns = 2;
lg.FontSize = 7;
% 3D 标题被排在 axes 内框顶之上约 1.32 倍内框高处; 按默认内框 (下沿 0.328、高 0.616) 算,
% 标题落在图坐标 y≈870 而画幅只有 760 高 ⇒ 标题从未被渲染 (实测: 标题开/关两张导出图零像素差)。
% 让出顶部空间 (下沿 0.30、高 0.44 ⇒ 标题顶 ≈707) 后两行标题才真的出现在 PNG 里。
% 只对经典 figure 宿主做: GUI 的 UIAxes 由 uigridlayout 定位, 这里写 Position 会被重排吃掉。
% 图加高不解决问题 —— 标题的绝对偏移随内框高度同比放大 (y ≈ 1.14*H), H 越大越出去。
if isa(ax, 'matlab.graphics.axis.Axes')
    ip = ax.Position;
    ax.Position = [ip(1) 0.30 ip(3) 0.44];
end
set(ax, 'Box','on');
try, set(ax,'Projection','perspective'); catch, end

%% 审计状态: 缺溯源就不可能声称"3D 已验证"
ax.UserData = struct('kind','tepc_geometry_3d','view',viewKind,'display_units',uLab, ...
    'unit_factor_from_m',uFac,'resolution_n',nRes,'camera',double(a.Camera(:)).', ...
    'cut_plane',char(string(a.CutPlane)), ...
    'geometryType',char(spec.geometryType),'electrodeTopology',char(spec.electrodeTopology), ...
    'fieldTopology',char(spec.fieldTopology),'topology',char(spec.fieldTopology), ...
    'auditComplete',logical(spec.auditComplete),'sha256Source',char(spec.sha256Source), ...
    'sourceConfigSha256',char(spec.sourceConfigSha256),'geometrySha256',char(spec.geometrySha256), ...
    'provenance_status', provenanceStatus(spec), ...
    'n_objects', numel(hs),'n_rng_calls_declared', 0);
if ownFigure
    fig.UserData = ax.UserData;
    set(fig,'HandleVisibility','on');
    h = fig;
else
    h = ax;
end
end

%% ==================== 局部函数 ====================

function s = provenanceStatus(spec)
% provenance 缺任一项 => 3D_NOT_AUDITED (不得显示"3D 已验证")。
if isfield(spec,'auditComplete') && logical(spec.auditComplete)
    s = 'PROVENANCE_PRESENT';
else
    s = '3D_NOT_AUDITED';
end
end

function ud = userDataField(spec, aF, uFac, nRes)
ud = struct('kind','analytic_field_sample','units','SI','display_units', ...
    char(string(sprintf('%g',uFac))),'unit_factor_from_m',uFac, ...
    'field_kind',char(aF.kind),'p',aF.p,'K',aF.K,'clip_m',double(aF.clip_m), ...
    'resolution_n',nRes,'topology',char(spec.fieldTopology), ...
    'electrodeTopology',char(spec.electrodeTopology), ...
    'geometryType',char(spec.geometryType), ...
    'sourceConfigSha256',char(spec.sourceConfigSha256), ...
    'geometrySha256',char(spec.geometrySha256), ...
    'note','值来自 meshSpec 里 tepc.detector.fieldModel 的解析采样; 图形层不求解场');
ud.display_units = 'see unit_factor_from_m';
end

function c = partColors()
% 固定色表 (不用 colormap/randperm; 色盲友好: 只用可区分明度 + 图例文字)
c = struct('gas_cavity',   [0.90 0.78 0.32], ...
           'wall',         [0.45 0.55 0.62], ...
           'cathode',      [0.20 0.35 0.55], ...
           'anode',        [0.75 0.22 0.22], ...
           'world_envelope',[0.80 0.80 0.80], ...
           'equivalent_site_realized', [0.20 0.60 0.30], ...
           'equivalent_site_requested',[0.55 0.85 0.60], ...
           'source_cone',  [0.60 0.35 0.65]);
end

function v = colFor(col, id)
if isfield(col, id), v = col.(id); else, v = [0.4 0.4 0.4]; end
end

function al = alphaForView(id, viewKind)
% 内外两张皮成对给不同透明度 (同材质不透明会把壁误当气体)。
switch id
    case 'gas_cavity'
        if viewKind == "exploded", al = 0.55; else, al = 0.30; end
    case 'wall'
        if viewKind == "exploded", al = 0.85; else, al = 0.18; end
    case 'cathode'
        al = 0.06;                                % 共面皮: 几乎只留描边
    case 'anode'
        al = 0.95;
    case 'world_envelope'
        al = 0.04;
    case 'equivalent_site_realized'
        al = 0.75;
    case 'equivalent_site_requested'
        al = 0.25;
    case 'source_cone'
        al = 0.20;
    otherwise
        al = 0.5;
end
end

function s = edgeColorFor(id, viewKind)
if strcmp(id,'cathode') && viewKind ~= "exploded", s = [0.20 0.35 0.55];
elseif strcmp(id,'world_envelope'), s = [0.70 0.70 0.70];
else, s = 'none';
end
end

function tf = drawEdgeOverlay(id, viewKind)
% 阴极与气腔重合: 只画边不铺第二层透明面 (共面会闪烁/显出假孔洞)。
tf = strcmp(id,'cathode') && viewKind ~= "exploded";
end

function s = legendFor(P, uLab, spec)
% 图例把单位与两个拓扑层都写出来 (敏感体积 vs 场拓扑)。
extra = '';
switch P.part_id
    case 'equivalent_site_realized'
        extra = sprintf(' | realised d_t = %.4f um', spec.realizedDiameter_um);
    case 'equivalent_site_requested'
        extra = sprintf(' | requested d_t = %.4f um', spec.requestedDiameter_um);
    case 'gas_cavity'
        extra = sprintf(' | transport: enter_mc (lbar = 4V/S = %.1f um)', spec.lbar_gas_um);
    case 'wall'
        extra = sprintf(' | t = %.2f mm | transport: energy-loss table only', ...
            spec.wallThickness_mm);
    case 'anode'
        extra = sprintf(' | r = %.1f um | %s', spec.anodeRadius_um, char(spec.anodeType));
    case 'world_envelope'
        extra = ' | >= 5x bbox (display/adapter envelope, not used by analytic transport)';
    case 'source_cone'
        % 状态跟着 spec.source.status 走: 写死 ASSUMED 会在配置已供数时仍标成假定值。
        % 状态词之外还必须写"只是显示": 图例是读三维的人唯一会看的一行, 只写状态会让人
        % 以为改了方向就会改输运角分布 (解析基线的入射角分布始终是各向同性外源弦)。
        extra = sprintf(' | direction & half-angle %s (display only; transport stays isotropic)', ...
            char(spec.source.status));
end
s = sprintf('%s [%s]%s', char(P.label), char(P.transport_role), extra);
if ~isempty(uLab), s = [s sprintf(' (/ %s)', uLab)]; end
end

function s = traceName(tr, uLab)
s = 'trace';
if isfield(tr,'eventID'), s = sprintf('%s eventID=%d', s, tr.eventID); end
if isfield(tr,'kind'),    s = sprintf('%s %s', s, char(string(tr.kind))); end
if isfield(tr,'gasPath_um')
    s = sprintf('%s gasPath=%.3f um', s, tr.gasPath_um);
end
if isfield(tr,'schematic') && logical(tr.schematic)
    s = sprintf('%s [SCHEMATIC]', s);
end
s = sprintf('%s (/ %s)', s, uLab);
end
