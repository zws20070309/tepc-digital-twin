function rows = reconcileDeviceV2(varargin)
%RECONCILEDEVICEV2 逐零件逐字段对账: meshSpec 现在产出的零件表 vs 清单读出的零件表。
%
%   rows = reconcileDeviceV2()               打印表格并返回行结构数组
%   rows = reconcileDeviceV2('Csv', f)       同时把表格写成 UTF-8 无 BOM 的 CSV
%   rows = reconcileDeviceV2('Tol', 1e-9)    数值比对用的相对容差
%
% 两侧字段名不同源, 所以对照关系写在 compareSpec() 里逐条声明, 不按名字自动匹配:
%   meshSpec   material / materialStatus / transport_role / transport_mode /
%              display_only / coincident_with / shape.*
%   清单       material_id / value_status / transport_stage / transport_enabled +
%              field_enabled + display_enabled / surface_contact / primitive.*
%
% 判定词汇 (verdict):
%   MATCH            两侧都有值且相等 (文本逐字, 数值相对差 <= Tol)
%   DIFF             两侧都有值但不等
%   NOT_COMPARABLE   一侧刻意无值 (清单的 null 是"未登记", meshSpec 侧是运行时派生量)
%   ONLY_IN_MANIFEST 清单有该零件而 meshSpec 没有
%   ONLY_IN_MESH_SPEC meshSpec 有该零件而清单没有
%
% 布尔对照的语义差: meshSpec 只有一个 display_only (真值 = "不参与任何计算"), 清单把它
% 拆成 transport_enabled / field_enabled / display_enabled 三个开关。这里按
% display_only == ~(transport_enabled | field_enabled) 比, 即"是否只画不算"。
%
% 本工具是只读的: 不写 geometry/ 下的任何文件, 也不改 meshSpec —— 换源是另一步。

    p = inputParser;
    p.addParameter('Csv', '', @(x) ischar(x) || isstring(x));
    p.addParameter('Tol', 1e-9, @(x) isnumeric(x) && isscalar(x) && x > 0);
    p.parse(varargin{:});
    opt = p.Results;
    tol = double(opt.Tol);

    root = tepc.io.projectRoot();
    cfg = tepc.config.load(fullfile(root, 'config', 'defaults', 'demo_only.json'));
    R = tepc.config.resolve(cfg);
    spec = tepc.geometry.meshSpec(cfg, R);
    dev = tepc.geometry.deviceSpec();

    mp = partIndex(spec.parts, 'part_id');
    dp = partIndex(dev.parts, 'part_id');
    ids = union(string(fieldnames(mp)).', string(fieldnames(dp)).');
    ids = sort(ids);

    rows = struct('part_id', {}, 'field', {}, 'meshSpec', {}, 'manifest', {}, ...
        'verdict', {}, 'note', {});

    for i = 1:numel(ids)
        id = ids(i);
        if ~isfield(mp, char(id))
            rows(end+1) = row(id, "(零件)", "-", char(id), ...
                "ONLY_IN_MANIFEST", "meshSpec 未产出该零件"); %#ok<AGROW>
            continue;
        end
        if ~isfield(dp, char(id))
            rows(end+1) = row(id, "(零件)", char(id), "-", ...
                "ONLY_IN_MESH_SPEC", "清单未登记该零件"); %#ok<AGROW>
            continue;
        end
        mpart = mp.(char(id));
        dpart = dp.(char(id));
        tbl = compareSpec();
        for j = 1:numel(tbl)
            q = tbl(j);
            rows(end+1) = judge(id, q, mpart, dpart, tol); %#ok<AGROW>
        end
    end

    % 只写在 spec 顶层、零件 shape 里没有的量: 壁厚 (壁的 shape 只有外半径, 厚度是内外
    % 半径之差)、丝长 (圆柱阳极的 height 在 anodeLength_m 里)、源锥高度 (顶点与底心之差)。
    coneH = NaN;
    if isfield(spec, 'source')
        apex = fieldOr(spec.source, 'coneApex_m');
        base = fieldOr(spec.source, 'coneBaseCenter_m');
        if isnumeric(apex) && isnumeric(base) && numel(apex) >= 3 && numel(base) >= 3
            % 锥高是顶点到底心的距离, 不是 z 分量之差: 源方向现在可以斜, 只取 z 会把斜锥
            % 的高度算短, 于是"清单 vs 网格"的比对在斜方向上系统性偏。
            coneH = norm(double(apex(1:3)) - double(base(1:3)));
        end
    end
    rows(end+1) = cmpRow("wall", "thickness_m(spec)", valOf(spec, "wallThickness_m"), ...
        valOf(dp.wall, "primitive.thickness_m"), tol); %#ok<AGROW>
    rows(end+1) = cmpRow("anode", "height_m(spec)", valOf(spec, "anodeLength_m"), ...
        valOf(dp.anode, "primitive.height_m"), tol); %#ok<AGROW>
    rows(end+1) = cmpRow("source_cone", "cone_height_m(spec)", coneH, ...
        valOf(dp.source_cone, "primitive.length_m"), tol); %#ok<AGROW>

    printTable(rows);
    if ~isempty(strtrim(char(string(opt.Csv))))
        writeCsv(char(string(opt.Csv)), rows);
        fprintf('reconcileDeviceV2: CSV -> %s\n', char(string(opt.Csv)));
    end
