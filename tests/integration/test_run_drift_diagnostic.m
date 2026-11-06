function tests = test_run_drift_diagnostic
%TEST_RUN_DRIFT_DIAGNOSTIC 漂移-收集诊断接线的产物级判据 (driftCollect 的消费者)。
%   这个模块以前是零调用点: 代码在库里但没人跑, 于是它的对错对交付毫无影响。接线成
%   诊断之后要锁四件事, 每件都可失败:
%     1 真被调用       summary 里出现 drift_* 键且 status=COMPLETE、数值有限且为正。
%     2 用的是逐事件 r0 起始半径模式 sampled 下 r0 有散布 => 收集时间必须有散布,
%                      且 drift_r0_degenerate=false; fixed 模式反过来必须报"同一个数、
%                      不是分布"。统一半径的实现无法同时满足这两条。
%     3 峰时刻量级     drift_peaking_time_s 必须是微秒量级 (成形峰), 落在 [1e-9,1e-3] s。
%                      它防的是一个具体的错: 把冲激响应的**幅度** hpeak 当峰位索引乘 Ts
%                      (那样会得到 ~5e5 s 这种荒谬值, 而数值仍然"有限且为正")。
%     4 不扰动发布量   删掉 gas.transport 再跑一次: 诊断必须 SKIPPED, y_F 逐位不变,
%                      事件文件里**每个数据集的值**逐位不变, 且根属性除点名的两项
%                      (config_sha256 运行身份、created_utc 墙钟) 外没有第二处不同,
%                      而那两项确实不同。诊断就是诊断, 它不许碰任何已发布数值。
%                      (不比 events.h5 的文件字节: config_sha256 是它的根属性, 换配置
%                       必然换身份哈希, 字节不同是设计而不是泄漏 —— 第一版判据正搞错过这点。)
%   诚实边界: 输运参数 (饱和漂移速度、半饱和 E/N、附着系数) 是配置里标 ASSUMED 的
%   演示级值, 可核对的电子输运关系需要外部数据表; 因此本文件只核"接线与量级",
%   不核时间域精度, 也不据此得任何装置符合性结论。
tests = functiontests(localfunctions);
end

function test_diagnostic_runs_and_is_inert(tc)
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
cfg.uq.enabled = false;
cfg.waveform.enabled = false;
cfg.run.chunkSize = 50;
td = fullfile(tempdir, sprintf('tepc_drift_%d', randi(1e9)));
mkdir(td);
cleanupDir = onCleanup(@() rmdir(td, 's'));  %#ok<NASGU>

% --- 1) 开着诊断跑一次 --------------------------------------------------------
RA = tepc.run.execute(cfg, 'N', 60, 'Seed', 5150, 'RunDir', fullfile(td, 'with'));
sA = readSummary(tc, fullfile(td, 'with', 'results', 'summary.json'));
tc.verifyEqual(string(sA.drift_status), "COMPLETE", sprintf( ...
    '诊断没跑起来 (实得 %s; note=%s)', string(sA.drift_status), string(sA.drift_note)));
tc.verifyGreaterThan(sA.drift_n, 0, 'drift_n=0: 一个事件都没算, 后面的数都是空的');
v = double([sA.drift_t_collect_med_s, sA.drift_t_collect_p90_s, sA.drift_t_collect_max_s, ...
    sA.drift_r0_min_m, sA.drift_r0_max_m, sA.drift_N_density_m3]);
tc.verifyTrue(all(isfinite(v)) && all(v > 0), sprintf( ...
    '诊断输出存在非有限或非正值: %s', strjoin(string(v), ', ')));
tc.verifyLessThanOrEqual(sA.drift_survival_min, 1);
tc.verifyGreaterThanOrEqual(sA.drift_survival_min, 0);
% 披露必须自己说清"参数是 ASSUMED"与"不参与发布量", 否则读者会把它当标定结果
note = string(sA.drift_note);
tc.verifyTrue(contains(note, "ASSUMED"), '漂移诊断的披露里没写 ASSUMED 参数口径');

