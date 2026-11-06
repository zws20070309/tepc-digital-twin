function htmlReport(R, outPath)
%HTMLREPORT 生成验证/结果报告 (首页固定字段)。
%   首页: 配置哈希/版本/seed/事件数/零沉积/overflow/underflow/yF/yD/Qbar/
%   气体剂量/活时间/主要不确定度/红线门禁/RESEARCH-DEMO 标签 + ASSUMED 列表。

A = R.analysis; S = A.spectrum; sumr = R.summary;
% execute/provenance 写的是 diagnostic.png; 旧代码只找 diagnostic_spectrum.png
% => 由 project.execute()+exportReport() 产出的报告**永远不含诊断图** (实测:
% runs/FINAL_evidence/results/report.html 里"诊断图"标题下是空的)。
imfile = fullfile(R.runDir.figures, 'diagnostic.png');
if ~isfile(imfile)
    imfile = fullfile(R.runDir.figures, 'diagnostic_spectrum.png');
end
imgTag = '';
if isfile(imfile)
    fid = fopen(imfile, 'r'); b = fread(fid, inf, 'uint8=>uint8'); fclose(fid);
    % fread 的第三个参数只说明"文件里是什么", 输出仍是 double; 把 double 交给
    % matlab.net.base64encode 会按每个元素 8 字节重排, 内嵌图就成了浏览器解不开的乱码
    % (实测: 230562 字节的 PNG 编出 2459328 个 base64 字符 = 解码后 1844496 字节 = 8 倍)。
    % 'uint8=>uint8' 才是"输出也要 uint8"的写法; 长度与类型在这里当场核, 不再悄悄出坏图。
    di = dir(imfile);
    if ~strcmp(class(b), 'uint8') || numel(b) ~= di(1).bytes
        error("tepc:report:ImageBytes", ...
            "诊断图字节读得不完整或类型不对: numel=%d class=%s 文件字节=%d", ...
            numel(b), class(b), di(1).bytes);
    end
    b64 = matlab.net.base64encode(b);
    % 不按列宽缩放: 诊断图的脚注是 6.5 pt (diagnosticFigure.m 的 footFs), 而 body 只有
    % 960 px —— 1887 px 的图缩到 960 px 后脚注约 6.9 px ≈ 3.3 pt, 中文已经读不出来,
    % 等于"图修好了, 报告里还是看不见"。改成原始像素 + 横向滚动容器, 脚注保持原字号。
    imgTag = sprintf(['<div style="overflow-x:auto;border:1px solid #ddd;padding:6px">' ...
        '<img src="data:image/png;base64,%s" style="max-width:none"></div>' ...
        '<p style="font-size:0.85em;color:#555">上图按原始像素显示 (脚注 6.5 pt), 视口不够宽时' ...
        '请横向滚动; 文件本体在运行目录 figures/diagnostic.png。</p>'], b64);
end

% ASSUMED 列表
assumedRows = '';
try
    st = tepc.config.statusScan(R.cfg);
    asum = st(strcmp(st.status, 'ASSUMED'), :);
    for i = 1:height(asum)
        assumedRows = [assumedRows sprintf('<li>%s (%s)</li>', asum.name{i}, asum.source{i})]; %#ok<AGROW>
    end
catch
    assumedRows = '<li>(参数状态扫描失败)</li>';
end

% 门禁表
gateRows = '';
for i = 1:numel(R.gates.items)
    it = R.gates.items(i);
    color = 'green';
    if strcmp(it.status, 'FAIL'), color = 'red'; elseif strcmp(it.status, 'WARN'), color = 'orange'; end
    if strcmp(it.status, 'NOT_EVALUATED'), color = 'blue'; end
    gateRows = [gateRows sprintf(['<tr><td>%s</td><td style="color:%s"><b>%s</b></td>' ...
        '<td>%s</td></tr>'], it.name, color, it.status, it.detail)]; %#ok<AGROW>
end

