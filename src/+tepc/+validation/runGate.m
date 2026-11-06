function G = runGate(R, A, rd)
%RUNGATE 红线门禁。每一项都必须消费可复算的数值:
%   - 不允许无条件 PASS / 把 NOT_EVALUATED 伪装成已检查;
%   - FAIL 阻断通过; NOT_EVALUATED 不阻断 DEMO 但阻断 RELEASED;
%   - 至少一项从落盘文件回读重算 (不信任内存对象), 一项对标外部登记锚点。
items = {};
tol_norm   = 1e-6;
tol_bin    = 0.02;        % 分箱矩与精确矩的相对容差
tol_cal    = 0.05;        % 仪器反演谱与真值谱的相对容差 (刻度自洽性)
tol_led    = 1e-6;        % 次级粒子能量账本闭合相对容差
anchor_rel = 0.05;        % 阻止本领锚点相对容差
S = A.spectrum;
% 降级许可只对非 VALIDATED 模式存在; 门禁 8/10/11/12 都早于原先的定义点, 故先算在这里。
modeVal = strcmp(string(R.cfg.run.mode), "VALIDATED");

Ev = [];
haveH5 = isfield(R,'eventsPath') && isfile(R.eventsPath);
if haveH5, Ev = tepc.io.readEventsH5(R.eventsPath); end

% 1) f(y) 归一: ∫f dy = 1 - 区间外份额
lost = (S.underflowWeight + S.overflowWeight)/max(S.SW_valid,eps);
items = addItem(items, 'int f dy 归一', S.intFdy, ...
    abs(S.intFdy - (1-lost)) < tol_norm, ...
    sprintf('intFdy=%.10f, 1-lost=%.10f, tol=%.1e', S.intFdy, 1-lost, tol_norm));

% 2) 分箱误差: **同群**的 binned yF vs 同群的精确 yF —— 两侧都必须只覆盖入 bin 事件。
% 与 S.yF_exact 相减会把域外/溢出事件的权重算成分箱误差 (与 bin 数无关); 而只换分子侧的
% 精确矩、继续用非重归一的 S.yF_binned (分母 = 全有效权重 SW) 同样错: 那会把 1-∫f dy 的
% 丢失份额当成误差 —— 实跑同一批事件 (in=1656, under=0, over=0) 给 1.5081e-3, 另一批
% (有 1 个溢出事件) 的 120 bin 报 3.72e-4 是"分母假象与真离散误差相消", 加到 720 bin 变
% 2.91e-3, 即"bin 越细分箱误差越大"的假象。A.spectrum_in 是 analyze 另存的
% renormInRange=true 那份 (分母 = SWin), 用它。
Si = A.spectrum_in;
dBin = abs(Si.yF_binned - S.yF_exact_inRange)/max(S.yF_exact_inRange,eps);
items = addItem(items, '分箱矩-精确矩一致', dBin, dBin < tol_bin, ...
    sprintf('rel|yF_binned-yF_exact_inRange|=%.4e (tol %.2f); intDdy=%.6f', dBin, tol_bin, S.intDdy));

