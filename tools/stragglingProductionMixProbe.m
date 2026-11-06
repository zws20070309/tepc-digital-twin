function out = stragglingProductionMixProbe(varargin)
%STRAGGLINGPRODUCTIONMIXPROBE 生产混合下的 Bohr 涨落触发占比与配对偏置 (实测产物)。
%   out = stragglingProductionMixProbe()                     默认 N=2000, 三个初级能量点
%   out = stragglingProductionMixProbe('N', 400)             只改事件数
%   out = stragglingProductionMixProbe('Energies_MeV', [1.0 0.3])
%   out = stragglingProductionMixProbe('MinFreeMb', 3500)    独占门槛 (0 = 不检查)
%
%   产物: docs/test_evidence/straggling_production_mix_<utc>.json + 同名 .log。
%   两份都落且当场复核成对: tools/writeLatestEvidence 的哈希表收 docs/test_evidence 下的
%   *.log, 只有 .json 的产物不进索引 —— 那种"静默没索引"与本仓库一直在清的静默失效同族。
%
%   为什么这条测量不需要新管線 (设计要点):
%   AnalyticAdapter 的逐事件抽样 (弦 / 通道权重 / 反冲能 / 诞生点) 全部在**调用
%   csdaTransport 之前**在同一-事件子流上完成 (按符号定位: AnalyticAdapter 的 mono_neutron 分支: sampleChord → pickChannel → nuclearChannel → sampleInVolume
%   这四步全在调用 csdaTransport 之前, 且都在同一-事件子流上), 而涨落只在那一步
%   内部消费 randn (csdaTransport.m:75)。于是同 seed 下"带涨落"与"straggle=false"两条腿
%   拿到逐位相同的 P0、方向、反冲能与通道, 唯一区别就是涨落本身 —— 这是配对 (common
%   random numbers) 比较: 既不复刻抽样 (那会造出第二份通道权重真相), 也不动 EventBatch
%   与 events.h5 的 23 个数据集。两条腿的 t0_s 会因 randn 消耗数不同而不同, 但 t0 不进
%   任何能量列, 所以不影响本判据。
%
%   三条产出 (判据的形状是被"哪里会假"逼出来的, 不是随手分的):
%     气/壁分配变化率 = |ΔEdepWall| 或 |ΔEescape| 超过 tol 的事件比例。**这才是物理效果**:
%       涨落改变的是"这一条径迹在出腔前已经攒掉了多少能量", 于是改变它**是否**来得及撞壁;
%       撞壁与否决定气/壁/逸出三项怎么分 (csdaTransport.m:80-88, 出口步用 dE_mean)。
%     沉积偏置 = mean(A)/mean(B) - 1 与其配对标准误。必须在同一张表里带上 **ulp 计数**
%       (0<|ΔEdepGas|<=tol 的事件数): 在气腔内停住的径迹, 两条腿的 EdepGas 都等于 E_R 本身
%       (逐步累加 + 残能就地沉积 = 恒等式, csdaTransport.m:45-48,78,89), 所以那一列的差
%       只可能是浮点重结合 (1000 keV 量级上 ~1e-13 keV), 拿它当"涨落起作用的占比"会把
%       个 ulp 的噪声读成几十倍 sigma。tol 因此按能量量级给 (TolKeV, 默认 1e-6 keV)。
%     同批地板 = std(A)/mean(A)/sqrt(N) —— 标签必须写全 "同批·未加权·仪器前": 它是本探针
%       自己那个估计量 (逐事件沉积均值) 的标准误, **不是** docs/performance_tiers.md 的计数地板 u_yF
%       (那个用加权后的有效事件数 n_eff=SW²/Σw² 且跳过 y==0, buildSpectrum.m:39,122,
%        实测 n_eff/N≈0.7525), 因此两者相差约 1.15 倍再加阈值/DAQ 剔除, 不许并排引用。
%
%   结构性地板 (必须随数携带, 否则占比会被读成"低能工况涨落也不起作用"):
%   表下限 T.E(1) 以下的事件第一步就落进残能分支 (csdaTransport.m:45), 一步都不涨落。
%   反冲能按通道在 [0, E_n·4A/(1+A)²] 上均匀 (nuclearChannel.m:18), 生产混合权重
%   p_H/p_C/p_O = 0.8136/0.1090/0.0775 (数密度份额 H .6038/C .2264/O .1509/N .0189 ×
%   截面 4.2/1.5/1.6 barn, 归一), 于是"天生不会涨落"的比例约
%   1.55% @1 MeV、5.16% @0.30 MeV、30.9% @0.05 MeV —— 0.05 MeV 那一行的占比上限就是 ~69%。
%
%   不做的事 (写清楚, 免得被当成已做):
%     * 不拆 H/C/O 三道的占比: 通道标签由 AnalyticAdapter 的文件内函数 pickChannel 抽,
%       没有对外出口; 要拆必须先导出它 (动热文件), 而不是在这儿重算一遍权重。
%     * 不判通过/失败: 这是量级记录, 判据属于 docs/performance_tiers.md 的措辞。
%     * 不谈仪器后: 两条腿都停在 AnalyticAdapter 出口 (pre-DAQ)。发布链后面按 t0 排序并
%       做占用/pile-up 剔除, 而 t0 用掉的事件序号流在两条腿上是**不同**的 (涨落少消耗
%       一次 randn), 所以这个配对只对逐事件沉积成立, 对 y_F 不成立。

