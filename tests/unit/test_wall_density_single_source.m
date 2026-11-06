function tests = test_wall_density_single_source
%TEST_WALL_DENSITY_SINGLE_SOURCE 壁密度的唯一来源: 常数注册表 -> csdaTransport。
%   锁的对象是"取数链路"而不是数值本身: 1.124 这个数错了由 measured_condition 负责,
%   但同一条链路上不允许再出现第二个持有该数的地方 (代码字面量 / 材料表镜像 / 调用方
%   覆盖), 否则改配置不改动输运结果 —— 那是静默失效, 不是精度问题。
%   物理依据: 壁内射程 R = ∫dE/(S(E)*rho), rho 偏低一千倍 (kg/m3 当成 g/cm3 用) 会让
%   射程放大一千倍, 壁能损趋零而逃逸份额趋满, 账本照样闭合 => 只有量级窗口能挡住它。
tests = functiontests(localfunctions);
end

function [Tp, geom, rho] = transportCase()
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
geom = tepc.geometry.buildGeometry(cfg);
[rho, ~] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, cfg.gas.temperature_K, ...
    cfg.gas.composition_molfrac, 1.0);
Tp = tepc.transport.stoppingPower(cfg, "proton");
end

function out = runOne(Tp, geom, rho, opts)
out = tepc.transport.csdaTransport(Tp, [0; 0; 0], [1; 0; 0], 1.0, geom, rho, ...
    RandStream('Threefry', 'Seed', 7), opts);
end

%% ==================== 默认取值必须来自注册表, 且随结果交出处 ====================

function test_default_density_comes_from_registry(tc)
[Tp, geom, rho] = transportCase();
out = runOne(Tp, geom, rho, struct('straggle', false));
want = double(tepc.config.constants('transport.a150.density_g_cm3'));
tc.verifyEqual(out.rhoWall_g_cm3, want, 'AbsTol', 0, ...
    sprintf('壁密度实得 %.12g, 注册表登记 %.12g', out.rhoWall_g_cm3, want));
tc.verifyTrue(isfield(out, 'rhoWallSource'), ...
    '出参必须带 rhoWallSource, 否则报告读者无法知道这个数从哪来');
s = out.rhoWallSource;
tc.verifyEqual(string(s.kind), "config", ...
    sprintf('未给覆盖项时来源必须是 config, 实得 %s', char(string(s.kind))));
tc.verifyEqual(string(s.const_id), "transport.a150.density_g_cm3");
tc.verifyEqual(string(s.units), "g/cm^3");
tc.verifyMatches(char(string(s.reader)), 'tepc\.config\.constants');
tc.verifyEqual(s.value_g_cm3, want, 'AbsTol', 0, '来源记录里的值必须与实际消费的值同一个');
end

%% ==================== 源码里不得再留数值镜像 ====================

function test_transport_source_holds_no_density_literal(tc)
root = tepc.io.projectRoot();
d = fullfile(root, 'src', '+tepc', '+transport');
txt = readUtf8(fullfile(d, 'csdaTransport.m'));
% 去掉每行 % 之后的注释再搜: 注释里提一句单位口径是允许的, 代码里留镜像不是。
code = regexprep(txt, '%[^\r\n]*', '');
tc.verifyFalse(contains(code, '1.124'), ...
    'csdaTransport 的代码/字面量里仍出现 1.124: 壁密度又有了第二处真相');
tc.verifyTrue(contains(code, 'tepc.transport.wallDensity('), ...
    'csdaTransport 不再经唯一取数点 tepc.transport.wallDensity 取壁密度');
wtxt = readUtf8(fullfile(d, 'wallDensity.m'));
tc.verifyTrue(contains(wtxt, "constants('transport.a150.density_g_cm3')"), ...
    'wallDensity 没读注册表: 条目里的 wired=true 就是假登记');
% 整个输运层只许有一处取数点: 逐文件剥注释后搜字面量, 出现第二处即红
mirror = 0;
for f = ["csdaTransport.m", "wallDensity.m", "AnalyticAdapter.m"]
    t2 = regexprep(readUtf8(fullfile(d, char(f))), '%[^\r\n]*', '');
    mirror = mirror + numel(strfind(t2, '1.124'));
end
msgMirror = sprintf('输运层代码里有 %d 处 1.124 字面量: 壁密度只许在常数注册表里有一份', mirror);
tc.verifyEqual(mirror, 0, msgMirror);
end

%% ==================== 材料表镜像必须与注册表同值 ====================

function test_material_mirror_agrees_with_registry(tc)
root = tepc.io.projectRoot();
% 走 deviceSpec 而不是自己 jsondecode 材料表: null 的表示 (空 / NaN) 由它归一,
% 本锁要核的是"两处同值必须同步改", 不该把解析细节再写一遍。
dev = tepc.geometry.deviceSpec(fullfile(root, 'geometry', 'device_v2.json'));
m = dev.materials;
ix = find(string({m.material_id}) == "a150", 1);
tc.verifyFalse(isempty(ix), '材料表里没有 a150 条目, 本锁无从核对');
e = m(ix);
want = double(tepc.config.constants('transport.a150.density_g_cm3'));
tc.verifyEqual(double(e.density_g_cm3), want, 'AbsTol', 0, ...
    sprintf(['材料表 a150 的 density_g_cm3 (%.12g) 与常数注册表 (%.12g) 分叉: ' ...
        '两处同值的镜像必须同时改, 改一处即红'], double(e.density_g_cm3), want));