if haveH5
    % 3) 能量账本闭合: Esecondary_keV = EdepGas_keV + EdepWall_keV + Eescape_keV
    %    (两边都是 keV; 下面 lhs 直接取列本身, 不乘 1e3 —— AnalyticAdapter 头注释
    %     早先写成 "Esecondary*1e3 == …", 那个 1e3 是单位笔误, 已按 16000 事件的
    %     实测残差改正。)
    lhs = Ev.ev.Esecondary_keV;
    rhs = Ev.ev.EdepGas_keV + Ev.ev.EdepWall_keV + Ev.ev.Eescape_keV;
    pos = lhs > 0;
    if ~any(pos)
        items = addItem(items, '能量账本闭合', NaN, false, ...
            "事件文件无正 Esecondary 列 (源类型或旧 schema)");
    else
        relL = max(abs(lhs(pos) - rhs(pos))./lhs(pos));
        items = addItem(items, '能量账本闭合', relL, relL < tol_led, ...
            sprintf('max rel resid %.3e / %d 事件 (tol %.1e)', relL, nnz(pos), tol_led));
    end
    % 4) 落盘回读重算 yF (不信任内存对象)
    w4 = Ev.ev.weight(:); y4 = Ev.ev.y_keV_per_um(:);
    ok4 = w4 > 0 & isfinite(y4) & y4 > 0;
    if ~any(ok4)
        items = addItem(items, 'events.h5 回读重算', NaN, false, "回读后无有效事件权重");
    else
        yF_rb = sum(w4(ok4).*y4(ok4))/sum(w4(ok4));
        dRb = abs(yF_rb - S.yF_exact)/max(S.yF_exact,eps);
        items = addItem(items, 'events.h5 回读重算', dRb, dRb < 1e-9, ...
            sprintf('yF(h5)=%.10f vs 谱=%.10f rel=%.2e', yF_rb, S.yF_exact, dRb));
    end
    % 5) 亚阈值/溢出/域外事件不得带权进入发布谱
    bad = bitand(Ev.ev.flags, uint32(2+1+256)) > 0;
    wBad = sum(Ev.ev.weight(bad));
    items = addItem(items, '无效测量零权重', wBad, ...
        A.instrument_chain && wBad == 0, ...
        sprintf('UNDER|OVERFLOW|OUT_OF_RANGE %d 个, 权重合计 %.3g; instrument_chain=%d', ...
        nnz(bad), wBad, A.instrument_chain));
    % 6) 权重账自洽: 零权重事件必须**恰好**等于"被 DAQ 拒收或测量无效"的事件并集。
    %    一个事件可同时带多个标志, 相加会双计 (实测 N=10000 时该门禁因此假失败),
    %    所以两侧都用位或并集。PILEUP(4) 同样清零权重, 必须一并计入并集,
    %    否则"零权重数 > 并集数"会让这条门禁真的失败。
    anyBad = bitand(Ev.ev.flags, uint32(8 + 4 + 2 + 1 + 256)) > 0;
    nFlag  = nnz(bitand(Ev.ev.flags, uint32(8)) > 0);
    nPile  = nnz(bitand(Ev.ev.flags, uint32(4)) > 0);
    nInv   = nnz(bitand(Ev.ev.flags, uint32(2 + 1 + 256)) > 0);
    nBoth  = nnz(bitand(Ev.ev.flags, uint32(8)) > 0 & bitand(Ev.ev.flags, uint32(2+1+256)) > 0);
    nW0    = nnz(Ev.ev.weight == 0);
    items = addItem(items, '权重账自洽', nW0, nW0 == nnz(anyBad), ...
        sprintf('零权重 %d == 拒绝∪无效 %d (死时间 %d, pileup %d, 测量无效 %d, 同时命中 %d)', ...
        nW0, nnz(anyBad), nFlag, nPile, nInv, nBoth));
    % 7) seed 三处一致 (配置 / summary / HDF5 根属性)
    seedH5 = NaN;
    try, seedH5 = h5readatt(R.eventsPath, '/', 'seed'); catch, end
    seedPv = NaN; seedSm = NaN;
    if isfield(R,'provenance') && isfield(R.provenance,'seed'), seedPv = R.provenance.seed; end
    if isfield(R,'summary')   && isfield(R.summary,'seed'),     seedSm = R.summary.seed; end
    okSeed = isfinite(seedPv) && numel(unique([seedPv, seedSm, seedH5])) == 1;
    items = addItem(items, 'seed 一致性', seedH5, okSeed, ...
        sprintf('provenance=%g summary=%g h5=%g', seedPv, seedSm, seedH5));
else
    items = addItem(items, '能量账本闭合', NaN, false, "events.h5 不存在");
    items = addItem(items, 'events.h5 回读重算', NaN, false, "events.h5 不存在");
    items = addItem(items, '无效测量零权重', NaN, false, "events.h5 不存在");
    items = addItem(items, '权重账自洽', NaN, false, "events.h5 不存在");
    items = addItem(items, 'seed 一致性', NaN, false, "events.h5 不存在");
end

% 8) 刻度自洽: 仪器反演谱 vs 真值谱 (反演链自洽性的核心要求)
if ~isempty(A.spectrum_truth) && isfinite(A.spectrum_truth.yF_exact)
    bias = abs(S.yF_exact - A.spectrum_truth.yF_exact)/A.spectrum_truth.yF_exact;
    items = addItem(items, '仪器反演-真值谱偏差', bias, bias < tol_cal, ...
        sprintf('|yF_meas-yF_true|/yF=%.4f (tol %.2f): meas=%.5f true=%.5f', ...
        bias, tol_cal, S.yF_exact, A.spectrum_truth.yF_exact), ternStr(modeVal, "FAIL", "ADVISORY"));
