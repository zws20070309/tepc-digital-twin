function tests = test_gate_failability
%TEST_GATE_FAILABILITY 每一项门禁都必须"植入缺陷 => 该项变红", 降级必须显式且按模式。
%
% 门禁的 forced 参数原本同时允许两件事: 通过的项目显示成 WARN (披露), 以及未通过的项目
% 被改成 WARN (降级)。后者让"违约"和"合规"在产物里长同一个样子。存档 525 次运行的
% gates.json 里 nFail 恒为 0 (8396 项状态 census: PASS 5748 / WARN 2123 /
% NOT_EVALUATED 525 / FAIL 0), 其中仪器反演项有 64 次偏差已超注册容差、参数域守卫项
% 525 次域外计数非零 —— 两项的 ok 表达式都不含模式, 却都传 forced="WARN"。
%
% 16 项门禁的负控落点 (按 runGate.m 的登记顺序):
%   1 int f dy 归一            tests/integration/test_pipeline.m 的 intFdy 伪造段
%   2 分箱矩-精确矩一致         同上, 伪造它真正消费的同群精确矩
%   3 能量账本闭合              同上, events.h5 缺失段 (5 项齐转 FAIL)
%   4 events.h5 回读重算        同上, 伪造内存谱 yF_exact 与缺失段
%   5 无效测量零权重            同上, 缺失段
%   6 权重账自洽                同上, 缺失段
%   7 seed 一致性               同上, 缺失段
%   8 仪器反演-真值谱偏差        本文件 (VALIDATED 违约=>FAIL, DEMO 违约=>WARN)
%   9 阻止本领外部锚点           本文件只做到 checkAnchors 层 (外部参考值减半 => 判假,
%                              原表 => 判真); runGate 层的端到端负控需要能把锚点路径注进
%                              runGate 的缝, 而现在 loadAnchors 的路径由 projectRoot() 写死
%                              => 这条缝不存在, 登记为债务, 不在这里假称已覆盖
%  10 位点-压强一致性            tests/unit/test_requested_realized_site_block.m 的阈值两侧段
%  11 参数域守卫                test_pipeline.m 的域外计数植入 (DEMO=>WARN) + 本文件 (VALIDATED=>FAIL)
%  12 ASSUMED 参数发布限制       本文件
%  13 配置哈希与产物可追溯       本文件 (config_sha256 截短)
%  14 参考场验证                本文件判其结构不可失败: 无实测数据时恒 NOT_EVALUATED,
%                              阻断走 release_eligible=false 而不是 FAIL (缺外部数据, 不伪造)
%  15 UQ 完成度                tests/unit/test_artifact_transaction.m 的 VALIDATED 段
%                              + 本文件的"有效样本数为 0 在 DEMO 也须 FAIL"
%  16 参考数据域与来源           本文件
tests = functiontests(localfunctions);
end

%% ==================== 夹具 (名字不得以 test 开头, 首参不得叫 tc) ====================

function [R, A, rd] = demoWork(tag)
% 用真跑出来的 R/A 再合成模式: 配置装载阶段禁止 VALIDATED 带 ASSUMED 参数,
% 所以"VALIDATED 下的判定"只能拿同一份运行结果改 run.mode 后重调 runGate。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
cfg.run.mode = 'RESEARCH_DEMO';
rd = fullfile(tempdir, sprintf('tepc_gatefail_%s_%d', tag, randi(1e9)));
R = tepc.run.execute(cfg, 'N', 300, 'Seed', 7701, 'RunDir', rd);
A = R.analysis;
end

function [Rv, Av] = implantFour(R, A)
% 四项各自的 ok 判据都推到明确越过容差的量级, 不贴边。
% 第 8 项吃的是 A.spectrum.yF_exact 与 A.spectrum_truth.yF_exact 之差, 不是 summary 里的字段。
Av = A;
if isempty(Av.spectrum_truth)
    Av.spectrum_truth = struct('yF_exact', Av.spectrum.yF_exact * 0.5);
else
    Av.spectrum_truth.yF_exact = Av.spectrum.yF_exact * 0.5;
end
Av.flags.outOfRange = 9999;
S = R.summary;
S.pct_events_in_ASSUMED_band = 88;
Rv = R;
Rv.summary = S;
end

function item = gateItem(G, want)
idx = find(string({G.items.name}) == string(want), 1);
assert(~isempty(idx), sprintf('门禁里没有这一项: %s', want));
item = G.items(idx);
end

function tf = isFail(G, want)
tf = string(gateItem(G, want).status) == "FAIL";
end