root = tepc.io.projectRoot();
opt = struct('n', 2000, 'seed', 90210, 'energiesMeV', [], 'quiet', false, ...
    'minFreeMb', 3500, 'tolKeV', 1e-6);
fnames = string(fieldnames(opt));
for i = 1:2:numel(varargin)
    % 选项名按"去掉下划线后小写"匹配: 直接 lower(传入名) 与驼峰字段名 (minFreeMb) 对不上,
    % 而 isfield 的大小写敏感又会把 'N' 判成未知选项 —— 实测就是这样被自己拒了一次。
    key = strrep(lower(string(varargin{i})), '_', '');
    j = find(key == strrep(lower(fnames), '_', ''), 1);
    if isempty(j)
        error("tepc:tools:StraggleProbeOpt", "未知选项 %s (可用: %s)", ...
            char(varargin{i}), strjoin(fnames, ', '));
    end
    opt.(char(fnames(j))) = varargin{i+1};
end
if ~(isnumeric(opt.tolKeV) && isscalar(opt.tolKeV) && opt.tolKeV > 0)
    error("tepc:tools:StraggleProbeTol", "TolKeV 必须是正标量, 实得 %s", mat2str(opt.tolKeV));
end

env = tepc.io.hostMemory();
if logical(opt.minFreeMb) && env.free_mb < opt.minFreeMb
    error("tepc:tools:StraggleProbeHostBusy", ...
        ['本机空闲 %.0f MB < 门槛 %.0f MB, 并发 MATLAB 镜像行 %d (>2 说明机器上不止一条链): ' ...
         '独占门槛没过, 拒绝开跑。墙钟与内存吃紧时的静默降级比不跑更贵。'], ...
        env.free_mb, opt.minFreeMb, env.matlab_processes);
end

cfg0 = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
if isempty(opt.energiesMeV)
    % 发货点 + 两个低能点: 低能段是 hE 与涨落真正绑定的区域 (Ts 档位那一行讲的是高能端)。
    E0s = [double(cfg0.source.energy_MeV), 0.30, 0.05];
else
    E0s = double(opt.energiesMeV(:)).';
end
geom = tepc.geometry.buildGeometry(cfg0);

rs = RandStream('Threefry', 'Seed', opt.seed);
rows = struct('E0_MeV', {}, 'N', {}, 'tol_keV', {}, ...
    'n_partition_changed', {}, 'frac_partition_changed', {}, ...
    'n_gas_diff', {}, 'n_gas_ulp_only', {}, 'frac_gas_over_tol', {}, ...
    'mean_A_keV', {}, 'mean_B_keV', {}, 'bias_rel', {}, 'se_rel', {}, 'bias_over_se', {}, ...
    'cv_A', {}, 'se_mean_A_rel', {}, 'max_abs_diff_keV', {}, ...
    'n_ledger_open_A', {}, 'n_ledger_open_B', {}, 'table_floor_keV', {}, ...
    'n_below_table_floor', {});
