function s = writeWaveformsH5(path, ids, traces, meta)
%WRITEWAVEFORMSH5 事件波形时序落盘 (独立文件) + 只由该时序决定的标量。
%   s = writeWaveformsH5(path, ids, traces, meta)
%     ids    [nSub x 1]          事件号 (数值列向量, 落盘为 uint64; 必须互不相同)
%     traces [nSub x nSamples]   成形并叠加串联噪声之后的电压时序 [V] —— 与
%                                tepc.electronics.simulate 里算 peak/触发/ADC 所用的
%                                那条 v 是同一个量 (单次一事件调用时即 aux.
%                                waveform_first_event), 落盘的是它本身, 不是它的摘要
%     meta   struct
%       必填: Ts_s  (>0 采样间隔 [s]),
%             cfg   (取其 electronics.adc 四个量化参数, 与 tepc.electronics.adc 同一实现),
%             hsign (±1 成形链极性, 峰定义与 tepc.electronics.peakSigned 同一实现)
%       可选: seed, config_sha256, matlab_release, created_utc, scale_V (显式定标),
%             Nwin (收集窗样本数, 只用于把噪声地板规则写进根属性),
%             event_scalars = struct(peak_V, t_trigger_s, adc_code) —— 来自事件表的
%             摘要列。**它只用于交叉核对** (算偏差写进根属性), 绝不参与落盘标量的计算:
%             "标量是波形的函数"这件事必须由本函数内部复算兑现, 不接受外部喂进来的值。
%
%   文件内数据集 (组 /waveform; 与 events.h5 的固定 23 列事件表是两个文件、两份契约 ——
%   事件表是"一事件一行"的定宽列, 波形是"一事件一行、列数=采样点数"的定长矩阵,
%   硬塞进同一张表会让两种形状共用同一套读取与门禁口径, 所以另立文件):
%     samples      int16  [nSub x nSamples]  量化后的波形, 电压 = samples*scale_V
%     event_id     uint64 [nSub x 1]
%     Ts_s         double [1 x 1]            采样间隔 [s] (同时写根属性)
%     scale_V      double [1 x 1]            量化定标 [V/LSB], 默认取 2 的幂
%     peak_V       double [nSub x 1]          由 samples 反量化后复算的带符号主峰
%     t_trigger_s  double [nSub x 1]          由 samples 复算的峰位时刻 = argmax*Ts
%     adc_code     int32  [nSub x 1]          由 peak_V 经 tepc.electronics.adc 复算的码
%     integral_Vs  double [nSub x 1]          由 samples 复算的矩形积分 = sum(v)*Ts
%   根属性: schema_version, producer, data_provenance, quantization, replay_recipe,
%     n_sub, n_samples, Ts_s, scale_V, max_abs_V, hsign, adc_bits, adc_fullScale_V,
%     adc_inl_lsb, adc_range2Gain, baseline_applied, baseline_rule,
%     条件属性: baseline_n_tail_short (仅当调用方给出 Nwin), seed / config_sha256 /
%     matlab_release / created_utc / waveWindow_s (仅当给出), xcheck_* (仅当给出 event_scalars)。
%
%   回放配方 (本函数是唯一的复算实现; readWaveformsH5 刻意不复算):
%     v   = double(samples)*scale_V;
%     [pk, ipk] = tepc.electronics.peakSigned(v(:), hsign);
%     t   = ipk*Ts_s;   integral = sum(v)*Ts_s;   code = tepc.electronics.adc(abs(pk), cfg)
%   readWaveformsH5 只交出 samples / v 和回放所需的 hsign 与 Ts_s, 不替调用方算标量 ——
%   否则"复算"就成了读回器的一次内部约定, 第三方拿不到可比的对象。单测按上面这四行
%   自己复算一遍并与盘上标量逐位比对, 所以复算式在这里与在单测里各有一份, 而
%   replay_recipe 属性是同一套式的机器可读文本 (三份表达式, 一套语义)。
%   cfg 可由本文件的 adc_* 属性重建 (见 readWaveformsH5), 因此"回放"不需要仓库里的
%   JSON 也能独立复算 —— 第三方拿到这一个文件就能查证标量与波形是否相符。
%
%   量化为什么对"逐位比对"是无损的:
%     落盘的四个标量都是由**盘上整数**经同一串确定性算术得出的 (double(int16)*scale_V
%     的乘法、max 的取首个最大位置、sum 的固定求和顺序、adc 的 floor/比较), 所以只要
%     操作数逐位相同、且求峰与求和的**形状与次序**相同, 结果就可要求逐位相同 (AbsTol 0)。
%     形状是契约的一部分而不是实现细节: 复算一律按"取第 j 行、求峰前转列、积分对行向量
%     求和"做 (与写出侧一致)。本机上行向量求和与其转置逐位相同, 但浮点求和的次序由实现
%     决定、不作为格式承诺, 所以只要求"与写出侧同形状", 不把它写进 replay_recipe。
%     scale_V 默认取 2 的幂, 于是 double(int16)*scale_V 是纯指数移位: 反量化本身
%     不引入舍入, 落盘的 peak_V 就是"这个波形的峰"而不是"原模拟量的峰"。信息损失
%     只在写入侧的 round() (量级 <= scale_V/2), 而它已经反映在盘上整数里 —— 正是
%     这一点让"标量 = 波形的函数"不被定标误差污染。
%     与事件表 peak_V 的偏差由交叉核对属性给出, 不做静默对齐。
%   确定性: 本函数内不含 RNG, 也不取当前时间 (created_utc 只能由调用方给), 因此
%     同一 (ids, traces, meta) 两次调用产出同一份字节 (除 HDF5 自身的元数据)。
%   诚实声明: traces 是解析代理模型
%     (tepc.backendId = analytic_surrogate_v1) 的电子学链输出, 属**模拟波形**,
%     不是实测脉冲形状; 本文件证明的是数据契约与回放一致性, 不构成电子学符合性验证。
%   事务: 本文件不写 run_status 属性 —— 提交与否由 logs/STATUS.json 与
%     artifact_manifest.json 的哈希决定, 在这里再存一份状态就是第二个可互相矛盾的真相。

