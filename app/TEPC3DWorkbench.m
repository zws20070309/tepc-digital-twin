function fig = TEPC3DWorkbench(varargin)
%TEPC3DWORKBENCH 两级三维审计工作台 (显示层真剖切 + 七视角 + 零件显隐 + 公差蒙卡).
%
%   fig = tepc.app.TEPC3DWorkbench()                 % 用 config/defaults/demo_only.json
%   fig = tepc.app.TEPC3DWorkbench(cfgStruct)         % 传已装载的配置
%   fig = tepc.app.TEPC3DWorkbench('path/to.json')    % 传配置路径
%   fig = tepc.app.TEPC3DWorkbench(cfg, 'Visible', false, 'Unique', true)
%
% 三条设计约束 (都是可核对的行为, 不是口号):
%   1) 剖切只发生在显示层。几何真相源是 meshSpec 的零件表; 本文件把 clipVolume 的结果
%      只喂给 patch 的顶点/面。体积/面积/弦长读数一律取 spec 的审计字段 (auditV/auditS/
%      auditL/audit4V), 从不因剖切/显隐/比例而重算, 所以切与不切同一套数 —— 这是"显示
%      层不变量"的结构保证。画布在真剖切生效时永久标注 "DISPLAY CLIP — 输运几何未变"。
%      生效与否逐零件判 (cut / plane-misses-part / failed), 判据是 clipVolume 的 stats
%      (面数变化 / 盖面数 / plane_misses_part / closed_after), 不是 display_only 恒真标志;
%      patch 的 UserData.display_only 也只在该零件自己被切开时为 true。
%   2) 示意比例 (对数实体尺度) 只改显示: 一旦开启就必须显示 NOT TO SCALE 水印, 且没有
%      单独关闭水印的入口 (退出示意档才会消失); 真实比例是默认档。
%   3) 零随机数: 本文件不含 rand/rng。公差蒙卡的随机流由本文件显式建的 RandStream 决定
%      (固定 seed, 同一次跑逐位可复现), 结果连同 seed 回显。
%
% 单位纪律: spec 内部恒 SI (米)。mm = 1e3, um = 1e6 只在显示坐标与两点测距换算里出现。
%
% 返回 uifigure 句柄, 便于自动化测试用 findall 按属性读回状态 (不靠截图判对错);
% 同时把控件句柄、审计结构体与动作句柄放进 setappdata(fig,'wb',...) 供 headless 驱动。

    if nargin < 1, varargin = {}; end
    args = varargin;

    % ---- 入参解析: 位置参数只可能是 cfg / 配置路径, 其余按 name-value 收 ----
    % 不用 inputParser 的 addOptional(cfg): 那样首个 'Visible' 字符串会被误吞成 cfg。
    cfgIn = [];
    rest = {};
    if ~isempty(args)
        a0 = args{1};
        if isstruct(a0)
            cfgIn = a0; rest = args(2:end);
        elseif (ischar(a0) || (isstring(a0) && isscalar(a0))) && isfile(string(a0))
            cfgIn = tepc.config.load(char(string(a0))); rest = args(2:end);
        else
            rest = args;
        end
    end
    visArg = true; uniq = true;
    for i = 1:2:numel(rest)
        switch lower(char(string(rest{i})))
            case 'visible', visArg = rest{i+1};
            case 'unique',  uniq = logical(rest{i+1});
        end
    end
    if islogical(visArg)
        if visArg, visChar = 'on'; else, visChar = 'off'; end
    else
        visChar = char(string(visArg));
    end

    root = tepc.io.projectRoot();
    if isempty(cfgIn)
        cfgIn = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
    end

    % ---- 几何真相源: 只走 meshSpec 这一个入口, 本文件不含任何几何公式 ----
    Rcfg = tepc.config.resolve(cfgIn);
    spec = tepc.geometry.meshSpec(cfgIn, Rcfg, "");
    parts = spec.parts;
    nPart = numel(parts);
    ids = cell(1, nPart);
    for k = 1:nPart
        ids{k} = char(string(fieldOr(parts(k), 'part_id', sprintf('part%d', k))));
    end

    % 审计量: 从 spec 的解析字段读一次, 之后所有读数都由它生成 (与显示无关)。
    audit = struct( ...
        'V_m3',              double(spec.V_m3), ...
        'S_m2',              double(spec.S_m2), ...
        'lbar_gas_m',        double(spec.lbar_gas_m), ...
        'meanChord_4V_over_S_m', double(spec.meanChord_4V_over_S_m));

    % ---- 窗口 (先收掉上一台同种工作台, 再开新的; Unique=false 时允许多开) ----
    if uniq
        prior = existingWorkbenches();
        for i = 1:numel(prior)
            try, delete(prior(i)); catch, end
        end
    end
    token = char(string(datetime('now', 'Format', 'HHmmssSSS')));
    fig = uifigure('Name', sprintf('wb6_%s — TEPC 三维审计工作台', token), ...
        'Visible', visChar, 'Position', [80 80 1300 800], ...
        'Color', [0.965 0.969 0.980], 'CloseRequestFcn', @(~,~) closeNow());
    setappdata(fig, 'tepcWorkbench', true);

    gl = uigridlayout(fig, [1 3]);
    gl.ColumnWidth = {310, '1x', 360};
    gl.RowHeight = {'1x'};

    % ================= 左: 零件显隐 / 单位 / 比例 / 剖切 / 测距 =================
    left = uipanel(gl, 'Title', '零件与显示');
    nRow = nPart + 10;
    % 第 1 列按内容自适应 ('fit'): 零件 id 最长 25 字符, 固定列宽下去掉省略号只会换成静默
    % 裁切, 缺陷没修掉。第 2 列吃剩余宽度。本机不接受 'auto' (MATLAB:ui:GridLayout:unknownInput)。
    lg = uigridlayout(left, [nRow, 2], 'Padding', 6, 'RowSpacing', 4, ...
        'ColumnWidth', {'fit', '1x'});
    lg.RowHeight = repmat({24}, [nRow, 1]);
    lg.RowHeight{nRow - 1} = 60;
    % 剖切状态行要装下逐零件三态判定 (cut / plane-misses-part / failed), 单行放不下。
    lg.RowHeight{nRow - 3} = 132;

    % 控件定位统一走"先创建, 再设 .Layout.Row/.Column" (与 TEPCApp 同法): uilabel 在构造
    % 参数里给 'Row'/'Column' 会被判"Row 不是 Label 的属性"直接抛错。
    cbParts = gobjects(nPart, 1);
    for k = 1:nPart
        role = char(string(fieldOr(parts(k), 'transport_role', '—')));
        mode = char(string(fieldOr(parts(k), 'transport_mode', '—')));
        c = uilabel(lg, 'Text', ids{k});
        % id 原样上屏: 屏上的标识符要能逐字抄回代码。切开 (带 '…') 的名字不是任何合法 part_id,
        % 而"实现位点/请求位点"这类语义对立的键名一旦被截断, 读者只能靠猜。
        c.Layout.Row = k; c.Layout.Column = 1;
        cbParts(k) = uicheckbox(lg, 'Text', trimTo([role '/' mode], 16), 'Value', true);
        cbParts(k).Layout.Row = k; cbParts(k).Layout.Column = 2;
        cbParts(k).ValueChangedFcn = @(~,~) redraw();
    end

    r0 = nPart + 1;
    c = uilabel(lg, 'Text', '单位'); c.Layout.Row = r0; c.Layout.Column = 1;
    uu = uidropdown(lg, 'Items', {'mm', 'um'}, 'Value', 'mm');
    uu.Layout.Row = r0; uu.Layout.Column = 2;
    uu.ValueChangedFcn = @(~,~) redraw();

    c = uilabel(lg, 'Text', '爆炸位移'); c.Layout.Row = r0+1; c.Layout.Column = 1;
    spEx = uispinner(lg, 'Limits', [0 1], 'Value', 0, 'Step', 0.1);
    spEx.Layout.Row = r0+1; spEx.Layout.Column = 2;
    spEx.ValueChangedFcn = @(~,~) redraw();

    c = uilabel(lg, 'Text', '示意比例(对数)'); c.Layout.Row = r0+2; c.Layout.Column = 1;
    cbSchem = uicheckbox(lg, 'Text', '开启后强制水印', 'Value', false);
    cbSchem.Layout.Row = r0+2; cbSchem.Layout.Column = 2;
    cbSchem.ValueChangedFcn = @(~,~) redraw();

    c = uilabel(lg, 'Text', '真剖切(仅显示层)'); c.Layout.Row = r0+3; c.Layout.Column = 1;
    cbClip = uicheckbox(lg, 'Text', '切开并补盖面', 'Value', false);
    cbClip.Layout.Row = r0+3; cbClip.Layout.Column = 2;
    cbClip.ValueChangedFcn = @(~,~) redraw();

    c = uilabel(lg, 'Text', '切面法向'); c.Layout.Row = r0+4; c.Layout.Column = 1;
    ddN = uidropdown(lg, 'Items', {'x', 'y', 'z'}, 'Value', 'x');
    ddN.Layout.Row = r0+4; ddN.Layout.Column = 2;
    ddN.ValueChangedFcn = @(~,~) redraw();

    c = uilabel(lg, 'Text', '切面偏距 d/R'); c.Layout.Row = r0+5; c.Layout.Column = 1;
    edD = uieditfield(lg, 'numeric', 'Value', 0, 'LowerLimit', -0.98, 'UpperLimit', 0.98);
    edD.Layout.Row = r0+5; edD.Layout.Column = 2;
    edD.ValueChangedFcn = @(~,~) redraw();

    clipNote = uilabel(lg, 'Text', '剖切状态: 未启用', 'FontColor', [0.30 0.34 0.40], 'WordWrap', 'on');
    clipNote.Layout.Row = r0+6; clipNote.Layout.Column = [1 2];

    % 动态范围提示 + 两点测距 (mm 级气腔与 um 级阳极不能同屏 1:1 看清)。
    c = uilabel(lg, 'Text', '两点测距 (当前单位)');
    c.Layout.Row = r0+7; c.Layout.Column = [1 2];
    edMeas = uieditfield(lg, 'text', 'Value', '0 0 0 25.4 0 0');
    edMeas.Layout.Row = r0+8; edMeas.Layout.Column = [1 2];
    btnMeasure = uibutton(lg, 'Text', '测距', 'ButtonPushedFcn', @(~,~) runMeasureFromField());
    btnMeasure.Layout.Row = r0+9; btnMeasure.Layout.Column = 1;
    resetBtn = uibutton(lg, 'Text', '复位真实比例', 'ButtonPushedFcn', @(~,~) resetView());
    resetBtn.Layout.Row = r0+9; resetBtn.Layout.Column = 2;

    % ================= 中: 三维视口 + 七预设 =================
    mid = uipanel(gl, 'Title', '三维视口');
    % 4 行: 相机预设 / 投影与取景按钮 / **两条状态文字各占自己的行** / 视口(拉伸)。
    % 旧版 3 行里 labProj 与 labFit 挤在按钮那一行 (30 px), 而它们的文案是 2~4 行折行 ——
    % 实测"取景: …零件最长边 155.4, 中" 之后的半句直接看不见
    % (证据 _工作底稿/截图/workbench_after_funcs.png)。抬整行会让下拉框与按钮变成 80 px 高,
    % 所以改成给状态行单独一行 (56 px) 并把两列各扩到 3 列宽, 折行数随之下降。
    mg = uigridlayout(mid, [4, 7], 'Padding', 4, 'RowSpacing', 2);
    mg.RowHeight = {30, 30, 56, '1x'};
    mg.ColumnWidth = repmat({'1x'}, [1, 7]);

    views = {'等轴', '前', '后', '左', '右', '顶', '底'};
    % 七个 (az, el) 两两不同: 相同 (az,el) 的两个预设点下去不会改相机, "七视角"就成了假话。
    cams  = {[37.5 30], [0 0], [180 0], [-90 0], [90 0], [0 90], [0 -90]};
    btnCam = gobjects(1, numel(views));
    for i = 1:numel(views)
        b = uibutton(mg, 'Text', views{i}, 'ButtonPushedFcn', @(~,~) setCam(i));
        b.Layout.Row = 1; b.Layout.Column = i;
        btnCam(i) = b;
    end
    % 相机第二维: 投影方式 + 放大取景。七个预设只改 (az,el), 既不能正交/透视切换,
    % 也不会把视野收到零件上 (mm 腔与 µm 丝同屏时零件只占几个像素, 只能靠缩轴范围看)。
    ddProj = uidropdown(mg, 'Items', {'正交', '透视'}, 'Value', '正交', ...
        'ValueChangedFcn', @(s, ~) setProj(s.Value));
    ddProj.Layout.Row = 2; ddProj.Layout.Column = [1 2];
    btnFit = uibutton(mg, 'Text', '放大取景', 'ButtonPushedFcn', @(~,~) zoomFit());
    btnFit.Layout.Row = 2; btnFit.Layout.Column = 3;
    labProj = uilabel(mg, 'Text', '投影: 正交 (工程图口径, 无近大远小)', ...
        'FontColor', [0.30 0.34 0.40], 'WordWrap', 'on');
    labProj.Layout.Row = 3; labProj.Layout.Column = [1 3];
    labFit = uilabel(mg, 'Text', '取景: 未调整 (视野按零件包围盒定级)', ...
        'FontColor', [0.30 0.34 0.40], 'WordWrap', 'on');
    labFit.Layout.Row = 3; labFit.Layout.Column = [4 7];
    ax = uiaxes(mg);
    ax.Layout.Row = 4;
    ax.Layout.Column = [1 7];
    grid(ax, 'on'); box(ax, 'on');
    hold(ax, 'on');

    % ================= 右: 审计同源读数 + 工程审计 =================
    right = uipanel(gl, 'Title', '审计读数 (与显示无关)');
    % 13 行: 最后一个是导出/动作状态行。导出提示必须有自己的一行 —— 早先借道 labTol,
    % 点一次导出就把公差蒙卡的结果整段冲掉。
    % 行高是**预算出来的**, 不是各行凑数字: 13 行之和 + 12*4 行距 + 2*8 内边边距必须 <= 窗口
    % 可用高度。旧值之和 782 (+48+16 = 846) 超出 800 高窗口里 rg 的可用 753 px 约 91 px,
    % 于是第 12 行 (导出按钮) 只剩 2 px 可见、第 13 行 (导出状态) **整行在窗口外** ——
    % 实测见 _工作底稿/截图/workbench_after_funcs.png (1300x800)。
    % 重分配的依据是同一张图里逐行量到的实占: row2 用 48 (声明 108)、row3 35 (80)、
    % row7 39 (126)、row8 11 (76)、row9 41 (86) —— 死余量约 300 px, 不必放大窗口就能腾出:
    % row5 干涉审计从 96 抬到 150 (最坏 9 行折行, 旧值把末行字形水平切掉一半),
    % row13 状态行回到窗内。总和 668 (+48+16 = 732) <= 753。
    rg = uigridlayout(right, [13, 1], 'Padding', 8, 'RowSpacing', 4);
    rg.RowHeight = {30, 64, 48, 26, 150, 26, 96, 44, 56, 28, 28, 28, 44};
    c = uilabel(rg, 'Text', '审计量 (与剖切/显隐/比例无关)', 'FontColor', [0.10 0.28 0.44]);
    c.Layout.Row = 1; c.Layout.Column = 1;
    labAudit = uilabel(rg, 'Text', '', 'WordWrap', 'on', 'VerticalAlignment', 'top');
    labAudit.Layout.Row = 2; labAudit.Layout.Column = 1;
    labAudit.FontSize = 11;
    labTopo = uilabel(rg, 'Text', '', 'WordWrap', 'on', 'FontSize', 10);
    labTopo.Layout.Row = 3; labTopo.Layout.Column = 1;
    c = uilabel(rg, 'Text', '干涉 / 间隙审计', 'FontColor', [0.10 0.28 0.44]);
    c.Layout.Row = 4; c.Layout.Column = 1;
    labInterf = uilabel(rg, 'Text', '干涉审计: 未运行', 'WordWrap', 'on');
    labInterf.Layout.Row = 5; labInterf.Layout.Column = 1;
    c = uilabel(rg, 'Text', '公差蒙特卡洛', 'FontColor', [0.10 0.28 0.44]);
    c.Layout.Row = 6; c.Layout.Column = 1;
    labTol = uilabel(rg, 'Text', '公差蒙卡: 未运行', 'WordWrap', 'on');
    labTol.Layout.Row = 7; labTol.Layout.Column = 1;
    labMeasure = uilabel(rg, 'Text', '两点测距: 未测', 'WordWrap', 'on');
    labMeasure.Layout.Row = 8; labMeasure.Layout.Column = 1;
    labScale = uilabel(rg, 'Text', dynamicRangeNote(spec), 'WordWrap', 'on', 'FontColor', [0.55 0.20 0.10]);
    labScale.Layout.Row = 9; labScale.Layout.Column = 1;
    btnI = uibutton(rg, 'Text', '运行干涉/间隙审计', 'ButtonPushedFcn', @(~,~) runInterference());
    btnI.Layout.Row = 10; btnI.Layout.Column = 1;
    btnT = uibutton(rg, 'Text', '运行公差蒙卡 (N=64)', 'ButtonPushedFcn', @(~,~) runTolerance());
    btnT.Layout.Row = 11; btnT.Layout.Column = 1;
    btnP = uibutton(rg, 'Text', '导出当前视图 PNG', 'ButtonPushedFcn', @(~,~) exportShot());
    btnP.Layout.Row = 12; btnP.Layout.Column = 1;
    labStatus = uilabel(rg, 'Text', '视图导出: 未导出', 'WordWrap', 'on', ...
        'FontColor', [0.30 0.34 0.40]);
    labStatus.Layout.Row = 13; labStatus.Layout.Column = 1;

    % ---------------- 内部状态与动作 ----------------
    % state 是显示层自身的事实 (哪个零件被判成 cut/misses/failed、当前控件档位), 与 audit
    % 严格分开: audit 恒取 spec 的解析字段, 永不因显示层动作改变。
    state = struct('cam', {[37.5 30]}, 'clipErr', '', 'clipped', false, ...
        'clip', emptyClipState(), 'interf', [], 'interfErr', '', 'tol', [], 'tolErr', '', ...
        'measure', [], 'units', 'mm', 'schematic', false, 'explode', 0, 'plane', 'x', ...
        'overr', 0, 'clipRequested', false, 'exportPath', '', 'exportErr', '', ...
        'interfRuns', 0);

    wb = struct();
    wb.fig = fig; wb.ax = ax; wb.parts = parts; wb.ids = ids; wb.spec = spec;
    wb.audit = audit; wb.cfg = cfgIn;
    wb.cbParts = cbParts; wb.uu = uu; wb.spEx = spEx; wb.cbSchem = cbSchem;
    wb.cbClip = cbClip; wb.ddN = ddN; wb.edD = edD; wb.edMeas = edMeas;
    wb.btnCam = btnCam; wb.btnI = btnI; wb.btnT = btnT; wb.btnP = btnP;
    wb.labAudit = labAudit; wb.labTopo = labTopo; wb.labClip = clipNote;
    wb.labMeasure = labMeasure; wb.labScale = labScale; wb.labInterf = labInterf;
    wb.labTol = labTol; wb.labStatus = labStatus;
    wb.ddProj = ddProj; wb.btnFit = btnFit; wb.labFit = labFit; wb.labProj = labProj;
    % api 里的 state/audit 必须是嵌套函数句柄: 匿名函数 @() state 在创建那一刻就把变量按值
    % 绑死了, 审计跑完后 api.state().tol 仍是开窗时的空值, 导出的就是陈旧数据。
    wb.api = struct( ...
        'redraw', @redraw, ...
        'setCam', @setCam, ...
        'resetView', @resetView, ...
        'measure', @measureDistance, ...
        'runInterference', @runInterference, ...
        'runTolerance', @runToleranceForTest, ...
        'audit', @auditLive, ...
        'state', @stateLive);
    setappdata(fig, 'wb', wb);

    state.fitN = 0;         % 放大取景级数 (复位归零): 第 n 级视野跨度 = 1.1x 零件最长边 / 2^(n-1)
    redraw();

    % ============ 嵌套动作 ============

    function setCam(i)
        % 七预设全部走 view(ax,[az el]) 一条路径: uiaxes 上混用 'tilted' 需要相机参数
        % 配套, 会让"等轴"与其它六个不可比。
        state.cam = cams{i};
        view(ax, state.cam);
        redraw();
    end

    function resetView()
        cbSchem.Value = false;
        spEx.Value = 0;
        cbClip.Value = false;
        uu.Value = 'mm';
        edD.Value = 0;
        view(ax, cams{1});
        state.cam = cams{1};
        % 复位必须把新加的两个自由度一起收回去: 否则"复位真实比例"只复位了一半,
        % 窗口上看着是复位了, 视野其实还停在放大过的正交取景里。
        state.fitN = 0;
        ddProj.Value = '正交';
        ax.Projection = 'orthographic';
        % 取景把轴范围置成了 manual, 不切回 auto 就永久停在被放大的那一段上。
        % 程序化写 ddProj.Value 不触发 ValueChangedFcn, 所以两行措辞都得在这儿自己写。
        ax.XLimMode = 'auto'; ax.YLimMode = 'auto'; ax.ZLimMode = 'auto';
        labProj.Text = projNote(ax.Projection);
        labFit.Text = '取景: 已复位 (级数 0, 视野回到自动包围)';
        redraw();
    end

    function setProj(v)
        s = lower(strtrim(string(v)));
        if s == "正交" || s == "orthographic"
            ax.Projection = 'orthographic';
        else
            ax.Projection = 'perspective';
        end
        labProj.Text = projNote(ax.Projection);
    end

    function t = projNote(mode)
        % 测距取的是坐标数值 (measureDistance), 与投影无关; 透视破坏的是"从画面上目测/
        % 拾取尺寸"这条路径 —— 措辞只能钉在真被破坏的东西上, 不能写成"透视不能测距"。
        if strcmp(mode, 'perspective')
            t = '投影: 透视 (近大远小: 屏幕上目测与拾取的位置不可当尺寸读)';
        else
            t = '投影: 正交 (工程图口径, 无近大远小)';
        end
    end

    function zoomFit()
        % 放大取景 = 级数 +1 后把视野落到零件上; 级数到视野的换算只在 applyFit 一处。
        state.fitN = state.fitN + 1;
        if ~applyFit()
            state.fitN = max(state.fitN - 1, 0);   % 没落成的那一级不留在状态里
            return
        end
        % 取景之后必须重出一遍画面: 比例尺的位置与长度都是从轴范围反推的 (drawScaleBar),
        % 只改轴范围不重画的话, 读数说视野已经减半而屏幕上的尺还停在上一级的跨度, 甚至会
        % 整条跑到新视野外面去。redraw 末尾按同一级重放取景, 所以两者不会打架。
        redraw();
    end

    function applied = applyFit()
        % 把第 state.fitN 级写进轴范围: 跨度 = 1.1 x 零件最长边 / 2^(级数-1), 中心 = 零件
        % 包围盒中心。基准必须是画出来的零件而不是当前轴范围 —— 隐藏窗口上 drawnow 会把
        % auto 轴范围打成默认 [0 1] (实测), 以轴范围为基准算出的倍数与零件无关。
        % 只写轴范围: 正交投影下缩范围即放大; 本机写 manual 轴范围会随之重算
        % CameraPosition (实测), 所以判据是轴范围跨度而不是相机坐标。
        applied = false;
        [ok, ctr, ext] = drawnPartCtr(ax);
        if ~ok
            % 零件全部隐藏或全部被切掉: 没有可取景的对象, 级数归零并交还自动包围。
            state.fitN = 0;
            axis(ax, 'auto');
            labFit.Text = '取景: 视口内没有可定位的零件面, 级数归零, 视野回到自动包围';
            return
        end
        lv = max(state.fitN, 1);
        r = 0.55 * ext * 0.5^(lv - 1);
        if ~isfinite(r) || r <= eps(max([1 norm(ctr)]))
            labFit.Text = sprintf('取景: 第 %d 级已到数值下限 (半宽 %.3g), 未改变视野', lv, r);
            return
        end
        axis(ax, 'manual');
        xlim(ax, [ctr(1)-r ctr(1)+r]);
        ylim(ax, [ctr(2)-r ctr(2)+r]);
        zlim(ax, [ctr(3)-r ctr(3)+r]);
        labFit.Text = sprintf('取景: 第 %d 级, 视野跨度 %.4g, 零件最长边 %.4g, 中心 (%.4g, %.4g, %.4g) (单位同显示)', ...
            lv, 2*r, ext, ctr(1), ctr(2), ctr(3));
        applied = true;
    end

    function redraw()
        cla(ax);
        hold(ax, 'on');
        uFac = unitFactor();
        f = spEx.Value;
        schematic = logical(cbSchem.Value);
        wantClip = logical(cbClip.Value);
        nVisible = nnz([cbParts.Value]);
        clippedAny = false;
        nPatched = 0;
        stIds = {}; stStates = {}; stDetails = {};
        for k = 1:nPart
            if ~cbParts(k).Value
                continue
            end
            [Vm, Ft] = baseMesh(k);
            if isempty(Vm) || isempty(Ft)
                continue
            end
            % display_only 逐零件判定: 只有"这个零件自己真的被切开并补盖"才打 true。
            % 早先在装配层统一盖 logical(clippedAny), 会让没被切的零件也声称是显示层剖切件。
            cutThis = false;
            stt = 'unclipped';
            if wantClip
                [Vm2, Ft2, stt, detail] = clipPart(k, Vm, Ft);
                stIds{end+1} = ids{k}; %#ok<AGROW>
                stStates{end+1} = stt; %#ok<AGROW>
                stDetails{end+1} = detail; %#ok<AGROW>
                switch stt
                    case 'cut'
                        Vm = Vm2; Ft = Ft2; clippedAny = true; cutThis = true;
                    case 'plane-misses-part'
                        if size(Ft2, 1) >= 3 && ~isempty(Vm2)
                            Vm = Vm2; Ft = Ft2;
                        else
                            % 保留半空间里没有这个零件: 显示层照它移除, 与状态行里
                            % "整体移出"的措辞保持一致 (不能一边说移走一边还画着)。
                            Vm = zeros(0, 3); Ft = zeros(0, 3);
                        end
                end
            end
            if isempty(Vm) || isempty(Ft) || size(Ft, 1) < 3
                % 切面把整个零件划到保留侧之外: 不画 patch, 状态行按 plane-misses-part 记。
                continue
            end
            Vd = displayTransform(Vm, ids{k}, f, schematic);
            col = colOf(ids{k});
            alp = alphaOf(ids{k});
            ph = patch('Parent', ax, 'Faces', Ft, 'Vertices', Vd*uFac, ...
                'FaceColor', col, 'FaceAlpha', alp, 'EdgeColor', [0.25 0.28 0.33], ...
                'LineWidth', 0.4, 'FaceLighting', 'gouraud', 'EdgeAlpha', 0.5);
            % UserData 里的审计量取自 spec, 与本次是否剖切无关 (结构不变量)。
            ph.UserData = struct('part_id', ids{k}, ...
                'transport_role', char(string(fieldOr(parts(k), 'transport_role', ''))), ...
                'display_only', cutThis, 'clip_state', stt, ...
                'scale_mode', scaleModeStr(), ...
                'units', uu.Value, 'unit_factor_from_m', uFac, ...
                'audit_V_m3', audit.V_m3, 'audit_S_m2', audit.S_m2, ...
                'audit_lbar_gas_m', audit.lbar_gas_m);
            nPatched = nPatched + 1;
        end
        try, lighting(ax, 'gouraud'); camlight(ax, 'headlight'); catch, end
        % 比例尺不在这里画: 它的位置是从轴范围反推的, 而取景在后面还要重写轴范围。
        % 状态标注: 水印不能被单独关闭 (示意档开着就有), 剖切开着就有 DISPLAY CLIP 标记。
        if schematic
            text(ax, 0.5, 0.015, 0.02, 'NOT TO SCALE (示意比例)', 'Units', 'normalized', ...
                'Color', [0.72 0.11 0.11], 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'center');
        end
        if clippedAny
            text(ax, 0.5, 0.985, 0.02, 'DISPLAY CLIP — 输运几何未变', 'Units', 'normalized', ...
                'Color', [0.10 0.40 0.20], 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'center');
        end
        xlabel(ax, ['x / ' uu.Value]); ylabel(ax, ['y / ' uu.Value]);
        zlabel(ax, ['z / ' uu.Value]);
        axis(ax, 'equal'); axis(ax, 'tight');
        ttl = sprintf('TEPC 装配 | 单位 %s | 比例 %s', uu.Value, scaleModeStr());
        if clippedAny
            ttl = [ttl ' | DISPLAY CLIP — 输运几何未变'];
        end
        title(ax, ttl, 'FontSize', 10, 'Interpreter', 'none');
        view(ax, state.cam);
        % 取景的级数要活过重绘: 上面 axis tight 把视野打回自动包围, 有级数就按新零件重算。
        if state.fitN > 0
            applyFit();
        end
        % 比例尺必须排在取景之后: 它的位置与长度都是从轴范围反推的 (见 drawScaleBar)。
        drawScaleBar(uFac, schematic);

        clipSt = emptyClipState();
        clipSt.ids = stIds; clipSt.states = stStates; clipSt.details = stDetails;
        clipSt.requested = wantClip; clipSt.engaged = clippedAny;
        clipSt.n_cut = nnz(strcmp(stStates, 'cut'));
        clipSt.n_misses = nnz(strcmp(stStates, 'plane-misses-part'));
        clipSt.n_failed = nnz(strcmp(stStates, 'failed'));
        clipSt.plane = char(string(ddN.Value));
        clipSt.overr = edD.Value;
        clipSt.n_visible = nVisible;
        clipSt.n_patched = nPatched;
        state.clip = clipSt;
        state.clipped = clippedAny;
        state.clipRequested = wantClip;
        state.units = char(string(uu.Value));
        state.schematic = schematic;
        state.explode = f;
        state.plane = char(string(ddN.Value));
        state.overr = edD.Value;
        clipNote.Text = clipSummaryText(clipSt);
        refreshReadouts();
        if strcmp(fig.Visible, 'on')
            try, drawnow; catch, end
        end
    end

    function drawScaleBar(uFac, schematic)
        % 比例尺长度由当前单位因子推出: 取视口宽的一个整数量级, 标出它的物理长度。
        % 示意档 (对数实体尺度) 下顶点已经被压过, 再除单位因子得到的"物理长度"是假的,
        % 同屏还挂着 NOT TO SCALE 水印 —— 两者口径必须一致: 明说这一段不是物理长度。
        try
            xl = xlim(ax);
            span = abs(xl(2) - xl(1));
            if ~(span > 0), return; end
            nice = niceRound(span*0.25);
            yl = ylim(ax); zl = zlim(ax);
            y0 = yl(1) + 0.06*(yl(2) - yl(1));
            z0 = zl(1);
            x0 = xl(1) + span*0.04;
            line(ax, [x0, x0 + nice], [y0 y0], [z0 z0], ...
                'Color', [0.10 0.10 0.10], 'LineWidth', 2, 'Tag', 'tepcScaleBar');
            lab = humanLen(nice, uFac);
            if schematic
                lab = [lab ' (示意段: 非物理长度)'];
            end
            text(ax, x0 + nice/2, y0, z0, sprintf('  %s', lab), ...
                'Color', [0.10 0.10 0.10], 'HorizontalAlignment', 'left', 'FontSize', 9, ...
                'Tag', 'tepcScaleBarLabel');
        catch
            % silent-by-design: 比例尺是可选显示件, 画不出来不影响几何与审计。
        end
    end

    function [Vm, Ft] = baseMesh(k)
        % 网格只从 spec 里 meshSpec 构造好的展示网格取 (SI 米); 本文件不重算几何。
        % buildPartMesh 返回单个结构体 M (不是 [V,F]), 换分辨率时用 M.V/M.F; 默认分辨率
        % 下 parts(k).V/.F 已是同一份网格, 直接用。
        Vm = zeros(0, 3); Ft = zeros(0, 3);
        Vraw = fieldOr(parts(k), 'V', zeros(0, 3));
        Fraw = fieldOr(parts(k), 'F', zeros(0, 3));
        if ~isempty(Vraw) && ~isempty(Fraw)
            Vm = double(Vraw); Ft = double(Fraw);
            return
        end
        try
            M = spec.buildPartMesh(parts(k).shape, spec.displayResolution_n);
            Vm = double(M.V); Ft = double(M.F);
        catch e
            % 取不到网格的零件本轮不画, 但必须留痕: 静默返回空会让"少了一个零件"
            % 看起来像用户勾掉了它。审计量取 spec 的解析字段, 与这里画不画无关。
            Vm = zeros(0, 3); Ft = zeros(0, 3);
            warning('tepc:gui:PartMeshFail', ...
                '零件 %s 的展示网格构造失败 (%s: %s) —— 该零件不画, 审计读数不受影响。', ...
                ids{k}, char(string(e.identifier)), e.message);
        end
    end

    function [Vc, Fc, stt, detail] = clipPart(k, Vm, Ft)
        % 在 SI 米域上裁: plane = [法向 | 面上一点]。点必须取 nv*d —— 早先写成
        % [nv d 0 0] 时, 对 y/z 法向该点不在法向轴上, 平面恒过原点, 偏距失效。
        %
        % 三态判定 (显示层诚实性的核心):
        %   out.display_only 恒为 true, 只说明"这次调用属于显示层", 不说明这个零件被切开了;
        %   结果非空也只说明有网格可画。真切开的证据在 out.stats 里 —— 面数/顶点数变化或
        %   补了盖面 (n_cap_faces>0)。切面整体位于零件一侧时 stats.plane_misses_part 为真,
        %   这类零件必须单独报 plane-misses-part, 不能混进"生效"里。
        Vc = Vm; Fc = Ft; stt = 'failed'; detail = '';
        nv = [1 0 0];
        switch ddN.Value
            case 'y', nv = [0 1 0];
            case 'z', nv = [0 0 1];
        end
        rr = sqrt(sum(Vm.^2, 2));
        bR = max(rr(:));
        if ~(bR > 0)
            detail = '零件退化 (无正尺度), 切面无从定义';
            return
        end
        d = edD.Value * bR;
        pt = nv * d;
        try
            out = tepc.geometry.clipVolume(Vm, Ft, 'Plane', [nv pt], ...
                'Keep', 'normal', 'Cap', 'auto', 'PartID', ids{k});
            st = struct();
            if isfield(out, 'stats'), st = out.stats; end
            nIn = numOr(st, 'n_faces_input', size(Ft, 1));
            nAfter = numOr(st, 'n_faces_after', size(out.F, 1));
            nCap = numOr(st, 'n_cap_faces', 0);
            misses = truthy(st, 'plane_misses_part');
            emptyAfter = truthy(st, 'empty_after');
            closed = truthy(st, 'closed_after');
            nVIn = size(Vm, 1); nVAfter = size(out.V, 1);
            usable = ~isempty(out.V) && ~isempty(out.F) && size(out.F, 1) >= 3;
            % "变了"必须能从 stats 里读出来: 面数、盖面数、顶点数三者全等即 no-op。
            changed = (nAfter ~= nIn) || (nCap > 0) || (nVAfter ~= nVIn);
            if misses
                stt = 'plane-misses-part';
                if emptyAfter || ~usable
                    Vc = zeros(0, 3); Fc = zeros(0, 3);
                    detail = sprintf(['切面整体在零件另一侧: %d 面全部落在保留侧之外, ' ...
                        '无切口 (整体移出, 非切开)'], nIn);
                else
                    detail = sprintf('切面未穿过零件: %d 面整体在保留侧, 面数未变 (%d->%d)', ...
                        nIn, nIn, nAfter);
                end
            elseif changed && usable
                Vc = double(out.V); Fc = double(out.F); stt = 'cut';
                detail = sprintf('面数 %d->%d, 盖面 %d, 闭口=%s', ...
                    nIn, nAfter, nCap, onOff(closed));
            else
                stt = 'failed';
                detail = sprintf(['切面穿过包围范围却没产生任何切割 (面数 %d->%d, 盖面 %d, ' ...
                    '闭口=%s, 盖面状态=%s) -> 退回未切网格'], ...
                    nIn, nAfter, nCap, onOff(closed), capStatusOf(out));
            end
        catch e
            Vc = Vm; Fc = Ft; stt = 'failed';
            detail = sprintf('clipVolume 抛错 (%s): %s', e.identifier, e.message);
        end
        detail = [detail sprintf(' [d=%.2e m, d/R=%g]', d, edD.Value)];
    end

    function Vd = displayTransform(V, id, explode, schematic)
        Vd = V;
        if explode > 0 && isfield(spec, 'offsets') && isfield(spec.offsets, id)
            off = double(spec.offsets.(id));      % offsets 是按 part_id 索引的结构体
            Vd = Vd + repmat(off * explode, size(Vd, 1), 1);
        end
        if schematic
            % 对数实体尺度: r' = r0*log10(1+r/r0), r0 取阳极半径。小特征近线性保住,
            % 大特征被压 -> 3 个数量级同屏可看; 单调、有限, 不改拓扑。
            r0 = max([spec.anodeRadius_m, realmin]);
            rr = sqrt(sum(Vd.^2, 2));
            f = ones(size(rr)) / log(10);
            idx = rr > 0;
            f(idx) = r0 * log10(1 + rr(idx) / r0) ./ rr(idx);
            Vd = Vd .* repmat(f, 1, 3);
        end
    end

    function c = colOf(id)
        switch lower(id)
            case 'gas_cavity', c = [0.90 0.78 0.32];
            case 'wall', c = [0.45 0.55 0.62];
            case 'cathode', c = [0.20 0.35 0.55];
            case 'anode', c = [0.75 0.22 0.22];
            case 'world_envelope', c = [0.80 0.80 0.80];
            case 'equivalent_site_realized', c = [0.20 0.60 0.30];
            case 'equivalent_site_requested', c = [0.55 0.85 0.60];
            case 'source_cone', c = [0.60 0.35 0.65];
            otherwise, c = [0.50 0.50 0.50];
        end
    end

    function a = alphaOf(id)
        switch lower(id)
            case 'gas_cavity', a = 0.30;
            case 'wall', a = 0.18;
            case 'cathode', a = 0.06;
            case 'anode', a = 0.95;
            case 'world_envelope', a = 0.05;
            case 'equivalent_site_realized', a = 0.75;
            case 'equivalent_site_requested', a = 0.25;
            case 'source_cone', a = 0.20;
            otherwise, a = 0.5;
        end
    end

    function refreshReadouts()
        % 审计读数只由 audit 生成, 不接任何显示参数 -> 结构上不可能被剖切改变。
        labAudit.Text = sprintf(['V = %.6e m^3\nS = %.6e m^2\nlbar = %.6e m' ...
            '\n4V/S = %.6e m'], audit.V_m3, audit.S_m2, audit.lbar_gas_m, ...
            audit.meanChord_4V_over_S_m);
        nVis = nnz([cbParts.Value]);
        labTopo.Text = sprintf(['敏感体积 %s | 电极拓扑 %s | 场 %s\n' ...
            '网格档 n = %g | 零件数 %d (可见 %d)\n溯源: %s'], ...
            char(string(spec.geometryType)), char(string(spec.electrodeTopology)), ...
            char(string(spec.fieldTopology)), spec.displayResolution_n, nPart, nVis, ...
            char(string(spec.sha256Source)));
    end

    function runMeasureFromField()
        % textarea 里输入 6 个数 (x1 y1 z1 x2 y2 z2), 用 sscanf 解析 (返回列向量)。
        v = sscanf(char(string(edMeas.Value)), '%f');
        if numel(v) < 6
            labMeasure.Text = '测距输入需要 6 个数: x1 y1 z1 x2 y2 z2 (当前单位)';
            return
        end
        measureDistance(v(1:3), v(4:6));
    end

    function m = measureDistance(p1, p2)
        % 两点距离: 输入按当前显示单位, 换算回米后取欧氏距, 再回显三套单位。
        uFac = unitFactor();
        a1 = double(p1(:)).' / uFac;
        a2 = double(p2(:)).' / uFac;
        d_m = norm(a2 - a1);
        m = struct('p1', a1, 'p2', a2, 'd_m', d_m, 'd_mm', d_m*1e3, ...
            'd_um', d_m*1e6, 'units_in', uu.Value);
        state.measure = m;
        labMeasure.Text = sprintf(['测距 (输入单位 %s):\n|P2-P1| = %.6e m\n' ...
            '= %.4f mm = %.2f um'], uu.Value, d_m, d_m*1e3, d_m*1e6);
    end

    function runInterference()
        % 已修的三处: 算子侧 faceAabb 的 min/max 维度参数、逐零件结构体数组的整元素赋值;
        % 取数侧把 rep 顶层的 n_parts 当成 summary 字段。face-hit 的数值判定**尚未**验证
        % (轴对齐退化几何下 0 命中, 见 overlapCheck 的 segTri 早退), 所以这里不能说
        % "网格路线已修通", 只能说"能跑完并返回 rep"。工作台侧仍保留失败分支: 失败原因
        % 可读、不残留"运行中"与上一次的陈旧表格、面板其余按钮与读数照常可用、可反复重跑。
        state.interfRuns = state.interfRuns + 1;
        labInterf.Text = '干涉审计: 运行中…';
        try
            r = tepc.geometry.overlapCheck(parts, 'GapMin_m', 1e-6, ...
                'PenetrationTol_m', 1e-9, 'MaxFacesPerPart', 4000);
            state.interf = r; state.interfErr = '';
            [txt, why] = interfText(r);
            if isempty(txt)
                % 结果结构不符合预期面板字段: 宁可报"判定项缺失 + 为什么", 也不拿空表
                % 冒充算完, 也不把取数失败含糊成"算子没数"。
                if isempty(why), why = 'summary 字段集不完整'; end
                state.interf = []; state.interfErr = why;
                labInterf.Text = ['干涉审计: 失败 -> 判定项缺失 (' why ') ' ...
                    '(算子已返回 rep, 面板仍可用)'];
            else
                labInterf.Text = txt;
            end
        catch e
            state.interf = []; state.interfErr = e.message;
            labInterf.Text = sprintf(['干涉审计: 失败 -> %s%s' ...
                '原因标识: %s%s处理: 该算子不参与审计读数, 三维显示/剖切/公差蒙卡仍可用; ' ...
                '再按一次可重跑。'], trimMsg(e.message), newline, ...
                char(string(e.identifier)), newline);
        end
    end

    function runTolerance()
        runTolN(64);
    end

    function runToleranceForTest(N)
        if nargin < 1, N = 64; end
        runTolN(N);
    end

    function runTolN(N)
        % 随机流必须显式建、显式记: 同 (类型, seed) 逐位可复现, 否则敏感性数字不可复核。
        labTol.Text = sprintf('公差蒙卡: 运行中 (N=%d)…', N);
        seed = 20260921;
        try
            rs = RandStream.create('mt19937ar', 'Seed', seed);
            r = tepc.geometry.toleranceMonteCarlo(cfgIn, N, rs);
            state.tol = r; state.tolErr = '';
            labTol.Text = sprintf(['蒙卡 N=%d seed=%d (%s)\n' ...
                '样本 ok=%d failed=%d | 通道 %s\n%s'], ...
                r.n_samples, seed, r.random_source.type, r.n_ok, r.n_failed, ...
                r.channel, tolSummaryLine(r));
        catch e
            state.tol = []; state.tolErr = e.message;
            labTol.Text = sprintf(['公差蒙卡: 失败 (N=%d seed=%d)\n-> %s'], ...
                N, seed, e.message);
        end
    end

    function exportShot()
        % 导出提示写在自己的状态行 labStatus: 早先借用 labTol, 一次导出就把公差蒙卡的
        % 结果 (含 N/seed/敏感度) 整段覆盖掉, 且无法找回。
        try
            d = fullfile(tempdir, 'tepc_workbench');
            if ~isfolder(d), mkdir(d); end
            stamp = char(string(datetime('now', 'Format', 'yyyyMMdd_HHmmssSSS')));
            fp = fullfile(d, sprintf('wb_%s.png', stamp));
            exportgraphics(ax, fp, 'Resolution', 150);
            ok = isfile(fp);
            if ok
                state.exportPath = fp; state.exportErr = '';
                labStatus.Text = ['视图导出: 成功 -> ' fp];
            else
                state.exportPath = ''; state.exportErr = 'exportgraphics 未产出文件';
                labStatus.Text = '视图导出: 失败 -> exportgraphics 未产出文件';
            end
        catch e
            state.exportPath = ''; state.exportErr = e.message;
            labStatus.Text = ['视图导出: 失败 -> ' e.message];
        end
        % labTol 一字不改: 公差面板的内容只有 runTolN 有权写。
    end

    function closeNow()
        try, delete(fig); catch, end
    end

    function s = stateLive()
        % 嵌套函数与父函数共享工作区, 每次调用读到的是当时的 state; 建窗时快照出去的
        % struct/匿名句柄都拿不到后续回调写入的值。
        s = state;
    end

    function a = auditLive()
        a = audit;
    end

    function uFac = unitFactor()
        if strcmp(uu.Value, 'um'), uFac = 1e6; else, uFac = 1e3; end
    end

    function s = scaleModeStr()
        if cbSchem.Value, s = '示意(log)'; else, s = '真实(1:1)'; end
    end
