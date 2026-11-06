classdef AppController < handle
%APPCONTROLLER GUI 状态机与运行管理。
%   UI 只负责显示与命令; 物理与 IO 全部经 tepc.* 服务层, 本类不含物理公式。
%   状态机: Empty->Configured->Validated->Running->Paused/Completed/Failed/
%   Cancelled->Reviewed->Released。
%   修复要点:
%   * 取消的真实标识符是 tepc:run:CancelRequested (原实现比对不存在的
%     'tepc:run:Cancelled', 于是每次取消都被报成 Failed) —— 见 classifyRunError。
%   * 终态可回到 Configured/Validated/Running: 原允许表里 Completed/Failed/Cancelled
%     都不含 Validated, 而 readAndValidate 无条件 transition("Validated") ->
%     第二次点[运行]必抛状态机错误 (被 UI 吞成红横幅, GUI 永久报废)。
%   * requestPause 同时改状态 (原来只写标志文件, pollRun 的 Paused 分支是死代码)。
%   * stopAll 供 CloseRequestFcn/析构调用: 取消后台 parfeval + 清标志文件。

properties (SetAccess = private)
    State = "Empty"
    cfg = []
    cfgPath = ""
    Future = []
    CancelFlagPath = ""
    PauseFlagPath = ""
    Result = []
    LastRunKind = ""      % ""|"completed"|"cancelled"|"failed"
end

properties
    % 诊断三元组: 只读给 UI, 但也允许外部写入 (测试需要注入一个已存在的 run 目录
    % 来验证 error.json 落点; 它们不参与任何判定逻辑, 因此开放写入不掩盖状态)。
    RuntimeInfo = []      % tepc.run.probeRuntime 的返回值
    LastRunDir = ""       % 本次后台运行的目录 (预分配, 让 UI 能显示"正在写入哪里")
    LastError = []        % 最近一次异常结构 (identifier/message/stack), 供 UI 显示根因
end

properties (SetAccess = private, Transient = true)
    listeners_ = {}
end