end

%% ==================== 对照表 ====================

function t = compareSpec()
% 每条 = 一个可比字段。kind: 'text' 逐字比, 'num' 相对容差比, 'onlyMesh'/'onlyMan'
% 表示只有一侧有这个概念 (仍把两边的值打出来, 判 NOT_COMPARABLE)。
    t = [
        spec1("label", "text", "label", "label");
        spec1("material", "text", "material", "material_id");
        spec1("value_status", "text", "materialStatus", "value_status");
        spec1("transport_stage", "text", "transport_mode", "transport_stage");
        spec1("transport_enabled", "derive_role", "transport_role", "transport_enabled");
        spec1("display_only", "derive_only", "display_only", "display_enabled");
        spec1("coincident_with", "text", "coincident_with", "surface_contact");
        spec1("shape.type", "text", "shape.type", "primitive.type");
        spec1("radius_m", "num", "shape.radius_m", "primitive.radius_m");
        spec1("outer_radius_m", "num", "shape.radius_m", "primitive.outer_radius_m");
        spec1("thickness_m", "num", "-", "primitive.thickness_m");
        spec1("half_m", "num", "shape.half_m", "primitive.half_m");
        spec1("height_m", "num", "shape.height_m", "primitive.height_m");
        spec1("length_m", "num", "shape.height_m", "primitive.length_m");
        spec1("half_angle_deg", "num", "-", "primitive.half_angle_deg");
        spec1("parent_id", "text", "-", "parent_id");
        spec1("source_document", "text", "-", "source_document");
        spec1("tolerance_m", "num", "-", "tolerance_m");
        spec1("temperature_K", "num", "-", "temperature_K");
        spec1("meshVertices", "num", "meshVertices", "-");
        spec1("analyticVolume_m3", "num", "analyticVolume_m3", "-");
    ];
end

function s = spec1(field, kind, meshPath, manPath)
    s = struct('field', field, 'kind', kind, 'meshPath', meshPath, 'manPath', manPath);
end

%% ==================== 判定 ====================

function r = judge(id, q, mpart, dpart, tol)
% 两种派生对照要在比之前先归一 (见文件头"布尔对照的语义差"):
%   derive_role: meshSpec 的 transport_role {enter_mc, passive} -> {true, false}
%   derive_only: 清单没有 display_only, 等价式是 ~(transport_enabled | field_enabled)
    [mv, mOk] = getByPath(mpart, q.meshPath);
    [dv, dOk] = getByPath(dpart, q.manPath);
    note = "";
    if strcmp(q.kind, "derive_role")
        mv = mapRoleToFlag(mv);
    elseif strcmp(q.kind, "derive_only")
        [te, okT] = getByPath(dpart, "transport_enabled");
        [fe, okF] = getByPath(dpart, "field_enabled");
        dOk = okT && okF;
        dv = "false";
        if dOk && isOnlyInactive(te) && isOnlyInactive(fe)
            dv = "true";              % 两条链都不进 = 只画不算, 等价于 display_only
        end
        note = "清单侧由 ~(transport_enabled | field_enabled) 推得";
    end
    ms = fmtVal(mv, mOk);
    ds = fmtVal(dv, dOk);
    if ~mOk && ~dOk
        v = "NOT_COMPARABLE";
        note = "两侧都没有该字段";
    elseif ~mOk
        v = "NOT_COMPARABLE";
        note = "meshSpec 侧无此概念 (清单登记的是未登记的几何量或运行时派生量)";
    elseif ~dOk
        v = "NOT_COMPARABLE";
        note = "清单侧无此字段或刻意留 null";
    elseif strcmp(q.kind, "num")
        a = toNum(mv);
        b = toNum(dv);
        if isnan(a) || isnan(b)
            v = "NOT_COMPARABLE";
            note = "存在 NaN 分量, 无法比对";
        else
            den = max([abs(a), abs(b), eps]);
            if abs(a - b) <= tol * den
                v = "MATCH";
            else
                v = "DIFF";
                note = sprintf('相对差 %.3e', abs(a - b) / den);
            end
        end
    else
        a = toText(mv);
        b = toText(dv);
        if a == b
            v = "MATCH";
        elseif lower(a) == lower(b)
            v = "DIFF";
            note = "仅大小写不同";
        else
            v = "DIFF";
        end
    end
    r = row(id, q.field, ms, ds, v, note);
