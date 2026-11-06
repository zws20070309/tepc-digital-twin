function tests = test_device_v2_manifest
%TEST_DEVICE_V2_MANIFEST 装置清单 (geometry/device_v2.json + geometry/materials.json)
%   真的被读、真的被校验的锁。文件可以写得很漂亮而没有任何代码消费它, 那时它是装饰
%   而不是数据源。本文件因此从两条独立路径取证:
%     (1) 经 tepc.geometry.deviceSpec 读取 (校验器与被测对象同一份实现);
%     (2) 直接 jsondecode 盘上字节 + 正则数 null 的个数 (绕开校验器, 证明它没瞎报)。
%   两条路径的结论必须一致, 否则就是"读到的"与"文件里写的"分叉。
%
% 覆盖: 可解析与 schema / 每条零件带齐 19 个声明字段 / material_id 全部落进材料表 /
% 引用反向索引 / 声明可空集 == 实测空值集 (加一个或删一个 null 都会红) /
% transport_stage 不得全表同值且逐条等于按 part_id 的映射 / 几何量与
% config/defaults/demo_only.json 对账 / 1000 倍单位错的负对照 (改内存副本, 不改 JSON) /
% 父链成环与自引用 / 枚举不得含清单没用过的成员 / 派生量仍是 null。
tests = functiontests(localfunctions);
end

%% ==================== 夹具与助手 (名字不以 test 开头) ====================

function root = repoRoot()
root = tepc.io.projectRoot();
end

function txt = readUtf8(f)
% 显式 UTF-8 按字节读: 本机默认字符集是 GBK, fileread 会把中文按双字节解码并吞掉紧随
% 其后的换行字节, 行号与字符串比较都会错位。
    fid = fopen(f, 'r', 'n', 'UTF-8');
    if fid < 0
        error("tepc:tests:Unreadable", "无法读取 %s", f);
    end
    b = fread(fid, inf, 'char=>char');
    fclose(fid);
    txt = b(:)';
end

function dev = loadManifest()
dev = tepc.geometry.deviceSpec();
end

function raw = rawManifest()
raw = jsondecode(readUtf8(fullfile(repoRoot(), 'geometry', 'device_v2.json')));
end

function raw = rawMaterials()
raw = jsondecode(readUtf8(fullfile(repoRoot(), 'geometry', 'materials.json')));
end

function list = asList(v)
% jsondecode 会给出 char / string / 元胞 / 结构数组, 一律归一成 string 列向量。
    if isempty(v)
        list = strings(0, 1);
    elseif iscell(v)
        list = strings(numel(v), 1);
        for i = 1:numel(v)
            list(i) = string(v{i});
        end
    else
        list = reshape(string(v), [], 1);
    end
end

function s = txt1(v)
% 单值文本: JSON null 在 jsondecode 下是空 double, string([]) 会得到 0x1 的空 string
% 数组 (赋值给标量位就报元素数目不同), 所以空一律映射成 ""。char 整体转 string,
% 不能用 v(1) —— 那取到的是第一个**字符**而不是第一个元素。
    if iscell(v) && numel(v) == 1
        v = v{1};
    end
    if isempty(v)
        s = "";
        return;
    end
    s = strtrim(string(v));
    if numel(s) > 1
        s = s(1);
    end
end

function d = setDiff(a, b)
% 两个集合的对称差 (排序去重后的差集拼接): 空 = 集合相等。
    a = sort(unique(reshape(string(a), [], 1)));
    b = sort(unique(reshape(string(b), [], 1)));
    d = [a(~ismember(a, b)); b(~ismember(b, a))];
