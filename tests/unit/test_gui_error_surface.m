function tests = test_gui_error_surface
%TEST_GUI_ERROR_SURFACE GUI 异常根因可见性。
%   前提: 28 处 catch 里 19 处不带异常变量, 一律"一刀切改成记录"是错的 ——
%   清理型 catch 本就该静默。所以真正的契约是二选一:
%     要么捕获并留痕 (noteUiError -> 横幅含 identifier + logs/error.json),
%     要么显式标注 silent-by-design 并给理由。
%   本文件锁: (1) 未标注的裸 catch 归零; (2) 用户可见路径确实留痕;
%   (3) 后台运行前的能力预检确实拦得住"线程池写不了 HDF5"这种配置。
tests = functiontests(localfunctions);
end

function test_no_unannotated_bare_catch_in_app(tc)
root = tepc.io.projectRoot();
% 必须用 cell: 两条路径长度不同, [charA; charB] 直接抛 vertcat 维度不一致
% —— 这个测试因此**从未真正跑过** (红在脚手架上而不是判据上)。
files = {fullfile(root,'app','TEPCApp.m'), fullfile(root,'app','AppController.m'), ...
    fullfile(root,'app','TEPC3DWorkbench.m')};
bad = strings(0,1);
for i = 1:numel(files)
    txt = fileread(files{i});
    L = splitlines(txt);
    for j = 1:numel(L)
        tk = strtrim(L(j));
        % 只查**裸 catch** (不带异常变量): `catch`、`catch;`、`catch  % 注释`。
        % 四类纯字符串比较里, "catch 后跟任意空白再跟 %" 必须用 regexp 兜住: 早先只写
        % startsWith(tk,'catch %') 时, 对齐成 `catch        % …` 的行既不是 tk=="catch"
        % 也不以 "catch %" 开头, 于是被分类器直接放过 —— 标记形同虚设, 测试为绿是
        % 分类漏洞而不是判据生效。char 走 regexp 而不是 string (string 输入的形状不同)。
        isBare = tk == "catch" || startsWith(tk, "catch;") || startsWith(tk, "catch%") ...
            || ~isempty(regexp(char(tk), '^catch\s+%', 'once'));
        if ~isBare, continue; end
        % 滚动检查窗口, 不逐行新建 strings(...) 数组: 这套件在单进程里连跑 200+ 用例,
        % 前面几个 UQ 用例已把内存吃紧 (实测这里抛过 MATLAB:nomem)。
        ctxHit = false;
        for q = max(1, j-3):min(numel(L), j+1)
            if contains(L(q), "silent-by-design"), ctxHit = true; break; end
        end
        if ~ctxHit
            bad(end+1) = sprintf('%s:%d', char(string(fileparts(files{i}))), j); %#ok<AGROW>
        end
    end
end
tc.verifyTrue(isempty(bad), sprintf('存在未标注的裸 catch: %s', strjoin(bad, ', ')));
end

function test_note_ui_error_shows_identifier_and_keeps_history(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
ME = MException('tepc:test:Root', '底层原因: %s', '某字段非法');
app.noteUiError('校验失败', ME);
b = char(string(app.Banner.Text));
tc.verifyTrue(contains(b, 'tepc:test:Root'), ...
    sprintf('横幅必须含 identifier (用户才能自查/求助), 实得: %s', b));
tc.verifyTrue(contains(b, '底层原因'), '横幅必须含首要原因文本');
tc.verifyEqual(numel(app.LogErrorHistory), 1, '异常必须进历史缓冲');
tc.verifyEqual(string(app.LogErrorHistory{1}.identifier), "tepc:test:Root");
end

function test_note_ui_error_writes_error_json_with_stack(tc)
root = tepc.io.projectRoot();
rd = fullfile(tempdir, sprintf('tepc_err_%s_%d', char(string(datetime('now','TimeZone','UTC','Format','yyyyMMdd_HHmmssSSS'))), feature('getpid')));
mkdir(fullfile(rd, 'logs'));
app = TEPCApp(false);
cleanupObj = onCleanup(@() tearDown(app, rd));
app.Controller.LastRunDir = rd;
try
    error('tepc:test:Boom', '炸了');
catch e
    app.noteUiError('运行失败', e);
end
p = fullfile(rd, 'logs', 'error.json');
tc.verifyTrue(isfile(p), 'noteUiError 必须把根因落到 run 的 logs/error.json');
j = jsondecode(fileread(p));
tc.verifyEqual(string(j.identifier), "tepc:test:Boom");
tc.verifyTrue(isfield(j,'stack') && ~isempty(j.stack), '必须含堆栈 (否则根因仍不可定位)');
tc.verifyTrue(isfield(j,'stage'), '必须记录发生在哪个阶段');
end

function tearDown(app, rd)
try, delete(app); catch, end
try, rmdir(rd, 's'); catch, end
end

function test_capability_probe_blocks_unusable_pool(tc)
% 预检的产物必须是**可判定**的三态, 且"不可用"时给出可行动文案 —— 不允许
% 用"看起来能跑"的绿色横幅替代能力判断。
info = tepc.run.probeRuntime();
tc.verifyTrue(ismember(string(info.hdf5_capability), ["OK","UNSUPPORTED","NOT_EVALUATED"]));
tc.verifyTrue(ismember(string(info.v73_capability),  ["OK","UNSUPPORTED","NOT_EVALUATED"]));
tc.verifyFalse(isempty(char(info.actionable)), '无论可否用, 都必须有面向用户的说明');
if ~info.can_run_background
    tc.verifyTrue(any(contains(lower(string(info.actionable)), ...
        ["进程池","同步","小样本","池"])), ...
        sprintf('禁用后台时必须给出替代路径, 实得: %s', char(info.actionable)));
end
end

function test_start_run_refuses_without_capability(tc)
% 起跑前的守卫必须**可判定且不依赖机器状态**。旧写法真的起一个后台运行、只 cancel
% 就返回, 收尾时留一个活 future 与一次 parpool 争用 —— 套件在这里挂过 20+ 分钟 (实测)。
% 现在分两条确定性断言:
%   (1) 状态机守卫: 未 Validated 就 Run 必须拒, 且**不得改变状态** —— 拒绝后必须还能
%       改配置重试, 停在 Running 就是把界面弄死;
%   (2) 能力守卫本身由 test_capability_probe_blocks_unusable_pool 覆盖 (三态 + 可行动文案),
%       成功起跑路径由 test_gui/test_gui_run_completes 覆盖 (真跑 600 事件到完成)。
root = tepc.io.projectRoot();
c = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
ctl = AppController();
tc.verifyError(@() ctl.startRun(20), 'tepc:gui:NotValidated');
tc.verifyEqual(string(ctl.State), "Empty", ...
    '被拒的 startRun 必须一行状态都不改 (曾实测: 预检拒绝后控制器停在 Running, GUI 报废)');
% 校验通过后状态必须可用 (起跑路径的前置条件), 但仍不起真跑
ctl.readAndValidate(c, fullfile(root,'config','defaults','demo_only.json'));
tc.verifyEqual(string(ctl.State), "Validated");
end
