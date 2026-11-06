function info = probeRuntime(varargin)
%PROBERUNTIME 运行前能力预检: 池类型 + **worker 内实测**的 HDF5/v7.3 能力。
%   动机: AppController 旧实现拿到任意 gcp('nocreate') 结果
%   就用, parpool 失败还被裸 catch 静默降级到 backgroundPool —— 而后台作业要写
%   events.h5, 线程池写不了, 于是失败发生在**跑到一半**且只留下一句"运行失败"。
%   这里把"能不能跑后台"变成运行前的显式判定, 并把依据 (实测能力位) 带回去显示。
%   Name-Value: 'Timeout_s' (探针等待上限, 默认 20), 'CreateIfMissing' (默认 false:
%   预检不产生副作用; GUI 要起池由自己决定)。
a = parseInputs(varargin{:});
info = struct();
info.created_utc = char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss'));
info.matlab_release = version('-release');
info.pool_kind = "none";
info.pool_class = "";
info.hdf5_capability = "NOT_EVALUATED";
info.v73_capability = "NOT_EVALUATED";
info.probe_detail = "";
info.can_run_background = false;
info.actionable = "";

pctLicensed = false;
try
    pctLicensed = logical(license('test', 'Distrib_Computing_Toolbox'));
catch e
    info.probe_detail = "license 查询失败: " + string(e.message);
end
info.pct_licensed = pctLicensed;

p = [];
try
    p = gcp('nocreate');
catch e
    info.probe_detail = info.probe_detail + " | gcp 不可用: " + string(e.message);
end
if isempty(p) && a.CreateIfMissing
    try
        p = parpool('Processes', 1);
        info.pool_started = true;
    catch e
        info.probe_detail = info.probe_detail + " | parpool 失败 (" + ...
            string(e.identifier) + "): " + string(e.message);
    end
end
if isempty(p)
    % 单条消息必须整体是一个 string: ["A" "B"] 是**两个元素** (只有 char 才做文本拼接),
    % 多元数组会让下游 contains(...) 返回向量而 verifyTrue 报"值必须为标量"。
    info.actionable = "尚无并行池。后台 Run 需要进程池 (PCT) 或已实测支持 HDF5 的池; " + ...
        "否则请用同步小样本运行 (直接调 tepc.run.execute, 不经过 parfeval)。";
    return
end
info.pool_class = string(class(p));
if contains(info.pool_class, "ThreadPool") || contains(info.pool_class, "ThreadGroup")
    info.pool_kind = "Threads";
elseif contains(info.pool_class, "ProcessPool") || contains(info.pool_class, "Cluster") ...
        || contains(info.pool_class, "Independent")
    info.pool_kind = "Processes";
else
    info.pool_kind = "Other";
end

% 在 worker 里实测 (客户端能力 != worker 能力, 尤其并行时)。
% R2025a 实测过的 API 事实 (本机 apiprobe 逐项试过, 别凭印象改):
%   * parallel.Future **没有** isDone / ResultsAvailable / done() —— 调它们抛
%     MATLAB:noSuchMethodOrField;
%   * wait(F, 秒) 会抛 MATLAB:parallel:future:FailedToInterpretState (即使独占机器);
%   * 可用组合是 `strcmp(string(F.State),"finished")` 轮询 + F.fetchOutputs()。
%   另: State 需要把 worker 回来的消息反序列化, 当 worker 被**其他 MATLAB 会话**抢满/
%   崩溃时它自己会抛异常 —— 那属于"探针不可用", 必须报 NOT_EVALUATED 并说清原因,
%   而不是让它冒泡成"这台机器不能后台跑"。给两轮重试。
cap = [];
lastErr = "";
% 提交**具名函数**而不是 evalin 字符串: MATLAB 的 eval/evalin 不接受"单行里的控制流
% 关键字" —— 实测 `evalin('base','try, ...; catch e, ...; end, v')` 直接抛
% MATLAB:m_illegal_reserved_keyword_usage (非法使用保留关键字 "try"), 于是探针自己
% 变成故障源 (老版本的 wait(F,t) 也是同类问题: 它在 R2025a 抛 FailedToInterpretState)。
% hdf5Probe 内部已把每一步真实读写都 try/catch 成能力位, 永远不会抛 -> 具名提交最稳。
for attempt = 1:2
    try
        f = parfeval(p, @tepc.run.hdf5Probe, 1);
    catch e
        lastErr = "parfeval 失败: " + string(e.identifier) + ": " + string(e.message);
        continue
    end
    t0 = tic;
    finished = false;
    stErr = "";
    while toc(t0) < a.Timeout_s
        try
            if strcmp(string(f.State), "finished")
                finished = true;
                break;
            end
        catch eS
            stErr = string(eS.identifier) + ": " + string(eS.message);
        end
        pause(0.4);                     % 刻意不用 wait(F,t): 见上
    end
    if ~finished
        try, cancel(f); catch, end
        if stErr == "", stErr = sprintf("探针超时 (>%.0f s)", a.Timeout_s); end
        lastErr = stErr;
        continue;
    end
    try
        cap = f.fetchOutputs();
        break;
    catch eF
        % parallel.ExecutionError 只是外壳, 真因在 .cause 里 —— 不挖出来就只能看到
        % "一个或多个 future 出现错误", 那种文案没法让人自查 (实测踩过)。
        det = string(eF.identifier) + ": " + string(eF.message);
        try
            for ic = 1:numel(eF.cause)
                cc = eF.cause{ic};
                det = det + " | cause: " + string(cc.identifier) + ": " + string(cc.message);
            end
        catch
        end
        lastErr = "探针任务抛错: " + det;
    end
end
if isempty(cap)
    info.probe_detail = info.probe_detail + " | " + lastErr;
    info.actionable = ["HDF5/v7.3 能力未评估成功 (探针任务不可用, 不等于实测不支持): " ...
        + lastErr + "。最常见原因是 worker 被其他 MATLAB 会话占满或崩溃 —— 停掉并发的 " ...
        "-batch/池后重试。禁止在此状态下启用后台 Run (那等于赌)。"];
    return
end
info.hdf5_capability = string(cap.hdf5);
info.v73_capability  = string(cap.v73);
info.probe_detail    = info.probe_detail + " | " + cap.detail;
info.can_run_background = (info.hdf5_capability == "OK") && (info.v73_capability == "OK");
if ~info.can_run_background
    info.actionable = sprintf(['当前池 (%s: %s) 的 worker 实测写不了 HDF5(%s)/v7.3(%s): ' ...
        '后台 Run 已禁用。请启动进程池 (PCT) 后重试, 或改用同步小样本运行 ' ...
        '(chunkSize 与 N 都调小)。若坚持后台, 错误会在跑到一半时才出现。'], ...
        char(info.pool_kind), char(info.pool_class), char(info.hdf5_capability), ...
        char(info.v73_capability));
else
    info.actionable = sprintf('池 %s 实测可写 HDF5/v7.3, 后台 Run 可用。', char(info.pool_kind));
end
end

function a = parseInputs(varargin)
p = inputParser;
p.addParameter('Timeout_s', 20, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('CreateIfMissing', false, @islogical);
p.parse(varargin{:});
a = p.Results;
end