end

%% ==================== 局部函数 (本文件含嵌套函数, 故所有函数一律带 end) ====================

function tf = fieldOr(s, nm, dflt)
if isfield(s, nm) && ~isempty(s.(nm))
    tf = s.(nm);
else
    tf = dflt;
end
end

function t = trimTo(s, n)
if numel(s) > n
    t = [s(1:n-1) '…'];
else
    t = s;
end
end

function s = capStatusOf(out)
s = '—';
try
    if isfield(out, 'cap') && isfield(out.cap, 'status')
        s = char(string(out.cap.status));
    end
catch   % silent-by-design: 单元格取状态是展示兜底, 读不出来就显示 '—', 不影响任何计算量
    s = '—';
end
end

function cs = emptyClipState()
% 三态计数的载体: 用平行 cell 数组而不是非标量结构体数组 (s.field 在非标量数组上是
% 逗号列表, 读回时容易踩)。
cs = struct('ids', {{}}, 'states', {{}}, 'details', {{}}, ...
    'requested', false, 'engaged', false, 'n_cut', 0, 'n_misses', 0, 'n_failed', 0, ...
    'plane', 'x', 'overr', 0, 'n_visible', 0, 'n_patched', 0);
end

function t = clipSummaryText(cs)
% 逐零件三态汇总。整句结论只在"至少一个零件真的切开"时才允许写"真剖切已生效";
% 一个都没切开时既要说不可用, 也要点名是每个零件落在哪一类 (misses / failed),
% 否则 no-op 就被整体措辞糊过去了。
if ~cs.requested
    t = '剖切状态: 未启用 (透明剖面, 不删网格)';
    return