% Qbar 可能是**字符串** "NA" (execute 在 Q 缺失时写字符串, 从不写 struct)。
% 旧判据 `isstruct(sumr.Qbar)` 永假 -> 落到 sprintf('%.2f', "NA") 得到 '78.00'
% ('N' 的 ASCII) —— 报告首页凭空造出一个品质因数。
if isnumeric(sumr.Qbar) && isscalar(sumr.Qbar) && isfinite(sumr.Qbar)
    qbarStr = sprintf('%.2f', sumr.Qbar);
else
    qbarStr = char(string(sumr.Qbar));
end
% Q 的语义标签必须显示出来: summary 里的 Q_y_research_estimate 是给机器读的, 而报告
% 是给人的。拼进同一个显示串而不是新增一行, 免得表格行数与格式串再次分叉。
% 判据用数值相等而不是字符串比较: 这个字段是 logical true, 而 logical 经 string()/char()
% 的转换在本机上取什么字面量并不可靠 (实测 strcmpi 对 {"true","1"} 两个都不命中)。
isResearchQ = false;
if isfield(sumr, 'Q_y_research_estimate')
    qv = sumr.Q_y_research_estimate;
    isResearchQ = (islogical(qv) || isnumeric(qv)) && ~isempty(qv) && any(qv(:) == 1);
end
if isResearchQ
    approxTxt = "";
    if isfield(sumr, 'Q_y_approx') && ~isempty(sumr.Q_y_approx)
        approxTxt = " " + string(sumr.Q_y_approx);
    end
    qbarStr = qbarStr + " [研究估计 Q_y_research_estimate=true" + approxTxt + "]";
end
% 后端标识: execute 已经把它写进 summary, 报告只回显, 不在这里另造一份字符串。
backendTxt = '未标注 (summary 无 backend_id 字段)';
if isfield(sumr,'backend_id') && ~isempty(sumr.backend_id)
    backendTxt = char(string(sumr.backend_id));
end

% 首页补齐"算了但从来没显示"的量 (u(y_F)、剂量率、T3 剂量当量、阈下事件数)。
% 剂量一律走 tepc.report.doseLine + 剂量链的分层诚实名 (z_*/D_macro/k_norm/H_macro),
% 这里不再手写任何"累计 vs 每事件"的标签: 两处各写一份标签正是读数错 4 个量级的根因。
doseRows = '';
if hasDoseCols(sumr)
    doseRows = [doseRows sprintf( ...
        '<tr><td>剂量链 (每事件 / 每历史 / 累计 / 宏观 分列)</td><td>%s</td></tr>', ...
        char(tepc.report.doseLine(sumr, '; ')))]; %#ok<AGROW>
else
    doseRows = [doseRows sprintf( ...
        '<tr><td>剂量链</td><td style="color:red"><b>字段缺失</b> summary 里没有 D_gas_* 与 z_mean_per_history_Gy, 本报告不打印剂量 (静默省略会被读成"剂量为零")</td></tr>')]; %#ok<AGROW>
end
% 深度档行同剂量行的先例: 行名写在这里, 取值与措辞一律走 tepc.report.depthLine,
% 报告里不再手写第二份档位措辞 (两处各拼一句必然分叉)。
doseRows = [doseRows sprintf( ...
    '<tr><td>不确定度传播深度</td><td>%s</td></tr>', ...
    char(tepc.report.depthLine(sumr, '; ')))]; %#ok<AGROW>
if isfield(sumr, 'z_mean_given_valid_Gy') && isnumeric(sumr.z_mean_given_valid_Gy) ...
        && isfinite(sumr.z_mean_given_valid_Gy)
    doseRows = [doseRows sprintf( ...
        ['<tr><td>z_mean_given_valid (T2 条件口径, 分母 = sum_valid w_stat)</td>', ...
         '<td>%.3e Gy</td></tr>'], sumr.z_mean_given_valid_Gy)]; %#ok<AGROW>
