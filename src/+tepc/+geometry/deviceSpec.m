function dev = deviceSpec(path, cfg, materialsIn)
%DEVICESPEC 读取并校验三维装置清单与材料表, 返回含已解析零件数组的结构体。
%
%   dev = deviceSpec()                 默认读 <projectRoot>/geometry/device_v2.json
%   dev = deviceSpec(manifestPath)     只校验清单自身的内部一致性
%   dev = deviceSpec(manifestPath, cfg)
%       再追加清单与 cfg 的交叉校验: 气腔半径 / 壁厚 / 阳极半径 / 温度 / 压强必须在
%       两侧同时成立, 任一处对不上即报 tepc:geometry:DeviceConfigMismatch 并点名是
%       哪个零件的哪个字段、两侧各是多少、差多少。
%   dev = deviceSpec(manifestPath, cfg, materialsPath)   显式指定材料表
%
% 第 1 与第 3 参数接受路径也接受结构体: 传结构体时按"内存里的清单"校验, 不读盘也不填
% file_sha256 (盘上字节哈希只对盘上文件负责)。把某个长度改成 1000 倍再验一次的负对照
% 因此不需要动仓库里那两份 JSON。
%
% 为什么清单必须与 cfg 互相约束: 如果清单只是 cfg 的另一份抄本, 它就不是真相源而是
% 镜像 —— 改一处漏一处时两边会各自"看起来合法"。交叉校验把"两边不能各说各话"变成
% 读取阶段的硬门禁。
%
% 读取口径 (两个静默失效点):
%   * 按字节 fread + native2unicode(...,'UTF-8')。fileread 按系统字符集解码, 中文说明
%     会变乱码, 之后所有字符串比较都在比垃圾; 本机 MATLAB 的字符集是 GBK。
%   * 拒绝 UTF-8 BOM: EF BB BF 会并进第一个字段名, schema 检查会在意想不到的地方失败。
%   * jsondecode 把 JSON null 还原成空 double, 把"元素字段集不一致"的数组还原成 cell。
%     缺键与值为 null 归一后同为空 double, 只能靠 normalizeParts 带出的 present 名单分开。
%
% 单位纪律 (清单内部长度一律以米书写):
%   * 数值字段的单位由名字后缀声明: _m 米 / _mm 毫米 / _um 微米 / _K 开尔文 /
%     _Pa 帕 / _deg 度 / _V 伏 / _kg_m3 千克每立方米 / _g_cm3 克每立方厘米。
%   * 每个后缀配一个量级窗口 (局部函数 magnitudeWindow), 越界报
%     tepc:geometry:UnitScaleSuspect。窗口按本装置的真实尺度取: 腔体半径量级 1e-2 m、
%     丝半径量级 1e-5 m、位点半径量级 1e-6 m、固体密度量级 1 g/cm3, 于是
%     radius_m=25.4 (mm 当 m 写) 与 density_g_cm3=1000 (kg/m3 当 g/cm3 写) 都撞墙。
%   * 单位写错不改 JSON 的合法性, 只改数量级, schema 检查看不见它, 必须靠数值判。
%
% 空值口径 (声明的可空路径见 allowedNullPaths, 逐条取自清单实际内容):
%   * parent_id      顶层零件没有父件 (只有 cathode 的父件是 wall)。
%   * tolerance_m    全表: 仓库内无机加工公差记录, 填 0 会读成"零公差"而不是"未知"。
%   * temperature_K  只有 gas_cavity 登记了气体温度, 壁与电极的工作温度未登记。
%   * primitive.*    equivalent_site_realized 的 radius_m (运行时派生量) 与
%                    (source_cone 的 half_angle_deg 与 transform.direction 已进配置, 不再可空)。
%   * transform.direction  同样已进配置 (source.direction), 不再可空。
%   * 其余字段承重: 值为 null 报 tepc:geometry:UnexpectedNull, 整个键没写报
%     tepc:geometry:MissingField —— 两者是不同故障, 前者是"知道它未知", 后者是漏项。
%   * dev.null_paths 是本次读到的空值路径, dev.allowed_null_paths 是声明的可空路径;
%     读取阶段只判"读到 ⊆ 声明", 两个集合相等由 tests/unit/test_device_v2_manifest.m 锁。
%
% 校验范围: schema / schema_version / units_internal / unit_scale_from_m /
% overlap_policy; parts 非空且 part_id 唯一 / 每条零件带齐 dev.declared_fields 的 19 个
% 字段 / role、transport_stage、value_status、surface_contact、export_units、
% primitive.type 六个枚举逐条核对 (成员取自清单实际内容与材料表自带的
% value_status_vocabulary) / 三个开关是标量 logical / transport_enabled 与
% transport_stage 不互相矛盾 / parent_id 指向已存在的 part_id、不自引用、不成环 /
% material_id 在材料表里存在且材料表每条至少被一个零件引用 / 数值量级窗口 /
% 未替换的 <...> 占位符一律拒绝。
%
% 返回: 清单原始字段全部保留, 另附
%   dev.path / dev.materials_path       两份清单的绝对路径 (结构体入参时为空串)
%   dev.n_parts                         零件数
%   dev.parts                           已校验的零件结构数组 (字段与清单同名)
%   dev.geometry                        逐零件归一化数值几何 (NaN = 该处为 null)
%   dev.materials / dev.material_ids    材料表与它的 id 列表
%   dev.material_ref_counts             每个材料被多少零件引用 (读取时聚合的反向索引)
%   dev.unreferenced_materials          没有被任何零件引用的材料 (本清单为空)
%   dev.sha256                          parts + 顶层字段 的规范化内容哈希
%   dev.file_sha256                     清单字节的哈希 (与 sha256 的区别: 一对内容,
%                                       一对书写)
%   dev.materials_sha256                材料表的规范化内容哈希
%   dev.pair_sha256                     上两者的合成哈希: "几何+材料"绑成一个版本
%   dev.canonical_text                  参与 sha256 的规范化文本 (可手工复算)
%   dev.declared_fields                 每条零件必须带齐的字段名
%   dev.nullable_fields                 允许为 null 的字段名 (还要过 allowedNullPaths)
%   dev.allowed_null_paths / dev.null_paths
%   dev.role_enum / dev.transport_stage_enum / dev.value_status_enum /
%   dev.surface_contact_enum / dev.primitive_type_enum / dev.units_enum
%   dev.config_checks                   与 cfg 的逐项比对结果; 只传 1 参时为 0x1 空表
%
% 哈希规范化 (同内容必同哈希): 固定字段顺序 + 数值一律 sprintf('%.17g') (double 可
% 精确往返) + 行间一律 \n (不随系统换行)。未列入固定顺序的字段按名字排序追加, 所以
% 新增字段会改哈希, 而字段书写顺序不改哈希。自指字段 geometry_sha256 被排除。
%
% transport_stage 的两条锁 (该列是按 part_id 逐条映射出来的, 不是自由填写):
%   全表同值 -> 映射被写死或参数传错的特征, 拒绝;
%   gas_cavity / wall / anode 三条与既有按 part_id 分支的映射不符 -> 拒绝。

    if nargin > 3
        error("tepc:geometry:TooManyInputs", ...
            "deviceSpec 最多接受 3 个输入参数 (清单, 已解析的 cfg, 材料表), 实得 %d", nargin);
    end
    rootDir = tepc.io.projectRoot();
    if nargin < 1 || isempty(path)
        path = fullfile(rootDir, 'geometry', 'device_v2.json');
    end
    inMem = isstruct(path);              % 结构体入参 = 内存清单 (数值负对照不读盘)

    if inMem
        dev = path;
        mPath = "";
        if ~isfield(dev, 'parts')
            error("tepc:geometry:NoParts", "传入的结构体里没有 parts 字段");
        end
    else
        mPath = char(string(path));
        dev = parseObject(readUtf8Text(mPath), mPath);
        if ~isfield(dev, 'parts')
            msg = "清单缺 parts 数组; 顶层字段: " + strjoin(string(fieldnames(dev)), " | ");
            error("tepc:geometry:NoParts", "%s; 文件 %s", msg, mPath);
        end
    end
    [dev.parts, present] = normalizeParts(dev.parts);

    placeholderScan(dev, "device", "清单");
    checkTopLevel(dev);

    % 材料表: 气体的温压与组分登记在它里面 (零件表里没有压强槽位), 零件的 material_id
    % 也必须能落到它的某一条上, 所以它在零件循环之前就位的。清单里
    % materials_sha256/geometry_sha256 是哨兵字符串 computed_at_load, 真值由这里与下面
    % 算出, 手填 64 位 hex 会被 selfHashGuard 拒绝。
    if nargin >= 3 && ~isempty(materialsIn)
        matPath = "";
        mat = materialsIn;
        if ~isstruct(mat)
            matPath = char(string(materialsIn));
            mat = parseObject(readUtf8Text(matPath), matPath);
        end
    else
        ref = "";
        if isfield(dev, "materials_ref")
            ref = textOrNil(dev.materials_ref);
        end
        if ref == ""
            error("tepc:geometry:MaterialsMissing", ...
                "清单顶层没有 materials_ref: 材料表路径只能由清单自己声明");
        end
        matPath = resolveRefPath(ref, mPath);
        if matPath == ""
            m1 = "清单声明了 materials_ref = " + ref + " 但读不到该文件";
            m2 = "材料表登记温压/组分/密度, 缺它则零件的 material_id 无从核对";
            error("tepc:geometry:MaterialsMissing", "%s; %s; 清单 %s", m1, m2, mPath);
        end
        mat = parseObject(readUtf8Text(matPath), matPath);
    end
    if ~isfield(mat, 'materials')
        error("tepc:geometry:MaterialsShape", "材料表没有 materials 数组: %s", matPath);
    end
    [matList, matPresent] = normalizeParts(mat.materials);
    mat.materials = matList;
    placeholderScan(mat, "materials", "材料表");
    checkMaterials(mat, matPresent);
    checkAllParts(dev.parts, present, mat);

    canon = canonicalText(dev);
    dev.sha256 = char(tepc.io.hashText(canon));
    dev.file_sha256 = "";
    if ~inMem
        dev.file_sha256 = char(tepc.io.hashFile(mPath));
    end
    dev.path = mPath;
    dev.materials_path = matPath;
    dev.n_parts = numel(dev.parts);
    dev.canonical_text = canon;
    dev.role_enum = roleEnum();
    dev.transport_stage_enum = stageEnum();
    dev.value_status_enum = valueStatusEnum(mat);
    dev.surface_contact_enum = contactEnum();
    dev.primitive_type_enum = primitiveTypeEnum();
    dev.units_enum = unitsEnum();
    dev.declared_fields = partFieldEnum();
    dev.nullable_fields = nullableFieldEnum();
    dev.allowed_null_paths = allowedNullPaths();
    dev.part_ids = colIds(dev.parts, 'part_id');
    dev.null_paths = allNullPaths(dev.parts, present, dev.part_ids);
    dev.material_allowed_null_paths = matAllowedNullPaths();
    dev.material_null_paths = allNullPaths(mat.materials, matPresent, matIds(mat));
    dev.materials = mat.materials;
    dev.material_ids = matIds(mat);
    dev.material_ref_counts = materialRefCounts(dev.parts, mat);
    dev.unreferenced_materials = dev.material_ids(dev.material_ref_counts == 0);
    dev.geometry = resolvedGeometry(dev.parts, mat);
    dev.materials_sha256 = char(tepc.io.hashText(materialsCanonicalText(mat)));
    dev.pair_sha256 = char(tepc.io.hashText(dev.sha256 + "|" + dev.materials_sha256));
    selfHashGuard(dev);

    if nargin < 2 || isempty(cfg)
        dev.config_checks = emptyCheckRows();
    else
        dev.config_checks = crossCheckManifest(dev, cfg, mat);
    end