end

function s = mapRoleToFlag(v)
% enter_mc -> true, passive -> false; 其他值原样返回 (让 DIFF 去报)。
    t = lower(strtrim(toText(v)));
    if t == "enter_mc"
        s = "true";
    elseif t == "passive"
        s = "false";
    else
        s = v;
    end
end

function tf = isOnlyInactive(v)
% 零件的这个开关是否"关着" (false / 空 / 非零数值一律按开)。
    tf = false;
    if isempty(v)
        tf = true;
        return;
    end
    if islogical(v)
        tf = ~logical(v);
    elseif isnumeric(v)
        tf = double(v(1)) == 0;
    end
end

function r = row(id, field, mv, dv, verdict, note)
    r = struct('part_id', char(id), 'field', char(field), 'meshSpec', char(mv), ...
        'manifest', char(dv), 'verdict', char(verdict), 'note', char(note));
end

function r = cmpRow(id, field, a, b, tol)
% 数值行的捷径写法: NaN 表示"该侧没有这个量"。
    if isnan(a) || isnan(b)
        if isnan(a)
            r = row(id, field, "-", fmtVal(b, true), "NOT_COMPARABLE", "meshSpec 侧无此量");
        else
            r = row(id, field, fmtVal(a, true), "-", "NOT_COMPARABLE", "清单侧无此量");
        end
        return;
    end
    den = max([abs(a), abs(b), eps]);
    if abs(a - b) <= tol * den
        r = row(id, field, fmtVal(a, true), fmtVal(b, true), "MATCH", "");
    else
        r = row(id, field, fmtVal(a, true), fmtVal(b, true), "DIFF", ...
            sprintf('相对差 %.3e', abs(a - b) / den));
    end
end

function v = valOf(s, dotted)
    [v, ok] = getByPath(s, dotted);
    if ~ok || ~(isnumeric(v) || islogical(v))
        v = NaN;
    elseif isempty(v)
        v = NaN;
    end
    v = double(v(1));
end

function s = fmtVal(v, ok)
    if ~ok
        s = "-";
        return;
    end
    if isnumeric(v) || islogical(v)
        if isempty(v)
            s = "-";
        elseif isvector(v) && ~isscalar(v)
            s = strjoin(string(v), ",");
        elseif islogical(v)
            if v, s = "true"; else, s = "false"; end
        else
            s = sprintf('%.17g', double(v));
        end
    elseif isempty(v)
        s = "-";
    else
        s = strtrim(string(v));
        if strlength(s) > 60
            s = extractBefore(s, 61) + "…";
        end
    end
    s = char(s);
end

function x = toNum(v)
    x = NaN;
    if isnumeric(v) || islogical(v)
        if ~isempty(v)
            x = double(v(1));
        end
    elseif ischar(v) || isstring(v)
        x = str2double(string(v));
    end
end

function s = toText(v)
    if islogical(v)
        if v, s = "true"; else, s = "false"; end
    elseif isnumeric(v)
        s = string(sprintf('%.17g', double(v(1))));
    else
        s = strtrim(string(v));
    end
    if numel(s) > 1
        s = s(1);
    end
end

%% ==================== 取值 ====================

function idx = partIndex(parts, key)
% 零件表 -> 以 part_id 为字段名的容器 (下标用 char 作字段名时先净化)。
    idx = struct();
    for k = 1:numel(parts)
        id = strtrim(string(fieldOr(parts(k), key)));
        f = sanitizeField(char(id));
        if f == ""
            continue;
        end
        idx.(char(f)) = parts(k);
    end
