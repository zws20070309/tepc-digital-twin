classdef StatusChip < handle
    %STATUSCHIP 顶部状态带里的小胶囊: 模式 / 后端 / 配置哈希短码 / 位点请求与实现 /
    %   未关闭阻塞项计数 / 是否允许发布。
    %
    % 一条硬约定: Chip.Text 与 Chip.Label.Text 必须**同时**由 setText 写入。
    %   只声明属性而不在写控件的那一处赋值, 属性会永远停在空串, 读它的测试与
    %   禁语扫描会静默地"扫得很干净"地放行一切。Text 是显示文本的镜像,
    %   Plain 是同一文本去掉图标字符的版本 (两个都在每次 setText 时重算)。
    %
    % 状态仍走 Theme 的三通道 (颜色 + 图标 + 文字): 状态带是全窗口最关键的一行,
    %   只用颜色区分等于把最重要的判断交给最容易失效的通道。
    %
    % 未取数的胶囊一律显式显示"未取数", 不显示空串也不显示 0:
    %   空与 0 都会被读成"这项没问题"。

    properties (SetAccess = private)
        Key = ''          % 胶囊名, 例如 位点 / 后端
        Value = ''        % 值文本 (setText 写的那个)
        Text = ''         % 完整显示文本 (图标 + 名字 + 值); 与 Label.Text 同步
        Plain = ''        % 去掉图标的同一文本
        Status = ''       % 三通道状态词 (Theme 里的词表)
        Label = []        % uilabel
        Clicks = 0        % 点击计数 (可点胶囊的诊断通道)
        Errors = {}       % 写控件失败的记录 (不静默)
    end

    properties
        OnClick = []      % @(evt) 挂载点; 胶囊只做转发, 不实现任何行为
        ShowKey = true    % false 时只显示值 (用于图形化窄带)
    end

    methods
        function self = StatusChip(parent, key, value, status, opts)
            %STATUSCHIP(parent, key, value, status, opts) 建一个胶囊。
            %   value 传空 -> 显示未取数; status 传空 -> 中性状态 UNKNOWN。
            if nargin < 3, value = ''; end
            if nargin < 4, status = ''; end
            if nargin < 5, opts = struct(); end
            if isempty(parent)
                error('tepc:gui:NoParent', 'StatusChip 需要一个父容器');
            end
            self.Key = StatusChip.cleanText(key);
            self.Status = Theme.normStatus(status);
            if isempty(self.Status), self.Status = 'UNKNOWN'; end
            if ~isempty(opts) && isstruct(opts) && isfield(opts, 'OnClick')
                self.OnClick = opts.OnClick;
            end
            self.Label = uilabel(parent);
            f = Theme.fontSpec('micro');
            % 本机 uilabel 没有边框类属性 (实测 'EdgeColor' 报"属性无法识别"): 写进
            % setProps 的名单里, 每个胶囊一出生就自带一条错误记录, 真故障会被它埋掉。
            self.setProps(self.Label, {'FontName', 'FontSize', 'HorizontalAlignment', ...
                'BackgroundColor'}, {f.family, f.size, 'center', ...
                Theme.ColorSurface});
            self.Value = [];
            self.setText(value);
        end

        function setText(self, txt)
            %SETTEXT 设值文本; 同时刷新 Text / Plain / 控件, 三者不留后。
            if nargin < 2, txt = ''; end
            v = StatusChip.cleanText(txt);
            if isempty(v)
                v = '未取数';
            end
            self.Value = v;
            self.refresh();
        end

        function setKey(self, key)
            self.Key = StatusChip.cleanText(key);
            self.refresh();
        end

        function setPair(self, key, txt)
            %SETPAIR 一次设名字与值 (状态带里的胶囊常常两项一起变)。
            self.Key = StatusChip.cleanText(key);
            self.setText(txt);
        end

        function applyStatus(self, status)
            %APPLYSTATUS 换状态: 重算三通道并刷新文本 (文字通道跟着换)。
            s = Theme.normStatus(status);
            if isempty(s), s = 'UNKNOWN'; end
            self.Status = s;
            self.refresh();
        end

        function setNeutral(self)
            %SETNEUTRAL 回到"没有判断"的状态: 灰底 + 中性图标, 不借用通过色。
            self.Status = 'NOT_EVALUATED';
            self.refresh();
        end

        function refresh(self)
            %REFRESH 由 Key/Value/Status 重算 Text 与 Plain, 并写进控件。
            one = Theme.tripletFor(self.Status);
            head = self.Key;
            if ~isempty(head) && self.ShowKey
                head = [head, ' '];
            elseif ~self.ShowKey
                head = '';
            end
            self.Plain = [head, self.Value];
            self.Text = [one.glyph, ' ', self.Plain];
            if isempty(self.Label) || ~isvalid(self.Label)
                % 控件没了也要把属性更新到位: 读 Text 的测试据此判断"文本逻辑没坏,
                % 只是窗口已关", 而不是误以为 setText 根本没被调用。
                self.noteError('refresh', '控件不存在或已销毁, Text 已是最新但界面未更新');
                return;
            end
            self.setProps(self.Label, {'Text', 'FontColor', 'BackgroundColor'}, ...
                {self.Text, one.color, one.background});
        end

        function clicked = click(self)
            %CLICK 供测试与点击回调共用的触发入口 (本机没有 keypress 手势,
            %   所以"能不能点到"只能由点击处理函数自己被调用来证明)。
            self.Clicks = self.Clicks + 1;
            clicked = true;
            if isempty(self.OnClick) || ~isa(self.OnClick, 'function_handle')
                return;
            end
            evt = struct();
            evt.key = self.Key;
            evt.text = self.Text;
            evt.value = self.Value;
            evt.clicks = self.Clicks;
            evt.source = self;
            try
                feval(self.OnClick, evt);
            catch e
                self.noteError('OnClick', e.message);
            end
        end

        function s = state(self)
            %STATE 结构化快照 (纯数据), 回归测试直接读它。
            s = struct();
            s.key = self.Key;
            s.value = self.Value;
            s.text = self.Text;
            s.plain = self.Plain;
            s.status = self.Status;
            s.label_text = '';
            s.clicks = self.Clicks;
            if ~isempty(self.Label) && isvalid(self.Label)
                try
                    s.label_text = char(string(self.Label.Text));
                catch
                    s.label_text = '';
                end
            end
            s.in_sync = strcmp(s.text, s.label_text);
            s.errors = self.Errors;
        end

        function delete(self)
            try
                if ~isempty(self.Label) && isvalid(self.Label)
                    delete(self.Label);
                end
            catch
                % 清理路径不得抛错: 析构里抛错会被吞掉并污染退出码
            end
            self.Label = [];
        end
    end

    methods (Static)
        function chips = band(parent, specs)
            %BAND(parent, specs) 一次建整条状态带, 返回 StatusChip 的 cell 数组。
            %   specs 每行: {名字, 值, 状态}; 状态缺省时用 UNKNOWN。
            %   行的顺序就是胶囊顺序, 所以缺项会显式占位而不是悄悄少一个胶囊。
            chips = {};
            rows = StatusChip.asRows(specs);
            for i = 1:size(rows, 1)
                status = '';
                if size(rows, 2) >= 3
                    status = rows{i, 3};
                end
                chips{end+1} = StatusChip(parent, rows{i, 1}, rows{i, 2}, status);
            end
        end

        function t = allText(chips, sep)
            %ALLTEXT 把一条状态带拼成一行文本 (供横幅与文案扫描整体读取)。
            if nargin < 3, sep = ' | '; end
            parts = {};
            for i = 1:numel(chips)
                parts{end+1} = chips{i}.Text; %#ok<AGROW>
            end
            if isempty(parts)
                t = '状态带为空';
            else
                t = strjoin(parts, char(string(sep)));
            end
        end

        function rows = defaultSpecs()
            %DEFAULTSPECS 状态带的六个固定席位与"未取数"初值。
            %   席位是**显示契约**: 少一个席位就等于少一项对使用者可见的判定。
            rows = { ...
                '模式',        '', 'UNKNOWN';        ...
                '后端',        '', 'UNKNOWN';        ...
                '配置哈希',    '', 'UNKNOWN';        ...
                '位点',        '', 'UNKNOWN';        ...
                '未关闭阻塞项', '', 'UNKNOWN';       ...
                '是否允许发布', '', 'UNKNOWN'};
        end

        function s = hashShort(sha)
            %HASHSHORT 配置哈希短码 (带总位数), 空值明确写未取数。
            s = Theme.shortHex(sha, 8);
        end

        function rows = asRows(specs)
            if isempty(specs)
                rows = StatusChip.defaultSpecs();
                return;
            end
            if isstruct(specs)
                n = numel(specs);
                rows = cell(n, 3);
                for i = 1:n
                    rows{i, 1} = StatusChip.strAt(specs(i), 'key');
                    rows{i, 2} = StatusChip.strAt(specs(i), 'value');
                    rows{i, 3} = StatusChip.strAt(specs(i), 'status');
                end
                return;
            end
            if iscell(specs) && numel(specs) == 1 && isstruct(specs{1})
                rows = StatusChip.asRows(specs{1});
                return;
            end
            if ~iscell(specs)
                error('tepc:gui:BadChipSpec', '状态带描述只能是元胞表或结构体数组');
            end
            rows = specs;
        end

        function s = strAt(g, f)
            s = '';
            if isstruct(g) && isfield(g, f) && ~isempty(g.(f))
                s = char(string(g.(f)));
            end
        end

        function t = cleanText(x)
            %CLEANTEXT 收成单行 char: 换行与多余空白会被状态带的行高吃掉。
            if isempty(x)
                t = '';
                return;
            end
            t = strtrim(char(string(x)));
            t = regexprep(t, '[\r\n]+', ' ');
        end
    end

    methods (Access = private)
        function setProps(self, comp, names, vals)
            %SETPROPS 逐个赋属性, 失败记进 Errors 而不是抛出:
            %   状态带是被动显示的, 一个可选修饰属性设不上不该让整条带消失。
            if isempty(comp) || ~isvalid(comp)
                return;
            end
            k = min(numel(names), numel(vals));
            for i = 1:k
                try
                    comp.(names{i}) = vals{i};
                catch e
                    self.noteError('setProps', sprintf('%s 属性设置失败: %s', ...
                        names{i}, e.message)); %#ok<AGROW>
                end
            end
        end

        function noteError(self, where, msg)
            %NOTEERROR 失败留痕: 被吞掉的属性错误会让胶囊停在旧文本上无人发现。
            self.Errors{end+1} = sprintf('%s(%s): %s', self.Key, where, ...
                char(string(msg))); %#ok<AGROW>
        end
    end
end
