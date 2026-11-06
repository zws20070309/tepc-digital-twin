function out = uqBudgetRefreshProbe(varargin)
%UQBUDGETREFRESHPROBE 把预算表引用的 y_F 与"壁参数零响应"按可复现配方重算并归档。
%   out = uqBudgetRefreshProbe()                 跑全腿并写 docs/test_evidence/
%   out = uqBudgetRefreshProbe('WriteFile', false)  只算不落盘
%   out = uqBudgetRefreshProbe('NEv', 1500)      快速核对档
%
%   为什么要它: 文档里"同 seed 12345、N=4000、mono_neutron 初级 1 MeV ⇒ y_F=19.41256772"
%   这句话定不出那个数 —— 没写配置文件、随机流种类、run 种子、y 的分母口径。
%   同一句话在现树跑出来的是 37.793699。本工具把这些全部钉死并写进产物抬头。
%
%   口径: 只调 AnalyticAdapter, 不经 execute/analyze, 所以 y_F 是**真值列口径**
%   (EdepGas_keV / lbar_tissue 的谱一阶矩, buildSpectrum 的 yF_exact),
%   与仪器反演后的发布 y 不是同一个量, 不可互相换算, 也不可与别的批次串成一条链。
%
%   三条自检, 缺一条产物就不可引用:
%     1) 同配方两次运行必须逐位相同 (否则"流种子钉死"是假的) -> 不满足直接 error;
%     2) 壁参数腿报的是**逐位比较结果**, 不是只报数值 (数值相等不等于列相等);
%     3) 伽马腿必须报壁作用产额随 rho_wall 覆盖项的变化序列 (全相等 = 采样侧没吃覆盖项)。

p = inputParser;
p.addParameter('NEv', 4000, @(v) isnumeric(v) && isscalar(v) && v > 0);
p.addParameter('GammaNEv', 1500, @(v) isnumeric(v) && isscalar(v) && v > 0);
p.addParameter('WriteFile', true, @islogical);
p.parse(varargin{:});
opt = p.Results;

root = tepc.io.projectRoot();
cfgPath = fullfile(root, 'config', 'defaults', 'demo_only.json');
streamKind = 'Threefry';
seed = 12345;
nEv = opt.NEv;
gEv = opt.GammaNEv;

cfg = tepc.config.load(cfgPath);
R = tepc.config.resolve(cfg);
tables = struct('proton', tepc.transport.stoppingPower(cfg, 'proton'), ...
    'electron', tepc.transport.stoppingPower(cfg, 'electron'), ...
    'heavy_C', tepc.transport.stoppingPower(cfg, 'heavy_C'), ...
    'heavy_O', tepc.transport.stoppingPower(cfg, 'heavy_O'));
rhoN = tepc.transport.wallDensity(struct());

[E1, ~] = legNeutron(cfg, R.geom, tables, nEv, seed, struct());
[E2, ~] = legNeutron(cfg, R.geom, tables, nEv, seed, struct());
S1 = specOf(E1, R);
S2 = specOf(E2, R);
repro = isequal(E1.ev.EdepGas_keV, E2.ev.EdepGas_keV) && (S1.yF_exact == S2.yF_exact);
if ~repro
    error('tepc:probe:NotReproducible', ...
        '同配方两次运行不逐位相同 (yF %.10f vs %.10f): 随机流没钉死, 产物不可引用', ...
        S1.yF_exact, S2.yF_exact);
end

[E3, ~] = legNeutron(cfg, R.geom, tables, nEv, seed, struct('rho_wall_g_cm3', 3*rhoN));
S3 = specOf(E3, R);
g5 = R.geom;
g5.wallThickness_m = 5*g5.wallThickness_m;
[E4, ~] = legNeutronGeom(cfg, g5, tables, nEv, seed);
S4 = specOf(E4, R);

[cfgG, wallCnt, gasCnt] = legGammaSweep(cfg, R.geom, tables, gEv, rhoN);

stamp = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyyMMdd''T''HHmmss''Z'));
jf = fullfile(root, 'docs', 'test_evidence', sprintf('uq_budget_refresh_%s.json', stamp));
lf = fullfile(root, 'docs', 'test_evidence', sprintf('uq_budget_refresh_%s.log', stamp));

