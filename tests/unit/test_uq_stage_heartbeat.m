function tests = test_uq_stage_heartbeat
%TEST_UQ_STAGE_HEARTBEAT 不确定度传播阶段的逐样本心跳。
%   该阶段过去只在入口写一次进度, 于是一个正常在算的作业可以连续几百秒不留任何
%   落盘痕迹: 外部"连续若干秒无推进即视为卡死"的判据会把它判成失效, 界面进度条
%   也会停在同一个百分比整个阶段。本文件锁三件事:
%     1) propagateMC 每完成一个样本回调一次, 序号 1..N 严格递增且不许多调;
%     2) 回调不消耗随机流 —— 同一 Seed 下带/不带回调的结果必须逐位相同,
%        否则"公共随机数配对"会被可观测性改动悄悄破坏;
%     3) execute 的 UQ 阶段确实把心跳接到了运行进度流上, 且心跳的 fraction
%        落在本阶段区间内 (越过下一阶段即破坏进度单调性)。
tests = functiontests(localfunctions);
end

function cfg = baseCfg(nS, nEv)
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
cfg.uq.enabled = true;
cfg.uq.nSamples = nS;
cfg.uq.NEvPerSample = nEv;
end

function recLine(p, frac, msg)
%RECLINE 记录一次回调。闭包不能改外层变量, 所以用追加写文件而不是内存计数。
fid = fopen(p, 'a');
if fid < 0, return; end
fprintf(fid, '%g\t%s\n', double(frac), char(string(msg)));
fclose(fid);
end

function [vals, lines] = readRec(p)
txt = string(fileread(p));
lines = strsplit(txt, newline);
lines = lines(strlength(lines) > 0);
vals = zeros(numel(lines), 1);
for k = 1:numel(lines)
    parts = strsplit(lines(k), '\t');
    vals(k) = str2double(parts{1});
end
end

function p = newRecFile(tag)
p = fullfile(tempdir, sprintf('tepc_hb_%s_%d.txt', tag, feature('getpid')));
if isfile(p), delete(p); end
end

function test_progressfcn_fires_once_per_sample(tc)
cfg = baseCfg(3, 60);
p = newRecFile('per');
cl = onCleanup(@() localDelete(p));
tepc.uq.propagateMC(cfg, 3, 'Seed', 931, 'NEvPerSample', 60, ...
    'ProgressFcn', @(k, nTot) recLine(p, k, nTot));
[vals, lines] = readRec(p);
tc.verifyEqual(numel(vals), 3, ...
    sprintf('回调次数应等于样本数 3, 实得记录:\n%s', strjoin(lines, newline)));
tc.verifyEqual(vals, (1:3)', 'AbsTol', 0, '序号必须 1..N 逐样本递增');
end

function test_callback_does_not_consume_randomness(tc)
cfg = baseCfg(3, 60);
p = newRecFile('rng');
cl = onCleanup(@() localDelete(p));
a = tepc.uq.propagateMC(cfg, 3, 'Seed', 933, 'NEvPerSample', 60);
b = tepc.uq.propagateMC(cfg, 3, 'Seed', 933, 'NEvPerSample', 60, ...
    'ProgressFcn', @(k, nTot) recLine(p, k, nTot));
tc.verifyEqual(b.summary.yF_mean, a.summary.yF_mean, 'AbsTol', 0, ...
    '带回调的 y_F 均值必须与不带时逐位相同 (公共随机数不得被可观测性改动扰动)');
tc.verifyEqual(b.summary.Dt_mean, a.summary.Dt_mean, 'AbsTol', 0);
[vals, ~] = readRec(p);
tc.verifyEqual(numel(vals), 3, '回调本身不应改变样本数');
end

function test_unknown_option_still_rejected(tc)
cfg = baseCfg(1, 50);
tc.verifyError(@() tepc.uq.propagateMC(cfg, 1, 'Seed', 5, 'NEvPerSample', 50, ...
    'ProgressFnc', @(~, ~) localDelete('')), 'tepc:uq:Args', ...
    '拼错的选项名必须继续报 tepc:uq:Args (白名单不能因新增键而放开)');
end

function test_uq_stage_is_wired_to_run_progress(tc)
% execute.m 的 UQ 阶段必须把 propagateMC 的心跳接进 prog(), 且 fraction 留在本阶段内。
src = char(fileread(fullfile(tepc.io.projectRoot(), 'src', '+tepc', '+run', 'execute.m')));
i = strfind(src, 'tepc.uq.propagateMC(cfg, nS');
tc.verifyNotEmpty(i, 'execute 的 UQ 阶段必须调用 propagateMC(cfg, nS, …)');
if isempty(i), return; end
after = src(i(1):end);
close = strfind(after, ');');
tc.verifyNotEmpty(close, 'propagateMC 调用必须能在源码里定位到收尾');
if isempty(close), return; end
call = after(1:close(1));
tc.verifyTrue(contains(call, "ProgressFcn"), ...
    sprintf('UQ 阶段没接心跳, 调用体是:\n%s', call));
tc.verifyTrue(contains(call, "prog("), ...
    '心跳必须走 prog() 而不是另开一条落盘路径 (否则 PROGRESS.json 仍不动)');
num = regexp(call, '([0-9]*\.[0-9]+)\s*\+\s*([0-9]*\.[0-9]+)\s*\*', 'tokens');
tc.verifyNotEmpty(num, '心跳的 fraction 必须是 基准 + 跨度*比例 的形式');
if ~isempty(num)
    base = str2double(num{1}{1}); span = str2double(num{1}{2});
    tc.verifyTrue(base >= 0.92 - 1e-12, sprintf('心跳起点不得低于本阶段的 0.92 (实得 %g)', base));
    tc.verifyTrue(base + span < 0.94, ...
        sprintf('心跳终点 %g 越过下一阶段 0.94, 会破坏进度单调性', base + span));
end
end

function test_throwing_callback_cannot_lose_uq(tc)
% 心跳是**可观测性而不是数据**: 回调抛错时样本必须照样跑完, 结果与不带回调逐位相同。
% 回调调用点一旦落在逐样本 try/catch 之外, 一次抛错就会掀掉整个样本循环 ——
% 症状从"少一条进度"升级成"整份不确定度没有产物", 所以这条锁钉的是那个洞。
cfg = baseCfg(3, 60);
boom = @(k, nTot) error('tepc:test:Boom', 'callback throws at %d', k);
a = tepc.uq.propagateMC(cfg, 3, 'Seed', 934, 'NEvPerSample', 60);
b = tepc.uq.propagateMC(cfg, 3, 'Seed', 934, 'NEvPerSample', 60, 'ProgressFcn', boom);
tc.verifyEqual(b.nSamples, 3, '回调抛错不得减少样本数');
tc.verifyEqual(b.summary.yF_mean, a.summary.yF_mean, 'AbsTol', 0, ...
    '回调抛错后的 y_F 均值必须与不带回调逐位相同');
tc.verifyEqual(numel(b.failed), 0, '回调抛错不得被记成"样本失败" (那是另一套词汇)');
end

function localDelete(p)
if isfile(p), delete(p); end
end