end
function g = geomOf(dev, id)
% dev.geometry 是逐零件归一化几何 (JSON null 与非正数一律 NaN), 按 part_id 取一条。
    w = strtrim(string(id));
    k = find(asList(string({dev.geometry.part_id}')) == w, 1);
    if isempty(k)
        error("tepc:tests:NoSuchPart", "清单里没有零件 %s", w);
    end
    g = dev.geometry(k);
end

%% ==================== 1. 两份清单真被读进来 ====================

function test_manifest_parses_and_declares_schema(tc)
dev = loadManifest();
tc.verifyEqual(txt1(dev.schema), "tepc-device-v2", ...
    'schema 改名要同步改 deviceSpec 的匹配式');
tc.verifyEqual(strtrim(string(dev.units_internal)), "SI");
tc.verifyEqual(dev.n_parts, 8, sprintf('零件数 = %d, 清单实际是 8 条', dev.n_parts));
tc.verifyEqual(numel(dev.parts), 8);
tc.verifyEqual(numel(unique(string({dev.parts.part_id}))), 8, 'part_id 有重复');
tc.verifyEqual(strtrim(string(dev.materials_ref)), "geometry/materials.json");
tc.verifyTrue(isfile(dev.materials_path), ...
    sprintf('materials_ref 指向的文件读不到: %s', char(dev.materials_path)));
tc.verifyEqual(numel(dev.materials), 5, '材料表条目数与清单登记不符');
end

function test_hashes_tie_the_two_files_together(tc)
% "读了但没读全"的特征是哈希只覆盖一份文件: 这里锁三条哈希各不相同且格式合法。
dev = loadManifest();
tc.verifyMatches(char(dev.sha256), '^[0-9a-f]{64}$', '几何内容哈希不是 64 位十六进制');
tc.verifyMatches(char(dev.materials_sha256), '^[0-9a-f]{64}$', '材料内容哈希不是 64 位十六进制');
tc.verifyMatches(char(dev.pair_sha256), '^[0-9a-f]{64}$', '配对哈希不是 64 位十六进制');
tc.verifyMatches(char(dev.file_sha256), '^[0-9a-f]{64}$', '清单字节哈希不是 64 位十六进制');
tc.verifyFalse(strcmp(char(dev.sha256), char(dev.materials_sha256)), ...
    '几何哈希与材料哈希相同: 两条规范化文本其实是同一份');
tc.verifyFalse(strcmp(char(dev.sha256), char(dev.file_sha256)), ...
    '内容哈希与字节哈希相同: 规范化没有生效');
tc.verifyEqual(strtrim(string(dev.geometry_sha256)), "computed_at_load", ...
    '清单里那是哨兵字符串: 被换成 64 位 hex 就说明有人在手填溯源');
end

%% ==================== 2. 字段带齐 ====================

function test_every_part_carries_every_declared_field(tc)
dev = loadManifest();
declared = sort(string(dev.declared_fields));
tc.verifyEqual(numel(declared), 19, ...
    sprintf('声明字段 %d 个, 清单每条实际 19 个键; 枚举漂移要一并改这里', numel(declared)));
raw = rawManifest();
bad = strings(0, 1);
for k = 1:numel(raw.parts)
    have = sort(string(fieldnames(raw.parts(k))).');
    miss = declared(~ismember(declared, have));
    extra = have(~ismember(have, declared));
    if ~isempty(miss) || ~isempty(extra)
        bad(end+1) = sprintf('%s: 缺 [%s] 多 [%s]', string(raw.parts(k).part_id), ...
            strjoin(miss, ','), strjoin(extra, ',')); %#ok<AGROW>
    end
end
tc.verifyEqual(bad, strings(0, 1), ...
    sprintf('盘上零件的字段集与 dev.declared_fields 不一致:\n  %s', strjoin(bad, '\n  ')));
for k = 1:numel(dev.parts)
    tc.verifyEqual(sort(string(fieldnames(dev.parts(k))).'), declared, ...
        sprintf('第 %d 条零件在 deviceSpec 输出里的字段集与声明不符', k));
end
end

%% ==================== 3. 材料引用 ====================

function test_no_part_is_missing_a_material_ref(tc)
dev = loadManifest();
ids = asList(dev.material_ids);
tc.verifyEqual(numel(ids), 5);
bad = strings(0, 1);
for k = 1:numel(dev.parts)
    mid = strtrim(string(dev.parts(k).material_id));
    if mid == ""
        bad(end+1) = sprintf('%s 的 material_id 为空', string(dev.parts(k).part_id)); %#ok<AGROW>
    elseif ~any(mid == ids)
        bad(end+1) = sprintf('%s -> %s 不在材料表里', string(dev.parts(k).part_id), mid); %#ok<AGROW>
    end
end
tc.verifyEqual(bad, strings(0, 1), sprintf('material_id 解析失败:\n  %s\n材料表 id: %s', ...
    strjoin(bad, '\n  '), strjoin(ids, ', ')));
end

function test_material_reverse_index_is_computed_not_copied(tc)
% 反向索引 (材料 -> 被多少零件引用) 只在读取时聚合; 两份文件里都没有这个数, 所以它
% 是"清单真被遍历过"的直接证据。
dev = loadManifest();
cnt = dev.material_ref_counts(:);
ids = asList(dev.material_ids);
tc.verifyEqual(numel(cnt), numel(ids));
tc.verifyEqual(sum(cnt), numel(dev.parts), ...
    '引用计数之和 != 零件数: 有零件的 material_id 没落到任何材料上');
tc.verifyFalse(any(cnt == 0), ...
    sprintf('这些材料没有被任何零件引用: %s', strjoin(ids(cnt == 0), ', ')));
want = struct('gas_te_methane_based', 1, 'a150', 2, 'tissue_equivalent', 2, ...
    'void', 2, 'unspecified_in_config', 1);
for k = 1:numel(ids)
    tc.verifyEqual(cnt(k), want.(char(ids(k))), ...
        sprintf('%s 的引用数变了 (现 %d): 零件与材料的对应关系被改过', ids(k), cnt(k)));
end
end

function test_material_composition_and_density_discipline(tc)
% 组分摩尔分数求和必须为 1 (0.64+0.32+0.04); 同一材料只允许一种密度写法。
dev = loadManifest();
nDens = 0;
for k = 1:numel(dev.materials)
    m = dev.materials(k);
    a = m.density_kg_m3;
    b = m.density_g_cm3;
    tc.verifyFalse(~isempty(a) && ~isempty(b), ...
        sprintf('%s: 两种密度写法同时有值, 某次换算必然分叉', string(m.material_id)));
    if ~isempty(a) || ~isempty(b)
        nDens = nDens + 1;
    end
    c = m.composition_molfrac;
    if ~isempty(c)
        tot = 0;
        fn = string(fieldnames(c)).';
        for i = 1:numel(fn)
            tot = tot + double(c.(fn{i}));
        end
        tc.verifyEqual(tot, 1, 'RelTol', 1e-12, ...
            sprintf('%s: 组分和 = %g', string(m.material_id), tot));
    end
end
tc.verifyEqual(nDens, 2, '有密度登记的材料应是 2 条 (组织等效 + A-150), 其余是导出量或未知');
end

%% ==================== 4. 空值口径 ====================

function test_allowed_null_set_equals_observed_null_set(tc)
% 主锁: 多一个 null (把值擦成未知) 与少一个 null (把未知填成一个看起来合理的数)
% 都会让两个集合不再相等。
dev = loadManifest();
allowed = sort(string(dev.allowed_null_paths));
observed = sort(string(dev.null_paths));
tc.verifyEqual(numel(allowed), 23, ...
    sprintf('声明可空 %d 条, 清单实际是 23 条 null; 数量变了要显式改这里', numel(allowed)));
missing = allowed(~ismember(allowed, observed));
surplus = observed(~ismember(observed, allowed));
d1 = setDiff(allowed, observed);
why = sprintf(['可空集与实测空值集不再相等 (缺: %s | 多: %s)。删掉一个 null 等于把' ...
    '"未登记"改成具体值, 加上一个 null 等于把承重字段清空; 两者都要在 deviceSpec 的' ...
    'allowedNullPaths 里同步登记。'], strjoin(missing, ','), strjoin(surplus, ','));
tc.verifyEmpty(d1, why);
% 第三条路径: 直接数盘上文本里的 null, 不依赖解码器对空值的表示法
txt = readUtf8(fullfile(repoRoot(), 'geometry', 'device_v2.json'));
n = numel(regexp(txt, '"[A-Za-z_0-9]+"\s*:\s*null'));
tc.verifyEqual(n, numel(observed), ...
    sprintf('盘上文本有 %d 处 null, 解码得到 %d 条空值路径: 两者应一一对应', n, numel(observed)));
end

function test_allowed_null_paths_are_the_three_declared_names(tc)
dev = loadManifest();
nullable = sort(string(dev.nullable_fields));
tc.verifyEqual(nullable, ["parent_id", "temperature_K", "tolerance_m"], ...
    '可空字段名集合变了: 头注与 allowedNullPaths 要同步');
p = string(dev.allowed_null_paths);
tail = regexprep(p, '^[^.]*\.', '');               % 去掉 part_id 前缀, 留字段路径
heads = regexprep(p, '\..*$', '');              % 只留 part_id
d2 = setDiff(heads, ["anode", "cathode", "equivalent_site_realized", ...
    "equivalent_site_requested", "gas_cavity", "source_cone", "wall", "world_envelope"]);
tc.verifyEmpty(d2, '可空路径覆盖的零件集合变了');
% 源锥的 half_angle_deg 与 transform.direction 已进配置, 不再是可空字段 (2026-09-23);
% 保留 primitive.radius_m 一条: 那是位点标记的半径。
d9 = setDiff(tail, ["parent_id", "tolerance_m", "temperature_K", ...
    "primitive.radius_m"]);
msg9 = sprintf('可空集里出现了新的字段路径: %s', strjoin(d9, ', '));
tc.verifyEmpty(d9, msg9);
end

function test_null_in_load_bearing_field_is_rejected(tc)
% 负对照: 把承重字段改成 null (只改内存副本) 必须在读取阶段报错。
dev = loadManifest();
mut = dev;
mut.parts(2).export_units = [];                      % wall 的导出单位
tc.verifyError(@() tepc.geometry.deviceSpec(mut), 'tepc:geometry:UnexpectedNull', ...
    'export_units 置空却没报错: 承重字段的 null 检查形同不存在');
mut2 = dev;
mut2.parts(1).role = [];
tc.verifyError(@() tepc.geometry.deviceSpec(mut2), 'tepc:geometry:UnexpectedNull', ...
    'role 置空却没报错');
end

function test_missing_field_is_rejected_and_differs_from_null(tc)
% 缺键与值为 null 是两种故障: 前者是清单漏项, 后者是显式未知。结构数组的字段集是齐的
% (少写的键会被补成空值), 所以这里把零件表交成 cell 形态来复现"JSON 里根本没写这个键"。
dev = loadManifest();
c = num2cell(dev.parts);
c{4} = rmfield(c{4}, 'surface_contact');             % anode 少写一个键
s = dev;
s.parts = c;
tc.verifyError(@() tepc.geometry.deviceSpec(s), 'tepc:geometry:MissingField', ...
    '整个键被删掉却没报缺字段: 缺键与 null 分不开');
end

function test_removing_a_null_breaks_the_equality_lock(tc)
% 负对照 (反方向): 填掉一个声明可空的 null 不触发校验错误 (那是合法收紧), 但集合相等
% 锁必须失效 —— 否则这条锁只是同义反复。
dev = loadManifest();
mut = dev;
mut.parts(3).tolerance_m = 2e-5;                     % cathode 的公差从"未知"变成有值
d2 = tepc.geometry.deviceSpec(mut);
tc.verifyNotEqual(numel(d2.null_paths), numel(d2.allowed_null_paths), ...
    '填掉一个 null 后两集合仍相等: null 集合的锁是假的');
tc.verifyTrue(ismember("cathode.tolerance_m", string(d2.allowed_null_paths)));
tc.verifyFalse(ismember("cathode.tolerance_m", string(d2.null_paths)), ...
    '实测空值集里还留着已被填掉的 cathode.tolerance_m');
end

function test_materials_null_set_is_declared_too(tc)
dev = loadManifest();
allowed = sort(string(dev.material_allowed_null_paths));
observed = sort(string(dev.material_null_paths));
tc.verifyEqual(numel(allowed), 18, ...
    sprintf('材料表声明可空 %d 条, 实际是 18 条', numel(allowed)));
d3 = setDiff(allowed, observed);
tc.verifyEmpty(d3, '材料表的可空集与实测空值集不再相等');
end

%% ==================== 5. transport_stage 映射 ====================

function test_transport_stage_is_not_one_value(tc)
% 回归锁: 四个取值退化成一个 = 映射被写死或参数传错。
dev = loadManifest();
st = asList(string({dev.parts.transport_stage}'));
tc.verifyGreaterThanOrEqual(numel(unique(st)), 2, ...
    sprintf('transport_stage 全表同值 (%s): 该列没有逐零件信息', strjoin(unique(st), ',')));
tc.verifyEqual(numel(unique(st)), 4, ...
    sprintf('transport_stage 取值数 = %d, 登记的映射是 4 类', numel(unique(st))));
d4 = setDiff(st, dev.transport_stage_enum);
msg4 = sprintf('transport_stage 枚举与该列实得取值不是一一对应: %s', strjoin(d4, ', '));
tc.verifyEmpty(d4, msg4);
end

function test_transport_stage_matches_the_part_id_mapping(tc)
% 既有实现里按 part_id 分支的映射给出这四个取值; 清单这一列是它的逐条抄本。这里独立
% 重写同一映射 (不读那份表), 两边对不上即红。
dev = loadManifest();
want = struct('gas_cavity', "mc_chord_and_csda", 'wall', "energy_loss_table", ...
    'anode', "field_model_only");
bad = strings(0, 1);
for k = 1:numel(dev.parts)
    id = strtrim(string(dev.parts(k).part_id));
    got = strtrim(string(dev.parts(k).transport_stage));
    if isfield(want, char(id))
        exp = want.(char(id));
    else
        exp = "not_used";                 % 映射按 part_id 分支, 其余一律 not_used
    end
    if got ~= exp
        bad(end+1) = sprintf('%s: 清单 %s, 映射 %s', id, got, exp); %#ok<AGROW>
    end
end
tc.verifyEqual(bad, strings(0, 1), ...
    sprintf('transport_stage 与按 part_id 的映射不符:\n  %s', strjoin(bad, '\n  ')));
end

function test_transport_flags_agree_with_stage(tc)
dev = loadManifest();
for k = 1:numel(dev.parts)
    p = dev.parts(k);
    st = strtrim(string(p.transport_stage));
    tc.verifyFalse(logical(p.transport_enabled) && st == "not_used", ...
        sprintf('%s: transport_enabled=true 却写 not_used', string(p.part_id)));
    tc.verifyTrue(islogical(p.transport_enabled) && isscalar(p.transport_enabled), ...
        sprintf('%s: transport_enabled 不是标量 logical', string(p.part_id)));
end
end

%% ==================== 6. 与配置对账 ====================

function test_geometry_numbers_agree_with_demo_config(tc)
% 两侧描述同一物理量时必须是同一个数: 配置用 mm/um 书写, 清单用米。判据取自盘上两份
% 文件, 相对容差 1e-9 只容纳换算的最后一两个比特; 把系数改成 1000 倍一定越界。
dev = loadManifest();
cfg = rawCfg();
b = geomOf(dev, 'gas_cavity').radius_m;
tc.verifyEqual(b, double(cfg.geometry.gasRadius_mm) * 1e-3, 'RelTol', 1e-9, ...
    'gas_cavity.radius_m 与 geometry.gasRadius_mm 不符');
t = geomOf(dev, 'wall').thickness_m;
tc.verifyEqual(t, double(cfg.geometry.wallThickness_mm) * 1e-3, 'RelTol', 1e-9, ...
    'wall.thickness_m 与 geometry.wallThickness_mm 不符');
a = geomOf(dev, 'anode').radius_m;
tc.verifyEqual(a, double(cfg.geometry.anodeRadius_um) * 1e-6, 'RelTol', 1e-9, ...
    'anode.radius_m 与 geometry.anodeRadius_um 不符');
o = geomOf(dev, 'wall').outer_radius_m;
tc.verifyEqual(o, (double(cfg.geometry.gasRadius_mm) + double(cfg.geometry.wallThickness_mm)) * 1e-3, ...
    'RelTol', 1e-9, 'wall.outer_radius_m != 气腔半径 + 壁厚 (读取侧现算, 不做位相等比较)');
end

function cfg = rawCfg()
cfg = jsondecode(readUtf8(fullfile(repoRoot(), 'config', 'defaults', 'demo_only.json')));
end

function test_gas_and_site_state_agree_with_demo_config(tc)
% 压强/温度成对登记在材料表里 (零件表没有压强槽位); 请求位点半径是目标直径的一半。
dev = loadManifest();
cfg = rawCfg();
g = geomOf(dev, 'gas_cavity');
tc.verifyEqual(g.temperature_K, double(cfg.gas.temperature_K), 'RelTol', 1e-12, ...
    'gas_cavity.temperature_K 与 gas.temperature_K 不符');
tc.verifyEqual(g.pressure_Pa, double(cfg.gas.pressure_Pa), 'RelTol', 1e-12, ...
    '材料表压强与 gas.pressure_Pa 不符');
tc.verifyTrue(isnan(g.density_kg_m3), ...
    '气体密度被钉进静态表: 它是温压/组分的导出量, 钉进来就是第二份真相');
r = geomOf(dev, 'equivalent_site_requested');
tc.verifyEqual(r.radius_m, double(cfg.site.targetDiameter_um) * 1e-6 / 2, 'RelTol', 1e-9, ...
    '请求位点半径与 site.targetDiameter_um 不符');
k = find(asList(dev.material_ids) == "tissue_equivalent", 1);
tc.verifyEqual(double(dev.materials(k).density_kg_m3), double(cfg.site.tissueDensity_kg_m3), ...
    'RelTol', 1e-12, '组织等效密度与 site.tissueDensity_kg_m3 不符');
end

function test_reader_cross_check_with_cfg_passes(tc)
% deviceSpec 自带的交叉校验 (清单侧 vs 配置侧) 必须真的比对了若干项, 而不是空转。
cfg = rawCfg();
dev = tepc.geometry.deviceSpec(fullfile(repoRoot(), 'geometry', 'device_v2.json'), cfg);
rows = dev.config_checks;
st = asList(string({rows.status}'));
tc.verifyGreaterThanOrEqual(nnz(st == "ok"), 3, ...
    sprintf('实际比对 %d 项, 太少: 交叉校验可能退化成空操作', nnz(st == "ok")));
tc_verify_subset(st, ["not_declared", "skipped", "ok"]);
end

function tc_verify_subset(st, allowed)
% 状态词汇外泄 = 交叉校验自己写串了, 单独判一条 (表达式不套进断言消息里)。
    bad = unique(st(~ismember(st, allowed)));
    assert(isempty(bad), sprintf('交叉校验出现意外状态: %s', strjoin(bad, ', ')));
end

%% ==================== 7. 单位量级负对照 ====================

function test_unit_scale_factor_1000_is_rejected(tc)
% 把清单里某个长度乘 1000 (即把 mm 当 m 写) 必须被拒 —— 只改内存副本, 不改 JSON。
dev = loadManifest();
mut = dev;
mut.parts(1).primitive.radius_m = 0.0254 * 1000;     % 25.4 "米"
tc.verifyError(@() tepc.geometry.deviceSpec(mut), 'tepc:geometry:UnitScaleSuspect', ...
    '气腔半径写成 25.4 米没被判为单位错: 量级窗口失效');
mut2 = dev;
mut2.parts(2).primitive.thickness_m = 0.003 * 1000;  % 3 "米"
tc.verifyError(@() tepc.geometry.deviceSpec(mut2), 'tepc:geometry:UnitScaleSuspect', ...
    '壁厚写成 3.0 米没被判为单位错');
mut3 = dev;
mut3.parts(1).temperature_K = 293.15 * 1000;
tc.verifyError(@() tepc.geometry.deviceSpec(mut3), 'tepc:geometry:UnitScaleSuspect', ...
    '温度量级窗口失效');
end

function test_unit_scale_factor_on_the_small_side_is_rejected(tc)
% 反方向: 长度除 1000 后落到 2.54e-5 m, 与丝半径同量级, 单靠窗口挡不住, 但交叉校验
% 会拿配置换算值比对 —— 这条锁证明"两道防线"不是只有一道。
dev = loadManifest();
cfg = rawCfg();
mut = dev;
mut.parts(1).primitive.radius_m = 0.0254 / 1000;
tc.verifyError(@() tepc.geometry.deviceSpec(mut, cfg), ...
    'tepc:geometry:DeviceConfigMismatch', '清单侧 1000 倍偏小没被交叉校验拦住');
end

function test_density_unit_scale_is_rejected(tc)
% 材料表侧: 把 kg/m3 的数写进 g/cm3 槽位 (1124 对 1.124) 必须被拒。
mat = rawMaterials();
ids = matRawIds(mat);
k = find(ids == "a150", 1);
tc.verifyFalse(isempty(k), '材料表里没有 a150 条目, 本负对照无从构造');
mm = mat.materials;
if iscell(mm)
    mm{k}.density_g_cm3 = 1124;
else
    mm(k).density_g_cm3 = 1124;
end
mat.materials = mm;
tc.verifyError(@() tepc.geometry.deviceSpec([], [], mat), ...
    'tepc:geometry:UnitScaleSuspect', '材料密度量级窗口失效');
end

function test_config_side_scale_error_is_rejected(tc)
% 反方向: 清单不动, 把配置里的 gasRadius_mm 乘 1000, 交叉校验必须拒绝。
cfg = rawCfg();
cfg.geometry.gasRadius_mm = double(cfg.geometry.gasRadius_mm) * 1000;
tc.verifyError(@() tepc.geometry.deviceSpec( ...
    fullfile(repoRoot(), 'geometry', 'device_v2.json'), cfg), ...
    'tepc:geometry:DeviceConfigMismatch', '配置侧 1000 倍单位错没被交叉校验拦住');
end

%% ==================== 8. 父链 ====================

function test_parent_chain_resolves_and_is_acyclic(tc)
dev = loadManifest();
ids = asList(string({dev.parts.part_id}'));
par = strings(numel(dev.parts), 1);
for k = 1:numel(dev.parts)
    par(k) = txt1(dev.parts(k).parent_id);
end
tc.verifyEqual(nnz(par == ""), 7, '无父件的零件应有 7 个');
tc.verifyEqual(par(par ~= ""), "wall", '唯一有父件的零件应指向 wall');
for k = 1:numel(dev.parts)
    if par(k) ~= ""
        tc.verifyTrue(any(par(k) == ids), ...
            sprintf('父件 %s 不存在', par(k)));
        tc.verifyNotEqual(par(k), ids(k), '自引用父件没被拦住');
    end
end
mut = dev;
mut.parts(2).parent_id = "cathode";                  % wall -> cathode -> wall
tc.verifyError(@() tepc.geometry.deviceSpec(mut), 'tepc:geometry:ParentCycle', ...
    '把父链闭合成环却没报错');
end

function test_unknown_material_id_is_rejected(tc)
dev = loadManifest();
mut = dev;
mut.parts(4).material_id = "graphite";               % 材料表里没有的名字
tc.verifyError(@() tepc.geometry.deviceSpec(mut), 'tepc:geometry:UnknownMaterial', ...
    '悬空 material_id 没被拦住');
mut2 = dev;
mut2.parts(4).role = "insulator";                    % 枚举里没有的角色
tc.verifyError(@() tepc.geometry.deviceSpec(mut2), 'tepc:geometry:BadRole', ...
    '越界 role 没被拦住');
end

%% ==================== 9. 枚举取自实际内容 ====================

function test_enums_have_no_unused_members(tc)
% 枚举里放一个清单没用过的值 = 给"以后可能用到"预支合法性, 该列写错时不会报警。
dev = loadManifest();
d5 = setDiff(string({dev.parts.role}'), dev.role_enum);
msg5 = sprintf('role 枚举与实际取值不符: %s', strjoin(d5, ', '));
tc.verifyEmpty(d5, msg5);
d6 = setDiff(string({dev.parts.surface_contact}'), dev.surface_contact_enum);
msg6 = sprintf('surface_contact 枚举与实际取值不符: %s', strjoin(d6, ', '));
tc.verifyEmpty(d6, msg6);
d7 = setDiff(string({dev.geometry.type}'), dev.primitive_type_enum);
msg7 = sprintf('primitive.type 枚举与实际取值不符: %s', strjoin(d7, ', '));
tc.verifyEmpty(d7, msg7);
seen = unique(asList(string({dev.parts.value_status}')));
tc.verifyTrue(all(ismember(seen, asList(dev.value_status_enum))), ...
    '零件的 value_status 落在材料表词表之外');
end

function test_value_status_vocabulary_is_read_from_materials(tc)
% 证据等级词表只有材料表自带的那一份: 代码里不另立一套等级名。
dev = loadManifest();
vocab = sort(asList(dev.value_status_enum));
tc.verifyTrue(any(vocab == "MEASURED_CONFIG"), ...
    sprintf('词表缺 MEASURED_CONFIG (实得 %s): 值来自配置不等于实测', strjoin(vocab, ',')));
mat = rawMaterials();
d8 = setDiff(vocab, mat.value_status_vocabulary);
msg8 = sprintf('读取器用的词表与材料表声明的词表不是同一份: %s', strjoin(d8, ', '));
tc.verifyEmpty(d8, msg8);
end

%% ==================== 10. 派生量与不可驱动的部分 ====================

function test_realized_site_radius_stays_unusable_until_derived(tc)
% 实现位点直径由质量厚度映射在运行时导出, 清单里刻意是 null: 读取方必须能区分
% "没有这个数" 与 "这个数是 0"。
dev = loadManifest();
g = geomOf(dev, 'equivalent_site_realized');
tc.verifyTrue(isnan(g.radius_m), '实现位点半径被填上了具体值: 静态表变成第二份真相');
tc.verifyTrue(isnan(g.tolerance_m), '公差被填上了具体值: 仓库内没有图纸与公差记录');
tc.verifyEqual(nnz(~arrayfun(@(k) isnan(dev.geometry(k).tolerance_m), 1:numel(dev.geometry))), 0, ...
    '全表 tolerance_m 都应为 NaN (无机加工公差记录)');
end

function test_source_cone_half_angle_is_traceable_to_config(tc)
% 半角与方向现在真的来自配置 (source.coneHalfAngle_deg / source.direction), 唯一消费点是
% meshSpec 的源锥构造; 清单抄同一对值, 三方不一致由 meshSpec 的身份对账与下面的等值断言抓。
dev = loadManifest();
g = geomOf(dev, 'source_cone');
w = geomOf(dev, 'world_envelope');
cfg = tepc.config.load(fullfile(repoRoot(), 'config', 'defaults', 'demo_only.json'));
tc.verifyEqual(double(g.half_angle_deg), double(cfg.source.coneHalfAngle_deg), 'RelTol', 1e-12, ...
    '清单的源锥半角与配置不同: 两份真相');
% 几何行只展平 primitive, transform 保持嵌套 => 方向要从原清单条目读。
k2 = find(string(dev.part_ids) == string('source_cone'), 1);
dMan = double(dev.parts(k2).transform.direction(:)).';
dCfg = double(cfg.source.direction(:)).';
tc.verifyEqual(dMan / norm(dMan), dCfg / norm(dCfg), 'RelTol', 1e-12, ...
    '清单的源方向与配置不同: 两份真相');
tc.verifyEqual(g.length_m, w.half_m, 'RelTol', 1e-12, ...
    '锥长与世界体半宽同值 (两者都登记为 0.127 m)');
end

function test_world_envelope_is_five_times_the_cavity_radius(tc)
% 球腔的包络半径就是气腔半径; 半宽取 5 x 包络半径。5 倍这个门禁由 meshSpec 执行,
% 清单侧只登记数值 —— 这里核对数值真被读到 (改内存副本后读回同值)。
dev = loadManifest();
g = geomOf(dev, 'world_envelope');
b = geomOf(dev, 'gas_cavity').radius_m;
tc.verifyEqual(g.half_m, 5 * b, 'RelTol', 1e-12, ...
    sprintf('世界体半宽 %.6g != 5 x 气腔半径 %.6g', g.half_m, b));
mut = dev;
mut.parts(5).primitive.half_m = 0.05;
d2 = tepc.geometry.deviceSpec(mut);
tc.verifyEqual(d2.geometry(5).half_m, 0.05, 'RelTol', 1e-12, ...
    '清单侧没把改过的半宽读出来: 说明读取的是缓存而不是清单');
end

function test_manifest_is_consumed_when_geometry_is_built(tc)
% 清单被读 != 清单有用: 建零件表那条路 (meshSpec) 必须报出它取用了哪一份清单, 取用的哈希
% 与这里读到的同一份, 且零件表里的半径/半宽就是清单里那几个数。缺这条, 本文件其余断言都
% 只在"读 + 校验"这一层自转, 清单对构建仍然是装饰。
cfg = rawCfg();
dev = loadManifest();
spec = tepc.geometry.meshSpec(cfg, tepc.config.resolve(cfg));
tc.verifyEqual(char(string(spec.manifest.state)), 'applied', ...
    'meshSpec 没有取用清单 (state 非 applied): 两份描述仍各活各的');
tc.verifyEqual(char(string(spec.manifest.sha256)), char(dev.sha256), ...
    '零件表记录的清单哈希与本文件读到的不是同一份');
tc.verifyEqual(spec.gasRadius_m, double(geomOf(dev, 'gas_cavity').radius_m), 'AbsTol', 0, ...
    '零件表的气腔半径不是清单那个数');
k = find(strcmpi({spec.parts.part_id}, 'world_envelope'), 1);
tc.verifyEqual(spec.parts(k).shape.half_m, double(geomOf(dev, 'world_envelope').half_m), ...
    'AbsTol', 0, '世界体半宽不是清单那个数');
end

function ids = matRawIds(mat)
% 材料条目可能是 cell (字段集不一致时 jsondecode 退化成元胞) 也可能是结构数组: 都取。
    m = mat.materials;
    ids = strings(numel(m), 1);
    for k = 1:numel(m)
        if iscell(m)
            ids(k) = string(m{k}.material_id);
        else
            ids(k) = string(m(k).material_id);
        end
    end
end
