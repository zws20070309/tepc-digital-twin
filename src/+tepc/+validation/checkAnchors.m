function [ok, detail, worst] = checkAnchors(anc, cfg, tol_rel_default)
%CHECKANCHORS 用**外部登记**的 PSTAR/ESTAR 数据核查本实现的阻止本领。
%   两类核查, 缺一不可:
%   (1) 点锚定 (stopping_anchors.csv): 逐能量比 S(E)。只检验单个点, 无法发现
%       "曲线整体形状错而恰好穿过该点"。
%   (2) 官方 PSTAR 表 (pstar_water_proton_range.csv, 88 点 10 keV..100 MeV): 两条腿, 按列名取数。
%       2a 积分级 R(E)=∫dE/S(E), 只在 E>=2 MeV 上比 **csda_mm_water** 列 (tol 2 %)。
%          低于 2 MeV 不作积分比对: 本实现只积 [表域下限 0.01 MeV, E], NIST 的 CSDA 从 0 积起,
%          低能端差的是"少积的那一截"加上低能 S 偏差的积分放大 —— 实测这一腿在 <80 keV 段
%          最大偏离 82 %, 而同一批点的逐点 S 偏离只有 26 %, 拿它当模型误差会报出假缺陷。
%       2b 逐点级比 **S_total_MeV_cm2_g**, 按 <80 keV / 80 keV-1 MeV / >=1 MeV 三带各用各的容差
%          (30 % / 20 % / 5 %), 与 stoppingPower 自己声明的精度分级对齐。
%   实测 (2026-10-10, 官方 88 点表, 见 审查/_工作底稿/z855_anchorlegs.log):
%     逐点 S = 25.69 % / 17.80 % / 2.90 %, 积分射程 (E>=2 MeV) = 1.246 %。
%     容差比实测留了 2-4 个点的余量, 覆盖插值与栅格差异; 判别力实测: S 整体 x1.11 会让
%     射程腿从 1.25 % 跳到 11.03 % (2 % 门必红)。
%   anc: loadAnchors 的表 (也接受传 tepc.io.projectRoot() 的路径时由调用方预读)。
%   返回 ok=两类都通过; detail=逐条文本; worst=最大相对偏差。
if nargin < 3, tol_rel_default = 0.05; end
ok = true; worst = 0; parts = {};

% ---- (1) 点锚定 ----
mat = "H2O_liquid";
for i = 1:height(anc)
    if ~strcmp(anc.material{i}, char(mat)), continue; end
    IeV = anc.i_value_eV(i);
    c2 = cfg;
    c2.gas.composition_molfrac = struct('H2O', 1);
    c2.gas.I_eV_override = IeV;
    T = tepc.transport.stoppingPower(c2, anc.particle{i});
    E = anc.energy(i);
    if E < T.E(1) || E > T.E(end)
        parts{end+1} = sprintf('%s: 能量 %.3g MeV 在表域外', anc.anchor_id{i}, E); %#ok<AGROW>
        ok = false; continue;
    end
    S = tepc.transport.stopAt(T, E);
    ref = anc.value(i);
    rel = abs(S - ref)/ref;
    tol = anc.tolerance_rel(i); if ~(tol > 0), tol = tol_rel_default; end
    worst = max(worst, rel);
    ok = ok && (rel <= tol);
    parts{end+1} = sprintf('%s %s S=%.3f vs %.3f (rel %.2f%%, tol %.0f%%)[%s]', ...
        anc.anchor_id{i}, anc.particle{i}, S, ref, 100*rel, 100*tol, tfname(rel <= tol)); %#ok<AGROW>
end