end
head = sprintf('剖切状态: 切面 %s 偏距 d/R = %g | 可见零件 %d (已画 %d) | ', ...
    cs.plane, cs.overr, cs.n_visible, cs.n_patched);
if isempty(cs.ids)
    t = [head '真剖切当前不可用 (无从作用): 没有可见零件 —— 全部零件被勾选隐藏, ' ...
        '这是显隐状态不是剖切失败; 未删网格, 审计量未受影响。'];
    return
end
nTot = numel(cs.ids);
if cs.n_cut > 0
    head = [head sprintf('真剖切已生效 (%d/%d 个零件切开并补盖面, 仅显示层)', ...
        cs.n_cut, nTot)];
else
    head = [head sprintf('真剖切当前不可用 (未生效): %d/%d 个零件没产生切口', ...
        nTot - cs.n_cut, nTot)];
end
segs = cell(1, nTot);
for i = 1:nTot
    segs{i} = sprintf('%s[%s] %s', cs.ids{i}, cs.states{i}, cs.details{i});
end
t = sprintf('%s | 逐零件: %s', head, strjoin(segs, ' ; '));
if cs.n_cut == 0
    t = [t ' | 已退回透明剖面显示 (只降不透明度, 不删网格)'];
end
t = [t ' | 审计 V/S/lbar 未变。'];
end

