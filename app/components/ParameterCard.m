classdef ParameterCard < handle
    %PARAMETERCARD 一张参数卡片: 标签 + 数值控件 + 单位 + 合法范围 + 来源状态徽标。
    %   输入 = Theme 常量 + 一条字段描述 (schema), 描述字段:
    %     Tag / Label / Kind('num'|'int'|'enum'|'text') / Unit / Min / Max / Step /
    %     Items / ValueStatus('MEASURED'|'MEASURED_CONFIG'|'REFERENCE'|'ASSUMED'|
    %     'FITTED') / Format / Decimals / Value / Advanced
    %
    % 本机控件 API 的真实边界 (决定了下面的写法, 越界写就是假承诺):
    %   * 没有 uinumericeditfield 这个函数名。数值输入是 uieditfield(parent,'numeric'),
    %     其句柄类为 matlab.ui.control.NumericEditField, 可用
    %     Value / Limits / LowerLimitInclusive / UpperLimitInclusive /
    %     ValueDisplayFormat / RoundFractionalValues / AllowEmpty / ValueChangedFcn;
    %     它**没有 Step**, 步长只能靠 uispinner (有 Step)。两者由本卡片互相同步。
    %   * NumericEditField 的 Value **只接数值**: 实测赋 '77' 也抛
    %     MATLAB:ui:NumericEditField:invalidValue。因此 EditorFlavor='text' 的数值卡
    %     用文本编辑框承载数值 (字符可原样写回, 供"载入配置回填"与界面校验用),
    %     合法域改由 AppState 的 min/max 判定 + 提示行显示, 单位仍走相邻标签。
    %   * 数值控件**没有单位后缀属性**。单位有两条合法出路: 相邻 label (缺省),
    %     或写进 ValueDisplayFormat 的格式串尾缀 (UnitMode='suffix')。尾缀若被本机
    %     拒绝, 失败会记进 PropertyErrors 并自动退回相邻 label, 不留一个空头衔。
    %   * 折叠没有公开 uiaccordion: 用 Visible off + 父网格本行 RowHeight 置 0 实现。
    %   * RowHeight / ColumnWidth 只接受数字、'Nx'、'fit', 没有 'auto'。
    %   * 行布局两档: Layout='standard' 用 Theme.layout('card') 的三行; Layout='compact'
    %     用 Theme.layout('cardCompact') 的两行 (标签+控件+步长+单位+徽标 / 提示行),
    %     给"一屏放下整张表单"的页签用。OpenHeight 含 RowSpacing, 因此写回父网格
    %     的行高不会比卡片自己的实际堆叠高度小。
    %
    % 本卡片不持有 AppState, 也不碰物理量: 它只管"一格输入 + 它的呈现"。改动经
    % OnChange 挂载点交回应用层, 由应用层决定何时写状态源 (一处写入, 不会两头分叉)。

    properties (SetAccess = private)
        Root = []          % 卡片自己的 uigridlayout
        Label = []
        Editor = []        % uieditfield(numeric/text) 或 uidropdown
        Spinner = []       % uispinner, 仅在给了 Step 时创建
        UnitLabel = []
        Badge = []         % 来源状态徽标 (颜色 + 图标 + 文字 三通道)
        HintLabel = []     % 范围/来源/就地校验提示
        Tag = ''
        Kind = 'num'
        Spec = []
        ValueStatus = ''
        Unit = ''
        Min = []
        Max = []
        Step = []
        Advanced = false
        Collapsed = false
        Issues = {}
        ParentGrid = []
        Row = 0
        Col = 1
        ColSpan = 1
        OpenHeight = 0
        ChangeCount = 0
        PropertyErrors = {}
        LastEvent = []
        EditorFlavor = 'numeric'   % numeric | text (见 makeEditor 的本机 API 说明)
        Compact = false            % true: 两行卡片 (表单密度), false: Theme.layout('card') 三行
        Syncing = false            % 程序写值期间的重入闸 (避免 editor<->spinner 互触发)
    end

    properties
        OnChange = []        % @(evt) 挂载点; evt = struct(tag, value, count, source)
        UnitMode = 'label'   % 'label' 相邻标签 | 'suffix' 写进 ValueDisplayFormat
        ShowSpinner = true
    end

    methods
        function self = ParameterCard(parent, spec, opts)
            %PARAMETERCARD(parent, spec, opts) 在 parent 里建一张卡片。
            %   opts: UnitMode('label'|'suffix') / ShowSpinner(logical) /
            %         EditorFlavor('numeric'|'text') / Layout('standard'|'compact')
            if nargin < 3, opts = struct(); end
            if isempty(parent)
                error('tepc:gui:NoParent', 'ParameterCard 需要一个父容器');
            end
            s = ParameterCard.asStruct(spec);
            self.Spec = s;
            self.Tag = char(string(Theme.optOr(s, 'Tag', '')));
            if isempty(self.Tag)
                error('tepc:gui:BadSpec', '字段描述缺少 Tag: 卡片无法被映射表寻址');
            end
            self.Kind = lower(char(string(Theme.optOr(s, 'Kind', 'num'))));
            self.Unit = char(string(Theme.optOr(s, 'Unit', '')));
            self.Min = Theme.optOr(s, 'Min', []);
            self.Max = Theme.optOr(s, 'Max', []);
            self.Step = Theme.optOr(s, 'Step', []);
            self.Advanced = logical(Theme.optOr(s, 'Advanced', false));
            self.ValueStatus = Theme.normStatus(Theme.optOr(s, 'ValueStatus', ''));
            if ~isempty(opts) && isstruct(opts)
                if isfield(opts, 'UnitMode') && ~isempty(opts.UnitMode)
                    self.UnitMode = char(string(opts.UnitMode));
                end
                if isfield(opts, 'ShowSpinner') && ~isempty(opts.ShowSpinner)
                    self.ShowSpinner = logical(opts.ShowSpinner);
                end
                if isfield(opts, 'EditorFlavor') && ~isempty(opts.EditorFlavor)
                    self.EditorFlavor = ParameterCard.pickFlavor(opts.EditorFlavor);
                end
                if isfield(opts, 'Layout') && ~isempty(opts.Layout)
                    self.Compact = strcmp(lower(char(string(opts.Layout))), 'compact');
                end
            end
            self.UnitMode = ParameterCard.pickUnitMode(self.UnitMode);
            if self.Compact
                L = Theme.layout('cardCompact');
            else
                L = Theme.layout('card');
            end
            self.OpenHeight = ParameterCard.stackHeight(L.RowHeight) + ...
                L.Padding(1) + L.Padding(3) + L.Spacing(1)*max(0, numel(L.RowHeight) - 1);
            self.Root = uigridlayout(parent);
            self.Root.RowHeight = L.RowHeight;
            self.Root.ColumnWidth = L.ColumnWidth;
            self.Root.Padding = L.Padding;
            self.Root.RowSpacing = L.Spacing(1);
            self.Root.ColumnSpacing = L.Spacing(2);
            self.buildWidgets(s);
            self.setStatus(self.ValueStatus);
        end

        % ---------- 取值与写值 ----------
        function v = value(self)
            %VALUE 控件当前值。数值格取不到时给 NaN 而不是 0: 0 是一个合法物理值。
            if isempty(self.Editor) || ~isvalid(self.Editor)
                v = NaN;
                return;
            end
            if self.isNumericKind()
                x = ParameterCard.asNumber(self.Editor.Value);
                if isempty(x) || ~isfinite(x)
                    v = NaN;
                else
                    v = x;
                end
            else
                v = strtrim(char(string(self.Editor.Value)));
            end
        end

        function tf = usesNumericEditor(self)
            %USESNUMERICEDITOR 本卡片是否真的用了 NumericEditField (text 承载时否)。
            tf = self.isNumericKind() && strcmp(self.EditorFlavor, 'numeric');
        end

        function syncSpinner(self)
            %SYNCSPIINNER 把步长控件拉到承载格当前的值 (应用层直接写控件后调它)。
            %   不做这件事时点一下步长箭头会从旧值起跳 —— 那比没有步长更难解释。
            if ~self.isNumericKind() || isempty(self.Spinner) || ~isvalid(self.Spinner)
                return;
            end
            x = ParameterCard.asNumber(self.Editor.Value);
            if isempty(x) || ~isfinite(x), return; end
            if ~isempty(self.Min), x = max(x, double(self.Min)); end
            if ~isempty(self.Max), x = min(x, double(self.Max)); end
            self.Syncing = true;
            cleanupObj = onCleanup(@() self.releaseSyncing());
            try
                self.Spinner.Value = x;
            catch e
                self.noteError('syncSpinner', e.message);
            end
        end

        function ok = writeValue(self, v)
            %WRITEVALUE 程序写入 (载入配置回填用); 不触发 OnChange, 避免回填被当成用户输入。
            ok = false;
            if isempty(self.Editor) || ~isvalid(self.Editor)
                self.noteError('writeValue', '控件已失效, 无法写入');
                return;
            end
            self.Syncing = true;
            cleanupObj = onCleanup(@() self.releaseSyncing());
            try
                if self.isNumericKind()
                    x = ParameterCard.asNumber(v);
                    if isempty(x) || ~isfinite(x)
                        self.noteError('writeValue', [self.Tag ' 收到非有限值, 已忽略']);
                        return;
                    end
                    self.Editor.Value = self.valueForEditor(x);
                    if ~isempty(self.Spinner) && isvalid(self.Spinner)
                        self.Spinner.Value = x;
                    end
                    ok = true;
                elseif strcmp(self.Kind, 'enum')
                    s = strtrim(char(string(v)));
                    if isempty(s)
                        self.noteError('writeValue', [self.Tag ' 收到空枚举值, 已忽略']);
                        return;
                    end
                    items = cellstr(string(self.Editor.Items));
                    if ~any(strcmp(items, s))
                        % 配置里的值不在预置项里时不静默丢弃, 而是追加并选中
                        items{end+1} = s;
                        self.Editor.Items = items;
                    end
                    self.Editor.Value = s;
                    ok = true;
                else
                    self.Editor.Value = strtrim(char(string(v)));
                    ok = true;
                end
            catch e
                self.noteError('writeValue', e.message);
            end
        end

        function releaseSyncing(self)
            self.Syncing = false;
        end

        function tf = syncing(self)
            tf = self.Syncing;
        end

        function txt = valueForEditor(self, x)
            %VALUEFOREDITOR 数值 -> 该编辑器吃得下的值。NumericEditField 只接数值
            %   (实测 '77' 这种字符会被拒), 文本承载格则反过来要字符。
            if self.usesNumericEditor()
                txt = x;
            else
                txt = self.numberText(x);
            end
        end

        function t = numberText(self, x)
            %NUMBERTEXT 按字段描述的格式串收成文本; 缺格式时用 %.10g
            %   (与界面回填的写法同源, 1234567 这类值不会被压成 1.23457e+06)。
            f = char(string(ParameterCard.formatOf(self.Spec)));
            try
                t = sprintf(f, double(x));
            catch
                % silent-by-design: 格式串不适用本机时退回通用写法, 不丢值
                t = sprintf('%.10g', double(x));
            end
        end

        function tf = isNumericKind(self)
            tf = any(strcmp(self.Kind, {'num', 'int'}));
        end

        % ---------- 呈现 ----------
        function setStatus(self, status)
            %SETSTATUS 来源状态徽标: 颜色 + 图标 + 文字三通道一起给。
            %   只改颜色不改文字等于把可访问性降级成"仅靠颜色区分"。
            s = Theme.normStatus(status);
            if isempty(s), s = 'UNKNOWN'; end
            self.ValueStatus = s;
            if isempty(self.Badge) || ~isvalid(self.Badge)
                return;
            end
            one = Theme.tripletFor(s);
            self.Badge.Text = [one.glyph, ' ', one.label];
            self.Badge.FontColor = one.color;
            self.Badge.BackgroundColor = one.background;
            self.Badge.Tooltip = sprintf('来源状态 %s (%s) | 色值 %s', ...
                one.label, one.status, one.hex);
            self.refreshHint();
        end

        function tf = isAssumed(self)
            tf = strcmp(self.ValueStatus, 'ASSUMED');
        end

        function tf = matchesFilter(self, mode)
            %MATCHESFILTER 卡片级筛选: all / assumed / issue / advanced / basic。
            m = lower(char(string(mode)));
            switch m
                case 'all',      tf = true;
                case 'assumed',  tf = self.isAssumed();
                case 'issue',    tf = ~isempty(self.Issues);
                case 'advanced', tf = self.Advanced;
                case 'basic',    tf = ~self.Advanced;
                otherwise
                    error('tepc:gui:BadFilterMode', ...
                        ['未知筛选模式 ' m ...
                         ' (可用: all/assumed/issue/advanced/basic)']);
            end
        end

        function showIssues(self, issues)
            %SHOWISSUES 把校验问题挂在字段旁边。
            %   来源状态徽标**不**跟着变: 合法但来源是假设, 与非法是两件事,
            %   挤在同一个徽标上会互相掩盖。
            if isempty(issues)
                self.Issues = {};
            elseif iscell(issues)
                self.Issues = issues(:)';
            else
                self.Issues = {issues};
            end
            self.refreshHint();
        end

        function clearIssues(self)
            self.Issues = {};
            self.refreshHint();
        end

        function n = issueCount(self)
            n = numel(self.Issues);
        end

        function setRange(self, lo, hi)
            %SETRANGE 改合法域: 能落到控件上的就落 (NumericEditField 有 Limits),
            %   文本承载格没有 Limits 属性 -> 域只进提示行并由 AppState 判定。
            self.Min = lo;
            self.Max = hi;
            lim = [double(lo), double(hi)];
            if ~isempty(self.Editor) && isvalid(self.Editor) && isprop(self.Editor, 'Limits')
                self.setProps(self.Editor, {'Limits', 'LowerLimitInclusive', ...
                    'UpperLimitInclusive'}, {lim, true, true});
            end
            self.setProps(self.Spinner, {'Limits'}, {lim});
            self.refreshHint();
        end

        function setStep(self, st)
            %SETSTEP 步长只有 uispinner 认 (uieditfield 没有 Step 属性)。
            self.Step = st;
            if ~isempty(st)
                self.setProps(self.Spinner, {'Step'}, {double(st)});
            end
            self.refreshHint();
        end

        function setEditable(self, tf)
            on = ParameterCard.enableText(logical(tf));
            self.setProps(self.Editor, {'Enable'}, {on});
            self.setProps(self.Spinner, {'Enable'}, {on});
        end

        function setCollapsed(self, tf)
            %SETCOLLAPSED 折叠 = 子控件隐藏 + 父网格本行行高归 0。
            %   本机没有公开的 uiaccordion。行高不置 0 的话, 隐藏后的卡片仍会在网格上
            %   留一条点不到的空白, 所以两步都要做。
            self.Collapsed = logical(tf);
            on = ParameterCard.visibleText(~self.Collapsed);
            comps = {self.Label, self.Editor, self.Spinner, self.UnitLabel, ...
                self.Badge, self.HintLabel};
            for i = 1:numel(comps)
                c = comps{i};
                if ~isempty(c) && isvalid(c)
                    try
                        c.Visible = on;
                    catch e
                        self.noteError('setCollapsed', e.message);
                    end
                end
            end
            self.applyRowHeight();
        end

        function tf = collapsed(self)
            tf = self.Collapsed;
        end

        function ids = componentIds(self)
            %COMPONENTIDS 本卡片持有的控件句柄 (double 形式)。
            %   应用层按句柄批量刷样式时要跳过这些控件: 紧凑卡片两行装六个控件,
            %   字号被外面的正文档 (14) 刷大会把提示行裁掉。
            comps = {self.Label, self.Editor, self.Spinner, self.UnitLabel, ...
                self.Badge, self.HintLabel};
            ids = [];
            for i = 1:numel(comps)
                c = comps{i};
                try
                    if ~isempty(c) && isvalid(c)
                        ids(end+1) = double(c); %#ok<AGROW>
                    end
                catch
                    % silent-by-design: 清理中的句柄不计入, 不影响卡片本身
                end
            end
        end

        function vis = visibleState(self)
            %VISIBLESTATE 六个子控件的 Visible 真值 (1=on) + 本行实际行高。
            %   这是"隐藏/裁切"能被属性读取核验的入口: 图元不可见必须报告化,
            %   而不是靠人盯屏幕。
            comps = {self.Label, self.Editor, self.Spinner, self.UnitLabel, ...
                self.Badge, self.HintLabel};
            names = {'label', 'editor', 'spinner', 'unit', 'badge', 'hint'};
            vis = struct();
            for i = 1:numel(comps)
                f = names{i};
                if isempty(comps{i}) || ~isvalid(comps{i})
                    vis.(f) = 0;
                else
                    try
                        vis.(f) = double(strcmp(comps{i}.Visible, 'on'));
                    catch
                        vis.(f) = -1;
                    end
                end
            end
            vis.row = self.Row;
            vis.row_height = NaN;
            vis.parent_height = NaN;
            try
                if ~isempty(self.ParentGrid) && isvalid(self.ParentGrid) && self.Row >= 1
                    x = self.ParentGrid.RowHeight{self.Row};
                    if isnumeric(x) && isscalar(x)
                        vis.row_height = double(x);
                    end
                    vis.parent_height = double(self.ParentGrid.Position(4));
                end
            catch
                % silent-by-design: 窗口未 realize 时行高读不到, 保持 NaN
            end
        end

        function place(self, row, col, span)
            %PLACE(row, col, span) 挂到父网格并记住位置。
            %   记住行号是折叠的前提: RowHeight 是父网格的属性, 卡片自己改不到。
            if nargin < 3, col = 1; end
            if nargin < 4, span = 1; end
            self.Row = max(1, round(double(row)));
            self.Col = max(1, round(double(col)));
            self.ColSpan = max(1, round(double(span)));
            if ~isempty(self.Root) && isvalid(self.Root)
                self.ParentGrid = self.Root.Parent;
                self.Root.Layout.Row = self.Row;
                if self.ColSpan == 1
                    self.Root.Layout.Column = self.Col;
                else
                    self.Root.Layout.Column = [self.Col, self.Col + self.ColSpan - 1];
                end
            end
            self.applyRowHeight();
        end

        function s = state(self)
            %STATE 结构化快照 (纯数据), 回归测试直接断言它, 不需要读像素。
            s = struct();
            s.tag = self.Tag;
            s.kind = self.Kind;
            s.editor_flavor = self.EditorFlavor;
            s.uses_numeric_editor = self.usesNumericEditor();
            s.compact = self.Compact;
            s.layout = self.pickLayoutName();
            s.value = self.value();
            s.value_status = self.ValueStatus;
            s.unit = self.Unit;
            s.min = self.Min;
            s.max = self.Max;
            s.step = self.Step;
            s.advanced = self.Advanced;
            s.collapsed = self.Collapsed;
            s.n_issues = numel(self.Issues);
            s.changes = self.ChangeCount;
            s.badge_text = ParameterCard.textOf(self.Badge);
            s.hint_text = ParameterCard.textOf(self.HintLabel);
            s.unit_label_shown = ParameterCard.shown(self.UnitLabel);
            s.row = self.Row;
            s.open_height = self.OpenHeight;
            s.property_errors = self.PropertyErrors;
        end

        function delete(self)
            %DELETE 只销毁本卡片的控件; 父容器与父网格归调用方。
            comps = {self.Label, self.HintLabel, self.UnitLabel, self.Badge, ...
                self.Spinner, self.Editor, self.Root};
            for i = 1:numel(comps)
                c = comps{i};
                try
                    if ~isempty(c) && isvalid(c)
                        delete(c);
                    end
                catch
                    % 清理路径不得抛错: 析构里抛错会被 MATLAB 吞掉并污染退出码
                end
            end
        end
    end

    methods (Access = private)
        function buildWidgets(self, s)
            %BUILDWIDGETS 两档堆叠:
            %   standard 三行 = 标签+徽标 / 控件+步长+单位 / 范围与提示
            %   compact  两行 = 标签+控件+步长+单位+徽标 / 范围与提示
            nCol = numel(self.Root.ColumnWidth);
            self.Label = uilabel(self.Root);
            self.Label.HorizontalAlignment = 'left';
            self.applyFont(self.Label, 'body');
            if self.Compact
                self.Label.Layout.Row = 1; self.Label.Layout.Column = 1;
            else
                self.Label.Layout.Row = 1; self.Label.Layout.Column = 1;
            end
            self.setProps(self.Label, {'Text', 'FontColor'}, ...
                {ParameterCard.titleOf(s), Theme.ColorInk});

            self.Badge = uilabel(self.Root);
            self.Badge.HorizontalAlignment = 'center';
            self.applyFont(self.Badge, 'micro');
            if self.Compact
                self.Badge.Layout.Row = 1; self.Badge.Layout.Column = nCol;
            else
                self.Badge.Layout.Row = 1; self.Badge.Layout.Column = [2, 3];
            end

            self.Editor = self.makeEditor(s);
            self.Editor.Layout.Row = 1 + double(~self.Compact);
            self.Editor.Layout.Column = 1 + double(self.Compact);
            if ~self.Compact
                self.applyFont(self.Editor, 'body');
            else
                self.applyFont(self.Editor, 'micro');
            end

            if self.isNumericKind() && ~isempty(self.Step) && self.ShowSpinner
                self.Spinner = uispinner(self.Root);
                self.Spinner.Layout.Row = self.Editor.Layout.Row;
                self.Spinner.Layout.Column = self.Editor.Layout.Column + 1;
                self.Spinner.Step = double(self.Step);
                self.Spinner.ValueChangedFcn = @(~, ~) self.onSpinnerChanged();
                if ~isempty(self.Min) && ~isempty(self.Max)
                    self.Spinner.Limits = [double(self.Min), double(self.Max)];
                end
                % 初值跟着承载格走并夹进合法域: 缺省 0 会让"点一下步长"把值跳到步长格
                x0 = ParameterCard.asNumber(Theme.optOr(s, 'Value', []));
                if ~isempty(x0) && isfinite(x0)
                    if ~isempty(self.Min), x0 = max(x0, double(self.Min)); end
                    if ~isempty(self.Max), x0 = min(x0, double(self.Max)); end
                    self.Spinner.Value = x0;
                end
                self.applyFont(self.Spinner, 'micro');
            end

            self.UnitLabel = uilabel(self.Root);
            self.UnitLabel.HorizontalAlignment = 'left';
            self.UnitLabel.FontColor = Theme.ColorMuted;
            self.applyFont(self.UnitLabel, 'micro');
            self.UnitLabel.Text = self.Unit;
            if self.Compact
                % 有步长时单位在步长右侧, 徽标再右移一格 (列序: 标签/控件/步长/单位/徽标)
                self.UnitLabel.Layout.Row = 1;
                self.UnitLabel.Layout.Column = self.Editor.Layout.Column + 1;
            else
                self.UnitLabel.Layout.Row = 2;
                self.UnitLabel.Layout.Column = 3;
            end
            % 相邻 label 与格式串尾缀二选一; 尾缀失败会自动退回相邻 label
            self.UnitLabel.Visible = ParameterCard.visibleText(...
                strcmp(self.UnitMode, 'label') || ~self.isNumericKind());
            if self.isNumericKind() && strcmp(self.UnitMode, 'suffix')
                self.applyUnitSuffix(s);
            end

            self.HintLabel = uilabel(self.Root);
            self.HintLabel.HorizontalAlignment = 'left';
            self.HintLabel.FontColor = Theme.ColorMuted;
            self.applyFont(self.HintLabel, 'micro');
            self.HintLabel.Layout.Row = numel(self.Root.RowHeight);
            self.HintLabel.Layout.Column = [1, nCol];
            self.refreshHint();
        end

        function ed = makeEditor(self, s)
            %MAKEEDITOR 按类型建输入控件并挂 ValueChangedFcn。
            %   数值格的两种承载 (实测本机 NumericEditField 拒绝字符赋值):
            %     numeric -> uieditfield('numeric'), 有 Limits/ValueDisplayFormat;
            %     text    -> uieditfield('text'), 字符可原样回填, 域判定交给状态源。
            ed = [];
            if strcmp(self.Kind, 'enum')
                ed = uidropdown(self.Root);
                items = Theme.optOr(s, 'Items', {});
                ed.Items = ParameterCard.asItemCell(items);
                ed.ValueChangedFcn = @(~, ~) self.onChanged();
                return;
            end
            if self.usesNumericEditor()
                ed = uieditfield(self.Root, 'numeric');
            else
                ed = uieditfield(self.Root, 'text');
            end
            ed.ValueChangedFcn = @(~, ~) self.onChanged();
            if self.isNumericKind()
                % 实测: AllowEmpty 只在 matlab.ui.control.NumericEditField 上有;
                % EditorFlavor='text' 的卡拿到的是父类 matlab.ui.control.EditField,
                % 直接赋值抛 MATLAB:noPublicFieldForClass 并让整个 TEPCApp 构造失败。
                if isprop(ed, 'AllowEmpty')
                    ed.AllowEmpty = false;
                end
                fmt = ParameterCard.formatOf(s);
                if strcmp(self.Kind, 'int') && isprop(ed, 'RoundFractionalValues')
                    ed.RoundFractionalValues = true;
                    fmt = '%d';
                end
                if isprop(ed, 'ValueDisplayFormat')
                    self.setProps(ed, {'ValueDisplayFormat'}, {fmt});
                end
                if ~isempty(self.Min) || ~isempty(self.Max)
                    self.setRangeQuiet(self.Min, self.Max);
                end
            end
            v0 = Theme.optOr(s, 'Value', []);
            if ~isempty(v0)
                ed.Value = self.valueForEditorChecked(v0);
            end
        end

        function v = valueForEditorChecked(self, v0)
            %VALUEFOREDITORCHECKED 初始值写进"该编辑器吃得下"的形状 (文本格给字符)。
            if ~self.isNumericKind() || self.usesNumericEditor()
                v = v0;
                return;
            end
            x = ParameterCard.asNumber(v0);
            if isempty(x) || ~isfinite(x)
                v = v0;
            else
                v = self.numberText(x);
            end
        end

        function setRangeQuiet(self, lo, hi)
            %SETRANGEQUIET 建控件期用: 只设编辑器自己的 Limits, 不回头刷提示行
            %   (提示行此刻还没建)。步长控件的 Limits 在它自己的创建分支里设。
            if isempty(lo) && isempty(hi)
                return;
            end
            a = -Inf;
            b = Inf;
            if ~isempty(lo), a = double(lo); end
            if ~isempty(hi), b = double(hi); end
            if isprop(self.Editor, 'Limits')
                self.setProps(self.Editor, {'Limits', 'LowerLimitInclusive', ...
                    'UpperLimitInclusive'}, {[a, b], true, true});
            end
        end

        function applyUnitSuffix(self, s)
            %APPLYUNITSUFFIX 单位写进 ValueDisplayFormat 的尾缀 (仅数值承载格)。
            %   本机若拒绝带尾缀的格式串, setProps 会把失败记下来, 这里据此把相邻
            %   单位标签重新打开 —— 用户不会看到一个"单位凭空消失"的格子。
            if isempty(self.Unit) || ~self.usesNumericEditor()
                return;
            end
            fmt = ParameterCard.formatOf(s);
            if strcmp(self.Kind, 'int'), fmt = '%d'; end
            before = numel(self.PropertyErrors);
            self.setProps(self.Editor, {'ValueDisplayFormat'}, {[fmt, ' ', self.Unit]});
            if numel(self.PropertyErrors) > before
                self.UnitLabel.Visible = 'on';
            end
        end

        function onSpinnerChanged(self)
            %ONSPINNERCHANGED 步长控件 -> 把值写回承载格, 再走同一条改动路径。
            %   程序写回会再次触发编辑框的 ValueChangedFcn, 所以用 Syncing 挡住回环。
            x = NaN;
            try
                x = double(self.Spinner.Value);
            catch e
                self.noteError('onSpinnerChanged', e.message);
                return;
            end
            if ~isempty(self.Editor) && isvalid(self.Editor) && ~self.Syncing
                self.Syncing = true;
                cleanupObj = onCleanup(@() self.releaseSyncing());
                try
                    self.Editor.Value = self.valueForEditor(x);
                catch e
                    self.noteError('spinnerSync', e.message);
                end
            end
            self.onChanged();
        end

        function onChanged(self)
            %ONCHANGED 控件改动 -> 计数 -> 交给挂载点。本卡片不写状态源也不算派生量。
            %   回环防护: 由 writeValue / onSpinnerChanged 引起的程序写入不再往外报,
            %   否则一次回填会被应用层当成一次用户输入, 派生量与脏标记都会多算一遍。
            if self.Syncing
                return;
            end
            self.ChangeCount = self.ChangeCount + 1;
            evt = struct();
            evt.tag = self.Tag;
            evt.value = self.value();
            evt.count = self.ChangeCount;
            evt.source = self;
            self.LastEvent = evt;
            if isempty(self.OnChange) || ~isa(self.OnChange, 'function_handle')
                return;
            end
            try
                feval(self.OnChange, evt);
            catch e
                self.noteError('OnChange', e.message);
            end
        end

        function refreshHint(self)
            %REFRESHHINT 提示行 = 范围/步长 + 来源三通道 + (有问题时) 首条问题。
            if isempty(self.HintLabel) || ~isvalid(self.HintLabel)
                return;
            end
            bits = {self.rangeText()};
            if ~isempty(self.ValueStatus)
                bits{end+1} = Theme.marked(self.ValueStatus); %#ok<AGROW>
            end
            bad = false;
            if ~isempty(self.Issues)
                bad = true;
                txt = ParameterCard.issueText(self.Issues{1});
                bits{end+1} = [Theme.glyphFor('FAIL'), ' ', txt]; %#ok<AGROW>
                if numel(self.Issues) > 1
                    bits{end+1} = sprintf('另有 %d 条', numel(self.Issues) - 1); %#ok<AGROW>
                end
            end
            self.HintLabel.Text = strjoin(bits, ' | ');
            if bad
                self.HintLabel.FontColor = Theme.ColorBad;
            else
                self.HintLabel.FontColor = Theme.ColorMuted;
            end
        end

        function t = rangeText(self)
            t = '';
            if ~isempty(self.Min) || ~isempty(self.Max)
                lo = '-inf';
                hi = '+inf';
                if ~isempty(self.Min), lo = num2str(self.Min, '%.10g'); end
                if ~isempty(self.Max), hi = num2str(self.Max, '%.10g'); end
                t = ['范围 ' lo ' .. ' hi];
            end
            if ~isempty(self.Step) && self.isNumericKind()
                if ~isempty(t), t = [t, ' | ']; end
                t = [t, '步长 ' num2str(self.Step, '%.10g')];
            end
            if isempty(t)
                t = '未登记范围';
            end
        end

        function nm = pickLayoutName(self)
            if self.Compact, nm = 'compact'; else, nm = 'standard'; end
        end

        function applyRowHeight(self)
            %APPLYROWHEIGHT 折叠时把父网格中本卡片那一行的行高写成 0。
            if isempty(self.ParentGrid) || ~isvalid(self.ParentGrid) || self.Row < 1
                return;
            end
            h = self.OpenHeight;
            if self.Collapsed, h = 0; end
            try
                self.ParentGrid.RowHeight(self.Row) = {h};
            catch e
                self.noteError('applyRowHeight', e.message);
            end
        end

        function applyFont(self, comp, level)
            f = Theme.fontSpec(level);
            self.setProps(comp, {'FontName', 'FontSize'}, {f.family, f.size});
        end

        function setProps(self, comp, names, vals)
            %SETPROPS 逐个赋属性。本机不认的属性只记录不抛出: 一个可选修饰属性
            %   建不起来不该让整张卡片消失, 但也不能假装设上了。
            if isempty(comp) || ~isvalid(comp)
                return;
            end
            k = min(numel(names), numel(vals));
            for i = 1:k
                try
                    comp.(names{i}) = vals{i};
                catch e
                    self.noteError('setProps', sprintf('%s 属性设置失败: %s', ...
                        names{i}, e.message));
                end
            end
        end

        function noteError(self, where, msg)
            %NOTEERROR 失败留痕: 静默跳过的属性设置会让"界面看着有, 其实是死的"。
            self.PropertyErrors{end+1} = sprintf('%s(%s): %s', self.Tag, where, ...
                char(string(msg))); %#ok<AGROW>
        end
    end

    methods (Static, Access = private)
        function s = asStruct(spec)
            if isstruct(spec)
                s = spec;
            elseif iscell(spec) && ~isempty(spec) && isstruct(spec{1})
                s = spec{1};
            else
                error('tepc:gui:BadSpec', ...
                    ['字段描述必须是结构体 (至少含 Tag 与 Kind), 收到 ' class(spec)]);
            end
        end

        function h = stackHeight(rows)
            %STACKHEIGHT 行高元胞里的数字部分求和 ('1x' 与 'fit' 无法静态算高度, 不计)。
            h = 0;
            for i = 1:numel(rows)
                x = rows{i};
                if isnumeric(x) && isscalar(x)
                    h = h + double(x);
                end
            end
        end

        function t = titleOf(s)
            lb = char(string(Theme.optOr(s, 'Label', '')));
            if isempty(lb)
                tg = char(string(Theme.optOr(s, 'Tag', '?')));
                lb = ['未命名参数 (' tg ')'];
            end
            t = lb;
        end

        function f = formatOf(s)
            f = char(string(Theme.optOr(s, 'Format', '')));
            d = Theme.optOr(s, 'Decimals', []);
            if isempty(f)
                if isempty(d), d = 6; end
                f = sprintf('%%.%dg', round(double(d)));
            end
        end

        function items = asItemCell(items)
            if iscell(items)
                items = cellstr(string(items(:)'));
            else
                items = cellstr(string(items));
            end
        end

        function x = asNumber(v)
            %ASNUMBER 把控件值收成标量: 数字直取, 字符走 str2double。
            x = [];
            if isempty(v), return; end
            if islogical(v)
                x = double(v(1));
                return;
            end
            if isnumeric(v)
                x = double(v(1));
                return;
            end
            s = strtrim(char(string(v)));
            if isempty(s), return; end
            y = str2double(s);
            if ~isnan(y)
                x = y;
            end
        end

        function m = pickUnitMode(m0)
            m = lower(char(string(m0)));
            if ~any(strcmp(m, {'label', 'suffix'}))
                error('tepc:gui:BadUnitMode', ...
                    ['UnitMode 只能是 label 或 suffix (数值控件没有单位后缀属性), 收到 ' m]);
            end
        end

        function f = pickFlavor(f0)
            % 本机没有 uinumericeditfield: 数值编辑是 uieditfield(p,'numeric') + uispinner,
            % 它的 Value 只接数值, 塞字符串会抛 MATLAB:ui:NumericEditField:invalidValue。
            % 所以"文本档"与"数值档"必须是显式两选一, 未知值当场报错而不是悄悄退回默认档 ——
            % 退回默认会让调用方以为自己传的选项生效了。
            f = lower(char(string(f0)));
            if ~any(strcmp(f, {'numeric', 'text'}))
                error('tepc:gui:BadEditorFlavor', ...
                    ['EditorFlavor 只能是 numeric 或 text, 收到 ' f]);
            end
        end

        function t = visibleText(on)
            if logical(on), t = 'on'; else, t = 'off'; end
        end

        function t = enableText(on)
            if logical(on), t = 'on'; else, t = 'off'; end
        end

        function t = textOf(comp)
            t = '';
            try
                if ~isempty(comp) && isvalid(comp)
                    t = char(string(comp.Text));
                end
            catch
                t = '';
            end
        end

        function tf = shown(comp)
            tf = false;
            try
                tf = ~isempty(comp) && isvalid(comp) && strcmp(comp.Visible, 'on');
            catch
                tf = false;
            end
        end

        function t = issueText(one)
            %ISSUETEXT 问题列表项 -> 一行文本。AppState.issue 的形状是
            %   struct(level, code, message, tag), 报告层的形状可能只有 message,
            %   所以缺字段时留空而不是抛错。
            if ~isstruct(one)
                t = char(string(one));
                return;
            end
            t = '';
            if isfield(one, 'message') && ~isempty(one.message)
                t = char(string(one.message));
            end
            if isfield(one, 'code') && ~isempty(one.code)
                t = [char(string(one.code)), ': ', t];
            end
            if isempty(t)
                t = '校验未给出说明';
            end
        end
    end
end
