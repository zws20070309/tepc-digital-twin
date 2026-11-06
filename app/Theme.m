classdef Theme
    %THEME 界面设计常量: 8 px 间距体系、字号层级、色板、状态三通道与合法布局 token。
    %   本类不创建也不修改任何控件, 只返回数值/字符串/元胞, 所以在没有 uifigure 的
    %   批处理会话里同样可求值 (测试可以直接断言常量而不必先开窗口)。
    %
    %   状态三通道 (颜色 + 图标字符 + 文字) 是硬要求:
    %   只靠颜色区分在色盲与灰度打印下整体失效; 只用图标则在缺字字体会显示成方框。
    %   因此 tripletFor() 一次给全三个通道, 消费侧必须把三个通道一起落到界面上,
    %   少落一个就等于把可访问性降级成"仅靠颜色"。
    %
    %   布局 token 的真实边界 (决定本类为什么只提供这三种值):
    %   本机 uigridlayout 的 RowHeight/ColumnWidth 只接受数字、'Nx'、'fit',
    %   没有 'auto'; GridLayout 也没有 FlowDirection/MinColumnWidth/ColumnBreak。
    %   所以"窄窗口 3 列变 1 列"这类响应式断点无法交给布局容器, 只能由持有
    %   SizeChangedFcn 的一侧取 Theme.columnWidths(n, width) 重算后写回。

    properties (Constant)
        % ---------- 8 px 间距体系 ----------
        Space = 8;
        GapXS = 4;
        GapS = 8;
        GapM = 16;
        GapL = 24;
        GapXL = 32;
        PadCard = 16;
        PadPage = 24;
        PadBand = 8;

        % ---------- 控件与行高 ----------
        ControlH = 32;
        ControlHIdeal = 36;
        FormRowH = 28;       % 单行表单行高 (控件 22 px 文本高 + 上下余量)
        EvidenceH = 250;     % 证据面板在页签网格里占的行高 (状态行+筛选+表+原文四行)
        ToolToolbarH = 74;   % 图区工具条行高 (ToolbarH + HintH + 上下 GapS)
        CardRowH = 66;       % 紧凑参数卡片行高 (ControlH + HintH + 上下 GapS)
        HintH = 18;
        LegendBandH = 205;   % 三维页图例预留行高: 图例挂在页签网格上而非坐标区那一格,
                             % 25 项两列实测 166 px 高、顶边在坐标区下沿之下约 32 px,
                             % 所以净空要按 32+166 给, 再留一点余量。
        ChipH = 26;
        BandH = 40;
        BannerFontSize = 13; % 警报横幅字号: 40 px 行高下唯一能整行走完的一档
        ToolbarH = 34;
        CardBodyH = 40;
        LabelColW = 132;
        MinCardW = 260;
        MinColW = 150;
        BreakTwoCol = 780;
        BreakThreeCol = 1180;

        % ---------- 字体 (Microsoft YaHei UI 缺失时 MATLAB 会自行回落, 故给备选名) ----------
        FontFamily = 'Microsoft YaHei UI';
        FontFamilyAlt = 'Microsoft YaHei';
        FontBody = 14;
        FontSecondary = 18;
        FontPageTitle = 24;
        FontMicro = 12;
        FontFloor = 11;

        % ---------- 色板 (行尾是十六进制原值; 三元组 = 字节/255) ----------
        ColorCanvas = [0.96078 0.96863 0.98039];
        ColorSurface = [1 1 1];
        ColorAccent = [0.14510 0.38824 0.92157];
        ColorOk = [0.08235 0.50196 0.23922];
        ColorWarn = [0.70588 0.32549 0.03529];
        ColorBad = [0.72549 0.10980 0.10980];
        ColorInk = [0.13 0.15 0.18];
        ColorMuted = [0.42 0.45 0.49];
        ColorRule = [0.86 0.88 0.91];

        HexCanvas = '#F5F7FA';
        HexSurface = '#FFFFFF';
        HexAccent = '#2563EB';
        HexOk = '#15803D';
        HexWarn = '#B45309';
        HexBad = '#B91C1C';
        HexPalette = {'#F5F7FA', '#FFFFFF', '#2563EB', '#15803D', '#B45309', '#B91C1C'};
        HexNeutral = '#6B7280';

        % ---------- 状态图标 (三通道里的图标通道; 文字通道见 statusTable) ----------
        GlyphOk = '✔';
        GlyphWarn = '⚠';
        GlyphBad = '✖';
        GlyphInfo = 'ℹ';
        GlyphNeutral = '●';
    end

    methods (Static)
        function n = px(k)
            %PX 8 px 体系的整数倍。
            if nargin < 1 || isempty(k), k = 1; end
            n = Theme.Space*max(0, round(double(k)));
        end

        function rgb = hexToRgb(hexStr)
            %HEXTORGB 十六进制 (#RRGGBB) -> 0..1 三元组。
            %   hex2dec 返回无符号整数类型, 与 double 混算会走整数算术并饱和成 0,
            %   所以三个分量都先 double() 再除 255。
            s = upper(strtrim(char(string(hexStr))));
            s = strrep(s, '#', '');
            if isempty(regexp(s, '^[0-9A-F]{6}$', 'once'))
                error('tepc:gui:BadHexColor', '颜色必须是 #RRGGBB 形式, 收到: %s', s);
            end
            rgb = [double(hex2dec(s(1:2))), double(hex2dec(s(3:4))), ...
                   double(hex2dec(s(5:6)))]/255;
        end

        function s = rgbToHex(rgb)
            %RGBTOHEX 0..1 三元组 -> #RRGGBB (与 hexToRgb 互为反函数, 可用来自检)。
            v = round(255*double(rgb(:)'));
            if numel(v) ~= 3 || any(v < 0) || any(v > 255)
                error('tepc:gui:BadRgbColor', '颜色三元组必须在 0..1 之间');
            end
            s = sprintf('#%02X%02X%02X', v(1), v(2), v(3));
        end

        function t = tint(rgb, frac)
            %TINT 与白底混合得到的淡色 (徽标/卡片背景); frac 是原色占比。
            f = min(max(double(frac), 0), 1);
            c = double(rgb(:)');
            if numel(c) ~= 3
                error('tepc:gui:BadRgbColor', 'tint 需要 1x3 颜色三元组');
            end
            t = f*c + (1 - f)*[1 1 1];
        end

        function T = statusTable()
            %STATUSTABLE 状态词 -> 图标 / 文字 / 色调 的唯一映射表。
            %   覆盖四套词表: 配置参数的来源状态 (value_status)、能力登记状态、
            %   门禁结论、证据类型。同一个状态词在这里只有一份定义。
            persistent CACHE
            if ~isempty(CACHE)
                T = CACHE;
                return;
            end
            rows = { ...
              'MEASURED',        Theme.GlyphOk,    '实测值',       'ok';       ...
              'MEASURED_CONFIG', Theme.GlyphInfo,  '配置给定值',   'accent';   ...
              'REFERENCE',       Theme.GlyphInfo,  '参考值',       'accent';   ...
              'FITTED',          Theme.GlyphOk,    '拟合值',       'accent';   ...
              'ASSUMED',         Theme.GlyphWarn,  '假设值',       'warn';     ...
              'SYNTHETIC',       Theme.GlyphWarn,  '合成数据',     'warn';     ...
              'NOT_AVAILABLE',   Theme.GlyphNeutral, '数据缺位',   'neutral';  ...
              'UNKNOWN',         Theme.GlyphNeutral, '未标注来源', 'neutral';  ...
              'DONE',            Theme.GlyphOk,    '已完成',       'ok';       ...
              'PARTIAL',         Theme.GlyphWarn,  '部分完成',     'warn';     ...
              'BLOCKED',         Theme.GlyphBad,   '受阻',         'bad';      ...
              'EXCLUDED',        Theme.GlyphNeutral, '本轮排除',   'neutral';  ...
              'PASS',            Theme.GlyphOk,    '通过',         'ok';       ...
              'OK',              Theme.GlyphOk,    '正常',         'ok';       ...
              'FAIL',            Theme.GlyphBad,   '未通过',       'bad';      ...
              'ERROR',           Theme.GlyphBad,   '错误',         'bad';      ...
              'WARN',            Theme.GlyphWarn,  '警告',         'warn';     ...
              'NOT_EVALUATED',   Theme.GlyphNeutral, '未评估',     'neutral';  ...
              'DISABLED',        Theme.GlyphNeutral, '未启用',     'neutral';  ...
              'INCOMPLETE',      Theme.GlyphWarn,  '不完整',       'warn';     ...
              'RELEASE_ELIGIBLE', Theme.GlyphOk,   '允许发布',     'ok';       ...
              'RELEASE_BLOCKED', Theme.GlyphBad,   '禁止发布',     'bad';      ...
              'CODE',            Theme.GlyphInfo,  '代码',         'accent';   ...
              'TEST',            Theme.GlyphOk,    '测试',         'accent';   ...
              'LOG',             Theme.GlyphInfo,  '日志',         'accent';   ...
              'SCREENSHOT',      Theme.GlyphInfo,  '截图',         'accent'};
            CACHE = struct();
            for i = 1:size(rows, 1)
                tok = upper(strtrim(char(string(rows{i, 1}))));
                one = struct('status', tok, 'glyph', char(string(rows{i, 2})), ...
                    'label', char(string(rows{i, 3})), 'tone', char(string(rows{i, 4})), ...
                    'color', Theme.toneColor(char(string(rows{i, 4}))));
                one.hex = Theme.rgbToHex(one.color);
                one.background = Theme.tint(one.color, 0.12);
                CACHE.(tok) = one;
            end
            % persistent 只能在此处交回输出: 缺这一行时首次调用抛 unassignedOutputs
            % (第二次调用才读得到 CACHE), 于是每个新会话第一次建徽标/胶囊都会炸。
            T = CACHE;
        end

        function list = statusNames()
            %STATUSNAMES 已登记的状态词 (排序后返回, 便于测试逐项比对)。
            T = Theme.statusTable();
            list = sort(fieldnames(T))';
        end

        function tf = isKnown(status)
            %ISKNOWN 该状态词是否在三通道映射表里 (不在就是一处漏配, 不得静默放行)。
            s = Theme.normStatus(status);
            T = Theme.statusTable();
            tf = isfield(T, s);
        end

        function s = normStatus(status)
            %NORMSTATUS 归一状态词: 去空白、转大写、char/string 通吃。
            s = upper(strtrim(char(string(status))));
        end

        function one = tripletFor(status)
            %TRIPLETFOR 状态 -> struct(status, glyph, label, tone, color, hex,
            %   background, triplet)。未登记的状态词返回中性兜底项,
            %   文字里带上原词, 这样它不会伪装成任何一个正常状态。
            s = Theme.normStatus(status);
            T = Theme.statusTable();
            if isfield(T, s)
                one = T.(s);
                return;
            end
            one = struct('status', s, 'glyph', Theme.GlyphNeutral, ...
                'label', ['未登记状态: ' s], 'tone', 'neutral', ...
                'color', Theme.ColorMuted);
            one.hex = Theme.rgbToHex(one.color);
            one.background = Theme.tint(one.color, 0.12);
        end

        function c = colorFor(status)
            %COLORFOR 状态 -> 前景色三元组 (另有图标与文字两个通道)。
            one = Theme.tripletFor(status);
            c = one.color;
        end

        function g = glyphFor(status)
            %GLYPHFOR 状态 -> 图标字符。
            one = Theme.tripletFor(status);
            g = one.glyph;
        end

        function s = textFor(status)
            %TEXTFOR 状态 -> 中文文字 (第三通道, 也是唯一能过屏幕朗读的通道)。
            one = Theme.tripletFor(status);
            s = one.label;
        end

        function b = backgroundFor(status)
            %BACKGROUNDFOR 状态 -> 淡色背景 (徽标与卡片用, 前景仍取 colorFor)。
            one = Theme.tripletFor(status);
            b = one.background;
        end

        function s = marked(status)
            %MARKED 状态 -> "图标 文字" 一串, 供只想显示一个标签的场合使用。
            one = Theme.tripletFor(status);
            s = [one.glyph, ' ', one.label];
        end

        function c = toneColor(tone)
            %TONECOLOR 色调名 -> 色板里的实际三元组。
            switch lower(strtrim(char(string(tone))))
                case 'ok',       c = Theme.ColorOk;
                case 'warn',     c = Theme.ColorWarn;
                case 'bad',      c = Theme.ColorBad;
                case 'accent',   c = Theme.ColorAccent;
                case 'canvas',   c = Theme.ColorCanvas;
                case 'surface',  c = Theme.ColorSurface;
                case 'ink',      c = Theme.ColorInk;
                otherwise,       c = Theme.ColorMuted;
            end
        end

        function f = fontSpec(level)
            %FONTSPEC 字号层级 -> struct(level, family, altFamily, size, floor)。
            %   层级固定四档: body 正文 14 / secondary 二级 18 / page 页标题 24 /
            %   micro 辅助 12。micro 是唯一低于正文的档位, 且不低于 FontFloor。
            %   未知层级直接报错: 静默回落到正文会让一处漏配变成"看着没问题"。
            lv = lower(strtrim(char(string(level))));
            switch lv
                case {'body', '正文'},        n = Theme.FontBody;
                case {'secondary', '二级'},   n = Theme.FontSecondary;
                case {'page', 'title', '页标题'}, n = Theme.FontPageTitle;
                case {'micro', 'hint', 'chip', '辅助'}, n = Theme.FontMicro;
                otherwise
                    error('tepc:gui:BadFontLevel', ...
                        '未知字号层级 %s (可用: body/secondary/page/micro)', lv);
            end
            n = max(n, Theme.FontFloor);
            f = struct('level', lv, 'family', Theme.FontFamily, ...
                'altFamily', Theme.FontFamilyAlt, 'size', n, 'floor', Theme.FontFloor);
        end

        function p = fontProps(level)
            %FONTPROPS 字号层级 -> 控件构造用的 name-value 元胞。
            %   用法要先存进变量再展开: MATLAB 不支持对函数调用结果直接索引,
            %   所以 uilabel(g, Theme.fontProps('body'){:}) 是错的,
            %   必须 fp = Theme.fontProps('body'); uilabel(g, fp{:})。
            f = Theme.fontSpec(level);
            p = {'FontName', f.family, 'FontSize', f.size};
        end

        function L = layout(name)
            %LAYOUT 命名布局 -> struct(RowHeight, ColumnWidth, Padding, Spacing)。
            %   所有行高/列宽只取数字、'Nx'、'fit' 三种合法 token。
            %   'collapsed' 行的数字写成 0, 配合 Visible off 就是折叠面板
            %   (本机没有公开的 uiaccordion, 折叠只能这么实现)。
            key = lower(strtrim(char(string(name))));
            L = struct();
            switch key
                case 'card'
                    L.RowHeight = {Theme.ControlHIdeal, Theme.HintH, Theme.HintH};
                    L.ColumnWidth = {'1x', 'fit', 'fit'};
                    L.Padding = [Theme.PadCard Theme.PadCard Theme.PadCard Theme.PadCard];
                    L.Spacing = [Theme.GapS Theme.GapS];
                case 'cardcompact'
                    % 两行卡片: 标签/控件/步长/单位/徽标 + 提示行。
                    % 徽标不放独立行, 所以卡片高度 = ControlH + HintH + 2*GapS = 66 px,
                    % 一屏能放下整张表单 (几何页有 12 个数值格)。
                    L.RowHeight = {Theme.ControlH, Theme.HintH};
                    L.ColumnWidth = {'fit', '1x', 'fit', 'fit', 'fit'};
                    L.Padding = [Theme.GapS Theme.GapS Theme.GapS Theme.GapS];
                    L.Spacing = [Theme.GapXS Theme.GapXS];
                case 'band'
                    L.RowHeight = {Theme.BandH};
                    L.ColumnWidth = {'fit', 'fit', 'fit', 'fit', 'fit', 'fit', '1x'};
                    L.Padding = [Theme.PadBand Theme.PadBand Theme.PadBand Theme.PadBand];
                    L.Spacing = [Theme.GapS Theme.GapXS];
                case 'chipstrip'
                    % 顶部状态带: 六个胶囊位 + 一个吸收剩余宽度的尾列。
                    % 胶囊文本长短不一, 所以六列全用 'fit' (实测本机 fit 列会按文本
                    % 实际宽度落地, 不会被挤扁)。
                    L.RowHeight = {Theme.ChipH};
                    L.ColumnWidth = {'fit', 'fit', 'fit', 'fit', 'fit', 'fit', '1x'};
                    L.Padding = [Theme.GapS Theme.GapXS Theme.GapS Theme.GapXS];
                    L.Spacing = [Theme.GapXS Theme.GapXS];
                case 'toolbar'
                    L.RowHeight = {Theme.ToolbarH};
                    L.ColumnWidth = {'fit', 'fit', 'fit', 'fit', 'fit', '1x', 'fit'};
                    L.Padding = [Theme.GapS Theme.GapS Theme.GapS Theme.GapS];
                    L.Spacing = [Theme.GapS Theme.GapXS];
                case 'page'
                    L.RowHeight = {Theme.FontPageTitle + 12, '1x'};
                    L.ColumnWidth = {'1x'};
                    L.Padding = [Theme.PadPage Theme.PadPage Theme.PadPage Theme.PadPage];
                    L.Spacing = [Theme.GapM Theme.GapM];
                case 'table'
                    L.RowHeight = {'fit', '1x'};
                    L.ColumnWidth = {'1x'};
                    L.Padding = [Theme.PadCard Theme.PadCard Theme.PadCard Theme.PadCard];
                    L.Spacing = [Theme.GapS Theme.GapS];
                otherwise
                    error('tepc:gui:BadLayoutName', ...
                        ['未知布局名 ' key ...
                         ' (可用: card/cardCompact/chipstrip/band/toolbar/page/table)']);
            end
            L.name = key;
            % cardHeight = 行高数字之和 + 上下内边距 + 行间距; '1x'/'fit' 行不计 (无法静态求高)。
            h = 0;
            for i = 1:numel(L.RowHeight)
                x = L.RowHeight{i};
                if isnumeric(x) && isscalar(x)
                    h = h + double(x);
                end
            end
            L.cardHeight = h + L.Padding(1) + L.Padding(3) + ...
                L.Spacing(1)*max(0, numel(L.RowHeight) - 1);
        end

        function [w, info] = columnWidths(nCols, availPx)
            %COLUMNWIDTHS 断点重排: 给定目标列数与可用宽度, 算出合法列宽元胞。
            %   本机没有自动布局, 所以"窗口变窄就减列"必须在 SizeChangedFcn 里
            %   显式重算后写回 ColumnWidth。元胞数组不能带字段, 因此附加信息走
            %   第二个返回值 info (cell 与 struct 混在一个返回值里会直接报错)。
            n = max(1, round(double(nCols)));
            a = max(0, double(availPx));
            usable = max(0, a - 2*Theme.PadPage);
            canFit = floor(usable/max(1, Theme.MinColW));
            k = min(n, max(1, canFit));
            if k == 1
                w = {'1x'};
            else
                fixed = (k - 1)*Theme.GapM;
                each = max(Theme.MinColW, floor((usable - fixed)/max(1, k)));
                w = cell(1, k);
                for i = 1:k-1
                    w{i} = each;
                end
                w{k} = '1x';
            end
            info = struct('requested', n, 'kEffective', k, 'usablePx', usable, ...
                'fitsRequested', canFit >= n, 'minColW', Theme.MinColW);
        end

        function rows = formRows(n)
            %FORMROWS n 行表单的行高元胞 (每行一个控件高度)。
            rows = repmat({Theme.ControlHIdeal}, 1, max(1, round(double(n))));
        end

        function v = optOr(opts, name, dflt)
            %OPTOR 从 spec/opts 结构体里取字段, 缺失或为空时给默认值。
            %   空 struct 与缺字段都算"没给", 返回 dflt 而不是抛错。
            v = dflt;
            if isempty(opts) || ~isstruct(opts), return; end
            if ~isfield(opts, name), return; end
            x = opts.(name);
            if isempty(x), return; end
            v = x;
        end

        function s = shortHex(sha, n)
            %SHORTHASH 哈希短码: 取前 n 位, 被截断时把总位数一起标出来。
            %   状态带里的配置哈希要一眼能认出是哪个配置, 又不能占满整行。
            t = strtrim(char(string(sha)));
            k = 8;
            if nargin >= 2 && ~isempty(n), k = max(4, round(double(n))); end
            if isempty(t)
                s = '未取数';
                return;
            end
            if numel(t) <= k
                s = t;
            else
                s = [t(1:k), '…/', num2str(numel(t))];
            end
        end
    end
end