function v = numOr(s, nm, dflt)
v = dflt;
if isfield(s, nm) && ~isempty(s.(nm)) && isnumeric(s.(nm))
    v = double(s.(nm));
end
end

function tf = truthy(s, nm)
tf = false;
if isfield(s, nm) && ~isempty(s.(nm))
    v = s.(nm);
    if isnumeric(v) || islogical(v)
        tf = any(v(:) > 0);
    else
        tf = strcmpi(char(string(v)), 'true');
    end
end
end

function s = onOff(v)
if v, s = '是'; else, s = '否'; end
end

function m = trimMsg(msg)
% 面板一行放不下面向堆栈的长错误, 折成单行并截断; 全文留在 state.interfErr 里。
m = strrep(char(string(msg)), newline, ' ');
m = strrep(m, sprintf('\r'), ' ');
if numel(m) > 240, m = [m(1:237) '…']; end
end

function [txt, why] = interfText(r)
% 判定表格的文本单独成型: 字段缺失时返回空串并给出**为什么**缺失, 由调用方落成
% "判定项缺失 + 原因", 免得把面板取数的失败混进算子失败的消息里, 也不让取数失败
% 看起来像算子失败。
txt = ''; why = '';
try
    s = r.summary;
    % n_parts 在算子返回的顶层 (rep.n_parts), 不在 rep.summary 里: 早先按 s.n_parts 取
    % 会当场抛错并被 catch 吞成空串, 面板于是回"缺少 summary 判定项"。
    nP = numOr(r, 'n_parts', NaN);
    if ~isfinite(nP)
        % %d 会把 NaN 强行折成一个看似合理的整数, 所以缺 n_parts 必须走"判定项缺失"
        % 这条显式路径, 不能印出一个假数字让面板看起来正常。
        why = 'rep.n_parts 缺失或非数值';
        return;
    end
    % 判定由 *_unexpected 列驱动 (设计共面的对不计为干涉), 所以总数与意外数必须同时给出:
    % 只印总数会把"包络/位点标记/源锥与实体必然重叠"读成真实干涉。
    % 内含对数也要单独印: 内含时 overlap_volume 等于内体整个体积, 最大重复体积会恰好
    % 等于某个零件的标称体积, 不标出来的话一行读数看起来像整腔互穿。
    nDisp = nnz([r.pairs.display_only_any]);
    txt = sprintf([ ...
        '判定: %s\n零件 %d / 零件对 %d (设计共面 %d, 含仅显示零件的对 %d)\n' ...
        '面-面相交 %d/%d (总/意外) | 穿透 %d/%d | 间隙不足 %d/%d | 重复体积 %d/%d (内含 %d)\n' ...
        'AABB 相接 %d/%d | 共面接触 %d | 未完全评估 %d | 体积未算 %d\n' ...
        '最小间隙 %.3e m | 最大穿透 %.3e m | 最大重复体积 %.3e m^3 | 面-面已测 %d'], ...
        verdictStr(r), nP, s.n_pairs, s.n_expected_coincident_pairs, nDisp, ...
        s.n_face_intersecting, s.n_face_intersecting_unexpected, ...
        s.n_penetrating, s.n_penetrating_unexpected, ...
        s.n_below_gap_min, s.n_below_gap_min_unexpected, ...
        s.n_with_duplicate_volume, s.n_with_duplicate_volume_unexpected, ...
        s.n_overlap_volume_contained_pairs, ...
        s.n_aabb_overlapping, s.n_aabb_overlapping_unexpected, ...
        s.n_coplanar_contact, s.n_not_fully_evaluated, ...
        s.n_overlap_volume_not_computed, s.min_gap_overall_m, ...
        s.max_penetration_overall_m, s.max_overlap_volume_overall_m3, ...
        s.n_face_pairs_tested_total);
