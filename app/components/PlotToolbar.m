classdef PlotToolbar < handle
    %PLOTTOOLBAR 图区小工具条: 视角预设 / 复制可复现命令 / 导出图 / 三层可见性。
    %
    % 职责边界 (刻意做窄, 越界就是撒谎):
    %   * 只产生"用户要什么"的结构化请求并把回调转出去; 不调用任何绘图函数,
    %     不取 axes 句柄, 不算相机, 不算物理量。视角怎么改、图怎么导由应用层实现。
    %   * 三层 (真值 Truth / 仪器 Instrument / 实验 Experiment) 的缺省可用性与本仓库
    %     实况一致: 没有任何实测数据, 所以实验层默认**不可开**并写明原因,
    %     而不是画一条没有说明的第三条曲线。
    %   * 复制命令走 clipboard (内建, Windows 可用), 失败就退回把命令文本显示在
    %     状态里让用户自己选抄; 不假装"已复制"。
    %   * 布局只用合法 token: 行高/列宽取数字、'Nx'、'fit', 没有 'auto'。
    %   * 静态方法块必须写 methods (Static): 写 methods (Access = static) 在类加载期
    %     就抛 MATLAB:class:InvalidAccessValue, 整个类因此不可用 (本机实测)。

    properties (SetAccess = private)
        Root = []
        ViewBox = []          % uidropdown: 视角预设
        CopyButton = []
        ExportButton = []
        LayerBoxes = []       % layer token -> uicheckbox
        StatusLabel = []      % 一行回显 (复制结果 / 缺层原因)
        Presets = {}          % {标签, token} 两列, 顺序即下拉顺序
        ViewPreset = 'home'
        Layers = []           % struct: 每个 layer 一个字段, 值为 logical
        Available = []        % struct: 每个 layer 是否有数据可显
        Notes = []            % struct: 每个 layer 的不可用原因文本
        LayerTokens = {}      % 层 token 序列 (缺省 truth/instrument/experiment)
        LayerTexts = {}       % {token, 显示名, 前景色} 三列, 顺序与 LayerTokens 一致
        UnavailableWords = {} % 缺省判"无数据"的 token 名
        CommandText = ''
        SuggestedName = ''
        StatusText = ''       % 回显文本的属性镜像 (控件可能已销毁, 属性始终最新)
        LastAction = ''
        Actions = {}          % 依次发生过的动作 (审计用, 也是测试断言处)
        Errors = {}
    end

    properties
        OnViewPreset = []     % @(req) 视角预设挂载点
        OnCopyCommand = []    % @(req) 复制命令挂载点 (置空则走内建剪贴板)
        OnExport = []         % @(req) 导出图挂载点
        OnLayers = []         % @(req) 可见性变化挂载点
    end

    methods
        function self = PlotToolbar(parent, opts)
            %PLOTTOOLBAR(parent, opts) 建工具条。
            %   opts.CommandText 初始可复现命令; opts.ExportName 建议文件名前缀;
            %   opts.Available 结构体 (层 token -> 是否有数据可显);
            %   opts.Layers 换层集合: {{token, 显示名, 前景色}, ...} —— 显示名由宿主页
            %     决定, 本组件不猜某一页里"某一层"具体画什么; 缺省仍是
            %     truth/instrument/experiment 三层 (谱页的口径);
            %   opts.Unavailable 缺省判"无数据"的 token 列表 (缺省 {'experiment'})。
            %   本构造函数只有两个入参, 缺省判据必须是 nargin<2: 写成 nargin<3 会把
            %   调用方传进来的 opts 整个丢掉, Layers/CommandText/ExportName 全部静默失效。
            if nargin < 2, opts = struct(); end
            if isempty(parent)
                error('tepc:gui:NoParent', 'PlotToolbar 需要一个父容器');
            end
            self.Presets = {{'正视', 'front'}, {'侧视', 'side'}, {'俯视', 'top'}, ...
                {'等轴', 'iso'}, {'全览', 'fit'}, {'复位', 'home'}};
            self.LayerTexts = PlotToolbar.defaultLayers();
            lay = Theme.optOr(opts, 'Layers', {});
            if ~isempty(lay)
                self.LayerTexts = PlotToolbar.asLayers(lay);
            end
            n = numel(self.LayerTexts);
            self.LayerTokens = cell(1, n);
            for i = 1:n
                self.LayerTokens{i} = char(string(self.LayerTexts{i}{1}));
            end
            uw = Theme.optOr(opts, 'Unavailable', {'experiment'});
            self.UnavailableWords = cellstr(string(uw));
            self.Layers = struct();
            self.Available = struct();
            self.Notes = struct();
            self.LayerBoxes = struct();   % 赋字段前必须是 struct (给 double 赋字段会直接报错)
            names = self.layerNames();
            avail = Theme.optOr(opts, 'Available', struct());
            for i = 1:numel(names)
                self.Layers.(names{i}) = false;
                if isstruct(avail) && isfield(avail, names{i})
                    self.Available.(names{i}) = logical(avail.(names{i}));
                else
                    % 缺省可用性: 名单里的层没有数据可显 (实测本仓库没有任何实测数据)
                    self.Available.(names{i}) = ~any(strcmp(self.UnavailableWords, names{i}));
                end
                if self.Available.(names{i})
                    self.Notes.(names{i}) = '';
                    self.Layers.(names{i}) = true;
                else
                    self.Notes.(names{i}) = '无实测数据 (NOT_AVAILABLE)';
                end
            end
            self.CommandText = char(string(Theme.optOr(opts, 'CommandText', '')));
            self.SuggestedName = char(string(Theme.optOr(opts, 'ExportName', '')));
            self.buildUi(parent);
            self.refreshUi();
        end

        % ---------- 视角 ----------
        function p = presets(self)
            %PRESETS 视角预设清单 {标签, token}。
            p = self.Presets;
        end

        function setViewPreset(self, token)
            %SETVIEWPRESET 程序设定预设 (不改相机, 只改状态并转发请求)。
            t = lower(strtrim(char(string(token))));
            toks = self.presetTokens();
            k = find(strcmp(toks, t), 1);
            if isempty(k)
                error('tepc:gui:BadViewPreset', ...
                    ['未知视角预设 ' t ' (可用: ' strjoin(toks, ', ') ')']);
            end
            self.ViewPreset = t;
            if ~isempty(self.ViewBox) && isvalid(self.ViewBox)
                self.ViewBox.Value = char(self.Presets{k}{1});
            end
            self.fire('view', self.request());
        end

        function t = viewPreset(self)
            t = self.ViewPreset;
        end

        % ---------- 图层可见性 ----------
        function names = layerNames(self)
            %LAYERNAMES 层顺序 = 构造时定下的 token 序列 (固定顺序, 不随 Children 变)。
            names = self.LayerTokens;
        end

        function labels = layerLabels(self)
            %LABELS 层的显示名: 图标 + 中文 + 英文, 三通道一起给 (不只靠颜色)。
            %   显示名由宿主页通过 opts.Layers 给出; 缺省是谱页的三层口径。
            labels = self.LayerTexts;
        end

        function setLayerVisible(self, layer, tf)
            %SETLAYERVISIBLE 改一层的可见性; 没有数据的层拒绝打开并说明原因。
            name = self.normLayer(layer);
            on = logical(tf);
            if on && ~self.Available.(name)
                self.setStatus([self.layerLabel(name) ' 不可开: ' ...
                    self.Notes.(name)]);
                self.Errors{end+1} = sprintf('%s 层不可见请求被拒绝: %s', ...
                    name, self.Notes.(name)); %#ok<AGROW>
                return;
            end
            self.Layers.(name) = on;
            box = self.layerBox(name);
            if ~isempty(box) && isvalid(box)
                try
                    box.Value = on;
                catch e
                    self.noteError('setLayerVisible', e.message);
                end
            end
            self.fire('layers', self.request());
        end

        function tf = layerVisible(self, layer)
            name = self.normLayer(layer);
            tf = false;
            if isfield(self.Layers, name)
                tf = logical(self.Layers.(name));
            end
        end

        function setLayerAvailable(self, layer, tf, note)
            %SETLAYERAVAILABLE 声明某层有没有数据可显 (实测数据到位后才允许打开)。
            if nargin < 4, note = ''; end
            name = self.normLayer(layer);
            ok = logical(tf);
            self.Available.(name) = ok;
            if ok
                self.Notes.(name) = '';
            else
                self.Layers.(name) = false;
                if isempty(note)
                    self.Notes.(name) = '无可用数据 (NOT_AVAILABLE)';
                else
                    self.Notes.(name) = char(string(note));
                end
            end
            self.refreshUi();
        end

        function tf = layerAvailable(self, layer)
            name = self.normLayer(layer);
            tf = false;
            if isfield(self.Available, name)
                tf = logical(self.Available.(name));
            end
        end

        % ---------- 命令与导出 ----------
        function setCommandText(self, txt)
            %SETCOMMANDTEXT 设"可复现命令"文本 (由应用层用真实 run/config 生成)。
            self.CommandText = strtrim(char(string(txt)));
            self.refreshUi();
        end

        function t = commandText(self)
            t = self.CommandText;
        end

        function copied = copyCommand(self)
            %COPYCOMMAND 有挂载点就交出去; 否则试内建剪贴板, 失败退回显示文本。
            req = self.request();
            req.action = 'copy';
            copied = false;
            if isempty(self.CommandText)
                self.setStatus('暂无可复现命令: 先完成一次校验或运行');
                self.Errors{end+1} = 'copy 请求时命令文本为空'; %#ok<AGROW>
                return;
            end
            if ~isempty(self.OnCopyCommand) && isa(self.OnCopyCommand, 'function_handle')
                try
                    feval(self.OnCopyCommand, req);
                    copied = true;
                    self.setStatus('命令已交给应用层复制');
                catch e
                    self.noteError('OnCopyCommand', e.message);
                end
                self.fire('copy', req);
                return;
            end
            try
                clipboard('copy', self.CommandText);
                copied = true;
                self.setStatus('命令已复制到剪贴板');
            catch e
                self.noteError('clipboard', e.message);
                self.setStatus(['复制到剪贴板失败 (' e.message ...
                    '), 命令文本已在下方, 请手动选抄']);
            end
            self.fire('copy', req);
        end

        function requestExport(self)
            %REQUESTEXPORT 把导出请求 (含建议文件名与当前层/视角) 转给应用层。
            req = self.request();
            req.action = 'export';
            if isempty(req.name)
                req.name = 'tepc_plot';
            end
            self.setStatus(sprintf('导出请求: %s (视角 %s, 可见层 %s)', req.name, ...
                req.view, strjoin(req.visible_layers, '/')));
            self.fire('export', req);
        end

        function setExportName(self, nm)
            self.SuggestedName = strtrim(char(string(nm)));
        end

        function req = request(self)
            %REQUEST 当前工具条状态的结构化快照 (应用层据此改图, 不反过来读控件)。
            req = struct();
            req.view = self.ViewPreset;
            req.layers = self.Layers;
            req.visible_layers = self.visibleLayers();
            req.command = self.CommandText;
            req.name = self.SuggestedName;
            req.action = '';
            req.source = self;
        end

        function s = state(self)
            %STATE 结构化快照, 给回归测试断言。
            s = self.request();
            s.source = [];
            s.action = '';
            s.last_action = self.LastAction;
            s.actions = self.Actions;
            s.errors = self.Errors;
            s.status_text = '';
            if ~isempty(self.StatusLabel) && isvalid(self.StatusLabel)
                try
                    s.status_text = char(string(self.StatusLabel.Text));
                catch
                    s.status_text = '';
                end
            end
            s.view_label = '';
            if ~isempty(self.ViewBox) && isvalid(self.ViewBox)
                try
                    s.view_label = char(string(self.ViewBox.Value));
                catch
                    s.view_label = '';
                end
            end
            s.available = self.Available;
        end

        function delete(self)
            comps = {self.ViewBox, self.CopyButton, self.ExportButton, self.StatusLabel};
            names = self.layerNames();
            for i = 1:numel(names)
                comps{end+1} = self.layerBox(names{i}); %#ok<AGROW>
            end
            comps{end+1} = self.Root;
            for i = 1:numel(comps)
                c = comps{i};
                try
                    if ~isempty(c) && isvalid(c)
                        delete(c);
                    end
                catch
                    % 清理路径不得抛错: 析构里抛错会被吞掉并污染退出码
                end
            end
        end
    end

    methods (Access = private)
        function buildUi(self, parent)
            %BUILDUI 两行: 视角下拉 + 复制/导出按钮 + 每层一个复选框 / 状态回显。
            %   列数随层数走 (宿主可以用 opts.Layers 换层集合), 尾列 '1x' 吸收剩余宽度,
            %   这样前面的 'fit' 列不会被挤扁。行高/列宽只用数字与 'Nx'/'fit'。
            L = Theme.layout('toolbar');
            nLayer = numel(self.layerNames());
            nCol = 3 + nLayer + 1;
            cols = repmat({'fit'}, 1, nCol);
            cols{nCol} = '1x';
            self.Root = uigridlayout(parent);
            self.Root.RowHeight = {Theme.ToolbarH, Theme.HintH};
            self.Root.ColumnWidth = cols;
            self.Root.Padding = L.Padding;
            self.Root.RowSpacing = 2;
            self.Root.ColumnSpacing = L.Spacing(2);

            self.ViewBox = uidropdown(self.Root);
            self.ViewBox.Layout.Row = 1;
            self.ViewBox.Layout.Column = 1;
            self.ViewBox.Items = self.presetLabels();
            self.ViewBox.Value = '复位';
            self.ViewBox.Tooltip = '视角预设名; 相机怎么摆由应用层实现';
            self.ViewBox.ValueChangedFcn = @(~, ~) self.onPresetChosen();

            self.CopyButton = uibutton(self.Root, 'Text', '复制可复现命令');
            self.CopyButton.Layout.Row = 1;
            self.CopyButton.Layout.Column = 2;
            self.CopyButton.ButtonPushedFcn = @(~, ~) self.copyCommand();

            self.ExportButton = uibutton(self.Root, 'Text', '导出图');
            self.ExportButton.Layout.Row = 1;
            self.ExportButton.Layout.Column = 3;
            self.ExportButton.ButtonPushedFcn = @(~, ~) self.requestExport();

            names = self.layerNames();
            labels = self.layerLabels();
            for i = 1:numel(names)
                box = uicheckbox(self.Root);
                box.Layout.Row = 1;
                % 列 4..6 放三个层开关, 第 7 列留给状态回显
                box.Layout.Column = 3 + i;
                box.Value = self.Layers.(names{i});
                box.FontName = Theme.FontFamily;
                box.FontSize = Theme.FontMicro;
                box.Tag = ['layer:' names{i}];
                box.ValueChangedFcn = @(obj, ~) self.onLayerChosen(obj);
                self.LayerBoxes.(names{i}) = box;
                box.Text = labels{i}{2};
                box.FontColor = labels{i}{3};
            end

            self.StatusLabel = uilabel(self.Root);
            self.StatusLabel.Layout.Row = 2;
            self.StatusLabel.Layout.Column = [1, 7];
            self.StatusLabel.FontName = Theme.FontFamily;
            self.StatusLabel.FontSize = Theme.FontMicro;
            self.StatusLabel.FontColor = Theme.ColorMuted;
            self.StatusLabel.HorizontalAlignment = 'left';
            self.StatusLabel.Text = '工具条就绪';
        end

        function onPresetChosen(self)
            try
                lbl = char(string(self.ViewBox.Value));
            catch e
                self.noteError('onPresetChosen', e.message);
                return;
            end
            labs = self.presetLabels();
            toks = self.presetTokens();
            k = find(strcmp(labs, lbl), 1);
            if isempty(k)
                self.noteError('onPresetChosen', ['下拉值 ' lbl ' 不在预设清单里']);
                return;
            end
            self.ViewPreset = toks{k};
            self.fire('view', self.request());
        end

        function onLayerChosen(self, box)
            %ONLAYERCHOSEN 复选框 -> 层名靠 Tag 反查, 不靠 Children 顺序。
            name = '';
            try
                tg = char(string(box.Tag));
            catch
                tg = '';
            end
            if numel(tg) > 6 && strcmp(tg(1:6), 'layer:')
                name = tg(7:end);
            end
            if isempty(name)
                self.noteError('onLayerChosen', '复选框 Tag 不含层名, 无法定位是哪一层');
                return;
            end
            try
                v = logical(box.Value);
            catch
                v = false;
            end
            self.setLayerVisible(name, v);
        end

        function fire(self, action, req)
            %FIRE 记录动作并调用对应挂载点; 没有挂载点时只记状态, 不猜测行为。
            self.LastAction = action;
            self.Actions{end+1} = action; %#ok<AGROW>
            switch action
                case 'view',    fn = self.OnViewPreset;
                case 'copy',    fn = [];
                case 'export',  fn = self.OnExport;
                otherwise,      fn = self.OnLayers;
            end
            if isempty(fn) || ~isa(fn, 'function_handle')
                return;
            end
            try
                feval(fn, req);
            catch e
                self.noteError(action, e.message);
            end
        end

        function setStatus(self, txt)
            self.setStatusText(char(string(txt)));
        end

        function setStatusText(self, txt)
            %SETSTATUSTEXT 回显写进属性与控件两处 (同 StatusChip 的纪律)。
            self.StatusText = txt;
            if isempty(self.StatusLabel) || ~isvalid(self.StatusLabel)
                return;
            end
            try
                self.StatusLabel.Text = txt;
            catch e
                self.noteError('setStatus', e.message);
            end
        end

        function name = normLayer(self, layer)
            name = lower(strtrim(char(string(layer))));
            names = self.layerNames();
            if ~any(strcmp(names, name))
                error('tepc:gui:BadLayer', ...
                    ['未知图层 ' name ' (可用: ' strjoin(names, ', ') ')']);
            end
        end

        function lbl = layerLabel(self, name)
            labels = self.layerLabels();
            lbl = name;
            for i = 1:numel(labels)
                if strcmp(labels{i}{1}, name)
                    lbl = labels{i}{2};
                    return;
                end
            end
        end

        function box = layerBox(self, name)
            box = [];
            if isfield(self.LayerBoxes, name)
                box = self.LayerBoxes.(name);
            end
        end

        function vis = visibleLayers(self)
            vis = {};
            names = self.layerNames();
            for i = 1:numel(names)
                if self.Layers.(names{i})
                    vis{end+1} = names{i}; %#ok<AGROW>
                end
            end
        end

        function labs = presetLabels(self)
            labs = cell(1, numel(self.Presets));
            for i = 1:numel(self.Presets)
                labs{i} = char(string(self.Presets{i}{1}));
            end
        end

        function toks = presetTokens(self)
            toks = cell(1, numel(self.Presets));
            for i = 1:numel(self.Presets)
                toks{i} = char(string(self.Presets{i}{2}));
            end
        end

        function refreshUi(self)
            %REFRESHUI 把可用性/文本刷回控件: 不可用的层禁用复选框并写明原因,
            %   这样"三条曲线"不会有一条其实是假的。
            names = self.layerNames();
            labels = self.layerLabels();
            for i = 1:numel(names)
                box = self.layerBox(names{i});
                if isempty(box) || ~isvalid(box)
                    continue;
                end
                ok = self.Available.(names{i});
                try
                    box.Enable = PlotToolbar.onOff(ok);
                    box.Value = logical(self.Layers.(names{i}));
                    if ok
                        box.Text = labels{i}{2};
                        box.Tooltip = '切换该层可见性';
                    else
                        % 不可用的层禁用复选框并把原因写进文本: 三层里有一层是假的
                        % 时必须看得出来, 否则就是把缺位画成了正常曲线。
                        box.Text = [labels{i}{2}, ' (', self.Notes.(names{i}), ')'];
                        box.Tooltip = self.Notes.(names{i});
                    end
                catch e
                    self.noteError('refreshUi', e.message);
                end
            end
            if ~isempty(self.ViewBox) && isvalid(self.ViewBox)
                try
                    self.ViewBox.Value = self.layerFreeViewLabel();
                catch e
                    self.noteError('refreshUi', e.message);
                end
            end
        end

        function lbl = layerFreeViewLabel(self)
            %LAYERFREEVIEWLABEL 当前预设对应的下拉文本 (找不到就回落到复位)。
            toks = self.presetTokens();
            labs = self.presetLabels();
            k = find(strcmp(toks, self.ViewPreset), 1);
            if isempty(k)
                lbl = labs{end};
            else
                lbl = labs{k};
            end
        end

        function noteError(self, where, msg)
            self.Errors{end+1} = sprintf('%s: %s', where, char(string(msg))); %#ok<AGROW>
        end
    end

    methods (Static)
        function t = onOff(on)
            if logical(on), t = 'on'; else, t = 'off'; end
        end

        function L = defaultLayers()
            %DEFAULTLAYERS 缺省三层: 真值 / 仪器 / 实验 (谱页的口径)。
            L = {{'truth', '● 真值 Truth', Theme.ColorInk}, ...
                {'instrument', '▲ 仪器 Instrument', Theme.ColorAccent}, ...
                {'experiment', '■ 实验 Experiment', Theme.ColorWarn}};
        end

        function L = asLayers(lay)
            %ASLAYERS 归一 opts.Layers -> {token, 显示名, 颜色} 三列元胞。
            if ~iscell(lay) || isempty(lay)
                error('tepc:gui:BadLayers', 'Layers 必须是 {{token,显示名,颜色}, ...} 元胞表');
            end
            if iscell(lay{1})
                rows = lay;
            else
                % 单行 {token,显示名,颜色} 也会被接住, 免得宿主多写一层元胞就报错
                rows = {lay};
            end
            L = cell(1, numel(rows));
            for i = 1:numel(rows)
                r = rows{i};
                if ~iscell(r) || numel(r) < 2
                    error('tepc:gui:BadLayers', ...
                        '第 %d 个层描述至少要给 token 与显示名', i);
                end
                one = {char(string(r{1})), char(string(r{2})), Theme.ColorInk};
                if numel(r) >= 3 && isnumeric(r{3}) && numel(r{3}) == 3
                    one{3} = double(r{3}(:)');
                end
                L{i} = one;
            end
        end
    end
end