payload = struct();
payload.schema = 'tepc-uq-budget-refresh-v1';
payload.generated_utc = char(string(datetime('now', 'TimeZone', 'UTC', ...
    'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z''')));
payload.recipe = struct('config', localRel(cfgPath, root), ...
    'config_sha256', char(tepc.io.hashFile(cfgPath)), ...
    'stream_kind', streamKind, 'stream_seed', seed, 'run_seed', seed, ...
    'nEv_neutron', nEv, 'nEv_gamma', gEv, ...
    'transport_entry', 'tepc.transport.AnalyticAdapter (不经 execute/analyze)', ...
    'y_F_definition', 'buildSpectrum(EdepGas_keV, R.lbar_tissue_um, weight, R.edges).yF_exact', ...
    'y_F_is_instrument_published', false, ...
    'matlab_version', version('-release'), 'backend_id', char(tepc.backendId()));
payload.context = struct('pressure_Pa', cfg.gas.pressure_Pa, ...
    'temperature_K', cfg.gas.temperature_K, 'energy_MeV', cfg.source.energy_MeV, ...
    'lbar_tissue_um', R.lbar_tissue_um, 'wall_thickness_m', R.geom.wallThickness_m, ...
    'rho_wall_g_cm3', rhoN, 'site_mode', char(R.siteMode));
payload.neutron = struct('yF_exact', S1.yF_exact, ...
    'escape_keV_sum', sum(E1.ev.Eescape_keV), ...
    'edep_wall_keV_sum', sum(E1.ev.EdepWall_keV), ...
    'wall_rho_x3', struct('yF_exact', S3.yF_exact, ...
        'gas_column_bitwise_equal', isequal(E1.ev.EdepGas_keV, E3.ev.EdepGas_keV), ...
        'yF_bitwise_equal', S3.yF_exact == S1.yF_exact, ...
        'escape_keV_sum', sum(E3.ev.Eescape_keV)), ...
    'wall_thickness_x5', struct('yF_exact', S4.yF_exact, ...
        'gas_column_bitwise_equal', isequal(E1.ev.EdepGas_keV, E4.ev.EdepGas_keV), ...
        'yF_bitwise_equal', S4.yF_exact == S1.yF_exact, ...
        'escape_keV_sum', sum(E4.ev.Eescape_keV)));
payload.gamma = struct('nEv', gEv, 'source_type', char(cfgG.source.type), ...
    'mass_atten_cm2_per_g', double(cfgG.source.gamma_massatt_cm2_g.value), ...
    'rho_multiples', [1 2 3], 'wall_born_count', wallCnt, ...
    'gas_deposit_events', gasCnt, ...
    'production_responds_to_override', all(diff(wallCnt) > 0));
payload.selfcheck = struct('same_recipe_bitwise_reproducible', repro);

if ~payload.gamma.production_responds_to_override
    warning('tepc:probe:WallProductionInert', ...
        '伽马腿壁作用产额不随 rho_wall 覆盖项严格增 (%s): 采样侧可能又去读注册表常数', ...
        mat2str(wallCnt));
end

