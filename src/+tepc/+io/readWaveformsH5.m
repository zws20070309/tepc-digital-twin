function W = readWaveformsH5(path)
%READWAVEFORMSH5 读回 writeWaveformsH5 产出的波形文件 (与其数据集/属性一一对应)。
%   W = readWaveformsH5(path) 返回:
%     W.samples_int16  [nSub x nSamples] int16   盘上原始整数 (逐位等于写入值)
%     W.v              [nSub x nSamples] double  反量化电压 = double(samples)*scale_V
%                                                (仅此一步换算, 与写出器同一表达式)
%     W.event_id [nSub x 1] uint64, W.Ts_s, W.scale_V, W.peak_V, W.t_trigger_s,
%     W.adc_code (int32), W.integral_Vs
%     W.hsign          成形链极性 (根属性), 峰定义所需的第二个实参
%     W.cfg            由根属性 adc_* **重建**的 ADC 口径: 证明文件自描述, 回放不需要
%                      仓库里的 config/defaults/*.json 也能独立复算
%     W.attrs          全部根属性 (struct)
%   刻意的限制:
%     * 不做任何"顺手修正" (不重量化、不插值、不替缺失属性猜默认值) —— 缺任一必需
%       项即报错, 否则回放一致性会被一个凭空补出来的常数悄悄"修好"。
%     * 返回 W.v 与 W.samples_int16 两份, 是为了让调用方能显式选择"按整数比对"
%       (证明往返无损) 还是"按电压复算标量" (证明标量是波形的函数)。
%   回放的三条形状约定 (与 writeWaveformsH5 的复算侧逐字同形, 否则"逐位相等"无从谈起):
%     * 求峰前把该行转成**列** (peakSigned 内部本就 v(:), 行列同次序);
%     * 求 integral_Vs 用 sum(第 j **行**) —— sum 对行向量与列向量的求和次序不保证
%       逐位相同, 所以形状也是契约的一部分;
%     * 反量化只做 double(int16)*scale_V 一次乘法, scale_V 是 2 的幂 -> 精确移位。
%   对称的精确读取调用 (本函数就是这些调用的唯一封装):
%     h5read(path,'/waveform/samples' | '/waveform/event_id' | '/waveform/Ts_s' |
%                  '/waveform/scale_V' | '/waveform/peak_V' | '/waveform/t_trigger_s' |
%                  '/waveform/adc_code' | '/waveform/integral_Vs')
%     h5readatt(path, '/', 'schema_version'|'producer'|'data_provenance'|'quantization'|
%                    'replay_recipe'|'n_sub'|'n_samples'|'Ts_s'|'scale_V'|'max_abs_V'|
%                    'hsign'|'adc_bits'|'adc_fullScale_V'|'adc_inl_lsb'|'adc_range2Gain')
%     (必需属性缺任一即报错; 可选 seed / waveWindow_s / matlab_release / created_utc /
%      config_sha256 / baseline_applied / baseline_rule / baseline_n_tail_short 读不到就
%      不写进 W.attrs, 也不拿它们猜任何口径。xcheck_* 一组刻意不在此封装里交出: 那是写出
%      侧与事件表的核对披露, 需要事件表才能解释, 本函数只交回放所需的量)
if ~isfile(path)
    error("tepc:io:WaveformFileMissing", "波形文件不存在: %s", path);
end
W = struct();
W.samples_int16 = h5read(path, '/waveform/samples');
if ~isinteger(W.samples_int16)
    error("tepc:io:WaveformSchema", "samples 不是整数型 (写出器按 int16 建集), 实得 %s", ...
        class(W.samples_int16));
end
W.event_id    = uint64col(h5read(path, '/waveform/event_id'));
W.Ts_s        = double(h5read(path, '/waveform/Ts_s'));
W.scale_V     = double(h5read(path, '/waveform/scale_V'));
W.peak_V      = doublecol(h5read(path, '/waveform/peak_V'));
W.t_trigger_s = doublecol(h5read(path, '/waveform/t_trigger_s'));
W.adc_code    = int32col(h5read(path, '/waveform/adc_code'));
W.integral_Vs = doublecol(h5read(path, '/waveform/integral_Vs'));
W.v           = double(W.samples_int16)*W.scale_V;    % 与写出器唯一的反量化表达式
nSub = size(W.samples_int16, 1);
if ~(isscalar(W.Ts_s) && isscalar(W.scale_V)) || W.Ts_s <= 0 || W.scale_V <= 0
    error("tepc:io:WaveformSchema", "Ts_s/scale_V 不是正标量 (Ts=%s scale=%s)", ...
        mat2str(W.Ts_s), mat2str(W.scale_V));
end
if numel(W.peak_V) ~= nSub || numel(W.t_trigger_s) ~= nSub || numel(W.adc_code) ~= nSub ...
        || numel(W.integral_Vs) ~= nSub || numel(W.event_id) ~= nSub
    error("tepc:io:WaveformSchema", "标量列长度与 samples 行数 %d 不符 (逐事件对齐被破坏)", nSub);
end

% --- 根属性: 必需项缺任一即报错 ---
needNum = {'n_sub', 'n_samples', 'Ts_s', 'scale_V', 'max_abs_V', 'hsign', ...
    'adc_bits', 'adc_fullScale_V', 'adc_inl_lsb', 'adc_range2Gain'};
needStr = {'schema_version', 'producer', 'data_provenance', 'quantization', 'replay_recipe'};
A = struct();
for i = 1:numel(needNum)
    A.(needNum{i}) = attrNum(path, needNum{i});
end
for i = 1:numel(needStr)
    A.(needStr{i}) = attrTxt(path, needStr{i});
end
optNum = {'seed', 'waveWindow_s', 'baseline_n_tail_short'};
for i = 1:numel(optNum)
    try, A.(optNum{i}) = attrNum(path, optNum{i}); catch, end
end
% baseline_applied/baseline_rule 由现在的写出器恒写, 但刻意留在可选表而不是 needStr:
% 本仓库 runs/ 下的历史波形文件没有这两条, 放进必需表会让"重开旧发布集"直接报错,
% 而读者拿不到它们时最坏的后果只是"不知道减没减基线" —— 那正是写出侧属性要回答的问题,
% 读侧无从补。缺项由调用方按 isfield(W.attrs,...) 自行判定 (单测就是这么锁的)。
optTxt = {'matlab_release', 'created_utc', 'config_sha256', 'baseline_applied', 'baseline_rule'};
for i = 1:numel(optTxt)
    try, A.(optTxt{i}) = attrTxt(path, optTxt{i}); catch, end
end
if A.n_sub ~= nSub || A.n_samples ~= size(W.samples_int16, 2)
    error("tepc:io:WaveformSchema", "属性记的规模 (%gx%g) 与数据集实得 (%gx%g) 不符", ...
        A.n_sub, A.n_samples, nSub, size(W.samples_int16, 2));
end
if abs(A.Ts_s - W.Ts_s) > 0 || abs(A.scale_V - W.scale_V) > 0
    error("tepc:io:WaveformSchema", "同一名值在属性与数据集里不一致 (Ts_s/scale_V)");
end
W.attrs = A;
W.hsign = A.hsign;
% 由文件属性重建 adc.m 所需口径 (回放所需的全部输入都在文件里)
W.cfg = struct('electronics', struct('adc', struct( ...
    'bits', A.adc_bits, 'fullScale_V', A.adc_fullScale_V, ...
    'inl_lsb', A.adc_inl_lsb, 'range2Gain', A.adc_range2Gain)));
end

% ---------------- helpers ----------------
function v = doublecol(raw)
v = double(raw(:));
end

function v = int32col(raw)
if ~isinteger(raw)
    v = cast(round(raw), 'int32');
else
    v = cast(raw(:), 'int32');
end
end

function v = uint64col(raw)
if ~isinteger(raw)
    v = cast(round(raw), 'uint64');
else
    v = cast(raw(:), 'uint64');
end
end

function v = attrNum(path, nm)
try
    raw = h5readatt(path, '/', nm);
catch e
    error("tepc:io:WaveformAttrMissing", ...
        "根属性 %s 读不出来 (文件不自描述就无法独立回放): %s", nm, e.message);
end
v = double(raw);
if ~isscalar(v) || ~isfinite(v)
    error("tepc:io:WaveformAttrMissing", "根属性 %s 不是有限标量, 实得 %s", nm, mat2str(v));
end
end

function v = attrTxt(path, nm)
try
    raw = h5readatt(path, '/', nm);
catch e
    error("tepc:io:WaveformAttrMissing", "根属性 %s 读不出来: %s", nm, e.message);
end
v = char(string(raw));
end