catch e
    txt = '';
    why = sprintf('面板取数失败 %s: %s', char(string(e.identifier)), trimMsg(e.message));
end
end

function s = verdictStr(r)
s = '—';
try
    if isfield(r, 'verdict'), s = char(string(r.verdict)); end
catch
    % silent-by-design: verdict 取不到时印 '—'; 判定缺失由调用方的"判定项缺失"分支说明。
    s = '—';
end
end

function line = tolSummaryLine(r)
% 从 out.sensitivity (非标量结构体数组: 取字段必须用 {s.field}) 里挑"壁厚->V"与
% "阳极半径->电容"两条, 报名义点偏导; 没有对应行给 NaN 而不是留空冒充算了。
line = '敏感度: 无 (蒙卡未给 sensitivity)';
try
    sens = r.sensitivity;
    vars = {sens.variable};
    qtys = {sens.quantity};
    dv   = [sens.derivative_at_nominal];
    j1 = find(strcmpi(vars, 'wall_thickness_rel') & strcmpi(qtys, 'V_m3'), 1);
    j2 = find(strcmpi(vars, 'anode_radius_rel') & strcmpi(qtys, 'capacitance_F'), 1);
    line = sprintf('壁厚->V 偏导 %s | 阳极半径->电容 偏导 %s', numOrNaN(dv, j1), ...
        numOrNaN(dv, j2));