% --- 入参核对 -------------------------------------------------------------
if nargin < 4 || ~isstruct(meta)
    error("tepc:io:WaveformArgs", ...
        "需要 (path, ids, traces, meta) 四个实参, 且 meta 必须是 struct (实得 nargin=%d)", nargin);
end
if ~isnumeric(traces) || ndims(traces) ~= 2 || size(traces, 1) == 0 || size(traces, 2) == 0
    error("tepc:io:WaveformShape", ...
        "traces 必须是非空的二维数值数组 [nSub x nSamples], 实得 %s (%s)", ...
        mat2str(size(traces)), class(traces));
end
tr = double(traces);
if any(~isfinite(tr(:)))
    error("tepc:io:WaveformNotFinite", "traces 含 NaN/Inf: 量化与取峰都无定义 (拒绝落盘, 不写 NaN 占位)");
end
[nSub, nSamp] = size(tr);
idv = double(ids(:));
if numel(idv) ~= nSub
    error("tepc:io:WaveformSize", "ids 个数 %d != traces 行数 %d (逐事件对齐是契约的一部分)", ...
        numel(idv), nSub);
end
if any(~isfinite(idv)) || any(idv ~= round(idv)) || any(idv < 1)
    error("tepc:io:WaveformId", "event_id 必须是 >=1 的有限整数 (实得 min=%g, 非整数个数=%d)", ...
        min(idv), nnz(idv ~= round(idv)));
end
if numel(unique(idv)) ~= numel(idv)
    error("tepc:io:WaveformIdDuplicated", "event_id 有重复: 同一事件的两条时序在文件里无从区分");