else
    items = addItem(items, '仪器反演-真值谱偏差', NaN, false, "未启用仪器链 (无标定结构)");
end

% 9) 外部锚点: 阻止本领对标登记册 (独立于本仓库自身输出)
try
    anc = tepc.validation.loadAnchors(tepc.io.projectRoot());
    [okA, detailA, worst] = tepc.validation.checkAnchors(anc, R.cfg, anchor_rel);
    % 不能写成 "worst rel X% / tol 5%": worst 现在是跨腿取的最大值 (逐点 S 的低能带按预注册的
    % 宽带判定, 本来就允许到 30%), 配一个单一 5% 容差会读成"超阈 5 倍却 PASS"的假绿。
    items = addItem(items, '阻止本领外部锚点', worst, okA, ...
        sprintf('%s (各腿最大偏差 %.3f%%; 每腿按各自预注册容差单独判定, 见明细)', detailA, 100*worst));
catch e
    items = addItem(items, '阻止本领外部锚点', NaN, false, ['锚点核查失败: ' e.message]);
end

% 10) 位点等效一致性
rel = R.resolve.siteConsistency.relative_mismatch;
if string(R.resolve.siteMode) == "derived"
    % rel 量化的是"请求位点 vs 当前温压下的等效位点"。derived 模式按定义不强制请求值,
    % 所以这里没有任何"被核对且通过"的量。旧实现给的是 PASS, 文案还写 "差 73.5% => 自洽",
    % 而同一批数字在 config 层已由 siteConsistency 发出 SITE_PRESSURE_MISMATCH 警告
    % (siteConsistency.m:33-38) —— 两层互相矛盾, 且发货配置就是 derived,
    % 于是该项在 VALIDATED 下也永不失败。改判未评估: 值照发 (它是有信息的实测量),
    % 但状态不承诺任何核对, 阻断仍走 release_eligible。
    okSite = true; tkSite = "NOT_EVALUATED";
    dA = sprintf(['位点由温压导出: d_t=%.4f um, lbar_t=%.4f um (请求 %.3f um, 差 %.1f%%); ' ...
        'derived 模式不强制请求值 -> 本项未评估 ' ...
        '(config 层已就同一差发 SITE_PRESSURE_MISMATCH, 不在这里改判成自洽)'], ...
        R.resolve.geom.site.d_tissue_m*1e6, R.resolve.lbar_tissue_um, ...
        R.resolve.site_requested_d_tissue_m*1e6, 100*rel);
elseif rel <= tepc.config.constants('site.mismatchRelTol')
    okSite = true; tkSite = "FAIL";
    dA = sprintf('请求位点与等效位点相对差 %.2f%% (<=%g%%)', 100*rel, 100*tepc.config.constants('site.mismatchRelTol'));
else
    okSite = false; tkSite = ternStr(modeVal, "FAIL", "ADVISORY");
    dA = sprintf('requested 模式下相对差 %.1f%% (超过阈值 %g%%): 发布 y 系统性偏差约 %.2f 倍', 100*rel, 100*tepc.config.constants('site.mismatchRelTol'), 1+rel);
end
items = addItem(items, '位点-压强一致性', rel, okSite, dA, tkSite);

% 11) 域外/表下限使用
nOOR = A.flags.outOfRange;
items = addItem(items, '参数域守卫', nOOR, nOOR == 0, ...
    sprintf('%d 事件触发表下限就地沉积或标定域外 (已打 OUT_OF_RANGE)', nOOR), ternStr(modeVal, "FAIL", "ADVISORY"));

% 12) ASSUMED 参数在 VALIDATED 模式下的发布限制
st0 = tepc.config.statusScan(R.cfg);
nAssumed = sum(strcmp(st0.status, 'ASSUMED'));
bad0 = strcmp(R.cfg.run.mode,"VALIDATED") && nAssumed > 0;
items = addItem(items, 'ASSUMED 参数发布限制', nAssumed, ~bad0, ...
    sprintf('%d 个 ASSUMED 参数; mode=%s (RESEARCH/DEMO 允许, 首页列出)', nAssumed, R.cfg.run.mode), ...
    ternStr(modeVal, "FAIL", "ADVISORY"));

% 13) 可追溯性: 哈希长度 + 产物条目数 + 清单确实在被哈希的产物里
nOut = 0; haveManifest = false; nMissing = 0;
if isfield(R,'provenance') && isfield(R.provenance,'outputs') && ~isempty(R.provenance.outputs)
    onames = fieldnames(R.provenance.outputs);
    nOut = numel(onames);
    haveManifest = any(contains(string(onames), "artifact_manifest"));