end
if isfield(sumr, 'k_norm')
    doseRows = [doseRows sprintf( ...
        '<tr><td>k_norm (T3 无量纲源归一因子)</td><td>%s</td></tr>', valTxt(sumr.k_norm))]; %#ok<AGROW>
end
% 剂量当量: T3 只在源归一链完整时有定义; 无定义时印原因, 不印数 (旧实现打印的
% H_micro 是一个被源强放大过的 Sv 数, 读者无从分辨它是不是法定量)。
if isfield(sumr, 'H_macro_Sv')
    if isnumeric(sumr.H_macro_Sv) && isfinite(sumr.H_macro_Sv)
        doseRows = [doseRows sprintf( ...
            ['<tr><td>H_macro = Qbar x D_macro (T3; 非法定剂量当量, 未经参考场标定)</td>', ...
             '<td>%.3e Sv</td></tr>'], sumr.H_macro_Sv)]; %#ok<AGROW>
    else
        rs = "source_normalization_status 未标注";
        if isfield(sumr, 'source_normalization_status') && ~isempty(sumr.source_normalization_status)
            rs = string(sumr.source_normalization_status);
        end
        % 为什么不可用要说具体的 (剂量链给的 reason 已点名缺哪个因子或是否只差声明):
        % 写死"缺注量/被照面积/接受度/作用概率任一因子"会把"因子齐了但状态没声明"
        % 也说成"因子没给", 读者就去补错的地方了。
        rr = "";
        if isfield(sumr, 'D_macro_reason') && ~isempty(sumr.D_macro_reason)
            rr = " " + string(sumr.D_macro_reason);
        end
        doseRows = [doseRows sprintf( ...
            ['<tr><td>H_macro (T3 剂量当量)</td><td><b>不可用</b> 源归一链状态 = %s:%s ', ...
             '因子不齐或状态未声明时不得给出 Sv 数</td></tr>'], char(rs), char(rr))]; %#ok<AGROW>
    end
end
% 口径注记: 每层的分子/分母与"旧名保留"清单逐条上屏 (真相源 = 剂量链的 dose_note)。
dn = doseNote(A, sumr);
if ~isempty(dn)
    doseRows = [doseRows sprintf( ...
        '<tr><td>剂量口径注记 (dose_note)</td><td>%s</td></tr>', char(strjoin(cellstr(dn), ' | ')))]; %#ok<AGROW>
end

xtra = '';
if isfield(sumr,'dose_rate_uGy_h') && isnumeric(sumr.dose_rate_uGy_h) ...
        && isfinite(sumr.dose_rate_uGy_h)
    % 分子是**累计** D_gas、分母是模拟观察跨度, 且无参考场标定 -> 演示值, 不可发布。
    kind = "DEMO";
    if isfield(sumr,'dose_rate_kind') && ~isempty(sumr.dose_rate_kind)
        kind = string(sumr.dose_rate_kind);
    end
    basis = "口径未标注";
    if isfield(sumr,'dose_rate_basis') && ~isempty(sumr.dose_rate_basis)
        basis = string(sumr.dose_rate_basis);
    end
    pub = "不可发布";
    if isfield(sumr,'dose_rate_publishable') && logical(sumr.dose_rate_publishable)
        pub = "可发布";
    end
    xtra = [xtra sprintf( ...
        ['<tr><td>剂量率 (演示值 %s / 绝对值未经参考场标定: %s)</td>', ...
         '<td>%.1f uGy/h &nbsp;<small>%s</small></td></tr>'], ...
        char(kind), char(pub), sumr.dose_rate_uGy_h, char(basis))]; %#ok<AGROW>