% --- 3) 峰时刻量级 (挡住"把幅度当索引"这类具体错误) ----------------------------
tPeak = double(sA.drift_peaking_time_s);
tc.verifyTrue(tPeak >= 1e-9 && tPeak <= 1e-3, sprintf( ...
    'drift_peaking_time_s=%.6g s 不在 [1e-9, 1e-3] s 的成形峰量级内: 这不是峰时刻', tPeak));
tc.verifyLessThanOrEqual(sA.drift_frac_over_peaking, 1);

% --- 4) 拿掉诊断输入: 必须 SKIPPED, 且发布量逐位不变 ---------------------------
cfgOff = cfg;
cfgOff.gas = rmfield(cfgOff.gas, 'transport');
RB = tepc.run.execute(cfgOff, 'N', 60, 'Seed', 5150, 'RunDir', fullfile(td, 'without'));
sB = readSummary(tc, fullfile(td, 'without', 'results', 'summary.json'));
tc.verifyEqual(string(sB.drift_status), "SKIPPED", sprintf( ...
    '缺 gas.transport 却仍给出诊断状态 %s: 缺参数就该跳过, 不许猜默认值', ...
    string(sB.drift_status)));
tc.verifyEqual(sB.yF_keV_um, sA.yF_keV_um, 'AbsTol', 0, sprintf( ...
    '诊断的输入变化改变了发布值 y_F: %.17g vs %.17g —— 诊断吃进了计算链', ...
    sB.yF_keV_um, sA.yF_keV_um));
pa = fullfile(td, 'with');  pb = fullfile(td, 'without');
% events.h5 的**字节**在这里本来就不同: config_sha256 是它的根属性 (设计上就带运行身份,
% 见 test_pipeline 对"根属性含 config_sha256"的锁), 而删掉 gas.transport 必然换身份哈希。
% 所以"只读旁路"不能拿文件字节当判据, 只能打在数据与其余属性上:
%   * 每个数据集的值逐位相同;
%   * 根属性除 config_sha256 外没有第二处不同 (否则诊断往文件里塞了别的东西)。
[badDs, badAt, diffAllowed] = compareEventFiles(fullfile(pa, 'events', 'events.h5'), ...
    fullfile(pb, 'events', 'events.h5'));
tc.verifyEmpty(badDs, sprintf('诊断输入变化后事件数据不再逐位相同: %s', strjoin(badDs, ', ')));
tc.verifyEmpty(badAt, sprintf(['根属性里除点名放行的两项之外还有 %d 处不同: %s —— ' ...
    '诊断不该往事件文件里写任何东西'], numel(badAt), strjoin(badAt, ', ')));
% 放行表必须是"点名"而不是"有差异就算了": 这两项确实该不同, 否则说明两次跑的其实是
% 同一份产物 (那上面所有"相同"就都是自证)。
tc.verifyEqual(sort(diffAllowed), ["config_sha256", "created_utc"], sprintf( ...
    '两次运行里 config_sha256/created_utc 没有恰好这两项不同 (实得 %s): 对照失效', ...
    strjoin(diffAllowed, ', ')));
tc.verifyEqual(tepc.io.hashFile(fullfile(pa, 'results', 'spectrum.csv')), ...
    tepc.io.hashFile(fullfile(pb, 'results', 'spectrum.csv')), ...
    'spectrum.csv 的字节随诊断输入变了 (谱文件里不含运行身份, 字节就该相同)');
% 报告页: 跑过时有一行, 跳过时不许假装有一行
ha = fileread(fullfile(pa, 'results', 'report.html'));
tc.verifyTrue(contains(ha, '漂移-收集时间诊断'), '诊断跑过了, 报告里却没有这一行');
end