end

%% ==================== 局部函数 (仅此文件内) ====================

function txt = readUtf8Text(path)
% 字节级读取 (与 tepc.io.hashFile 同一套读法, 故 file_sha256 与内容解码看到同一批字节),
% 再显式按 UTF-8 解码。
    fid = fopen(path, 'r');
    if fid < 0
        error("tepc:geometry:ManifestNotFound", "清单无法按字节打开 (不存在或无权限): %s", path);
    end
    cleanup = onCleanup(@() fclose(fid));
    raw = fread(fid, Inf, 'uint8=>uint8');
    clear cleanup
    if isempty(raw)
        error("tepc:geometry:EmptyManifest", "清单是空文件: %s", path);
    end
    % fread 给列向量: 直接与 1x3 比较会因隐式扩展成 3x3, all() 出来是 1x3, 喂给 && 就报
    % "操作数必须可转换为标量逻辑值"。先转成行向量再比, 判据才是标量。
    raw = uint8(raw(:)).';
    if numel(raw) >= 3 && all(raw(1:3) == uint8([239 187 191]))
        m1 = "清单带 UTF-8 BOM (EF BB BF): BOM 会并进第一个字段名, 使 schema 检查在错的地方失败";
        m2 = "请以无 BOM 的 UTF-8 重新保存";
        error("tepc:geometry:Utf8Bom", "%s; %s; 文件 %s", m1, m2, path);
    end
    txt = native2unicode(uint8(raw(:)).', 'UTF-8');   % 行向量输入 -> 单个 char 行向量
    txt = char(txt);
    if any(txt == char(65533))
        m1 = "清单不是合法 UTF-8 (解码出现替换符 U+FFFD): 中文说明会变成乱码, 字符串比较静默失效";
        error("tepc:geometry:NotUtf8", "%s; 文件 %s", m1, path);
    end
end

function obj = parseObject(txt, path)
    try
        obj = jsondecode(txt);
    catch err
        msg = sprintf("清单不是合法 JSON: %s", err.message);
        error("tepc:geometry:ManifestParse", "%s; 文件 %s", msg, path);
    end
    if ~isstruct(obj) || ~isscalar(obj)
        m1 = "清单顶层必须是单个 JSON 对象";
        error("tepc:geometry:NotObject", "%s (实得 %s, 元素数 %d); 文件 %s", ...
            m1, class(obj), numel(obj), path);
    end
end

function [out, present] = normalizeParts(parts)
% jsondecode 对"元素字段不完全一致的数组"给 cell (每元素一个 struct), 对字段集一致的
% 数组给 struct 数组 (JSON null 还原成空 double)。两种形态都要归一, 否则 isfield 检查
% 会随数组形态而异, 哈希也会随书写顺序漂移。
% present{k} = 该元素在 JSON 里**实际写出的**键名。缺键与值为 null 在归一后都是空
% double, 只有靠这份名单才分得开: "零件没写 role" (缺数据, 报错) 与 "零件写了
% temperature_K: null" (声明为未知, 允许) 是两件不同的事。
    if isstruct(parts)
        out = parts;
        present = cell(1, numel(parts));
        for k = 1:numel(parts)
            present{k} = string(fieldnames(parts(k))).';
        end
        return;
    end
    if ~iscell(parts) || isempty(parts)
        m1 = "parts 必须是非空的 JSON 对象数组";
        error("tepc:geometry:PartsShape", "%s (实得 %s, 元素数 %d)", ...
            m1, class(parts), numel(parts));
    end
    names = strings(0, 1);
    present = cell(1, numel(parts));
    for k = 1:numel(parts)
        p = parts{k};
        if ~isstruct(p) || ~isscalar(p)
            m1 = "数组的第 " + string(k) + " 个元素不是单个对象";
            error("tepc:geometry:PartsShape", "%s (实得 %s)", m1, class(p));
        end
        fn = string(fieldnames(p)).';
        present{k} = fn;
        names = [names, setdiff(fn, names)]; %#ok<AGROW>
    end
    tmpl = struct();
    for i = 1:numel(names)
        tmpl.(char(names(i))) = [];
    end
    out = repmat(tmpl, numel(parts), 1);
    for k = 1:numel(parts)
        fnk = fieldnames(parts{k});
        for i = 1:numel(fnk)
            out(k).(fnk{i}) = parts{k}.(fnk{i});
        end
    end
end

function v = reqField(s, name, who)
% 取字段并剥掉 jsondecode 留下的 1x1 cell; 字段缺失即点名报错。
    if ~isfield(s, char(string(name)))
        error("tepc:geometry:MissingField", "%s: 缺字段 %s", who, string(name));
    end
    v = s.(char(string(name)));
    if iscell(v) && numel(v) == 1
        v = v{1};
    end
end

function t = textOf(v, name, who)
% 文本字段: char/string 标量, 空视为 ""。数值/结构一律拒绝 —— 枚举比较在数值上恒假,
% 放过就是"看起来校验过了其实什么都没比"。
    if iscell(v) && numel(v) == 1
        v = v{1};
    end
    if isempty(v)
        t = "";
    elseif ischar(v)
        t = strtrim(string(v));
    elseif isstring(v) && isscalar(v)
        t = strtrim(string(v));
    else
        error("tepc:geometry:BadFieldType", "%s: 字段 %s 必须是文本 (实得 %s, %d 个元素)", ...
            who, string(name), class(v), numel(v));
    end
end

function t = textOrNil(v)
% 宽松版: 非文本一律给 "", 用于"有则核对、无则跳过"的字段。
    t = "";
    if ischar(v)
        t = strtrim(string(v));
    elseif isstring(v) && isscalar(v)
        t = strtrim(string(v));
    elseif iscell(v) && numel(v) == 1
        t = textOrNil(v{1});
    end
end

function x = numScalarOf(v, name, who)
    if ~(isnumeric(v) || islogical(v)) || ~isscalar(v)
        error("tepc:geometry:BadFieldType", ...
            "%s: 字段 %s 必须是标量数值 (实得 %s, %d 个元素)", ...
            who, string(name), class(v), numel(v));
    end
    x = double(v);
    if ~isfinite(x)
        error("tepc:geometry:BadNumber", "%s: 字段 %s 必须是有限值 (实得 %s)", ...
            who, string(name), mat2str(x));
    end
end

function checkTopLevel(dev)
    TOP = "清单顶层";
    sch = textOf(reqField(dev, "schema", TOP), "schema", TOP);
    if isempty(regexp(sch, '^tepc-device-v2$', 'once'))
        error("tepc:geometry:BadSchema", ...
            "schema 必须整串匹配 ^tepc-device-v2$ (实得 %s)", sch);
    end
    raw = reqField(dev, "schema_version", TOP);
    sv = textOrNil(raw);
    if sv == "" && isnumeric(raw) && isscalar(raw) && isfinite(raw)
        sv = string(mat2str(raw));        % 写成数值 2.0 也算有版本号, 不因此拒绝
    end
    if sv == ""
        error("tepc:geometry:BadSchemaVersion", ...
            "schema_version 不得为空 (例如 2.0): 没有版本号的清单不知道按哪套规则读");
    end
    u = textOf(reqField(dev, "units_internal", TOP), "units_internal", TOP);
    if u ~= "SI"
        m1 = "units_internal 必须是 SI: 清单内部长度一律以米书写";
        m2 = "非米单位只允许出现在带 _mm / _um 后缀的字段里, 否则 1000 倍错读没有报警";
        error("tepc:geometry:BadUnits", "%s; %s; 实得 %s", m1, m2, u);
    end
    sc = numScalarOf(reqField(dev, "unit_scale_from_m", TOP), "unit_scale_from_m", TOP);
    if sc <= 0
        error("tepc:geometry:BadUnitScale", ...
            "unit_scale_from_m 必须是正数 (米到导出单位的乘子, 实得 %.17g)", sc);
    end
    if isfield(dev, "export_units")
        unitsGuard(textOf(dev.export_units, "export_units", TOP), "export_units", TOP);
    end
end

function checkAllParts(parts, present, mat)
    roles = roleEnum();
    stages = stageEnum();
    vsEnum = valueStatusEnum(mat);
    scEnum = contactEnum();
    mids = matIds(mat);
    declared = partFieldEnum();
    allowedNull = allowedNullPaths();
    flagNames = ["transport_enabled", "field_enabled", "display_enabled"];
    geoNames = ["primitive", "mesh", "dimensions_SI", "geometry", "shapes"];
    n = numel(parts);
    if n == 0
        error("tepc:geometry:NoParts", "parts 为空: 清单必须至少列一个零件");
    end

    ids = strings(n, 1);
    for k = 1:n
        who = "parts(" + string(k) + ")";
        pid = textOf(reqField(parts(k), "part_id", who), "part_id", who);
        if pid == ""
            error("tepc:geometry:MissingField", "%s: part_id 不得为空", who);
        end
        ids(k) = pid;
    end
    [u, ~, ic] = unique(ids);
    for i = 1:numel(u)
        rep = find(ic == i);
        if numel(rep) > 1
            m1 = "part_id 重复: " + u(i);
            m2 = "出现在 parts(" + strjoin(string(rep), ", ") + ")";
            error("tepc:geometry:DuplicatePartId", "%s; %s", m1, m2);
        end
    end

    used = strings(n, 1);                 % 每零件实际声明的 transport_stage
    parents = zeros(n, 1);                % parent_id 的下标 (0 = 无父件), 供成环检查
    for k = 1:n
        p = parts(k);
        who = "零件 " + ids(k);
        % (i) 字段带齐: 缺键与写 null 是两种故障, 前者是清单漏项。
        have = strings(0, 1);
        if numel(present) >= k
            have = present{k};
        end
        miss = declared(~ismember(declared, have));
        if ~isempty(miss)
            m1 = who + ": JSON 里没有这些键 " + strjoin(miss, " | ");
            m2 = "缺键不等于 null: 承重字段缺项与显式未知必须分得开";
            error("tepc:geometry:MissingField", "%s; %s", m1, m2);
        end

        % (ii) 空值口径: 读到的 null 必须落在声明的可空集合内。承重字段的 null 在这里
        % 就拒, 早于枚举核对 —— 否则空 role 会被报成"不在枚举内", 掩盖真实故障是缺值。
        np = nullPathsOf(p, ids(k), have);
        badNull = np(~ismember(np, allowedNull));
        if ~isempty(badNull)
            m1 = who + ": 这些路径为 null " + strjoin(badNull, " | ");
            m2 = "它们不在声明的可空集合内 (承重字段空值即缺数据, 见 deviceSpec 头注)";
            error("tepc:geometry:UnexpectedNull", "%s; %s", m1, m2);
        end

        hasGeo = false;
        for i = 1:numel(geoNames)
            nm = char(geoNames(i));
            if isfield(p, nm) && ~isempty(p.(nm))
                hasGeo = true;
                break;
            end
        end
        if ~hasGeo
            m1 = who + ": 没有任何几何字段";
            m2 = "至少要有 " + strjoin(geoNames, " | ") + " 之一";
            error("tepc:geometry:NoPrimitive", "%s; %s", m1, m2);
        end

        role = textOf(reqField(p, "role", who), "role", who);
        if ~any(role == roles)
            m1 = who + ": role = " + role + " 不在枚举内";
            m2 = "允许值: " + strjoin(roles, " | ");
            error("tepc:geometry:BadRole", "%s; %s", m1, m2);
        end

        for i = 1:numel(flagNames)
            v = reqField(p, flagNames(i), who);
            if ~(islogical(v) && isscalar(v))
                m1 = who + ": " + flagNames(i) + " 必须是标量 logical";
                m2 = "实得类型 " + string(class(v)) + " 元素数 " + string(numel(v)) ...
                    + " (null 与 0/1 数值都不算: 它们会被当成 false 静默放过)";
                error("tepc:geometry:BadFlag", "%s; %s", m1, m2);
            end
        end

        stage = textOf(reqField(p, "transport_stage", who), "transport_stage", who);
        if ~any(stage == stages)
            m1 = who + ": transport_stage = " + stage + " 不在枚举内";
            m2 = "允许值: " + strjoin(stages, " | ");
            error("tepc:geometry:BadStage", "%s; %s", m1, m2);
        end
        if p.transport_enabled && stage == "not_used"
            m1 = who + ": transport_enabled=true 与 transport_stage=not_used 自相矛盾";
            m2 = "声称进输运就必须写明怎么进 (mc_chord_and_csda / energy_loss_table / field_model_only)";
            error("tepc:geometry:TransportFlagConflict", "%s; %s", m1, m2);
        end
        % 反方向不报错: 不进输运的实体仍可只进场模型 (阳极 transport_enabled=false 且
        % transport_stage=field_model_only 正是这个形态)。
        used(k) = stage;

        par = textOf(reqField(p, "parent_id", who), "parent_id", who);
        if par ~= ""
            if par == ids(k)
                error("tepc:geometry:SelfParent", "%s: parent_id 指向自身", who);
            end
            at = find(par == ids, 1);
            if isempty(at)
                m1 = who + ": parent_id = " + par + " 在清单里没有对应 part_id";
                m2 = "已有 part_id: " + strjoin(ids, " | ");
                error("tepc:geometry:BadParent", "%s; %s", m1, m2);
            end
            parents(k) = at;
        end

        if isfield(p, "export_units")
            unitsGuard(textOf(p.export_units, "export_units", who), "export_units", who);
        end

        % (iii) 两个内容枚举与材料引用。
        vs = textOf(reqField(p, "value_status", who), "value_status", who);
        if ~any(vs == vsEnum)
            m1 = who + ": value_status = " + vs + " 不在证据词表内";
            m2 = "允许值 (取自材料表 value_status_vocabulary): " + strjoin(vsEnum, " | ");
            error("tepc:geometry:BadValueStatus", "%s; %s", m1, m2);
        end
        sc = textOf(reqField(p, "surface_contact", who), "surface_contact", who);
        if ~any(sc == scEnum)
            m1 = who + ": surface_contact = " + sc + " 不在枚举内";
            m2 = "允许值: " + strjoin(scEnum, " | ");
            error("tepc:geometry:BadSurfaceContact", "%s; %s", m1, m2);
        end
        mid = textOf(reqField(p, "material_id", who), "material_id", who);
        if ~any(mid == mids)
            m1 = who + ": material_id = " + mid + " 在材料表里没有对应条目";
            m2 = "材料表 id: " + strjoin(mids, " | ");
            error("tepc:geometry:UnknownMaterial", "%s; %s", m1, m2);
        end

        % (iv) 几何分量与量级窗口 (单位错只改数量级, 不改 JSON 合法性)。
        checkPrimitive(p.primitive, who);
        checkTransform(p.transform, who);
        checkScalarField(p, "tolerance_m", who, have);
        checkScalarField(p, "temperature_K", who, have);
    end
    assertNoParentCycle(ids, parents);
    checkStageLocks(ids, used);
end

function checkPrimitive(pr, who)
% primitive 是嵌套对象: type 决定该形状必须出现哪些分量, 分量再按后缀过量级窗口。
    if ~isstruct(pr) || ~isscalar(pr)
        error("tepc:geometry:BadPrimitive", "%s: primitive 必须是单个对象 (实得 %s)", ...
            who, class(pr));
    end
    fn = string(fieldnames(pr)).';
    if ~hasfieldIn(fn, "type")
        error("tepc:geometry:MissingField", "%s: primitive 缺 type 键", who);
    end
    typ = textOf(pr.type, "primitive.type", who);
    tEnum = primitiveTypeEnum();
    if ~any(typ == tEnum)
        m1 = who + ": primitive.type = " + typ + " 不在枚举内";
        m2 = "允许值: " + strjoin(tEnum, " | ");
        error("tepc:geometry:BadPrimitiveType", "%s; %s", m1, m2);
    end
    need = primitiveKeys(typ);
    miss = need(~ismember(need, fn));
    if ~isempty(miss)
        m1 = who + ": type=" + typ + " 的 primitive 缺分量 " + strjoin(miss, " | ");
        m2 = "分量的有无由形状决定, 缺一个就无法闭合出体积";
        error("tepc:geometry:IncompletePrimitive", "%s; %s", m1, m2);
    end
    for i = 1:numel(fn)
        if fn(i) == "type"
            continue;
        end
        checkMagnitude(pr.(fn(i)), fn(i), who + ".primitive." + fn(i));
    end
    % 壁厚与内外皮自洽: shell 的 thickness_m 为正且外半径大于它 (内皮半径 = 外半径 - 壁厚)。
    if typ == "shell" && isfinite(pr.outer_radius_m) && pr.outer_radius_m <= pr.thickness_m
        m1 = who + ": outer_radius_m 必须大于 thickness_m (内皮半径将为非正)";
        m2 = sprintf('实得 outer=%.17g thickness=%.17g', pr.outer_radius_m, pr.thickness_m);
        error("tepc:geometry:BadShell", "%s; %s", m1, m2);
    end
end

function checkTransform(tr, who)
% transform: translate_m 必须是 3 个有限实数; rotate_deg/scale 出现时按各自窗口判。
    if ~isstruct(tr) || ~isscalar(tr)
        error("tepc:geometry:BadTransform", "%s: transform 必须是单个对象 (实得 %s)", ...
            who, class(tr));
    end
    fn = string(fieldnames(tr)).';
    if ~any(fn == "translate_m")
        error("tepc:geometry:MissingField", "%s: transform 缺 translate_m 键", who);
    end
    v = tr.translate_m;
    if iscell(v) && numel(v) == 1
        v = v{1};
    end
    if ~(isnumeric(v) && isvector(v) && numel(v) == 3 && all(isfinite(v)))
        m1 = who + ": transform.translate_m 必须是 3 个有限实数";
        m2 = sprintf('实得 %s (%d 个元素)', class(v), numel(v));
        error("tepc:geometry:BadTranslate", "%s; %s", m1, m2);
    end
    for i = 1:numel(fn)
        if fn(i) == "direction" && isempty(tr.(fn(i)))
            continue;                       % 方向为 null 由空值口径那条判, 这里不量级
        end
        checkMagnitude(tr.(fn(i)), fn(i), who + ".transform." + fn(i));
    end
end

function checkScalarField(p, nm, who, have)
% 零件顶层的带单位后缀标量 (tolerance_m / temperature_K): 有值才过量级窗口。
    if ~any(have == nm)
        return;
    end
    v = p.(char(nm));
    if isempty(v)
        return;                             % null 已由空值口径判过
    end
    checkMagnitude(v, nm, who + "." + nm);
end

function checkMagnitude(v, nm, who)
% 按字段名后缀声明的单位判量级。窗口见 magnitudeWindow: 它挡的是 1000/1e6 这类
% 单位错写, 不是精度问题, 所以边界取在"差一个数量级以上"的位置。
    if iscell(v) && numel(v) == 1
        v = v{1};
    end
    if ~(isnumeric(v) && ~islogical(v))
        return;                             % 文本/逻辑不参与量级判定
    end
    w = magnitudeWindow(nm);
    if isempty(w)
        return;                             % 无单位后缀: 没有量级口径可判
    end
    x = double(v(:));
    if any(~isfinite(x))
        error("tepc:geometry:BadNumber", "%s: 必须是有限值 (实得 %s)", who, mat2str(x(:).'));
    end
    lo = w(1);
    hi = w(2);
    if any(x < lo) || any(x > hi)
        m1 = who + " = " + strjoin(string(x), ",") + " 越出 " + char(nm) + " 的量级窗口";
        m2 = sprintf('[%g, %g] (单位 %s): 疑似把非 SI 单位写进了 SI 字段', ...
            lo, hi, unitOf(nm));
        error("tepc:geometry:UnitScaleSuspect", "%s; %s", m1, m2);
    end
end

function w = magnitudeWindow(nm)
% 窗口 [下限, 上限], 空 = 该字段无量级口径。判据是本装置的真实尺度: 气腔半径
% 2.54e-2 m、丝半径 5e-5 m、位点半径 1e-6 m、壁厚 3e-3 m、气体密度 1.6e-1 kg/m3、
% 组织密度 1e3 kg/m3、常温 293.15 K、真空紫外到常压 1e2..1e5 Pa。
    switch char(string(nm))
        case {'radius_m', 'inner_radius_m', 'outer_radius_m', 'thickness_m', ...
              'half_m', 'height_m', 'length_m', 'diameter_m', 'apex_m', 'base_m'}
            w = [1e-9, 1.0];                % 25.4 (mm 当 m) 与 2.54e4 (um 当 m) 都越界
        case 'tolerance_m'
            w = [1e-9, 1e-2];              % 机加工公差量级 1e-5..1e-4 m
        case 'translate_m'
            w = [0, 1.0];                  % 允许 0 (装置中心在原点), 上限同腔体尺度
        case {'radius_mm', 'thickness_mm', 'length_mm', 'height_mm', 'diameter_mm'}
            w = [1e-6, 1e3];
        case {'radius_um', 'thickness_um', 'diameter_um', 'length_um'}
            w = [1e-3, 1e6];
        case 'temperature_K'
            w = [100, 1000];               % 20 这类读数更像摄氏度, 判为单位错
        case 'pressure_Pa'
            w = [1, 1e8];                  % 0.01 (bar 当 Pa) 越下界, 1e9 越上界
        case {'half_angle_deg', 'cone_half_angle_deg'}
            w = [1e-9, 90];      % 半角必须是正角: 0 会让锥底退化成一个点 (与本文件其余"正长度"同口径)
        case 'rotate_deg'
            w = [-360, 360];
        case {'energy_MeV', 'hv_V', 'voltage_V'}
            w = [1e-3, 1e7];
        case 'density_kg_m3'
            w = [1e-3, 3e4];
        case 'density_g_cm3'
            w = [1e-6, 25];                % 1000 (kg/m3 当 g/cm3) 越界
        case 'compressibility_Z'
            w = [0.1, 5];                  % 无量纲, 常温常压气体 Z ~ 1
        otherwise
            w = [];
    end
end

function u = unitOf(nm)
    s = char(string(nm));
    i = find(s == '_', 1, 'last');
    if isempty(i) || startsWith(s, "_")
        u = s;
    else
        u = s(i+1:end);
    end
end

function tf = hasfieldIn(fn, nm)
    tf = any(fn == nm);
end

%% ---------------- 材料表 ----------------

function checkMaterials(mat, present)
% 材料表是零件 material_id 的取值域, 也是气体温压/组分与壁/组织密度的登记处。
% 只走 JSON 里真写出来的键: temperature_K/pressure_Pa/compressibility_Z 三键只在气态
% 条目里出现, 固体条目没写它们不等于"未知", 而是"不适用"。
    need = matFieldEnum();
    ids = matIds(mat);
    n = numel(mat.materials);
    if n == 0
        error("tepc:geometry:MaterialsEmpty", "材料表 materials 为空: 零件的 material_id 无从解析");
    end
    if numel(unique(ids)) ~= n
        error("tepc:geometry:DuplicateMaterialId", "material_id 有重复: %s", strjoin(ids, " | "));
    end
    vsEnum = valueStatusEnum(mat);
    stEnum = materialStateEnum();
    allowedNull = matAllowedNullPaths();
    for k = 1:n
        m = mat.materials(k);
        who = "材料 " + ids(k);
        miss = need(~ismember(need, present{k}));
        if ~isempty(miss)
            error("tepc:geometry:MissingField", "%s: JSON 里没有这些键 %s", who, strjoin(miss, " | "));
        end
        np = nullPathsOf(m, ids(k), present{k});
        badNull = np(~ismember(np, allowedNull));
        if ~isempty(badNull)
            error("tepc:geometry:UnexpectedNull", "%s: 这些路径为 null %s", who, strjoin(badNull, " | "));
        end
        vs = textOf(reqField(m, "value_status", who), "value_status", who);
        if ~any(vs == vsEnum)
            m1 = who + ": value_status = " + vs + " 不在证据词表内";
            m2 = "允许值: " + strjoin(vsEnum, " | ");
            error("tepc:geometry:BadValueStatus", "%s; %s", m1, m2);
        end
        st = textOf(reqField(m, "state", who), "state", who);
        if st ~= "" && ~any(st == stEnum)
            m1 = who + ": state = " + st + " 不在枚举内";
            m2 = "允许值: " + strjoin(stEnum, " | ");
            error("tepc:geometry:BadMaterialState", "%s; %s", m1, m2);
        end
        % 密度只允许一种写法: 两处并存迟早某次换算时分叉。
        hasSI = ~isempty(getFieldOf(m, 'density_kg_m3'));
        hasCGS = ~isempty(getFieldOf(m, 'density_g_cm3'));
        if hasSI && hasCGS
            error("tepc:geometry:DoubleDensity", "%s: 两种密度写法同时有值", who);
        end
        if hasSI
            checkMagnitude(m.density_kg_m3, "density_kg_m3", who + ".density_kg_m3");
        end
        if hasCGS
            checkMagnitude(m.density_g_cm3, "density_g_cm3", who + ".density_g_cm3");
        end
        checkScalarField(m, "temperature_K", who, present{k});
        checkScalarField(m, "pressure_Pa", who, present{k});
        checkScalarField(m, "compressibility_Z", who, present{k});
        checkComposition(m, who, st);
        % 三键的有无由 state 决定: 只有气态条目登记温压与压缩因子。
        if st == "gas"
            for f = ["temperature_K", "pressure_Pa", "compressibility_Z"]
                if ~any(present{k} == f)
                    error("tepc:geometry:MissingGasState", "%s: 气态材料缺 %s 键", who, f);
                end
            end
        end
    end
end

function checkComposition(m, who, st)
% 摩尔分数求和必须是 1 (0.64+0.32+0.04): 归一化会把配方的错抄成"看起来对"的值。
    c = getFieldOf(m, 'composition_molfrac');
    if isempty(c)
        return;
    end
    if ~isstruct(c) || ~isscalar(c)
        error("tepc:geometry:BadComposition", "%s: composition_molfrac 必须是对象", who);
    end
    fn = string(fieldnames(c)).';
    tot = 0;
    for i = 1:numel(fn)
        v = c.(fn{i});
        if ~(isnumeric(v) && isscalar(v) && isfinite(v) && v >= 0 && v <= 1)
            error("tepc:geometry:BadComposition", "%s: 组分 %s 必须是 [0,1] 内的标量", who, fn(i));
        end
        tot = tot + double(v);
    end
    if ~isfinite(tot) || abs(tot - 1) > 1e-9
        error("tepc:geometry:CompositionSum", "%s: 摩尔分数和 = %.17g, 不是 1", who, tot);
    end
    if st == "gas" && numel(fn) == 0
        error("tepc:geometry:BadComposition", "%s: 气态材料没有任何组分", who);
    end
end

function s = matIds(mat)
    s = strings(numel(mat.materials), 1);
    for k = 1:numel(mat.materials)
        s(k) = textOf(reqField(mat.materials(k), "material_id", "材料条目"), "material_id", ...
            "材料条目");
    end
end

function cnt = materialRefCounts(parts, mat)
% 反向索引 (材料 -> 引用它的零件数) 在读取时聚合, 抄进文件就是第二份真相。
    ids = matIds(mat);
    cnt = zeros(numel(ids), 1);
    for k = 1:numel(parts)
        mid = textOrNil(getFieldOf(parts(k), 'material_id'));
        j = find(mid == ids, 1);
        if ~isempty(j)
            cnt(j) = cnt(j) + 1;
        end
    end
end

function g = resolvedGeometry(parts, mat)
% 逐零件的归一化数值几何: 字段缺失或为 null 一律 NaN (调用方据此判"该量不可驱动")。
% 派生量 inner_radius_m = outer_radius_m - thickness_m 在读取侧现算: 双精度下
% 0.0254+0.003 与字面量 0.0284 差 1 ulp, 拿字面量做位相等比较会假红。
    ids = matIds(mat);
    n = numel(parts);
    g = repmat(emptyGeometry(), 1, n);
    for k = 1:n
        p = parts(k);
        g(k).part_id = textOrNil(getFieldOf(p, 'part_id'));
        g(k).parent_id = textOrNil(getFieldOf(p, 'parent_id'));
        g(k).role = textOrNil(getFieldOf(p, 'role'));
        g(k).material_id = textOrNil(getFieldOf(p, 'material_id'));
        g(k).transport_stage = textOrNil(getFieldOf(p, 'transport_stage'));
        g(k).value_status = textOrNil(getFieldOf(p, 'value_status'));
        g(k).surface_contact = textOrNil(getFieldOf(p, 'surface_contact'));
        g(k).export_units = textOrNil(getFieldOf(p, 'export_units'));
        g(k).tolerance_m = nanScalar(getFieldOf(p, 'tolerance_m'));
        g(k).temperature_K = nanScalar(getFieldOf(p, 'temperature_K'));
        pr = getFieldOf(p, 'primitive');
        if isstruct(pr) && isscalar(pr)
            g(k).type = textOrNil(getFieldOf(pr, 'type'));
            g(k).radius_m = nanScalar(getFieldOf(pr, 'radius_m'));
            g(k).outer_radius_m = nanScalar(getFieldOf(pr, 'outer_radius_m'));
            g(k).thickness_m = nanScalar(getFieldOf(pr, 'thickness_m'));
            g(k).half_m = nanScalar(getFieldOf(pr, 'half_m'));
            g(k).height_m = nanScalar(getFieldOf(pr, 'height_m'));
            g(k).length_m = nanScalar(getFieldOf(pr, 'length_m'));
            g(k).half_angle_deg = nanScalar(getFieldOf(pr, 'half_angle_deg'));
            if isfinite(g(k).outer_radius_m) && isfinite(g(k).thickness_m)
                g(k).inner_radius_m = g(k).outer_radius_m - g(k).thickness_m;
            end
        end
        tr = getFieldOf(p, 'transform');
        if isstruct(tr) && isscalar(tr)
            v = getFieldOf(tr, 'translate_m');
            if isnumeric(v) && numel(v) == 3
                g(k).translate_m = double(v(:)).';
            end
        end
        j = find(g(k).material_id == ids, 1);
        if ~isempty(j)
            mm = mat.materials(j);
            g(k).material_state = textOrNil(getFieldOf(mm, 'state'));
            g(k).density_kg_m3 = nanScalar(getFieldOf(mm, 'density_kg_m3'));
            gd = nanScalar(getFieldOf(mm, 'density_g_cm3'));
            if isnan(g(k).density_kg_m3) && isfinite(gd)
                g(k).density_kg_m3 = gd * 1000;      % 1 g/cm3 = 1e3 kg/m3
            end
            g(k).pressure_Pa = nanScalar(getFieldOf(mm, 'pressure_Pa'));
        end
    end
end

function g = emptyGeometry()
    g = struct('part_id', "", 'parent_id', "", 'role', "", 'material_id', "", ...
        'transport_stage', "", 'value_status', "", 'surface_contact', "", ...
        'export_units', "", 'type', "", 'radius_m', NaN, 'inner_radius_m', NaN, ...
        'outer_radius_m', NaN, 'thickness_m', NaN, 'half_m', NaN, 'height_m', NaN, ...
        'length_m', NaN, 'half_angle_deg', NaN, 'translate_m', [NaN NaN NaN], ...
        'tolerance_m', NaN, 'temperature_K', NaN, 'material_state', "", ...
        'density_kg_m3', NaN, 'pressure_Pa', NaN);
end

function x = nanScalar(v)
% 有值取 double, null/缺失/文本一律 NaN: 下游用 isfinite 区分"有数"与"没数"。
    if iscell(v) && numel(v) == 1
        v = v{1};
    end
    if isnumeric(v) && isscalar(v) && isfinite(double(v))
        x = double(v);
    else
        x = NaN;
    end
end

function t = materialsCanonicalText(mat)
% 材料表的规范化文本: 与装置清单同一套字段顺序 + %.17g 数值格式, 因此同一内容必得同一
% 哈希。自指字段 (sha256_source / materials_sha256 / geometry_sha256) 排除在外。
    NL = sprintf('\n');
    lines = strings(1, 0);
    lines(end+1) = "tepc-materials-v1/canon-1";
    top = {"schema", "schema_version", "units_internal", "export_units", "unit_scale_from_m"};
    listed = [top, cellstr(selfRefNames()), {"materials", "value_status_vocabulary", "note"}];
    for i = 1:numel(top)
        nm = char(top{i});
        if isfield(mat, nm)
            lines(end+1) = string(nm) + "=" + canonValue(mat.(nm), {}); %#ok<AGROW>
        end
    end
    lines = [lines, extraLines(mat, listed)]; %#ok<AGROW>
    lines(end+1) = "n_materials=" + string(numel(mat.materials));
    for k = 1:numel(mat.materials)
        lines(end+1) = "material[" + string(k) + "]|" + ...
            canonStruct(mat.materials(k), matOrder()); %#ok<AGROW>
    end
    t = strjoin(lines, NL);
end

function o = matOrder()
    o = {"material_id", "state", "composition_molfrac", "elements", "density_kg_m3", ...
        "density_g_cm3", "temperature_K", "pressure_Pa", "compressibility_Z", ...
        "value_status", "source_document", "note"};
end

function paths = nullPathsOf(p, prefix, present)
% 递归收集值为 null 的字段路径, 形式 "part_id.a.b"。只走 JSON 里真写出来的键 (present),
% 否则 normalizeParts 补出来的空占位会被当成 null。累加器一律 1x0 行向量: 0x1 空串到行
% 向量上会报维度不一致。
    paths = strings(1, 0);
    fn = string(fieldnames(p)).';
    if nargin >= 3 && ~isempty(present)
        fn = fn(ismember(fn, present));
    end
    for i = 1:numel(fn)
        v = p.(fn{i});
        if iscell(v) && numel(v) == 1
            v = v{1};
        end
        q = prefix + "." + fn(i);
        if isstruct(v) && isscalar(v)
            paths = [paths, nullPathsOf(v, q)]; %#ok<AGROW>
        elseif iscell(v)
            for j = 1:numel(v)
                if isstruct(v{j}) && isscalar(v{j})
                    paths = [paths, nullPathsOf(v{j}, q + "(" + string(j) + ")")]; %#ok<AGROW>
                elseif isempty(v{j}) && ~ischar(v{j})
                    paths(end+1) = q + "(" + string(j) + ")"; %#ok<AGROW>
                end
            end
        elseif isempty(v) && ~ischar(v)
            paths(end+1) = q; %#ok<AGROW>
        end
    end
end

function paths = allNullPaths(items, present, names)
% 整张表的实测空值路径 (已排序), 供测试与 dev.allowed_null_paths 做集合相等锁。
% names = 每条目的标识 (零件用 part_id, 材料用 material_id): 两者不能共用一个字段名。
    paths = strings(1, 0);
    for k = 1:numel(items)
        have = strings(0, 1);
        if numel(present) >= k
            have = present{k};
        end
        nm = "(第" + string(k) + "条)";
        if numel(names) >= k && strlength(string(names(k))) > 0
            nm = string(names(k));
        end
        paths = [paths, nullPathsOf(items(k), nm, have)]; %#ok<AGROW>
    end
    paths = sort(paths);
end

function s = colIds(list, field)
% 取一列条目标识: 结构数组的 s.field 是逗号列表而不是数组, 必须逐条取。
    s = strings(numel(list), 1);
    for k = 1:numel(list)
        s(k) = textOrNil(getFieldOf(list(k), field));
    end
end

function assertNoParentCycle(ids, parents)
% parent_id 是每节点至多一条出边的图: 沿父链走一圈, 重新走到本次已访问的节点就是环。
% 环上的零件谁也不包含谁, 装配层次与爆炸视图位移都会失去定义。
    n = numel(ids);
    for k = 1:n
        seen = false(n, 1);
        cur = k;
        while cur > 0
            if seen(cur)
                m1 = "parent_id 成环: 从 " + ids(k) + " 出发沿父链又回到 " + ids(cur);
                m2 = "装配层次要求父链有限长, 环上的零件谁也不包含谁";
                error("tepc:geometry:ParentCycle", "%s; %s", m1, m2);
            end
            seen(cur) = true;
            cur = parents(cur);
        end
    end
end

function checkStageLocks(ids, used)
% transport_stage 是按 part_id 逐条映射出来的事实, 不是自由字段, 所以两条锁:
%   全表同值 = 映射被写死/参数传错 (旧实现把 part_id 传成了别的东西时正是这个形态);
%   gas_cavity / wall / anode 三条与既有映射不符 = 清单与输运侧各说各话。
% 其余零件的取值不在映射表里 (都是 not_used), 由 transport_enabled 一致性那条管。
    if numel(used) > 1 && numel(unique(used)) == 1
        m1 = "transport_stage 全表同值 (" + used(1) + ")";
        m2 = "四个取值退化成一个说明映射被写死, 该列没有逐零件信息";
        error("tepc:geometry:TransportStageDegenerate", "%s; %s", m1, m2);
    end
    expect = struct('part_id', {"gas_cavity", "wall", "anode"}, ...
        'stage', {"mc_chord_and_csda", "energy_loss_table", "field_model_only"});
    for i = 1:numel(expect)
        at = find(lower(ids) == lower(string(expect(i).part_id)), 1);
        if isempty(at)
            continue;
        end
        if used(at) ~= string(expect(i).stage)
            m1 = "零件 " + ids(at) + ": transport_stage = " + used(at);
            m2 = "与该零件在输运/场模型里的实际用法不符, 应为 " + string(expect(i).stage);
            error("tepc:geometry:TransportStageMismatch", "%s; %s", m1, m2);
        end
    end
end

function p = resolveRefPath(ref, manifestPath)
% 清单里的引用按三种基准依次解析: 项目根、清单所在目录、原样 (绝对路径)。
% 三种都能命中, 所以抄进清单的相对路径不会因换机器或换目录而失效。
    root = tepc.io.projectRoot();
    s = strrep(char(string(ref)), '\', '/');
    parts = strsplit(s, "/");
    cand = {fullfile(root, parts{:}), fullfile(fileparts(manifestPath), parts{:}), s};
    p = "";
    for i = 1:numel(cand)
        if isfile(cand{i})
            p = cand{i};
            return;
        end
    end
end

function unitsGuard(t, name, who)
    allowed = ["m", "mm", "um"];
    if t ~= "" && ~any(t == allowed)
        m1 = who + ": " + name + " = " + t + " 不在单位枚举内";
        m2 = "允许值: " + strjoin(allowed, " | ") + " (内部量恒为米, 这里只声明导出/显示单位)";
        error("tepc:geometry:BadExportUnits", "%s; %s", m1, m2);
    end
end

function placeholderScan(v, path, who)
% 未替换的占位符 (整个值形如 <...>) 会被下游当成合法字符串或数值用, 属静默失效, 在
% 读入阶段就按字段路径点名。自指字段 (本函数自己算的哈希) 允许留占位符或 null。
    if isstruct(v)
        fn = string(fieldnames(v)).';
        for i = 1:numel(v)
            for j = 1:numel(fn)
                if any(fn(j) == selfRefNames())
                    continue;
                end
                placeholderScan(v(i).(char(fn(j))), path + "." + fn(j), who);
            end
        end
    elseif iscell(v)
        for i = 1:numel(v)
            placeholderScan(v{i}, path + "(" + string(i) + ")", who);
        end
    elseif ischar(v) || isstring(v)
        t = string(v);
        for i = 1:numel(t)
            if t(i) ~= "" && startsWith(t(i), "<") && endsWith(t(i), ">")
                m1 = who + ": 字段 " + path + " 仍是占位符 " + t(i);
                m2 = "清单必须是实际值而不是待填模板";
                error("tepc:geometry:PlaceholderValue", "%s; %s", m1, m2);
            end
        end
    end
end

function o = selfRefNames()
    o = ["geometry_sha256", "sha256", "raw_sha256", "file_sha256", "canonical_text"];
end

%% ---------------- 规范化文本与哈希 ----------------

function canon = canonicalText(dev)
% 行累加器一律用 1xN 行向量: strings(0,1) 的首次 end+1 赋值会得到 1x1, 第二次起 MATLAB
% 沿第 2 维增长 -> 变成行向量, 再与列向量的 extraLines 做 [;] 串联就报维度不一致。
    NL = sprintf('\n');
    lines = strings(1, 0);
    lines(end+1) = "tepc-device-v2/canon-1";
    top = {"schema", "schema_version", "units_internal", "export_units", ...
        "unit_scale_from_m", "overlap_policy", "materials_ref", "note"};
    listed = [top, cellstr(selfRefNames()), {"parts"}];
    for i = 1:numel(top)
        nm = char(top{i});
        if isfield(dev, nm)
            lines(end+1) = string(nm) + "=" + canonValue(dev.(nm), subOrder(nm)); %#ok<AGROW>
        end
    end
    lines = [lines, extraLines(dev, listed)]; %#ok<AGROW>
    parts = dev.parts;
    lines(end+1) = "n_parts=" + string(numel(parts));
    for k = 1:numel(parts)
        lines(end+1) = "part[" + string(k) + "]|" + canonStruct(parts(k), partOrder()); %#ok<AGROW>
    end
    canon = strjoin(lines, NL);
end

function out = extraLines(s, listed)
% 固定清单之外的字段按名字排序补齐: 加字段一定改哈希, 换书写顺序不改哈希。
    fn = string(fieldnames(s)).';
    keep = ~ismember(lower(fn), lower(string(listed)));
    fn = sort(fn(keep));
    out = strings(1, numel(fn));
    for i = 1:numel(fn)
        nm = char(fn(i));
        out(i) = fn(i) + "=" + canonValue(s.(nm), subOrder(nm));
    end
end

function s = canonStruct(p, order)
    names = orderedNames(string(fieldnames(p)).', order);
    toks = strings(numel(names), 1);
    for i = 1:numel(names)
        nm = char(names(i));
        toks(i) = names(i) + "=" + canonValue(p.(nm), subOrder(nm));
    end
    s = strjoin(toks, "|");
end

function o = orderedNames(fn, order)
    ord = string(order);
    ord = ord(:).';                       % 统一成行向量
    if isempty(ord)
        o = sort(fn);                     % 没有固定顺序可用: 全按名字排序, 仍然确定
        return;
    end
    ord = ord(ismember(lower(ord), lower(fn)));
    o = [ord, sort(fn(~ismember(lower(fn), lower(ord))))];
end

function s = canonValue(v, order)
    if iscell(v) && numel(v) == 1 && ~iscell(v{1})
        v = v{1};                         % 1x1 cell 与其内容同义
    end
    if isempty(v)
        s = "null";
    elseif isstruct(v)
        toks = strings(numel(v), 1);
        for k = 1:numel(v)
            toks(k) = canonStruct(v(k), order);
        end
        if numel(v) == 1
            s = "{" + toks(1) + "}";
        else
            s = "{" + strjoin(toks, "};{") + "}";
        end
    elseif iscell(v)
        s = joinVals(canonList(v, order));
    elseif islogical(v)
        toks = strings(numel(v), 1);
        for k = 1:numel(v)
            toks(k) = boolTok(v(k));
        end
        s = joinVals(toks);
    elseif isnumeric(v)
        toks = strings(numel(v), 1);
        for k = 1:numel(v)
            toks(k) = fmtG(v(k));
        end
        s = joinVals(toks);
    elseif ischar(v)
        s = quoteStr(string(v));
    elseif isstring(v)
        toks = strings(numel(v), 1);
        for k = 1:numel(v)
            toks(k) = quoteStr(v(k));
        end
        s = joinVals(toks);
    else
        m1 = "规范化不支持该类型: " + string(class(v));
        m2 = "要哈希的东西必须全部可确定性文本化";
        error("tepc:geometry:CanonicalType", "%s; %s", m1, m2);
    end
end

function toks = canonList(c, order)
    toks = strings(numel(c), 1);
    for k = 1:numel(c)
        toks(k) = canonValue(c{k}, order);
    end
end

function s = joinVals(toks)
    if numel(toks) == 1
        s = toks(1);
    else
        s = "[" + strjoin(toks, ",") + "]";
    end
end

function t = boolTok(b)
    if b
        t = "1";
    else
        t = "0";
    end
end

function s = fmtG(v)
% 17 位十进制可精确往返 double; 整值也照此写 (0 就是 0, 1000 就是 1000), 不做 %d 特例,
% 免得同一数值因书写方式不同得到不同哈希。
    s = string(sprintf('%.17g', double(v)));
end

function s = quoteStr(t)
% 手写转义: 逐字符按码位分类 (34 双引号 / 92 反斜杠 / 10 换行 / 9 制表)。
% 反斜杠与引号都用 char(92)/char(34) 构造: MATLAB 的字符串字面量里反斜杠**不是**转义符
% (与 C/Python 相反), "\" 与 "\"" 这类写法会把词法搞乱, 码位构造不受影响。
    c = char(string(t));
    dq = char(34);
    bs = char(92);
    acc = dq;
    for i = 1:numel(c)
        ch = c(i);
        if ch == dq
            acc = [acc, bs, dq];        %#ok<AGROW>
        elseif ch == bs
            acc = [acc, bs, bs];        %#ok<AGROW>
        elseif ch == sprintf('\n')
            acc = [acc, bs, 'n'];       %#ok<AGROW>
        elseif ch == sprintf('\t')
            acc = [acc, bs, 't'];       %#ok<AGROW>
        else
            acc = [acc, ch];            %#ok<AGROW>
        end
    end
    s = string([acc, dq]);
end

function o = partOrder()
    o = {"part_id", "parent_id", "label", "primitive", "mesh", "dimensions_SI", ...
        "transform", "material_id", "role", "transport_enabled", "field_enabled", ...
        "display_enabled", "transport_stage", "value_status", "source_document", ...
        "drawing_revision", "tolerance_m", "temperature_K", "pressure_Pa", ...
        "surface_contact", "export_units", "note"};
end

function o = subOrder(nm)
% 嵌套对象里已知键的固定顺序 (其余键按名字排序补在后面)。switch 的表达式取 char:
% 单元数组形式的 case 只对 char/数值标量成立, 传 string 标量会一支都不命中。
    key = lower(char(string(nm)));
    if isempty(key)
        key = 'x';
    end
    switch key
        case {'primitive', 'dimensions_SI', 'mesh'}
            o = {"type", "radius_m", "inner_radius_m", "outer_radius_m", "thickness_m", ...
                "half_m", "height_m", "length_m", "half_angle_deg", "apex_m", "base_m", ...
                "direction"};
        case 'transform'
            o = {"translate_m", "rotate_deg", "direction", "scale"};
        otherwise
            o = {};
    end
end

function selfHashGuard(dev)
% 清单若已写死一个 64 位 hex 的 geometry_sha256 (即已落库的那一份), 它必须与本次
% 规范化内容算得的相等; 占位符与 null 跳过 (那不是值)。
    if ~isfield(dev, 'geometry_sha256')
        return;
    end
    t = textOrNil(dev.geometry_sha256);
    if strlength(t) ~= 64 || isempty(regexp(char(t), '^[0-9a-fA-F]{64}$', 'once'))
        return;
    end
    if ~strcmpi(char(t), char(dev.sha256))
        m1 = "清单自带的 geometry_sha256 与本次对 parts + materials 引用 算得的哈希不一致";
        m2 = "规范化文本在 dev.canonical_text 里, 逐行 diff 即可定位改动 (自指字段不参与哈希)";
        error("tepc:geometry:ShaMismatch", "%s; %s; 文件 %s", m1, m2, dev.path);
    end
end

%% ---------------- 与 cfg 的交叉校验 ----------------

function rows = crossCheckManifest(dev, cfg, mat)
% 清单侧与配置侧各按候选字段路径取数, 配置侧乘单位因子换算到米 (cfg 用 mm/um 书写,
% 清单内部一律米)。容差取相对 1e-9: 只容纳换算的最后一两个比特, 1000 倍量级的单位错
% 一定越界。零件表没有压强槽位 (压强随材料登记在材料表), 所以零件侧找不到时再问材料表。
    if ~isstruct(cfg) || ~isscalar(cfg)
        m1 = "交叉校验需要已解析的配置结构体";
        error("tepc:geometry:BadCfgArgument", "%s (实得 %s, 元素数 %d)", ...
            m1, class(cfg), numel(cfg));
    end
    tbl = crossSpec();
    rows = emptyCheckRows();
    nDone = 0;
    for i = 1:numel(tbl)
        q = tbl(i);
        [pid, fpath, mv, hasMan] = findManifestValue(dev.parts, q);
        if ~hasMan && ~isempty(q.matFields) && isfield(mat, 'materials')
            [pid, fpath, mv, hasMan] = findMaterialsValue(mat, q, dev.parts);
        end
        if ~hasMan
            if q.required
                m1 = "清单未声明 " + q.name + ": 找不到零件 " + strjoin(string(q.partIds), " | ");
                m2 = "的字段 " + strjoin(string(q.fields), " | ") + " 中任何一个有限数值";
                error("tepc:geometry:CrossCheckMissing", "%s; %s; 该项必须与配置比对", m1, m2);
            end
            rows(end+1) = checkRow(q.name, "", "", NaN, "not_declared", NaN, NaN, "skipped"); %#ok<AGROW>
            continue;
        end
        [cfgField, ref, rawv, factor, hasCfg] = findCfgValue(cfg, q);
        if ~hasCfg
            m1 = q.name + " 无法比对: 配置里找不到 " + strjoin(string(q.cfgNames), " | ");
            m2 = sprintf(' 中任何一个有限数值 (清单侧 %s.%s = %.17g)', char(pid), char(fpath), mv);
            error("tepc:geometry:DeviceConfigMismatch", "%s; %s", m1, m2);
        end
        d = abs(mv - ref);
        tol = max(1e-9 * max(abs(mv), abs(ref)), 1e-15);
        if d > tol
            m1 = sprintf('%s 不一致: 清单 %s.%s = %.17g', char(q.name), char(pid), char(fpath), mv);
            m2 = sprintf(' 配置 cfg.%s = %.17g (原值 %.17g 乘单位因子 %g 换算而来)', ...
                char(cfgField), ref, rawv, factor);
            m3 = sprintf('差 %.3e, 容差 %.3e', d, tol);
            error("tepc:geometry:DeviceConfigMismatch", "%s;%s; %s", m1, m2, m3);
        end
        nDone = nDone + 1;
        rows(end+1) = checkRow(q.name, pid, fpath, mv, cfgField, ref, d, "ok"); %#ok<AGROW>
    end
    if nDone == 0
        m1 = "清单与配置没有任何可比字段, 交叉校验退化为空操作";
        error("tepc:geometry:DeviceConfigMismatch", "%s; 文件 %s", m1, dev.path);
    end
end

function t = crossSpec()
% 五项交叉量的字段候选。清单侧是相对零件的 a.b 路径, 配置侧是相对 cfg 的路径加一个
% 单位乘子: 配置里 gasRadius_mm=25.4 与清单里 radius_m=0.0254 必须指向同一长度。
    gasIds = {"gas_cavity", "cavity", "gas_volume", "sensitive_gas_cavity"};
    gasRadiusFields = {"primitive.radius_m", "dimensions_SI.radius_m", ...
        "primitive.inner_radius_m", "mesh.radius_m"};
    gasRadiusCfg = {{'geometry.gasRadius_mm', 1e-3}, {'geometry.gasRadius_m', 1}, ...
        {'geometry.radii.b_m', 1}, {'geom.R_m', 1}, {'field.b', 1}};
    a = specRow("gas_cavity_radius_m", gasIds, gasRadiusFields, gasRadiusCfg, true);

    wallIds = {"wall", "wall_shell", "shell", "gas_cavity_wall"};
    wallFields = {"primitive.thickness_m", "dimensions_SI.thickness_m", ...
        "primitive.wall_thickness_m", "dimensions_SI.wall_thickness_m"};
    wallCfg = {{'geometry.wallThickness_mm', 1e-3}, {'geometry.wallThickness_m', 1}, ...
        {'geom.wallThickness_m', 1}};
    b = specRow("wall_thickness_m", wallIds, wallFields, wallCfg, true);

    anodeIds = {"anode", "anode_wire", "central_electrode", "center_electrode"};
    anodeFields = {"primitive.radius_m", "dimensions_SI.radius_m", ...
        "primitive.outer_radius_m", "mesh.radius_m"};
    anodeCfg = {{'geometry.anodeRadius_um', 1e-6}, {'geometry.anodeRadius_m', 1}, ...
        {'detector.innerRadius_m', 1}, {'field.a', 1}, {'geom.anode.radius_m', 1}};
    c = specRow("anode_radius_m", anodeIds, anodeFields, anodeCfg, true);

    tempFields = {"temperature_K", "primitive.temperature_K", "dimensions_SI.temperature_K"};
    tempCfg = {{'gas.temperature_K', 1}};
    d = specRow("gas_temperature_K", gasIds, tempFields, tempCfg, false, {"temperature_K"});

    pressFields = {"pressure_Pa", "primitive.pressure_Pa", "dimensions_SI.pressure_Pa"};
    pressCfg = {{'gas.pressure_Pa', 1}};
    e = specRow("gas_pressure_Pa", gasIds, pressFields, pressCfg, false, {"pressure_Pa"});

    t = [a, b, c, d, e];
end

function r = specRow(name, partIds, fields, cfgc, required, matFields)
% matFields 是"零件表里没有该槽位时, 去材料表的条目上找的字段名" (给空表示不问材料表)。
    if nargin < 6
        matFields = {};
    end
    names = cell(numel(cfgc), 1);
    for j = 1:numel(cfgc)
        names{j} = cfgc{j}{1};
    end
    r = struct('name', name, 'partIds', {partIds}, 'fields', {fields}, ...
        'cfgc', {cfgc}, 'cfgNames', {names}, 'required', required, ...
        'matFields', {matFields});
end

function k = findPart(parts, want)
    w = lower(string(want));
    k = 0;
    for i = 1:numel(parts)
        if ~isfield(parts(i), 'part_id')
            continue;
        end
        if lower(textOrNil(parts(i).part_id)) == w
            k = i;
            return;
        end
    end
end

function [pid, fpath, val, found] = findManifestValue(parts, q)
    pid = "";
    fpath = "";
    val = NaN;
    found = false;
    for i = 1:numel(q.partIds)
        k = findPart(parts, q.partIds{i});
        if k == 0
            continue;
        end
        for j = 1:numel(q.fields)
            [ok, v] = getPath(parts(k), q.fields{j});
            if ok && isnumeric(v) && isscalar(v) && isfinite(v)
                pid = textOrNil(parts(k).part_id);
                fpath = string(q.fields{j});
                val = double(v);
                found = true;
                return;
            end
        end
    end
end

function [mid, fpath, val, found] = findMaterialsValue(mat, q, parts)
% 材料表侧取值: 只认气体现那一条 (先按零件的 material_id 命中, 退一步按 state=="gas"),
% 免得把固体材料上的同名槽位当成气体压强来比对。
    mid = "";
    fpath = "";
    val = NaN;
    found = false;
    want = "";
    k = findPart(parts, q.partIds{1});
    if k > 0
        [gotId, vId] = getPath(parts(k), "material_id");
        if gotId
            want = lower(textOrNil(vId));
        end
    end
    list = mat.materials;
    for i = 1:numel(list)
        id = lower(textOrNil(getFieldOf(list(i), 'material_id')));
        st = lower(textOrNil(getFieldOf(list(i), 'state')));
        if want ~= ""
            hit = (id == want);
        else
            hit = (st == "gas");
        end
        if ~hit
            continue;
        end
        for j = 1:numel(q.matFields)
            v = getFieldOf(list(i), char(q.matFields{j}));
            if isnumeric(v) && isscalar(v) && isfinite(v)
                mid = textOrNil(getFieldOf(list(i), 'material_id'));
                fpath = "materials.json:" + q.matFields{j} + " (材料条目 " + mid + ")";
                val = double(v);
                found = true;
                return;
            end
        end
    end
end

function v = getFieldOf(s, nm)
    v = [];
    if isstruct(s) && isscalar(s) && isfield(s, nm)
        v = s.(nm);
        if iscell(v) && numel(v) == 1
            v = v{1};
        end
    end
end

function [fname, ref, rawv, factor, found] = findCfgValue(cfg, q)
    fname = "";
    ref = NaN;
    rawv = NaN;
    factor = NaN;
    found = false;
    for j = 1:numel(q.cfgc)
        [ok, v] = getPath(cfg, q.cfgc{j}{1});
        if ok && isnumeric(v) && isscalar(v) && isfinite(v)
            rawv = double(v);
            factor = q.cfgc{j}{2};
            ref = factor * rawv;
            fname = string(q.cfgc{j}{1});
            found = true;
            return;
        end
    end
end

function [found, val] = getPath(s, dotted)
% 按 a.b.c 逐段取字段, 顺手剥掉 jsondecode 可能留下的 1x1 cell。
    found = false;
    val = [];
    cur = s;
    f = strsplit(string(dotted), ".");
    for i = 1:numel(f)
        if iscell(cur) && numel(cur) == 1
            cur = cur{1};
        end
        if ~isstruct(cur) || ~isscalar(cur) || ~isfield(cur, char(f(i)))
            return;
        end
        cur = cur.(char(f(i)));
    end
    if iscell(cur) && numel(cur) == 1
        cur = cur{1};
    end
    found = true;
    val = cur;
end

function r = checkRow(quantity, pid, field, mv, cfgField, cfgVal, diff, status)
    r = struct('quantity', quantity, 'part_id', pid, 'field', field, ...
        'manifest_value', mv, 'cfg_field', cfgField, 'cfg_value', cfgVal, ...
        'abs_diff', diff, 'status', status);
end

function r = emptyCheckRows()
    r = struct('quantity', {}, 'part_id', {}, 'field', {}, 'manifest_value', {}, ...
        'cfg_field', {}, 'cfg_value', {}, 'abs_diff', {}, 'status', {});
end

%% ---------------- 枚举与字段清单 ----------------
% 成员一律取自两份清单的实际内容: 枚举里放一个清单没用过的值, 等于给"以后可能用到"
% 预支合法性, 该列写错时不会被拦住。新增成员必须同时改清单与本表。

function r = roleEnum()
    r = ["sensitive_gas", "wall", "electrode", "housing", "source"];
end

function s = stageEnum()
    s = ["mc_chord_and_csda", "energy_loss_table", "field_model_only", "not_used"];
end

function s = contactEnum()
    s = ["none", "gas_cavity", "wall_inner"];
end

function s = primitiveTypeEnum()
    s = ["box", "cone", "cylinder", "shell", "sphere"];
end

function s = materialStateEnum()
    s = ["gas", "liquid_water_equivalent", "solid", "vacuum"];
end

function s = unitsEnum()
    s = ["m", "mm", "um"];
end

function s = matFieldEnum()
% 每条材料都写出来的键 (温度/压强/压缩因子只在气态条目里出现, 属可选键)。
    s = ["material_id", "state", "composition_molfrac", "elements", "density_kg_m3", ...
        "density_g_cm3", "value_status", "source_document", "sha256_source", "note"];
end

function v = valueStatusEnum(mat)
% 词表读自材料表自带的 value_status_vocabulary: 两份清单共用一份证据等级词表, 不在
% 代码里另立一套 (MEASURED_CONFIG = 值逐字来自已登记配置, 与实验测得的 MEASURED 不同)。
    v = strings(0, 1);
    if isfield(mat, 'value_status_vocabulary')
        raw = mat.value_status_vocabulary;
        if iscell(raw)
            for i = 1:numel(raw)
                v(end+1) = textOrNil(raw{i}); %#ok<AGROW>
            end
        elseif isstring(raw) || ischar(raw)
            v = string(raw);
        end
    end
    v = sort(v(v ~= ""));
    if isempty(v)
        error("tepc:geometry:NoValueStatusVocabulary", ...
            "材料表没有可用的 value_status_vocabulary: 证据等级无从判定");
    end
end

function f = partFieldEnum()
% 零件条目的字段清单 (= 清单里每条零件实际写出的键集, 顺序与文件一致)。
    f = ["part_id", "parent_id", "label", "primitive", "transform", "material_id", ...
        "role", "transport_enabled", "field_enabled", "display_enabled", ...
        "transport_stage", "value_status", "source_document", "drawing_revision", ...
        "tolerance_m", "temperature_K", "surface_contact", "export_units", "note"];
end

function f = nullableFieldEnum()
% 允许为 null 的字段名 (还要过 allowedNullPaths 的逐条路径白名单)。
    f = ["parent_id", "tolerance_m", "temperature_K"];
end

function p = allowedNullPaths()
% 装置清单里"声明为未知"的全部路径, 形式 part_id.字段路径; 逐条取自文件实际内容。
% 加一条 null 必须同时在这里登记, 否则读取时报 UnexpectedNull。
    p = [nullableFor("gas_cavity", {"parent_id", "tolerance_m"}), ...
         nullableFor("wall", {"parent_id", "tolerance_m", "temperature_K"}), ...
         nullableFor("cathode", {"tolerance_m", "temperature_K"}), ...
         nullableFor("anode", {"parent_id", "tolerance_m", "temperature_K"}), ...
         nullableFor("world_envelope", {"parent_id", "tolerance_m", "temperature_K"}), ...
         nullableFor("equivalent_site_realized", ...
            {"parent_id", "tolerance_m", "temperature_K", "primitive.radius_m"}), ...
         nullableFor("equivalent_site_requested", {"parent_id", "tolerance_m", "temperature_K"}), ...
         nullableFor("source_cone", {"parent_id", "tolerance_m", "temperature_K"})];
    p = sort(p);
end

function p = nullableFor(pid, names)
    p = string(names(:)).';
    p = pid + "." + p;
end

function p = matAllowedNullPaths()
% 材料表里"声明为未知"的全部路径, 形式 material_id.字段路径。气体密度是运行时导出量
% (rho = p*M/(Z*R*T)), 钉进静态表会变成第二份真相, 所以两条密度都留 null。
    p = [nullableFor("gas_te_methane_based", ...
            {"elements", "density_kg_m3", "density_g_cm3"}), ...
         nullableFor("a150", {"composition_molfrac", "elements", "density_kg_m3"}), ...
         nullableFor("tissue_equivalent", ...
            {"composition_molfrac", "elements", "density_g_cm3"}), ...
         nullableFor("void", {"composition_molfrac", "elements", ...
            "density_kg_m3", "density_g_cm3"}), ...
         nullableFor("unspecified_in_config", {"state", "composition_molfrac", "elements", ...
            "density_kg_m3", "density_g_cm3"})];
    p = sort(p);
end

function need = primitiveKeys(typ)
% 该形状必须出现的分量 (取自清单实际内容): 缺一个就闭不出体积。
    switch char(string(typ))
        case 'sphere',    need = "radius_m";
        case 'shell',     need = ["outer_radius_m", "thickness_m"];
        case 'cylinder',  need = ["radius_m", "height_m"];
        case 'box',       need = "half_m";
        case 'cone',      need = ["half_angle_deg", "length_m"];
        otherwise,        need = strings(0, 1);
    end
end