end
if isfield(sumr,'underflow_threshold_count')
    % 这些事件仍被数字化(只置标志), 但它们**不进入发布矩** —— 写"非丢失"会让读者以为
    % 谱是完整的。这里改为直说排除, 并给出全历史真值口径下的截断偏差。
    biasTxt = '未记录';
    if isfield(sumr,'threshold_truncation_bias_rel_yF') && isfinite(sumr.threshold_truncation_bias_rel_yF)
        biasTxt = sprintf('发布 y_F 相对全历史真值偏高 %+.1f%%', 100*sumr.threshold_truncation_bias_rel_yF);
    end
    xtra = [xtra sprintf(['<tr><td>阈下事件 (仍被数字化并置标志, 但已从发布矩中排除; %s)</td>', ...
        '<td>%d / %d (%.1f%%)</td></tr>'], biasTxt, sumr.underflow_threshold_count, sumr.nEvents, ...
        100*sumr.underflow_threshold_count/sumr.nEvents)]; %#ok<AGROW>
end
if isfield(sumr,'u_yF_rel') && isfield(sumr,'u_yF_CI95') && numel(sumr.u_yF_CI95) == 2
    xtra = [xtra sprintf(['<tr><td>u(y_F) 相对 / 95%% CI (propagateMC, %d 样本)</td>', ...
        '<td>%.1f%% / [%.2f, %.2f] keV/um</td></tr>'], sumr.u_nSamples, ...
        100*sumr.u_yF_rel, sumr.u_yF_CI95(1), sumr.u_yF_CI95(2))]; %#ok<AGROW>
end
% UQ 没做完时那一行以前会**整行消失**, 读者只能看到"没有不确定度"而不是
% "不确定度未评估"。现在无论有没有值都固定印一行 u(y_F) 状态。
uqSt = "NOT_REQUESTED";
if isfield(sumr,'uq_status'), uqSt = string(sumr.uq_status); end
uqNote = "";
if isfield(sumr,'uq_note'), uqNote = string(sumr.uq_note); end
uqCol = 'green';
if uqSt ~= "COMPLETE", uqCol = 'orange'; end
if any(uqSt == ["INCOMPLETE","FAILED"]), uqCol = 'red'; end
xtra = [xtra sprintf( ...
    '<tr><td>u(y_F) 评估状态</td><td style="color:%s"><b>%s</b> %s</td></tr>', ...
    uqCol, char(uqSt), char(uqNote))]; %#ok<AGROW>
% 事件波形开关也固定印一行: "没生成"与"生成失败"对读者是两件不同的事,
% 只靠 summary.json 里的键会让人以为报告漏了一项产物。
wfSt = "ABSENT";
if isfield(sumr,'waveform_status'), wfSt = string(sumr.waveform_status); end
wfNote = "";
if isfield(sumr,'waveform_note'), wfNote = string(sumr.waveform_note); end
wfCol = 'gray';
if wfSt == "WRITTEN", wfCol = 'green'; end
if wfSt == "FAILED", wfCol = 'red'; end
% 三个已知状态词之外的任何值 (包括 summary 里根本没有 waveform_status 时的 ABSENT,
% 以及状态词被改写/拼错) 标橙色: 让"缺项"和"异常词"看起来与正常的 DISABLED 同色,
% 就等于把不一致伪装成关闭。
if ~any(wfSt == ["DISABLED", "WRITTEN", "FAILED"]), wfCol = 'orange'; end
wfSize = "";
if wfSt == "WRITTEN" && isfield(sumr,'waveform_nSub') && isfield(sumr,'waveform_n_samples')
    wfSize = sprintf(' (%d 事件 x %d 样本 -> %s)', sumr.waveform_nSub, ...
        sumr.waveform_n_samples, string(sumr.waveform_path));
end
% 失败且没能删掉的那半件 (Windows 上文件被占用时 delete 会失败) 必须在这一行显出来:
% 它会被整棵 _work 的清单递归哈希并提交, 只在 summary 里留个键等于没人会看到。
if isfield(sumr,'waveform_partial_left') && sumr.waveform_partial_left
    % ASCII 标记 [PARTIAL_LEFT] 是给机器读的: 报告是 UTF-8 文件, 而本机读取端可能按 GBK
    % 解码, 只有 ASCII 片段在两种码页下都稳定 (测试判据就匹配这个标记)。
    wfSize = wfSize + " [PARTIAL_LEFT 警告: 发布树里残留未完成的 waveforms.h5, 已被清单哈希]";
    wfCol = 'red';