catch e
    line = ['敏感度解析失败 -> ' e.message];
end
end

function s = numOrNaN(v, j)
if isempty(j) || ~isfinite(v(j))
    s = '未建模(NaN)';
else
    s = sprintf('%.3e', v(j));
end
end

function [ok, ctr, ext] = drawnPartCtr(ax)
% 画出来的零件 (patch 顶点) 的包围盒中心与最长边跨度。本机 uiaxes 的类是
% matlab.ui.control.UIAxes, 它没有 plotbox 方法 (实测抛 MATLAB:UndefinedFunction),
% 包围盒只能从子对象顶点自算。
% 两类东西必须排除, 而且都是实测咬过的:
%   * 比例尺 line/text —— 它们的位置是从当前轴范围反推的, 算进来会让取景追着自己的
%     比例尺跑 (每按一次中心就漂一次);
%   * world_envelope 零件本身 —— meshSpec 里它是"给外部 MC 适配器预留的合同位",
%     解析基线不消费, 半宽取 5*bboxR。含它时基准跨度实测 254 mm, 而装置只有 50.8 mm,
%     于是"放大取景"框的是一个空盒子, 第一级几乎没有放大 (265 -> 279)。
ok = false;
ctr = [NaN NaN NaN];
ext = NaN;
vx = []; vy = []; vz = [];
ch = ax.Children;
for k = 1:numel(ch)
    h = ch(k);
    if ~isa(h, 'matlab.graphics.primitive.Patch'), continue; end
    if ~strcmp(h.Visible, 'on'), continue; end
    ud = h.UserData;
    if isstruct(ud) && isfield(ud, 'part_id') ...
            && strcmp(char(string(ud.part_id)), 'world_envelope')
        continue;
    end
    V = h.Vertices;
    if ~isnumeric(V) || size(V, 2) < 3, continue; end
    vx = [vx; V(:,1)]; vy = [vy; V(:,2)]; vz = [vz; V(:,3)]; %#ok<AGROW>
