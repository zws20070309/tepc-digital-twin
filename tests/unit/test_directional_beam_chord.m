function tests = test_directional_beam_chord
%TEST_DIRECTIONAL_BEAM_CHORD 准直束弦抽样: 方向在哪一维可观测, 在哪一维按构造不可观测。
%   四条互不相同的判据, 各挡一种"看着绿其实空转"的走法:
%     1) 球腔换 beamDir 后 L **逐位不变**, 而出射点必须变 —— 只核前一半的话,
%        "把方向参数吞掉"的假实现也能全绿; 两半一起核才说明方向真的走到了几何里,
%        只是球的弦长与它无关 (L=2*sqrt(R^2-b^2) 只挂撞击参数 b)。
%     2) 同 seed 下 parallel_beam 与 isotropic_external 的 L 逐位相同 —— 把"球的方向不可观测"
%        从散文变成等式 (两条分支的第一次 rand 都是 b, 所以是逐位而不是"接近")。
%     3) 有限圆柱 (H=2R) 轴向准直束: 均值弦 = H 且**零方差** (每条命中的射线都从一端板走到另一端板)。
%     4) 横向准直束: 均值弦 = pi*R/2, 两者之比 = 4/pi (+27.3%) —— 方向在这里是可观测的,
%        所以 3) 与 4) 的均值必须明显不同, 否则这两条分支可能抄自同一段代码。
%   语言/环境事实: functiontests 只收集单参数 (tc) 的 test_ 子函数, helper 一律带输出参数;
%   开括号后不能换行, 所以本文件里没有把 sprintf( 留在行尾的写法。
tests = functiontests(localfunctions);
end

%% ============================================================ 用例

function test_sphere_beam_direction_changes_points_not_lengths(tc)
% 判据 1: L 逐位不变 + 出射点必须变。
g = sphereGeom(); R = g.R_m;
rs1 = RandStream('Threefry', 'Seed', 4242);
rs2 = RandStream('Threefry', 'Seed', 4242);
Lz  = tepc.geometry.sampleChord(g, 20000, "parallel_beam", rs1, [0;0;1]);
Lo  = tepc.geometry.sampleChord(g, 20000, "parallel_beam", rs2, [1;1;1]/sqrt(3));
tc.verifyTrue(isequal(Lz, Lo), ...
    '球腔里换了束方向, L 就变了: 弦长本不该依赖方向 (L 只挂 b), 说明抽样里混进了方向相关量');
% 出射点必须不同: 若实现把 beamDir 吞掉 (退化成固定 z 向), L 也会"逐位不变", 那条判据就成了空转。
rsP = RandStream('Threefry', 'Seed', 4242);
rsQ = RandStream('Threefry', 'Seed', 4242);
[~, ~, Qz] = tepc.geometry.sampleChord(g, 200, "parallel_beam", rsP, [0;0;1]);
[~, ~, Qo] = tepc.geometry.sampleChord(g, 200, "parallel_beam", rsQ, [1;1;1]/sqrt(3));
tc.verifyFalse(isequal(Qz, Qo), ...
    '两个方向的出射点完全相同: 方向参数根本没进几何, 上面那条"L 不变"是假绿');
% 端点必须真在球面上 (否则求交/放置写错了也能对上均值)。入射点也要核: 上一版只查出射点,
% 于是 P_in = mid - d*half 被改成 P_in = mid (把入射点丢在球内) 也能 5/5 通过。
tc.verifyLessThanOrEqual(max(abs(sqrt(sum(Qz.^2,1)) - R)), 1e-12, '轴向束出射点不在球面上');
tc.verifyLessThanOrEqual(max(abs(sqrt(sum(Qo.^2,1)) - R)), 1e-12, '斜入束出射点不在球面上');
[~, PinZ] = tepc.geometry.sampleChord(g, 200, "parallel_beam", RandStream('Threefry','Seed',4242), [0;0;1]);
[LoB, PinO, QoB] = tepc.geometry.sampleChord(g, 200, "parallel_beam", RandStream('Threefry','Seed',4242), [1;1;1]/sqrt(3));
tc.verifyLessThanOrEqual(max(abs(sqrt(sum(PinZ.^2,1)) - R)), 1e-12, '轴向束入射点不在球面上');
tc.verifyLessThanOrEqual(max(abs(sqrt(sum(PinO.^2,1)) - R)), 1e-12, '斜入束入射点不在球面上');
% 弦长必须等于**同一次调用**两端点之间的距离。上一轮我加的是"两端点中点落在过球心且垂直于 d
% 的平面上"—— 那条恒成立 (mid 由与 d 垂直的 u1/u2 张成), 挡不住任何端点错配, 已换掉。
% 另一处自伤: 先版本拿这次 200 样本的端点去比另一次 20000 样本调用里 L 的前 200 个 ——
% Threefry 不保证不同长度的请求共享前缀, 实测差到 1.8e-11 m (容差 2.5e-14) 而判红。
ch = sqrt(sum((QoB - PinO).^2, 1));
tc.verifyLessThanOrEqual(max(abs(ch - LoB.')), 1e-12*R, ...
    '弦长与两端点距离不等: L 与端点是分开算的, 两者可以各自都对但配不成一条弦');
% 缺省方向必须真是 [0;0;1]: 头部注释这么写, 没人用四参数调用过它就是个假承诺。
[~, Pdef, Qdef] = tepc.geometry.sampleChord(g, 200, "parallel_beam", RandStream('Threefry','Seed',4242));
tc.verifyTrue(isequal(Pdef, PinZ) && isequal(Qdef, Qz), ...
    '不传 beamDir 的结果与传 [0;0;1] 不一致: 注释里写的缺省方向没有实现');
% 单靠上一条是恒真的 (四参数与五参数都落在同一个默认值上, 默认值取什么都不影响它)。
% 配上"与另一个显式方向必须不同"才把默认值钉住: 默认若被改成 [0;1;0], 这条先红。
[~, Pdif, Qdif] = tepc.geometry.sampleChord(g, 200, "parallel_beam", ...
    RandStream('Threefry','Seed',4242), [0;1;0]);
tc.verifyFalse(isequal(Pdef, Pdif) && isequal(Qdef, Qdif), ...
    '缺省方向与 [0;1;0] 给出同一批端点: 上面那条"默认=[0;0;1]"是恒真判据');
end

function test_sphere_beam_matches_isotropic_lengths_bitwise(tc)
% 判据 2: 同 seed 下与 isotropic_external 的 L 逐位相同 (b 都是第一次抽样)。
g = sphereGeom();
rs1 = RandStream('Threefry', 'Seed', 777);
rs2 = RandStream('Threefry', 'Seed', 777);
Li = tepc.geometry.sampleChord(g, 50000, "isotropic_external", rs1);
Lb = tepc.geometry.sampleChord(g, 50000, "parallel_beam", rs2, [0;1;0]);
tc.verifyTrue(isequal(Li, Lb), ...
    '球的准直束与各向同性外源的 L 不逐位相同: 两者本应只差方向, 只差浮点重排不算发现');
m = mean(Lb); sec = std(Lb)/sqrt(numel(Lb));
tc.verifyLessThan(abs(m - 4*g.R_m/3)/sec, 6, ...
    '均值弦偏离 Cauchy 的 4R/3 超过 6 倍标准误');
end

function test_cylinder_axial_beam_is_exactly_height(tc)
% 判据 3: H=2R 的有限圆柱, 轴向准直束的每条弦都等于 H (零方差), 且命中点真在端板与半径内。
[g, R, H] = cylinderGeom();
[L, Pin, Pout] = tepc.geometry.sampleChord(g, 20000, "parallel_beam", RandStream('Threefry','Seed',31), [0;0;1]);
% 上一版这里写的是 numel(L)>0 —— L 在函数开头按 zeros(N,1) 预分配, 永远有 N 行, 那条断言
% 不可能失败。真正会失败的是"有的样本没被赋到值"(未命中的行留在 0), 所以查 min(L)>0。
tc.verifyGreaterThan(min(L), 0, '轴向束里有样本弦长为 0: 拒绝抽样没把它补上');
tc.verifyLessThanOrEqual(max(abs(L - H)), 1e-9*H, ...
    sprintf('轴向弦长不等于板间距 H (最大偏差 %g m)', max(abs(L - H))));
tc.verifyLessThanOrEqual(std(L)/H, 1e-9, '轴向束出现方差: 命中集合里混进了未穿体的样本');
% 端点约束是这条用例的杀伤力所在: 轴向弦长与撞击半径无关, 所以把 intersectLine 里的
% "par = ~nz & (px^2+py^2 < R^2)" 退化成 "par = ~nz" 时, 三条弦长判据照样全绿 ——
% 只有查入射/出射点是否真在半径内、真在端板上, 才拦得住这个改动。
tc.verifyLessThanOrEqual(max(sqrt(Pin(1,:).^2 + Pin(2,:).^2)), R, '轴向束入射点落在圆柱半径之外');
tc.verifyLessThanOrEqual(max(abs(abs(Pin(3,:)) - H/2)), 1e-12*H, '轴向束入射点不在端板上');
tc.verifyLessThanOrEqual(max(abs(abs(Pout(3,:)) - H/2)), 1e-12*H, '轴向束出射点不在端板上');
end

function test_cylinder_transverse_beam_matches_piR2(tc)
% 判据 4: 横向准直束均值弦 = pi*R/2 (平行束均值弦 = V/S_投影, 横向 S_投影 = 2R*H)。
[g, R, ~] = cylinderGeom();
L = tepc.geometry.sampleChord(g, 200000, "parallel_beam", RandStream('Threefry','Seed',31), [1;0;0]);
m = mean(L); sec = std(L)/sqrt(numel(L));
tc.verifyLessThan(abs(m - pi*R/2)/sec, 6, ...
    sprintf('横向均值弦 %g 与 pi*R/2=%g 差过 6 倍标准误 (sec=%g)', m, pi*R/2, sec));
% 非空转: 两个方向的均值必须明显不同, 否则 3) 与 4) 可能是同一段代码的两次调用。
La = tepc.geometry.sampleChord(g, 20000, "parallel_beam", RandStream('Threefry','Seed',31), [0;0;1]);
tc.verifyGreaterThan(abs(mean(La) - m)/m, 0.1, ...
    '轴向与横向均值几乎相同: 方向在有限圆柱上也没被用起来, 判据 3/4 双双失去意义');
% 比值的带必须按比值自己的标准误算: 轴向零方差, 横向那一份经 r = H/m 传播要乘 dr/dm = -H/m^2,
% 即 se_ratio = (4/pi)*sec/m。上一版把带写成 6*sec/m, 实际是 4.71 倍标准误却自称 6 倍 ——
% 方向保守 (只会更难红), 但措辞与判据不符。
seRatio = (4/pi) * sec / m;
tc.verifyLessThan(abs(mean(La)/m - 4/pi), 6*seRatio, ...
    sprintf('两方向均值比 %g 与 4/pi=%g 的差超过比值 6 倍标准误 (%g)', mean(La)/m, 4/pi, seRatio));
end

function test_beam_input_guards(tc)
% 负腿: 无限圆柱的横向投影是无界带, 没有外接圆盘可拒绝抽样; 零向量方向不是"缺省", 必须拒。
cfg = demoCfg(); cfg.geometry.type = 'cylinder_endless';
ge = tepc.geometry.buildGeometry(cfg);
rs = RandStream('Threefry', 'Seed', 5);
fEndless = @() tepc.geometry.sampleChord(ge, 100, "parallel_beam", rs, [1;0;0]);
tc.verifyError(fEndless, 'tepc:geometry:BeamUnsupported');
gs = sphereGeom();
fZero = @() tepc.geometry.sampleChord(gs, 100, "parallel_beam", rs, [0;0;0]);
tc.verifyError(fZero, 'tepc:geometry:BadBeamDir');
fNaN = @() tepc.geometry.sampleChord(gs, 100, "parallel_beam", rs, [1;NaN;0]);
tc.verifyError(fNaN, 'tepc:geometry:BadBeamDir');
% 归一化不改物理: [0;0;2] 与 [0;0;1] 必须给同一批弦长 (否则"方向"里混进了模长)。
[~, ~, Qa] = tepc.geometry.sampleChord(gs, 500, "parallel_beam", ...
    RandStream('Threefry', 'Seed', 9), [0;0;1]);
[~, ~, Qb] = tepc.geometry.sampleChord(gs, 500, "parallel_beam", ...
    RandStream('Threefry', 'Seed', 9), [0;0;2]);
tc.verifyTrue(isequal(Qa, Qb), '束方向的模长进了几何: 准直束只该由方向决定');
% 字符方向不是"缺省写法", 是一维输入 —— 必须拒, 不能靠归一化蒙混过去。
fChar = @() tepc.geometry.sampleChord(gs, 100, "parallel_beam", rs, 'z');
tc.verifyError(fChar, 'tepc:geometry:BadBeamDir');
end

%% ============================================================ 夹具

function cfg = demoCfg()
root = tepc.io.projectRoot();
cfg = tepc.config.load(fullfile(root,'config','defaults','demo_only.json'));
end

function g = sphereGeom()
g = tepc.geometry.buildGeometry(demoCfg());
tc0 = string(g.type);
assert(tc0 == "sphere", '发货几何不再是球, 本文件的"方向不可观测"前提要重述');
end

function [g, R, H] = cylinderGeom()
% 等径高有限圆柱 (H=2R): 轴向均值弦 = H = 2R, 横向 = pi*R/2, 比值 4/pi。
cfg = demoCfg();
R0 = tepc.geometry.buildGeometry(cfg).R_m;
cfg.geometry.type = 'cylinder_finite';
cfg.geometry.cylinderLength_mm = 2*R0*1e3;
g = tepc.geometry.buildGeometry(cfg);
R = g.R_m;
H = 2*sqrt(max(g.bboxR_m^2 - R^2, 0));
% 夹具自检: 容差按"这个 H 是两次开方再相减"的量级给, 不给 1e-15 (那只有几个 ulp, 换一次
% 发货半径就会把整文件的 5 条用例变成硬错误 —— 自检应当挡"夹具造错了", 不该挡浮点末位)。
assert(abs(H - 2*R) < 1e-12*R, '夹具没造出 H=2R, 4/pi 那条判据的解析值就无出处');
end