for j = 1:numel(E0s)
    cfg = cfg0;
    cfg.source.energy_MeV = E0s(j);
    cfg.provenance.seed = opt.seed;
    % 表构造与 execute.m:149-151 同一套 (四道: 质子/电子/重碳/重氧), 每能量点建一次给两条腿共用。
    T = struct('proton', tepc.transport.stoppingPower(cfg, "proton"), ...
               'electron', tepc.transport.stoppingPower(cfg, "electron"), ...
               'heavy_C', tepc.transport.stoppingPower(cfg, "heavy_C"), ...
               'heavy_O', tepc.transport.stoppingPower(cfg, "heavy_O"));
    floorKeV = 1e3*min([T.proton.E(1), T.electron.E(1), T.heavy_C.E(1), T.heavy_O.E(1)]);
    A = legEvents(cfg, geom, T, rs, opt.n, true);     % 显式带涨落
    B = legEvents(cfg, geom, T, rs, opt.n, false);    % 无涨落基准
    ga = A.EdepGas_keV(:); gb = B.EdepGas_keV(:);
    if ~isequal(size(ga), size(gb))
        error("tepc:tools:StraggleProbeSize", "两条腿事件数不同: %d vs %d", numel(ga), numel(gb));
    end
    tol = opt.tolKeV;
    dGas = ga - gb;
    absD = abs(dGas);
    % 分配变化 = 壁或逸出任一侧动了超过 tol。这是唯一"物理上"的差别 (见头注释)。
    partChanged = abs(A.EdepWall_keV(:) - B.EdepWall_keV(:)) > tol | ...
                  abs(A.Eescape_keV(:) - B.Eescape_keV(:)) > tol;
    meanA = mean(ga); meanB = mean(gb);
    bias = meanA/meanB - 1;
    se = std(dGas)/abs(meanB)/sqrt(numel(dGas));
    cv = std(ga)/meanA;
    % 账本 (次级能量 = 气 + 壁 + 逸出) 在**两条**腿上都必须闭合, 否则这两条腿不可比。
    okA = abs(A.EdepGas_keV + A.EdepWall_keV + A.Eescape_keV - A.Esecondary_keV) ...
        <= 1e-9 + 1e-9*abs(A.Esecondary_keV);
    okB = abs(B.EdepGas_keV + B.EdepWall_keV + B.Eescape_keV - B.Esecondary_keV) ...
        <= 1e-9 + 1e-9*abs(B.Esecondary_keV);
    rows(end+1) = struct('E0_MeV', E0s(j), 'N', numel(ga), 'tol_keV', tol, ...
        'n_partition_changed', nnz(partChanged), 'frac_partition_changed', mean(partChanged), ...
        'n_gas_diff', nnz(absD > 0), 'n_gas_ulp_only', nnz(absD > 0 & absD <= tol), ...
        'frac_gas_over_tol', mean(absD > tol), ...
        'mean_A_keV', meanA, 'mean_B_keV', meanB, 'bias_rel', bias, 'se_rel', se, ...
        'bias_over_se', bias/max(se, realmin), 'cv_A', cv, ...
        'se_mean_A_rel', cv/sqrt(numel(ga)), 'max_abs_diff_keV', max(absD), ...
        'n_ledger_open_A', sum(okA), 'n_ledger_open_B', sum(okB), ...
        'table_floor_keV', floorKeV, ...
        'n_below_table_floor', sum(B.Esecondary_keV(:) < floorKeV));  %#ok<AGROW>
    if ~logical(opt.quiet)
        fprintf(['E0=%-8.4g N=%-6d 分配变化 %6.2f%%  沉积差超阈 %6.2f%% (其中只差 ulp %d 条)  ' ...
                 'bias=%+.3e (%.1f 倍 se) 均值标准误 %.2f%%  账本闭合 A/B=%d/%d\n'], ...
            E0s(j), numel(ga), 100*mean(partChanged), 100*mean(absD > tol), ...
            nnz(absD > 0 & absD <= tol), bias, bias/max(se, realmin), ...
            100*cv/sqrt(numel(ga)), sum(okA), sum(okB));
    end
end

stamp = char(datetime('now', 'TimeZone', 'UTC', 'Format', "yyyyMMdd'T'HHmmss'Z'"));
dirEv = fullfile(root, 'docs', 'test_evidence');
if ~isfolder(dirEv)
    mkdir(dirEv);