function test_per_event_radius_reaches_the_model(tc)
% 逐事件 r0 是否真的进了漂移模型: 两种起始半径模式的对照。
root = tepc.io.projectRoot();
base = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
base.uq.enabled = false;
base.waveform.enabled = false;
base.run.chunkSize = 50;
td = fullfile(tempdir, sprintf('tepc_driftmode_%d', randi(1e9)));
mkdir(td);
cleanupDir = onCleanup(@() rmdir(td, 's'));  %#ok<NASGU>

cFix = base;   cFix.detector.avalancheStartMode = 'fixed';
cSmp = base;   cSmp.detector.avalancheStartMode = 'sampled';
cSmp.detector.startPositionJitter = 0.35;      % 对数正态相对展宽, 让 r0 真的散开
RF = tepc.run.execute(cFix, 'N', 60, 'Seed', 5151, 'RunDir', fullfile(td, 'fixed'));
RS = tepc.run.execute(cSmp, 'N', 60, 'Seed', 5151, 'RunDir', fullfile(td, 'sampled'));
SF = readSummary(tc, fullfile(td, 'fixed', 'results', 'summary.json'));
SS = readSummary(tc, fullfile(td, 'sampled', 'results', 'summary.json'));
tc.verifyEqual(string(SF.drift_status), "COMPLETE");
tc.verifyEqual(string(SS.drift_status), "COMPLETE");
% fixed: 所有事件同一个 r0 —— 诊断必须自己承认这不是分布
tc.verifyTrue(logical(SF.drift_r0_degenerate), ...
    'fixed 起始半径模式下诊断没标 degenerate: 读者会把单一值当分布读');
tc.verifyEqual(SF.drift_r0_min_m, SF.drift_r0_max_m, 'AbsTol', 0, ...
    'fixed 模式却出现 r0 散布: 起始半径模式的口径变了');
% sampled: r0 有散布, 收集时间就必须有散布 (统一半径的实现到这里会露馅)
tc.verifyFalse(logical(SS.drift_r0_degenerate), ...
    'sampled 模式却报 degenerate: 逐事件 r0 没进诊断');
tc.verifyGreaterThan(SS.drift_r0_max_m, SS.drift_r0_min_m * 1.01, sprintf( ...
    'sampled 模式 r0 几乎没散开 (%.3e..%.3e): 对照失效', SS.drift_r0_min_m, SS.drift_r0_max_m));
tc.verifyGreaterThan(SS.drift_t_collect_max_s, SS.drift_t_collect_med_s * 1.01, sprintf( ...
    'r0 散开了而收集时间没散 (med %.4g max %.4g): 诊断仍在用某个统一半径, 逐事件 r0 没被消费', ...
    SS.drift_t_collect_med_s, SS.drift_t_collect_max_s));
end

function test_driftcollect_physics_monotonicity(tc)
% 直接打 driftCollect: 附着与起始半径的两条单调性, 以及温度守卫。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
Rs = tepc.config.resolve(cfg);
fld = Rs.field;
T = cfg.gas.temperature_K;
kB = 1.380649e-23;
gas0 = struct('N_density', cfg.gas.pressure_Pa/(kB*T), ...
    'vd_max', cfg.gas.transport.vd_max_m_s.value, ...
    'vd_half_Ed', cfg.gas.transport.vd_half_Ed_Vm2.value, ...
    'eta_attach', cfg.gas.transport.eta_attach_per_m.value);
opts = struct('temperature_K', T, 'nStepsMax', 40000);
oNear = tepc.detector.driftCollect(struct('r0', 2*fld.a, 'N0', 1, 't0', 0), fld, gas0, [], opts);
oFar  = tepc.detector.driftCollect(struct('r0', min(0.9*fld.b, 40*fld.a), 'N0', 1, 't0', 0), ...
    fld, gas0, [], opts);
tc.verifyGreaterThan(oFar.t_collect_s, oNear.t_collect_s * 1.05, sprintf( ...
    '起始半径更大的簇收集时间反而不长 (%.3e vs %.3e): 漂移方向或场取值不对', ...
    oFar.t_collect_s, oNear.t_collect_s));