end
% 缺失产物必须区分"**按设计就不该存在**"与"**本该写出却没写上**": uq.json 在
% cfg.uq.enabled=false 时本来不产 (uq_status=DISABLED 就是为此而设)。把它算成
% 缺失, 会让每一次"关掉 UQ 的快速运行"在可追溯性门禁上假 FAIL (实测 N=400/seed=11)。
uqOff = false;
if isfield(R,'summary') && isfield(R.summary,'uq_status')
    uqOff = any(string(R.summary.uq_status) == ["DISABLED", "NOT_REQUESTED"]);
end
missAll = string({});
nOptMissing = 0;
if isfield(R,'provenance') && isfield(R.provenance,'outputs_missing')
    missAll = string(R.provenance.outputs_missing);
    if uqOff
        isUq = contains(missAll, "uq.json");
        nOptMissing = nnz(isUq);
        missAll = missAll(~isUq);
    end
end
nMissing = numel(missAll);
missTxt = "";
if nMissing > 0
    missTxt = " (" + strjoin(cellstr(missAll), ', ') + ")";
end
if nOptMissing > 0
    missTxt = missTxt + sprintf(' [按设计不产: %d 项 (UQ 未启用 -> uq.json)]', nOptMissing);
end
seedP = NaN;
if isfield(R,'provenance') && isfield(R.provenance,'seed'), seedP = R.provenance.seed; end
okTrace = numel(R.config_sha256) == 64 && nOut >= 5 && haveManifest && nMissing == 0;
items = addItem(items, '配置哈希与产物可追溯', nOut, okTrace, ...
    sprintf('sha256 长度 %d, 已哈希产物 %d 项, 清单被哈希=%d, 缺失产物 %d 项%s', ...
    numel(R.config_sha256), nOut, haveManifest, nMissing, char(missTxt)));

% 14) 参考场验证 (仓库内无实测谱/参考场数据 —— 如实报告)
items = addItem(items, '参考场验证', NaN, false, ...
    '仓库内无实测微分谱或参考辐射场数据; 禁止据此 RELEASED', "NOT_EVALUATED");

% 15) UQ 完成度: "不确定度未评估"不得被读成"有不确定度"。
%     只读 R.summary —— 两次 runGate 的唯一交集; 不读 uq.json (路径随事务提交变化),
%     也不读 provenance (只有第二轮才有)。
uqSt = "NOT_REQUESTED"; uqNote = "summary 无 uq_status 字段 (旧 schema)";
if isfield(R,'summary') && isfield(R.summary,'uq_status')
    uqSt = string(R.summary.uq_status);
    if isfield(R.summary,'uq_note'), uqNote = string(R.summary.uq_note); end
end
nFailUq = NaN;
if isfield(R,'summary') && isfield(R.summary,'u_nFailed'), nFailUq = R.summary.u_nFailed; end
nSampUq = NaN;
if isfield(R,'summary') && isfield(R.summary,'u_nSamples'), nSampUq = R.summary.u_nSamples; end
% "没有任何有效样本" 与 "个别样本失败" 不是同一件事: 前者 u(y_F) 是 NaN, 报告上就是
% 一个不存在的数, 降级水印救不了它。实测教训 —— propagateMC 里一行 cell 点索引让 5/5
% 样本静默失败, 而 DEMO 下的 INCOMPLETE 只是 WARN, 于是这个塌方一路绿灯到测试层才被发现。
nOkUq = nSampUq - nFailUq;
allDead = ~isnan(nOkUq) && nOkUq <= 0 && nSampUq > 0;
switch uqSt
    case "COMPLETE"
        tkU = "FAIL"; okU = true;      % 合规项: 不降级, 落库 PASS
        nOOD = NaN;
        if isfield(R.summary,'u_n_out_of_domain'), nOOD = R.summary.u_n_out_of_domain; end
        dU = sprintf(['UQ 完整: 样本 %s, 失败 %s, u(yF)=%s; 其中 %s 个样本越出已验证域' ...
            '(越界不剔除, 只披露: 丢掉样本会让不确定度低估)'], ...
            val2txt(getf(R.summary,'u_nSamples')), val2txt(nFailUq), ...
            val2txt(getf(R.summary,'u_yF_rel')), val2txt(nOOD));
    case {"NOT_REQUESTED","DISABLED"}
        % VALIDATED 下"根本没评估不确定度"是发布阻断项, DEMO 下经显式降级词降为非阻断
        okU = ~modeVal; tkU = ternStr(modeVal, "FAIL", "ADVISORY");
        dU = "未做不确定度评估 (cfg.uq.enabled 未开启): 报告不得给出 u(y_F)";
    otherwise
        % 发布口径: VALIDATED 模式阻断发布, RESEARCH_DEMO 只能橙色降级并在首页
        % 水印 —— 所以 DEMO 下不完整是 WARN, VALIDATED 下才是 FAIL。
        % 例外: 有效样本数为 0 不是"不完整"而是"没有结果", 任何模式都阻断。
        okU = false;
        if allDead || modeVal, tkU = "FAIL"; act = "阻断发布";
        else, tkU = "ADVISORY"; act = "只能橙色降级"; end
        if allDead
            dU = sprintf(['UQ 无任何有效样本 (%g/%g 样本失败): u(y_F) 不存在, ' ...
                '任何模式下都不得发布; %s'], nFailUq, nSampUq, char(uqNote));
        else
            dU = sprintf('UQ 不完整 (%s 下 %s): %s', char(R.cfg.run.mode), act, char(uqNote));
        end
