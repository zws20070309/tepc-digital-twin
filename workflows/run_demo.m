function R = run_demo(varargin)
%RUN_DEMO 演示工作流: 固定 seed 的 10000 事件、events.h5、
%   spectrum.csv、summary.json、诊断图。默认读 config/defaults/demo_only.json。
%   用法: R = run_demo();  R = run_demo('N', 50000, 'Config', 'config/local.json');

p = inputParser;
addParameter(p, 'Config', fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'), @ischar);
addParameter(p, 'N', 10000);
addParameter(p, 'Seed', []);
parse(p, varargin{:});
cfgPath = p.Results.Config;
cfg = tepc.config.load(cfgPath);
seed = cfg.provenance.seed;
if ~isempty(p.Results.Seed), seed = p.Results.Seed; end

prog = @(f, m) fprintf('[%5.1f%%] %s\n', 100*f, m);
R = tepc.run.execute(cfg, 'N', p.Results.N, 'Seed', seed, 'Progress', prog);

% 诊断图由 execute 统一产出 (figures/diagnostic.png, 并进 provenance)。
% 这里曾再存一份 figures/diagnostic_spectrum.png —— 同一张图两个名字, 而 htmlReport
% 只认后一个, 于是走 project.execute()+exportReport() 的报告永远没有诊断图。

% 报告由 execute 产出并**已经过 provenance 哈希 + 事务式提交**。这里曾再调一次
% htmlReport 覆盖同一个文件 —— 提交后再改产物等于让 provenance 的哈希当场失真,
% 所以现在只打印路径。
fprintf('报告: %s\n', R.reportPath);

fprintf('\n===== DEMO 摘要 =====\n');
fprintf('runID: %s\n', R.runDir.runID);
fprintf('yF = %.2f keV/um, yD = %.2f keV/um\n', ...
    R.summary.yF_keV_um, R.summary.yD_keV_um);
fprintf('%s (RESEARCH/DEMO, 禁绝对发布)\n', tepc.report.doseLine(R.summary));
fprintf('剂量率(演示, 未标定) = %.1f uGy/h\n', R.summary.dose_rate_uGy_h);
fprintf('事件: %d, 零沉积 %.1f%%, 死时间拒绝 %d, liveFrac %.3f\n', ...
    R.summary.nEvents, 100*R.summary.zeroDep_fraction, ...
    R.summary.deadRejected, R.summary.liveFrac);
fprintf('门禁: %s (%d 项)\n', R.gates.watermark, numel(R.gates.items));
% 两个量度分开打印: computational_gates_passed 只说"有没有 FAIL",
% release_eligible 还要求零未评估项, released 再要求 run.mode=="VALIDATED"。
fprintf('计算门禁全过=%d, 具备发布资格=%d, released=%d\n', ...
    R.gates.computational_gates_passed, R.gates.release_eligible, R.gates.released);
% runDirs 重构后 rd.root **就是**本次 run 目录 (曾在此再拼一层 runs/<runID>,
% 打出一个不存在的路径)
fprintf('输出目录: %s\n', R.runDir.root);end