gasA = gas0;  gasA.eta_attach = 50;          % 1/m, 人为加附着
oAtt = tepc.detector.driftCollect(struct('r0', 4*fld.a, 'N0', 1, 't0', 0), fld, gasA, [], opts);
oNoA = tepc.detector.driftCollect(struct('r0', 4*fld.a, 'N0', 1, 't0', 0), fld, gas0, [], opts);
tc.verifyLessThan(oAtt.survival, oNoA.survival, '有附着时的存活份额必须低于无附着');
tc.verifyEqual(oNoA.survival, 1, 'AbsTol', 0, 'eta=0 时存活份额必须恰为 1 (不该有别的损耗)');
tc.verifyError(@() tepc.detector.driftCollect(struct('r0', 4*fld.a, 'N0', 1, 't0', 0), ...
    fld, gas0, [], struct('nStepsMax', 40000)), 'tepc:drift:MissingTemperature', ...
    '温度不再必填: 硬编码温度会静默用错 (旧缺陷)');
end

% ==================== helpers (都有输出参数, 不被静态计数当用例) ====================

function [badDs, badAt, diffAllowed] = compareEventFiles(pA, pB)
% 逐数据集比值 + 比根属性。三个口径细节: h5info 在组下列出的是**组内短名**, 而 h5read
% 要求带前导 '/' 的完全路径; 属性名不是合法 MATLAB 字段名, 所以用"名字数组 + 值 cell"
% 平行存放, 不转结构体; 放行的属性一律**点名** (config_sha256 = 运行身份, created_utc =
% 墙钟时刻, 两次独立运行本就该不同), 不写"有差异就算了"。
allowed = ["config_sha256", "created_utc"];
badDs = strings(0, 1);  badAt = strings(0, 1);  diffAllowed = strings(0, 1);
na = eventDatasetNames(pA);  nb = eventDatasetNames(pB);
if isempty(na) || isempty(nb)
    badDs = "拿不到 /events 组的数据集清单 (两态都要有)";
    return
end
if ~isequal(sort(na), sort(nb))
    badDs = "数据集名字集合不同";
    return
end
for i = 1:numel(na)
    a = h5read(pA, '/events/' + na(i));
    b = h5read(pB, '/events/' + na(i));
    if ~isequaln(a, b) || ~isequal(class(a), class(b))
        badDs(end + 1) = na(i); %#ok<AGROW>
    end
end
[an, av] = rootAttrs(pA);  [bn, bv] = rootAttrs(pB);
names = union(an, bn);
for i = 1:numel(names)
    ia = find(an == names(i), 1);  ib = find(bn == names(i), 1);
    if isempty(ia) ~= isempty(ib)
        differs = true;
    else
        differs = ~isequaln(av{ia}, bv{ib});
    end
    if any(allowed == names(i))
        if differs
            diffAllowed(end + 1) = names(i); %#ok<AGROW>
        end
        continue
    end
    if differs
        badAt(end + 1) = names(i); %#ok<AGROW>
    end
end
end

function nm = eventDatasetNames(p)
info = h5info(p);
if isempty(info.Groups), nm = strings(0,1); return; end
g = string({info.Groups.Name});
k = find(g == "/events", 1);
if isempty(k), nm = strings(0,1); return; end
nm = string({info.Groups(k).Datasets.Name}');
end

function [names, vals] = rootAttrs(p)
info = h5info(p);
a = info.Attributes;
names = string({a.Name}');
vals = cell(1, numel(a));
for i = 1:numel(a)
    vals{i} = a(i).Value;
end
end

function s = readSummary(tc, p)
tc.verifyTrue(isfile(p), sprintf('缺 summary.json: %s', p));
fid = fopen(p, 'r', 'n', 'UTF-8');
b = fread(fid, inf, 'char=>char');
fclose(fid);
s = jsondecode(b(:)');
end
