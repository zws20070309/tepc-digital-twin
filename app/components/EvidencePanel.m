classdef EvidencePanel < handle
    %EVIDENCEPANEL 能力登记表驱动的证据面板。
    %
    % 措辞纪律: 本面板显示的每一句定位话术都从 config/capability_register.json 的
    %   allowed_phrases / reason / title / note 字段取, 类里不写任何一句自造的定位句子。
    %   表里没有可声称措辞 (allowed_phrases 为空) 时, 显示的就是"无可用措辞"这个事实,
    %   而不是挑一句看着相近的话填上 —— 那正是登记表要消除的失效模式。
    %
    % 分组与筛选: 按 status 分组 (DONE / PARTIAL / BLOCKED / EXCLUDED, 表内词表),
    %   另支持四种筛选。注意 ASSUMED 不是登记表的状态词, 所以"只看 ASSUMED"是
    %   **按表内文本命中** (title/reason/allowed_phrases 里出现该词) 来筛,
    %   面板上也是这么写的, 不把它伪装成一个状态分组。
    %
    % 读表方式与生成定位文档的那条路径一致: 按字节 fopen(...,'n','UTF-8') 再
    %   native2unicode 后 jsondecode。fileread 会按系统字符集解码, 中文说明会变成乱码,
    %   同一份表被两种编码读出来必然分叉。
    %
    % 布局: uitable 的 ColumnWidth 用数字与 '1x' (本机没有 'auto'), 折叠/展开由
    %   父网格行高控制, 与 ParameterCard 同一套做法。

    properties (SetAccess = private)
        Root = []           % 面板自己的 uigridlayout
        FilterBox = []      % uidropdown: 筛选
        Table = []          % uitable: 分组后的条目
        DetailBox = []      % uitextarea: 选中条目的表内原文
        LineBox = []        % uilabel: 计数与加载状态一行
        Path = ''           % 登记表绝对路径
        Register = []       % 解析后的表 (struct)
        Entries = []        % 条目数组
        LoadError = ''      % 读表失败原因 (空表示成功)
        Loaded = false
        Filter = 'all'
        SelectedId = ''
        RowKeys = {}        % 与表格行一一对应: 条目 id, 组标题行为 ''
        RowCount = 0
        Counts = []         % 各状态计数
        Errors = {}
    end

    methods
        function self = EvidencePanel(parent, opts)
            %EVIDENCEPANEL(parent, opts) 建面板。opts: Root/Filter/AutoLoad。
            %   本构造函数只有两个入参, 缺省判据必须是 nargin<2: 写成 nargin<3 会把
            %   调用方传进来的 opts 整个丢掉, Root/Filter/AutoLoad 全部静默失效。
            if nargin < 2, opts = struct(); end
            if isempty(parent)
                error('tepc:gui:NoParent', 'EvidencePanel 需要一个父容器');
            end
            self.Filter = EvidencePanel.normMode(Theme.optOr(opts, 'Filter', 'all'));
            self.buildUi(parent);
            root = Theme.optOr(opts, 'Root', '');
            if Theme.optOr(opts, 'AutoLoad', true)
                self.loadRegister(root);
            end
        end

        % ---------- 读表 ----------
        function ok = loadRegister(self, root)
            %LOADREGISTER 读登记表并刷新。失败时把 NOT_AVAILABLE 明明白白显示出来:
            %   空面板会被读成"没有受阻项", 那比报错危险得多。
            %   方法名不叫 load: 那是内建函数, 同名只会在调试时制造歧义。
            if nargin < 2, root = ''; end
            self.LoadError = '';
            self.Loaded = false;
            try
                dir0 = self.resolveRoot(root);
                self.Path = fullfile(dir0, 'config', 'capability_register.json');
                if ~isfile(self.Path)
                    error('tepc:config:NoRegister', '缺 %s', self.Path);
                end
                txt = EvidencePanel.readUtf8(self.Path);
                J = jsondecode(txt);
                if ~isstruct(J) || ~isfield(J, 'entries')
                    error('tepc:config:BadRegister', '登记表里没有 entries 字段: %s', self.Path);
                end
                self.Register = J;
                self.Entries = J.entries;
                self.Loaded = true;
            catch e
                self.LoadError = sprintf('[%s] %s', e.identifier, e.message);
                % 读表失败必须同时进 Errors: 只写 LoadError 的话, state()/snapshot()
                % 里的 errors 恒空, "面板知道自己坏了"这件事对上层不可见。
                self.noteError('loadRegister', self.LoadError);
                self.Register = [];
                self.Entries = [];
            end
            self.Counts = self.counts();
            self.refresh();
            ok = self.Loaded;
        end

        function reload(self)
            self.loadRegister(self.rootOfPath());
        end

        function d = rootOfPath(self)
            %ROOTOFPATH 从登记表路径反推仓库根 (未加载时给当前目录)。
            if ~isempty(self.Path) && isfile(self.Path)
                d = fileparts(fileparts(fileparts(self.Path)));
            else
                d = pwd();
            end
        end

        function ok = isLoaded(self)
            ok = self.Loaded;
        end

        function n = counts(self)
            %COUNTS 各状态计数 (含一个表内没有的 DONE=0 槽位, 缺位必须看得见)。
            n = struct('DONE', 0, 'PARTIAL', 0, 'BLOCKED', 0, 'EXCLUDED', 0, 'total', 0);
            for i = 1:numel(self.Entries)
                st = EvidencePanel.entryField(self.Entries(i), 'status');
                if isfield(n, st) && ~isempty(st)
                    n.(st) = n.(st) + 1;
                end
            end
            n.total = numel(self.Entries);
        end

        function ids = visibleIds(self)
            %VISIBLEIDS 当前筛选下命中的条目 id (顺序与分组顺序一致)。
            ids = {};
            for i = 1:numel(self.Entries)
                if self.matches(self.Entries(i))
                    ids{end+1} = EvidencePanel.entryField(self.Entries(i), 'id'); %#ok<AGROW>
                end
            end
        end

        function ph = phrases(self, id)
            %PHRASES 某条目的表内允许措辞 (allowed_phrases), 一字不改。
            ph = {};
            e = self.entryById(id);
            if isempty(e), return; end
            ph = EvidencePanel.toStringCell(e, 'allowed_phrases');
        end

        function why = reason(self, id)
            %REASON 某条目的表内 reason 原文 (没有就返回空串, 不编造)。
            e = self.entryById(id);
            why = '';
            if ~isempty(e)
                why = EvidencePanel.entryField(e, 'reason');
            end
        end

        function claim = claimableText(self)
            %CLAIMABLETEXT "可以声称"一节: 只取 status=DONE 条目的 allowed_phrases。
            %   DONE 为空时退回登记表自己的 note 字段原文 —— 表说什么就显示什么,
            %   本类不加一句自己的判断。
            claim = {};
            for i = 1:numel(self.Entries)
                e = self.Entries(i);
                if strcmp(EvidencePanel.entryField(e, 'status'), 'DONE')
                    p = EvidencePanel.toStringCell(e, 'allowed_phrases');
                    for j = 1:numel(p)
                        claim{end+1} = p{j}; %#ok<AGROW>
                    end
                end
            end
            if ~isempty(claim), return; end
            note = EvidencePanel.regField(self.Register, 'note');
            if ~isempty(note)
                claim = {note};
            else
                claim = {'登记表没有 note 字段, 也没有任何 DONE 条目可供声称'};
            end
        end

        function blocked = blockers(self)
            %BLOCKERS 未达可声称状态的条目 (DONE 以外全部), 即"未关闭项"的清单来源。
            %   面板只列条目与表内原因, 不对"能不能发布"下结论: 结论属于门禁层。
            blocked = {};
            for i = 1:numel(self.Entries)
                e = self.Entries(i);
                if ~strcmp(EvidencePanel.entryField(e, 'status'), 'DONE')
                    one = struct();
                    one.id = EvidencePanel.entryField(e, 'id');
                    one.status = EvidencePanel.entryField(e, 'status');
                    one.gate_layer = EvidencePanel.entryField(e, 'gate_layer');
                    one.reason = EvidencePanel.entryField(e, 'reason');
                    blocked{end+1} = one; %#ok<AGROW>
                end
            end
        end

        function n = openBlockerCount(self)
            %OPENBLOCKERCOUNT 未关闭条目数 (状态带的"未关闭阻塞项"取数处之一)。
            %   表读不到时返回 [] 而不是 0: 0 会被读成"干净"。
            if ~self.Loaded
                n = [];
            else
                n = numel(self.blockers());
            end
        end

        % ---------- 筛选 ----------
        function setFilter(self, mode)
            self.Filter = EvidencePanel.normMode(mode);
            self.refresh();
        end

        function modes = filterModes()
            modes = EvidencePanel.modeTokens();
        end

        function tf = matchesFilterMode(self, id, mode)
            %MATCHESFILTERMODE 单条判定 (给测试与外部复用)。
            e = self.entryById(id);
            if isempty(e)
                tf = false;
                return;
            end
            tf = self.matches(e, mode);
        end

        % ---------- 选择与刷新 ----------
        function selectId(self, id)
            self.SelectedId = EvidencePanel.cleanStr(id);
            self.showDetail();
        end

        function id = selectedId(self)
            id = self.SelectedId;
        end

        function refresh(self)
            %REFRESH 重建表格数据 (分组 + 组内按表原序), 并把计数写进状态行。
            [data, keys] = self.tableData();
            self.RowCount = size(data, 1);
            self.RowKeys = keys;
            if ~isempty(self.Table) && isvalid(self.Table)
                try
                    self.Table.Data = data;
                catch e
                    self.noteError('refresh', e.message);
                end
            end
            if isempty(self.SelectedId) && ~isempty(keys)
                for i = 1:numel(keys)
                    if ~isempty(keys{i})
                        self.SelectedId = keys{i};
                        break;
                    end
                end
            end
            if ~isempty(self.LineBox) && isvalid(self.LineBox)
                self.LineBox.Text = self.countLine();
            end
            self.showDetail();
        end

        function [data, keys] = tableData(self)
            %TABLEDATA 分组后的表格数据: 每组一行组标题, 下面列条目。
            %   第四列只放表内原文: 有 allowed_phrases 就逐条列出, 没有就写
            %   表内 reason; 两者都没有时写"表内无措辞无原因", 空着会被读成"没问题"。
            data = {};
            keys = {};
            groups = {'DONE', 'PARTIAL', 'BLOCKED', 'EXCLUDED'};
            for g = 1:numel(groups)
                rows = self.groupRows(groups{g});
                if isempty(rows)
                    continue;
                end
                one = Theme.tripletFor(groups{g});
                head = {[], [one.glyph, ' ', groups{g}, ' ', one.label], ...
                    sprintf('%d 条', numel(rows)), []};
                % 0x0 元胞上做 data(end+1,:) 赋值要靠隐式扩容, 纵向拼接更直白
                data = [data; head]; %#ok<AGROW>
                keys{end+1} = ''; %#ok<AGROW>
                for k = 1:numel(rows)
                    e = self.Entries(rows(k));
                    id = EvidencePanel.entryField(e, 'id');
                    ttl = EvidencePanel.entryField(e, 'title');
                    ph = EvidencePanel.toStringCell(e, 'allowed_phrases');
                    if ~isempty(ph)
                        txt = strjoin(ph, '; ');
                    else
                        why = EvidencePanel.entryField(e, 'reason');
                        if isempty(why)
                            txt = '表内既无允许措辞也无原因';
                        else
                            txt = ['缺位说明: ' why];
                        end
                    end
                    data = [data; {id, one.label, ttl, txt}]; %#ok<AGROW>
                    keys{end+1} = id; %#ok<AGROW>
                end
            end
            if isempty(data)
                data = {'表内无命中条目', '', '当前筛选下一条都没有', ''};
                keys = {''};
            end
        end

        function s = state(self)
            %STATE 结构化快照 (纯数据): 测试读它而不是读像素。
            s = struct();
            s.path = self.Path;
            s.loaded = self.Loaded;
            s.load_error = self.LoadError;
            s.filter = self.Filter;
            s.n_entries = numel(self.Entries);
            s.counts = self.counts();
            s.visible = self.visibleIds();
            s.selected = self.SelectedId;
            s.n_rows = self.RowCount;
            s.claimable = self.claimableText();
            s.open_blockers = self.openBlockerCount();
            s.line_text = '';
            if ~isempty(self.LineBox) && isvalid(self.LineBox)
                try
                    s.line_text = char(string(self.LineBox.Text));
                catch
                    s.line_text = '';
                end
            end
            s.errors = self.Errors;
        end

        function delete(self)
            comps = {self.FilterBox, self.Table, self.DetailBox, self.LineBox, self.Root};
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
            %BUILDUI 四行: 状态行 / 筛选行 / 条目表 / 表内原文。
            L = Theme.layout('table');
            self.Root = uigridlayout(parent);
            self.Root.RowHeight = {'fit', Theme.ControlH, '1x', Theme.FontBody*6};
            self.Root.ColumnWidth = L.ColumnWidth;
            self.Root.Padding = L.Padding;
            self.Root.RowSpacing = L.Spacing(1);
            self.Root.ColumnSpacing = L.Spacing(2);

            self.LineBox = uilabel(self.Root);
            self.LineBox.Layout.Row = 1;
            self.LineBox.Layout.Column = 1;
            self.LineBox.FontName = Theme.FontFamily;
            self.LineBox.FontSize = Theme.FontBody;
            self.LineBox.FontColor = Theme.ColorInk;
            self.LineBox.HorizontalAlignment = 'left';
            self.LineBox.Text = '能力登记表: 未加载';

            self.FilterBox = uidropdown(self.Root);
            self.FilterBox.Layout.Row = 2;
            self.FilterBox.Layout.Column = 1;
            self.FilterBox.FontName = Theme.FontFamily;
            self.FilterBox.FontSize = Theme.FontBody;
            self.FilterBox.Items = EvidencePanel.filterLabels();
            self.FilterBox.Value = EvidencePanel.labelOf(self.Filter);
            self.FilterBox.ValueChangedFcn = @(~, ~) self.onFilterChanged();

            self.Table = uitable(self.Root);
            self.Table.Layout.Row = 3;
            self.Table.Layout.Column = 1;
            self.Table.ColumnName = {'条目', '状态', '标题', '表内措辞 / 缺位说明'};
            self.Table.ColumnWidth = {90, 110, 230, '1x'};
            self.Table.FontName = Theme.FontFamily;
            self.Table.FontSize = Theme.FontMicro;
            self.Table.Data = {};
            % 本机 uitable 的选择回调叫 CellSelectionCallback (R2025a 实测
            % isprop(Table,'CellSelectionChangedFcn')=0, 赋上去直接抛
            % noPublicFieldForClass, 整个面板因此建不起来)。
            self.Table.CellSelectionCallback = @(~, ~) self.onRowChosen();

            self.DetailBox = uitextarea(self.Root);
            self.DetailBox.Layout.Row = 4;
            self.DetailBox.Layout.Column = 1;
            self.DetailBox.Editable = false;
            self.DetailBox.FontName = Theme.FontFamily;
            self.DetailBox.FontSize = Theme.FontMicro;
            self.DetailBox.Value = {'选中一行后看表内原文'};
        end

        function onFilterChanged(self)
            want = EvidencePanel.normMode(self.FilterBox.Value);
            self.Filter = want;
            self.refresh();
        end

        function onRowChosen(self)
            %ONROWCHOSEN 表里点一行 -> 显示该条目的表内原文; 组标题行不清选择。
            try
                sel = self.Table.CellSelection;
            catch e
                self.noteError('CellSelection', e.message);
                return;
            end
            if isempty(sel) || numel(sel) < 2, return; end
            r = sel(1);
            if r < 1 || r > numel(self.RowKeys), return; end
            key = self.RowKeys{r};
            if isempty(key)
                return;
            end
            self.SelectedId = key;
            self.showDetail();
        end

        function showDetail(self)
            %SHOWDETAIL 原文面板: 只贴表里的字段, 一行都不自己写。
            lines = {};
            if ~self.Loaded
                if isempty(self.LoadError)
                    self.DetailBox.Value = {'登记表未加载 (NOT_AVAILABLE)'};
                else
                    msgLine = ['登记表未加载 (NOT_AVAILABLE): ' self.LoadError];
                    self.DetailBox.Value = {msgLine};
                end
                return;
            end
            lines{end+1} = sprintf('登记表 schema: %s | 生成日: %s | 条目 %d', ...
                EvidencePanel.regField(self.Register, 'schema'), ...
                EvidencePanel.regField(self.Register, 'generated'), ...
                numel(self.Entries));
            lines{end+1} = EvidencePanel.regField(self.Register, 'purpose');
            e = self.entryById(self.SelectedId);
            if isempty(e)
                lines{end+1} = '当前筛选下没有选中条目';
            else
                st = EvidencePanel.entryField(e, 'status');
                one = Theme.tripletFor(st);
                lines{end+1} = sprintf('%s | %s %s | 门禁层级 %s | 需要: %s', ...
                    EvidencePanel.entryField(e, 'id'), one.glyph, ...
                    [st, ' ', one.label], EvidencePanel.entryField(e, 'gate_layer'), ...
                    strjoin(EvidencePanel.toStringCell(e, 'requires'), ', '));
                lines{end+1} = ['标题: ' EvidencePanel.entryField(e, 'title')];
                ph = EvidencePanel.toStringCell(e, 'allowed_phrases');
                if isempty(ph)
                    lines{end+1} = '允许措辞: 表内为空 (无可声称表述)';
                else
                    for j = 1:numel(ph)
                        lines{end+1} = sprintf('允许措辞 %d: %s', j, ph{j}); %#ok<AGROW>
                    end
                end
                why = EvidencePanel.entryField(e, 'reason');
                if ~isempty(why)
                    lines{end+1} = ['原因: ' why];
                end
                ev = EvidencePanel.entryField(e, 'forbidden_phrases_ref');
                if ~isempty(ev)
                    lines{end+1} = ['禁语清单指针: ' ev];
                end
                lines{end+1} = sprintf('证据 %d 项: %s', numel(self.evidenceOf(e)), ...
                    strjoin(self.evidenceOf(e), ' | '));
            end
            if isfield(self.Counts, 'total') && isstruct(self.Counts)
                lines{end+1} = self.countLine();
            end
            if ~isempty(self.LoadError)
                lines{end+1} = ['最近一次读表失败: ' self.LoadError];
            end
            self.DetailBox.Value = lines(:)';
        end

        function ev = evidenceOf(self, e)
            %EVIDENCEOF 条目证据路径 (表内 evidence 数组的 path/kind), 原样列出。
            ev = {};
            if ~isstruct(e) || ~isfield(e, 'evidence')
                return;
            end
            v = e.evidence;
            if isempty(v) || ~isstruct(v)
                return;
            end
            for i = 1:numel(v)
                p = EvidencePanel.entryField(v(i), 'path');
                k = EvidencePanel.entryField(v(i), 'kind');
                if isempty(p) && isempty(k), continue; end
                ev{end+1} = sprintf('%s (%s)', p, k); %#ok<AGROW>
            end
        end

        function e = entryById(self, id)
            e = [];
            want = EvidencePanel.cleanStr(id);
            if isempty(want), return; end
            for i = 1:numel(self.Entries)
                if strcmp(EvidencePanel.entryField(self.Entries(i), 'id'), want)
                    e = self.Entries(i);
                    return;
                end
            end
        end

        function rows = groupRows(self, group)
            %GROUPROWS 某状态组在当前筛选下命中的条目下标 (保持表内原序)。
            rows = [];
            for i = 1:numel(self.Entries)
                e = self.Entries(i);
                if strcmp(EvidencePanel.entryField(e, 'status'), group) && self.matches(e)
                    rows(end+1) = i; %#ok<AGROW>
                end
            end
        end

        function tf = matches(self, e, mode)
            %MATCHES 筛选判定。
            %   assumed 是**文本命中**: 登记表的状态词表里没有 ASSUMED, 所以它不是
            %   一个状态分组, 只是把表内写到 ASSUMED 的条目挑出来。
            if nargin < 3, mode = self.Filter; end
            st = EvidencePanel.entryField(e, 'status');
            switch mode
                case 'all'
                    tf = true;
                case 'blocked'
                    tf = strcmp(st, 'BLOCKED');
                case 'assumed'
                    tf = EvidencePanel.mentions(e, 'ASSUMED');
                case 'no_phrase'
                    tf = isempty(EvidencePanel.toStringCell(e, 'allowed_phrases'));
                otherwise
                    tf = true;
            end
        end

        function s = countLine(self)
            %COUNTLINE 计数一行: 四态 + 未关闭数 + 读表状态, 缺位也照样列出。
            c = self.counts();
            s = sprintf(['登记表 DONE %d / PARTIAL %d / BLOCKED %d / EXCLUDED %d ' ...
                '(共 %d) | 筛选 %s | 未关闭 %s | 读表 %s'], ...
                c.DONE, c.PARTIAL, c.BLOCKED, c.EXCLUDED, c.total, ...
                EvidencePanel.labelOf(self.Filter), ...
                EvidencePanel.numOrNA(self.openBlockerCount()), ...
                EvidencePanel.loadWord(self.Loaded, self.LoadError));
        end

        function noteError(self, where, msg)
            self.Errors{end+1} = sprintf('%s: %s', where, char(string(msg))); %#ok<AGROW>
        end

        function d = resolveRoot(self, root)
            %RESOLVEROOT 仓库根: 显式入参 -> tepc.io.projectRoot -> 本文件上溯两级。
            %   服务层不在路径上时也能定位到表, 面板是纯展示件, 不该依赖物理层在位。
            d = char(string(root));
            if ~isempty(d) && isfolder(d), return; end
            try
                d = tepc.io.projectRoot();
                if isfolder(d), return; end
            catch
                % 回落到按文件位置反推, 不静默当成成功
            end
            here = mfilename('fullpath');
            if ~isempty(here)
                d = fileparts(fileparts(fileparts(here)));
            else
                d = pwd();
            end
            if ~isfolder(d)
                d = pwd();
            end
        end
    end

    methods (Static, Access = private)
        function txt = readUtf8(path)
            %READUTF8 按字节读 + 显式 UTF-8 解码 (与生成定位文档的那条路径一致)。
            %   fread 给的是**列**向量, 必须先转成行向量再解码: 本机 native2unicode
            %   对列向量返回按行切开的结果, string() 之后就成了字符串数组,
            %   jsondecode 随即报 MATLAB:json:InvalidInput (实测)。
            %   BOM 也要剥: 带 BOM 时 jsondecode 的第一个字符就不是 '{'。
            fid = fopen(path, 'r', 'n', 'UTF-8');
            if fid < 0
                error('tepc:io:ReadFailed', '打不开登记表: %s', path);
            end
            raw = fread(fid, inf, 'uint8=>uint8');
            fclose(fid);
            % fread 给的是**列**向量, 而 [239 187 191] 写成行会让 == 广播成 3x3 逻辑阵,
            % all(...) 随之返回 1x3, 交给 && 就抛 MATLAB:nonLogicalConditional ——
            % 整张能力登记表因此读不进来。BOM 与被比对的切片都按列给, 用 isequal 收成标量。
            bom = uint8([239; 187; 191]);
            if numel(raw) >= 3 && isequal(raw(1:3), bom)
                raw = raw(4:end);
            end
            txt = string(native2unicode(raw(:)', 'UTF-8'));
        end

        function toks = modeTokens()
            toks = {'all', 'assumed', 'blocked', 'no_phrase'};
        end

        function labs = filterLabels()
            %FILTERLABELS 下拉项文本; 与 modeTokens 一一对应, 顺序不能动。
            labs = {'全部条目', ...
                '只看表内提到 ASSUMED 的条目', ...
                '只看 BLOCKED', ...
                '只看无可用措辞的条目'};
        end

        function m = normMode(m0)
            %NORMMODE 筛选模式入参归一。三类写法都收: 内部 token、下拉项原文、
            %   表内印的 Theme 状态显示词 (表格里 BLOCKED 显示成"受阻", 读表回来的
            %   显示词必须能筛同一批条目); 其余一律具名拒绝, 不退化成 all。
            s = lower(strtrim(char(string(m0))));
            toks = EvidencePanel.modeTokens();
            if any(strcmp(toks, s))
                m = s;
                return;
            end
            labs = EvidencePanel.filterLabels();
            raw = strtrim(char(string(m0)));
            for i = 1:numel(labs)
                if strcmp(labs{i}, raw)
                    m = toks{i};
                    return;
                end
            end
            want = {'assumed', 'blocked', 'no_phrase'};
            stat = {'ASSUMED', 'BLOCKED', 'NOT_AVAILABLE'};
            T = Theme.statusTable();
            for i = 1:numel(want)
                if isfield(T, stat{i}) && ...
                        strcmp(char(string(T.(stat{i}).label)), raw)
                    m = want{i};
                    return;
                end
            end
            error('tepc:gui:BadFilterMode', ...
                ['未知筛选模式 ' s ' (可用: all/assumed/blocked/no_phrase)']);
        end

        function lab = labelOf(m)
            toks = EvidencePanel.modeTokens();
            labs = EvidencePanel.filterLabels();
            k = find(strcmp(toks, m), 1);
            if isempty(k)
                lab = labs{1};
            else
                lab = labs{k};
            end
        end

        function s = cleanStr(x)
            if isempty(x)
                s = '';
            else
                s = strtrim(char(string(x)));
            end
        end

        function s = entryField(e, f)
            %ENTRYFIELD 取条目里的一个字段并收成文本 (数字也收成文本)。
            s = '';
            if ~isstruct(e) || ~isfield(e, f) || isempty(e.(f))
                return;
            end
            x = e.(f);
            if iscell(x)
                if isempty(x), return; end
                x = x{1};
            end
            if isstruct(x)
                if isfield(x, 'id')
                    s = char(string(x.id));
                else
                    s = class(x);
                end
            elseif isnumeric(x)
                s = num2str(double(x(1)), '%.10g');
            elseif ischar(x) || isstring(x)
                s = char(string(x));
            end
        end

        function s = regField(J, f)
            s = '';
            if isstruct(J) && isfield(J, f) && ~isempty(J.(f))
                s = char(string(J.(f)));
            end
        end

        function c = toStringCell(e, f)
            %TOSTRINGCELL JSON 字符串数组 -> 元胞。jsondecode 对单元素数组给 char,
            %   对多元素给 cell, 空数组给空 cell, 三种都要接住。
            c = {};
            if ~isstruct(e) || ~isfield(e, f) || isempty(e.(f))
                return;
            end
            x = e.(f);
            if iscell(x)
                c = cell(1, numel(x));
                for i = 1:numel(x)
                    if isempty(x{i})
                        c{i} = '';
                    else
                        c{i} = char(string(x{i}));
                    end
                end
            elseif isstruct(x)
                c = {class(x)};
            elseif isnumeric(x)
                c = {num2str(double(x(1)), '%.10g')};
            else
                c = {char(string(x))};
            end
        end

        function tf = mentions(e, word)
            %MENTIONS 条目的表内文本 (标题/原因/措辞/需要的数据) 里是否出现某词。
            %   逐项拼进 parts 而不是用 {a{:}} 展开: 那会把内层元胞嵌进外层,
            %   后面的 ischar 判定就会整批漏掉。
            tf = false;
            if ~isstruct(e), return; end
            parts = {EvidencePanel.entryField(e, 'title'), ...
                EvidencePanel.entryField(e, 'reason')};
            bags = {EvidencePanel.toStringCell(e, 'allowed_phrases'), ...
                EvidencePanel.toStringCell(e, 'requires')};
            for b = 1:numel(bags)
                for j = 1:numel(bags{b})
                    parts{end+1} = bags{b}{j}; %#ok<AGROW>
                end
            end
            w = upper(word);
            for i = 1:numel(parts)
                if isempty(parts{i}), continue; end
                if ~ischar(parts{i}) && ~isstring(parts{i}), continue; end
                if contains(upper(char(string(parts{i}))), w)
                    tf = true;
                    return;
                end
            end
        end

        function s = numOrNA(x)
            if isempty(x)
                s = '不可得';
            else
                s = sprintf('%d', round(double(x)));
            end
        end

        function s = loadWord(ok, err)
            %LOADWORD 读表状态: 失败时带原因, 空原因也不写"成功"以外的含糊话。
            if ok && isempty(err)
                s = '正常';
            elseif ok
                s = ['已加载但上次失败: ' err];
            else
                s = ['NOT_AVAILABLE: ' err];
            end
        end
    end
end