if opt.WriteFile
    tepc.io.writeJson(jf, payload);
    fid = fopen(lf, 'w', 'n', 'UTF-8');
    if fid >= 0
        cl = onCleanup(@() fclose(fid));
        fprintf(fid, 'uq_budget_refresh %s\n', stamp);
        fprintf(fid, 'recipe: config=%s sha16=%.16s stream=%s seed=%d runSeed=%d N=%d\n', ...
            payload.recipe.config, payload.recipe.config_sha256, streamKind, seed, seed, nEv);
        fprintf(fid, 'y_F 口径: %s —— 真值列, 不是仪器反演发布值, 不可跨批引用\n', ...
            payload.recipe.y_F_definition);
        fprintf(fid, 'context: P=%g Pa T=%g K E0=%g MeV lbar_t=%.4f um t_wall=%g m rho_wall=%.4f mode=%s\n', ...
            payload.context.pressure_Pa, payload.context.temperature_K, ...
            payload.context.energy_MeV, payload.context.lbar_tissue_um, ...
            payload.context.wall_thickness_m, rhoN, payload.context.site_mode);
        fprintf(fid, 'SELFCHECK same-recipe bitwise reproducible = %d\n', repro);
        fprintf(fid, 'NEUTRON yF_exact=%.8f  escape=%.6g  edepWall=%.6g\n', ...
            S1.yF_exact, payload.neutron.escape_keV_sum, payload.neutron.edep_wall_keV_sum);
        fprintf(fid, '  rho_wall x3 : gas_col_bitwise=%d  yF_bitwise=%d  yF=%.8f  escape=%.6g\n', ...
            payload.neutron.wall_rho_x3.gas_column_bitwise_equal, ...
            payload.neutron.wall_rho_x3.yF_bitwise_equal, S3.yF_exact, ...
            payload.neutron.wall_rho_x3.escape_keV_sum);
        fprintf(fid, '  t_wall   x5 : gas_col_bitwise=%d  yF_bitwise=%d  yF=%.8f  escape=%.6g\n', ...
            payload.neutron.wall_thickness_x5.gas_column_bitwise_equal, ...
            payload.neutron.wall_thickness_x5.yF_bitwise_equal, S4.yF_exact, ...
            payload.neutron.wall_thickness_x5.escape_keV_sum);
        fprintf(fid, 'GAMMA   N=%d  mu/rho=%.4g cm2/g  rho x1/x2/x3 -> wall_born=%s  gas_dep_ev=%s  responds=%d\n', ...
            gEv, payload.gamma.mass_atten_cm2_per_g, mat2str(wallCnt), mat2str(gasCnt), ...
            payload.gamma.production_responds_to_override);
        fprintf(fid, 'json = %s\n', localRel(jf, root));
    end
    fprintf('uqBudgetRefreshProbe: 产物 %s (+ 同名 .log)\n', localRel(jf, root));
end
out = payload;
end

function r = localRel(fp, root)
r = strrep(strrep(fp, root, ''), '\', '/');
r = strrep(r, '//', '/');
if ~isempty(r) && r(1) == '/'
    r = r(2:end);
end
end

function [E, extra] = legNeutron(cfg, geom, tables, nEv, seed, xopts)
% opts 一律显式给 tNext=0: 留空会让 AnalyticAdapter 走默认分支, 于是"seed 钉死"
% 仍然定不出同一个数 —— 预算表那两个 y_F 不可比, 根子就在这类缺项上。
rs = RandStream('Threefry', 'Seed', seed);
if isempty(fieldnames(xopts))
    [E, extra] = tepc.transport.AnalyticAdapter(cfg, geom, tables, rs, nEv, seed, ...
        struct('tNext', 0));
else
    [E, extra] = tepc.transport.AnalyticAdapter(cfg, geom, tables, rs, nEv, seed, ...
        struct('tNext', 0), xopts);
end
end

function [E, extra] = legNeutronGeom(cfg, g, tables, nEv, seed)
rs = RandStream('Threefry', 'Seed', seed);
[E, extra] = tepc.transport.AnalyticAdapter(cfg, g, tables, rs, nEv, seed, struct('tNext', 0));
end

function S = specOf(E, R)
S = tepc.analysis.buildSpectrum(E.ev.EdepGas_keV, R.lbar_tissue_um, E.ev.weight, R.edges);
end

function [cfgG, cnt, gasN] = legGammaSweep(cfg, geom, tables, gEv, rhoN)
cfgG = cfg;
cfgG.source.type = "mono_gamma";
mult = [1 2 3];
cnt = zeros(1, 3);
gasN = zeros(1, 3);
for k = 1:3
    rs = RandStream('Threefry', 'Seed', 91007);
    [E, ~] = tepc.transport.AnalyticAdapter(cfgG, geom, tables, rs, gEv, 91007, ...
        struct('tNext', 0), struct('rho_wall_g_cm3', mult(k)*rhoN));
    cnt(k) = nnz(bitand(E.ev.flags, uint32(8192)) > 0);
    gasN(k) = nnz(E.ev.EdepGas_keV > 0);
end
end
