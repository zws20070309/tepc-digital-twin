classdef TEPCApp < handle
%TEPCAPP TEPC 解析代理模型 (Fast Surrogate) GUI (程序化 uifigure)。
%   页签: 项目/几何与气体/电场与增益/源/电子学/运行/谱与剂量/验证与报告。
%   顶部三色警报横幅(红=结果无效/橙=限制假设/蓝=信息, 文字+符号双通道)。
%   运行经 AppController(backgroundPool) 非阻塞; 取消/暂停协作式 flag。
%   构造: app = TEPCApp();  app = TEPCApp(false) 隐藏窗口(测试用)。
%
%   关键约定 (历史缺陷已修, 由 tests/integration/test_gui_tab_mapping.m 锁定):
%   1) 页签内容一律经 tabByTitle(标题) 挂载 —— uigridlayout/uitabgroup 的
%      Children 顺序不保证, 禁止用 Children(end-k) 反序索引 (曾致 8 页内容整体镜像)。
%   2) 界面 -> 配置 走单一映射表 cfgMap(): gatherConfig 按"当前选中的配置文件"
%      加载后逐项覆写, 每个覆写都带 isfield 守卫 + isfinite 断言; applyConfig 用
%      同一张表回填全部可编辑控件 —— 加载与收集永远对称, 不会出现混合配置。
%   3) 关窗经 CloseRequestFcn 统一清理 (timer/DataQueue/parfeval/flag 文件,
%      以及 AppState 的延时装载器), 且所有 UI 写入前查 uiAlive()
%      —— MATLAB timer 不随 uifigure 销毁。
%
%   组件层的分工 (app/Theme.m, app/AppState.m, app/components/*):
%   * AppState  = 界面字段值的唯一真相源 + 派生量的延后重算 (单发防抖定时器)。
%     控件仍是"当前输入"的物理载体, 但界面读出的值只在 gatherConfig 与卡片改动
%     回调两处进状态源; 界面到配置的字段路径只有 cfgMap 一张表 (投影层)。
%   * Theme     = 颜色/字号/间距与状态三通道 (图标 + 文字 + 色) 的唯一常量出处。
%   * StatusChip.band = 顶部状态带六个席位 (模式/后端/配置哈希/位点/未关闭阻塞项/
%     是否允许发布); 整行文本经 statusStripText() 程序化可取。
%   * ParameterCard = 几何与气体页的 12 个数值格 (单位/合法域/步长/来源徽标)。
%   * EvidencePanel = 验证与报告页的能力登记表面板 (按字节 UTF-8 读登记表)。
%   * PlotToolbar   = 三维几何页的图区工具条 (视角预设/导出图/复制命令/图层可见性)。
%   路径: addpath(app) 不覆盖 app/components —— tepc_gui.m 与本文件都要单独加。

properties (SetAccess = private)
    UIFigure
    Controller
    Banner
    SiteBand = ''         % 顶部状态带常驻位点串 (请求/实现/相对偏差); 横幅唯一写入点在 setBanner
    Tabs
    StatusLabel
    Fields          % struct: tag -> uicompONENT (仅界面控件)
    Buttons
    ProgBar
    LogList
    GatesTable
    AxSpectrum
    AxGeom3D
    AxField
    AxGeom
    LogData = {}
    PollTimer = []
    ResultShown = false
    ProgressQueue = []
    ProgressMsgs = {}
    ProgressFracs = []
    LastResult = []         % 上一次运行结果 (谱模式下拉重绘用)
    TabTitles = {}          % 页签标题白名单 (挂载唯一寻址依据)
    PollActive = false      % 轮询开关 (防关窗后 timer 回调写失效控件)
    Closed = false          % 已请求关闭
    State = []              % AppState 实例: 字段值与派生量的真相源
    Strip = []              % 顶部状态带的 uigridlayout (六个胶囊位 + 一个尾列吃剩余宽度)
    Chips = {}              % 1x6 StatusChip 元胞 (StatusChip.band 建, 席位固定)
    StripText = ''          % 状态带整行文本镜像 (与胶囊控件同时写入, 供程序读取)
    Cards = {}              % 几何/气体页的 ParameterCard 元胞
    Evidence = []           % 验证与报告页的 EvidencePanel
    Toolbar = []            % 三维几何页的 PlotToolbar
    SiteReqUm = NaN         % 请求位点直径 um (refreshSiteBand 写入, 状态带从这里取值)
    SiteRealUm = NaN        % 实现位点直径 um
    SiteRelPct = NaN        % 实现相对请求的偏差 %
    BlockerSource = ''      % 未关闭阻塞项计数的出处
    MutedControls = {}      % 用弱化字色的说明控件 (applyTheme 不得把它们刷成主字色)
end

properties (Transient, SetAccess = private)
    CfgMapCache = []        % gatherConfig/applyConfig 共用映射表缓存
    LogErrorHistory = {}    % noteUiError 收集的 MException (供"复制详情"与事后审计)
end

methods
    function self = TEPCApp(visible)
        if nargin < 1, visible = true; end
        ensureComponentsOnPath();     % app/components 不在 addpath(app) 的覆盖范围内
        self.Controller = AppController();
        self.Fields = struct(); self.Buttons = struct();
        self.initStateSource();
        self.buildUI();
        self.applyTheme();
        if visible
            self.UIFigure.Visible = 'on';
        else
            self.UIFigure.Visible = 'off';
        end
        self.setBanner("blue", "就绪。填写或载入配置后点击 [校验配置]。");
        self.setStateLabel("Empty");
    end

    function initStateSource(self)
        %INITSTATESOURCE 建 AppState 并交给它界面那一张映射表 (含单位/合法域/步长/来源)。
        %   延时常量取 0.25 s: 本机 timer 回调只在主线程空闲时触发, 重算 (resolve 全链)
        %   比延时长时也不会堆积 —— 装载器是单发的, 每次输入先 stop 再 start。
        self.State = AppState();
        self.State.setSchema(self.fieldSchema());
        self.State.setDebounceDelay(0.25);
        % 派生量到期只刷状态带: 页面上的文本框由各自的回调写, 让延后回调去覆盖它们
        % 会把"校验后显示"的措辞在几百毫秒后换成另一套话。
        self.State.subscribe(@(evt) self.onStateEvent(evt), {'derived'});
    end

    function onStateEvent(self, evt)
        %ONSTATEEVENT 状态源事件: 目前只有派生量到期一路需要刷界面。
        if isempty(evt) || ~isfield(evt, 'Reason')
            return;
        end
        if strcmp(string(evt.Reason), "derived")
            self.refreshStatusStrip();
        end
    end

    % ---------- UI 构建 ----------
    function buildUI(self)
        self.UIFigure = uifigure('Name', 'TEPC 解析代理模型 (Fast Surrogate) [非真实装置复现] RESEARCH/DEMO', ...
            'Position', self.windowPosition(), 'Color', Theme.ColorCanvas, ...
            'CloseRequestFcn', @(~,~) self.onCloseRequest());
        grid = uigridlayout(self.UIFigure);
        % 四行: 警报横幅 / 状态带 / 页签 / 状态行。原来的三行里没有状态带的位置。
        % 第 1 行用 'fit' 而不是定高: 横幅是单行 uilabel 时, 一条长告警的自然宽实测 2528 px
        % 而控件只有 1224 px, 定高单行会把后半句静默裁掉 —— 红线披露不能靠文案短。
        % 'auto' 关键字在本机 R2025a 被 uigridlayout 拒绝, 'fit' 可用 (120 字折行标签量到 22 px)。
        grid.RowHeight = {'fit', Theme.ChipH, '1x', Theme.ChipH};
        grid.ColumnWidth = {'1x'};
        grid.Padding = [Theme.GapS Theme.GapS Theme.GapS Theme.GapS];
        grid.RowSpacing = Theme.GapXS;

        self.Banner = uilabel(grid);
        self.Banner.Layout.Row = 1; self.Banner.Layout.Column = 1;
        self.Banner.FontSize = 13; self.Banner.HorizontalAlignment = 'left';
        self.Banner.WordWrap = 'on';
        % (uilabel 在本机 R2025a 没有 MinimumSize, 实测 noPublicFieldForClass; 短文案时
        %  这一行就只有文字本身的高度, 长文案靠 'fit' 行高向上撑开。)
        self.Banner.Text = ' ';

        self.buildStatusStrip(grid);

        tg = uitabgroup(grid);
        tg.Layout.Row = 3; tg.Layout.Column = 1;
        self.Tabs = tg;
        self.TabTitles = {'项目','几何与气体','电场与增益','源','电子学','运行','谱与剂量','三维几何','验证与报告'};
        for i = 1:numel(self.TabTitles)
            uitab(tg, 'Title', self.TabTitles{i});
        end

        self.StatusLabel = uilabel(grid);
        self.StatusLabel.Layout.Row = 4; self.StatusLabel.Layout.Column = 1;
        self.StatusLabel.Text = '状态: Empty'; self.StatusLabel.FontSize = 12;

        % 按标题取页: 不依赖 Children 顺序 (镜像错配的根本修复)
        self.buildProjectTab(self.tabByTitle('项目'));
        self.buildGeomTab(self.tabByTitle('几何与气体'));
        self.buildFieldTab(self.tabByTitle('电场与增益'));
        self.buildSourceTab(self.tabByTitle('源'));
        self.buildElecTab(self.tabByTitle('电子学'));
        self.buildRunTab(self.tabByTitle('运行'));
        self.buildSpecTab(self.tabByTitle('谱与剂量'));
        self.buildGeom3dTab(self.tabByTitle('三维几何'));
        self.buildReportTab(self.tabByTitle('验证与报告'));
    end

    function pos = windowPosition(self)
        %WINDOWPOSITION 目标 1240x860, 再按大屏工作区夹取。
        %   加高/加宽的原因不是美观: 顶部状态带占 26 px, 几何页的数值格改成参数卡片后
        %   每行由 28 px 变成 66 px —— 页签内容行是固定行高, 窗口不放大就会裁掉最后几行。
        %   本机实测: get(groot,'ScreenSize') 返回的是 96 dpi 单位下的工作区
        %   (150% 缩放的 2560x1600 屏给 1706.7x1066.7), PixelsPerInch/PhysicalScreenSize
        %   在 R2025a 的 groot 上已不是合法属性 (实测 MATLAB:hg:InvalidProperty)。
        want = [60 60 1240 860];
        mp = [];
        try
            mp = get(groot, 'MonitorPositions');
        catch
            % silent-by-design: 取不到屏幕信息就用缺省尺寸, 不得让界面建不起来
        end
        if isempty(mp)
            try
                ss = get(groot, 'ScreenSize');
                mp = [1 1 ss(3) ss(4)];
            catch
                % silent-by-design: 两条探测路径都不可用 (无显示会话) 时保留缺省尺寸
            end
        end
        if ~isempty(mp)
            availW = max(700, double(mp(1, 3)) - 100);
            availH = max(560, double(mp(1, 4)) - 90);
            want(3) = min(want(3), availW);
            want(4) = min(want(4), availH);
            want(1) = max(0, min(want(1), max(0, double(mp(1, 3)) - want(3) - 20)));
            want(2) = max(0, min(want(2), max(0, double(mp(1, 4)) - want(4) - 20)));
        end
        pos = want;
    end

    function buildStatusStrip(self, host)
        %BUILDSTATUSSTRIP 顶部状态带: 六个席位由 StatusChip.band 一次建齐。
        %   席位是显示契约 (StatusChip.defaultSpecs 定义), 缺一个就等于少一项
        %   对使用者可见的判定; 未取数的席位显式显示"未取数"。
        L = Theme.layout('chipstrip');
        strip = uigridlayout(host);
        strip.Layout.Row = 2; strip.Layout.Column = 1;
        strip.RowHeight = L.RowHeight;
        strip.ColumnWidth = L.ColumnWidth;      % 六列 'fit' + 一列 '1x' (本机 fit 实测可用)
        strip.Padding = L.Padding;
        strip.RowSpacing = L.Spacing(1);
        strip.ColumnSpacing = L.Spacing(2);
        self.Strip = strip;
        self.Chips = StatusChip.band(strip, StatusChip.defaultSpecs());
        for i = 1:numel(self.Chips)
            % band() 把胶囊按行序建在同一个容器里; 列位置在这里逐格钉死,
            % 不依赖 uigridlayout 的自动摆放顺序 (Children 顺序在本机不保证)。
            self.Chips{i}.Label.Layout.Row = 1;
            self.Chips{i}.Label.Layout.Column = i;
        end
        self.refreshStatusStrip();
    end

    function tab = tabByTitle(self, tabTitle)
        %TABBYTITLE 按 Title 精确匹配取页签; 找不到即报错, 绝不退化为顺序索引。
        %   tabTitleOf 是本文件末尾的**局部函数** (不是方法): methods 块内不带
        %   self 的 function 仍是方法, 把 Tab 句柄当 self 传递会直接报错。
        want = char(string(tabTitle));
        cand = self.allTabs();
        for i = 1:numel(cand)
            ttl = tabTitleOf(cand(i));
            if ~isempty(ttl) && strcmp(ttl, want)
                tab = cand(i);
                return;
            end
        end
        have = cell(1, numel(cand));
        for i = 1:numel(cand)
            ttl = tabTitleOf(cand(i));
            if isempty(ttl), have{i} = '<无标题>'; else, have{i} = ttl; end
        end
        error('tepc:gui:NoTab','找不到标题为 "%s" 的页签 (现有: %s)', want, strjoin(have, ' | '));
    end

    function list = allTabs(self)
        %ALLTABS 页签对象数组 (只按类名筛, 绝不按位置索引)。
        %   R2025a 实测两条坑:
        %   1) matlab.ui.container.TabGroup 没有 Tabs 属性 (properties 里只有
        %      Children), 原先"优先取 Tabs"的分支永远落在 catch 里;
        %   2) 从 list = [] 起手的 list(end+1) = tabObj 会被转成 **double 句柄数组**
        %      (实测 class(list)='double'), 于是 list(i).Title 抛
        %      structRefFromNonStruct, 每个页签都读成"<无标题>" -> tabByTitle 报
        %      tepc:gui:NoTab, buildUI 崩溃, 15 个 GUI 用例连带失败。
        %   正解: 用逻辑索引 ch(keep) 直接从对象数组切片, 不做任何拼装。
        list = [];
        try
            ch = self.Tabs.Children;
        % silent-by-design: 页签标题取不到不影响功能, 回落默认标题
        catch
            return;
        end
        if isempty(ch), return; end
        keep = false(1, numel(ch));
        for i = 1:numel(ch)
            keep(i) = contains(class(ch(i)), '.Tab');
        end
        if ~any(keep), return; end
        list = ch(keep);
    end

    function buildGeomTab(self, tab)
        % 几何与气体页: 12 个数值格由 ParameterCard 承载 (紧凑两行卡片), 两个下拉与
        % 反解按钮保持单行。卡片自己带"标签/控件/步长/单位/来源徽标 + 提示行",
        % 所以父网格每行的行高由 card.place() 按 OpenHeight 写回 (66 px)。
        %   解析输运目前只对 sphere 实现体均匀起点抽样; 其余类型可校验但会在运行时拒绝
        g = self.newGrid(tab, 3, 8);
        g.RowHeight = self.geomTabRows(8);        % 表单单行 + 四行卡片 + 说明/文本域/坐标区
        self.addDropdown(g, 1, 1, '几何类型', ...
            {'sphere','cylinder_endless','cylinder_finite','slab'}, 'sphere', 'geo_type');
        % 位点等效模式: derived = 由温压导出位点(发货默认); requested = 保持请求位点
        self.addDropdown(g, 1, 2, '位点等效模式', {'derived','requested'}, ...
            'derived', 'site_mode');
        % 反解按钮只输出建议压强 (同一密度模型下的数学解), 不写配置也不写界面取值
        bSolve = uibutton(g, 'Text', '求解满足请求位点所需压强', ...
            'Tooltip', '只给出建议值: 同一气体密度模型下满足请求位点所需的压强; 不修改配置与界面取值', ...
            'ButtonPushedFcn', @(~,~) self.onSolveSitePressure());
        bSolve.Layout.Row = 1; bSolve.Layout.Column = [5 6];
        self.Buttons.solve_site_pressure = bSolve;
        order = {'geo_R','geo_wall','geo_len','geo_anode','site_d','gas_p', ...
                 'gas_T','gas_W','gas_F','gas_ch4','gas_co2','gas_n2'};
        for i = 1:numel(order)
            r = 1 + ceil(i/3);                 % 卡片行 2..5
            c = 1 + 3*mod(i-1, 3);             % 每张卡占两列 (标签列 + 控件列)
            self.addParamCard(g, order{i}, r, c);
        end
        % 多行说明必须用 uitextarea 承载: uilabel 在本网格里不随单元格撑开, 实测三行
        % 文字只给到 22 px (需 ~54 px), 第二行被水平切半、第三行整行不可见。
        % 本文件其它多行说明 (:618) 用的就是 uitextarea, 此处与之同法。
        nt = uitextarea(g, 'Editable', false, 'Value', {'位点等效只有两个自由度(压强/位点直径): derived 自洽但位点非请求值;', ...
            'requested 保留请求位点, 偏差在降级路径上处理 (VALIDATED 模式下 FAIL)。', ...
            '卡片提示行里的"范围"取自服务层的判定口径 (尺寸为正、组分之和=1), 步长只是增量。'});
        nt.Layout.Row = 6; nt.Layout.Column = [1 6];
        g.RowHeight(6) = {3*18 + 8};
        nt.FontColor = Theme.ColorMuted;
        self.MutedControls{end+1} = nt;
        out = uitextarea(g, 'Editable', false, 'Value', {'几何/气体派生量: 校验后显示'});
        out.Layout.Row = 7; out.Layout.Column = [1 6];
        self.Fields.geom_out = out;
        self.AxGeom = uiaxes(g);
        self.AxGeom.Layout.Row = 8; self.AxGeom.Layout.Column = [1 6];
        title(self.AxGeom, '几何截面 (mm)');
        self.logGeomTabBudget(g);
    end

    function addParamCard(self, g, tag, row, col)
        %ADDPARAMCARD 一张参数卡片 -> 界面控件表 + 卡片表, 并把改动挂回状态源。
        %   EditorFlavor='text': 本机 uieditfield('numeric') 的 Value 只接数值
        %   (实测赋 '77' 也抛 MATLAB:ui:NumericEditField:invalidValue), 而界面回填
        %   (applyConfig) 与用例都按字符写这一格; 卡片改用文本承载 + 数值步长控件,
        %   合法域由 AppState 的 min/max 判定并印在提示行上。
        card = ParameterCard(g, self.cardSpec(tag), ...
            struct('Layout', 'compact', 'EditorFlavor', 'text'));
        card.place(row, col, 2);
        card.OnChange = @(evt) self.onCardChange(evt);
        self.Fields.(tag) = card.Editor;
        self.Cards{end+1} = card;
    end

    function onCardChange(self, evt)
        %ONCARDCHANGE 卡片改动 -> 解析 -> 写状态源 (一次输入排一次延后重算)。
        %   解析失败不写: 状态源里只留合法值, 非法文本由 gatherConfig 点名报错,
        %   两处都写会把一个"暂时打错的字符串"当成配置值参与派生量重算。
        if isempty(self.State) || self.State.isClosed() || isempty(evt)
            return;
        end
        tag = char(string(Theme.optOr(evt, 'tag', '')));
        if isempty(tag), return; end
        kind = self.kindOf(tag);
        [v, ok] = self.parseValue(Theme.optOr(evt, 'value', ''), kind);
        if ~ok
            % 就地校验的失败也要看得见: 把"这一格不是有限实数"直接挂到卡片提示行
            self.State.setField(tag, str2double(char(string(Theme.optOr(evt, 'value', '')))));
        else
            self.State.setField(tag, v);
        end
        self.refreshCardIssues(tag);
    end

    function refreshCardIssues(self, oneTag)
        %REFRESHCARDISSUES 把状态源的就地校验结论画到卡片提示行上。
        %   合法域 (min/max) 只在 AppState 一处判定, 界面上不复制第二份规则;
        %   来源徽标不跟着变 —— "合法但来源是假设"与"非法"是两件事, 挤在一起会互相掩盖。
        if isempty(self.State) || self.State.isClosed(), return; end
        for i = 1:numel(self.Cards)
            tag = self.Cards{i}.Tag;
            if nargin >= 2 && ~strcmp(tag, oneTag), continue; end
            try
                self.Cards{i}.showIssues(self.State.fieldIssues(tag));
            catch
                % silent-by-design: 单张卡片的提示行刷不上不影响取值与校验
            end
        end
    end

    % ---------- 字段描述 (映射表 + 单位/合法域/步长/来源) ----------
    function m = fieldMeta(self)
        %FIELDMETA tag -> {显示名(不含单位), 单位, 下限, 上限, 步长}。
        %   下限/上限不是新造的物理约束: 服务层判的是"尺寸为正/有限"与"组分之和=1"
        %   (src/+tepc/+config/validate.m), 这里把那两条口径搬到界面上显示;
        %   没登记的字段留空 -> 卡片提示行显式印"未登记范围"。
        %   步长只是 uispinner 的增量, 不参与任何判定。
        rows = { ...
          'geo_R',    '气腔半径',    'mm',      0, [],  0.1; ...
          'geo_wall', '壁厚',        'mm',      0, [],  0.1; ...
          'geo_len',  '圆柱长/板厚',  'mm',      0, [],  1;   ...
          'geo_anode','阳极半径',    'um',      0, [],  1;   ...
          'site_d',   '位点直径',    'um',      0, [],  0.1; ...
          'gas_p',    '压强',        'Pa',      0, [],  10;  ...
          'gas_T',    '温度',        'K',       0, [],  0.5; ...
          'gas_W',    'W 值',        'eV',      0, [],  0.1; ...
          'gas_F',    'Fano',        '',        0, 1,   0.01; ...
          'gas_ch4',  'CH4 摩尔分数', 'mol/mol', 0, 1,   0.01; ...
          'gas_co2',  'CO2 摩尔分数', 'mol/mol', 0, 1,   0.01; ...
          'gas_n2',   'N2 摩尔分数',  'mol/mol', 0, 1,   0.01};
        m = struct();
        m.rows = rows;
        m.n = size(rows, 1);
    end

    function S = fieldSchema(self)
        %FIELDSCHEMA 界面映射表 + 单位/域/步长/来源状态 -> AppState 的字段描述表。
        %   列序按 AppState.toSchema: {tag, path, kind, min, max, step, unit,
        %   value_status, items}。字段路径的唯一出处仍是 cfgMap(), 这里只做拼接。
        M = self.cfgMap();
        meta = self.fieldMeta();
        sc = self.statusLookup();
        S = cell(size(M, 1), 9);
        for i = 1:size(M, 1)
            tag = M{i, 1}; path = M{i, 2}; kind = M{i, 3};
            S{i, 1} = tag; S{i, 2} = path; S{i, 3} = kind;
            S{i, 4} = []; S{i, 5} = []; S{i, 6} = []; S{i, 7} = '';
            k = self.metaRow(meta, tag);
            if ~isempty(k)
                S{i, 4} = meta.rows{k, 4};
                S{i, 5} = meta.rows{k, 5};
                S{i, 6} = meta.rows{k, 6};
                S{i, 7} = meta.rows{k, 3};
            end
            S{i, 8} = self.statusOf(sc, path);
            S{i, 9} = [];
            if isfield(self.Fields, tag) && isa(self.Fields.(tag), 'matlab.ui.control.DropDown')
                S{i, 9} = cellstr(string(self.Fields.(tag).Items));
            end
        end
    end

    function k = metaRow(~, meta, tag)
        k = [];
        for i = 1:meta.n
            if strcmp(meta.rows{i, 1}, tag), k = i; return; end
        end
    end

    function sc = statusLookup(self)
        %STATUSLOOKUP 配置文件自带的 {value,status,source} 标签 -> 点分路径表。
        %   来源状态不在界面里另立一份: 只读服务层 statusScan 的结果。
        %   键里有小数点, 不能当结构体字段 -> 用两条并列的元胞数组做线性查表。
        sc = struct('names', {{}}, 'statuses', {{}});
        cfg = self.controllerOrFileCfg();
        if isempty(cfg) || ~isstruct(cfg), return; end
        try
            T = tepc.config.statusScan(cfg);
        catch
            % silent-by-design: 服务层不可用时不猜任何来源状态, 徽标退回缺省词
            return;
        end
        if isempty(T), return; end
        n = height(T);
        names = cell(1, n);
        sts = cell(1, n);
        for i = 1:n
            names{i} = char(string(T.name(i)));
            sts{i} = char(string(T.status(i)));
        end
        sc.names = names;
        sc.statuses = sts;
    end

    function s = statusOf(~, sc, path)
        %STATUSOF 字段路径 -> 来源状态词。'gas.W_eV.value' 的标签挂在父节点上,
        %   所以先按去掉尾部字段名的路径查, 再按整条路径查; 两处都没有就是缺省词。
        s = '';
        cand = path;
        if numel(cand) > 1 && any(strcmp(cand{end}, {'value', 'enabled'}))
            cand = cand(1:end-1);
        end
        keys = {strjoin(cand, '.'), strjoin(path, '.')};
        for i = 1:numel(keys)
            k = find(strcmp(sc.names, keys{i}), 1);
            if ~isempty(k) && ~isempty(strtrim(sc.statuses{k}))
                s = sc.statuses{k};
                return;
            end
        end
        % 配置里没带来源标签的字段: 值确实来自配置文件, 没有任何实测背书
        s = 'MEASURED_CONFIG';
    end

    function spec = cardSpec(self, tag)
        %CARDSPEC 一条字段描述 -> ParameterCard 的入参。
        M = self.cfgMap();
        meta = self.fieldMeta();
        sc = self.statusLookup();
        spec = struct('Tag', tag, 'Label', tag, 'Kind', 'num', 'Unit', '', ...
            'Min', [], 'Max', [], 'Step', [], 'Value', '', 'ValueStatus', 'UNKNOWN', ...
            'Format', '%.10g', 'Items', {{}});
        rowK = self.metaRow(meta, tag);
        for i = 1:size(M, 1)
            if ~strcmp(M{i, 1}, tag), continue; end
            spec.Kind = M{i, 3};
            [v0, found] = self.getPath(self.controllerOrFileCfg(), M{i, 2});
            if found && isnumeric(v0) && isscalar(v0) && isfinite(double(v0))
                spec.Value = double(v0);
            elseif found
                spec.Value = char(string(v0));
            end
            spec.ValueStatus = self.statusOf(sc, M{i, 2});
        end
        if ~isempty(rowK)
            spec.Label = meta.rows{rowK, 2};
            spec.Unit = meta.rows{rowK, 3};
            spec.Min = meta.rows{rowK, 4};
            spec.Max = meta.rows{rowK, 5};
            spec.Step = meta.rows{rowK, 6};
        end
    end

    function cfg = controllerOrFileCfg(self)
        %CONTROLLERORFILECFG 卡片初值的取数处: 已校验配置优先, 否则读界面选中的文件。
        if ~isempty(self.Controller.cfg)
            cfg = self.Controller.cfg;
            return;
        end
        cfg = struct();
        try
            cfg = tepc.config.load(self.resolveConfigPath());
        catch
            % silent-by-design: 配置文件读不到时卡片按界面缺省值走, 不额外弹窗
        end
    end

    function lb = mutedLabel(self, g, row, col, txt)
        %MUTEDLABEL 说明性文字: 用弱化字色登记进 MutedControls, applyTheme 刷正文色时跳过。
        %   不登记的话会被统一刷成主字色, 说明与取值就没有视觉层级了。
        lb = uilabel(g, 'Text', txt);
        lb.Layout.Row = row;
        lb.Layout.Column = col;
        lb.FontColor = Theme.ColorMuted;
        self.MutedControls{end+1} = lb;
    end

    function g = newGrid(self, tab, nCols, nRows)
        if nargin < 4, nRows = 12; end
        g = uigridlayout(tab);
        g.ColumnWidth = repmat({Theme.LabelColW, '1x'}, 1, max(1, nCols));
        g.RowHeight = repmat({Theme.FormRowH}, max(1, nRows), 1);
        g.Padding = [Theme.GapS Theme.GapS Theme.GapS Theme.GapS];
        g.RowSpacing = Theme.GapXS;
        g.ColumnSpacing = Theme.GapS;
    end

    function addField(self, g, row, col, label, default, tag, editable)
        if nargin < 8, editable = true; end
        lb = uilabel(g, 'Text', label);
        lb.Layout.Row = row; lb.Layout.Column = 2*(col-1)+1;
        lb.HorizontalAlignment = 'right';
        ed = uieditfield(g, 'text', 'Value', default);
        ed.Layout.Row = row; ed.Layout.Column = 2*(col-1)+2;
        ed.Editable = editable;
        self.Fields.(tag) = ed;
    end

    function addDropdown(self, g, row, col, label, items, def, tag)
        %ADDDROPDOWN 标签+下拉成对放置 (与 addField 同一列网格, 不产生孤儿控件)
        lb = uilabel(g, 'Text', label);
        lb.Layout.Row = row; lb.Layout.Column = 2*(col-1)+1;
        lb.HorizontalAlignment = 'right';
        dd = uidropdown(g, 'Items', items);
        dd.Layout.Row = row; dd.Layout.Column = 2*(col-1)+2;
        dd.Value = def;
        self.Fields.(tag) = dd;
    end

    function buildProjectTab(self, tab)
        g = self.newGrid(tab, 2, 7);
        self.addField(g, 1, 1, '事件数 N', '10000', 'run_nEvents');
        self.addField(g, 1, 2, '随机种子', '12345', 'run_seed');
        % 发布模式: 唯一控件 = 下拉 (原实现先建编辑框再用同名键覆盖, 留下无用控件,
        % 且 gatherConfig 从不读取它 -> cfg.run.mode 恒为 JSON 值, 门禁 12 永不触发)
        self.addDropdown(g, 2, 1, '发布模式', {'RESEARCH_DEMO','VALIDATED'}, ...
            'RESEARCH_DEMO', 'run_mode');
        self.addField(g, 2, 2, '分块 chunk', '2000', 'run_chunk');
        self.addField(g, 3, 1, '配置文件', 'config/defaults/demo_only.json', 'cfg_path');
        bLoad = uibutton(g, 'Text', '载入配置', 'ButtonPushedFcn', @(~,~) self.onLoadConfig());
        bLoad.Layout.Row = 3; bLoad.Layout.Column = 4;
        self.Buttons.load = bLoad;
        bVal = uibutton(g, 'Text', '校验配置', 'ButtonPushedFcn', @(~,~) self.onValidate());
        bVal.Layout.Row = 4; bVal.Layout.Column = 4;
        self.Buttons.validate = bVal;
        lbl = uilabel(g, 'Text', {'项目说明: 纯 MATLAB 解析/经验基线; 未用蒙卡输运;', ...
            '未经参考场标定, 输出仅限 RESEARCH/DEMO。', ...
            '注意: [运行] 使用当前"配置文件"路径 + 本窗口全部界面值。'});
        lbl.Layout.Row = 5; lbl.Layout.Column = [1 4];
        lbl.FontColor = [0.35 0.35 0.35];
        % 多行文字的行高必须与行数相称: 留 'auto' 时本行会被下面固定 140 px 的
        % uitextarea 挤压, 实测第 2 行被水平切掉一半、第 3 行整行不可见。
        g.RowHeight(5) = {3*18 + 8};
        ta = uitextarea(g, 'Editable', false, 'Value', {'provenance: 未运行'});
        ta.Layout.Row = 6; ta.Layout.Column = [1 4]; g.RowHeight(6) = {140};
        self.Fields.provenance = ta;
    end

    function buildFieldTab(self, tab)
        g = self.newGrid(tab, 3, 7);
        self.addField(g, 1, 1, '高压 V', '700', 'field_hv');
        self.addField(g, 2, 1, 'Diethorn ΔV', '36.5', 'field_dV');
        self.addField(g, 3, 1, '增益模式', 'analytic_diethorn', 'field_mode');
        out = uitextarea(g, 'Editable', false, 'Value', {'增益/雪崩: 校验后显示'});
        out.Layout.Row = 4; out.Layout.Column = [1 4]; g.RowHeight(4) = {60};
        self.Fields.field_out = out;
        self.AxField = uiaxes(g);
        self.AxField.Layout.Row = 6; self.AxField.Layout.Column = [1 6];
        g.RowHeight(6) = {230};
        title(self.AxField, 'E(r) 与 E/N (校验后绘制)');
    end

    function buildSourceTab(self, tab)
        g = self.newGrid(tab, 3, 8);
        self.addDropdown(g, 1, 1, '源类型', ...
            {'mono_neutron','mono_gamma','mixed'}, 'mono_neutron', 'src_type');
        self.addField(g, 2, 1, '能量 MeV', '1.0', 'src_E');
        self.addField(g, 3, 1, '计数率 cps', '100', 'src_rate');
        self.addField(g, 4, 1, '注量 m^-2', '1e6', 'src_flu');
        self.addDropdown(g, 5, 1, '到达模型', {'poisson','fixed'}, 'poisson', 'src_arr');
        nt = uitextarea(g, 'Editable', false, 'Value', ...
            {'通道权重: 弹性 H/C/O, 截面为 ASSUMED 演示值;', ...
             '解析基线不宣称中子/伽马输运精度。', ...
             'mixed 源需 classPrior, 界面不提供 -> 请在配置文件中给出。', ...
             '到达模型 fixed 使用全局事件序号, 跨块时间戳不重复。'});
        nt.Layout.Row = 2; nt.Layout.Column = [3 6]; g.RowHeight(2) = {110};
    end

    function buildElecTab(self, tab)
        g = self.newGrid(tab, 3, 8);
        self.addField(g, 1, 1, 'Cf F', '1e-12', 'el_cf');
        self.addField(g, 1, 2, '触发阈值 V', '0.02', 'el_thr');
        self.addField(g, 1, 3, 'ADC bits', '14', 'el_bits');
        self.addField(g, 2, 1, 'Rf Ohm', '5e7', 'el_rf');
        self.addField(g, 2, 2, '迟滞 V', '0.005', 'el_hyst');
        self.addField(g, 2, 3, '满量程 V', '2.0', 'el_fs');
        self.addField(g, 3, 1, '成形时间 s', '1e-6', 'el_tau');
        self.addField(g, 3, 2, '死时间 s', '1e-5', 'el_dt');
        self.addField(g, 3, 3, '量程2 增益', '32', 'el_g2');
        self.addField(g, 4, 1, '采样 Ts s', '1e-8', 'el_ts');
        self.addField(g, 4, 2, '波形窗 s', '1.2e-5', 'el_wwin');
        self.addField(g, 4, 3, 'pile-up 拒绝 s', '3e-6', 'el_pu');
        self.addDropdown(g, 5, 1, '死时间模型', ...
            {'nonparalyzable','paralyzable'}, 'nonparalyzable', 'el_dtmode');
        nt = uitextarea(g, 'Editable', false, 'Value', ...
            {'链: Ramo 波形 -> CSA->PZ(匹配)->CR-RC(sos 级联)->串联噪声->峰/触发->双量程 ADC;', ...
             '两个量程各占码域 [0,2^bits-1], 由 RANGE2 标志区分; 标定/反演在线性化的等效码上;', ...
             '量程2 上限 = 满量程 V × 量程2 增益 (须覆盖最高沉积能的峰值电压, 否则大面积饱和);', ...
             '标定: 电荷注入扫描与测量共用同一条正向链。'});
        nt.Layout.Row = 6; nt.Layout.Column = [1 6]; g.RowHeight(6) = {90};
    end

    function buildRunTab(self, tab)
        g = self.newGrid(tab, 4, 14);
        g.RowHeight = repmat({30}, 14, 1);
        bRun = uibutton(g, 'Text', '▶ 运行 (Run)', 'BackgroundColor', [0.2 0.6 0.2], ...
            'FontColor', 'w', 'ButtonPushedFcn', @(~,~) self.onRun());
        bRun.Layout.Row = 1; bRun.Layout.Column = 1;
        bPause = uibutton(g, 'Text', '⏸ 暂停', 'ButtonPushedFcn', @(~,~) self.onPauseToggle());
        bPause.Layout.Row = 1; bPause.Layout.Column = 2;
        bCancel = uibutton(g, 'Text', '✖ 取消', 'BackgroundColor', [0.8 0.25 0.2], ...
            'FontColor', 'w', 'ButtonPushedFcn', @(~,~) self.onCancel());
        bCancel.Layout.Row = 1; bCancel.Layout.Column = 3;
        self.Buttons.run = bRun; self.Buttons.pause = bPause; self.Buttons.cancel = bCancel;
        self.ProgBar = uigauge(g, "linear");
        self.ProgBar.Layout.Row = 2; self.ProgBar.Layout.Column = [1 8];
        % 量规的缺省量程是 [0 100] (本机 R2025a 实测 Limits_default=[0 100]), 而 onProgress 写进来的
        % 是 execute 的 prog(frac) 分数 0..1 —— 两边不同代时 0.92 只填 0.92%, 整轮运行看着像一直是 0。
        % 量程对齐到 0..1 同时消掉了原来的刻度拥挤: 1030 px 宽上 0..100 步长 2 会印 51 个标签。
        self.ProgBar.Limits = [0 1];
        self.ProgBar.Value = 0;

        self.LogList = uitextarea(g, 'Editable', false);
        self.LogList.Layout.Row = 3; self.LogList.Layout.Column = [1 8];
        g.RowHeight(3) = {'1x'};
        self.LogList.Value = {'[日志] 空闲'};
    end

    function buildSpecTab(self, tab)
        g = self.newGrid(tab, 4, 4);
        dd = uidropdown(g, 'Items', {'线性 y f(y)','对数 y d(y)','f(y) 对数轴'});
        dd.Layout.Row = 1; dd.Layout.Column = [1 2];
        dd.Value = '对数 y d(y)';
        dd.ValueChangedFcn = @(~,~) self.redrawSpectrum();
        self.Fields.spec_mode = dd;
        out = uitextarea(g, 'Editable', false, 'Value', {'yF/yD/Qbar/D: 运行后显示'});
        out.Layout.Row = 1; out.Layout.Column = [3 8]; g.RowHeight(1) = {150};
        % 宽度给满整行: 剂量行与深度行各 100~220 字符, 只给 4 格时一行会折成 2~3 个视觉行,
        % 150 px 的预留高度就被折行吃掉, 末尾两行掉进滚动区。行高实测约 13 px/视觉行。
        % 预留高度按行数给: showResult 满负荷发 8 行 (yF/yD、剂量、n_eff、深度、矩的总体、
        % 仪器链、真值与刻度偏差、位点)。uitextarea 装不下时不报错也不提示, 只把多出的行
        % 折进滚动区 —— 屏幕上看不见的那一行, 等于没有披露。
        self.Fields.spec_out = out;
        self.AxSpectrum = uiaxes(g);
        self.AxSpectrum.Layout.Row = 3; self.AxSpectrum.Layout.Column = [1 8];
        g.RowHeight(3) = {'1x'};
        title(self.AxSpectrum, '线能谱 (运行后显示)');
    end

    function buildGeom3dTab(self, tab)
        %三维几何页。
        %   纪律: 本页**只读已解析的 R** (meshSpec(cfg,R)), 不在 GUI 里重算位点/场;
        %   几何证据由 checkMesh/exportGeometry 产出 (含 manifest 与哈希), 截图只是副产品。
        % 第 4 行是空的: 它不属于任何控件, 只给 'southoutside' 图例留出净空 (图例的父级是
        % 本页网格, 不是坐标区那一格)。没有这一行时 25 项图例从坐标区下沿一路长出网格外,
        % 既被窗口下沿裁掉约 18 条, 又压住按钮行。
        g = self.newGrid(tab, 4, 6);
        dd = uidropdown(g, 'Items', {'剖切图','爆炸图','结果叠加'}, ...
            'ValueChangedFcn', @(~,~) self.onPreview3d());
        dd.Layout.Row = 1; dd.Layout.Column = [1 2]; dd.Value = '剖切图';
        self.Fields.geo3_view = dd;
        out = uitextarea(g, 'Editable', false, ...
            'Value', {'点击 [刷新三维] 生成几何规格 + 网格门禁结果 (需先 [校验配置])'});
        out.Layout.Row = 1; out.Layout.Column = [3 8]; g.RowHeight(1) = {70};
        self.Fields.geo3_out = out;
        self.AxGeom3D = uiaxes(g);
        self.AxGeom3D.Layout.Row = 3; self.AxGeom3D.Layout.Column = [1 8];
        g.RowHeight(3) = {'1x'};
        g.RowHeight(4) = {Theme.LegendBandH};
        title(self.AxGeom3D, '三维几何 (运行前即可预览; 只画配置里的实体)');
        b1 = uibutton(g, 'Text', "⟳ 刷新三维", 'ButtonPushedFcn', @(~,~) self.onPreview3d());
        b1.Layout.Row = 5; b1.Layout.Column = 1;
        b2 = uibutton(g, 'Text', "⤓ 导出网格+清单", 'ButtonPushedFcn', @(~,~) self.onExport3d());
        b2.Layout.Row = 5; b2.Layout.Column = 2;
        b3 = uibutton(g, 'Text', "⧉ 打开三维工作台", 'ButtonPushedFcn', @(~,~) self.onOpen3dWorkbench());
        b3.Layout.Row = 5; b3.Layout.Column = 3;
        self.Buttons.preview3d = b1; self.Buttons.export3d = b2; self.Buttons.open3dWorkbench = b3;
        self.buildGeom3dToolbar(g);
        nt = self.mutedLabel(g, 6, [1 8], {['图层开关的判据只认 renderTEPC3D 写进图元 UserData 的字段: ' ...
            'part_id / edge_overlay 归几何, 其余面片与线归场与叠加。'], ...
            '实测层没有图元可关 (仓库里没有实测数据): 复选框禁用并把原因写在文本上。'});
        nt.Layout.Row = 6; nt.Layout.Column = [1 8];
        g.RowHeight(6) = {Theme.HintH*2 + 6};
    end

    function buildGeom3dToolbar(self, g)
        %BUILDGEOM3DTOOLBAR 图区工具条挂在页签网格的第 2 行 (原来那行是空的 28 px)。
        %   工具条自己不调任何绘图函数: 它只把"用户要什么"交回本类的三个挂载点。
        %   三层在本页的口径 (名字由宿主给, 组件不猜):
        %     geometry 几何实体        = 清单里参与审计的实体面片
        %     field    场与叠加图元    = 解析场线/等位面与 overlay 线段
        %     measured 实测轮廓        = 仓库里没有实测数据 -> 不可开, 复选框禁用并写明原因
        g.RowHeight(2) = {Theme.ToolToolbarH};
        opts = struct();
        opts.CommandText = self.reproCommand();
        opts.ExportName = 'tepc_geom3d';
        opts.Layers = {{'geometry', '● 几何 Geometry', Theme.ColorInk}, ...
            {'field', '▲ 场与叠加 Field/overlay', Theme.ColorAccent}, ...
            {'measured', '■ 实测 Measured', Theme.ColorWarn}};
        opts.Unavailable = {'measured'};
        self.Toolbar = PlotToolbar(g, opts);
        self.Toolbar.Root.Layout.Row = 2;
        self.Toolbar.Root.Layout.Column = [1 8];
        self.Toolbar.OnViewPreset = @(req) self.onToolbarView(req);
        self.Toolbar.OnExport = @(req) self.onToolbarExport(req);
        self.Toolbar.OnLayers = @(req) self.onToolbarLayers(req);
    end

    function cmd = reproCommand(self)
        %REPROCOMMAND 一条能从命令行重跑同一配置的命令 (剪贴板内容必须是真能跑的)。
        %   取数全部来自界面/已校验配置, 不写死任何路径或事件数。
        root = tepc.io.projectRoot();
        p = '';
        try
            p = self.resolveConfigPath();
        catch
            % silent-by-design: 路径解析失败时命令里留占位, 由用户补配置文件路径
        end
        if isempty(p), p = 'config/defaults/demo_only.json'; end
        n = '10000';
        sd = '12345';
        if isfield(self.Fields, 'run_nEvents')
            n = strtrim(char(string(self.Fields.run_nEvents.Value)));
        end
        if isfield(self.Fields, 'run_seed')
            sd = strtrim(char(string(self.Fields.run_seed.Value)));
        end
        cmd = ['cd ''' root '''; addpath(''src'',''app'',''app/components''); ' ...
            'cfg = tepc.config.load(''' p '''); ' ...
            sprintf('R = tepc.run.execute(cfg, ''N'', %s, ''Seed'', %s);', n, sd)];
    end

    function onToolbarView(self, req)
        %ONTOOLBARVIEW 视角预设 -> 只动相机, 不重画几何 (重画会丢已画的图元)。
        if isempty(self.AxGeom3D) || ~isvalid(self.AxGeom3D), return; end
        ax = self.AxGeom3D;
        try
            switch char(string(Theme.optOr(req, 'view', 'home')))
                case 'front', view(ax, [0 0]);        % 沿 -y 看 x-z 平面
                case 'side',  view(ax, [90 0]);       % 沿 -x 看 y-z 平面
                case 'top',   view(ax, [0 90]);       % 沿 -z 看 x-y 平面
                case 'iso',   view(ax, [37.5 30]);
                case 'fit'
                    axis(ax, 'tight');
                    camzoom(ax, 1);
                otherwise,    view(ax, [37.5 -30]);   % 复位 = MATLAB 三维缺省方位
            end
            self.log(sprintf('三维视角: %s', char(string(Theme.optOr(req, 'view', 'home')))));
        catch e
            self.noteUiError('切换三维视角失败', e);
        end
    end

    function onToolbarExport(self, req)
        %ONTOOLBAREXPORT 导出当前三维坐标区的图。
        %   只导出单个 uiaxes: 本机 exportgraphics 对多容器 uifigure 直接拒绝
        %   ("Figure has more than one container"), 整窗证据要走屏幕截图。
        try
            outDir = fullfile(tempdir, 'tepc_gui_plots');
            if ~isfolder(outDir), mkdir(outDir); end
            base = char(string(Theme.optOr(req, 'name', 'tepc_plot')));
            base = regexprep(base, '[^A-Za-z0-9_\-]', '_');
            fn = fullfile(outDir, sprintf('%s_%s.png', base, ...
                char(string(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS')))));
            exportgraphics(self.AxGeom3D, fn, 'Resolution', 150);
            self.setBanner('green', sprintf('三维图已导出 (单坐标区): %s', fn));
            self.log(['导出图: ' fn]);
        catch e
            self.noteUiError('导出三维图失败', e);
        end
    end

    function onToolbarLayers(self, req)
        %ONTOOLBARYLAYERS 图层开关 -> 按图元角色改 Visible。
        %   角色判定见 objectRoleOf (只认 renderTEPC3D 写进 UserData 的字段, 不靠
        %   DisplayName 文本猜)。各类图元的计数存进坐标区自己的 UserData, 供属性读取
        %   核验 —— 状态带/日志说"这一层有几个图元"必须有出处, 不能凭手感。
        try
            cnt = self.applyLayerRoles(req);
            self.log(sprintf(['图层切换: 几何 %d / 场与叠加 %d / 实测 %d / 不参与开关 %d ' ...
                '(几何层开=%d, 场层开=%d)'], cnt.geometry, cnt.field, cnt.measured, cnt.other, ...
            self.toolbarLayerOn(req, 'geometry'), self.toolbarLayerOn(req, 'field')));
            if cnt.geometry == 0 && cnt.field == 0
                self.log('提示: 当前坐标区里没有可切的图元 —— 先点 [刷新三维]。');
            end
        catch e
            self.noteUiError('切换图层失败', e);
        end
    end

    function cnt = applyLayerRoles(self, req)
        %APPLYLAYERROLES 按角色写 Visible 并回报各类图元数。
        cnt = struct('geometry', 0, 'field', 0, 'measured', 0, 'other', 0);
        if isempty(self.AxGeom3D) || ~isvalid(self.AxGeom3D)
            return;
        end
        ax = self.AxGeom3D;
        ch = ax.Children;
        for i = 1:numel(ch)
            role = self.objectRoleOf(ch(i));
            if ~isfield(cnt, role)
                cnt.other = cnt.other + 1;
                continue;
            end
            if strcmp(role, 'measured')
                % 实测层永远没有图元可关: 计数照常报 0, 由组件的复选框文本说明缺什么
                cnt.measured = cnt.measured + 0;
                continue;
            end
            self.setOpt(ch(i), 'Visible', ternaryWord(self.toolbarLayerOn(req, role), 'on', 'off'));
            cnt.(role) = cnt.(role) + 1;
        end
        try
            ud = ax.UserData;
            if ~isstruct(ud), ud = struct(); end
            ud.LayerCounts = cnt;
            ud.LastLayerRequest = req;
            ax.UserData = ud;
        catch
            % silent-by-design: 坐标区不接受自定义 UserData 时计数只留在日志里
        end
    end

    function on = toolbarLayerOn(~, req, role)
        on = false;
        if isempty(req) || ~isstruct(req) || ~isfield(req, 'layers')
            return;
        end
        if isfield(req.layers, role)
            on = logical(req.layers.(role));
        end
    end

    function role = objectRoleOf(~, obj)
        %OBJECTROLEOF 图元 -> 图层角色 ('geometry' | 'field' | 'other')。
        %   判据只有 renderTEPC3D 写进 UserData 的字段, 不读 DisplayName 文本:
        %     part_id        -> 清单里的实体面片 (含共面皮的描边层 edge_overlay)
        %     kind='watermark' -> 水印标注, 永远显示, 不参与图层开关
        %     其余带 UserData 结构体的面片/线 -> 解析场线、等位面与 overlay 轨迹
        %   没有 UserData 的对象 (坐标区装饰等) 一律算 other。
        role = 'other';
        ud = [];
        try
            ud = obj.UserData;
        catch
            % silent-by-design: 取不到 UserData 的对象不参与图层开关
            return;
        end
        if ~isstruct(ud) || isempty(ud)
            return;
        end
        if isfield(ud, 'kind') && strcmp(char(string(ud.kind(1))), 'watermark')
            return;
        end
        if isfield(ud, 'part_id')
            role = 'geometry';
            return;
        end
        if isfield(ud, 'edge_overlay') && logical(ud.edge_overlay)
            role = 'geometry';
            return;
        end
        role = 'field';
    end

    function spec = geom3dSpec(self)
        %从**已解析**配置构造几何规格; 不重算位点 (位点实现值来自 R.geom.site)。
        if isempty(self.Controller.cfg)
            error("tepc:gui:NoCfg", "请先 [校验配置]: 三维几何需要解析后的配置");
        end
        R = tepc.config.resolve(self.Controller.cfg);
        % 配置身份哈希由运行链产出 (execute.m 里 R.config_sha256 = idOut.sha256),
        % tepc.config.resolve 的返回结构没有这个字段 —— 早先按 resolve 的结果取它,
        % 每次预览都会抛 nonExistentField 并在日志里留一条永久的假告警。
        % 预览只有在跑过之后才谈得上哈希, 未运行时就是空串 (meshSpec 对空串有显式分支)。
        sha = "";
        if ~isempty(self.LastResult) && isfield(self.LastResult, 'config_sha256')
            sha = string(self.LastResult.config_sha256);
        end
        spec = tepc.geometry.meshSpec(self.Controller.cfg, R, sha);
    end

    function onOpen3dWorkbench(self)
        % 主界面此前没有进工作台的入口 (只能另起独立启动器), 于是"两级三维"对只用主界面的人
        % 是断的。工作台必须用**同一份已校验的配置**: 没有 Controller.cfg 时提示而不是拿
        % 默认配置偷偷开一台, 那会让人以为看到的是自己刚改的配置。
        if isempty(self.Controller.cfg)
            self.setBanner('orange', '打开三维工作台前请先点 [校验配置]: 工作台要用同一份解析后的配置。');
            return;
        end
        try
            TEPC3DWorkbench(self.Controller.cfg);
            self.setBanner('green', '三维工作台已打开 (Unique 默认生效: 重复点击收掉上一台再开新的)。');
        catch e
            self.noteUiError('三维工作台', e);
        end
    end

    function onPreview3d(self)
        try
            spec = self.geom3dSpec();
            M = tepc.geometry.checkMesh(spec);
            view = self.geo3dViewName();
            tr = [];
            if strcmpi(view, 'overlay')
                % 轨迹只能来自输运层的种子化服务 (图形层不许自带随机数): 固定取 1..8 号事件,
                % 与上一次运行结果无关, 所以连点两次"预览"画出来的是同一批线。
                cfg3 = self.Controller.cfg;
                tr = tepc.geometry.traceSpec(cfg3, tepc.config.resolve(cfg3), 1:8);
            end
            tepc.geometry.renderTEPC3D(spec, 'View', view, 'Traces', tr, 'Host', 'axes', ...
                'Parent', self.AxGeom3D, 'Units', 'mm');
            self.fitGeom3dLegend();
            rel = 100*(spec.realizedDiameter_m/max(spec.requestedDiameter_m,eps) - 1);
            ln1 = sprintf('敏感体积 %s / 电极拓扑 %s / 场 %s', ...
                char(spec.geometryType), char(spec.electrodeTopology), ...
                char(spec.fieldTopology));
            ln2 = sprintf('位点: 请求 %.3f um, 实现 %.3f um (相对差 %+.1f%%)', ...
                spec.requestedDiameter_m*1e6, spec.realizedDiameter_m*1e6, rel);
            ln3 = sprintf(['世界体 >= %.1fx 包络; 网格门禁: 闭合=%d ' ...
                '非流形边=%d 零面积面=%d'], ...
                spec.worldEnvelopeFactor, M.closed, M.nonmanifold_edges, ...
                M.zero_area_faces);
            self.Fields.geo3_out.Value = {ln1; ln2; ln3};
            % 图元刚画完就按当前图层开关落一次 Visible, 并把各类图元的计数写进
            % 坐标区 UserData (属性读取能核验"这一层到底有没有东西")。
            if ~isempty(self.Toolbar)
                try
                    self.applyLayerRoles(self.Toolbar.request());
                catch e
                    self.noteUiError('三维图层应用失败', e);
                end
            end
            self.setBanner('green', '三维几何已刷新 (配置驱动, 无自带 RNG)');
        catch e
            self.noteUiError('三维预览失败', e);
        end
    end

    function lg = tabLegend(self)
        %TABLEGEND 取三维页那条零件图例 (与坐标区同挂在页签网格上)。
        %   按"与 AxGeom3D 同父"认: 谱页也有一条图例, 按条目数或位置挑都会挑错, 而父容器
        %   就是像素框所在的那个 GridLayout, 认它同时保证了后面读到的框与坐标区同代。
        %   matlab.graphics.illustration.Legend 没有 ItemsData, 条目数只能数 String。
        lg = [];
        if isempty(self.AxGeom3D) || ~isvalid(self.AxGeom3D), return; end
        lgs = findall(self.UIFigure, 'Type', 'Legend');
        for i = 1:numel(lgs)
            if isequal(lgs(i).Parent, self.AxGeom3D.Parent)
                lg = lgs(i); return
            end
        end
    end

    function fitGeom3dLegend(self)
        %FITGEOM3DLEGEND 把三维页的零件图例收进预留行, 实得几何留在坐标区 UserData 供界面测试核对。
        %   'southoutside' 图例挂在页签网格上, 所以它从坐标区下沿一路向下长: 25 项按两列排时
        %   实测高 166 px、顶边在坐标区下沿之下 32 px, 而坐标区以下原本只有 87 px —— 图例下溢
        %   网格 111 px (约 18 条被窗口下沿裁掉), 同时压住下面那行按钮。buildGeom3dTab 因此
        %   空出第 4 行 (Theme.LegendBandH) 专门给图例。
        %   列数与图例尺寸不是单调一维关系: 列多则行数少 (变矮) 但宽度成倍涨, 横竖都会出界,
        %   所以按**实测像素**取溢出最小的一档, 而不是照条目数算。
        if isempty(self.AxGeom3D) || ~isvalid(self.AxGeom3D), return; end
        lg = self.tabLegend();
        if isempty(lg), return; end
        % 像素框都按图例自己的父容器读 (Position 就是相对它的), 再核对坐标区与图例同父,
        % 否则"网格高"与图例框不同代, 判据算出来的越界量没有意义。
        g = lg.Parent;
        % 核对坐标区确实挂在这个父容器上 (而不是"图例与坐标区的父恰好是同一个对象"这种
        % 由上一步挑法保证的恒真式): 像素框与网格高不同代时越界量没有意义。
        kids = g.Children;
        axesInGrid = false;
        for q = 1:numel(kids)
            if isequal(kids(q), self.AxGeom3D), axesInGrid = true; break; end
        end
        sameParent = axesInGrid && isequal(g, self.AxGeom3D.Parent);
        if ~sameParent || ~isprop(g, 'Position'), return; end
        if isprop(lg, 'Units'), lg.Units = 'pixels'; end
        maxW = g.Position(3) - 2*Theme.GapS;
        gridH = g.Position(4);
        band = Theme.LegendBandH;
        ovFinal = Inf;
        for grow = 1:4
            bestOv = Inf; bestNc = lg.NumColumns;
            for nc = 2:5
                lg.NumColumns = nc;
                drawnow;
                p = lg.Position;
                ov = max(0, -p(2)) + max(0, p(2) + p(4) - gridH) + max(0, p(3) - maxW) ...
                    + 1e4 * self.legendClashes(p, self.legendRowBoxes());
                if ov < bestOv, bestOv = ov; bestNc = nc; end
                if ov == 0, break; end
            end
            ovFinal = bestOv;
            lg.NumColumns = bestNc;
            drawnow;
            if bestOv == 0, break; end
            band = band + 40;
            g.RowHeight(4) = {band};
            drawnow;
        end
        p = lg.Position;
        units = 'n/a';
        if isprop(lg, 'Units'), units = lower(char(lg.Units)); end
        nf = struct( ...
            'legend_box_px', p, 'legend_units', units, 'legend_cols', lg.NumColumns, ...
            'legend_band_px', band, 'legend_grid_px', g.Position, ...
            'legend_max_width_px', maxW, 'legend_entries', numel(lg.String), ...
            'legend_axes_same_parent', sameParent, 'legend_clash', ovFinal, ...
            'legend_inside', strcmp(units, 'pixels') && p(2) >= 0 ...
                && p(2) + p(4) <= gridH && p(3) <= maxW);
        prev = self.AxGeom3D.UserData;
        if ~isstruct(prev), prev = struct(); end
        flds = fieldnames(nf);
        for q = 1:numel(flds)
            prev.(flds{q}) = nf.(flds{q});
        end
        self.AxGeom3D.UserData = prev;
    end

    function boxes = legendRowBoxes(self)
        %LEGENDROWBOXES 三维页里与图例同在一个页签网格中的控件像素框 (Nx4)。
        %   按"与坐标区同父"筛而不是把控件名字列一遍: 本页以后添控件不用回来改这里。
        boxes = zeros(0, 4);
        if isempty(self.AxGeom3D) || ~isvalid(self.AxGeom3D), return; end
        par = self.AxGeom3D.Parent;
        flds = fieldnames(self.Buttons);
        for q = 1:numel(flds)
            h = self.Buttons.(flds{q});
            if isgraphics(h) && isequal(h.Parent, par)
                boxes(end+1, :) = h.Position; %#ok<AGROW>
            end
        end
    end

    function k = legendClashes(self, box, boxes)
        %LEGENDCLASHES 与图例像素框有实在面积交 (大于 1x1 px) 的兄弟控件个数。
        k = 0;
        for q = 1:size(boxes, 1)
            bx = boxes(q, :);
            xOv = min(box(1) + box(3), bx(1) + bx(3)) - max(box(1), bx(1));
            yOv = min(box(2) + box(4), bx(2) + bx(4)) - max(box(2), bx(2));
            if xOv > 1 && yOv > 1, k = k + 1; end
        end
    end

    function onExport3d(self)
        try
            spec = self.geom3dSpec();
            % exportGeometry 的第 2 参是**文件基名** (它用 fileparts 拆目录/前缀),
            % 不是目录: 只传目录会让所有文件平铺进 tempdir, 而横幅却说"导出到 <目录>"。
            outDir = fullfile(tempdir, sprintf('tepc_geom3d_%s_%d', ...
                char(string(datetime('now','TimeZone','UTC','Format','yyyyMMdd_HHmmssSSS'))), ...
                feature('getpid')));
            man = tepc.geometry.exportGeometry(spec, fullfile(outDir, 'tepc_geometry'));
            np = 0;
            if isfield(man, 'parts'), np = numel(man.parts); end
            ln1 = sprintf('导出到 %s', outDir);
            ln2 = sprintf('schema=%s; 零件数=%d; 导出单位=%s (系数 %g/m)', ...
                string(man.schema), np, string(man.units_export), man.unit_scale_from_m);
            ln3 = sprintf('config_sha=%s; geometry_sha=%s', ...
                string(man.source_config_sha256), string(man.geometry_sha256));
            ln4 = '注意: STL 本身不带单位, 单位只写在文件名与清单里 (乘错单位就是 1000 倍)';
            self.Fields.geo3_out.Value = {ln1; ln2; ln3; ln4};
            self.setBanner('green', '三维网格与几何清单已导出');
        catch e
            self.noteUiError("三维导出失败", e);
        end
    end

    function v = geo3dViewName(self)
        switch char(string(self.Fields.geo3_view.Value))
            case '爆炸图',   v = 'exploded';
            case '结果叠加', v = 'overlay';
            otherwise,       v = 'section';
        end
    end

    function buildReportTab(self, tab)
        % 验证与报告页: 上半是本次运行的门禁表, 下半是能力登记表的证据面板。
        %   两块的分工不同 —— 门禁表说"这一轮跑出来的结论", 证据面板说"哪些能力
        %   在登记表里是 DONE / PARTIAL / BLOCKED / EXCLUDED", 措辞只从表里取。
        g = self.newGrid(tab, 4, 4);
        g.RowHeight = {'1x', Theme.EvidenceH, Theme.FormRowH, Theme.FormRowH};
        self.GatesTable = uitable(g);
        self.GatesTable.ColumnName = {'门禁项', '状态', '数值', '细节'};
        self.GatesTable.RowName = {};
        self.GatesTable.Layout.Row = 1; self.GatesTable.Layout.Column = [1 8];
        self.GatesTable.ColumnWidth = {200, 110, 110, '1x'};
        self.Evidence = EvidencePanel(g);
        self.Evidence.Root.Layout.Row = 2;
        self.Evidence.Root.Layout.Column = [1 8];
        self.takeRegisterBlockers();
        bRep = uibutton(g, 'Text', '导出 HTML 报告', 'ButtonPushedFcn', @(~,~) self.onExport());
        bRep.Layout.Row = 3; bRep.Layout.Column = 1;
        self.Buttons.export = bRep;
        bRel = uibutton(g, 'Text', '重读能力登记表', ...
            'Tooltip', '重新按字节读 config/capability_register.json 并刷新计数与未关闭项', ...
            'ButtonPushedFcn', @(~,~) self.onReloadRegister());
        bRel.Layout.Row = 3; bRel.Layout.Column = 2;
        self.Buttons.reload_register = bRel;
    end

    % takeRegisterBlockers 只在文件后部定义一次 (带可选 R)。这里曾出现过第二份
    % 窄签名定义, 两份同名方法会让整个 classdef 无法加载 (MATLAB:class:DuplicateMethod),
    % 而 checkcode 只报 parse=0 —— 类定义改动必须由实际构造一次来验。

    function onReloadRegister(self)
        %ONRELOADREGISTER 重读登记表 -> 刷新计数 -> 刷状态带。失败也在面板上显式可见。
        try
            if isempty(self.Evidence)
                self.setBanner('orange', '证据面板没建起来, 无从重读登记表。');
                return;
            end
            self.Evidence.reload();
            self.takeRegisterBlockers();
            self.refreshStatusStrip();
            st = self.Evidence.state();
            if st.loaded
                self.setBanner('green', sprintf('能力登记表已重读: %d 条, 未关闭 %s 条。', ...
                    st.n_entries, mat2str(st.open_blockers)));
            else
                self.setBanner('orange', ['能力登记表重读失败: ', st.load_error]);
            end
            self.log(sprintf('重读登记表: %s (loaded=%d)', self.Evidence.Path, st.loaded));
        catch e
            self.noteUiError('重读登记表失败', e);
        end
    end

    % ---------- 横幅与状态 ----------
    function setBanner(self, color, msg)
        if ~self.uiAlive(), return; end
        % 三色 + 图标双通道的色值一律取 Theme 状态色板 (tint 后的淡底),
        % 图标字符与文字前缀是同一状态词的另两个通道, 不允许只换底色。
        switch color
            case 'red',    c = Theme.tint(Theme.ColorBad, 0.14); ic = '[✖ 红线] ';
            case 'orange', c = Theme.tint(Theme.ColorWarn, 0.16); ic = '[⚠ 限制] ';
            case 'green',  c = Theme.tint(Theme.ColorOk, 0.14); ic = '[✔ 通过] ';
            otherwise,     c = Theme.tint(Theme.ColorAccent, 0.14); ic = '[ℹ 信息] ';
        end
        self.Banner.BackgroundColor = c;
        self.Banner.FontColor = Theme.ColorInk;
        if isstring(msg) && numel(msg) > 1
            msg = strjoin(msg, ' ');                % 展平 string 数组
        end
        self.Banner.Text = char(string(ic) + string(msg) + bannerTailOf(self));
        % 全文另挂一份在 Tooltip 上: 折行 + 'fit' 行高保证屏幕上不裁字, Tooltip 保证即使
        % 窗口被拖窄、或将来有人把行高改回定值, 完整文案仍然取得出来。
        self.Banner.Tooltip = self.Banner.Text;
        % 状态带与横幅同一个刷新点: 横幅唯一写入点在这里, 挂在这里就不会出现
        % "横幅已更新而状态带还停在旧值"的第二次写入路径。
        self.refreshStatusStrip();
    end

    function refreshStatusStrip(self)
        %REFRESHSTATUSSTRIP 重写六个席位的值文本 (席位名与顺序由 StatusChip 定)。
        %   取不到的项写空串 -> StatusChip 自己显式印"未取数", 不印 0 也不留空。
        if isempty(self.Chips) || ~self.uiAlive(), return; end
        if numel(self.Chips) < 6, return; end
        self.Chips{1}.setPair('模式', self.modeChipText());
        self.Chips{1}.applyStatus(self.modeChipStatus());
        self.Chips{2}.setPair('后端', self.backendChipText());
        self.Chips{2}.applyStatus('REFERENCE');
        sha = self.configShaText();
        self.Chips{3}.setPair('配置哈希', StatusChip.hashShort(sha));
        self.Chips{3}.applyStatus(ternaryWord(sha == "", 'UNKNOWN', 'MEASURED_CONFIG'));
        self.Chips{4}.setPair('位点', self.siteChipText());
        self.Chips{4}.applyStatus(self.siteChipStatus());
        self.Chips{5}.setPair('未关闭阻塞项', self.blockerChipText());
        self.Chips{5}.applyStatus(self.blockerChipStatus());
        self.Chips{6}.setPair('是否允许发布', self.releaseChipText());
        self.Chips{6}.applyStatus(self.releaseChipStatus());
        % 工具提示给全量出处 (胶囊里只放短码, 完整哈希与计数出处放在提示里)
        setChipTip(self.Chips{2}, sprintf('backendId = %s', self.backendIdText()));
        setChipTip(self.Chips{3}, sprintf('config sha256 = %s', ...
            ternaryWord(sha == "", "未取数 (配置身份哈希只在运行链里产出)", sha)));
        setChipTip(self.Chips{5}, sprintf('出处: %s', ...
            ternaryWord(self.BlockerSource == "", "未登记", string(self.BlockerSource))));
        setChipTip(self.Chips{6}, '发布资格只取 runGate 的 release_eligible; 未运行时为未判定');
        % 席位 1 与 4 以前没有提示: 六列都是 'fit' 且界面里没有任何标签开折行,
        % 所以文案一旦变长只有"溢出格宽"或"撑出窗口"两条路 —— 提示是全文的唯一出口。
        tipSite = char(string(self.SiteBand));
        if isempty(strtrim(tipSite))
            tipSite = '位点: 未校验 (点 [校验配置] 后常驻显示)';
        end
        setChipTip(self.Chips{1}, sprintf(['运行模式 %s; 发布还需 run.mode=VALIDATED ' ...
            '且没有未评估项'], char(string(self.modeChipText()))));
        setChipTip(self.Chips{4}, tipSite);
        self.StripText = char(string(StatusChip.allText(self.Chips)));
    end

    function t = statusStripText(self)
        %STATUSSTRIPTEXT 状态带整行文本 (程序化读取口, 与胶囊控件同源同一次写入)。
        if ~isempty(self.Chips)
            t = char(string(StatusChip.allText(self.Chips)));
        else
            t = self.StripText;
        end
    end

    function m = modeChipText(self)
        m = '未取数';
        if ~isempty(self.Controller.cfg)
            m = char(string(self.Controller.cfg.run.mode));
        elseif isfield(self.Fields, 'run_mode')
            m = char(string(self.Fields.run_mode.Value));
        end
    end

    function s = modeChipStatus(self)
        % 演示口径与已验证口径分开着色; VALIDATED 还要求真的通过校验
        s = 'PARTIAL';
        if ~strcmp(self.modeChipText(), 'VALIDATED'), return; end
        if self.Controller.state() == "Validated", s = 'OK'; else, s = 'WARN'; end
    end

    function s = backendIdText(~)
        s = '';
        try
            s = char(string(tepc.backendId()));
        catch
            % silent-by-design: 服务层不在路径上时状态带只显称谓, 不因取 id 失败而中断
        end
    end

    function t = backendChipText(self)
        % 后端称谓的唯一出处就是横幅尾巴那句"解析代理模型 (Fast Surrogate)": 状态带用
        % 同一个词, 不另造第二个称谓。完整的 backendId 太长, 放工具提示。
        t = '解析代理模型';
        self.backendIdText();       % 取一次以驱动服务层解析 (失败也不影响称谓显示)
    end

    function sha = configShaText(self)
        %CONFIGSHATEXT 配置身份哈希的取数处。
        %   完整身份链 (canonicalJson + effective_seed) 由运行链产出并写进结果里,
        %   GUI 不另算一份 (两份算法必然分叉)。未运行时这里就是空串 -> 席位显"未取数"。
        sha = "";
        if isempty(self.LastResult) || ~isstruct(self.LastResult)
            return;
        end
        if isfield(self.LastResult, 'config_sha256')
            sha = string(self.LastResult.config_sha256);
        elseif isfield(self.LastResult, 'summary') && ...
                isfield(self.LastResult.summary, 'config_sha256')
            sha = string(self.LastResult.summary.config_sha256);
        end
    end

    function t = siteChipText(self)
        % 位点席只放"请求 / 实现"两个直径 (相对偏差留在横幅尾巴与派生量面板上,
        % 状态带是全窗口最关键的一行, 不是长句的落脚点)。
        if ~isfinite(self.SiteReqUm) || ~isfinite(self.SiteRealUm)
            t = '';
            return;
        end
        t = sprintf('请求 %.3f / 实现 %.3f um', self.SiteReqUm, self.SiteRealUm);
    end

    function s = siteChipStatus(self)
        s = 'UNKNOWN';
        if ~isfinite(self.SiteReqUm) || ~isfinite(self.SiteRealUm), return; end
        tol = 100*tepc.config.constants('site.mismatchRelTol');
        if abs(self.SiteRelPct) <= tol
            s = 'OK';
        else
            s = 'WARN';
        end
    end

    function t = blockerChipText(self)
        if isempty(self.State) || self.State.isClosed()
            t = '';
            return;
        end
        n = self.State.openBlockers();
        if isempty(n)
            t = '';                      % 未取数 -> 由 StatusChip 印出"未取数"
        else
            t = sprintf('%d', n);
        end
    end

    function s = blockerChipStatus(self)
        s = 'NOT_EVALUATED';
        if isempty(self.State) || self.State.isClosed(), return; end
        n = self.State.openBlockers();
        if isempty(n), return; end
        if n > 0, s = 'PARTIAL'; else, s = 'OK'; end
    end

    function t = releaseChipText(self)
        t = '';
        if isempty(self.LastResult) || ~isfield(self.LastResult, 'gates')
            t = '未判定';
            return;
        end
        g = self.LastResult.gates;
        if ~isfield(g, 'release_eligible')
            t = '未判定';
            return;
        end
        if logical(g.release_eligible)
            t = '允许发布';
        else
            t = '禁止发布';
        end
        nFail = 0; nNE = 0;
        if isfield(g, 'nFail'), nFail = g.nFail; end
        if isfield(g, 'nNotEvaluated'), nNE = g.nNotEvaluated; end
        t = sprintf('%s (FAIL %d / 未评估 %d)', t, nFail, nNE);
    end

    function s = releaseChipStatus(self)
        t = self.releaseChipText();
        if startsWith(t, '允许'), s = 'RELEASE_ELIGIBLE';
        elseif startsWith(t, '禁止'), s = 'RELEASE_BLOCKED';
        else, s = 'NOT_EVALUATED';
        end
    end

    % ---------- 主题落地 (只改属性, 不动层级) ----------
    function applyTheme(self)
        %APPLYTHEME 把 Theme 的字体/字色/底色落到既有控件上 (不改任何数值行为)。
        %   本机实测的两条形状差别, 决定了这里为什么逐项 try 而不是"一次设全":
        %     1) matlab.ui.control.UIAxes 没有 ColorMap 属性, 只有经典 Axes 有;
        %     2) uitextarea 没有 FontColor 与 BackgroundColor (设上去只会静默失败)。
        %   设不上的项不谎称已应用: 结果按类型计数写进日志, 日志里那句"用了多少项"
        %   就是这条路径被真正执行过的证据。
        if ~self.uiAlive(), return; end
        fig = self.UIFigure;
        self.setOpt(fig, 'Color', Theme.ColorCanvas);
        skip = self.cardComponentIds();
        P = self.themePasses();
        % 正文控件两轮: body 档 (14) 与 micro 档 (12)。12 是 Theme.FontFloor 之上的
        % 最低档, 再小就低于可读下限。
        for p = 1:numel(P)
            pass = P(p);
            list = [];
            for j = 1:numel(pass.types)
                list = [list; findall(fig, 'Type', pass.types{j})]; %#ok<AGROW>
            end
            hit = zeros(1, numel(pass.props));
            for i = 1:numel(list)
                if any(double(list(i)) == skip)
                    continue;         % 参数卡片内部的字号由卡片自己管 (紧凑两行)
                end
                for k = 1:numel(pass.props)
                    nm = pass.props{k};
                    v = pass.values{k};
                    if strcmp(nm, 'FontSize')
                        v = pass.size;
                    end
                    if strcmp(nm, 'FontColor') && strcmp(list(i).Type, 'uilabel') ...
                            && self.isMuted(list(i))
                        v = Theme.ColorMuted;   % 说明性文字保持弱化字色
                    end
                    if strcmp(nm, 'BackgroundColor') && strcmp(list(i).Type, 'uilabel')
                        continue;               % 标签留画布底色, 刷成白底会像一排假输入框
                    end
                    hit(k) = hit(k) + self.setOpt(list(i), nm, v);
                end
            end
            self.log(sprintf('样式: %s 类控件 %d 个, 属性 %s 分别落上 %s 个', ...
                strjoin(pass.types, '/'), numel(list), strjoin(pass.props, '/'), ...
                mat2str(hit)));
        end
        for i = 1:numel(self.AxesList())
            self.styleAxes(self.AxesList{i});
        end
        self.setOpt(self.Banner, 'FontSize', Theme.BannerFontSize);
    end

    function P = themePasses(~)
        %THEMEPASSES 两轮样式: 标签走正文档 (14), 其余控件走辅助档 (12)。
        %   两轮的类型集合不重叠 —— 同一个类型出现在两轮里时后一轮会盖掉前一轮的字号。
        P = struct('types', {{'uilabel'}}, 'props', {{'FontName', 'FontSize', 'FontColor'}}, ...
            'size', Theme.FontBody, 'values', {{Theme.FontFamily, Theme.FontBody, ...
            Theme.ColorInk}});
        P(2) = struct('types', {{'uieditfield', 'uidropdown', 'uibutton', ...
            'uitextarea', 'uitable', 'uigauge'}}, ...
            'props', {{'FontName', 'FontSize', 'FontColor', 'BackgroundColor'}}, ...
            'size', Theme.FontMicro, 'values', {{Theme.FontFamily, Theme.FontMicro, ...
            Theme.ColorInk, Theme.ColorSurface}});
    end

    function A = AxesList(self)
        A = {self.AxGeom, self.AxField, self.AxSpectrum, self.AxGeom3D};
    end

    function styleAxes(self, ax)
        %STYLEAXES 坐标区文字/网格/底色。UIAxes 上没有的属性由 setOpt 记 0, 不抛错。
        if isempty(ax) || ~isvalid(ax), return; end
        self.setOpt(ax, 'FontName', Theme.FontFamily);
        self.setOpt(ax, 'FontSize', Theme.FontMicro);
        self.setOpt(ax, 'XColor', Theme.ColorInk);
        self.setOpt(ax, 'YColor', Theme.ColorInk);
        self.setOpt(ax, 'ZColor', Theme.ColorInk);
        self.setOpt(ax, 'GridColor', Theme.ColorRule);
        self.setOpt(ax, 'Color', Theme.ColorSurface);
        cm = [];
        ok = false;
        try
            cm = ax.ColorMap;
            ok = isnumeric(cm) && size(cm, 2) == 3 && size(cm, 1) >= 3;
        catch
            % silent-by-design: 本机 UIAxes 没有 ColorMap 属性 (实测), 经典 Axes 才有
            ok = false;
        end
        if ok
            % 只换色表前两行: 经典七色表的第 1/2 行正是曲线常用的两个颜色。
            self.setOpt(ax, 'ColorMap', [Theme.ColorInk; Theme.ColorAccent; cm(3:end, :)]);
        end
    end

    function tf = setOpt(~, obj, name, val)
        %SETOPT 设一个可选样式属性, 返回是否真的设上 (调用方据此计数, 不静默谎称)。
        tf = false;
        try
            obj.(name) = val;
            tf = true;
        catch
            % silent-by-design: 样式属性缺位只影响观感, 不得改变任何数值行为
        end
    end

    function ids = cardComponentIds(self)
        %CARDCOMPONENTIDS 参数卡片自己管的控件句柄 (按 double 句柄比对, 避免句柄数组
        %   拼装时的类型退化问题 —— 见 allTabs 里同一条实测教训)。
        ids = [];
        for i = 1:numel(self.Cards)
            ids = [ids, self.Cards{i}.componentIds()]; %#ok<AGROW>
        end
    end

    function tf = isMuted(self, obj)
        tf = false;
        for i = 1:numel(self.MutedControls)
            if double(self.MutedControls{i}) == double(obj), tf = true; return; end
        end
    end

    function rows = geomTabRows(self, nRow)
        %GEOMTABROWS 几何与气体页的行高: 表单单行 + 每行一张紧凑参数卡片。
        %   卡片是 32 px 控件行 + 18 px 提示行 + 上下各 8 px 内边距 = 66 px;
        %   说明行按 3 行文字给 60 px (缺省单行会把三行说明裁成一行)。
        rows = repmat({Theme.FormRowH}, 1, max(1, nRow));
        rows(2:5) = repmat({Theme.CardRowH}, 1, 4);
        rows(6) = {Theme.HintH*3 + 6};
        rows(7) = {Theme.HintH*5};
        rows(8) = {150};
    end

    function logGeomTabBudget(self, g)
        %LOGGEOMTABBUDGET 把几何页的"需要高度 / 给定高度"写进日志。
        %   窗口在隐藏态下 uigridlayout 不算几何 (所有 Position 停在缺省值), 所以
        %   裁切只能按行高元胞的算式核对, 不能靠读隐藏窗口的像素。
        need = 0;
        for i = 1:numel(g.RowHeight)
            x = g.RowHeight{i};
            if isnumeric(x) && isscalar(x)
                need = need + double(x);
            end
        end
        need = need + g.Padding(1) + g.Padding(3) + g.RowSpacing*max(0, numel(g.RowHeight) - 1);
        tabH = NaN;
        try
            tabH = g.Parent.Position(4);
        catch
            % silent-by-design: 隐藏态下取不到页签高度, 日志只报需要的高度
        end
        self.log(sprintf(['几何页行高预算: 需要 %.0f px; 页签给定 %s; 固定行合计 %.0f px ' ...
            '(卡片行 %.0f px x 4)'], need, ternaryWord(isfinite(tabH), ...
            sprintf('%.0f px', tabH), '未计算 (窗口隐藏)'), need, Theme.CardRowH));
    end

    function tail = bannerTailOf(self)
        %BANNERTAILOF 顶部状态带的常驻尾巴: 后端称谓 + 请求/实现位点/相对偏差。
        %   横幅只有 setBanner 一处写入点, 因此把常驻信息拼在这里就能覆盖全部路径,
        %   不需要在每个调用方各带一份 (也避免某条分支忘了说后端是什么模型)。
        band = char(self.SiteBand);
        if isempty(strtrim(band))
            band = '位点: 未校验 (点 [校验配置] 后常驻显示)';
        end
        tail = sprintf(' | 解析代理模型 (Fast Surrogate) | %s', band);
    end

    function refreshSiteBand(self, dReqUm, dRealUm, relPct)
        %REFRESHSITEBAND 刷新常驻位点串。数值一律来自已解析的模型结果, GUI 不重算物理。
        %   relPct 为 NaN 时按实现/请求比补算 (派生模式下两者等价)。
        %   同时把三个数存成属性: 顶部状态带的位点席位读它们, 不从串里反解。
        if ~isfinite(dReqUm) || ~isfinite(dRealUm)
            self.SiteBand = '';
            self.SiteReqUm = NaN;
            self.SiteRealUm = NaN;
            self.SiteRelPct = NaN;
            self.refreshStatusStrip();
            return;
        end
        if ~isfinite(relPct)
            relPct = 100*(dRealUm/max(dReqUm, eps) - 1);
        end
        self.SiteReqUm = double(dReqUm);
        self.SiteRealUm = double(dRealUm);
        self.SiteRelPct = double(relPct);
        self.SiteBand = sprintf('位点: 请求 %.3f um / 实现 %.3f um / 相对偏差 %+.1f%%', ...
            dReqUm, dRealUm, relPct);
        self.refreshStatusStrip();
    end

    function setStateLabel(self, st)
        if ~self.uiAlive(), return; end
        self.StatusLabel.Text = sprintf('状态: %s', char(string(st)));
    end

    function noteUiError(self, tag, e)
        %NOTEUIERROR 用户可见异常的统一出口。
        %   旧实现: 28 处 catch 里 19 处不带异常变量, 用户只看到"红横幅",
        %   identifier / 堆栈 / 该改哪个字段 全部丢失, 事后也无处复核。
        txt = sprintf('%s: [%s] %s', tag, string(e.identifier), string(e.message));
        try
            self.setBanner('red', txt);
        catch
            % silent-by-design: 横幅控件本身已失效时, 日志与 error.json 仍会记录
        end
        try, self.log(txt); catch, end
        try
            self.LogErrorHistory(end+1) = {e};
        catch
            % silent-by-design: 历史缓冲写满不是错误
        end
        try
            rd = string(self.Controller.LastRunDir);
            if rd ~= "" && isfolder(char(rd))
                logDir = fullfile(char(rd), 'logs');
                runID = char(string(self.Controller.LastRunKind));
            else
                % 最需要兜底的场景恰恰是"配置被改坏 -> 根本没建 run 目录": 那时没有
                % LastRunDir 可写, 根因就只留在内存里 (日志满 400 行还会丢前 200 行),
                % 用户合上窗口就再也查不到。兜底写到系统临时目录并打印路径。
                logDir = fullfile(tempdir, 'tepc_gui_errors');
                if ~isfolder(logDir), mkdir(logDir); end
                runID = "no-run-dir";
            end
            ctxStage = 'gui';
            % 每次失败单独成文: 固定名会让第二次失败覆盖第一次的根因。
            fn = sprintf('gui_error_%s_%s.json', ...
                char(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS')), ...
                regexprep(char(string(e.identifier)), '[^A-Za-z0-9]', '_'));
            p = tepc.io.writeErrorLog(logDir, e, ...
                struct('stage', ctxStage, 'runID', runID, ...
                       'cfgPath', char(string(self.Controller.cfgPath)), ...
                       'extra', struct('fallback_dir', ~(rd ~= "" && isfolder(char(rd))))), fn);
            if ~isempty(p)
                % 同时留一份固定名的"最近一次" (横幅与 GUI 只说 error.json, 人要找得到),
                % 历史则由上面的带时间戳文件承担 —— 两者不是重复: 一个答"现在怎么了",
                % 一个答"先后发生过什么"。
                try, copyfile(p, fullfile(logDir, 'error.json'), 'f'); catch, end
                self.log(['异常详情已落盘: ' string(p)]);
            end
        catch
            % silent-by-design: 记录异常的代码不得再抛 (否则回到"异常被吞"的原罪)
        end
    end

    function log(self, msg)
        if ~self.uiAlive(), return; end
        try
            t = datestr(now, 'HH:MM:SS');
            self.LogData{end+1} = ['[', t, '] ', char(string(msg))]; %#ok<AGROW>
            if numel(self.LogData) > 400, self.LogData(1:200) = []; end
            self.LogList.Value = self.LogData(max(1,end-15):end);
        % silent-by-design: 日志写控件失败 (控件已销毁) 不得再抛出
        catch
        end
    end

    function tf = uiAlive(self)
        tf = false;
        if self.Closed, return; end
        try
            tf = ~isempty(self.UIFigure) && isvalid(self.UIFigure);
        % silent-by-design: 探测控件存活性, 任何异常都意味着"不存活"
        catch
            tf = false;
        end
    end

    % ---------- 界面 <-> 配置 单一映射表 ----------
    function M = cfgMap(self)
        %CFGMAP 每行: {界面 tag, 配置字段路径, 类型}  类型 num|int|enum|text
        %   int  -> 必须为整数值 (nEvents/chunk/seed/bits)
        %   enum -> uidropdown, 值必须是字符串 (写回时若不在 Items 内会追加, 不静默丢弃)
        if ~isempty(self.CfgMapCache), M = self.CfgMapCache; return; end
        M = { ...
          'run_nEvents', {'run','nEvents'},                                    'int';  ...
          'run_seed',    {'provenance','seed'},                                'int';  ...
          'run_mode',    {'run','mode'},                                       'enum'; ...
          'run_chunk',   {'run','chunkSize'},                                  'int';  ...
          'geo_type',    {'geometry','type'},                                  'enum'; ...
          'geo_R',       {'geometry','gasRadius_mm'},                          'num';  ...
          'geo_wall',    {'geometry','wallThickness_mm'},                      'num';  ...
          'geo_anode',   {'geometry','anodeRadius_um'},                        'num';  ...
          'geo_len',     {'geometry','cylinderLength_mm'},                     'num';  ...
          'gas_p',       {'gas','pressure_Pa'},                                'num';  ...
          'gas_T',       {'gas','temperature_K'},                              'num';  ...
          'gas_W',       {'gas','W_eV','value'},                               'num';  ...
          'gas_F',       {'gas','fano','value'},                               'num';  ...
          'gas_ch4',     {'gas','composition_molfrac','CH4'},                  'num';  ...
          'gas_co2',     {'gas','composition_molfrac','CO2'},                  'num';  ...
          'gas_n2',      {'gas','composition_molfrac','N2'},                   'num';  ...
          'site_d',      {'site','targetDiameter_um'},                         'num';  ...
          'site_mode',   {'site','equivalenceMode'},                           'enum'; ...
          'field_hv',    {'field','hv_V'},                                     'num';  ...
          'field_dV',    {'detector','diethorn_deltaV_V','value'},             'num';  ...
          'field_mode',  {'detector','gainMode'},                              'text'; ...
          'src_type',    {'source','type'},                                    'enum'; ...
          'src_E',       {'source','energy_MeV'},                              'num';  ...
          'src_rate',    {'source','rate_cps'},                                'num';  ...
          'src_flu',     {'source','fluence_m2'},                              'num';  ...
          'src_arr',     {'source','arrivalModel'},                            'enum'; ...
          'el_cf',       {'electronics','Cf_F'},                               'num';  ...
          'el_rf',       {'electronics','Rf_Ohm'},                             'num';  ...
          'el_tau',      {'electronics','shaping_s'},                          'num';  ...
          'el_ts',       {'electronics','sampleTime_s'},                       'num';  ...
          'el_thr',      {'electronics','trigger','threshold_V'},              'num';  ...
          'el_hyst',     {'electronics','trigger','hysteresis_V'},             'num';  ...
          'el_pu',       {'electronics','trigger','pileUpReject_s'},           'num';  ...
          'el_dt',       {'electronics','deadTime_s'},                         'num';  ...
          'el_wwin',     {'electronics','waveWindow_s'},                       'num';  ...
          'el_dtmode',   {'electronics','deadTimeMode'},                       'enum'; ...
          'el_bits',     {'electronics','adc','bits'},                         'int';  ...
          'el_fs',       {'electronics','adc','fullScale_V'},                  'num';  ...
          'el_g2',       {'electronics','adc','range2Gain'},                   'num'};
        self.CfgMapCache = M;
    end

    function cfg = gatherConfig(self)
        %GATHERCONFIG 读"当前选中的配置文件" -> 逐项应用界面覆写。
        %   原实现硬编码 demo_only.json, 导致"部分界面生效、其余静默取 JSON"。
        %   界面缺该控件 -> 保留配置文件值; 界面有值但非法 -> 报错 (不静默降级)。
        %   收集完成后把"配置文件为底 + 界面覆写"整体交给状态源: 状态源里的字段值
        %   与这次收集到的 cfg 同快照, 派生量随后按防抖延后重算。
        p = self.resolveConfigPath();
        cfg = tepc.config.load(p);
        M = self.cfgMap();
        bad = {};
        tags = {};
        vals = {};
        for i = 1:size(M, 1)
            tag = M{i,1}; path = M{i,2}; kind = M{i,3};
            if ~isfield(self.Fields, tag), continue; end        % isfield 守卫
            [v, ok] = self.readField(tag, kind);
            if ~ok
                % 空控件要分两种: 配置文件里本来就没有这一项 (球形没有 cylinderLength_mm,
                % applyConfig 按"配置无该项 -> 保留界面现值"跳过, 卡片因此停在构造默认的空
                % 串) —— 这种不是用户的非法输入, 不覆写也不伪造数值, 直接跳过; 配置里明明
                % 有值而控件却是空的 (用户清空了) 才是非法输入, 照旧点名报错。
                raw = self.fieldValue(tag);
                [~, hasSrc] = self.getPath(cfg, path);
                if ~hasSrc && isempty(strtrim(char(string(raw))))
                    continue;
                end
                % 复用上面读到的 raw, 不再第二次访问控件。跳过之所以安全, 是因为真需要该
                % 尺寸时服务层自己会拦: validate 报 GEOM_LENGTH_MISSING、buildGeometry
                % 抛 MissingLength、meshSpec 抛 BadDimension —— 以后要让更多行享受这个跳过,
                % 必须先确认下游有等价守卫, 否则跳过就变成静默吞掉必填项。
                bad{end+1} = sprintf('%s="%s"', tag, strtrim(char(string(raw)))); %#ok<AGROW>
                continue;
            end
            tags{end+1} = tag; vals{end+1} = v;                 %#ok<AGROW>
            cfg = self.setPath(cfg, path, v);
        end
        if ~isempty(bad)
            self.Controller.invalidate();
            error('tepc:gui:BadField', '界面数值非法(须为有限实数, int 项须为整数): %s', ...
                strjoin(bad, ', '));
        end
        self.pushToState(cfg, tags, vals);
    end

    function pushToState(self, cfg, tags, vals)
        %PUSHTOSTATE 一次批量写入状态源 (延时装载器只排一次)。
        if isempty(self.State) || self.State.isClosed(), return; end
        self.State.setConfig(cfg, 'gather');
        if ~isempty(tags)
            self.State.setFields(tags, vals, 'ui');
        end
        self.State.markClean();         % 界面与状态源此刻同快照, 没有待同步的格子
    end

    function applyConfig(self, cfg)
        %APPLYCONFIG cfg -> 全部可编辑控件 (onLoadConfig 回填, 与 gatherConfig 对称)
        %   状态源先整体收下这份配置, 再按映射表逐项投影到控件: 投影失败 (控件没了)
        %   不会让状态源停在旧值上。
        if ~isempty(self.State) && ~self.State.isClosed()
            self.State.setConfig(cfg, 'load-file');
        end
        M = self.cfgMap();
        for i = 1:size(M, 1)
            tag = M{i,1}; path = M{i,2}; kind = M{i,3};
            if ~isfield(self.Fields, tag), continue; end
            [v, found] = self.getPath(cfg, path);
            if ~found, continue; end               % 配置无该项 -> 保留界面现值
            self.writeField(tag, kind, v);
        end
        self.refreshCardBadges();
        if ~isempty(self.State) && ~self.State.isClosed()
            self.State.markClean();
        end
    end

    function refreshCardBadges(self)
        %REFRESHCARDBADGES 载入/校验后按配置里自带的来源标签重刷徽标。
        %   徽标的出处只有 statusScan 扫出来的那一份, 界面不另立来源标记。
        if isempty(self.Cards), return; end
        sc = self.statusLookup();
        M = self.cfgMap();
        for i = 1:numel(self.Cards)
            tag = self.Cards{i}.Tag;
            k = find(cellfun(@(s) strcmp(s, tag), M(:, 1)), 1);
            if isempty(k), continue; end
            self.Cards{i}.setStatus(self.statusOf(sc, M{k, 2}));
        end
    end

    function p = resolveConfigPath(self)
        %RESOLVECONFIGPATH 界面"配置文件"字段 -> 绝对路径 (相对路径按项目根解析)
        root = tepc.io.projectRoot();
        if isfield(self.Fields, 'cfg_path')
            s = strtrim(char(string(self.fieldValue('cfg_path'))));
        else
            s = '';
        end
        if isempty(s), s = fullfile('config', 'defaults', 'demo_only.json'); end
        if self.isAbsolutePath(s)
            p = s;
        else
            parts = strsplit(s, {'/', '\'});
            keep = {};
            for i = 1:numel(parts)
                if ~isempty(parts{i}), keep{end+1} = parts{i}; end %#ok<AGROW>
            end
            p = fullfile(root, keep{:});
        end
        if ~isfile(p)
            error('tepc:gui:NoConfigFile', '配置文件不存在: %s', p);
        end
    end

    function tf = isAbsolutePath(self, s)
        tf = ~isempty(regexp(s, '^[A-Za-z]:[\\/]', 'once')) || ...
             ~isempty(regexp(s, '^[\\/]', 'once'));
    end

    function k = kindOf(self, tag)
        %KINDOF tag -> 映射表里的字段类型 (num|int|enum|text); 没登记按 text 兜底。
        M = self.cfgMap();
        k = find(strcmp(M(:, 1), tag), 1);
        if isempty(k)
            k = 'text';
        else
            k = M{k, 3};
        end
    end

    function [v, ok] = parseValue(~, raw, kind)
        %PARSEVALUE 界面原文 -> 配置值。num/int 走 str2double + isfinite 断言 (int 另判整数),
        %   enum/text 收成去空白的 char。非法值一律 ok=false, 由调用方点名报错。
        ok = false; v = [];
        switch kind
            case {'num', 'int'}
                if isnumeric(raw) && isscalar(raw)
                    x = double(raw);
                    if isfinite(x) && ~(strcmp(kind, 'int') && x ~= round(x))
                        v = x; ok = true;
                    end
                    return;
                end
                s = strtrim(char(string(raw)));
                if isempty(s), return; end
                x = str2double(s);
                if isempty(x) || ~isfinite(x), return; end     % isfinite 断言
                if strcmp(kind, 'int') && x ~= round(x), return; end
                v = x; ok = true;
            case {'enum', 'text'}
                s = strtrim(char(string(raw)));
                if isempty(s), return; end
                v = s; ok = true;
            otherwise
                error('tepc:gui:BadKind','未知字段类型 %s', kind);
        end
    end

    function [v, ok] = readField(self, tag, kind)
        %READFIELD 从控件读一格并解析。状态源的写入集中在 gatherConfig 的批量路径与
        %   参数卡片的改动回调两处, 这里只解析不写 —— 一次收集循环里每个 tag 只排一次延后。
        raw = self.fieldValue(tag);
        [v, ok] = self.parseValue(raw, kind);
    end

    function writeField(self, tag, kind, v)
        c = self.Fields.(tag);
        switch kind
            case {'num', 'int'}
                if ~isnumeric(v) || isempty(v), return; end
                c.Value = sprintf('%.10g', double(v));
            case 'enum'
                s = char(string(v));
                if isempty(s), return; end
                items = cellstr(string(c.Items));
                if ~any(strcmp(items, s))
                    items{end+1} = s;   % 不静默丢弃配置值: 追加选项并选中
                    c.Items = items;
                end
                c.Value = s;
            otherwise
                s = char(string(v));
                if ~isempty(s), c.Value = s; end
        end
        % 参数卡片格: 步长控件跟着回填值走, 否则点一下增量会跳回旧值。
        idx = self.cardIndexOf(tag);
        if ~isempty(idx)
            self.Cards{idx}.syncSpinner();
        end
    end

    function idx = cardIndexOf(self, tag)
        idx = [];
        for i = 1:numel(self.Cards)
            if strcmp(self.Cards{i}.Tag, tag), idx = i; return; end
        end
    end

    function s = setPath(self, s, path, v)
        if numel(path) == 1
            s.(path{1}) = v;
        else
            if ~isstruct(s) || ~isfield(s, path{1}), s.(path{1}) = struct(); end
            s.(path{1}) = self.setPath(s.(path{1}), path(2:end), v);
        end
    end

    function [v, found] = getPath(self, s, path)
        v = []; found = false;
        try
            if ~isstruct(s) || ~isfield(s, path{1}), return; end
            v = s.(path{1});
            if numel(path) == 1, found = true; return; end
            [v, found] = self.getPath(v, path(2:end));
        % silent-by-design: 路径不存在时返回空值由调用方判 found
        catch
            v = []; found = false;
        end
    end

    function species = unsupportedSpecies(self, cfg)
        % 界面只有 CH4/CO2/N2 三个组分字段; 其它组分无对应控件 -> 显式提示
        species = {};
        [c, found] = self.getPath(cfg, {'gas','composition_molfrac'});
        if ~found || ~isstruct(c), return; end
        covered = {'CH4','CO2','N2'};
        fn = fieldnames(c);
        for i = 1:numel(fn)
            if ~any(strcmp(fn{i}, covered)), species{end+1} = fn{i}; end %#ok<AGROW>
        end
    end

    function onValidate(self)
        try
            cfg = self.gatherConfig();
        catch e
            self.Controller.invalidate();
            self.setBanner('red', ['配置校验失败: ', e.message]);
            self.setStateLabel(self.Controller.state());
            return;
        end
        try
            iss = self.Controller.readAndValidate(cfg, self.Fields.cfg_path.Value);
            if isempty(iss)
                nE = 0; nW = 0; msgE = strings(1, 0);
            else
                lvA = cellfun(@(s) string(s.level), iss, 'UniformOutput', false);
                lvA = [lvA{:}];                                   % 1xN string
                nE = nnz(lvA == "error"); nW = nnz(lvA == "warn");
                % iss 是 cell: 逐项必须用 iss{i} (实测 iss(i).message 抛
                % structRefFromNonStruct, 把"校验失败"横幅变成"校验异常"),
                % 消息收集成 string 数组并用 join 拼接 (strjoin 不接受 string cell)。
                msgE = strings(1, nE); k = 0;
                for i = 1:numel(iss)
                    if lvA(i) == "error", k = k + 1; msgE(k) = string(iss{i}.message); end
                end
            end
            if nE > 0
                self.setBanner('red', char("配置校验失败: " + join(msgE, " | ")));
                self.setStateLabel(self.Controller.state());
                return;
            end
            % 派生量显示 (服务层计算)
            R = tepc.config.resolve(self.Controller.cfg);
            geom = R.geom;
            % 场模型必须先于任何使用处构造 (曾把 fGui 的定义留在下面的 E(r) 绘图段,
            % 导致这里的引用抛错并被外层 catch 吞成 "校验失败", 状态机卡在 Configured)
            fGui = tepc.detector.fieldModel(R.field.a, R.field.b, R.field.hv_V, R.field.kind);
            self.Fields.geom_out.Value = self.geomText(R, cfg);
            self.Fields.field_out.Value = { sprintf('G_mean = %.1f @ %.0f V (Diethorn, ASSUMED, 场=%s)', ...
                R.G_mean, cfg.field.hv_V, R.field.kind), ...
                sprintf('E(a) = %.3g V/m, E(b) = %.3g V/m', ...
                fGui.E(R.field.a), fGui.E(R.field.b)) };
            % 截面图
            cla(self.AxGeom); hold(self.AxGeom, 'on');
            th = linspace(0, 2*pi, 200);
            Rg = cfg.geometry.gasRadius_mm;
            plot(self.AxGeom, Rg*cos(th), Rg*sin(th), 'b-', 'LineWidth', 1.2);
            plot(self.AxGeom, (Rg+cfg.geometry.wallThickness_mm)*cos(th), ...
                (Rg+cfg.geometry.wallThickness_mm)*sin(th), 'k--');
            plot(self.AxGeom, cfg.geometry.anodeRadius_um*1e-3*cos(th), ...
                cfg.geometry.anodeRadius_um*1e-3*sin(th), 'r.', 'MarkerSize', 8);
            axis(self.AxGeom, 'equal'); grid(self.AxGeom, 'on');
            title(self.AxGeom, sprintf('截面: 气腔 R=%.1f mm, 壁 %.1f mm', Rg, cfg.geometry.wallThickness_mm));
            xlabel(self.AxGeom, 'x (mm)'); ylabel(self.AxGeom, 'y (mm)');
            % E(r) 图
            cla(self.AxField); hold(self.AxField, 'on');
            rr = linspace(geom.anode.radius_m*1.2, geom.R_m*0.999, 300);
            aa = geom.anode.radius_m; bb = geom.R_m; V = cfg.field.hv_V; %#ok<NASGU>
            % 场与引擎同一模型 (fGui 已在本方法前面构造)
            E = fGui.E(rr);
            Nden = R.rho_g / R.gasMeta.molarMass_kg_per_mol * 6.02214076e23;
            semilogy(self.AxField, rr*1e3, E, 'b-', 'LineWidth', 1.2);
            ylabel(self.AxField, 'E (V/m)'); xlabel(self.AxField, 'r (mm)');
            % kind 与引擎同源 (小写), 不再套用不存在的首字母大写函数
            title(self.AxField, sprintf('%s 场 E(r) (与引擎同一模型), N=%.2e m^{-3}', ...
                char(fGui.kind), Nden));
            grid(self.AxField, 'on');
            % 警报
            self.setConsistencyBanner(R, cfg, nW);
            self.setStateLabel(self.Controller.state());
            self.log(sprintf('校验通过 (错误 %d, 警告 %d)', nE, nW));
        catch e
            self.Controller.invalidate();
            self.setBanner('red', ['校验异常: ', e.identifier, ' — ', e.message]);
            self.setStateLabel(self.Controller.state());
        end
    end

    function txt = geomText(self, R, cfg)
        %GEOMTEXT 派生量面板: 明确区分"实现位点"(derived) 与"请求位点"
        mode = string(R.siteMode);
        dReq = R.site_requested_d_tissue_m*1e6;
        dReal = R.geom.site.d_tissue_m*1e6;
        txt = { sprintf('rho_g = %.4e kg/m^3', R.rho_g), ...
                sprintf('lbar_gas = %.2f mm, V = %.3e m^3', R.geom.lbar_gas_m*1e3, R.geom.V_m3), ...
                sprintf('位点模式 = %s', char(mode)), ...
                sprintf('实现位点: d_t = %.4f um, lbar_tissue = %.4f um (请求 %.3f um)', ...
                    dReal, R.lbar_tissue_um, dReq), ...
                sprintf('等效位点(质量厚度映射): d_t_eq = %.3f um, 相对差 %.1f%%, 达成请求位点需 %.0f Pa', ...
                    R.siteConsistency.d_t_eq_m*1e6, 100*R.siteConsistency.relative_mismatch, ...
                    R.siteConsistency.pressure_for_target_Pa), ...
                sprintf('迁移率(ASSUMED): mu_e = %.3e, mu_i = %.3e m^2/(V s); 雪崩起点 r0 = %.3e m', ...
                    R.mob.mu_e_m2_Vs, R.mob.mu_i_m2_Vs, R.r0_m)};
        if string(cfg.geometry.type) ~= "sphere"
            txt{end+1} = sprintf(['注意: 解析输运的体均匀作用点抽样只实现 sphere; ' ...
                '%s 可通过校验与解析, 但运行时会被 transport:Geom 拒绝。'], ...
                char(string(cfg.geometry.type)));
        end
    end

    function setConsistencyBanner(self, R, cfg, nW)
        %SETCONSISTENCYBANNER 位点-压强一致性警报: derived 模式已自洽, 不再是"矛盾"
        rel = R.siteConsistency.relative_mismatch;
        mode = string(R.siteMode);
        dReq = R.site_requested_d_tissue_m*1e6;
        dReal = R.geom.site.d_tissue_m*1e6;
        % 常驻位点串必须在设横幅之前刷新: setBanner 把它拼进状态带尾巴
        self.refreshSiteBand(dReq, dReal, 100*rel);
        if mode == "derived"
            self.setBanner('green', sprintf(['配置校验通过 (%d 警告)。位点由温压导出: ' ...
                '实现 d_t=%.3f um (与请求 %.3f um 差 %.1f%%, derived 模式下自洽)。'], ...
                nW, dReal, dReq, 100*rel));
            return;
        end
        if rel > tepc.config.constants('site.mismatchRelTol')
            self.setBanner('orange', sprintf(['演示参数矛盾: 请求位点 %.2f um 与 %.0f Pa 下等效位点 ' ...
                '%.3f um 不一致; 质量厚度映射要求约 %.0f Pa (详见报告)。'], ...
                dReq, cfg.gas.pressure_Pa, R.siteConsistency.d_t_eq_m*1e6, ...
                R.siteConsistency.pressure_for_target_Pa));
        elseif nW > 0
            self.setBanner('orange', sprintf('校验通过, 但有 %d 个警告(见日志/报告)。', nW));
        else
            self.setBanner('green', '配置校验通过。可以运行。');
        end
    end

    function onSolveSitePressure(self)
        %ONSOLVESITEPRESSURE 位点反解: 只给建议压强, 不改任何配置。
        %   该值是"同一气体密度模型 + 质量厚度映射"下的数学解, 不是装置能力:
        %   真实计数器能否把位点做到那个尺寸要由图纸与实测决定, 界面上不得写成后者。
        try
            cfg = self.gatherConfig();
            R = tepc.config.resolve(cfg);
            sc = R.siteConsistency;
            dReq = R.site_requested_d_tissue_m*1e6;
            dReal = R.geom.site.d_tissue_m*1e6;
            tolPct = 100*tepc.config.constants('site.mismatchRelTol');
            ln1 = sprintf('请求位点 %.3f um; 当前 %.0f Pa 下实现位点 %.3f um (相对偏差 %+.1f%%, 阈值 %g%%)', ...
                dReq, cfg.gas.pressure_Pa, dReal, 100*sc.relative_mismatch, tolPct);
            ln2 = sprintf('建议: 同一气体密度模型下满足请求位点所需压强约 %.0f Pa (质量厚度映射的数学解)。', ...
                sc.pressure_for_target_Pa);
            ln3 = '本按钮只生成建议值: 未修改配置文件与界面取值, 也不表示真实装置可调到该位点。';
            self.refreshSiteBand(dReq, dReal, 100*sc.relative_mismatch);
            % geomText 返回**行** cell, 因此逐格横向追加 (纵向拼会把 1xN 与 Nx1 撞维度)
            gv = self.geomText(R, cfg);
            gv{end+1} = ln1; gv{end+1} = ln2; gv{end+1} = ln3;
            self.Fields.geom_out.Value = gv;
            self.setBanner('blue', sprintf('%s %s %s', ln1, ln2, ln3));
            self.log(['位点压强反解 (只给建议值, 未改配置): ' ln2]);
        catch e
            self.noteUiError('位点压强求解失败', e);
        end
    end

    % ---------- 运行控制 ----------
    function onRun(self)
        try
            self.onValidate();
            if self.Controller.state() ~= "Validated"
                self.setBanner('red', '运行被拒: 配置未通过校验');
                self.log('运行被拒: 配置未通过校验');
                return;
            end
            self.dropProgressQueue();
            dq = parallel.pool.DataQueue;
            afterEach(dq, @(pm) self.onProgress(pm.f, pm.m));
            self.ProgressQueue = dq;
            self.Controller.startRun(self.Controller.cfg.run.nEvents, dq);
            self.LastResult = [];
            self.ResultShown = false;
            self.log('运行已启动 (parfeval + DataQueue)');
            self.setStateLabel("Running");
            self.syncPauseButton(self.Controller.state());
            self.setBanner('blue', '运行中... 进度见进度条与日志。');
            self.startPolling();
        catch e
            self.setBanner('red', ['无法启动: ', e.message]);
            self.log(['无法启动: ', e.message]);
            % startRun 在 parpool/parfeval **之前**就 transition("Running"): 启动器
            % 抛错会把状态机永久卡在 Running, 之后每次点击都被 ensureConfigured 拒绝
            % (只能重载窗口)。这里必须把状态退回来。
            if any(self.Controller.state() == ["Running", "Paused"])
                self.Controller.stopAll();
                self.setStateLabel(self.Controller.state());
            end
        end
    end

    function onPauseToggle(self)
        st = self.Controller.state();
        try
            if st == "Paused"
                self.Controller.requestPause(false);
            else
                if st ~= "Running"
                    self.setBanner('orange', '只有在 Running 状态才能暂停 (先点 [运行])。');
                    return;
                end
                self.Controller.requestPause(true);
            end
        catch e
            self.setBanner('red', ['暂停/继续失败: ', e.message]);
            return;
        end
        self.syncPauseButton(self.Controller.state());
        self.setStateLabel(self.Controller.state());
        if self.Controller.state() == "Paused"
            self.log('已请求暂停: 后台作业在下一个 chunk 边界挂起 (状态 Paused)');
        else
            self.log('继续运行 (暂停标志文件已删除)');
        end
    end

    function onCancel(self)
        try
            self.Controller.requestCancel();
            self.log('已请求取消 (当前 chunk 结束后抛 tepc:run:CancelRequested)...');
        catch e
            self.log(['取消失败: ', e.message]);
        end
    end

    function syncPauseButton(self, st)
        if ~self.uiAlive(), return; end
        if string(st) == "Paused"
            self.Buttons.pause.Text = '▶ 继续';
        else
            self.Buttons.pause.Text = '⏸ 暂停';
        end
    end

    function startPolling(self)
        self.dropPollTimer();
        self.PollTimer = timer('ExecutionMode', 'fixedRate', 'Period', 2, ...
            'TimerFcn', @(~,~) self.pollRun());
        self.PollActive = true;
        start(self.PollTimer);
    end

    function stopPolling(self)
        % 只 stop: 在 TimerFcn 内删除自身 timer 不受支持, 删除交给 dropPollTimer
        self.PollActive = false;
        try
            if ~isempty(self.PollTimer) && isvalid(self.PollTimer)
                stop(self.PollTimer);
            end
        % silent-by-design: 关窗清理: 定时器可能已不存在
        catch
        end
    end

    function dropPollTimer(self)
        self.PollActive = false;
        try
            if ~isempty(self.PollTimer) && isvalid(self.PollTimer)
                stop(self.PollTimer); delete(self.PollTimer);
            end
        % silent-by-design: 关窗清理: 删除已失效 timer 无意义
        catch
        end
        self.PollTimer = [];
    end

    function dropProgressQueue(self)
        try
            if ~isempty(self.ProgressQueue) && isvalid(self.ProgressQueue)
                delete(self.ProgressQueue);
            end
        % silent-by-design: 关窗清理: DataQueue 可能已被 worker 释放
        catch
        end
        self.ProgressQueue = [];
    end

    function dropStateQuietly(self)
        %DROPSTATEQUIETLY 收口 AppState: 停表 + 删表 + 断开订阅者。
        %   本机 timer 不随 uifigure 销毁, 而定时器对象持有 self (回调里存着界面句柄),
        %   不删定时器就既回收不掉应用对象, 也会在下次主线程空闲时回调到已销毁的控件。
        if isempty(self.State)
            return;
        end
        try
            if ~self.State.isClosed()
                self.State.close('close-request');
            end
        catch
            % silent-by-design: 关窗兜底, 状态源自己已经收口过就不再重复
        end
        self.State = [];
    end

    function n = runGateBlockers(self, R)
        %RUNGATEBLOCKERS 本次运行的未关闭门禁项数 (FAIL + 未评估)。
        %   WARN 不计: 警告是已评估且有结论的降级项, 不算"未关闭"。
        n = 0;
        if nargin < 2 || isempty(R) || ~isstruct(R), return; end
        if ~isfield(R, 'gates') || isempty(R.gates), return; end
        g = R.gates;
        if isfield(g, 'nFail'), n = n + double(g.nFail); end
        if isfield(g, 'nNotEvaluated'), n = n + double(g.nNotEvaluated); end
    end

    function takeRegisterBlockers(self, R)
        %TAKEREGISTERBLOCKERS 状态带"未关闭阻塞项"的取数处, 两个口径不混算:
        %   1) 能力登记表: 状态不是 DONE 的条目数 —— 与运行无关的能力缺口 (缺省口径);
        %   2) 本次运行的门禁: FAIL + 未评估项数 —— 拦住"这一轮"的缺口。
        %   有运行结果时用 (2), 并把两个数都写进出处文本; 表读不到时 (1) 给空 ->
        %   席位显示"未取数"而不是 0。
        if nargin < 2, R = []; end
        if isempty(self.State) || self.State.isClosed(), return; end
        regN = [];
        if ~isempty(self.Evidence)
            try
                regN = self.Evidence.openBlockerCount();     % [] = 表没读到
            catch        % silent-by-design: 登记表 IO 失败按"未取数"显示, 不冒充成 0 席位
                regN = [];
            end
        end
        n = regN;
        parts = {};
        if ~isempty(regN)
            parts{end+1} = sprintf('登记表未关闭 %d', regN);
        else
            parts{end+1} = '登记表未取数';
        end
        gateN = [];
        if ~isempty(R) && isstruct(R) && isfield(R, 'gates') && ~isempty(R.gates)
            gateN = self.runGateBlockers(R);
            parts{end+1} = sprintf('本次运行门禁未关闭 %d (FAIL+未评估)', gateN);
            n = gateN;                        % 有结果时以本轮门禁为准
        end
        src = strjoin(parts, ' | ');
        self.State.setOpenBlockers(n, src);
        self.BlockerSource = src;
    end

    function onProgress(self, f, m)
        if ~self.uiAlive() || ~self.PollActive, return; end
        try
            self.ProgBar.Value = min(max(double(f), 0), 1);
            self.log(m);
        catch e
            % 进度回调不能打断后台作业, 但**必须留痕**: 旧实现裸 catch 全吞,
            % 于是"进度条不再动"这种异常在日志上完全隐形。
            self.noteUiError('进度回调失败', e);
        end
    end

    function pollRun(self)
        if ~self.PollActive, return; end
        if ~self.uiAlive(), self.stopPolling(); return; end
        try
            st = self.Controller.pollRun();
            self.syncPauseButton(st.state);
            if ~st.done, return; end
            self.stopPolling();
            if st.succeeded
                self.showResult(st.result);
                [col, msg] = self.resultBanner(st.result);
                self.setBanner(col, msg);
            elseif st.cancelled
                self.setBanner('orange', ['运行已取消 (非失败): ', st.errMsg, ...
                    ' —— 已完成 chunk 保留在 raw/, STATUS.json=CANCELLED, 未产出发布结果。']);
                self.log('运行已取消');
            else
                self.setBanner('red', ['运行失败: ', st.errMsg]);
                self.log(['运行失败: ', st.errMsg]);
            end
            self.setStateLabel(self.Controller.state());
        catch e
            self.stopPolling();
            % 首要原因 + identifier 一起显示, 并落 logs/error.json
            self.noteUiError('轮询异常', e);
        end
    end

    function [col, msg] = resultBanner(self, R)
        %RESULTBANNER 依据门禁水印给色, 不再把"未评估项"当通过
        col = 'green';
        % 发布资格只从 release_eligible 取, 缺字段一律当场报错: 任何默认值都会让
        % 横幅颜色与真实判定脱钩 (字段名一改就静默地永远橙色或永远绿色)。
        if ~isfield(R, 'gates') || isempty(R.gates)
            error('tepc:gui:MissingGateField', ...
                'Result 里没有 gates 结构, 无法判定横幅颜色');
        end
        g = R.gates;
        assert(isfield(g, 'release_eligible'), 'tepc:gui:MissingGateField', ...
            'gates 里没有 release_eligible 字段, 拒绝用默认值代替');
        nFail = 0; nWarn = 0; nNE = 0; wm = '未评估';
        if isfield(g,'nFail'), nFail = g.nFail; end
        if isfield(g,'nWarn'), nWarn = g.nWarn; end
        if isfield(g,'nNotEvaluated'), nNE = g.nNotEvaluated; end
        block = ~logical(g.release_eligible);
        if isfield(g,'watermark'), wm = char(string(g.watermark)); end
        msg = sprintf(['运行完成: yF=%s, yD=%s (RESEARCH/DEMO)。门禁 %s' ...
            ' (FAIL %d / WARN %d / 未评估 %d)。'], ...
            tepc.report.publishedText(R.summary, 'yF'), tepc.report.publishedText(R.summary, 'yD'), ...
            wm, nFail, nWarn, nNE);
        if nFail > 0
            col = 'red';
            msg = [msg, ' 结果 INVALID, 不得发布 (见验证页)。'];
        elseif block
            col = 'orange';
            msg = [msg, ' 存在未通过/未评估项 -> 禁止 RELEASED (参考场验证缺失)。'];
        end
    end

    function showResult(self, R)
        if ~self.uiAlive(), return; end
        self.ResultShown = true;
        self.LastResult = R;
        % 有结果之后, 状态带的"未关闭阻塞项"改按本轮门禁 (FAIL+未评估) 计数,
        % 出处文本里同时保留登记表的口径 —— 两个数都看得见, 但不相加。
        self.takeRegisterBlockers(R);
        s = R.summary;
        ln = { sprintf('yF = %s, yD = %s', tepc.report.publishedText(s, 'yF'), tepc.report.publishedText(s, 'yD')), ...
               sprintf('Qbar = %s | %s (禁绝对发布)', ...
               self.qbarStr(s.Qbar), tepc.report.doseLine(s, ', ')), ...
               sprintf('n_eff = %s, liveFrac = %.4f, 零沉积 %s', ...
               tepc.report.publishedText(s, 'effN'), s.liveFrac, tepc.report.publishedText(s, 'zeroDepPct')), ...
               char(tepc.report.depthLine(s, ', ')) };
        % 矩建在哪个事件群上必须与 yF/yD 同屏: 阈下事件是按零权重排除的, 只印 n_eff 或
        % liveFrac 都看不出"有多少事件根本没进矩"。份额与被剔数一起给, 读者不必自己除。
        if isfield(s, 'threshold_lost_fraction') && isfield(s, 'threshold_lost_count')
            popTxt = '未记录';
            if isfield(s, 'published_moment_population') && ~isempty(s.published_moment_population)
                popTxt = char(string(s.published_moment_population));
            end
            nPubTxt = '未记录';
            if isfield(s, 'n_published_moments')
                nPubTxt = sprintf('%d', s.n_published_moments);
            end
            ln{end+1} = sprintf('矩的总体: %s | 过阈 %.4f%% (阈下剔 %d/%d), 进矩 %s', ...
                popTxt, 100*(1 - s.threshold_lost_fraction), s.threshold_lost_count, ...
                s.nEvents, nPubTxt);
        end
        if isfield(s,'instrument_chain')
            if s.instrument_chain
                ln{end+1} = sprintf('仪器链: 启用 (反演有效事件 %d/%d)', s.n_meas_valid, s.nEvents);
            else
                ln{end+1} = '仪器链: 未启用 (发布量为真值 y, 无标定结构)';
            end
        end
        if isfield(s,'yF_truth_keV_um') && isfield(s,'instr_bias_yF')
            ln{end+1} = sprintf('真值 yF = %.3f keV/um; 仪器刻度偏差 = %+.2f%%', ...
                s.yF_truth_keV_um, 100*s.instr_bias_yF);
        end
        if isfield(s,'site_realized_d_tissue_um') && isfield(s,'site_requested_d_tissue_um')
            relRun = NaN;
            if isfield(R,'resolve') && isfield(R.resolve,'siteConsistency')
                relRun = 100*R.resolve.siteConsistency.relative_mismatch;
            end
            self.refreshSiteBand(s.site_requested_d_tissue_um, s.site_realized_d_tissue_um, relRun);
            ln{end+1} = sprintf('位点: 实现 %.3f um / 请求 %.3f um (%s)', ...
                s.site_realized_d_tissue_um, s.site_requested_d_tissue_um, ...
                char(string(s.site_equivalence_mode)));
        end
        self.Fields.spec_out.Value = ln;
        self.Fields.provenance.Value = { sprintf('runID: %s', s.runID), ...
            sprintf('config_sha256: %s', s.config_sha256), ...
            sprintf('seed: %d, 事件: %d, 续跑自: %d', s.seed, s.nEvents, s.resumed_from), ...
            sprintf('输出: %s', R.runDir.results) };
        self.redrawSpectrum(R);
        self.fillGatesTable(R);
        self.log('结果显示完毕');
    end

    function fillGatesTable(self, R)
        items = R.gates.items;
        gt = cell(numel(items), 4);
        for i = 1:numel(items)
            gt{i,1} = char(string(items(i).name));
            gt{i,2} = char(string(items(i).status));
            if isfield(items(i), 'value')
                v = items(i).value;
                if isnumeric(v) && isscalar(v) && ~isfinite(v)
                    gt{i,3} = 'NA';
                else
                    gt{i,3} = sprintf('%.4g', double(v));
                end
            else
                gt{i,3} = '-';
            end
            gt{i,4} = char(string(items(i).detail));
        end
        self.GatesTable.Data = gt;
    end

    function val = fieldValue(self, tag)
        c = self.Fields.(tag);
        val = c.Value;
    end

    function s = qbarStr(self, q)
        if ischar(q) || isstring(q), s = char(q); else, s = sprintf('%.2f', q); end
    end

    function redrawSpectrum(self, R)
        %REDRAWSPECTRUM 画当前谱。nargin<2 (下拉切换模式) 时用上一次结果 LastResult,
        %   原实现在这种情况下直接 return -> 谱模式下拉是死的。
        if ~self.uiAlive(), return; end         % 关窗后不得再写已失效控件
        if nargin < 2 || isempty(R)
            R = self.LastResult;
        end
        if isempty(R) || ~isfield(R,'analysis') || ~isfield(R.analysis,'spectrum')
            self.Fields.spec_out.Value = {'尚无结果: 谱模式下拉需先运行 (点 [运行])。'};
            return;
        end
        self.LastResult = R;
        S = R.analysis.spectrum;
        mode = self.Fields.spec_mode.Value;
        cla(self.AxSpectrum); hold(self.AxSpectrum, 'on');
        valid = S.counts_raw > 0;             % 零计数 bin 不伪造
        if ~any(valid)
            title(self.AxSpectrum, '线能谱: 无有效 bin (全部零计数/区间外)');
            xlabel(self.AxSpectrum, 'y (keV/\mum)'); grid(self.AxSpectrum, 'on');
            return;
        end
        objs = gobjects(0); labs = {};
        switch mode
            case '线性 y f(y)'
                set(self.AxSpectrum, 'XScale', 'linear');
                h1 = plot(self.AxSpectrum, S.center(valid), S.center(valid).*S.f(valid), ...
                    'b-', 'LineWidth', 1.2);
                h2 = errorbar(self.AxSpectrum, S.center(valid), S.center(valid).*S.f(valid), ...
                    S.center(valid).*S.sigma_f(valid), 'k.', 'LineWidth', 0.5);
                set(self.AxSpectrum, 'YScale', 'linear');
                ylabel(self.AxSpectrum, 'y f(y) (无量纲)');
                title(self.AxSpectrum, '频率分布 (线性)');
                objs(2) = h2; objs(1) = h1;
                labs = {'y f(y)', '统计误差'};
            case 'f(y) 对数轴'
                set(self.AxSpectrum, 'XScale', 'log');
                h1 = semilogx(self.AxSpectrum, S.center(valid), S.f(valid), 'b-', 'LineWidth', 1.2);
                set(self.AxSpectrum, 'YScale', 'log');
                ylabel(self.AxSpectrum, 'f(y) (keV/\mum)^{-1}');
                title(self.AxSpectrum, '频率分布密度 (对数-对数)');
                objs(1) = h1;
                labs = {'f(y)'};
            otherwise  % 对数 y d(y)
                yd = S.center .* S.d;
                m2 = yd > 0 & valid;
                set(self.AxSpectrum, 'XScale', 'log');
                if any(m2)
                    h1 = semilogx(self.AxSpectrum, S.center(m2), yd(m2), 'r-', 'LineWidth', 1.2);
                    objs(1) = h1;
                    labs = {'y d(y)'};
                end
                set(self.AxSpectrum, 'YScale', 'log');
                ylabel(self.AxSpectrum, 'y d(y) (无量纲)');
                title(self.AxSpectrum, sprintf('剂量分布 (对数), int d dy = %s', tepc.report.publishedText(S, 'intD')));
        end
        xlabel(self.AxSpectrum, 'y (keV/\mum)');
        grid(self.AxSpectrum, 'on');
        if numel(objs) == numel(labs) && ~isempty(objs)
            legend(self.AxSpectrum, objs, labs, 'Location', 'northeast');
        end
    end

    function onExport(self)
        try
            C = self.Controller;
            if isempty(C.Result)
                self.setBanner('orange', '尚无结果可导出。');
                return;
            end
            outp = fullfile(C.Result.runDir.results, 'report.html');
            tepc.report.htmlReport(C.Result, outp);
            self.setBanner('green', ['报告已导出: ', outp]);
            self.log(['报告: ', outp]);
        catch e
            self.setBanner('red', ['导出失败: ', e.message]);
        end
    end

    function onLoadConfig(self)
        %ONLOADCONFIG 载入界面指定路径的配置, 并回填全部可编辑控件
        try
            p = self.resolveConfigPath();
            cfg = tepc.config.load(p);
            self.applyConfig(cfg);
            extra = self.unsupportedSpecies(cfg);
            msg = ["已载入: ", p, " — 全部界面字段已同步, 点击 [校验配置] 后可运行。"];
            if isempty(extra)
                self.setBanner('blue', msg);
            else
                self.setBanner('orange', [msg, ' 注意: 气体组分 ', strjoin(extra, '/'), ...
                    ' 无对应界面字段, 校验会按组分之和拦截。']);
            end
            self.log(['载入配置: ', p]);
        catch e
            self.setBanner('red', ['载入失败: ', e.message]);
        end
    end

    % ---------- 关闭与析构 ----------
    function onCloseRequest(self)
        %ONCLOSEREQUEST 关窗清理: timer 不随 uifigure 销毁, 必须显式停/删;
        %   DataQueue 与后台 parfeval 也要撤, 否则 worker 继续跑并残留 flag 文件。
        if self.Closed, return; end
        self.Closed = true;
        self.closeCleanup();
        try
            if ~isempty(self.UIFigure) && isvalid(self.UIFigure)
                delete(self.UIFigure);
            end
        % silent-by-design: 关窗兜底: 清理失败也必须让窗口关闭
        catch
        end
    end

    function closeCleanup(self)
        self.stopPolling();
        self.dropPollTimer();
        self.dropProgressQueue();
        self.dropStateQuietly();      % AppState 的延时装载器同样是 timer
        try
            self.Controller.stopAll();
        % silent-by-design: 关窗兜底: 逐个尽力清理, 不因单个失败中断
        catch
        end
    end

    function delete(self)
        % 析构: 与 CloseRequestFcn 共用清理 (幂等)
        if ~self.Closed
            self.Closed = true;
            self.closeCleanup();
        end
        try
            if ~isempty(self.UIFigure) && isvalid(self.UIFigure)
                delete(self.UIFigure);
            end
        % silent-by-design: 析构兜底: 析构中抛错会被 MATLAB 吞掉且污染退出码
        catch
        end
    end
end
end

% ========================================================================
% 文件局部函数 (R2016b+ 允许在 classdef 文件末尾定义, 只对本类方法可见)。
% 放在 methods 块"里面"的 function 会被当成方法调用 (第一个实参被当作 self),
% 对 Tab 句柄这种 double 实参会直接抛 MATLAB:UndefinedFunction。
% ========================================================================
function ttl = tabTitleOf(obj)
%TABCANDIDATE 安全取页签 Title; 非 Tab 对象/属性不可读时返回空。
    ttl = '';
    try
        ttl = char(string(obj.Title));
    % silent-by-design: 析构兜底: 析构中抛错会被 MATLAB 吞掉且污染退出码
    catch
        ttl = '';
    end
end

function s = ternaryWord(cond, a, b)
%TERNARYWORD 标量条件取串。状态带里有几处"二选一"的措辞, 集中一处写免得每个席位
%   各写一个 if/else 而各自漂移 (文件局部函数, 不是方法: methods 块里的 function
%   第一个实参会被当成对象)。
    if logical(cond), s = string(a); else, s = string(b); end
end

function setChipTip(chip, tip)
%SETCHIPTIP 给胶囊挂工具提示 (席位文本只放短码, 完整哈希/计数出处放这里)。
    try
        if ~isempty(chip) && ~isempty(chip.Label) && isvalid(chip.Label)
            chip.Label.Tooltip = char(string(tip));
        end
    catch
        % silent-by-design: 提示文本设不上不影响状态带显示与程序化读取
    end
end

function ok = ensureComponentsOnPath()
%ENSURECOMPONENTSONPATH 把 app/components 加进路径。
%   addpath(fullfile(root,'app')) 只覆盖 app/ 一层, 不含 app/components —— 缺这一条
%   时 StatusChip/ParameterCard/EvidencePanel/PlotToolbar 全是"文件在仓库里但运行时
%   找不到"的死代码, 而且只在第一次用到时报错, 很容易在测试之外漏过。
    ok = false;
    here = which('TEPCApp');
    if isempty(here)
        here = mfilename('fullpath');
    end
    if isempty(here)
        return;
    end
    dir0 = fullfile(fileparts(here), 'components');
    if ~isfolder(dir0)
        return;
    end
    p = strsplit(path, pathsep);
    if any(strcmp(cellstr(string(p)), dir0))
        ok = true;
        return;
    end
    addpath(dir0);
    ok = true;
end