function txt = readTextUtf8(f)
% 必须显式按 UTF-8 读: 本机默认字符集是 GBK, fileread 会吞掉紧随其后的字节。
fid = fopen(f, 'r', 'n', 'UTF-8');
assert(fid >= 0, sprintf('打不开 %s', f));
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = char(b(:).');
end

function n = countDowngradeLiterals(txt)
% 裸降级字样: addItem 调用里以逗号接一个 WARN 字面量收尾 (两种引号写法都要抓,
% 因为 addItem 收 char 与 string 都行; 注释里出现同样写法也会被算进来, 所以本仓
% 描述旧写法时不带引号)。
tok = regexp(txt, ',\s*["'']WARN["'']\s*\)', 'tokens');
n = numel(tok);
end

%% ==================== 用例 ====================

function test_implanted_violations_block_under_validated(tc)
[R, A, rd] = demoWork('val');
cleanup = onCleanup(@() rmdir(rd, 's'));
[Rv, Av] = implantFour(R, A);
Rv.cfg.run.mode = 'VALIDATED';
G = tepc.validation.runGate(Rv, Av, R.runDir);
badNames = {'仪器反演-真值谱偏差', '参数域守卫', 'ASSUMED 参数发布限制', '参考数据域与来源'};
for k = 1:numel(badNames)
    it = gateItem(G, badNames{k});
    tc.verifyEqual(string(it.status), "FAIL", ...
        sprintf('%s 违约时 VALIDATED 下必须是 FAIL, 实得 %s / %s', ...
        badNames{k}, it.status, it.detail));
    tc.verifyTrue(isFail(G, badNames{k}), 'FAIL 名单必须收到该项');
end
% 植入必须"落到该项消费的量上"才算数: 只断言状态的话, 健康工况本来就已经把这几项推到违约,
% 植入即使整个没生效用例也照样绿 (值断言是唯一能区分"植入生效"与"本来就是坏的"的证据)。
tc.verifyEqual(gateItem(G, '仪器反演-真值谱偏差').value, 1.0, 'RelTol', 1e-9, ...
    '植入真值谱=一半, bias 必须精确等于 1.0');
tc.verifyEqual(gateItem(G, '参数域守卫').value, 9999, ...
    '该项的 value 必须是植入的域外计数, 不是跑出来的原值');
tc.verifyEqual(gateItem(G, '参考数据域与来源').value, 88, ...
    '该项的 value 必须是植入的 ASSUMED 带占比');
tc.verifyGreaterThanOrEqual(G.nFail, 4, ...
    sprintf('四项违约应至少累计 4 个 FAIL, 实得 nFail=%d', G.nFail));
tc.verifyEqual(string(G.watermark), "INVALID", '水印必须跟着变成 INVALID');
tc.verifyFalse(G.computational_gates_passed, '计算门禁不得报告通过');
% 这两条在当前仓库是结构性恒 false (第 14 项无实测数据 => nNE>=1 => release_eligible 必 false),
% 保留是为了"哪天它变 true 时必须有人发现", 不是本补丁判别力的来源。
tc.verifyFalse(G.release_eligible, '有未评估项就不得具备发布资格 (结构性判据, 非本补丁的锁)');
tc.verifyFalse(G.released);
% 硬化不能牵连合规项: 归一项在健康运行里仍必须是 PASS。
it1 = gateItem(G, 'int f dy 归一');
tc.verifyEqual(string(it1.status), "PASS", sprintf('归一项被牵连了: %s', it1.detail));
end

function test_advisory_items_stay_nonblocking_under_demo(tc)
% 反例腿: 若把降级禁令做成"任何 WARN 都违规", DEMO 会全红, 这一条就会红。
[R, A, rd] = demoWork('demo');
cleanup = onCleanup(@() rmdir(rd, 's'));
[Rv, Av] = implantFour(R, A);
Rv.cfg.run.mode = 'RESEARCH_DEMO';
G = tepc.validation.runGate(Rv, Av, R.runDir);
% 与"同一份未植入结果"比 delta, 不与 0 比: 换 seed 也不会让这条变成假红。
Gc = tepc.validation.runGate(R, A, R.runDir);
badNames = {'仪器反演-真值谱偏差', '参数域守卫', 'ASSUMED 参数发布限制', '参考数据域与来源'};
for k = 1:numel(badNames)
    it = gateItem(G, badNames{k});
    tc.verifyEqual(string(it.status), "WARN", ...
        sprintf('%s 在 DEMO 下应仍是非阻断 WARN, 实得 %s', badNames{k}, it.status));
    tc.verifyFalse(isFail(G, badNames{k}), 'DEMO 下该项不得进 FAIL 名单');
end
tc.verifyEqual(G.nFail, Gc.nFail, ...
    sprintf('DEMO 下植入四项违约不得新增 FAIL (植入前 %d, 植入后 %d)', Gc.nFail, G.nFail));
tc.verifyTrue(contains(string(G.watermark), "WARN"), ...
    sprintf('降级项必须在水印里可见, 实得 %s', G.watermark));
tc.verifyFalse(contains(string(G.watermark), "INVALID"), 'DEMO 水印不应被判 INVALID');
sts = string({G.items.status});
allowed = ["PASS", "FAIL", "WARN", "NOT_EVALUATED"];
tc.verifyTrue(all(ismember(sts, allowed)), ...
    sprintf('出现词表外的状态: %s', strjoin(unique(sts(~ismember(sts, allowed))), ',')));
% 保留锁: "UQ 有效样本数为 0" 不是"不完整", 任何模式都必须 FAIL。若把降级禁令做成
% 一刀切的 ternStr(modeVal,...), 这条会在 DEMO 下退成 WARN。
Rd = R;
Rd.summary.uq_status = 'INCOMPLETE';
Rd.summary.u_nSamples = 5;
Rd.summary.u_nFailed = 5;
Rd.summary.uq_note = 'implanted: every sample failed';
Gd = tepc.validation.runGate(Rd, A, R.runDir);
itU = gateItem(Gd, 'UQ 完成度');
tc.verifyEqual(string(itU.status), "FAIL", ...
    sprintf('有效样本为 0 的 UQ 在 DEMO 下也必须是 FAIL, 实得 %s / %s', itU.status, itU.detail));
tc.verifyGreaterThanOrEqual(Gd.nFail, 1, 'allDead 必须计入 nFail');
tc.verifyEqual(string(Gd.watermark), "INVALID", '没有结果的运行不得带着降级水印出货');
% 第 14 项没有 FAIL 通道: 缺外部实测数据时它恒 NOT_EVALUATED, 阻断经 release_eligible。
itR = gateItem(G, '参考场验证');
tc.verifyEqual(string(itR.status), "NOT_EVALUATED", ...
    sprintf('参考场项必须如实报告无法评估, 实得 %s', itR.status));
tc.verifyFalse(G.release_eligible, '存在未评估项时不得具备发布资格');
% 第 10 项: rel 量的是"请求位点 vs 当前温压导出的等效位点", 而 derived 模式按定义不强制
% 请求值 —— 旧实现在这里给 PASS 并写 "差 73.5% => 自洽", 与 config 层对同一数字发出的
% SITE_PRESSURE_MISMATCH 警告 (siteConsistency.m:33-38) 直接互相矛盾, 且发货配置就是
% derived ⇒ 该项在 VALIDATED 下也永不失败。两种模式下都必须是 NOT_EVALUATED。
itS = gateItem(G, '位点-压强一致性');
tc.verifyEqual(string(itS.status), "NOT_EVALUATED", ...
    sprintf('DEMO 下 derived 位点项必须如实报未评估, 实得 %s / %s', itS.status, itS.detail));
Rn = R;
Rn.cfg.run.mode = 'VALIDATED';
Gn = tepc.validation.runGate(Rn, A, R.runDir);
itSn = gateItem(Gn, '位点-压强一致性');
tc.verifyEqual(string(itSn.status), "NOT_EVALUATED", ...
    sprintf('VALIDATED 下 derived 位点项也不得冒充通过, 实得 %s', itSn.status));
end

function test_traceability_gate_fails_on_thin_provenance(tc)
[R, A, rd] = demoWork('trace');
cleanup = onCleanup(@() rmdir(rd, 's'));
it0 = gateItem(tepc.validation.runGate(R, A, R.runDir), '配置哈希与产物可追溯');
tc.verifyEqual(string(it0.status), "PASS", sprintf('健康运行的可追溯项应为 PASS, 实得 %s', it0.detail));
Rk = R;
Rk.config_sha256 = 'deadbeef';
Gk = tepc.validation.runGate(Rk, A, R.runDir);
itk = gateItem(Gk, '配置哈希与产物可追溯');
tc.verifyEqual(string(itk.status), "FAIL", ...
    sprintf('配置哈希被截短后该项必须 FAIL (任何模式), 实得 %s / %s', itk.status, itk.detail));
tc.verifyTrue(isFail(Gk, '配置哈希与产物可追溯'), 'FAIL 名单必须收到可追溯项');
end

function test_anchor_gate_has_teeth(tc)
% 第 9 项此前只有"名字"没有负控: 外部参考值整列减半后核查必须判假 (植入腿),
% 未改动的登记册必须判真 (正控) —— 后者同时复跑"电子阻止修正后锚点仍 PASS"。
% 幅度要算准: worst 现在是**跨腿最大值** —— 未改动时实测 0.256929, 它由官方 PSTAR 88 点表
% 的 <80 keV 逐点带 (25.69%) 决定, 点锚定腿本身只有 0.67% (见 checkAnchors 头注释)。
% 参考值列**翻倍**只把点锚定腿推到 ~0.497 (贴不住 0.5 门, 更压不过 0.2569 的地板),
% **减半**推到 ~1.014（z855 的两个锚点现算: 45.947/22.835−1=1.0121, 1.873/0.930−1=1.0140） —— 所以植入用减半, 判据用 >0.9: 地板 0.2569 与植入 1.014 之间留得开。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
anc = tepc.validation.loadAnchors(root);
tc.verifyGreaterThan(height(anc), 0, '锚点表为空则本用例恒绿, 先让它红');
[okRef, ~, worstRef] = tepc.validation.checkAnchors(anc, cfg, 0.05);
tc.verifyTrue(okRef, sprintf('未篡改的登记册必须通过, 实得 worst=%.6g', worstRef));
a2 = anc;
a2.value = a2.value * 0.5;
[okBad, ~, worstBad] = tepc.validation.checkAnchors(a2, cfg, 0.05);
tc.verifyFalse(okBad, '外部参考值减半后核查必须判假 (锚点不是装饰)');
tc.verifyGreaterThan(worstBad, 0.9, sprintf('减半应把最大相对偏差推到 >0.9, 实得 %.6g', worstBad));
end

function test_thin_reference_hash_blocks_under_validated(tc)
% 反例来自复核代理: 占比合规 (<=50) 但参考表没登记哈希时, 该项的 ok 同样是假的。
% 若把这一支无条件写成 ADVISORY, VALIDATED 下就还是"违约却不阻断" —— 本用例钉住它。
[R, A, rd] = demoWork('sha');
cleanup = onCleanup(@() rmdir(rd, 's'));
S = R.summary;
S.pct_events_in_ASSUMED_band = 10;
S.stopping_table_sha256_proton = "";
Rv = R;
Rv.summary = S;
Rv.cfg.run.mode = 'VALIDATED';
G = tepc.validation.runGate(Rv, A, R.runDir);
it = gateItem(G, '参考数据域与来源');
tc.verifyEqual(string(it.status), "FAIL", ...
    sprintf('占比合规但无登记表哈希时, VALIDATED 下必须是 FAIL, 实得 %s / %s', it.status, it.detail));
Rm = Rv;
Rm.cfg.run.mode = 'RESEARCH_DEMO';
Gm = tepc.validation.runGate(Rm, A, R.runDir);
itM = gateItem(Gm, '参考数据域与来源');
tc.verifyEqual(string(itM.status), "WARN", ...
    sprintf('同一份数据在 DEMO 下仍是披露性降级, 实得 %s', itM.status));
% 哈希在位且占比合规时, 这一支仍必须是 WARN (ASSUMED 带份额不许变绿)
S2 = R.summary;
S2.pct_events_in_ASSUMED_band = 10;
Rp = R;
Rp.summary = S2;
Rp.cfg.run.mode = 'VALIDATED';
Gp = tepc.validation.runGate(Rp, A, R.runDir);
itP = gateItem(Gp, '参考数据域与来源');
tc.verifyEqual(string(itP.status), "WARN", ...
    sprintf('哈希在位时 VALIDATED 下仍是披露性 WARN (不得变绿), 实得 %s', itP.status));
end

function test_no_bare_downgrade_literal_in_gate_source(tc)
% 正控: 现在的源码里, addItem 的末参不能是裸的降级字面量。
f = fullfile(tepc.io.projectRoot(), 'src', '+tepc', '+validation', 'runGate.m');
n = countDowngradeLiterals(readTextUtf8(f));
tc.verifyEqual(n, 0, ...
    sprintf('runGate.m 里出现 %d 处裸降级字面量末参; 违约项只能经显式降级词落地', n));
end

function test_downgrade_literal_scanner_has_a_teeth_leg(tc)
% 反例腿: 上面的静态判据必须能抓到重新种回去的那一行, 否则它是恒绿装饰。
clean = "items = addItem(items, 'x', v, v < tol, sprintf('%.3f', v));";
bad = "items = addItem(items, 'x', v, v < tol, 'd', ""WARN"");";
badQ = "items = addItem(items, 'x', v, v < tol, 'd', 'WARN');";
modegated = "items = addItem(items, 'x', v, v < tol, 'd', ternStr(modeVal, ""FAIL"", ""ADVISORY""));";
tc.verifyEqual(countDowngradeLiterals(clean), 0, '无末参的调用不该被判为降级');
tc.verifyEqual(countDowngradeLiterals(bad), 1, '裸降级写法必须被扫到');
tc.verifyEqual(countDowngradeLiterals(badQ), 1, '单引号的裸降级写法同样必须被扫到');
tc.verifyEqual(countDowngradeLiterals(modegated), 0, '按模式选的三目式不是裸降级');
end