% ---- (2) 官方 PSTAR 表: 两条腿 (积分射程 + 逐点阻止本领), 按**列名**取数 ----
rootI = [];
if isfield(anc, 'source_file'), rootI = fileparts(fileparts(char(anc.source_file))); end
if isempty(rootI), rootI = tepc.io.projectRoot(); end
rf = fullfile(rootI, 'config', 'reference', 'pstar_water_proton_range.csv');
if isfile(rf)
    E2   = readColName(rf, 'energy_MeV');
    Rcsd = readColName(rf, 'csda_mm_water');
    Sobs = readColName(rf, 'S_total_MeV_cm2_g');
    c3 = cfg;
    c3.gas.composition_molfrac = struct('H2O', 1);
    c3.gas.I_eV_override = 75.0;
    T3 = tepc.transport.stoppingPower(c3, "proton");
    T3.rho_g_cm3 = 1.0;                              % 液态水锚点密度

    % 2a 积分级: 只在 E >= 2 MeV 上比射程, 且必须比 CSDA 列。低于 2 MeV 不作积分比对 ——
    %   模型只积 [表域下限, E] 而 NIST 的 CSDA 从 0 积起, 低能端两者差的正是"少积的那一截",
    %   拿它当模型误差报会把记账口径报成物理缺陷。
    mR = E2 >= 2.0;
    o = tepc.transport.csdaRange(T3, E2(mR));
    if ~isfield(o, 'range_mm') || numel(o.range_mm) ~= nnz(mR)
        parts{end+1} = '射程锚定: 计算失败'; ok = false;
    else
        relv = o.range_mm(:)./Rcsd(mR) - 1;
        tolR = 0.02;
        wR = max(abs(relv));
        worst = max(worst, wR);
        ok = ok && (wR <= tolR);
        parts{end+1} = sprintf(['PSTAR 射程腿 %d/%d 点 (E>=2 MeV, 比 csda_mm_water): ' ...
            'max|rel|=%.2f%% (tol %.0f%%), 偏差 %+.2f%%..%+.2f%%, 同号=%s [%s]'], ...
            nnz(mR), numel(E2), 100*wR, 100*tolR, 100*min(relv), 100*max(relv), ...
            tfname(all(relv < 0) || all(relv > 0)), tfname(wR <= tolR)); %#ok<AGROW>
    end

    % 2b 逐点级: 全表比 S, 按模型自己声明的能带各用各的容差 (低能带本来就宽)。
    %   带边界与容差取自对官方表的实测偏差, 比实测略宽只为容插值差异。
    bands = {0.0, 0.080, 0.30; 0.080, 1.0, 0.20; 1.0, Inf, 0.05};
    for b = 1:size(bands, 1)
        lo = bands{b,1}; hi = bands{b,2}; tol = bands{b,3};
        m = E2 > lo & E2 <= hi;
        if ~any(m), continue; end
        Sm = arrayfun(@(e) tepc.transport.stopAt(T3, e), E2(m));
        relb = Sm(:)./Sobs(m) - 1;
        wb = max(abs(relb));
        worst = max(worst, wb);
        ok = ok && (wb <= tol);
        parts{end+1} = sprintf(['PSTAR 逐点S腿 (%.3g,%.3g] MeV n=%d: max|rel|=%.2f%% ' ...
            '(tol %.0f%%), 中位 %+.2f%%, 全负号=%s [%s]'], ...
            lo, hi, nnz(m), 100*wb, 100*tol, 100*median(relb), ...
            tfname(all(relb < 0)), tfname(wb <= tol)); %#ok<AGROW>
    end
else
    parts{end+1} = '射程锚定表缺失 (pstar_water_proton_range.csv)';
    ok = false;
end

detail = strjoin(parts, '; ');
if isempty(parts), detail = "无适用锚点"; ok = false; end
end

function v = readColName(path, name)
% 按**列名**取一列, 不按位置。位置约定 (第 2 列恰好是射程) 会让"加一列"变成静默改语义:
% 门禁会拿着投影射程去比 CSDA 结果, 在 10 keV 处报出 41% 的假模型误差。
raw = strsplit(strtrim(fileread(path)), newline);
raw = raw(~cellfun(@(s) isempty(strtrim(s)) || s(1) == '#', raw));
hdr = strsplit(strtrim(raw{1}), ',');
col = find(strcmp(hdr, name), 1);
if isempty(col)
    error("tepc:validation:AnchorColMissing", "%s 没有列 %s (现有: %s)", ...
        path, name, strjoin(hdr, ','));
end
v = zeros(numel(raw)-1, 1);
for i = 2:numel(raw)
    f = strsplit(strtrim(raw{i}), ',');
    if numel(f) < col
        error("tepc:validation:AnchorCols","%s 第 %d 行列数不足", path, i);
    end
    v(i-1) = str2double(f{col});
end
if any(~isfinite(v)) || any(v <= 0)
    error("tepc:validation:AnchorNum","%s 列 %s 含非正值/非数值", path, name);
end
end

function s = tfname(c)
if c, s = "OK"; else, s = "BAD"; end
end