tc.verifyTrue(noValue(e.density_kg_m3), ...
    '同一材料不得同时给 kg/m3 与 g/cm3 两种写法 (表头规则), 否则换算谁做没有答案');
tc.verifyFalse(isempty(strfind(string(e.source_document), 'transport.a150.density_g_cm3')), ...
    '镜像必须在自己条目里声明它的来源常数, 否则读表的人无从知道该改哪一处');
end

function tf = noValue(v)
% JSON null 经 deviceSpec 归一后可能是空数组, 也可能是 NaN 占位 —— 两者都表示
% "这一单位形式没有登记"。
tf = isempty(v) || (isnumeric(v) && all(isnan(v(:))));
end

%% ==================== 调用方覆盖仍有效, 且来源记录要如实改口 ====================

function test_caller_override_is_honored_and_labelled(tc)
[Tp, geom, rho] = transportCase();
out = runOne(Tp, geom, rho, struct('straggle', false, 'rho_wall_g_cm3', 0.5));
tc.verifyEqual(out.rhoWall_g_cm3, 0.5, 'AbsTol', 0, '显式覆盖被注册表值顶掉了');
tc.verifyEqual(string(out.rhoWallSource.kind), "caller_override", ...
    '用了调用方的值却仍标成 config: 来源记录在撒谎');
end

%% ==================== 负控: 量级窗口必须挡住单位口径错 ====================

function test_si_magnitude_density_is_rejected(tc)
[Tp, geom, rho] = transportCase();
f = @() runOne(Tp, geom, rho, struct('straggle', false, 'rho_wall_g_cm3', 1124));
tc.verifyError(f, 'tepc:csda:BadWallDensity', ...
    '把 1124 (kg/m3 量级) 写进 g/cm3 字段必须被拒: 否则壁射程放大一千倍, 壁能损静默归零');
end

%% ==================== 密度确实进了账本: 减半 => 逃逸增多、壁沉积减少 ====================

function test_density_actually_drives_wall_partition(tc)
% 取一个与人造壁厚可比拟的射程, 让 1 - t/R 的差别大到不可能被舍入噪声吞掉:
% 1 MeV 质子在 A-150 里射程约 70 um (test_transport.m 的实测注), 壁厚取 20 um,
% 密度减半 => R 加倍 => 逃逸份额从约 0.71E 升到约 0.86E。方向唯一由 R 正比 1/rho 决定。
[Tp, geom, rho] = transportCase();
base = runOne(Tp, geom, rho, struct('straggle', false, 'wallThickness_m', 2e-5));
half = runOne(Tp, geom, rho, struct('straggle', false, 'wallThickness_m', 2e-5, ...
    'rho_wall_g_cm3', base.rhoWall_g_cm3/2));
tc.verifyGreaterThan(half.Eescape_keV, 1.05*base.Eescape_keV, ...
    sprintf('密度减半后逃逸份额必须上升 (>1.05x): 实得 %.6g -> %.6g', ...
    base.Eescape_keV, half.Eescape_keV));
tc.verifyLessThan(half.EdepWall_keV, 0.95*base.EdepWall_keV, ...
    sprintf('密度减半后壁内沉积必须下降 (<0.95x): 实得 %.6g -> %.6g', ...
    base.EdepWall_keV, half.EdepWall_keV));
for s = [base, half]
    tot = s.EdepGas_keV + s.EdepWall_keV + s.Eescape_keV;
    tc.verifyLessThan(abs(tot - 1000), 5, ...
        sprintf('账本 E0=EdepGas+EdepWall+Eescape 不闭合: 合计 %.6g keV', tot));
end
end

function test_run_summary_records_wall_density(tc)
% 出参要有产物层面的读者: 报告与 summary.json 必须能看到这次用的壁密度是多少、从哪一
% 条常数来的。取数点与被锁对象是同一个函数, 所以这里核的是链路而不是又抄一份数。
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
R = tepc.run.execute(cfg, 'N', 40, 'Seed', 3131, 'RunDir', tempname());
S = R.summary;
tc.verifyTrue(isfield(S, 'wall_rho_g_cm3'), 'summary 没记录壁密度');
tc.verifyEqual(double(S.wall_rho_g_cm3), ...
    double(tepc.config.constants('transport.a150.density_g_cm3')), 'AbsTol', 0);
tc.verifyEqual(string(S.wall_rho_source.kind), "config", ...
    'summary 记录的来源不是 config: 取数链路又分叉了');
end

function txt = readUtf8(f)
% 按字节显式 UTF-8 读: 本机默认字符集 GBK, fileread 会把中文按双字节解码并吞掉紧随
% 其后的换行字节, 行号与字符串比较都会错位。
fid = fopen(f, 'r', 'n', 'UTF-8');
if fid < 0
    error("tepc:tests:Unreadable", "无法读取 %s", f);
end
b = fread(fid, inf, 'char=>char');
fclose(fid);
txt = b(:)';
end
