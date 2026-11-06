function tests = test_requested_realized_site_block
%TEST_REQUESTED_REALIZED_SITE_BLOCK 请求位点与实现位点的偏差必须在门禁上可见并可阻断。
%
% 质量厚度映射 rho_g*lbar_g = rho_t*lbar_t (球形位点 lbar_t = 2*d_t/3) 只有两个自由度:
% 压强与位点直径, 二者不能同时"请求"。发货演示工况要 2 um 位点 + 1000 Pa, 两者不相容,
% 实现值只有约 0.53 um 量级, 相对差远在注册表阈值之外。本文件锁四件事:
%   1) 相对差由 siteConsistency 算出, 且能用闭式独立复算 (图形层不得重算);
%   2) 第 10 项 "位点-压强一致性" 在 site.equivalenceMode='requested' 下的模式分支:
%      RESEARCH_DEMO 给 WARN 且不进 FAIL 名单, VALIDATED 给 FAIL 且 release_eligible=false;
%   3) 判定跟着注册表阈值走, 而不是跟着模式走 (同一 VALIDATED 模式下阈值两侧必须翻转);
%   4) 阈值的接线状态反查: 两个被登记的文件要么都读注册表, 要么都留字面量, 且字面量
%      仍等于注册表值。半接线 (只改一处) 必须红。
% 测试里不出现阈值字面量: 唯一来源是 tepc.config.constants('site.mismatchRelTol')。
%
% 关于 execute 不能直接跑 VALIDATED: validate 在该模式下禁止任何 ASSUMED 参数, 而发货
% 配置带着一批 ASSUMED 项, 所以"VALIDATED 下的判定"只能拿同一份 R 改 run.mode 再调
% runGate (合成 R)。这恰好让"只改阈值一侧"的对照成立。
tests = functiontests(localfunctions);
end

%% ==================== 夹具 (名字不得以 test 开头, 首参不得叫 tc) ====================

function root = repoRoot()
root = tepc.io.projectRoot();
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(repoRoot(), 'config', 'defaults', 'demo_only.json'));
end

function tol = siteTol()
tol = double(tepc.config.constants('site.mismatchRelTol'));
end