end
if isempty(vx), return; end
m = isfinite(vx) & isfinite(vy) & isfinite(vz);
if ~any(m), return; end
lo = [min(vx(m)) min(vy(m)) min(vz(m))];
hi = [max(vx(m)) max(vy(m)) max(vz(m))];
ctr = (lo + hi) / 2;
ext = max(hi - lo);
ok = all(isfinite(ctr)) && isfinite(ext) && ext > 0;
end

function t = dynamicRangeNote(spec)
% 让 mm 与 um 的跨级问题在面板上可见: 给出气腔与阳极的特征半径与量级比。
b_m = double(spec.gasRadius_m);
a_m = double(spec.anodeRadius_m);
ratio = b_m / max(a_m, realmin);
t = sprintf(['动态范围: 腔半径 %.3f mm, 阳极半径 %.1f um, ' ...
    '相差约 %d 倍 (~%.1f 个数量级)。真实 1:1 无法同时看清两级 —— ' ...
    '需要时开"示意比例(对数)"。'], ...
    b_m*1e3, a_m*1e6, round(ratio), log10(ratio));
end

function v = niceRound(x)
if ~(x > 0), v = 1; return; end
e = floor(log10(x));
f = x / 10^e;
if f < 1.5
    m = 1;
elseif f < 3
    m = 2;
elseif f < 7
    m = 5;
else
    m = 10;
end
v = m * 10^e;
end

function s = humanLen(vDisp, uFac)
% 比例尺长度: 显示单位坐标 -> 物理长度, 再选一个人类可读的单位。
v_m = vDisp / uFac;
if v_m*1e3 >= 1
    s = sprintf('%.3g mm', v_m*1e3);
else
    s = sprintf('%.3g um', v_m*1e6);
end
end

function h = existingWorkbenches()
% 只找本工作台开过的 uifigure (按 appdata 标记), 不碰其它窗口: 会话是共享的。
h = [];
try
    all0 = findall(0);
    keep = [];
    for i = 1:numel(all0)
        o = all0(i);
        if isgraphics(o, 'figure') && ~isempty(getappdata(o, 'tepcWorkbench'))
            keep(end+1) = o; %#ok<AGROW>
        end
    end
    h = keep;
catch   % silent-by-design: 枚举图形句柄只用于"关掉旧工作台窗口", 枚举失败就不关, 不吞计算错误
    h = [];
end
end