end
items = addItem(items, 'UQ 完成度', nFailUq, okU, dU, tkU);

% 16) 参考数据域与来源: "落在插值域内" 不等于 "对标过实测数据"。
%     仓库里没有 NIST/ICRU 表格对象, 只有 2 个阻止本领锚点 + 13 个 B 级转载射程点;
%     次级带电粒子若全部落在 <1 MeV 的锚定拼接带, 谱形就主要由 ASSUMED 模型决定。
pctBand = NaN; nPos = NaN; lim = NaN; tblSha = "";
if isfield(R,'summary')
    if isfield(R.summary,'pct_events_in_ASSUMED_band'), pctBand = R.summary.pct_events_in_ASSUMED_band; end
    if isfield(R.summary,'n_events_with_secondaries'), nPos = R.summary.n_events_with_secondaries; end
    if isfield(R.summary,'stopping_assumed_band_MeV'), lim = R.summary.stopping_assumed_band_MeV; end
    if isfield(R.summary,'stopping_table_sha256_proton'), tblSha = string(R.summary.stopping_table_sha256_proton); end
end
okSha = numel(char(tblSha)) == 64;
% 哈希前缀只能截到**实际长度**: 曾无条件写 tblSha(1:12), 于是哈希缺失 (旧表、
% 或元数据未落地的表) 时门禁自己抛"索引超过数组元素的数量" —— 一个本该报告
% "参考数据缺哈希"的项, 变成了整次运行的崩溃 (实测于 N=400/seed=11)。
shaTxt = char(tblSha);
if isempty(shaTxt), shaHead = "<无哈希>"; else, shaHead = shaTxt(1:min(12, numel(shaTxt))); end
if ~isfinite(pctBand)
    tkB = "NOT_EVALUATED"; okB = false;
    dB = "没有带次级带电粒子的事件 (源类型或零沉积主导), ASSUMED 带占比无法评估";
elseif pctBand > 50
    okB = ~modeVal; tkB = ternStr(modeVal, "FAIL", "ADVISORY");   % VALIDATED 下 "多数事件靠 ASSUMED 带" 必须阻断
    fmt = '%.1f%% 事件的次级能量 < %.2g MeV, 落在自算锚定拼接带 (对官方 PSTAR 逐点实测 80keV-1MeV <=17.8%%, <80keV <=25.7%%); 表哈希 %s -- 谱形主要由 ASSUMED 模型决定, 不得宣称参考符合性';
    dB = string(sprintf(fmt, pctBand, lim, shaHead));
else
    okB = true;
    if okSha
        tkB = "ADVISORY";   % 占比合规但仍在自算带: 纯披露, 落库 WARN
    else
        % 表没登记哈希 => "无法核对本次运行用的是哪一版参考数据" 是违约而不是披露
        tkB = ternStr(modeVal, "FAIL", "ADVISORY");
    end
    dB = string(sprintf("ASSUMED 带占比 %.1f%% (<%.2g MeV / %d 个有次级的事件); 表哈希 %s...", ...
        pctBand, lim, nPos, shaHead));