function txt = readTextUtf8(f)
% 必须显式按 UTF-8 读: 本机默认字符集是 GBK, fileread 会把 UTF-8 中文按双字节解码并
% 吞掉紧随其后的字节, 文本反查于是静默失准。
fid = fopen(f, 'r', 'n', 'UTF-8');
assert(fid >= 0, sprintf('打不开 %s', f));
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = char(b(:).');
end

function item = gateItem(G, want)
% 按名字取门禁项; 名字不存在直接抛错 (绝不退化成按序号猜)。
k = find(string({G.items.name}) == want, 1);
if isempty(k)
    error('tepc:tests:GateItemMissing', '门禁项 "%s" 不存在 (被改名或被删)', want);
end
item = G.items(k);
end

function tf = isGateFail(G, want)
nm = string({G.items.name});
st = string({G.items.status});
tf = any(nm(st == "FAIL") == want);
end

function [cfgReq, R] = requestedFixture()
% 把位点口径切成 requested: 请求值不再被温压导出值覆写, 偏差于是成为发布谱的系统性偏差。
cfgReq = demoCfg();
cfgReq.site.equivalenceMode = 'requested';
cfgReq.uq.enabled = false;          % 不测 UQ 分支, 也不让 32 个样本拖慢本文件
R = tepc.config.resolve(cfgReq);
end

%% ==================== 1. 偏差本身 ====================

function test_demo_site_gap_exceeds_registered_threshold(tc)
tol = siteTol();
cfg = demoCfg();
R = tepc.config.resolve(cfg);
sc = R.siteConsistency;
tc.verifyEqual(cfg.gas.pressure_Pa, 1000, 'AbsTol', 0, '本用例的前提是发货工况的 1000 Pa');
tc.verifyEqual(R.site_requested_d_tissue_m, cfg.site.targetDiameter_um*1e-6, 'RelTol', 1e-12);
% 独立复算 d_t_eq = 1.5*rho_g*lbar_g/rho_t (与 siteConsistency 分开写, 互为对账)
dHand = 1.5*R.rho_g*R.geom.lbar_gas_m/cfg.site.tissueDensity_kg_m3;
tc.verifyEqual(sc.d_t_eq_m, dHand, 'RelTol', 1e-12, '实现位点必须等于质量厚度映射的闭式解');
dReq = R.site_requested_d_tissue_m;
tc.verifyEqual(sc.relative_mismatch, abs(dHand - dReq)/dReq, 'RelTol', 1e-12);
tc.verifyGreaterThan(sc.relative_mismatch, tol, ...
    sprintf('请求 2 um @1000 Pa 的相对差必须落在注册表阈值 %g 之外 (实得 %g)', ...
    tol, sc.relative_mismatch));
tc.verifyGreaterThan(sc.pressure_for_target_Pa, cfg.gas.pressure_Pa, ...
    '实现位点小于请求位点 => 达到请求值需要更高压强 (方向必须如此)');
codes = strings(0, 1);
if ~isempty(sc.issues)
    codes = string(cellfun(@(s) char(string(s.code)), sc.issues, 'UniformOutput', false));
end
tc.verifyTrue(any(codes == "SITE_PRESSURE_MISMATCH"), strjoin(cellstr(codes), ','));
end

%% ==================== 2. 第 10 项的模式分支 ====================

function test_gate_item10_warns_in_demo_and_fails_in_validated(tc)
[cfgReq, Rchk] = requestedFixture();
tc.verifyGreaterThan(Rchk.siteConsistency.relative_mismatch, siteTol(), ...
    'requested 口径下实现值与请求值必须仍可复算地不一致');
rd = fullfile(tempdir, sprintf('tepc_site_block_%d', randi(1e9)));
cleanup = onCleanup(@() rmdir(rd, 's'));
cfgReq.run.mode = 'RESEARCH_DEMO';
R = tepc.run.execute(cfgReq, 'N', 300, 'Seed', 4242, 'RunDir', rd);
A = R.analysis;
Gd = tepc.validation.runGate(R, A, R.runDir);
itemD = gateItem(Gd, '位点-压强一致性');
tc.verifyEqual(string(itemD.status), "WARN", ...
    sprintf('RESEARCH_DEMO 下 requested 位点的超阈值偏差必须是 WARN (实得 %s)', itemD.detail));
tc.verifyEqual(itemD.value, R.resolve.siteConsistency.relative_mismatch, 'RelTol', 1e-12, ...
    '该项的 value 必须是可复算的相对差本身, 不是状态词');
tc.verifyFalse(isGateFail(Gd, '位点-压强一致性'), 'DEMO 下该项不得进 FAIL 名单 (不阻断)');
tc.verifyEqual(Gd.nFail, nnz(string({Gd.items.status}) == "FAIL"));
Rv = R;
Rv.cfg.run.mode = 'VALIDATED';
Gv = tepc.validation.runGate(Rv, A, R.runDir);
itemV = gateItem(Gv, '位点-压强一致性');
tc.verifyEqual(string(itemV.status), "FAIL", ...
    sprintf('VALIDATED 下同一份事件集的第 10 项必须是 FAIL (实得 %s)', itemV.detail));
tc.verifyTrue(isGateFail(Gv, '位点-压强一致性'));
tc.verifyFalse(Gv.release_eligible, 'VALIDATED + 超阈值偏差不得具备发布资格');
tc.verifyFalse(Gv.released);
tc.verifyEqual(Gv.watermark, "INVALID");
% DEMO 的 released 也必须为 false, 但理由只能是参考场项未评估, 不是这一项。
tc.verifyEqual(string(gateItem(Gd, '参考场验证').status), "NOT_EVALUATED");
tc.verifyFalse(Gd.released);
end

%% ==================== 3. 判定跟着阈值, 不是跟着模式 ====================

function test_gate_item10_tracks_the_registered_threshold(tc)
% 同一 mode=VALIDATED, 只把相对差放到阈值两侧 => 判定必须翻转。
% 若门禁其实是"VALIDATED 一律 FAIL", 下面 PASS 侧三条红; 若阈值在代码里被写死成别的
% 数, 边界两侧的红绿就会错位。
tol = siteTol();
[cfgReq, ~] = requestedFixture();
rd = fullfile(tempdir, sprintf('tepc_site_tol_%d', randi(1e9)));
cleanup = onCleanup(@() rmdir(rd, 's'));
R = tepc.run.execute(cfgReq, 'N', 300, 'Seed', 4243, 'RunDir', rd);
A = R.analysis;
relCase = [tol*0.5; tol*0.999999; tol; tol*1.000001; tol*2];
expCase = ["PASS", "PASS", "PASS", "FAIL", "FAIL"];
for i = 1:numel(relCase)
    Rp = R;
    Rp.cfg.run.mode = 'VALIDATED';
    Rp.resolve.siteMode = 'requested';
    Rp.resolve.siteConsistency.relative_mismatch = relCase(i);
    G = tepc.validation.runGate(Rp, A, R.runDir);
    it = gateItem(G, '位点-压强一致性');
    tc.verifyEqual(string(it.status), expCase(i), ...
        sprintf('rel=%.12g (阈值 %.12g) 时第 10 项应为 %s, 实得 %s', ...
        relCase(i), tol, expCase(i), it.status));
    tc.verifyEqual(isGateFail(G, '位点-压强一致性'), expCase(i) == "FAIL", ...
        '该项是否出现在 FAIL 名单里必须与阈值判定一致');
end
% 阈值合法域本身也要有界: 退化为 0 会让任何偏差都阻断, 退化为 >=1 让门禁永不生效。
tc.verifyTrue(isscalar(tol) && isfinite(tol) && tol > 0 && tol < 1);
end

%% ==================== 4. 阈值的接线状态反查 ====================

function test_threshold_is_registered_and_used_by_both_sites(tc)
tol = siteTol();
root = repoRoot();
regPath = fullfile(root, 'docs', 'constants.json');
tc.verifyTrue(isfile(regPath), '缺 docs/constants.json');
if ~isfile(regPath), return; end
doc = jsondecode(readTextUtf8(regPath));
k = find(string({doc.constants.const_id}) == "site.mismatchRelTol", 1);
tc.verifyFalse(isempty(k), 'site.mismatchRelTol 未登记在注册表里');
if isempty(k), return; end
wired = logical(doc.constants(k).wired);
ub = doc.constants(k).used_by;
tc.verifyEqual(numel(ub), 2, sprintf('used_by 应登记两处, 实得 %d 处', numel(ub)));
files = {fullfile(root, 'src', '+tepc', '+geometry', 'siteConsistency.m'); ...
         fullfile(root, 'src', '+tepc', '+validation', 'runGate.m')};
refs = false(numel(files), 1);
for i = 1:numel(files)
    txt = readTextUtf8(files{i});
    refs(i) = contains(txt, "constants('site.mismatchRelTol')") ...
        || contains(txt, 'constants("site.mismatchRelTol")');
    msg = sprintf('%s 的阈值判定必须等于注册表值 %g (且只能有一处来源)', files{i}, tol);
    if wired
        tc.verifyTrue(refs(i), msg);
    else
        lit = numericRelLiterals(txt);
        tc.verifyTrue(numel(lit) > 0 && all(abs(lit - tol) <= 1e-12), msg);
    end
end
tc.verifyEqual(refs(1), refs(2), ...
    '两处只接线一处就是半接线: 要么都读注册表, 要么都留字面量并把 wired 保持 false');
% 第三处比较点 (meshSpec 的 site_mismatch 标志) 没有登记在 used_by 里, 但它同样在和这个
% 阈值比较, 所以只要求"读注册表 或 字面量等于注册表值", 不要求它已接线。
ms = readTextUtf8(fullfile(root, 'src', '+tepc', '+geometry', 'meshSpec.m'));
litM = numericRelLiterals(ms);
tc.verifyTrue(any(contains(ms, "constants('site.mismatchRelTol')")) ...
    || (numel(litM) > 0 && all(abs(litM - tol) <= 1e-12)), ...
    sprintf('meshSpec 的相对差比较与注册表阈值 %g 不一致', tol));
end

function lit = numericRelLiterals(txt)
% 抽出"与相对差比较的数值字面量", 形如 rel 与一个常数比大小, 或 relSite 与常数比大小。
% 只认右操作数是数值的情况: 接线成 constants(...) 之后不再命中, 由调用方分流。
% 词边界必须写 \<: MATLAB 的 regexp 方言里 \b 是退格符而不是词首边界 (实测 '\brel\w*'
% 对 "relSite > 0.05" 零命中, '\<rel\w*' 命中且不匹配 "xrelSite")。
L = strsplit(strrep(txt, sprintf('\r\n'), sprintf('\n')), newline);
lit = zeros(0, 1);
for i = 1:numel(L)
    tok = regexp(strtrim(L{i}), '\<rel\w*\s*(<=|>=|<|>)\s*([0-9][0-9.eE+-]*)', 'tokens');
    for j = 1:numel(tok)
        lit(end+1) = str2double(tok{j}{2}); %#ok<AGROW>
    end
end
lit = lit(:);
end

%% ==================== 5. 真实工况位点剖面 (加法, 不动演示工况) ====================

function test_site_matched_profile_closes_the_gap_demo_does_not(tc)
% 订正做法是**加法**: demo_only.json 的 1000 Pa / 0.531 µm 不自洽工况是被有意展示给读者的
% (本文件上面四条锁钉着它), 所以另开一个真实工况剖面, 让"位点-压强自洽"在同一套代码路径上
% 真的成立一次。三条判据缺一不可:
%   ① 剖面压强必须等于质量厚度映射反解出的 pressure_for_target_Pa (数是算出来的, 不是抄的);
%   ② requested 口径 + VALIDATED 模式下第 10 项必须 PASS, 且实现位点 ≈ 请求的 2 µm;
%   ③ 同一判据在 demo 工况上必须**不成立** —— 否则剖面是装饰, ② 会恒真。
% 只有 derived 口径不构成证据: runGate 对 derived 直接给"由温压导出 => 自洽", 那是按构造成立。
p = fullfile(repoRoot(), 'config', 'defaults', 'site_matched_3767Pa.json');
tc.verifyTrue(isfile(p), '缺少真实工况剖面 config/defaults/site_matched_3767Pa.json');
if ~isfile(p)
    return
end
tol = siteTol();
cfg = tepc.config.load(p);
R = tepc.config.resolve(cfg);
sc = R.siteConsistency;
tc.verifyGreaterThan(cfg.gas.pressure_Pa, 1000, '剖面必须离开演示压强, 否则与 demo 无差别');
tc.verifyEqual(cfg.gas.pressure_Pa, sc.pressure_for_target_Pa, 'RelTol', 1e-3, sprintf( ...
    '剖面压强 %g Pa 必须等于映射反解值 %g Pa', cfg.gas.pressure_Pa, sc.pressure_for_target_Pa));
tc.verifyLessThanOrEqual(sc.relative_mismatch, tol, sprintf( ...
    '剖面上请求位点与实现位点相对差 %g 仍在注册表阈值 %g 之外', sc.relative_mismatch, tol));
tc.verifyEqual(R.geom.site.d_tissue_m, cfg.site.targetDiameter_um*1e-6, 'RelTol', 1e-3, ...
    '实现位点必须约等于请求位点 —— 这是本剖面存在的唯一理由');
cfgR = cfg;
cfgR.site.equivalenceMode = 'requested';
rd = fullfile(tempdir, sprintf('tepc_site_prof_%d', randi(1e9)));
cleanup = onCleanup(@() rmdir(rd, 's'));
Rr = tepc.run.execute(cfgR, 'N', 300, 'Seed', 4244, 'RunDir', rd);
Rv = Rr;
% execute 跑不了 VALIDATED (validate 在该模式下禁止任何 ASSUMED 参数), 与本文件上面两条用例
% 同一手法: 拿同一份事件集改 run.mode 再调门禁。
Rv.cfg.run.mode = 'VALIDATED';
G = tepc.validation.runGate(Rv, Rr.analysis, Rr.runDir);
it = gateItem(G, '位点-压强一致性');
tc.verifyEqual(string(it.status), "PASS", sprintf( ...
    '真实工况剖面在 requested+VALIDATED 下第 10 项必须 PASS, 实得 %s | %s', it.status, it.detail));
tc.verifyLessThanOrEqual(abs(it.value), tol, '该项 value 必须是可复算的相对差本身, 不是状态词');
Rd = tepc.config.resolve(demoCfg());
tc.verifyGreaterThan(Rd.siteConsistency.relative_mismatch, tol, ...
    'demo 工况也已自洽 => 两剖面同差别, 上面那条 PASS 是恒真装饰');
end