end
xtra = [xtra sprintf(['<tr><td>事件波形落盘 (模拟波形, 非实测脉冲形状)</td>' ...
    '<td style="color:%s"><b>%s</b>%s %s</td></tr>'], ...
    wfCol, char(wfSt), char(wfSize), char(wfNote))]; %#ok<AGROW>
% 漂移-收集诊断行: 只在诊断跑过时印, 且把"输运参数是 ASSUMED"与"是不是分布"一起写出来。
if isfield(sumr,'drift_status') && string(sumr.drift_status) == "COMPLETE"
    dSt = "COMPLETE"; dCol = 'orange';
    dTxt = sprintf('中位 %.3g s / p90 %.3g s / 最大 %.3g s; 成形峰时间 %.3g s; 超峰事件占比 %.1f%%; 存活下限 %.3f', ...
        sumr.drift_t_collect_med_s, sumr.drift_t_collect_p90_s, sumr.drift_t_collect_max_s, ...
        sumr.drift_peaking_time_s, 100*sumr.drift_frac_over_peaking, sumr.drift_survival_min);
    if isfield(sumr,'drift_r0_degenerate') && sumr.drift_r0_degenerate
        dTxt = [dTxt ' (所有事件同一 r0: 这是单一值, 不是分布)'];
    end
    xtra = [xtra sprintf(['<tr><td>漂移-收集时间诊断 (逐事件 r0; 输运参数 ASSUMED, 不参与发布量)</td>' ...
        '<td style="color:%s"><b>%s</b> %s</td></tr>'], dCol, char(dSt), char(dTxt))]; %#ok<AGROW>
end
% 位点 requested/realized 必须同屏 (实测更正: 默认已是
% derived, 真正的缺口是 HTML 报告里没有位点行, 只有 limitations 里的一串文本)。
% provenance/审计缺一律显示 3D_NOT_AUDITED, 不得显示"3D 已验证"
if isfield(sumr,'geometry_audit')
    gv = string(sumr.geometry_audit);
    gcol = 'green'; if gv ~= "3D_AUDITED", gcol = 'red'; end
    xtra = [xtra sprintf(['<tr><td>三维/几何审计 (网格闭合+拓扑一致)</td>' ...
        '<td style="color:%s"><b>%s</b> 详见 results/geometry_audit.json</td></tr>'], ...
        gcol, char(gv))]; %#ok<AGROW>
end
if isfield(sumr,'electrode_topology') && isfield(sumr,'field_kind')
    % 电场拓扑决定增益 (同一半径比下柱对称场与球壳场的 G 相差三个量级), 报告不写
    % 拓扑就是歧义文档。
    xtra = [xtra sprintf(['<tr><td>电极拓扑 / 场类型 (增益与漂移律的唯一来源)</td>' ...
        '<td>%s &rarr; %s 对称场 (见 input/config_resolved.json)</td></tr>'], ...
        char(string(sumr.electrode_topology)), char(string(sumr.field_kind)))];
end
if isfield(sumr,'liveFrac') && isfield(sumr,'liveFrac_basis')
    % "活时间"有两种口径: 计数比与 DAQ 占用区间并集。只在 r*tau 很小时两者才接近,
    % 所以打印时把口径一起写出来, 不让读者自己猜。
    xtra = [xtra sprintf(['<tr><td>活时间占比 / 口径 (计数比 %.4f; 占用区间并集 %.4f)</td>' ...
        '<td>%s</td></tr>'], sumr.liveFrac_count, sumr.liveFrac, ...
        char(string(sumr.liveFrac_basis)))];