end
Ts = reqField(meta, 'Ts_s');
if ~(isnumeric(Ts) && isscalar(Ts) && isfinite(Ts) && Ts > 0)
    error("tepc:io:WaveformTs", "meta.Ts_s 必须是正的有限标量 [s], 实得 %s", mat2str(Ts));
end
% 极性一律要求显式给出: 缺省取 +1 会让漏传把峰符号写成与生产链相反的一份数, 而文件
% 根属性仍声称"按 hsign 复算" —— 自描述就成了假话。宁可拒写。
% 极性取值是否合法交给 peakSigned 判 (它是全项目唯一的峰实现, 不在这里重复它的校验)。
hs = reqField(meta, 'hsign');
cfgW = reqField(meta, 'cfg');
if ~(isstruct(cfgW) && isfield(cfgW, 'electronics') && isfield(cfgW.electronics, 'adc'))
    error("tepc:io:WaveformCfg", "meta.cfg 必须带 electronics.adc (adc_code 由 tepc.electronics.adc 复算)");
end
adcS = cfgW.electronics.adc;
% 四个量化参数一律要求 (读回侧要按同一套口径重建 cfg): 少一个, "文件自描述可回放"
% 就成了假话, 所以宁可拒写也不允许属性缺项。
needAdc = {'bits', 'fullScale_V', 'inl_lsb', 'range2Gain'};
for i = 1:numel(needAdc)
    if ~isfield(adcS, needAdc{i}) || isempty(adcS.(needAdc{i}))
        error("tepc:io:WaveformCfg", "meta.cfg.electronics.adc 缺 %s", needAdc{i});
    end
end
g2v = double(adcS.range2Gain);
if ~(isscalar(g2v) && isfinite(g2v) && g2v >= 1)
    error("tepc:io:WaveformCfg", ...
        "meta.cfg.electronics.adc.range2Gain 必须是 >=1 的有限标量 (量程判决要它), 实得 %s", mat2str(g2v));
end

% --- 量化 (int16) 与反量化 ------------------------------------------------
maxAbs = max(abs(tr(:)));
if isfield(meta, 'scale_V') && ~isempty(meta.scale_V)
    sc = double(meta.scale_V);
    if ~(isscalar(sc) && isfinite(sc) && sc > 0)
        error("tepc:io:WaveformScale", "meta.scale_V 必须是正的有限标量, 实得 %s", mat2str(sc));
    end
    % 属性文本恒写 "power of two; dequantisation is an exact exponent shift", 所以这里
    % 必须保证它成立: 允许任意正的 scale_V 就等于让文件自描述属性可以说假话
    % (非 2 的幂时 double(samples)*sc 会引入舍入, 回放不再逐位可复现)。
    if sc ~= 2^round(log2(sc))
        error("tepc:io:WaveformScaleNotPow2", ...
            "meta.scale_V=%.17g 不是 2 的幂; 本格式的「精确回放」承诺依赖指数移位, 请取 2^k", sc);
    end
    if maxAbs > 32767*sc
        error("tepc:io:WaveformSaturation", ...
            "给定 scale_V=%.6e 会削顶: max|v|=%.6e > 32767*scale_V=%.6e", sc, maxAbs, 32767*sc);
    end
elseif maxAbs == 0
    sc = 2^-30;                       % 全零波形: 定标任意取一个正的 2 的幂 (仍可精确回放)
else
    sc = 2^ceil(log2(maxAbs/32767));  % 2 的幂 -> 反量化是精确的指数移位, 且不削顶
end
qiD = round(tr./sc);
if any(abs(qiD(:)) > 32767)
    % 数学上到不了这里 (sc 按 maxAbs 选过); 留着是为了"削顶"绝不静默发生
    error("tepc:io:WaveformSaturation", "量化后仍有整数样本越出 int16 范围 (scale_V=%.6e)", sc);
end
qi = cast(qiD, 'int16');
dq = double(qi)*sc;                   % 与 readWaveformsH5/单测逐位同口径