end
jf = fullfile(dirEv, sprintf('straggling_production_mix_%s.json', stamp));
lf = fullfile(dirEv, sprintf('straggling_production_mix_%s.log', stamp));
payload = struct('generated_utc', char(datetime('now', 'TimeZone', 'UTC', ...
        'Format', "yyyy-MM-dd'T'HHmmss'Z'")), ...
    'seed', opt.seed, 'n_events', opt.n, 'source_energy_MeV', E0s, ...
    'gas_composition_molfrac', cfg0.gas.composition_molfrac, ...
    'channel_weights', cfg0.source.neutronChannels, ...
    'channel_sigma_barn', cfg0.source.channelSigma_barn, ...
    'bohr_coeff_MeV2_cm2_per_g', double(tepc.config.constants('transport.bohr.coeffMeV2cm2PerG')), ...
    'env', env, ...
    'note', ['涨落触发占比 = 两腿的**气/壁/逸出分配**变化超过 tol 的事件比例 (in-gas 停住的径迹两腿沉积恒等, ' ...
             '所以只看 EdepGas 的逐位差会把浮点重结合读成物理效应, 该列单列"仅 ulp 条数")。' ...
             '偏置是配对差, 只与该比例一起读; 均值标准误是本探针自己估计量的, 不是 docs/performance_tiers.md 的计数地板 u_yF。' ...
             '道别 (H/C/O) 未拆: 通道标签在 AnalyticAdapter 的文件内函数 pickChannel 里, 未导出。'], ...
    'rows', rows);
tepc.io.writeJson(jf, payload);
fid = fopen(lf, 'w', 'n', 'UTF-8');
if fid < 0
    error("tepc:tools:StraggleLogUnwritable", "写不了 %s", lf);
end
fwrite(fid, probeText(payload), 'char');
fclose(fid);
if ~(isfile(jf) && isfile(lf))
    error("tepc:tools:StragglePairMissing", "产物不成对: json=%d log=%d", isfile(jf), isfile(lf));
end
fprintf('产物: %s\n产物: %s\n', jf, lf);
out = struct('json', jf, 'log', lf, 'rows', rows, 'env', env);
end

function ev = legEvents(cfg, geom, T, rs, n, on)
% 一条腿: 走 AnalyticAdapter 本尊。两条腿都**显式**写 straggle, 不让"生产口径"依赖
% csdaTransport 的默认值 —— 默认改了的话这里会静默跟着改, 那就是两份真相。
xopts = struct('straggle', logical(on));
[E, ~] = tepc.transport.AnalyticAdapter(cfg, geom, T, rs, n, 1, struct('tNext', 0), xopts);
ev = E.ev;
end

function t = probeText(p)
e0 = strtrim(strjoin(cellfun(@(v) sprintf('%.4g', v), num2cell(p.source_energy_MeV(:)), ...
    'UniformOutput', false), ', '));
L = {'# TEPC 生产混合下的 Bohr 涨落触发占比与配对偏置', ...
     sprintf('# generated_utc : %s', p.generated_utc), ...
     sprintf('# seed=%d n_events=%d E0_MeV=[%s]', p.seed, p.n_events, e0), ...
     sprintf('# env: free_mb=%.0f total_mb=%.0f matlab_rows=%s source=%s', ...
     p.env.free_mb, p.env.total_mb, mat2str(p.env.matlab_processes), p.env.source), ...
     sprintf('# bohr_coeff=%.6g (唯一来源 config/constants: transport.bohr.coeffMeV2cm2PerG)', ...
     p.bohr_coeff_MeV2_cm2_per_g), ...
     '# 配对偏置只在"气/壁分配真的变了"的事件上才有物理含义; 只差 ulp 的条数单列, 不混进占比。', ...
     '# E0_MeV     N     分配变化%   沉积差>tol%  仅ulp条数  bias_rel      se_rel        bias/se   均值标准误%  max|dE|keV  账本A/B    地板以下', ...
     '# ---------------------------------------------------------------------------------------'};
for i = 1:numel(p.rows)
    r = p.rows(i);
    L{end+1} = sprintf('%-10.4g %-6d %9.3f  %11.3f  %9d  %+12.4e  %12.4e  %8.2f  %10.3f  %12.4g  %6d/%-6d %8d', ...
        r.E0_MeV, r.N, 100*r.frac_partition_changed, 100*r.frac_gas_over_tol, ...
        r.n_gas_ulp_only, r.bias_rel, r.se_rel, r.bias_over_se, ...
        100*r.se_mean_A_rel, r.max_abs_diff_keV, r.n_ledger_open_A, r.n_ledger_open_B, ...
        r.n_below_table_floor);  %#ok<AGROW>
end
L{end+1} = sprintf('# tol=%.3g keV; 表下限逐点 = %s keV (取四道表 E(1) 的最小值, 未拆道)', ...
    rowsTol(p.rows), mat2str(rowsFloor(p.rows)));
L{end+1} = sprintf('# note: %s', p.note);
t = strjoin(cellstr(L), sprintf('\n'));
end

function v = rowsTol(rows)
v = rows(1).tol_keV;
end

function v = rowsFloor(rows)
v = [rows.table_floor_keV];
end