end
if isfield(sumr,'site_equivalence_mode') && isfield(sumr,'site_requested_d_tissue_um') ...
        && isfield(sumr,'site_realized_d_tissue_um')
    xtra = [xtra sprintf(['<tr><td>位点等效 (模式 / 请求 / 实现 / 相对差)</td>', ...
        '<td>%s / %.3f / %.3f um / %+.1f%%</td></tr>'], ...
        char(string(sumr.site_equivalence_mode)), sumr.site_requested_d_tissue_um, ...
        sumr.site_realized_d_tissue_um, ...
        100*(sumr.site_realized_d_tissue_um/max(sumr.site_requested_d_tissue_um,eps) - 1))];
end
% 谱归一化口径: y_F/y_D 的分母是**全部有效事件**, f(y)/d(y) 只覆盖域内 bin,
% 因此 ∫f dy = 1 - 阈下权重 - 超溢权重 而不是 1。不写出来就会被当成 bug。
if isfield(S,'SW_valid') && isfield(S,'SW_inBins')
    xtra = [xtra sprintf(['<tr><td>归一化口径 (精确矩=全部有效事件; f,d=域内 bin)</td>', ...
        '<td>SW_valid=%.4e / SW_in_bins=%.4e / 阈下 %.3e (%d 个) / 超溢 %.3e (%d 个)</td></tr>'], ...
        S.SW_valid, S.SW_inBins, S.underflowWeight, S.counts_underflow, ...
        S.overflowWeight, S.counts_overflow)]; %#ok<AGROW>
