function [wR, meta] = radiationWeighting(E, varargin)
%RADIATIONWEIGHTING 中子辐射权重因子 w_R(E_n) —— ICRP 103 式 (2.8) 的三段函数。
%
% 出处: ICRP Publication 103 (Ann. ICRP 37(2-4)) 付属書 B; 本仓从 ICRP 116 官方全文
%   (仓内 ICRP_P116_ja_official.pdf 第 47 页) 的表 2.1 与式 (2.8) 抄取, 系数落在
%   config/reference/icrp103_neutron_wR_branches.csv —— 代码里不写死数值, 单一真相源在那张表。
%
% 与 tepc.analysis.qualityFactor 的分工: 那个是 TEPC 微剂量学里的品质因子 Q(y) (按传能线密度),
% 本函数是辐射防护的 w_R(E_n) (按入射中子能量)。两者不得互相顶替: Q(y) 吃的是局部能谱,
% w_R 吃的是未碰撞粒子的入射能量。
%
% 为什么系数必须逐能量乘: ICRP 116 的 C.12/C.27/F.3 给的是吸收剂量/注量 (pGy*cm2),
% 要当量剂量 (Sv) 就得乘 w_R(E)。大气中子剂量的主要贡献落在 100 MeV-1 GeV, 那里 w_R 只有
% 2.5-5; 若按"中子=20"这一个常数算, 高能段会被夸大约 4-8 倍。
%
% 用法: wR = radiationWeighting(E_MeV)                  任意形状实数数组, 输出同形状
%       [wR, meta] = radiationWeighting(E, 'tablePath', p)
%   meta 带三段系数、断点跳变实测值与出处。tablePath 是刻意留的反例口子: 装载期自检
%   (段数/覆盖/跳变) 只有在能被指到一张坏表时才算真被测过, 否则那条守卫是"永远绿"。
%
% 装载期自检 (不通过即报错, 不给数):
%   段数必须是 3; 覆盖 (0, Inf) 且相邻段边界相接; 系数为正且量级合理;
%   断点处两支同点取值的相对跳变 <= 1e-3 —— 原文是"近似连续"的经验拟合 (实测 3.96e-4 与
%   7.29e-4), 不是精确恒等, 所以阈值留了一倍余量, 不写成"必须为 0"。
%
% 能量归属: E=1 与 E=50 都归第 2 段, 与原文 "<1 / 1<=E<=50 / >50" 一致。

p = inputParser;
p.addParameter('tablePath', '', @(s) (ischar(s) && ~isempty(s)) || (isstring(s) && strlength(s) > 0));
p.parse(varargin{:});
tab = char(p.Results.tablePath);
if isempty(tab)
    tab = fullfile(tepc.io.projectRoot(), 'config', 'reference', ...
        'icrp103_neutron_wR_branches.csv');
end
[BR, JUMP] = loadBranches(tab);

if ~(isnumeric(E) && isreal(E))
    error("tepc:wR:BadInput", "E 必须是实数数组 (单位 MeV), 实得 %s", class(E));
end
if any(E(:) <= 0) || any(~isfinite(E(:)))
    error("tepc:wR:BadInput", "中子能量必须为正的有限值 [MeV]");
end
Ev = E(:);
wR = zeros(size(Ev));
for i = 1:size(BR, 1)
    % 归属逐字照原文 "<1 / 1<=E<=50 / >50": 中间段含两端, 末段严格大于下界。
    % 覆盖顺序依赖这一点 —— 末段若也用 >=, E=50 会被第 3 段抢走 (两支差 7.3e-4);
    % 首段用 >= 会把 E=0 也算进来, 但正值校验已先拦掉 0。
    if isinf(BR(i, 3))
        m = Ev > BR(i, 2);
    else
        m = Ev >= BR(i, 2) & Ev <= BR(i, 3);
    end
    wR(m) = evalRow(BR(i, :), Ev(m));
end
if any(wR == 0)
    error("tepc:wR:Uncovered", "有能量点没落进任何一段 (检查表的覆盖区间)");