methods
    function self = AppController()
        d = tempdir;
        self.CancelFlagPath = fullfile(d, ['tepc_cancel_' char(string(floor(rand*1e9))) '.flag']);
        self.PauseFlagPath  = fullfile(d, ['tepc_pause_'  char(string(floor(rand*1e9))) '.flag']);
    end

    function s = state(self), s = self.State; end

    function ok = canTransition(self, to)
        % 终态 -> Configured/Validated/Running 必须允许, 否则一次运行后界面报废
        to = string(to);                      % 兼容 char 入参 (string/char 不可直接比较)
        allowed = {
            "Empty",      ["Configured"];
            "Configured", ["Validated", "Configured", "Empty"];
            "Validated",  ["Running", "Configured"];
            "Running",    ["Paused", "Completed", "Failed", "Cancelled"];
            "Paused",     ["Running", "Completed", "Failed", "Cancelled"];
            "Completed",  ["Reviewed", "Configured", "Validated", "Running"];
            "Failed",     ["Configured", "Validated", "Running", "Completed"];
            "Cancelled",  ["Configured", "Validated", "Running", "Completed"];
            "Reviewed",   ["Released", "Configured", "Validated"];
            "Released",   ["Configured"]};
        ok = false;
        for i = 1:size(allowed, 1)
            if self.State == allowed{i,1} && any(to == allowed{i,2})
                ok = true; return;
            end
        end
    end

    function transition(self, to)
        to = string(to);
        if ~self.canTransition(to)
            error("tepc:gui:BadTransition","状态机不允许 %s -> %s", self.State, to);
        end
        self.State = to;
    end

    function ensureConfigured(self)
        %ENSURECONFIGURED 重新收集配置 = 回到 Configured (幂等, 任意非运行态可用)
        %   注: 一律用 == 比较 string (switch + char 单元与 string 标量不匹配)
        if self.State == "Configured", return; end
        if self.State == "Empty"
            self.transition("Configured"); return;
        end
        if self.State == "Running" || self.State == "Paused"
            error("tepc:gui:Running","运行中不可修改配置 (当前 %s)", self.State);
        end
        if self.canTransition("Configured")
            self.transition("Configured");
        else
            self.State = "Configured";        % 状态机未列出的重入兜底
        end
    end

    function issues = readAndValidate(self, cfg, cfgPath)
        % UI 收集好的 cfg 交给服务层校验; 全部 error -> 停在 Configured
        if nargin < 2 || isempty(cfgPath), cfgPath = ""; end
        self.cfgPath = string(cfgPath);
        iss = tepc.config.validate(cfg);
        if isempty(iss)
            errs = {};
        else
            lv_ = cellfun(@(s) string(s.level), iss, 'UniformOutput', false);
            errs = iss([lv_{:}] == "error");
        end
        self.ensureConfigured();               % 终态/Empty/Validated -> Configured
        if isempty(errs)
            self.cfg = cfg;
            self.transition("Validated");
        else
            self.cfg = [];                     % 校验失败: 丢弃可用配置, 阻止用旧 cfg 起跑
        end
        issues = iss;
    end

    function invalidate(self)
        %INVALIDATE 界面数值/配置文件读不到: 作废当前可用配置 (不打断正在跑的作业)
        self.cfg = [];
        if any(self.State == ["Running", "Paused"]), return; end
        try
            self.ensureConfigured();
        % silent-by-design: 作废配置时的状态机兜底, 不得打断用户操作
        catch
        end
    end

    function startRun(self, N, dq)
        % 后台执行 (parfeval/backgroundPool), 取消/暂停经 flag 文件协作;
        % 进度经 DataQueue 回传 (send struct(f, m))。
        if self.State ~= "Validated"
            error("tepc:gui:NotValidated","只有 Validated 状态可以 Run (当前 %s)", self.State);
        end
        if isempty(self.cfg)
            error("tepc:gui:NoCfg","无有效配置");
        end
        if isfile(self.CancelFlagPath), delete(self.CancelFlagPath); end
        if isfile(self.PauseFlagPath), delete(self.PauseFlagPath); end
        cfg = self.cfg;
        self.LastRunKind = "";
        self.Result = [];
        % 状态迁移**推迟到能力预检之后**: 曾在这里就 transition("Running"), 于是
        % 预检拒绝时控制器停在 Running, 而 ensureConfigured 拒绝 Running 下的任何
        % 操作 —— 一次"这台机器不能后台跑"就把整个 GUI 卡死 (预检拒绝后
        % 必须还能改配置重试)。
        if nargin >= 2 && ~isempty(dq)
            prog = @(f, m) send(dq, struct('f', f, 'm', m));
        else
            prog = [];
        end
        % 后台运行前先**实测**能力 (旧实现: 复用任意 gcp('nocreate') 结果,
        % parpool 失败被裸 catch 吞掉并静默降级到 backgroundPool —— 而线程池写不了
        % HDF5/v7.3, 于是失败发生在跑到一半, 只留下一句"运行失败")。
        % probeRuntime 在 worker 里真的 h5create/h5write/h5read + save('-v7.3') 一遍,
        % 超时给 NOT_EVALUATED; 三种"不确定"一律禁用后台 Run。
        try
            info = tepc.run.probeRuntime('CreateIfMissing', true);
        catch eME
            info = struct('can_run_background', false, 'pool_kind', "none", ...
                'hdf5_capability', "NOT_EVALUATED", 'v73_capability', "NOT_EVALUATED", ...
                'actionable', string(eME.message), 'probe_detail', "", ...
                'pool_class', "", 'pct_licensed', false);
        end
        self.RuntimeInfo = info;
        if ~info.can_run_background
            self.LastError = struct('identifier', "tepc:gui:NoBackgroundCapability", ...
                'message', char(info.actionable));
            error("tepc:gui:NoBackgroundCapability", "%s", char(info.actionable));
        end
        pool = gcp('nocreate');
        if isempty(pool)
            self.LastError = struct('identifier', "tepc:gui:NoPool", ...
                'message', "预检称能力可用但拿不到池 (竞态?): 拒绝后台运行");
            error("tepc:gui:NoPool", "预检后仍无可用并行池, 拒绝后台运行");
        end
        % 到这里才真正开始跑: 状态机进入 Running。
        self.transition("Running");
        % 预分配 run 目录: runDirs 原本在工作进程内才被调用, 于是 GUI 永远不知道
        % 自己正在往哪儿写 (PROGRESS.json 对 GUI 无用正是因为这点)。
        outBase = getenv('TEPC_RUNS_DIR');
        if isempty(outBase) || ~isfolder(outBase)
            outBase = tepc.io.projectRoot();
        end
        runDir = fullfile(outBase, 'runs', ...
            char(string(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'))) + "-gui");
        self.LastRunDir = runDir;
        self.Future = parfeval(pool, @tepc.run.execute, 1, cfg, ...
            'N', N, 'CancelFlag', self.CancelFlagPath, 'PauseFlag', self.PauseFlagPath, ...
            'Progress', prog, 'RunDir', runDir);
    end

    function changed = requestPause(self, on)
        %REQUESTPAUSE 写/删标志文件 + 同步状态 (原实现只写文件 -> Paused 永不可达)
        changed = false;
        if on
            if self.State == "Paused"
                self.touchFlag(self.PauseFlagPath, 'p');      % 标志与状态保持一致
                return;
            end
            if self.State ~= "Running", return; end
            self.touchFlag(self.PauseFlagPath, 'p');
            self.transition("Paused");
            changed = true;
        else
            self.dropFlag(self.PauseFlagPath);
            if self.State == "Paused"
                self.transition("Running");
                changed = true;
            end
        end
    end

    function requestCancel(self)
        self.touchFlag(self.CancelFlagPath, 'c');
        % 暂停中的作业在 pause 循环里等标志消失: 取消必须同时放行暂停标志
        self.dropFlag(self.PauseFlagPath);
        if self.State == "Paused"
            self.transition("Running");           % 归还到 Running, 由 pollRun 判 Cancelled
        end
    end

    function st = pollRun(self)
        % 返回 struct(state, done, succeeded, cancelled, result, errMsg)
        st = struct('state', self.State, 'done', false, 'result', [], ...
            'errMsg', '', 'succeeded', false, 'cancelled', false);
        if isempty(self.Future), return; end
        fs = self.Future.State;
        switch fs
            case 'finished'
                try
                    out = self.Future.fetchOutputs;
                    self.Result = out;
                    self.dropFlag(self.PauseFlagPath);
                    if self.State == "Running" || self.State == "Paused"
                        self.transition("Completed");
                    end
                    st.done = true; st.succeeded = true; st.result = self.Result;
                    self.LastRunKind = "completed";
                catch e
                    st.done = true;
                    st.errMsg = e.message;
                    kind = self.classifyRunError(e.identifier);
                    st.cancelled = (kind == "cancelled");
                    self.LastRunKind = kind;
                    self.dropFlag(self.PauseFlagPath);
                    if self.State == "Paused"
                        self.transition("Running");        % Paused -> Running -> 终态
                    end
                    if self.State == "Running"
                        if st.cancelled, self.transition("Cancelled");
                        else, self.transition("Failed"); end
                    end
                end
                self.dropFuture();
            case 'running'
                % 状态与标志文件的一致性兜底 (Paused 由 requestPause 维护)
                if self.State == "Paused" && ~isfile(self.PauseFlagPath)
                    self.touchFlag(self.PauseFlagPath, 'p');
                end
            case 'queued'
                % 等待
        end
        st.state = self.State;
    end

    function kind = classifyRunError(~, id)
        %CLASSIFYRUNERROR 取消 != 失败: execute 抛出的是 tepc:run:CancelRequested
        cancelledIds = ["tepc:run:CancelRequested", "tepc:run:Cancelled"];
        if any(cancelledIds == string(id))
            kind = "cancelled";
        else
            kind = "failed";
        end
    end

    function stopAll(self)
        %STOPALL 关窗/析构清理: 撤销后台作业; 作业可能还在跑时**保留**取消标志。
        %   parfeval 一旦开跑 cancel() 就无效, 而 execute 唯一的让出点是轮询标志文件;
        %   旧实现紧接着 clearFlags() 把刚写的取消标志删掉 -> 关掉窗口作业照跑到底,
        %   还把 STATUS.json 写成 COMPLETED。另: Future.State 只有
        %   'scheduled'|'running'|'finished', 旧代码比对的 'queued'/'evaluating' 永不匹配。
        wasRunning = any(self.State == ["Running", "Paused"]);   % 保守: 状态即"可能还有活"
        try
            if ~isempty(self.Future)
                wasRunning = wasRunning || ~strcmp(self.Future.State, 'finished');
            end
        % silent-by-design: 关窗/析构清理: Future 状态读取失败时按保守路径继续
        catch
        end
        if wasRunning
            % 先立标志再 cancel: parfeval 开跑后 cancel() 无效, 而且它本身可能抛错;
            % 没有 Future 也可能有活 (startRun 在 parfeval 之前就 transition("Running"))。
            self.touchFlag(self.CancelFlagPath, 'c');
        end
        try
            if ~isempty(self.Future)
                cancel(self.Future);
                delete(self.Future);
            end
        % silent-by-design: 关窗/析构清理: Future 状态读取失败时按保守路径继续
        catch
        end
        self.Future = [];
        if ~wasRunning
            self.clearFlags();
        end
        if any(self.State == ["Running", "Paused"])
            self.State = "Cancelled";
        end
    end

    function clearFlags(self)
        self.dropFlag(self.CancelFlagPath);
        self.dropFlag(self.PauseFlagPath);
    end

    function dropFuture(self)
        try
            if ~isempty(self.Future), delete(self.Future); end
        % silent-by-design: 删除已失效 Future 对象无意义
        catch
        end
        self.Future = [];
    end

    function resetToConfigured(self)
        self.State = "Configured";
        self.cfg = [];
        self.dropFuture();
        self.Result = [];
        self.LastRunKind = "";
        self.clearFlags();
    end
end

methods (Access = private)
    function touchFlag(self, path, ch)
        if isempty(path), return; end
        fid = fopen(path, 'w');
        if fid > 0
            fwrite(fid, ch); fclose(fid);
        end
    end

    function dropFlag(self, path)
        try
            if ~isempty(path) && isfile(path), delete(path); end
        % silent-by-design: 标志文件删不掉 (权限/已消失) 不应让关窗失败
        catch
        end
    end
end
end