end
% 限制声明用 summary.limitations (execute 的唯一真相源), 不再在报告里另写一份
if isfield(sumr,'limitations') && ~isempty(sumr.limitations)
    limRows = ['<li>' strjoin(cellstr(string(sumr.limitations(:))'), '</li><li>') '</li>'];
else
    limRows = ['<li>Q(y)≈Q(L) 为近似; Qbar 不是法定剂量当量。</li>', ...
        '<li>中子通道截面权重为 ASSUMED 演示值。</li>'];
end

% 水印逐字打印, 不追加任何解释性后缀:
%   R.gates 是整次运行**唯一一次**门禁求值的结果 (求值点与理由见 tepc.run.execute 的
%   phase="manifest"~"provenance" 段), 与 results/gates.json 落盘的是同一个对象。
%   固定形状 "<b>红线门禁水印: X</b>" 是对外契约: tests/integration/
%   test_report_gate_identity.m 按 红线门禁水印: 到 </b> 之间取值, 与 gates.json 的
%   watermark 逐字比对。在这里加后缀会让那条一致性核对变成字符差异而不是结论差异。
html = sprintf([...
'<!DOCTYPE html><html><head><meta charset="utf-8"><title>TEPC Run Report</title>', ...
'<style>body{font-family:Segoe UI,Arial;max-width:960px;margin:24px auto;color:#222}', ...
'h1{font-size:1.4em} table{border-collapse:collapse;width:100%%} td,th{border:1px solid #ccc;padding:6px;font-size:0.92em;overflow-wrap:anywhere}', ...
'.banner{background:#fff3cd;border:1px solid #e0c060;padding:10px;border-radius:4px}', ...
'.invalid{background:#fdecea;border:1px solid #d05038;padding:8px}</style></head><body>', ...
'<h1>TEPC 解析基线仿真报告</h1>', ...
'<div class="banner"><b>演示参数 — 禁止绝对剂量发布 (RESEARCH/DEMO)。</b> ', ...
'解析/经验基线, 未用蒙卡输运; H_macro 不自动等同 H*(10)。</div>', ...
'<div class="%s"><b>红线门禁水印: %s</b> | <b>后端: 解析代理模型 (Fast Surrogate)</b> backend_id=%s</div>', ...
'<h2>首页固定字段</h2><table>', ...
'<tr><th>字段</th><th>值</th></tr>', ...
'<tr><td>runID</td><td>%s</td></tr>', ...
'<tr><td>配置哈希 (SHA-256)</td><td>%s</td></tr>', ...
'<tr><td>seed / 事件数 / 续跑自</td><td>%d / %d / %d</td></tr>', ...
'<tr><td>零沉积 / overflow / underflow(权重)</td><td>%s / %d / %.3e</td></tr>', ...
'<tr><td>y_F / y_D</td><td>%s / %s</td></tr>', ...
'<tr><td>Qbar</td><td>%s (%s)</td></tr>', ...
'%s', ...
'<tr><td>活时间占比</td><td>%.4f</td></tr>', ...
'<tr><td>有效样本数 n_eff</td><td>%s</td></tr>', ...
'<tr><td>int f dy / int d dy</td><td>%.8f / %s</td></tr>', ...
'%s', ...
'</table>', ...
'<h2>ASSUMED 参数 (阻止绝对剂量发布)</h2><ul>%s</ul>', ...
'<h2>红线门禁</h2><table><tr><th>项</th><th>状态</th><th>细节</th></tr>%s</table>', ...
'<h2>诊断图</h2>%s', ...
'<h2>限制声明</h2><ul>%s</ul></body></html>'], ...
tern(startsWith(string(R.gates.watermark), "INVALID"), 'invalid', 'banner'), ...
    char(string(R.gates.watermark)), ...
    backendTxt, ...
sumr.runID, sumr.config_sha256, sumr.seed, sumr.nEvents, sumr.resumed_from, ...
tepc.report.publishedText(sumr, 'zeroDepPct'), sumr.overflow_count, sumr.underflowWeight, ...
tepc.report.publishedText(sumr, 'yF'), tepc.report.publishedText(sumr, 'yD'), qbarStr, R.analysis.dose.Qnote, ...
doseRows, ...
sumr.liveFrac, tepc.report.publishedText(sumr, 'effN'), ...
S.intFdy, tepc.report.publishedText(S, 'intD'), xtra, assumedRows, gateRows, imgTag, limRows);

fid = fopen(outPath, 'w', 'n', 'UTF-8');
if fid < 0
    % 旧实现不检查 fid, 目录不存在/只读时 fwrite 静默失败,
    % 于是"报告已生成"是假的 —— 现在必须让失败可见 (execute 会据此写 INCOMPLETE)。
    error("tepc:report:WriteFailed", "无法写入报告 %s (目录不存在或只读?)", outPath);
end
n = fwrite(fid, html, 'char');
fclose(fid);
if n ~= numel(html)
    error("tepc:report:ShortWrite", "报告只写出 %d/%d 字节: %s", n, numel(html), outPath);
end
end

function out = tern(c, a, b)
if c, out = a; else, out = b; end
end

function tf = hasDoseCols(s)
% 剂量行要的全部列 (新名优先, 允许只有旧名的历史 summary): 缺一即不打印,
% 由调用方改成"字段缺失"行 —— 少一行剂量与"剂量为零"在读者眼里是两回事。
tf = (isfield(s,'D_gas_per_event_Gy') && isfield(s,'D_gas_Gy')) && ...
    (isfield(s,'z_mean_per_history_Gy') || isfield(s,'D_tissue_per_event_Gy'));
end

function t = valTxt(v)
% 数值/空值统一成短文本 (NaN 与"字段不存在"都不得印成 0)。
if isempty(v)
    t = "未产出";
elseif isnumeric(v) && isscalar(v)
    if isfinite(v), t = sprintf('%.4g', v); else, t = "NaN (该层无定义)"; end
else
    t = string(v);
end
end

function dn = doseNote(A, sumr)
%DOSENOTE 剂量口径注记的唯一真相源是剂量链的 dose_note (分层分母 + 旧名保留清单)。
%   报告不再自己写一份"累计 vs 每事件"的说明: 那正是两处各说各话的开始。
dn = strings(0, 1);
if isfield(A, 'dose_note') && ~isempty(A.dose_note)
    dn = string(A.dose_note(:));
elseif isfield(sumr, 'dose_note') && ~isempty(sumr.dose_note)
    dn = string(sumr.dose_note(:));
end
dn = dn(strlength(strtrim(dn)) > 0);
end