end
wR = reshape(wR, size(E));
if nargout > 1
    meta = struct( ...
        'source', "ICRP 103 式(2.8), 抄自 ICRP 116 表2.1/图2.1 (仓内 ICRP_P116_ja_official.pdf p47)", ...
        'table', string(tab), 'branches', BR, 'boundary_jump_rel', JUMP, ...
        'peak_MeV', 1.0, 'peak_wR', evalRow(BR(2, :), 1.0), ...
        'branch_at_1_and_50', 2, ...
        'note', "断点处两段同点取值差 3.96e-4 / 7.29e-4: 经验拟合的近似连续, 不是精确恒等");
end
end

function [BR, JUMP] = loadBranches(path)
if ~isfile(path)
    error("tepc:wR:MissingTable", "w_R 分段表不存在: %s", path);
end
raw = strsplit(strtrim(fileread(path)), newline);
raw = raw(~cellfun(@(s) isempty(strtrim(s)) || startsWith(strtrim(s), '#'), raw));
if numel(raw) < 2
    error("tepc:wR:EmptyTable", "%s 没有数据行", path);
end
hdr = strsplit(strtrim(raw{1}), ',');
need = {'branch', 'E_low_MeV', 'E_high_MeV', 'offset', 'amplitude', ...
    'log_arg_factor', 'exponent_divisor'};
for i = 1:numel(need)
    if ~any(strcmp(hdr, need{i}))
        error("tepc:wR:NoColumn", "表头缺列 %s", need{i});
    end
end
M = zeros(numel(raw) - 1, numel(hdr));
for i = 2:numel(raw)
    f = strsplit(strtrim(raw{i}), ',');
    if numel(f) ~= numel(hdr)
        error("tepc:wR:RaggedCsv", "第 %d 行列数与表头不符", i);
    end
    for j = 1:numel(f)
        v = str2double(f{j});
        if isnan(v) && strcmpi(strtrim(f{j}), 'Inf')
            v = Inf;
        end
        if isnan(v)
            error("tepc:wR:RaggedCsv", "第 %d 行第 %d 列不是数值: %s", i, j, f{j});
        end
        M(i-1, j) = v;
    end
end
col = @(name) find(strcmp(hdr, name), 1);
BR = M(:, [col('branch'), col('E_low_MeV'), col('E_high_MeV'), col('offset'), ...
    col('amplitude'), col('log_arg_factor'), col('exponent_divisor')]);
if size(BR, 1) ~= 3
    error("tepc:wR:BranchCount", "式(2.8) 应是 3 段, 实得 %d", size(BR, 1));
end
if BR(1, 2) ~= 0 || ~isinf(BR(end, 3))
    error("tepc:wR:Coverage", "三段必须覆盖 (0, Inf): 实得 %g..%g", BR(1, 2), BR(end, 3));
end
nb = size(BR, 1);
for i = 1:nb - 1
    if BR(i, 3) ~= BR(i+1, 2)
        error("tepc:wR:Coverage", "第 %d/%d 段边界不接: %g vs %g", i, i+1, BR(i, 3), BR(i+1, 2));
    end
    if any(BR(i, 4:7) <= 0) || any(BR(i, 4:7) > 1e3)
        error("tepc:wR:BadCoeff", "第 %d 段系数非正或量级异常: %s", i, mat2str(BR(i, 4:7)));
    end
end
JUMP = zeros(nb - 1, 1);
for i = 1:nb - 1
    Eb = BR(i, 3);
    w1 = evalRow(BR(i, :), Eb); w2 = evalRow(BR(i+1, :), Eb);
    JUMP(i) = abs(w2 / w1 - 1);
    if JUMP(i) > 1e-3
        error("tepc:wR:BoundaryJump", ...
            "E=%g MeV 处两段取值差 %.3e (>1e-3): 抄表出错或原文不是同一条拟合", Eb, JUMP(i));
    end
end
end

function w = evalRow(row, E)
% w_R = offset + amplitude * exp( -[ln(log_arg_factor*E)]^2 / exponent_divisor )
w = row(4) + row(5) .* exp(-log(row(6) .* E).^2 / row(7));
end
