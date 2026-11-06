function tests = test_radiation_weighting
%TEST_RADIATION_WEIGHTING 中子 w_R(E) 三段函数 (ICRP 103 式 2.8) 的数值锁与自检反例腿。
%   四个用例:
%     shapeValues        12 个能量点的数值锁 (含峰值 20.69 @1 MeV 与两端趋 2.5)
%     branchOwnership    E=1 与 E=50 必须归第 2 段 —— 断点两侧取值差 4e-4/7.3e-4,
%                        写错归属会偏到另一支的值上, 这条判据正是用来抓它的
%     selfCheckGuards    装载期自检有牙: 改坏一个系数必须触发 BoundaryJump, 缺段/断覆盖必须触发
%     badInputs          非正/非数值/缺表三类坏输入的错名
%   为什么自检要单独测: 段数/覆盖/跳变三条守卫只在"表坏了"时才走异常分支; 真实表永远合法,
%   所以不拿合成坏表跑一遍, 那三条守卫就是恒绿的装饰。

tests = functiontests(localfunctions);
end

function test_shapeValues(tc)
E = [1e-9 1e-6 1e-3 0.025 0.1 1 5 20 50 100 1e3 1e4];
W = [2.500000 2.500000 2.506400 4.384100 10.021500 20.691793 ...
     12.025600 6.759900 5.495898 4.859300 2.836400 2.508200];
w = tepc.analysis.radiationWeighting(E);
tc.verifyEqual(w, W, 'RelTol', 2e-4, 'AbsTol', 1e-5);
[~, meta] = tepc.analysis.radiationWeighting(1);
tc.verifyEqual(meta.peak_wR, 20.691793, 'RelTol', 2e-4, '峰值 w_R (E=1 MeV)');
tc.verifyTrue(all(meta.boundary_jump_rel <= 1e-3), ...
    sprintf('断点跳变 %s 超 1e-3', mat2str(meta.boundary_jump_rel)));
% 单调形状: 1 MeV 之前升、之后降
tc.verifyTrue(all(diff(w(1:6)) >= 0), '低能段应单调上升');
tc.verifyTrue(all(diff(w(6:end)) < 0), '高能段应单调下降');
end

function test_branchOwnership(tc)
% 原文归属: <1 / 1<=E<=50 / >50。两支在断点同点取值不同 (20.700000 vs 20.691793;
% 5.495898 vs 5.499902), 所以只要写反归属, 这两个数就会跳到另一支上。
tc.verifyEqual(tepc.analysis.radiationWeighting(1), 20.691793, 'RelTol', 2e-6, ...
    'E=1 必须取第 2 段 (第 1 段会给 20.700000)');
tc.verifyEqual(tepc.analysis.radiationWeighting(50), 5.495898, 'RelTol', 2e-6, ...
    'E=50 必须取第 2 段 (第 3 段会给 5.499902)');
tc.verifyEqual(tepc.analysis.radiationWeighting(0.999999), 20.699998, 'RelTol', 1e-5, ...
    'E 略小于 1 才归第 1 段');
tc.verifyEqual(tepc.analysis.radiationWeighting(50.000001), 5.499902, 'RelTol', 1e-5, ...
    'E 略大于 50 才归第 3 段');
end

function test_selfCheckGuards(tc)
root = tepc.io.projectRoot();
src = fullfile(root, 'config', 'reference', 'icrp103_neutron_wR_branches.csv');
txt = fileread(src);
% 正控: 逐字节复制一份走 tablePath, 必须与原表同值 (口子本身不引入偏差)
copy = fullfile(tempdir, 'tepc_wR_copy.csv');
fid = fopen(copy, 'w'); fwrite(fid, unicode2native(string(txt), 'UTF-8')); fclose(fid);
tc.verifyEqual(tepc.analysis.radiationWeighting([0.1 10 200], 'tablePath', copy), ...
    tepc.analysis.radiationWeighting([0.1 10 200]), 'RelTol', 0, 'AbsTol', 0, ...
    '同一张表经口子读回来必须逐位相同');
% 反例 1: 第 1 段振幅 18.2 -> 19.0, E=1 处跳变变 3.9% -> 装载期自检必须拦下
bad = writeTemp('tepc_wR_jump.csv', strrep(txt, '1,0,1,2.5,18.2,1,6', '1,0,1,2.5,19.0,1,6'));
tc.verifyError(@()tepc.analysis.radiationWeighting(1, 'tablePath', bad), ...
    'tepc:wR:BoundaryJump');
% 反例 2: 少一段 -> BranchCount
bad2 = writeTemp('tepc_wR_short.csv', strrep(txt, '3,50,Inf,2.5,3.25,0.04,6', ''));
tc.verifyError(@()tepc.analysis.radiationWeighting(1, 'tablePath', bad2), ...
    'tepc:wR:BranchCount');
% 反例 3: 段间留缝 (第 2 段上界改 40) -> Coverage
bad3 = writeTemp('tepc_wR_gap.csv', strrep(txt, '2,1,50,5.0,17.0,2,6', '2,1,40,5.0,17.0,2,6'));
tc.verifyError(@()tepc.analysis.radiationWeighting(1, 'tablePath', bad3), ...
    'tepc:wR:Coverage');
end

function test_badInputs(tc)
tc.verifyError(@()tepc.analysis.radiationWeighting(0), 'tepc:wR:BadInput');
tc.verifyError(@()tepc.analysis.radiationWeighting([-1 5]), 'tepc:wR:BadInput');
tc.verifyError(@()tepc.analysis.radiationWeighting([1 Inf]), 'tepc:wR:BadInput');
tc.verifyError(@()tepc.analysis.radiationWeighting("1"), 'tepc:wR:BadInput');
tc.verifyError(@()tepc.analysis.radiationWeighting(1, 'tablePath', ...
    fullfile(tempdir, 'tepc_wR_absent.csv')), 'tepc:wR:MissingTable');
end

function p = writeTemp(name, txt)
p = fullfile(tempdir, name);
fid = fopen(p, 'w');
if fid < 0
    error("tepc:test:CannotWrite", "写不出 %s", p);
end
fwrite(fid, unicode2native(string(txt), 'UTF-8'));
fclose(fid);
end