end

function f = sanitizeField(s)
% MATLAB 字段名只允许 字母/数字/下划线 且不得以数字开头。
    f = regexprep(string(s), '[^A-Za-z0-9_]', '_');
    if f ~= "" && f(1) >= '0' && f(1) <= '9'
        f = "_" + f;
    end
end

function [v, ok] = getByPath(s, dotted)
% 按 a.b.c 取字段; 任一段缺失或值为空 (JSON null) 都算"没有值" -> ok=false。
    v = [];
    ok = false;
    if strcmp(dotted, "-")
        return;
    end
    cur = s;
    seg = strsplit(string(dotted), ".");
    for i = 1:numel(seg)
        if iscell(cur) && numel(cur) == 1
            cur = cur{1};
        end
        if ~isstruct(cur) || ~isscalar(cur) || ~isfield(cur, char(seg(i)))
            return;
        end
        cur = cur.(char(seg(i)));
    end
    if iscell(cur) && numel(cur) == 1
        cur = cur{1};
    end
    if isempty(cur)
        return;
    end
    v = cur;
    ok = true;
end

function v = fieldOr(s, nm)
    if isstruct(s) && isfield(s, nm)
        v = s.(nm);
    else
        v = "";
    end
end

%% ==================== 输出 ====================

function printTable(rows)
% MATLAB 的 fprintf 不支持 C 的 '*' 宽度说明符, 所以列宽由 pad 手工补齐。
    W = [22 17 34 34 18];
    hdr = {'part_id', 'field', 'meshSpec', 'manifest', 'verdict'};
    fprintf('\n== meshSpec vs deviceSpec 对账 (%d 行) ==\n', numel(rows));
    fprintf('%s %s %s %s %s %s\n', pad(hdr{1}, W(1)), pad(hdr{2}, W(2)), ...
        pad(hdr{3}, W(3)), pad(hdr{4}, W(4)), pad(hdr{5}, W(5)), 'note');
    for k = 1:numel(rows)
        r = rows(k);
        fprintf('%s %s %s %s %s %s\n', pad(r.part_id, W(1)), pad(r.field, W(2)), ...
            pad(r.meshSpec, W(3)), pad(r.manifest, W(4)), pad(r.verdict, W(5)), r.note);
    end
    v = string({rows.verdict});
    ids = string({rows.part_id});
    bad = v == "DIFF" | v == "ONLY_IN_MANIFEST" | v == "ONLY_IN_MESH_SPEC";
    nDiff = nnz(bad);
    nMatch = nnz(v == "MATCH");
    nNC = nnz(v == "NOT_COMPARABLE");
    badParts = unique(ids(bad));
    allParts = unique(ids);
    okParts = setdiff(allParts, badParts);
    fprintf(['\n汇总: 行 MATCH=%d DIFF/缺失=%d NOT_COMPARABLE=%d\n' ...
             '零件: 无差异 %d / 有差异 %d (共 %d)\n有差异零件: %s\n'], ...
        nMatch, nDiff, nNC, numel(okParts), numel(badParts), numel(allParts), ...
        strjoin(badParts, ", "));
end

function s = pad(x, w)
    s = char(string(x));
    if numel(s) > w - 1
        s = [s(1:max(1, w - 2)), '+'];
    else
        s = [s, blanks(max(0, w - 1 - numel(s)))];
    end
end

function writeCsv(f, rows)
% UTF-8 无 BOM, 逐行 fprintf: fwrite(unicode2native(char(矩阵))) 会把含换行的字符串炸掉。
    fid = fopen(f, 'w', 'n', 'UTF-8');
    if fid < 0
        error("tepc:reconcile:CsvWrite", "无法写 CSV: %s", f);
    end
    cleanup = onCleanup(@() fclose(fid));
    fprintf(fid, 'part_id,field,meshSpec,manifest,verdict,note\n');
    for k = 1:numel(rows)
        r = rows(k);
        fprintf(fid, '%s,%s,%s,%s,%s,%s\n', q(r.part_id), q(r.field), q(r.meshSpec), ...
            q(r.manifest), q(r.verdict), q(r.note));
    end
    clear cleanup
end

function s = q(x)
    s = strrep(string(x), '"', '""');
    s = strrep(s, ",", "，");          % 逗号换成全角: 不破坏 CSV 分列
    s = sprintf('"%s"', char(s));
end
