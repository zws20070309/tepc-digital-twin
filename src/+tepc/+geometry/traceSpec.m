function tr = traceSpec(cfg, R, eventIDs, varargin)
%TRACESPEC 种子化轨迹服务 (输运/几何层, **不是**图形层)。
%
%   tr = traceSpec(cfg, R, [1 2 3])                 % 默认 seed = cfg.provenance.seed
%   tr = traceSpec(cfg, R, eventIDs, 'Seed', s)     % 显式 seed
%   tr = traceSpec(cfg, R, eventIDs, 'Ledger', L)   % L.gasPath_um / L.flags / L.collinear
%
% 为什么单独一个函数: 轨迹叠加的数据生成必须在输运层做种子化服务, 图形层不得含任何
% 随机数。renderTEPC3D 只**消费**本函数返回的 struct 数组; 所有抽样 (RandStream) 只
% 发生在这里。
%
% 可复现锚定 (与 tepc.transport.AnalyticAdapter 逐字同一套流构造):
%   AnalyticAdapter 主循环里那三行 (按符号定位, 不按行号 —— 行号会在别人插注释之后漂移,
%   这一处就漂过 12 行: 原先写 :50-51 时真实位置已在 :62-63):
%     rsE = RandStream('Threefry','Seed',seed); rsE.Substream = eid
%     [~,Pin,Pout] = sampleChord(geom,1,"isotropic_external",rsE)   (中子/光子两条分支各一处)
%   => 同一 (seed, eventID) 必然给出**逐位相同**的弦端点, 与分块大小/续跑/并行无关。
%   图上画的与账本算的是同一条弦, 不是"看着像"。
%
% 诚实边界 (不要拿本函数当 step 级轨迹):
%   events.h5 / tepc.domain.EventBatch 只有积分后的 gasPath_um, 没有逐步位置
%   (preallocate 的列里无 points/steps) => 每条 trace 只有入射弦的两个端点, 且
%   schematic 字段恒为 true, 图形层据此打"示意轨迹"水印, 不得称输运真值。
%
% 逐事件门禁:
%   共线事件 (径迹就在入射弦上, 如 gamma 光电分支: gasPath = 弦上作用距离):
%     (1) gasPath_um <= ‖Pout-Pin‖ + tol
%     (2) 若 flags 含 WALL_LOSS 或 ESCAPE (粒子穿出气腔) => 必须**取等号**
%   非共线事件 (中子弹性反冲核、康普顿电子: 诞生点在体内、方向另起一条线):
%     弦长不是它的上界 —— 用凸体内最紧的闭式上界: 球 = 直径 2R, 有限圆柱 = 面对角线
%     sqrt(H^2+(2R)^2)。在此如实区分, 而不是把一条物理上不成立的"不等式"当门禁。
%   违反 => error('tepc:geometry:TraceInequality') (门禁可失败)。
%
% 返回 tr (struct 数组, 坐标一律 SI 米):
%   eventID seed pin_m pout_m points_m(2x3) chord_um gasPath_um flags collinear
%   bound_um bound schematic kind gasPathSource

p = inputParser;
p.addParameter('Seed', []);
p.addParameter('Ledger', []);
p.addParameter('TolUm', 1e-9);
p.parse(varargin{:});
a = p.Results;

seed = a.Seed;
if isempty(seed)
    if ~isfield(cfg,'provenance') || ~isfield(cfg.provenance,'seed') || isempty(cfg.provenance.seed)
        error("tepc:geometry:NoSeed","traceSpec 需要 seed: cfg.provenance.seed 缺失且未显式给");
    end
    seed = cfg.provenance.seed;
end
if ~(isscalar(seed) && isfinite(seed) && seed >= 0)
    error("tepc:transport:BadSeed","seed 必须是非负有限标量, 实得 %s", mat2str(seed));
end
seedU = uint32(round(seed));

eventIDs = double(eventIDs(:));
if isempty(eventIDs), error("tepc:geometry:NoEvents","eventIDs 为空"); end
if any(eventIDs ~= round(eventIDs)) || any(eventIDs < 1)
    error("tepc:geometry:BadEventID","eventID 必须是 >=1 的整数 (实得 %s)", mat2str(eventIDs));
end

geom = R.geom;
tol = abs(double(a.TolUm));
L = a.Ledger;
hasLedger = ~isempty(L);
if hasLedger
    if ~isfield(L,'gasPath_um')
        error("tepc:geometry:BadLedger","Ledger 需要 gasPath_um 列 (events.h5 同名)");
    end
    if numel(L.gasPath_um) ~= numel(eventIDs)
        error("tepc:geometry:LedgerSize","Ledger 条数 %d != eventIDs 条数 %d", ...
            numel(L.gasPath_um), numel(eventIDs));
    end
end
maxTrack_m = maxChordBound(geom);              % 非共线径迹的闭式最紧上界