end
% 必须用 + 拼接: [charVar, "literal"] 或 [stringVar, charVar] 得到的是**多元 string 数组**
% (每个操作数一个元素), 而不是"一条消息"。多元数组再被 char() 落成填充过的字符阵列,
% 消费方 (test_pipeline 的 strtrim 逐项核对) 就以 MATLAB:strtrim:TooManyDimensions 崩掉。
if ~okSha
    dB = dB + "; 阻止本领表无 sha256 登记 -> 无法核对本次运行用的是哪一版参考数据";
end
dB = dB + "; 域内!=REFERENCE; 阻止本领表哈希长度合法=" + string(okSha);
items = addItem(items, '参考数据域与来源', pctBand, okB && okSha, dB, tkB);

% ---------------- 汇总 ----------------
% 注意 (实测缺陷): items 是"装着 string 标量的 cell", 而 strcmp 对 cell 只认
% 字符向量 —— strcmp(cellOfStrings,'FAIL') 恒为 false, 于是 nFail/nWarn/nNE
% 永远等于 0, computational_gates_passed 永远为真, 水印永远是 "VALID(FOR DEMO)":
% 整套红线门禁形同无条件通过。必须先展平成 string 数组再用 == 比较。
stt = string(cellfun(@(s) char(string(s.status)), items, 'UniformOutput', false));
G = struct();
G.items = [items{:}];
nFail = nnz(stt == "FAIL"); nWarn = nnz(stt == "WARN");
nNE   = nnz(stt == "NOT_EVALUATED");
G.nFail = nFail; G.nWarn = nWarn; G.nNotEvaluated = nNE; G.backend_id = tepc.backendId();
% 两个布尔度量对象不同, 可以一真一假:
%   computational_gates_passed —— 计算门禁里有没有 FAIL;
%   release_eligible         —— 是否具备发布资格, 还要求没有任何未评估项。
G.computational_gates_passed = nFail == 0;
G.release_eligible = ~(nFail > 0 || nNE > 0);
if nFail > 0
    G.watermark = "INVALID";
elseif nWarn > 0
    G.watermark = "VALID(FOR DEMO, WARN)";
else
    G.watermark = "VALID(FOR DEMO)";
end
% released 比 release_eligible 多一道 mode 门槛: 具备发布资格是必要条件而非充分条件,
% 只有 run.mode=="VALIDATED" 的运行才谈得上 released。
G.released = G.release_eligible && strcmp(R.cfg.run.mode, "VALIDATED");
G.logPath = fullfile(rd.results, 'gates.json');
end

% ---------------- helpers ----------------
function t = val2txt(v)
if isempty(v) || (isnumeric(v) && ~isfinite(v)), t = "n/a";
elseif isnumeric(v), t = sprintf('%.4g', v);
else, t = string(v); end
end

function v = getf(s, nm)
if isfield(s, nm), v = s.(nm); else, v = NaN; end
end

function out = ternStr(c, a, b)
if c, out = a; else, out = b; end
end

function items = addItem(items, name, value, ok, detail, forced)
% 门禁状态代数: 调用方只能收窄结论, 不能放宽。
%   ok=false 的默认落库是 FAIL; 要让它不阻断, 唯一途径是显式写 ADVISORY (有意降级)
%   或 NOT_EVALUATED (无法评估)。旧写法 WARN 不在合法集合内 -> 直接报错: 那条
%   "ok=false 也落 WARN"的路径正是违约项在任何模式下都无法阻断的根因。
% 输入 token 与落库状态是两套词: items.status 恒为 PASS/FAIL/WARN/NOT_EVALUATED 四词之一
% (GUI 表格配色与 HTML 报告只认这四个)。
if nargin < 6
    if ok, st = "PASS"; else, st = "FAIL"; end
else
    tk = string(forced);
    if ~ismember(tk, ["FAIL", "ADVISORY", "NOT_EVALUATED"])
        error("tepc:validation:GateToken", ...
            '门禁末参非法: %s (合法值 FAIL / ADVISORY / NOT_EVALUATED; 未通过的检查不得经该参数降级)', char(tk));
    end
    if ok
        switch tk
            case "FAIL",          st = "PASS";
            case "ADVISORY",      st = "WARN";
            otherwise,            st = "NOT_EVALUATED";
        end
    else
        switch tk
            case "ADVISORY",      st = "WARN";
            case "NOT_EVALUATED", st = "NOT_EVALUATED";
            otherwise,            st = "FAIL";
        end
    end
end
items{end+1} = struct('name', name, 'status', string(st), ...
    'value', value, 'detail', char(string(detail))); %#ok<AGROW>
end
