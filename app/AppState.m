classdef AppState < handle
    %APPSTATE GUI 的单一状态源: 配置结构体 + 派生量 + 订阅者列表。
    %   本类不创建也不修改任何控件 (界面对它只读); 一切改动都从 setField 进来。
    %   订阅者是同步函数句柄回调, 所以订阅方可以是控件刷新函数, 也可以是纯记录器
    %   (回归测试用纯记录器订阅, 不需要先开 uifigure)。
    %
    % 两条校验通道, 时延刻意不同:
    %   1) 就地校验 validateField / validateModel 同步做。MATLAB 的 timer 回调只在
    %      主线程空闲时才被调用, 把"这个格子填错了"挂在定时器上会让提示比手慢。
    %   2) 派生量重算 (整条 resolve 链) 延后进 timer('StartDelay', DebounceDelay):
    %      每次输入先 stop 再 start, 复用同一个一次性定时器, 于是连续输入只结算最后
    %      一次; 单次重算比 DebounceDelay 慢时也不会堆积 (下一拍先把上一拍停掉)。
    %
    % 延后通道的可观测边界 (调用方必须按这三态读, 别把"没跑"当成"跑过了"):
    %   排上   timerState()=='on' 且 debounce_armed==true: 已排期, 尚未结算;
    %   结算   回调落到 recomputeNow, armed 归 false, ComputeCount +1;
    %   不可用 定时器建不出来 (受限/无头会话) 时 DebounceError 记下原因并当场同步重算。
    %   主线程长期不空闲 (例如 -batch 无头会话跑到退出) 时, 排上的回调可能一次都不派发 ——
    %   要立刻拿到派生量就显式调 recomputeNow (同步兜底, 与回调走同一条落点)。
    %
    % timer 生命周期 (本机 timer 不随 uifigure 销毁, 必须自己收口):
    %   创建   惰性且唯一: 只有 armDebounce 建, 建好后反复复用, 不出现第二个对象;
    %   重排   cancelDebounce 只在 Running 为 on 时 stop, 然后 start 重新计时;
    %   回调   开头查 Closed 与 isvalid, 关闭后到达的在途回调直接丢弃;
    %   销毁   close / delete 显式 stop + delete + 置空, 并清空订阅者, 断开回调句柄
    %          对 self 的引用 —— 定时器持有 self, 不删定时器就永远回收不掉;
    %   兜底   timer 建不出来 (受限会话) 时退化为同步重算, 并把原因留在 DebounceError,
    %          不让派生量静默停在旧值。
    %
    % 界面到配置的映射表不在本类里重写: setSchema 只接收应用层那一张表。

    properties (SetAccess = private)
        Config = []              % 配置结构体 (唯一副本)
        Derived = []             % 最近一次派生量投影
        DerivedState = ''        % NOT_COMPUTED | PARTIAL | FRESH | FAILED
        DerivedError = ''        % 最近一次重算失败或缺位说明
        DerivedMissing = {}      % 取不到的派生量名 (空表示全都取到了)
        Issues = {}              % 最近一次 validateModel 的结果
        FieldIssues = []         % tag -> 就地校验问题列表
        Schema = {}              % 字段描述行 (cell of struct)
        Dirty = {}               % 自上次界面同步以来改过的 tag
        Revision = 0             % 每次 setField 递增
        Subscribers = {}         % cell of struct(Id, Fn, Tags)
        SubscriberErrors = {}    % 订阅者抛出的异常记录 (不静默吞)
        OpenBlockers = []        % 未关闭阻塞项计数; [] 表示未取数
        OpenBlockerSource = ''   % 计数出处; 空表示没有出处
        DebounceTimer = []       % 唯一的延时装载器
        DebounceArmed = false    % 是否已排上延后重算
        DebounceError = ''       % 定时器不可用时的原因
        ComputeCount = 0         % 重算尝试次数 (成功与失败都算; 只数成功会让失败看起来像"没跑")
        Busy = false             % 重算进行中 (防重入)
        NextSubId = 1
        Closed = false
        CloseReason = ''         % 收口来源 (close / delete / 关窗回调), 便于事后追查
    end

    properties
        DebounceDelay = 0.3      % 秒, 对应 timer 的 StartDelay
    end

    methods
        function self = AppState(cfg)
            if nargin >= 1 && ~isempty(cfg)
                self.Config = cfg;
            end
            self.FieldIssues = struct();
            self.Derived = struct();
        end

        % ---------- 配置 ----------
        function cfg = config(self)
            %CONFIG 配置的副本; 调用方改返回值不会动到状态源 (结构体按值传)。
            cfg = self.Config;
        end

        function setConfig(self, cfg, reason)
            %SETCONFIG 整体替换配置 (载入配置文件时用), 并把登记表里的字段全标脏。
            if nargin < 3, reason = 'config'; end
            self.ensureOpen();
            if ~isstruct(cfg) || isempty(cfg)
                error('tepc:gui:BadConfig', 'setConfig 需要一个非空配置结构体');
            end
            self.Config = cfg;
            self.Revision = self.Revision + 1;
            self.Dirty = {};
            for i = 1:numel(self.Schema)
                self.Dirty{end+1} = self.Schema{i}.tag; %#ok<AGROW>
            end
            self.DerivedState = 'STALE';
            self.FieldIssues = struct();
            self.armDebounce();
            self.notifyEvent(self.Dirty, reason);
        end

        function changed = setField(self, tag, value)
            %SETFIELD 写一个字段 -> 记脏 -> 同步就地校验 -> 排期派生量 -> 通知订阅者。
            self.ensureOpen();
            t = AppState.needVarname(tag);
            path = self.pathFor(t);
            [old, hadOld] = AppState.getFromPath(self.Config, path);
            self.Config = AppState.setInPath(self.Config, path, value);
            self.Revision = self.Revision + 1;
            if ~self.isDirty(t)
                self.Dirty{end+1} = t;
            end
            self.DerivedState = 'STALE';
            self.validateField(t);
            self.armDebounce();
            changed = ~(hadOld && isequaln(old, value));
            self.notifyEvent({t, 'model'}, 'field');
        end

        function changed = setFields(self, tags, values, reason)
            %SETFIELDS 批量写入: 一次收集整张表单时用它, 而不是循环调 setField。
            %   逐项 setField 会逐项 stop/start 延时装载器并逐项派发事件 —— 界面映射表
            %   有几十行, 收集一次配置就要排几十次延后; 这里改成写完后只排一次、
            %   只派发一个事件 (Tags 是全部改过的 tag)。就地校验仍然逐项做。
            if nargin < 4, reason = 'fields'; end
            self.ensureOpen();
            t = AppState.toCell(tags);
            if ~iscell(values)
                values = cellstr(string(values));
            end
            if numel(values) ~= numel(t)
                error('tepc:gui:BadBatchShape', ...
                    'setFields 需要与 tags 等长的值 (tags %d, values %d)', numel(t), numel(values));
            end
            % 先整表验形状再逐项落笔: 半批写进去的版本号与脏表都是收不回来的
            for i = 1:numel(t)
                t{i} = AppState.needVarname(t{i});
            end
            changed = {};
            for i = 1:numel(t)
                path = self.pathFor(t{i});
                [old, hadOld] = AppState.getFromPath(self.Config, path);
                self.Config = AppState.setInPath(self.Config, path, values{i});
                if ~self.isDirty(t{i})
                    self.Dirty{end+1} = t{i}; %#ok<AGROW>
                end
                self.validateField(t{i});
                if ~(hadOld && isequaln(old, values{i}))
                    changed{end+1} = t{i}; %#ok<AGROW>
                end
            end
            self.Revision = self.Revision + 1;
            self.DerivedState = 'STALE';
            self.armDebounce();
            self.notifyEvent([t, {'model'}], reason);
        end

        function v = fieldValue(self, tag)
            %FIELDVALUE 按 tag 读当前配置值; 取不到返回空。
            path = self.pathFor(AppState.needVarname(tag));
            [v, found] = AppState.getFromPath(self.Config, path);
            if ~found
                v = [];
            end
        end

        function tags = dirty(self)
            tags = self.Dirty;
        end

        function markClean(self, tags)
            %MARKCLEAN 界面同步完成后清脏标记; 不传参数就全清。
            if nargin < 2 || isempty(tags)
                self.Dirty = {};
                return;
            end
            want = AppState.toCell(tags);
            keep = {};
            for i = 1:numel(self.Dirty)
                if ~any(strcmp(want, self.Dirty{i}))
                    keep{end+1} = self.Dirty{i}; %#ok<AGROW>
                end
            end
            self.Dirty = keep;
        end

        function tf = isDirty(self, tag)
            tf = any(strcmp(self.Dirty, AppState.normKey(tag)));
        end

        function n = revision(self)
            n = self.Revision;
        end

        % ---------- 字段描述表 ----------
        function setSchema(self, M)
            %SETSCHEMA 接收"界面 tag -> 配置路径 + 合法域"的描述表。
            %   入参可以是应用层 cfgMap 那种 cell 数组 (列序
            %   {tag, path, kind[, min, max, step, unit, value_status]}),
            %   也可以是含同名字段的 struct 数组或 struct cell。
            %   映射表的唯一来源仍是应用层那一张: 本类只接收不复制, 否则同一个字段
            %   会有两条互不相干的界面到配置路径。
            self.ensureOpen();
            rows = AppState.toSchema(M);
            for i = 1:numel(rows)
                rows{i}.tag = AppState.needVarname(rows{i}.tag);
            end
            self.Schema = rows;
            self.FieldIssues = struct();
        end

        function rows = schema(self)
            rows = self.Schema;
        end

        function row = schemaFor(self, tag)
            %SCHEMAFOR 取某 tag 的字段描述行。没登记时返回 kind 为 text 的兜底行
            %   (不做范围判定), 而不是抛错: 界面允许存在纯展示用的 tag。
            t = AppState.needVarname(tag);
            row = AppState.newRow();
            row.tag = t;
            for i = 1:numel(self.Schema)
                if strcmp(self.Schema{i}.tag, t)
                    row = self.Schema{i};
                    return;
                end
            end
        end

        function path = pathFor(self, tag)
            %PATHFOR tag -> 配置路径元胞。多层路径只在字段描述表的 path 列里给
            %   (形如 {'geometry','width'}); 没登记描述的 tag 就是一层同名配置字段。
            row = self.schemaFor(AppState.needVarname(tag));
            path = row.path;
            if isempty(path)
                path = {row.tag};
            end
        end

        % ---------- 就地校验 ----------
        function issues = validateField(self, tag)
            %VALIDATEFIELD 单字段校验, 同步执行, 返回问题列表 (cell of struct)。
            %   每项: level (error/warn) / code / message / tag。
            %   这里只管"这一个格子对不对", 跨字段约束一律留给 validateModel。
            t = AppState.needVarname(tag);
            issues = {};
            row = self.schemaFor(t);
            [v, found] = AppState.getFromPath(self.Config, self.pathFor(t));
            if ~found
                issues{end+1} = AppState.issue('error', 'FIELD_MISSING', ...
                    ['配置里没有 ' t ' 这一项: 界面写到了一个不存在的字段路径'], t);
            else
                switch row.kind
                    case {'num', 'int'}
                        issues = AppState.checkNumeric(t, v, row, issues);
                    case 'enum'
                        s = strtrim(char(string(v)));
                        if isempty(row.items)
                            if isempty(s)
                                issues{end+1} = AppState.issue('error', 'ENUM_EMPTY', ...
                                    [t ' 的下拉尚未选中任何值'], t); %#ok<AGROW>
                            end
                        elseif ~any(strcmp(row.items, s))
                            issues{end+1} = AppState.issue('error', 'ENUM_VALUE', ...
                                [t ' 的当前值 ' s ' 不在允许值内'], t); %#ok<AGROW>
                        end
                    case {'text', 'path'}
                        if isempty(strtrim(char(string(v))))
                            issues{end+1} = AppState.issue('error', 'TEXT_EMPTY', ...
                                [t ' 不能为空'], t); %#ok<AGROW>
                        end
                    otherwise
                        issues{end+1} = AppState.issue('error', 'BAD_KIND', ...
                            [t ' 的字段类型 ' row.kind ' 无法识别'], t); %#ok<AGROW>
                end
            end
            if ~isfield(self.FieldIssues, t)
                self.FieldIssues.(t) = {};
            end
            self.FieldIssues.(t) = issues;
        end

        function issues = fieldIssues(self, tag)
            %FIELDISSUES 某字段最近一次就地校验的问题列表 (cell of struct)。
            t = AppState.needVarname(tag);
            issues = {};
            if isfield(self.FieldIssues, t)
                issues = self.FieldIssues.(t);
            end
        end

        function list = allFieldIssues(self)
            %ALLFIELDISSUES 所有已挂问题的字段 (cell of struct, 每项带 field)。
            list = {};
            fn = fieldnames(self.FieldIssues);
            for i = 1:numel(fn)
                lst = self.FieldIssues.(fn{i});
                for j = 1:numel(lst)
                    one = lst{j};
                    one.field = fn{i};
                    list{end+1} = one; %#ok<AGROW>
                end
            end
        end

        function issues = validateModel(self)
            %VALIDATEMODEL 跨字段校验: 整段委托给服务层 tepc.config.validate。
            %   本类不复制一份校验规则 (两份规则必然分叉: 界面绿、命令行红)。
            %   服务层不可用时给一条 error 级问题而不是空列表 —— 空列表会被界面
            %   读成"没有问题", 那正是静默放行。
            self.ensureOpen();
            issues = {};
            if isempty(self.Config) || ~isstruct(self.Config)
                self.Issues = {AppState.issue('error', 'NO_CONFIG', ...
                    '还没有载入配置, 跨字段校验未执行', 'model')};
                issues = self.Issues;
                return;
            end
            try
                got = tepc.config.validate(self.Config);
                for i = 1:numel(got)
                    g = got{i};
                    lv = 'error';
                    if isfield(g, 'level') && string(g.level) == "warn"
                        lv = 'warn';
                    end
                    issues{end+1} = AppState.issue(lv, AppState.strField(g, 'code'), ...
                        AppState.strField(g, 'message'), 'model'); %#ok<AGROW>
                end
            catch e
                if strcmp(e.identifier, 'MATLAB:UndefinedFunction')
                    issues = {AppState.issue('error', 'SERVICE_UNAVAILABLE', ...
                        ['服务层 tepc.config.validate 不可用 (' e.message ...
                         ') : 跨字段校验未执行, 空结果不代表通过'], 'model')};
                else
                    issues = {AppState.issue('error', 'VALIDATE_THREW', ...
                        ['校验过程抛出异常 [' e.identifier '] ' e.message], 'model')};
                end
            end
            self.Issues = issues;
        end

        function n = issueCount(self, want)
            %ISSUECOUNT 最近一次 validateModel 里某级别的问题数。
            lv = 'error';
            if nargin >= 2 && ~isempty(want), lv = char(string(want)); end
            n = 0;
            for i = 1:numel(self.Issues)
                if strcmp(self.Issues{i}.level, lv), n = n + 1; end
            end
        end

        function s = issueSummary(self)
            %ISSUESUMMARY "错误 n / 警告 m"; 从没校验过时明确写"未校验"。
            if isempty(self.Issues)
                s = '未校验';
                return;
            end
            s = sprintf('错误 %d / 警告 %d', self.issueCount('error'), ...
                self.issueCount('warn'));
        end

        % ---------- 派生量 ----------
        function d = derived(self, how)
            %DERIVED 派生量投影: 位点请求/实现/偏差、增益、量程、气体量、运行预算。
            %   默认只回缓存 (绘制路径里不做重算); derived('now') 才同步重算一次。
            %   返回结构体恒带 state / error / missing 三个说明通道: 取不到的量是
            %   NaN 并被列进 missing, 不会伪装成一个看起来很正常的 0。
            if nargin >= 2 && strcmp(char(string(how)), 'now')
                self.recomputeNow();
            end
            d = struct();
            base = self.Derived;
            if isstruct(base) && ~isempty(base)
                fn = fieldnames(base);
                for i = 1:numel(fn)
                    d.(fn{i}) = base.(fn{i});
                end
            end
            d.state = self.DerivedState;
            d.revision = self.Revision;
            d.compute_count = self.ComputeCount;
            d.missing = self.DerivedMissing;
            d.error = self.DerivedError;
        end

        function recomputeNow(self)
            %RECOMPUTENOW 同步重算派生量 (延后到期、或没有定时器可用时走这里)。
            %   也是主线程不空闲、回调迟迟不派发时调用方的同步兜底入口。
            %   顺带取消在途排期: 同一个值不该被延时装载器再算第二遍。
            %   ComputeCount 记的是"跑了这一次", 失败同样计数: 只数成功会让
            %   "服务层不可用"看起来像"从未来得及算", 两条不同的故障共用一个 0。
            if self.Closed || self.Busy, return; end
            self.cancelDebounce();
            self.ComputeCount = self.ComputeCount + 1;
            if ~isstruct(self.Config) || isempty(self.Config)
                self.Derived = struct();
                self.DerivedMissing = {};
                self.DerivedState = 'NOT_COMPUTED';
                self.DerivedError = '还没有配置, 派生量不可得';
                self.notifyEvent({'derived'}, 'derived');
                return;
            end
            self.Busy = true;
            guard = onCleanup(@() self.releaseBusy()); %#ok<NASGU>
            try
                R = tepc.config.resolve(self.Config);
                [d, missing] = AppState.projectDerived(R, self.Config);
                self.Derived = d;
                self.DerivedMissing = missing;
                if isempty(missing)
                    self.DerivedState = 'FRESH';
                    self.DerivedError = '';
                else
                    self.DerivedState = 'PARTIAL';
                    self.DerivedError = ['部分派生量取不到: ' strjoin(missing, ', ')];
                end
            catch e
                self.Derived = struct();
                self.DerivedMissing = {};
                self.DerivedState = 'FAILED';
                if strcmp(e.identifier, 'MATLAB:UndefinedFunction')
                    self.DerivedError = ['派生量服务层不可用: ' e.message];
                else
                    self.DerivedError = ['[' e.identifier '] ' e.message];
                end
            end
            self.notifyEvent({'derived'}, 'derived');
        end

        function releaseBusy(self)
            self.Busy = false;
        end

        function txt = derivedLines(self)
            %DERIVEDLINES 派生量的可显示文本 (cell of char)。只排版, 不写控件。
            d = self.derived();
            txt = {sprintf('派生量状态: %s', char(string(d.state)))};
            if ~isempty(d.error)
                txt{end+1} = sprintf('  说明: %s', char(string(d.error))); %#ok<AGROW>
            end
            if ~isfield(d, 'site_requested_um')
                return;
            end
            txt{end+1} = sprintf('  位点: 请求 %s / 实现 %s / 偏差 %s (模式 %s)', ...
                AppState.numOrNA(d.site_requested_um, '%.3f um'), ...
                AppState.numOrNA(d.site_realized_um, '%.3f um'), ...
                AppState.numOrNA(d.site_rel_mismatch_pct, '%+.1f%%'), ...
                AppState.textOrNA(d.site_mode)); %#ok<AGROW>
            txt{end+1} = sprintf(['  达成请求位点所需压强: %s —— 同一气体密度模型下' ...
                '的数学解, 不是装置能力'], ...
                AppState.numOrNA(d.pressure_for_target_Pa, '%.0f Pa')); %#ok<AGROW>
            txt{end+1} = sprintf('  增益 G_mean = %s @ %s (Diethorn, 场 %s)', ...
                AppState.numOrNA(d.gain_mean, '%.1f'), ...
                AppState.numOrNA(d.hv_V, '%.0f V'), ...
                AppState.textOrNA(d.field_kind)); %#ok<AGROW>
            txt{end+1} = sprintf('  ADC 量程上界: 量程1 %s, 量程2 %s', ...
                AppState.numOrNA(d.range1_top_V, '%.3g V'), ...
                AppState.numOrNA(d.range2_top_V, '%.3g V')); %#ok<AGROW>
            txt{end+1} = sprintf('  气体: rho = %s kg/m^3, 平均弦长 %s, 体积 %s m^3', ...
                AppState.numOrNA(d.rho_g, '%.4e'), ...
                AppState.numOrNA(d.gas_lbar_um, '%.2f um'), ...
                AppState.numOrNA(d.gas_volume_m3, '%.3e')); %#ok<AGROW>
            txt{end+1} = sprintf('  预算: 事件 %s, 分块 %s, 约 %s 块', ...
                AppState.numOrNA(d.n_events, '%d'), ...
                AppState.numOrNA(d.chunk_size, '%d'), ...
                AppState.numOrNA(d.n_chunks, '%d')); %#ok<AGROW>
        end

        % ---------- 阻塞项计数 ----------
        function setOpenBlockers(self, n, source)
            %SETOPENBLOCKERS 登记未关闭阻塞项的计数与出处; 传空表示回到未取数。
            %   没有出处时不得显示成 0 —— 0 会被读成"已经干净了"。
            if nargin < 3, source = ''; end
            if isempty(n)
                self.OpenBlockers = [];
            else
                self.OpenBlockers = max(0, round(double(n(1))));
            end
            self.OpenBlockerSource = char(string(source));
        end

        function n = openBlockers(self)
            n = self.OpenBlockers;
        end

        function s = openBlockersText(self)
            %OPENBLOCKERSTEXT 计数文本 (带出处); 未取数时明确写未取数。
            if isempty(self.OpenBlockers)
                s = '未取数';
                return;
            end
            s = sprintf('%d', self.OpenBlockers);
            if ~isempty(self.OpenBlockerSource)
                s = [s, ' (出处: ', self.OpenBlockerSource, ')'];
            end
        end

        % ---------- 订阅 ----------
        function id = subscribe(self, fn, tags)
            %SUBSCRIBE 挂一个刷新回调, 返回用于退订的 id。
            %   fn(evt) 收到 struct(Tags, Reason, Revision, Source)。
            %   tags 传空表示所有事件都要 (缺省)。
            self.ensureOpen();
            if ~isa(fn, 'function_handle')
                error('tepc:gui:BadSubscriber', '订阅者必须是函数句柄');
            end
            if nargin < 3, tags = {}; end
            id = self.NextSubId;
            s = struct();
            s.Id = id;
            s.Fn = fn;
            s.Tags = AppState.toCell(tags);
            self.Subscribers{end+1} = s;
            self.NextSubId = id + 1;
        end

        function removed = unsubscribe(self, id)
            want = double(id);
            keep = {};
            for i = 1:numel(self.Subscribers)
                if self.Subscribers{i}.Id ~= want
                    keep{end+1} = self.Subscribers{i}; %#ok<AGROW>
                end
            end
            removed = numel(keep) < numel(self.Subscribers);
            self.Subscribers = keep;
        end

        function n = subscriberCount(self)
            n = numel(self.Subscribers);
        end

        function n = notify(self, evt)
            %NOTIFY 逐个调用订阅者。单个订阅者抛错只记录并继续, 不打断其它刷新。
            snapshot = self.Subscribers;
            n = 0;
            for i = 1:numel(snapshot)
                s = snapshot{i};
                if ~isempty(s.Tags) && ~AppState.overlaps(s.Tags, evt.Tags)
                    continue;
                end
                try
                    feval(s.Fn, evt);
                    n = n + 1;
                catch e
                    self.SubscriberErrors{end+1} = sprintf( ...
                        '订阅者 %d 抛错 [%s] %s', s.Id, e.identifier, e.message); %#ok<AGROW>
                end
            end
        end

        % ---------- 延后重算 (防抖) ----------
        function armed = armDebounce(self)
            %ARMDEBOUNCE stop-before-start 复用同一个一次性定时器。
            %   ExecutionMode 的合法值是 'singleShot': 写成 'singleShotTime' 时
            %   timer() 整体构造失败, 延后通道就永久退化为同步重算 (每次输入都重算
            %   整条 resolve 链), 而且只在 DebounceError 里留一句话。
            armed = false;
            if self.Closed, return; end
            self.cancelDebounce();
            try
                if isempty(self.DebounceTimer) || ~isvalid(self.DebounceTimer)
                    self.DebounceTimer = timer('Name', 'tepc_appstate_debounce', ...
                        'Tag', 'tepc_appstate_debounce', ...
                        'StartDelay', max(0.01, double(self.DebounceDelay)), ...
                        'ExecutionMode', 'singleShot', ...
                        'TimerFcn', @(~, ~) self.onTimerFired());
                end
                armed = self.startDebounce();
            catch e
                self.DebounceArmed = false;
                self.dropTimerQuietly();
                self.DebounceError = ['延时装载器不可用 (' e.message ...
                    ') : 派生量退化为同步重算'];
                self.recomputeNow();
            end
        end

        function armed = startDebounce(self)
            %STARTDEBOUNCE 起表并把排期标记落到属性上。
            %   stop 是异步的: 连续输入时上一拍可能还在收尾, 这一起 start 会报"已在
            %   运行" —— 延后效果正是我们要的, 按排上处理, 不当成建表失败删掉对象。
            armed = false;
            try
                start(self.DebounceTimer);
                armed = true;
            catch
                try
                    armed = strcmp(self.DebounceTimer.Running, 'on');
                catch
                    armed = false;
                end
            end
            self.DebounceArmed = armed;
            if armed
                self.DebounceError = '';
            end
        end

        function cancelDebounce(self)
            self.DebounceArmed = false;
            try
                tmr = self.DebounceTimer;
                if ~isempty(tmr) && isvalid(tmr) && strcmp(tmr.Running, 'on')
                    stop(tmr);
                end
            catch e
                self.DebounceError = e.message;
            end
        end

        function onTimerFired(self)
            %ONTIMERFIRED 定时器回调: 只在主线程空闲时被调用, 也可能来自已关闭的会话。
            if self.Closed, return; end
            try
                alive = isvalid(self);
            catch
                alive = false;
            end
            if ~alive, return; end
            self.DebounceArmed = false;
            self.recomputeNow();
        end

        function st = timerState(self)
            %TIMERSTATE 定时器自查 ('on' / 'off' / 'none'), 给回归测试断言用。
            if isempty(self.DebounceTimer) || ~isvalid(self.DebounceTimer)
                st = 'none';
                return;
            end
            try
                st = char(string(self.DebounceTimer.Running));
            catch
                st = 'unknown';
            end
        end

        function setDebounceDelay(self, delaySec)
            %SETDEBOUNCEDELAY 改延时常量; 非法值拒绝而不是悄悄夹到最小值。
            ok = ~isempty(delaySec) && isnumeric(delaySec) && ...
                 isscalar(delaySec) && isfinite(delaySec);
            if ~ok
                error('tepc:gui:BadDebounceDelay', ...
                    'DebounceDelay 需要一个有限秒数 (当前缺省 0.3 秒)');
            end
            v = max(0.01, double(delaySec));
            self.DebounceDelay = v;
            if ~isempty(self.DebounceTimer) && isvalid(self.DebounceTimer)
                self.DebounceTimer.StartDelay = v;
            end
        end

        % ---------- 关闭 ----------
        function close(self, reason)
            %CLOSE 显式收口: 停表 + 删表 + 断开订阅者 (定时器句柄里存着 self)。
            %   关窗时必须走到这里: 本机 timer 不随 uifigure 销毁, 只删窗口会让
            %   定时器留在 timer 组里并在下一次主线程空闲时回调到已销毁的界面上。
            if nargin < 2, reason = 'close'; end
            if self.Closed, return; end
            self.cancelDebounce();
            self.dropTimerQuietly();
            self.Subscribers = {};
            self.Closed = true;
            self.CloseReason = char(string(reason));
        end

        function dropTimerQuietly(self)
            %DROPTIMERQUIETLY 停并删定时器, 失败只记录不抛 (清理路径不得打断关窗)。
            try
                tmr = self.DebounceTimer;
                if ~isempty(tmr) && isvalid(tmr)
                    stop(tmr);
                    delete(tmr);
                end
            catch e
                self.DebounceError = e.message;
            end
            self.DebounceTimer = [];
            self.DebounceArmed = false;
        end

        function tf = isClosed(self)
            tf = self.Closed;
        end

        function s = summary(self)
            %SUMMARY 结构化快照 (纯数据, 测试可直接逐字段断言)。
            s = struct();
            s.revision = self.Revision;
            s.dirty = self.Dirty;
            s.derived_state = self.DerivedState;
            s.compute_count = self.ComputeCount;
            s.missing = self.DerivedMissing;
            s.n_issues = numel(self.Issues);
            s.subscribers = numel(self.Subscribers);
            s.subscriber_errors = numel(self.SubscriberErrors);
            s.debounce_delay = self.DebounceDelay;
            s.debounce_armed = self.DebounceArmed;
            s.debounce_error = self.DebounceError;
            s.timer = self.timerState();
            s.closed = self.Closed;
            s.close_reason = self.CloseReason;
            s.open_blockers = self.openBlockersText();
        end

        function delete(self)
            self.close('delete');
        end
    end

    methods (Static)
        function t = normKey(tag)
            t = strtrim(char(string(tag)));
        end

        function t = needVarname(tag)
            %NEEDVARNAME 界面 tag 的唯一合法形状: 一个合法 MATLAB 字段名。
            %   配置里的多层路径由字段描述表的 path 列用**字段名元胞**表达
            %   (例如 {'electronics','adc','fullScale_V'}), 不写成点号串:
            %   FieldIssues 的键与 Dirty 的元素都要当结构体字段名用, 点号串会在
            %   第一次写问题时抛 MATLAB:AddField:InvalidFieldName (一个裸的引擎错误,
            %   既不点名合法形状, 也会把整条写入路径打断)。
            t = AppState.normKey(tag);
            if ~isvarname(t)
                error('tepc:gui:BadFieldPath', ...
                    ['字段标识必须是合法字段名 (如 gwidth); 多层配置路径要走字段描述表的 ' ...
                     'path 元胞 (如 {''geometry'', ''width''}), 不接受点号串: 收到 ''' t '''']);
            end
        end

        function c = toCell(x)
            %TOCELL char / string / 元胞统一成行元胞 (空输入给空元胞)。
            if isempty(x)
                c = {};
                return;
            end
            if iscell(x)
                c = cell(1, numel(x));
                for i = 1:numel(x)
                    c{i} = strtrim(char(string(x{i})));
                end
                return;
            end
            v = string(x);
            c = cell(1, numel(v));
            for i = 1:numel(v)
                c{i} = strtrim(char(v(i)));
            end
        end

        function tf = overlaps(a, b)
            tf = false;
            for i = 1:numel(a)
                if any(strcmp(b, a{i})), tf = true; return; end
            end
        end

        function iss = issue(level, code, message, tag)
            iss = struct('level', char(string(level)), 'code', char(string(code)), ...
                'message', char(string(message)), 'tag', char(string(tag)));
        end

        function s = strField(g, f)
            %STRFIELD 从服务层返回的结构体里取一个文本字段; 缺失给空串。
            s = '';
            if isstruct(g) && isfield(g, f) && ~isempty(g.(f))
                s = char(string(g.(f)));
            end
        end

        function x = rawField(g, f)
            %RAWFIELD 取一个原样字段 (可以是元胞); 缺失或为空给空数组。
            x = [];
            if isstruct(g) && isfield(g, f)
                x = g.(f);
            end
        end

        function row = newRow()
            %NEWROW 一行字段描述。用逐字段赋值而不是 struct('a',{}) 起手:
            %   零尺寸结构体数组的字段赋值是空操作, 会把整行静默丢掉。
            row = struct();
            row.tag = '';
            row.path = {};
            row.kind = 'num';
            row.min = [];
            row.max = [];
            row.step = [];
            row.unit = '';
            row.value_status = '';
            row.items = {};
            row.help = '';
        end

        function out = toSchema(in)
            %TOSCHEMA 归一字段描述表 -> cell of struct。
            out = {};
            if isempty(in), return; end
            if isstruct(in)
                for i = 1:numel(in)
                    out{end+1} = AppState.rowFromStruct(in(i)); %#ok<AGROW>
                end
                return;
            end
            if ~iscell(in), return; end
            % 元胞数组: 可能是 {tag, path, kind, ...} 的表, 也可能是行结构体的 cell。
            if size(in, 1) == 1 && isstruct(in{1})
                out = AppState.toSchema(in{1});
                return;
            end
            nCol = size(in, 2);
            for i = 1:size(in, 1)
                row = AppState.newRow();
                row.tag = AppState.cellStr(in, i, 1);
                row.path = AppState.toCell(in{i, 2});
                row.kind = AppState.cellStr(in, i, 3);
                if isempty(row.kind), row.kind = 'num'; end
                row.min = AppState.cellNum(in, i, 4);
                row.max = AppState.cellNum(in, i, 5);
                row.step = AppState.cellNum(in, i, 6);
                row.unit = AppState.cellStr(in, i, 7);
                row.value_status = AppState.cellStr(in, i, 8);
                if nCol >= 9
                    row.items = AppState.toCell(in{i, 9});
                end
                if ~isempty(row.tag)
                    out{end+1} = row;
                end
            end
        end

        function row = rowFromStruct(g)
            row = AppState.newRow();
            row.tag = AppState.strField(g, 'tag');
            row.kind = AppState.strField(g, 'kind');
            if isempty(row.kind), row.kind = 'num'; end
            row.path = AppState.toCell(AppState.rawField(g, 'path'));
            row.min = AppState.numField(g, 'min');
            row.max = AppState.numField(g, 'max');
            row.step = AppState.numField(g, 'step');
            row.unit = AppState.strField(g, 'unit');
            row.value_status = AppState.strField(g, 'value_status');
            row.items = AppState.toCell(AppState.rawField(g, 'items'));
            row.help = AppState.strField(g, 'help');
        end

        function v = numField(g, f)
            v = [];
            if isstruct(g) && isfield(g, f) && ~isempty(g.(f))
                x = g.(f);
                if isnumeric(x) && isfinite(double(x(1)))
                    v = double(x(1));
                end
            end
        end

        function s = cellStr(in, i, j)
            s = '';
            if j <= size(in, 2) && ~isempty(in{i, j})
                s = strtrim(char(string(in{i, j})));
            end
        end

        function v = cellNum(in, i, j)
            v = [];
            if j > size(in, 2), return; end
            x = in{i, j};
            if isempty(x) || ~isnumeric(x) || ~isscalar(x), return; end
            if isfinite(double(x))
                v = double(x);
            end
        end

        function issues = checkNumeric(t, v, row, issues)
            %CHECKNUMERIC 标量/有限/整数/上下限四类判定; 上下限只在描述表给了时才判。
            if ~(isnumeric(v) || islogical(v)) || isempty(v) || ~isscalar(v)
                issues{end+1} = AppState.issue('error', 'FIELD_NOT_SCALAR', ...
                    [t ' 需要一个标量数值, 当前不是'], t); %#ok<AGROW>
                return;
            end
            x = double(v);
            if ~isfinite(x)
                issues{end+1} = AppState.issue('error', 'FIELD_NOT_FINITE', ...
                    [t ' 必须是有限实数'], t); %#ok<AGROW>
                return;
            end
            if strcmp(row.kind, 'int') && x ~= round(x)
                issues{end+1} = AppState.issue('error', 'FIELD_NOT_INTEGER', ...
                    [t ' 必须是整数, 当前 ' num2str(x)], t); %#ok<AGROW>
            end
            if ~isempty(row.min) && isfinite(row.min) && x < row.min
                issues{end+1} = AppState.issue('error', 'FIELD_BELOW_MIN', ...
                    [t ' 小于允许下限 ' num2str(row.min)], t); %#ok<AGROW>
            end
            if ~isempty(row.max) && isfinite(row.max) && x > row.max
                issues{end+1} = AppState.issue('error', 'FIELD_ABOVE_MAX', ...
                    [t ' 大于允许上限 ' num2str(row.max)], t); %#ok<AGROW>
            end
        end

        function [v, found] = getFromPath(s, path)
            %GETFROMPATH 按路径元胞读配置; 任一级缺失即 found=false, 不抛错。
            v = [];
            found = false;
            if ~isstruct(s) || isempty(path), return; end
            cur = s;
            for i = 1:numel(path)
                k = char(string(path{i}));
                if ~isstruct(cur) || ~isfield(cur, k), return; end
                cur = cur.(k);
            end
            v = cur;
            found = true;
        end

        function s = setInPath(s, path, value)
            %SETINPATH 按路径元胞写配置, 中间缺的层自动补空结构体。
            if ~isstruct(s), s = struct(); end
            if isempty(path)
                error('tepc:gui:BadPath', '写入配置需要至少一级字段名');
            end
            k = char(string(path{1}));
            if numel(path) == 1
                s.(k) = value;
            else
                if ~isfield(s, k) || ~isstruct(s.(k))
                    s.(k) = struct();
                end
                s.(k) = AppState.setInPath(s.(k), path(2:end), value);
            end
        end

        function [d, missing] = projectDerived(R, cfg)
            %PROJECTDERIVED 从 resolve 的产物里挑出界面要显示的派生量。
            %   取不到的项留 NaN 并记进 missing, 界面据此显示"不可得"而不是 0。
            d = struct();
            missing = {};
            [d.site_requested_um, ok] = AppState.grabNum(R, ...
                {'site_requested_d_tissue_m'}, 1e6);
            missing = AppState.track(missing, ok, 'site_requested_um');
            [d.site_realized_um, ok] = AppState.grabNum(R, ...
                {'geom', 'site', 'd_tissue_m'}, 1e6);
            missing = AppState.track(missing, ok, 'site_realized_um');
            [d.site_rel_mismatch_pct, ok] = AppState.grabNum(R, ...
                {'siteConsistency', 'relative_mismatch'}, 100);
            missing = AppState.track(missing, ok, 'site_rel_mismatch_pct');
            [d.pressure_for_target_Pa, ok] = AppState.grabNum(R, ...
                {'siteConsistency', 'pressure_for_target_Pa'}, 1);
            missing = AppState.track(missing, ok, 'pressure_for_target_Pa');
            [d.gain_mean, ok] = AppState.grabNum(R, {'G_mean'}, 1);
            missing = AppState.track(missing, ok, 'gain_mean');
            [d.hv_V, ok] = AppState.grabNum(R, {'field', 'hv_V'}, 1);
            missing = AppState.track(missing, ok, 'hv_V');
            [d.anode_radius_um, ok] = AppState.grabNum(R, {'field', 'a'}, 1e6);
            missing = AppState.track(missing, ok, 'anode_radius_um');
            [d.cavity_radius_mm, ok] = AppState.grabNum(R, {'field', 'b'}, 1e3);
            missing = AppState.track(missing, ok, 'cavity_radius_mm');
            [d.rho_g, ok] = AppState.grabNum(R, {'rho_g'}, 1);
            missing = AppState.track(missing, ok, 'rho_g');
            [d.gas_lbar_um, ok] = AppState.grabNum(R, {'geom', 'lbar_gas_m'}, 1e6);
            missing = AppState.track(missing, ok, 'gas_lbar_um');
            [d.gas_volume_m3, ok] = AppState.grabNum(R, {'geom', 'V_m3'}, 1);
            missing = AppState.track(missing, ok, 'gas_volume_m3');
            [d.tissue_lbar_um, ok] = AppState.grabNum(R, {'lbar_tissue_um'}, 1);
            missing = AppState.track(missing, ok, 'tissue_lbar_um');
            [d.range1_top_V, ok1] = AppState.grabNum(cfg, ...
                {'electronics', 'adc', 'fullScale_V'}, 1);
            missing = AppState.track(missing, ok1, 'range1_top_V');
            [d.range2_gain, ok2] = AppState.grabNum(cfg, ...
                {'electronics', 'adc', 'range2Gain'}, 1);
            if ok1 && ok2
                d.range2_top_V = d.range1_top_V*d.range2_gain;
            else
                d.range2_top_V = NaN;
                missing = AppState.track(missing, false, 'range2_top_V');
            end
            d.n_events = AppState.grabNum(cfg, {'run', 'nEvents'}, 1);
            d.chunk_size = AppState.grabNum(cfg, {'run', 'chunkSize'}, 1);
            if isfinite(d.n_events) && isfinite(d.chunk_size) && d.chunk_size > 0
                d.n_chunks = ceil(d.n_events/d.chunk_size);
            else
                d.n_chunks = NaN;
                missing = AppState.track(missing, false, 'n_chunks');
            end
            d.site_mode = AppState.grabChar(R, {'siteMode'});
            d.field_kind = AppState.grabChar(R, {'field', 'kind'});
            d.electrode_topology = AppState.grabChar(R, {'field', 'topology'});
        end

        function [v, ok] = grabNum(s, path, scale)
            %GRABNUM 安全取一个有限标量并乘尺度因子; 取不到给 NaN。
            v = NaN;
            ok = false;
            try
                [x, found] = AppState.getFromPath(s, path);
                if ~found || ~isnumeric(x) || isempty(x), return; end
                y = double(x(1));
                if ~isfinite(y), return; end
                v = y*scale;
                ok = true;
            catch
                v = NaN;
                ok = false;
            end
        end

        function s = grabChar(s0, path)
            %GRABCHAR 安全取一个文本项; 取不到给空串 (显示层会印成不可得)。
            s = '';
            try
                [x, found] = AppState.getFromPath(s0, path);
                if found && ~isempty(x) && (ischar(x) || isstring(x))
                    s = char(string(x));
                end
            catch
                s = '';
            end
        end

        function missing = track(missing, ok, name)
            if ~ok
                missing{end+1} = name; %#ok<AGROW>
            end
        end

        function s = numOrNA(x, form)
            %NUMORNA 数值或"不可得"; 缺位一律显式印出来, 不印成 0 也不留空。
            if isempty(x) || numel(x) ~= 1 || ~isnumeric(x) || ~isfinite(double(x))
                s = '不可得';
            else
                s = sprintf(form, double(x));
            end
        end

        function s = textOrNA(x)
            if isempty(x) || ~any(char(string(x)) > ' ')
                s = '不可得';
            else
                s = char(string(x));
            end
        end
    end

    methods (Access = private)
        function notifyEvent(self, tags, reason)
            %NOTIFYEVENT 组一个事件并派发。Source 用逐字段赋值放进结构体而不是走
            %   struct('Source', obj): struct() 对句柄对象会按属性展开成结构体数组。
            evt = struct();
            evt.Tags = AppState.toCell(tags);
            evt.Reason = char(string(reason));
            evt.Revision = self.Revision;
            evt.State = self.DerivedState;
            evt.Source = self;
            self.notify(evt);
        end

        function ensureOpen(self)
            if self.Closed
                error('tepc:gui:StateClosed', 'AppState 已关闭, 拒绝继续写入状态源');
            end
        end
    end
end