tr = repmat(emptyRow(), 1, numel(eventIDs));
for k = 1:numel(eventIDs)
    eid = eventIDs(k);
    rsE = RandStream('Threefry', 'Seed', seedU);
    rsE.Substream = eid;                       % 与 AnalyticAdapter 同一锚定
    [Lc, Pin, Pout] = tepc.geometry.sampleChord(geom, 1, "isotropic_external", rsE);
    pin = double(Pin(:,1)); pout = double(Pout(:,1));
    if ~(all(isfinite(pin)) && all(isfinite(pout)))
        error("tepc:geometry:BadChord","eventID %d 的弦端点非有限", eid);
    end
    chord_um = norm(pout - pin)*1e6;           % 1 m = 1e6 um (显式系数)
    if ~(chord_um > 0)
        error("tepc:geometry:ZeroChord","eventID %d 的弦长为 0 (退化抽样)", eid);
    end
    if abs(chord_um - double(Lc(1))*1e6) > tol
        error("tepc:geometry:ChordMismatch", ...
            "eventID %d: ‖Pout-Pin‖ 与 sampleChord 返回的 L 不一致 (%.9g vs %.9g um)", ...
            eid, chord_um, double(Lc(1))*1e6);
    end

    row = struct('eventID',eid,'seed',seedU,'pin_m',pin.', 'pout_m',pout.', ...
        'points_m',[pin.'; pout.'],'chord_um',chord_um,'gasPath_um',chord_um, ...
        'flags',uint32(0),'collinear',true,'bound_um',chord_um,'bound','chord', ...
        'schematic',true,'kind','incident_chord','gasPathSource','chord_only');
    if hasLedger
        g = double(L.gasPath_um(k));
        fl = uint32(0);
        if isfield(L,'flags') && ~isempty(L.flags), fl = uint32(L.flags(k)); end
        col = true;
        if isfield(L,'collinear') && ~isempty(L.collinear), col = logical(L.collinear(k)); end
        if col
            bound = chord_um; bname = 'chord';
        else
            bound = maxTrack_m*1e6; bname = 'convex_max_chord';
        end
        checkInequality(eid, g, fl, col, chord_um, bound, tol);
        row.gasPath_um = g;
        row.flags = fl;
        row.collinear = col;
        row.bound_um = bound;
        row.bound = bname;
        row.kind = 'ledger_gaspath_on_incident_chord';
        row.gasPathSource = 'ledger';
    end
    tr(k) = row;
end
end

%% ==================== 局部函数 ====================

function r = emptyRow()
r = struct('eventID',{},'seed',{},'pin_m',{},'pout_m',{},'points_m',{},'chord_um',{}, ...
    'gasPath_um',{},'flags',{},'collinear',{},'bound_um',{},'bound',{},'schematic',{}, ...
    'kind',{},'gasPathSource',{});
end

function b = maxChordBound(geom)
% 凸体内**任意**一条径迹的长度上界 (闭式, 紧):
%   球: 直径 2R; 有限圆柱: 过轴的 diagonal sqrt(H^2 + (2R)^2); 其他: 包络直径。
switch lower(string(geom.type))
    case "sphere"
        b = 2*geom.R_m;
    case "cylinder_finite"
        R = geom.R_m;
        H = 2*sqrt(max(geom.bboxR_m^2 - R^2, 0));
        b = sqrt(H^2 + (2*R)^2);
    otherwise
        b = 2*geom.bboxR_m;
end
end

function checkInequality(eid, g, fl, col, chord_um, bound_um, tol)
if ~isfinite(g) || g < 0
    error("tepc:geometry:TraceInequality", ...
        "eventID %d: gasPath_um 必须有限非负 (实得 %g)", eid, g);
end
if g > bound_um + tol
    error("tepc:geometry:TraceInequality", ...
        ['eventID %d: gasPath_um %.9g > 上界 %.9g + tol (bound=%s)。共线径迹的上界是弦长 ' ...
         'norm(Pout-Pin), 非共线次级粒子的上界是凸体最大弦 -- 两者都违反说明账本或' ...
         '几何不一致'], eid, g, bound_um, tern(col,'chord','convex_max_chord'));
end
F = tepc.domain.Flags();
exited = bitand(fl, F.WALL_LOSS) ~= 0 || bitand(fl, F.ESCAPE) ~= 0;
if col && exited && abs(g - chord_um) > tol
    error("tepc:geometry:TraceInequality", ...
        ['eventID %d: 事件带 WALL_LOSS|ESCAPE 却未取等号: gasPath_um %.9g != 弦长 %.9g ' ...
         '(差 %.3e um > tol %.3e)。穿出气腔的共线径迹必须在边界处结束'], ...
        eid, g, chord_um, abs(g-chord_um), tol);
end
end

function s = tern(cond, a, b)
if cond, s = a; else, s = b; end
end