% --- 由波形复算标量 (回放配方的正方向) ------------------------------------
pkV   = zeros(nSub, 1);
tTr   = zeros(nSub, 1);
integ = zeros(nSub, 1);
cod   = zeros(nSub, 1, 'int32');
ipkV  = zeros(nSub, 1);               % 只回给调用方看, 不落盘 (可由 samples 复算)
for j = 1:nSub
    [pk, ipk] = tepc.electronics.peakSigned(dq(j, :).', hs);
    pkV(j)   = pk;
    ipkV(j)  = ipk;
    tTr(j)   = ipk*Ts;                % 与 simulate.m 的 t_trigger_s 同一口径 (1 基索引 x Ts)
    integ(j) = sum(dq(j, :))*Ts;      % 矩形积分; 求和顺序固定 -> 回放逐位可复现
    [ck, ~]  = tepc.electronics.adc(abs(pk), cfgW);
    cod(j)   = ck;
end

% --- 与事件表摘要的交叉核对 (只披露, 不参与计算) --------------------------
xdev = struct();
if isfield(meta, 'event_scalars') && isstruct(meta.event_scalars) && ~isempty(meta.event_scalars)
    es = meta.event_scalars;
    xdev = checkVsEventTable(es, pkV, tTr, cod, nSub);
end

% --- 落盘 (幂等重写, 与 writeEventsH5 同一手法) ---------------------------
if isfile(path), delete(path); end
ckSamp = [min(nSub, 8), min(nSamp, 1024)];
ck1 = [min(nSub, 10000), 1];
h5create(path, '/waveform/samples', [nSub, nSamp], 'DataType', 'int16', ...
    'ChunkSize', ckSamp, 'Deflate', 5);
h5write(path, '/waveform/samples', qi);
h5create(path, '/waveform/event_id', [nSub, 1], 'DataType', 'uint64', ...
    'ChunkSize', ck1, 'Deflate', 5);
h5write(path, '/waveform/event_id', cast(idv, 'uint64'));
h5create(path, '/waveform/peak_V', [nSub, 1], 'DataType', 'double', ...
    'ChunkSize', ck1, 'Deflate', 5);
h5write(path, '/waveform/peak_V', pkV);
h5create(path, '/waveform/t_trigger_s', [nSub, 1], 'DataType', 'double', ...
    'ChunkSize', ck1, 'Deflate', 5);
h5write(path, '/waveform/t_trigger_s', tTr);
h5create(path, '/waveform/adc_code', [nSub, 1], 'DataType', 'int32', ...
    'ChunkSize', ck1, 'Deflate', 5);
h5write(path, '/waveform/adc_code', cod);
h5create(path, '/waveform/integral_Vs', [nSub, 1], 'DataType', 'double', ...
    'ChunkSize', ck1, 'Deflate', 5);
h5write(path, '/waveform/integral_Vs', integ);
% 1x1 的标量集刻意做成数据集而不是只留属性: 只读 h5read 的人也能拿到回放所需的全部量
h5create(path, '/waveform/Ts_s', [1, 1], 'DataType', 'double');
h5write(path, '/waveform/Ts_s', Ts);
h5create(path, '/waveform/scale_V', [1, 1], 'DataType', 'double');
h5write(path, '/waveform/scale_V', sc);

at = struct();
% 属性文本一律 ASCII: MATLAB 的 HDF5 属性文本编码受本机默认字符集影响, 让中文注释
% 进入属性就等于把"回放配方是否可读"押在运行机器上 (中文说明留在源码注释里)。
at.schema_version  = 'tepc-waveforms-1';
at.producer        = 'tepc.io.writeWaveformsH5';
at.data_provenance = ['simulated_analytic_surrogate (' char(tepc.backendId()) ')' ...
    ' - NOT measured pulse shapes'];
at.quantization    = sprintf(['int16 x scale_V (%g V/LSB, power of two); ' ...
    'dequantisation is an exact exponent shift; no clipping'], sc);
at.replay_recipe   = ['v=double(samples)*scale_V; [pk,ipk]=peakSigned(v,hsign); ' ...
    't=ipk*Ts_s; integral=sum(v)*Ts_s; code=adc(abs(pk),{adc_bits,adc_fullScale_V,' ...
    'adc_inl_lsb,adc_range2Gain})'];
at.n_sub      = double(nSub);
at.n_samples  = double(nSamp);
at.Ts_s       = double(Ts);
at.scale_V    = double(sc);
at.max_abs_V  = double(maxAbs);
at.hsign      = double(hs);
at.adc_bits         = double(adcS.bits);
at.adc_fullScale_V  = double(adcS.fullScale_V);
at.adc_inl_lsb      = double(adcS.inl_lsb);
at.adc_range2Gain   = g2v;
opt = {'seed', 'config_sha256', 'matlab_release', 'created_utc', 'waveWindow_s'};
for i = 1:numel(opt)
    if isfield(meta, opt{i}) && ~isempty(meta.(opt{i}))
        at.(opt{i}) = meta.(opt{i});
    end
end
fnm = fieldnames(xdev);
for i = 1:numel(fnm)
    at.(['xcheck_' fnm{i}]) = xdev.(fnm{i});
end
% --- 基线口径自述 (盘上样本减没减 pedestal, 文件必须自己说) ---
% 本函数从 tr 到 dq 只做"除定标、取整、乘回定标", 没有任何去均值步骤, 所以这里只能声明
% "未减基线"而不能顺手报一个基线数 —— 那会成为与 tepc.electronics.simulate 并存的第二份
% 基线真相。给出 Nwin 时同时报"这条规则在本文件里对多少个事件根本算不出来": 判据
% (峰位之后还要留 >=20 个样本) 由盘上量自己核算, 不靠散文断言。
[nbRule, nbTailShort] = baselineDeclaration(nSamp, ipkV, meta);
at.baseline_applied = 'none';
at.baseline_rule    = nbRule;
if nbTailShort >= 0
    at.baseline_n_tail_short = double(nbTailShort);
end
attn = fieldnames(at);
for i = 1:numel(attn)
    val = at.(attn{i});
    if ischar(val) || isstring(val)
        h5writeatt(path, '/', attn{i}, char(val));
    elseif islogical(val)
        h5writeatt(path, '/', attn{i}, double(val));
    elseif isnumeric(val) && isscalar(val)
        h5writeatt(path, '/', attn{i}, double(val));
    else
        h5writeatt(path, '/', attn{i}, char(string(val)));
    end
end

% --- 返回 -----------------------------------------------------------------
di = dir(path);
s = struct();
s.path          = char(path);
s.nSub          = nSub;
s.nSamples      = nSamp;
s.bytes         = di.bytes;
s.Ts_s          = Ts;
s.scale_V       = sc;
s.max_abs_V     = maxAbs;
s.hsign         = hs;
s.event_id      = idv;
s.peak_V        = pkV;
s.t_trigger_s   = tTr;
s.peak_index    = ipkV;
s.adc_code      = cod;
s.integral_Vs   = integ;
s.datasets      = {'/waveform/samples', '/waveform/event_id', '/waveform/Ts_s', ...
    '/waveform/scale_V', '/waveform/peak_V', '/waveform/t_trigger_s', ...
    '/waveform/adc_code', '/waveform/integral_Vs'};
s.quantization  = string(at.quantization);
s.data_provenance = string(at.data_provenance);
s.xcheck = xdev;                          % 未给 event_scalars 时为空 struct
end

% ---------------- helpers ----------------
function [txt, nShort] = baselineDeclaration(nSamp, ipkV, meta)
%BASELINEDECLARATION 盘上样本有没有减基线, 以及噪声地板能否只凭本文件复算。
%   两条文本各自对应一个事实: ①本函数的算术里没有去均值 (tr -> round(tr/sc) -> dq),
%   所以"未减基线"是可以由代码本身担保的; ②噪声地板规则照抄 tepc.electronics.simulate
%   的拖尾段 (峰位之后、收集窗之外、至少 20 个样本), 它需要 Nwin, 没给就不能声称可复算。
head = ['no pedestal/baseline subtraction is applied: samples are the shaped output ' ...
    '(signal + series noise) exactly as the electronics chain produced them, and ' ...
    'peak_V/t_trigger_s/integral_Vs are taken from these un-subtracted samples. '];
nv = [];
if isfield(meta, 'Nwin') && ~isempty(meta.Nwin)
    v = double(meta.Nwin);
    if ~(isscalar(v) && isfinite(v) && v == round(v) && v >= 1)
        error("tepc:io:WaveformNwin", ...
            "meta.Nwin 必须是 >=1 的整数样本数 (收集窗), 实得 %s", mat2str(v));
    end
    nv = v;
end
if isempty(nv)
    txt = [head 'noise-floor RMS is NOT recomputable from this file alone: Nwin ' ...
        '(collection window in samples) was not given to the writer.'];
    nShort = -1;
    return
end
% 窗长判据与 simulate.m 的 (ipk + c.Nwin + 1):numel(v) 且 numel>=20 完全同式
% (即 nSamp - (ipk+Nwin) >= 20), 但峰位来源不同: 这里用**盘上反量化后**的时序取峰
% (ipkV 来自 dq), simulate 用的是量化前的连续 v —— 两者可以差一个样本, 所以只说
% "同式", 不说"同值"。
nShort = nnz(nSamp - (ipkV(:) + nv) < 20);
txt = sprintf(['%sNoise-floor RMS rule (same window arithmetic as tepc.electronics.simulate, ' ...
    'peak index taken from the dequantised trace stored here): de-meaned RMS of samples with ' ...
    'index > peak_index + Nwin, Nwin=%d samples, needing >=20 samples; baseline_n_tail_short ' ...
    'counts stored events whose trace is too short for that window.'], head, nv);
% 全数不可算时必须把这句话说出来: 只留一个整数会让读者以为规则在本文件里可用。
% (发货窗长就是这种情形: 1201 个采样点 < Nwin, 每个事件都判不出。)
if nShort == numel(ipkV)
    txt = [txt ' FOR THIS FILE the window is unavailable for EVERY stored event ' ...
        '(baseline_n_tail_short == n_sub): the noise-floor RMS cannot be recomputed from ' ...
        'these traces, only from a longer acquisition window.'];
end
end

function v = reqField(st, nm)
if ~isfield(st, nm) || isempty(st.(nm))
    error("tepc:io:WaveformMeta", "meta 缺必填字段 %s (回算标量离不开它)", nm);
end
v = st.(nm);
end

function xdev = checkVsEventTable(es, pkV, tTr, cod, nSub)
%CHECKVSEVENTTABLE 波形复算值与事件表摘要的偏差 (纯披露: 不参与任何落盘标量的计算)。
%   偏差的期望量级: peak_V ~ scale_V/2 的量化误差再叠加"抽样重跑"与"分块生产"之间
%   本不应出现的任何差异; adc_code 是整数码, 在量化边界附近可差 1 码。
xdev = struct();
if isfield(es, 'peak_V') && numel(es.peak_V(:)) == nSub
    d = abs(double(es.peak_V(:)) - pkV);
    xdev.peak_V_abs_max = max(d);
    xdev.peak_V_rel_max = max(d./max(abs(pkV), eps));
end
if isfield(es, 't_trigger_s') && numel(es.t_trigger_s(:)) == nSub
    xdev.t_trigger_s_abs_max = max(abs(double(es.t_trigger_s(:)) - tTr));
end
if isfield(es, 'adc_code') && numel(es.adc_code(:)) == nSub
    xdev.adc_code_abs_max = max(abs(double(es.adc_code(:)) - double(cod)));
end
end
