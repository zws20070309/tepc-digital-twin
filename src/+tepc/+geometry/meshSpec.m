function spec = meshSpec(cfg, R, cfgSha256, geometrySha256)
%MESSPEC 三维几何零件表 —— TEPC 3D 证据链的唯一真相源。
%
%   spec = meshSpec(cfg, R)                              % 无哈希 (headless 调试路径)
%   spec = meshSpec(cfg, R, cfgSha256)                   % 第三参数 = 配置 SHA-256
%   spec = meshSpec(cfg, R, cfgSha256, geometrySha256)   % 第四参数 = 几何产物 SHA-256
%
% 单位纪律: **spec 内所有长度一律 SI (米)**; mm/um 只出现在带
% _mm/_um 后缀的显示字段里, 且换算系数写死在代码中 (1 m = 1e3 mm, 1 m = 1e6 um)。
%
% 单一真相源纪律:
%   * 零件表只从**已解析**的 R 取数 (R.geom / R.field / R.site*), 绝不在此重算位点等效
%     或场类型 —— 那是 resolve.m 的职责 (GUI 与图形层同样禁止重算)。
%   * 电极拓扑只问 tepc.geometry.electrode(cfg) 一份: 仓库里同时存在多份 拓扑->场 映射
%     必然分叉 (resolve 的那份 centerSphere 分支曾是空操作), 所以这里不引入第四份:
%     .valid=false 时原样抛出它自己的 errId/reason, 不发明新错误标识符。
%   * 场线/等势面在这里用 tepc.detector.fieldModel 的解析式**算好存进 spec.field**,
%     图形层只画不算 (renderTEPC3D 不得含 RNG, 也不得调用任何抽样器)。
%   * 网格只在这里构造一份 (局部函数 buildMeshAt), 并以句柄 spec.buildPartMesh 交给
%     checkMesh / renderTEPC3D / exportGeometry 复用 —— 避免第二处几何实现。
%   * 装置清单 geometry/device_v2.json 经 tepc.geometry.deviceSpec 校验后在 3b 节进入构建
%     路径: 它声明的长度与身份列是这里的取数处, 逐位相同即取清单值, 十进制书写带来的
%     <=2 ulp 漂移保留运行时值 (V/S/lbar 的算式输入是 resolve 的 mm/um*10^k 换算),
%     越出带宽即 tepc:geometry:ManifestMismatch —— 同一台装置不允许有两份各说各话的
%     几何描述, 也不允许其中一份只在测试里被读。取用记录与两侧数值见 spec.manifest。
%
% 不画的东西 (引线/端盖/气口/支撑杆): 配置里没有这些尺寸, 画就等于在图形代码里编尺寸,
% 会污染 V/S/lbar 审计 —— 零件表只含配置可溯源的实体。
%
% transport_role 只有两个值 (判据是"是否进入 Monte Carlo 世界"):
%   'enter_mc'   气腔: tepc.geometry.sampleChord 的弦与 tepc.transport.csdaTransport 的
%                步进只消费 geom.R_m / V_m3 / S_m2 / lbar_gas_m。
%   'passive'    其余全部 —— 但"passive"不等于"什么都没干", 所以每个零件另带
%                transport_mode 说清**怎么**被用到 (逐条回查代码, 不是猜的):
%                  energy_loss_table  壁: csdaTransport.m 出腔后交给本地 wallEscape(),
%                        用同一张阻止本领表 + opts.rho_wall_g_cm3 (A-150 名义密度,
%                        读取点是该文件的 resolveWallDensity -> 常数注册表条目
%                        transport.a150.density_g_cm3, 源码不留数值镜像)
%                        + opts.wallThickness_m 求射程,
%                        再按 射程>壁厚 与否把剩余能量劈成 EdepWall/Eescape。既无弦抽样
%                        也无体元步进 => 壁不是 MC 几何体, 不能标 enter_mc。
%                  field_model_only   阳极: 半径只进 fieldModel/Diethorn 增益 (探测器层)。
%                  not_used           阴极/世界体/位点标记/源锥: 解析基线完全不消费。
%
% ASSUMED 项集中在 spec.assumed (报告由它生成, 不手抄): 丝长取法、
% A-150 名义密度、世界体倍数取下界、球腔+轴向丝的柱对称理想化; 源方向与锥半角只在配置
% 缺字段时才进这份清单 (它们现在由 source.direction / source.coneHalfAngle_deg 供数)。
%
% 溯源: 第三/第四参数只接受 64 位十六进制 SHA-256, 其他非空输入直接报错 (不当 0 用)。
% geometrySha256 必须是**已提交 run 的 manifest 值**: 几何构造函数不得哈希自己
% (自哈希会让 provenance 变成不可达的循环, 并破坏 "哈希 == 盘上内容")。两者齐备时
% spec.sha256Source = "manifest", 否则 "none" 且 spec.auditComplete = false —— 空串
% 合法仅为让最小调用路径跑通, 但这个"无溯源"状态必须机器可读。

if nargin < 3, cfgSha256 = ''; end
if nargin < 4, geometrySha256 = ''; end

%% ---------------- 0. 拓扑: 唯一真相源, 缺失/非法即拒 (不猜默认值) ----------------
el = tepc.geometry.electrode(cfg);
if ~el.valid
    error(el.errId, "%s", el.reason);        % 原样复用 electrode 的标识符与文案
end

%% ---------------- 1. 尺寸: 只从已解析的 R 取, 全部 SI ----------------
gt = lower(string(R.geom.type));             % 敏感体积 (微剂量学几何, Cauchy 4V/S 之体)
if gt ~= lower(string(cfg.geometry.type))
    error("tepc:geometry:SpecStale", ...
        "R.geom.type=%s 与 cfg.geometry.type=%s 不一致: R 不是这份 cfg 的解析结果", ...
        string(R.geom.type), string(cfg.geometry.type));
end
if ~(gt == "sphere" || gt == "cylinder_finite")
    error("tepc:geometry:UnsupportedVolume", ...
        "3D 零件表只支持 sphere / cylinder_finite 敏感体积 (实得 %s): 无限圆柱无端盖、平板无中心阳极", gt);
end
b_m   = double(R.geom.R_m);                  % 气腔半径 [m]
t_m   = double(R.geom.wallThickness_m);      % 壁厚 [m]
a_m   = double(R.field.a);                   % 阳极半径 [m]
hv_V  = double(R.field.hv_V);                % 高压 [V]
bboxR = double(R.geom.bboxR_m);              % 探测器包络半径 [m]
H_m   = NaN;                                 % 有限圆柱腔的轴向长度 [m]
if gt == "cylinder_finite"
    H_m = double(cfg.geometry.cylinderLength_mm)*1e-3;   % mm -> m: 显式系数 1e-3
end

%% ---------------- 2. 位点: 请求值与实现值必须成对出现 ----------------
dReq_m  = double(R.site_requested_d_tissue_m);
dReal_m = double(R.geom.site.d_tissue_m);    % derived 模式下已被 resolve 覆写为温压导出值
siteMode = "derived";
if isfield(R,'siteMode') && ~isempty(R.siteMode), siteMode = lower(string(R.siteMode)); end
lbarT_m = NaN; rhoT = NaN;
if isfield(R.geom,'site')
    if isfield(R.geom.site,'lbar_tissue_m'), lbarT_m = R.geom.site.lbar_tissue_m; end
    if isfield(R.geom.site,'rho_tissue'),    rhoT    = R.geom.site.rho_tissue;    end
end
relSite = abs(dReal_m - dReq_m)/dReq_m;
siteMismatch = relSite > 0.05;               % 5% 阈值与 siteConsistency 的 WARN 同源
                                             % 这里**只置标志不 warn**: 报警归 validate/runGate

%% ---------------- 3. 守卫 ----------------
dims = struct('gasRadius_m',b_m,'wallThickness_m',t_m,'anodeRadius_m',a_m, ...
    'bboxR_m',bboxR,'siteRequested_m',dReq_m,'siteRealized_m',dReal_m);
dn = fieldnames(dims); dv = struct2cell(dims);
badKeep = cellfun(@(v) isfinite(v) && v > 0, dv);
if ~all(badKeep)
    error("tepc:geometry:BadDimension", ...
        "meshSpec 尺寸必须有限且为正 [m]: %s", strjoin(dn(~badKeep), ', '));
end
if ~(a_m < b_m)
    error("tepc:geometry:AnodeTooBig", ...
        "阳极半径 %.6e m 必须小于气腔半径 %.6e m (否则无灵敏体积)", a_m, b_m);
end
if ~(t_m < b_m)
    error("tepc:geometry:BadDimension", ...
        "壁厚 %.6e m 不应大于气腔半径 %.6e m (内外皮会交叉)", t_m, b_m);
end
if gt == "cylinder_finite" && ~isfinite(H_m)
    error("tepc:geometry:BadDimension", "cylinder_finite 需要有限的 cylinderLength_mm");
end
% 世界体: 半宽至少取探测器包络尺寸的 5-10 倍。
% 倍数默认取区间下界 5; 可被 cfg.geometry.worldEnvelopeFactor 覆盖 —— 因为只有"可被
% 配置调小"时下面这条断言才是**可失败的门禁** (否则 env = 5*bbox 恒 >= 5*bbox 是同义反复)。
envFactor = 5.0;
if isfield(cfg.geometry,'worldEnvelopeFactor') && ~isempty(cfg.geometry.worldEnvelopeFactor)
    envFactor = double(cfg.geometry.worldEnvelopeFactor);
end
if ~isfinite(envFactor) || envFactor <= 0
    error("tepc:geometry:BadDimension", "worldEnvelopeFactor 必须有限为正 (实得 %g)", envFactor);
end
envHalf_m = envFactor*bboxR;
if ~(envHalf_m >= 5*bboxR)
    error("tepc:geometry:EnvelopeTooSmall", ...
        "世界体半宽 %.6e m 必须 >= 5*geom.bboxR_m (%.6e m): 包络倍数的下界", ...
        envHalf_m, 5*bboxR);
end

%% ---------------- 3b. 装置清单 geometry/device_v2.json: 声明量的取用与对账 ----------------
% 清单 (tepc.geometry.deviceSpec 负责 schema/枚举/量级/父链/哈希校验) 是这台装置几何量与
% 身份列的声明处; 本节把它的值**取进构建路径**, 而不是只读不用:
%   承重长度 (进 V/S/lbar 与场求解的半径/壁厚/极间距) —— 要求与 R 侧逐位相同, 只容纳
%     十进制书写带来的 <=2 ulp 漂移 (清单 0.00005 m 对 50*1e-6 m, 0.0284 对 0.0254+0.003);
%     带内取运行时值, 因为 resolve 的 mm/um*10^k 换算是这些量的算式输入;
%   模型/展示长度 (丝长, 世界体半宽) —— 在 1e-9 相对带内**取清单值**, 所以改清单确实会改
%     零件表与网格, 而 V/S/lbar/增益逐位不动 (它们只读 R);
%   身份列 (transport_role/transport_mode/materialStatus) —— 取清单值, 并与本文件按
%     part_id 分支的映射 (transportModeOf) 与 mkPart 字面量逐条对账; display_only 与清单的
%     三个开关不是同一根轴 (它是 checkMesh 的网格门分流), 所以只登记两侧取值不互相派生;
%   任一条越出各自带宽即 tepc:geometry:ManifestMismatch, 点名零件、字段、两侧的 17 位值。
% 请求位点直径是每次运行的用户输入 (不是装置尺寸), 故只登记不断言。
% 清单描述的不是这台装置 (敏感体积类型或阳极形状不符) 时整段不生效, 状态写进
% spec.manifest.state = not_this_device —— 不假装对过账, 也不因此拒画。
[mf, mfState] = loadDeviceManifest(cfg);
% 源方向/半角先解析并校验, 再进清单对账: 坏值的报错应当是它自己的错。
[srcDir, srcDirRaw, srcHalfDeg, srcDirFromCfg, coneFromCfg] = sourceShapeParams(cfg);
mfRows = {};
anodeRule_m = 2*b_m;                     % 球腔: 丝长 = 敏感体积直径 (模型选择, 非图纸)
if gt == "cylinder_finite", anodeRule_m = H_m; end
anodeLen_m = NaN;
mfOn = mfApplies(mf, gt, el);
if mfOn
    [b_m,        row] = mfBearing(mf, 'gas_cavity', 'radius_m',      b_m);        mfRows{end+1} = row;
    [t_m,        row] = mfBearing(mf, 'wall',       'thickness_m',   t_m);        mfRows{end+1} = row;
    [a_m,        row] = mfBearing(mf, 'anode',      'radius_m',      a_m);        mfRows{end+1} = row;
    [~,          row] = mfBearing(mf, 'cathode',    'radius_m',      b_m);        mfRows{end+1} = row;
    [~,          row] = mfBearing(mf, 'wall',       'outer_radius_m', b_m + t_m); mfRows{end+1} = row;
    % 世界体: 清单按默认包络倍数 5 声明半宽; 配置改了倍数就按比例缩放, 下界门禁重跑一次。
    [envHalf_m,  row] = mfDeclared(mf, 'world_envelope', 'half_m', 5*bboxR, ...
        envFactor/5, 1e-9);                                                       mfRows{end+1} = row;
    if ~(envHalf_m >= 5*bboxR)
        error("tepc:geometry:EnvelopeTooSmall", ...
            "清单声明的世界体半宽 %.6e m 按倍数 %g 缩放后仍须 >= 5*geom.bboxR_m (%.6e m)", ...
            envHalf_m, envFactor, 5*bboxR);
    end
    % 丝长: 配置无此字段, 清单是唯一声明处; 带宽外的声明不采信 (模型规则见 anodeRule_m)
    [anodeLen_m, row] = mfDeclared(mf, 'anode', 'height_m', anodeRule_m, 1, 1e-9); mfRows{end+1} = row;
    [~,          row] = mfDeclared(mf, 'source_cone', 'length_m', 5*bboxR, ...
        envFactor/5, 1e-9);                                                       mfRows{end+1} = row;
    % 源方向与半角: 清单现在也声明这两个数, 就必须与配置对账。否则那一栏只是装饰, 而本文件
    % 的纪律是"同一台装置不允许两份各说各话的几何描述, 也不允许其中一份只在测试里被读"。
    [mfHa, okHa] = mfField(mf, 'source_cone', 'half_angle_deg');
    haCfg = srcHalfDegForReconcile(cfg);
    if okHa && isfinite(haCfg)
        if abs(mfHa - haCfg) > 1e-12 * max(1, abs(haCfg))
            mfMismatchText('source_cone', 'half_angle_deg~source.coneHalfAngle_deg', ...
                string(mfHa), string(haCfg));
        end
        mfRows{end+1} = mfRow('source_cone', 'half_angle_deg~source.coneHalfAngle_deg', ...
            string(mfHa), string(haCfg), string(haCfg), ...
            informational(string(mfHa), string(haCfg)));     % 对账留痕
    elseif ~okHa
        % 清单侧没声明: 记一行"未声明"。留空行与"对过且一致"在表里长得一样, 读者就分不出
        % 哪一侧根本没供数 —— 这是双向对账要能被审计的前提。
        mfRows{end+1} = mfRow('source_cone', 'half_angle_deg~source.coneHalfAngle_deg', ...
            NaN, string(haCfg), string(srcHalfDeg), 'not_declared');
    elseif ~isfinite(haCfg)
        % 配置侧缺字段 (走兜底常量): 清单值仍然登记, 但采信的是兜底常量。
        mfRows{end+1} = mfRow('source_cone', 'half_angle_deg~source.coneHalfAngle_deg', ...
            string(mfHa), NaN, string(srcHalfDeg), 'config_absent_use_default');
    end
% mfField 只看平铺字段, 而清单把方向放在 transform 下 (deviceSpec 不展平 transform),
% 所以这里必须显式取嵌套值: 用 mfField 会得到 ok=false, 对账静默跳过, 那一栏就变回
% 只被测试读的装饰 —— 正是本文件禁止的形态。
    [dMan, dirDeclared] = mfTransformDir(mf, 'source_cone');
    dirCfg = srcDirForReconcile(cfg);
    if dirDeclared && isempty(dMan)
        % 清单声明了方向但值不可用 (非三元/非有限/零向量): 静默跳过就等于那一栏仍是装饰。
        mfMismatchText('source_cone', 'transform.direction->source.direction', ...
            mat2str(dMan), mat2str(dirCfg));
    end
    if ~isempty(dMan) && ~isempty(dirCfg)
        if norm(dMan - dirCfg) > 1e-12
            mfMismatchText('source_cone', 'transform.direction->source.direction', ...
                mat2str(dMan), mat2str(dirCfg));
        end
        mfRows{end+1} = mfRow('source_cone', 'transform.direction~source.direction', ...
            mat2str(dMan), mat2str(dirCfg), mat2str(dirCfg), ...
            informational(mat2str(dMan), mat2str(dirCfg)));   % 对账留痕: 比过 vs 跳过可分
    elseif isempty(dirCfg)
        mfRows{end+1} = mfRow('source_cone', 'transform.direction~source.direction', ...
            mat2str(dMan), NaN, mat2str(srcDir), 'config_absent_use_default');
    else
        mfRows{end+1} = mfRow('source_cone', 'transform.direction~source.direction', ...
            NaN, mat2str(dirCfg), mat2str(srcDir), 'not_declared');
    end
    mfState.state = "applied";
elseif mfState.state == "none"
    mfState.state = "not_this_device";
end

%% ---------------- 4. 场拓扑与 R.field 对账 ----------------
fieldTopology = lower(string(el.fieldKind));         % 'cylinder' | 'sphere'
if fieldTopology ~= lower(string(R.field.kind))
    error("tepc:geometry:TopologyFieldMismatch", ...
        "spec.fieldTopology=%s 必须等于 R.field.kind=%s (拓扑->场只允许一份映射)", ...
        fieldTopology, lower(string(R.field.kind)));
end
fm = tepc.detector.fieldModel(a_m, b_m, hv_V, fieldTopology);

%% ---------------- 5. 场线/等势面: 解析采样在这里算完, 图形层只画 ----------------
% 采样半径严格落在开区间内: 必须屏蔽 r<a 与 r>b, 避免 1/r 奇异值污染颜色范围。
% 钳位系数 1e-4 是**显示采样**约定, 不参与任何物理量。
rMin_m = a_m*(1 + 1e-4);
rMax_m = b_m*(1 - 1e-4);
if ~(rMax_m > rMin_m)
    error("tepc:geometry:NoFieldRoom", "阳极 %.6e m 与气腔 %.6e m 之间无场采样空间", a_m, b_m);
end
rS = linspace(rMin_m, rMax_m, 200).';
ES = fm.E(rS);
phiS = fm.phiw(rS);
if ~all(isfinite(ES)) || ~all(ES > 0)
    error("tepc:geometry:BadFieldSamples", "E(r) 采样必须有限且为正");
end
if ~(abs(fm.phiw(a_m) - 1) < 1e-12 && abs(fm.phiw(b_m)) < 1e-12)
    error("tepc:geometry:BadFieldSamples", ...
        "权重场边界条件被破坏: 必须 phi_w(a)=1 且 phi_w(b)=0");
end
phiLevels = [0.1 0.25 0.5 0.75 0.9];                  % 图例用的等权重面
if fieldTopology == "cylinder"
    rIso = b_m*exp(-phiLevels*log(b_m/a_m));           % phi_w = ln(b/r)/ln(b/a) 的反解
else
    rIso = 1./((1/a_m - 1/b_m)*phiLevels + 1/b_m);     % phi_w = (1/r-1/b)/(1/a-1/b) 的反解
end
rIso = rIso(:);
if ~all(isfinite(rIso)) || ~all(rIso > rMin_m) || ~all(rIso < rMax_m)
    error("tepc:geometry:BadIsoRadii", "等势面半径必须落在 (a,b) 内: %s", mat2str(rIso(:).'));
end
if max(abs(fm.phiw(rIso) - phiLevels(:))) > 1e-12
    error("tepc:geometry:BadIsoRadii", ...
        "等势面闭式反解与 fieldModel 不一致 (最大残差 %.3e)", max(abs(fm.phiw(rIso)-phiLevels(:))));
end
nLine = 12;                                            % 12 条径向场线 (z=0 中面)
thL = (0:nLine-1).'/nLine*2*pi;
rL = linspace(rMin_m, rMax_m, 60).';
fieldLines = cell(numel(thL),1);
for k = 1:numel(thL)
    fieldLines{k} = [rL*cos(thL(k)), rL*sin(thL(k)), zeros(size(rL))];
end

%% ---------------- 6. 零件表 ----------------
nDisp = 96;                                            % 展示网格分辨率 (合理区间 64-128)
pcell = {};

% (a) 敏感气腔 —— 唯一 enter_mc 的实体
pcell{end+1} = mkPart('gas_cavity', 'sensitive gas cavity', ...
    volShape(gt, b_m, H_m, NaN), gasLabel(cfg), 'MEASURED_CONFIG', 'enter_mc', ...
    'tepc.geometry.sampleChord + tepc.transport.csdaTransport (R_m/V_m3/S_m2/lbar_gas_m)', ...
    false, [0 0 0], '', sprintf(['弦长与能量沉积的唯一作用体; 解析值取自 R.geom: ' ...
    'V=%.6e m3, S=%.6e m2, lbar=%.6e m (Cauchy 4V/S, ICRU 36 -> 登记 R03)'], ...
    R.geom.V_m3, R.geom.S_m2, R.geom.lbar_gas_m));

% (b) 组织等效壁外表面 (A-150 壁): 外半径 = 气腔 + 壁厚
pcell{end+1} = mkPart('wall', 'A-150 wall (outer skin)', ...
    volShape(gt, b_m + t_m, H_m, 2*t_m), char(cfg.geometry.wallMaterial), 'ASSUMED', ...
    'passive', 'csdaTransport/wallEscape: 同一张阻止本领表 + rho_wall 取常数注册表 transport.a150.density_g_cm3 + 壁厚', ...
    false, [0 0 0], '', sprintf(['外半径 %.6e m = 气腔半径 + 壁厚。壁壳由内外两张闭合皮' ...
    '构成: 内皮是零件 cathode/气腔面, 外皮是本体; 二者径向间隙 = 壁厚'], b_m + t_m));

% (c) 阴极 = 壁内表面。与气腔面重合是物理事实, 不是建模疏漏。
pcell{end+1} = mkPart('cathode', 'cathode = wall inner surface', ...
    volShape(gt, b_m, H_m, NaN), char(cfg.geometry.wallMaterial), 'ASSUMED', 'passive', ...
    '解析输运不消费端盖/支撑几何 (配置无这些尺寸, 见文件头 "不画的东西")', ...
    false, [0 0 0], 'gas_cavity', ...
    '壳层内侧闭合皮; 与 gas_cavity 共面, 图形层只描边不重复铺透明面 (避免共面引起的假孔洞)');

% (d) 阳极: 形状只由拓扑决定, 不再由 geometry.type 猜
anodeLen = NaN;
if strcmp(el.anodeType, 'centerSphere')
    anodeShape = struct('type',"sphere",'radius_m',a_m,'height_m',NaN);
    anodeNote = sprintf('同心球阳极: 半径 %.6e m (与 %s 场自洽)', a_m, fieldTopology);
else
    anodeLen = anodeRule_m;                          % 球腔 2R / 圆柱腔 cylinderLength
    if isfinite(anodeLen_m), anodeLen = anodeLen_m; end   % 清单声明值 (带内已对账)
    anodeShape = struct('type',"cylinder",'radius_m',a_m,'height_m',anodeLen);
    anodeNote = sprintf('轴向丝状阳极: 半径 %.6e m, 长 %.6e m', a_m, anodeLen);
end
pcell{end+1} = mkPart('anode', 'anode (central electrode)', anodeShape, ...
    'unspecified_in_config', 'ASSUMED', 'passive', ...
    '阳极半径只进探测器层 (fieldModel/avalanche 的 a), 不进粒子输运', ...
    false, [0 0 0], '', anodeNote);

% (e) 世界体包络 (>= 5x 包络; 解析基线不消费, 为外部 MC 适配器预留的合同位)
pcell{end+1} = mkPart('world_envelope', 'Monte-Carlo world envelope', ...
    struct('type',"box",'radius_m',NaN,'height_m',NaN,'half_m',envHalf_m), ...
    'void', 'ASSUMED', 'passive', ...
    '解析基线不建 MC 世界: 凸体弦长走 4V/S 与 sampleChord 的解析轮廓', ...
    true, [0 0 0], '', sprintf('半宽 %.6e m = 5*geom.bboxR_m (包络倍数下界)', envHalf_m));

% (f,g) 等效位点标记: 实现值与请求值都画 (不得把 2 um 请求值误画成实际值)
pcell{end+1} = mkPart('equivalent_site_realized', 'equivalent site (realised)', ...
    struct('type',"sphere",'radius_m',dReal_m/2,'height_m',NaN), ...
    'tissue_equivalent', 'MEASURED_CONFIG', 'passive', ...
    '位点等效走质量厚度 rho_g*lbar_g = rho_t*lbar_t, 不是几何体输运', ...
    false, [0 0 0], '', sprintf('实现位点 d_t = %.6e m = %.6f um (模式 %s)', ...
    dReal_m, dReal_m*1e6, siteMode));
pcell{end+1} = mkPart('equivalent_site_requested', 'equivalent site (requested)', ...
    struct('type',"sphere",'radius_m',dReq_m/2,'height_m',NaN), ...
    'tissue_equivalent', 'MEASURED_CONFIG', 'passive', '同上 (仅标记, 不参与输运)', ...
    false, [0 0 0], '', sprintf('请求位点 d_t = %.6e m = %.6f um, 相对差 %.2f%%', ...
    dReq_m, dReq_m*1e6, 100*relSite));

% (h) 源锥: 方向与半角取自配置 (解析与值校验在 loadDeviceManifest 之后一次做完,
% 这里只按它们构造几何)。锥轴 = 入射方向的反向: 源在上游, 束沿 srcDir 传到腔心。
% 默认 srcDir=[0 0 -1] 给出顶点 (0,0,+envHalf) 与底心 (0,0,+0.4envHalf),
% 与本改动前逐位相同。
uSrcAxis = -srcDir;
apex_m = envHalf_m * uSrcAxis;
base_m = 0.4 * envHalf_m * uSrcAxis;
coneH_m = norm(apex_m - base_m);
baseR  = coneH_m * tand(srcHalfDeg);
srcStatus = 'ASSUMED';
if srcDirFromCfg && coneFromCfg
    % 用既有词表的 MEASURED_CONFIG ("值逐字来自已登记配置"), 不新造状态词: 清单与代码
    % 两侧的身份对账只比字符串, 造一个新词就等于把对账改成永真。
    srcStatus = 'MEASURED_CONFIG';
end
pcell{end+1} = mkPart('source_cone', sprintf('source cone (%s)', char(string(cfg.source.type))), ...
    struct('type',"cone",'radius_m',baseR,'height_m',coneH_m, ...
           'apex_m',apex_m,'base_m',base_m), ...
    'void', srcStatus, 'passive', ...
    srcRoleNote(srcDirFromCfg, coneFromCfg), ...
    true, (apex_m + base_m)/2, '', ...
    srcGeomNote(srcDir, srcHalfDeg, srcDirFromCfg, coneFromCfg));

parts = pcell{1};
for k = 2:numel(pcell), parts(k) = pcell{k}; end
for k = 1:numel(parts)
    m = buildMeshAt(parts(k).shape, nDisp);
    parts(k).V = m.V;
    parts(k).F = m.F;
    parts(k).meshVertices = size(m.V,1);
    parts(k).meshFaces = size(m.F,1);
    parts(k).analyticVolume_m3 = analyticVolume(parts(k).shape);
    parts(k).analyticArea_m2   = analyticArea(parts(k).shape);
    % transport_role 只用两个值 {enter_mc, passive} (GUI/表格按它判"是否进
    % MC 世界"); "怎么进"放在 transport_mode 里说清楚, 不靠第三个枚举值表达。
    parts(k).transport_mode = transportModeOf(parts(k).part_id);
    [parts(k), idRows] = mfIdentity(mf, parts(k), mfOn);  % 身份列: 清单声明值, 与本文件的映射对账
    mfRows = [mfRows, idRows];                           %#ok<AGROW>
    parts(k).nominal_radius_m = nominalRadius(parts(k).shape);
    parts(k).resolution_n = nDisp;
end

%% ---------------- 7. 组装 spec (SI) ----------------
spec = struct();
spec.units = "SI";                           % 内部单位声明: 导出/显示层才换算
spec.geometryType = gt;                      % 敏感体积 (球/有限圆柱) —— 与场拓扑可以不同
spec.electrodeTopology = lower(string(el.topology));
spec.fieldTopology = fieldTopology;          % 已断言 == R.field.kind
spec.anodeType = string(el.anodeType);
spec.elec = el;                              % 电极真相源快照 (渲染层 UserData 读它)
spec.field = struct('a_m',a_m,'b_m',b_m,'hv_V',hv_V,'kind',char(fieldTopology), ...
    'p',fm.p,'K',fm.K,'rSample_m',rS,'E_V_m',ES,'phiw',phiS, ...
    'rIso_m',rIso,'phiLevels',phiLevels(:), ...
    'clip_m',[rMin_m rMax_m],'note',fm.note);
spec.field.lines = fieldLines;               % 12x1 cell: 每条场线是 60x3 的 SI 坐标
spec.gasRadius_m = b_m;
spec.gasRadius_mm = b_m*1e3;                 % 1 m = 1e3 mm
spec.wallThickness_m = t_m;
spec.wallThickness_mm = t_m*1e3;
spec.wallOuterRadius_m = b_m + t_m;
spec.wallOuterRadius_mm = (b_m + t_m)*1e3;
spec.anodeRadius_m = a_m;
spec.anodeRadius_um = a_m*1e6;               % 1 m = 1e6 um
spec.anodeLength_m = anodeLen;
spec.cylinderLength_m = H_m;
spec.bboxR_m = bboxR;
spec.worldEnvelopeHalf_m = envHalf_m;
spec.worldEnvelopeFactor = envHalf_m/bboxR;          % 实测倍数 (>=5 由上面的门禁保证)
spec.worldEnvelopeMinFactorOfBbox = 5;
spec.requestedDiameter_m = dReq_m;
spec.realizedDiameter_m = dReal_m;
spec.requested_diameter_m = dReq_m;          % 别名拼写 (同一数值, 不重算)
spec.realized_diameter_m = dReal_m;
spec.requestedDiameter_um = dReq_m*1e6;
spec.realizedDiameter_um = dReal_m*1e6;
spec.siteRequestedDiameter_um = spec.requestedDiameter_um;
spec.siteRealizedDiameter_um = spec.realizedDiameter_um;
spec.siteRelativeDifference = relSite;
spec.siteEquivalenceMode = siteMode;
spec.site_mismatch = siteMismatch;
spec.site = struct('requested_m',dReq_m,'realized_m',dReal_m, ...
    'requestedDiameter_m',dReq_m,'realizedDiameter_m',dReal_m, ...
    'requestedRadius_m',dReq_m/2,'realizedRadius_m',dReal_m/2, ...
    'relativeDifference',relSite,'equivalenceMode',siteMode,'mismatch',siteMismatch, ...
    'lbar_tissue_m',lbarT_m,'rho_tissue_kg_m3',rhoT);
spec.source = struct('type',string(cfg.source.type),'energy_MeV',double(cfg.source.energy_MeV), ...
    'directionUnit',srcDir,'directionRaw',srcDirRaw,'coneHalfAngle_deg',srcHalfDeg, ...
    'coneApex_m',apex_m, ...
    'coneBaseCenter_m',base_m,'coneBaseRadius_m',baseR,'status',srcStatus, ...
    'fromConfig',struct('direction',srcDirFromCfg,'coneHalfAngle_deg',coneFromCfg), ...
    'angularModel',"isotropic_external (tepc.geometry.sampleChord)");
spec.V_m3 = double(R.geom.V_m3);             % 解析灵敏体积 (与三角网格无关)
spec.S_m2 = double(R.geom.S_m2);
spec.lbar_gas_m = double(R.geom.lbar_gas_m);
spec.lbar_gas_um = double(R.geom.lbar_gas_m)*1e6;
spec.meanChord_4V_over_S_m = 4*spec.V_m3/spec.S_m2;
spec.displayResolution_n = nDisp;
spec.transportGrid = struct('kind','analytic_none','note', ...
    '解析基线用 4V/S 闭式 + csdaTransport 自适应步长, 不消费三角网格; 本表网格是展示网格');
% 清单取用记录: state = applied (本节量已由 geometry/device_v2.json 供数) / not_this_device
% (清单描述的是另一台装置, 未取用) / missing (盘上没有那份清单)。rows 是逐条取用的结构数组,
% 每行给出两侧的 17 位值、取用的值与判定, 空 = 未取用。审计量 (V/S/lbar/4V/S) 不在此列:
% 它们只来自 R。
mfr = struct('part_id', {}, 'field', {}, 'manifest', {}, 'built', {}, ...
    'adopted', {}, 'verdict', {});
if ~isempty(mfRows)
    mfr = [mfRows{:}];
end
spec.manifest = struct('state', mfState.state, 'path', mfState.path, ...
    'sha256', mfState.sha256, 'materials_sha256', mfState.materials_sha256, ...
    'pair_sha256', mfState.pair_sha256, 'n_parts', mfState.n_parts, ...
    'reason', mfState.reason, 'rows', {mfr});
spec.offsets = explodeOffsets(b_m, t_m);     % 爆炸视图位移 (只平移, 不改尺寸)
spec.parts = parts;
% 轨迹叠加的**可选**输入: 由输运层服务 (tepc.geometry.traceSpec) 填入; 图形层不生成。
spec.traces = [];
spec.schematicTraces = true;                 % EventBatch 无 step 级轨迹 => 默认"示意"
% 网格构造句柄: checkMesh/renderTEPC3D/exportGeometry 复用同一份构造代码, 避免第二处
% 几何实现。句柄指向本文件的局部函数 buildMeshAt —— 纯函数, 无 RNG, 无抽样。
spec.buildPartMesh = @(shape,n) buildMeshAt(shape, n);

%% ---------------- 8. 溯源字段 ----------------
% 自哈希哨兵先查: 它是"调用方误在几何层算哈希"的信号, 比格式错误更值得单独报。
if any(strcmpi(charIfText(geometrySha256), "RECOMPUTED_IN_GEOMETRY"))
    error("tepc:geometry:SelfHashForbidden", ...
        'geometrySha256 必须是 manifest 里已落盘产物的哈希: 几何构造函数不得哈希自己');
end
okC = isSha256Hex(cfgSha256);
okG = isSha256Hex(geometrySha256);
if ~okC && ~isempty(charIfText(cfgSha256))
    error("tepc:geometry:BadSha256", "cfgSha256 必须是 64 位十六进制 (实得 '%s')", ...
        charIfText(cfgSha256));
end
if ~okG && ~isempty(charIfText(geometrySha256))
    error("tepc:geometry:BadSha256", ...
        "geometrySha256 必须是 64 位十六进制, 且必须来自已提交 run 的 manifest (不在此重算)");
end
spec.sourceConfigSha256 = "";
if okC, spec.sourceConfigSha256 = char(string(cfgSha256)); end
spec.geometrySha256 = "";
if okG, spec.geometrySha256 = char(string(geometrySha256)); end
if okC && okG, spec.sha256Source = "manifest"; else, spec.sha256Source = "none"; end
spec.geometrySha256Source = "none";
if okG, spec.geometrySha256Source = "manifest"; end
spec.auditComplete = okC && okG;             % false = 无溯源, 报告须打 3D_NOT_AUDITED

%% ---------------- 9. ASSUMED 清单 ----------------
% 源方向/锥角只在**没给配置**时才是假定值: 给了就不该继续挂在 ASSUMED 清单里 (那会让
% 清单越攒越长, 读者分不清哪一条还欠着)。缺哪一条就只列哪一条。
srcAssumed = {};
if ~srcDirFromCfg
    srcAssumed{end+1} = sprintf( ...
        'source.direction 缺字段: 兜底 [0 0 -1] (纯显示轴向; 解析基线各向同性)');
end
if ~coneFromCfg
    srcAssumed{end+1} = 'source.coneHalfAngle_deg 缺字段: 兜底 15 deg (纯显示锥角)';
end
% 与"丝"有关的假定必须按拓扑分支: centerSphere 下 anodeLen 是 NaN, 直接 sprintf 会把
% "axialWire 丝长 = NaN m" 与一根不存在的丝写进发布清单 (实测踩过)。
wireAssumed = {};
if strcmp(el.anodeType, 'centerSphere')
    wireAssumed{end+1} = sprintf(['阳极是中心球 (半径 %.6e m), 本拓扑没有轴向丝: ' ...
        '丝长、丝的悬空端、沿丝引线孔径这些登记项在此拓扑不适用'], a_m);
    wireAssumed{end+1} = '中心球阳极的场为纯径向 1/r: 无柱对称乘法区理想化, 但也无丝状阴极可比';
else
    wireAssumed{end+1} = sprintf(['axialWire 丝长 = %.6e m: 球腔取 2R (圆柱腔取 cylinderLength_mm); ' ...
        '配置无丝长字段, 由装置清单 anode.primitive.height_m 声明 => 模型选择而非图纸'], anodeLen);
    wireAssumed{end+1} = sprintf(['阳极丝负 z 端 (z = %.6e m) 无机械支撑建模: 清单只声明丝的半径' ...
        '与长度, 张紧/支撑结构无尺寸来源 => 登记为缺口而不是造一个零件'], -anodeLen/2);
end
% 注意 wireAssumed 必须在花括号**外**拼接: 写成 {..., wireAssumed} 会把整个 1x2 cell
% 套成第 6 个元素 (嵌套 cell), strjoin/exportGeometry 会当场抛 InvalidCellType。
spec.assumed = [srcAssumed, { ...
    'anode.material 未指定: 配置只给 anodeRadius_um, 无材料/引线尺寸', ...
    sprintf(['A-150 壁名义密度取自常数注册表 transport.a150.density_g_cm3 = %.4f g/cm3 ' ...
        '(ASSUMED, 非证书值; 读取点 tepc.transport.wallDensity)'], ...
        tepc.config.constants('transport.a150.density_g_cm3')), ...
    '球腔 + 轴向丝 = 乘法区柱对称理想化: 未找到可引用来源支持该具体构型 (见 electrode.m 头注)', ...
    '世界体半宽取建议区间 [5,10]x 包络的下界 5x', ...
    sprintf(['高压引线穿壁孔径未建模: 壁在输运里按连续闭合球壳参与 (csdaTransport 只用标量 ' ...
        'R = %.6e m 求交), 加任何穿壁引线或绝缘件都会与输运几何矛盾, 而装置清单未给孔径尺寸 ' ...
        '=> 不造装饰件, 只在此登记'], b_m)}, wireAssumed];
end

%% ==================== 局部函数 (仅此文件内) ====================

function [mf, st] = loadDeviceManifest(cfg)
% 读装置清单 (几何量与身份列的声明处)。路径或内存清单由 cfg.geometry.deviceManifest 指定,
% 缺省取 <projectRoot>/geometry/device_v2.json; 内存清单让负对照不必碰盘上那份。
% 这里不把 cfg 交给 deviceSpec: 清单与运行时值的对账在下面的 mfBearing/mfDeclared 里做,
% 用的正是已解析的 R (mm/um 换算之后), 因此配置侧的 1000 倍单位错同样会被
% tepc:geometry:ManifestMismatch 拒住, 报错口径只有一套。
% 只有默认路径上的文件不存在才降级为 missing; 显式指定的路径读不到就是错, 不静默当成没清单。
st = struct('state', "none", 'path', "", 'sha256', "", 'materials_sha256', "", ...
    'pair_sha256', "", 'n_parts', 0, 'reason', "未指定清单, 取项目根 geometry/device_v2.json");
ref = "";

inMem = [];
if isfield(cfg, 'geometry') && isfield(cfg.geometry, 'deviceManifest')
    v = cfg.geometry.deviceManifest;
    if isstruct(v) && isscalar(v)
        inMem = v;
    elseif (ischar(v) || (isstring(v) && isscalar(v))) && ~isempty(strtrim(string(v)))
        ref = strtrim(string(v));
        st.path = char(ref);
    end
end
try
    if ~isempty(inMem)
        mf = tepc.geometry.deviceSpec(inMem);
    elseif ref == ""
        mf = tepc.geometry.deviceSpec();
    else
        mf = tepc.geometry.deviceSpec(char(ref));
    end
catch err
    if ref == "" && isempty(inMem) && strcmp(err.identifier, "tepc:geometry:ManifestNotFound")
        st.state = "missing";
        st.reason = string(err.message);
        mf = [];
        return
    end
    rethrow(err)
end
st.sha256 = string(mf.sha256);
st.materials_sha256 = string(mf.materials_sha256);
st.pair_sha256 = string(mf.pair_sha256);
st.n_parts = double(mf.n_parts);
if strlength(st.path) == 0, st.path = string(mf.path); end
st.reason = "清单已通过 deviceSpec 的 schema/枚举/量级/父链/哈希校验";
end

function tf = mfHasPart(mf, id)
tf = false;
if isempty(mf), return; end
tf = any(string(mf.part_ids) == string(id));
end

function g = mfGeom(mf, id)
g = [];
if isempty(mf), return; end
k = find(string(mf.part_ids) == string(id), 1);
if ~isempty(k), g = mf.geometry(k); end
end

function tf = mfApplies(mf, gt, el)
% 清单是否描述**这台**装置: 敏感体积类型与阳极形状两处都得对上。对不上时表里的数字属于
% 另一台装置, 采信它就是拿别人的图纸画本图 —— 所以整段不取用, 状态写进 spec.manifest。
tf = false;
if isempty(mf), return; end
g = mfGeom(mf, 'gas_cavity');
a = mfGeom(mf, 'anode');
if isempty(g) || isempty(a), return; end
want = lower(string(gt));
if want == "cylinder_finite", want = "cylinder"; end
if lower(string(g.type)) ~= want, return; end
wantAnode = "cylinder";                       % 轴向丝 -> 圆柱
if strcmp(el.anodeType, 'centerSphere'), wantAnode = "sphere"; end
tf = lower(string(a.type)) == wantAnode;
end

function [d, declared] = mfTransformDir(mf, id)
% 取清单里 transform.direction (嵌套字段, mfField 只看平铺字段, 取不到它)。
% declared=true 而 d=[] 表示"清单声明了但值不可用" —— 调用方必须把它当不一致处理,
% 否则坏值会让对账静默跳过, 那一栏又变回只被读的装饰。
d = []; declared = false;
if isempty(mf), return; end
k = find(string(mf.part_ids) == string(id), 1);
if isempty(k) || ~isfield(mf.parts(k), 'transform'), return; end
tr = mf.parts(k).transform;
if ~isfield(tr, 'direction') || isempty(tr.direction), return; end
declared = true;
v = double(tr.direction);
if isnumeric(v) && numel(v) == 3 && all(isfinite(v)) && norm(v) > 0
    d = v(:).' / norm(v);
end
end

function [dirUnit, dirRaw, halfDeg, dirFromCfg, coneFromCfg] = sourceShapeParams(cfg)
% 源方向与锥半角的唯一解析处: 取值 -> 判形状 -> 判有限/非零 -> 归一。
% 放在清单对账之前调用, 所以坏值报的是 BadSourceDirection / BadSourceCone, 而不是
% 被清单不一致抢先一步 (那会把"配置写错"说成"两份几何描述各说各话")。
dirRaw = [0 0 -1];  dirFromCfg = false;
if isfield(cfg.source, 'direction') && ~isempty(cfg.source.direction)
    dv = cfg.source.direction;
    % 类型判定必须在 double() 之前做: double('abc') = [97 98 99]、double(true) = 1 会把
    % 非数值伪装成合法方向, 然后被标成 MEASURED_CONFIG —— 那是把垃圾说成配置值。
    if ~isnumeric(dv) || islogical(dv)
        error("tepc:geometry:BadSourceDirection", ...
            "source.direction 必须是 3 个有限数的数值数组, 实得 %s 类型", class(dv));
    end
    dirRaw = double(dv);
    dirFromCfg = true;
end
if numel(dirRaw) ~= 3
    % 先判形状再判有限性: 2 元或 4 元向量直接进 norm/dot/cross 报的是 base 的尺寸错。
    error("tepc:geometry:BadSourceDirection", ...
        "source.direction 必须是 3 个有限数, 实得 %s", mat2str(dirRaw));
end
dirRaw = dirRaw(:).';
n = norm(dirRaw);
if ~(all(isfinite(dirRaw)) && isfinite(n) && n > 0)
    % 零向量归一会得 NaN, 让整台工作台画出一个非有限锥体。配置层已拦一次, 但 meshSpec
    % 也可被测试与脚本直接调用, 所以自己也要拒绝而不是往下传 NaN。
    error("tepc:geometry:BadSourceDirection", ...
        "source.direction 无法归一 (需 3 个有限数且非零向量), 实得 %s", mat2str(dirRaw));
end
dirUnit = dirRaw / n;                        % 单位化只做在这里, 一处一次
halfDeg = 15;  coneFromCfg = false;
if isfield(cfg.source, 'coneHalfAngle_deg') && ~isempty(cfg.source.coneHalfAngle_deg)
    hv = cfg.source.coneHalfAngle_deg;
    % 同上: double(true)=1 落在 (0,90) 里, 会被当成"配置给了 1 度"并标成 MEASURED_CONFIG。
    if ~isnumeric(hv) || islogical(hv)
        error("tepc:geometry:BadSourceCone", ...
            "source.coneHalfAngle_deg 必须是数值标量, 实得 %s 类型", class(hv));
    end
    halfDeg = double(hv);
    coneFromCfg = true;
end
% 下界开区间: 半角 0 使底半径 = h*tan(0) = 0, 环上顶点全部重合 -> checkMesh 数出 n-1 个
% 重复顶点与 2n 个零面积面, 整次运行被降级成 3D_NOT_AUDITED。上界 90 度: tan 发散。
if ~(isscalar(halfDeg) && isfinite(halfDeg) && halfDeg > 0 && halfDeg < 90)
    error("tepc:geometry:BadSourceCone", ...
        "source.coneHalfAngle_deg 须落在 (0, 90) 度内, 实得 %s", mat2str(halfDeg));
end
end

function h = srcHalfDegForReconcile(cfg)
% 只取配置真给了的锥角; 缺字段返回 NaN => 上面的对账整段跳过 (不与兜底常量硬比)。
h = NaN;
if isfield(cfg.source, 'coneHalfAngle_deg') && ~isempty(cfg.source.coneHalfAngle_deg)
    h = double(cfg.source.coneHalfAngle_deg);
end
end

function d = srcDirForReconcile(cfg)
% 同上, 但给**归一后**的方向: 清单可以用非单位向量声明同一方向 (长度不是新信息)。
d = [];
if isfield(cfg.source, 'direction') && ~isempty(cfg.source.direction)
    v = double(cfg.source.direction(:));
    if numel(v) == 3 && all(isfinite(v)) && norm(v) > 0
        d = v.' / norm(v);
    end
end
end

function [v, ok] = mfField(mf, id, nm)
% 声明值: 先看 deviceSpec 归一化后的几何行 (null -> NaN, 视为未声明), 再看清单原条目
% (三个布尔开关与 label 不在几何行里)。文本给 char, 数值给 double, 开关给 logical。
v = []; ok = false;
g = mfGeom(mf, id);
if isempty(g), return; end
nm = char(string(nm));
if isfield(g, nm)
    x = g.(nm);
    if isnumeric(x) && isscalar(x) && isfinite(double(x))
        v = double(x); ok = true; return
    end
    if isstring(x) && isscalar(x) && strlength(x) > 0
        v = char(x); ok = true; return
    end
end
k = find(string(mf.part_ids) == string(id), 1);
if isempty(k), return; end
p = mf.parts(k);
if ~isfield(p, nm), return; end
x = p.(nm);
if iscell(x) && isscalar(x), x = x{1}; end
if islogical(x) && isscalar(x)
    v = logical(x); ok = true;
elseif isnumeric(x) && isscalar(x) && isfinite(double(x))
    v = double(x); ok = true;
elseif ischar(x) || (isstring(x) && isscalar(x))
    v = char(string(x)); ok = true;
end
end

function row = mfRow(id, nm, mv, cv, val, verdict)
row = struct('part_id', char(id), 'field', char(nm), 'manifest', mv, ...
    'built', cv, 'adopted', val, 'verdict', char(verdict));
end

function [val, row] = mfBearing(mf, id, nm, rt)
% 承重长度 (进 V/S/lbar 与场的算式): 清单值与运行时值必须逐位相同; 只容纳十进制书写带来的
% <=2 ulp 漂移, 且带内仍取运行时值 —— 采信清单字面量会把最后一位挪掉, 那是改数字不是改口径。
val = rt;
[mv, ok] = mfField(mf, id, nm);
if ~ok || ~isnumeric(mv) || isempty(mf)
    row = mfRow(id, nm, NaN, rt, rt, 'not_declared');
    return
end
if mv == rt
    val = mv;   row = mfRow(id, nm, mv, rt, val, 'adopted_bit_identical');
elseif abs(mv - rt) <= 2*eps(mv)
    row = mfRow(id, nm, mv, rt, rt, sprintf('spelling_drift_%+.0fulp', (mv-rt)/max(eps(rt), realmin)));
else
    mfMismatch(id, nm, mv, rt, 2*eps(mv));
end
end

function [val, row] = mfDeclared(mf, id, nm, ref, scale, band)
% 模型/展示长度 (丝长、世界体半宽、源锥顶高): 带宽内**取清单值**, 因此清单确实是这几量的
% 供数处 —— 换一份清单就换一张图; 带宽外报错 (清单与模型规则各说各话)。
% ref = 按模型规则算出的基准值, scale = 配置侧倍数换算 (世界体按包络倍数缩放)。
val = ref*scale;
[mv, ok] = mfField(mf, id, nm);
if ~ok || ~isnumeric(mv) || isempty(mf)
    row = mfRow(id, nm, NaN, ref, val, 'not_declared');
    return
end
if abs(mv - ref) <= band*max(abs(ref), abs(mv))
    val = mv*scale;
    if mv == ref && scale == 1
        row = mfRow(id, nm, mv, ref, val, 'adopted_bit_identical');
    else
        row = mfRow(id, nm, mv, ref, val, sprintf('adopted_within_rel_%g', band));
    end
else
    mfMismatch(id, nm, mv, ref, band*max(abs(ref), abs(mv)));
end
end

function [p, rows] = mfIdentity(mf, p, applies)
% 身份列取清单声明值, 取用前先与本文件按 part_id 分支的映射 (transportModeOf) 和 mkPart
% 字面量逐条对账: 对不上就是"清单说的用法"与"代码里的用法"分叉, 那正是两张表各活一次的样子。
rows = {};
% applies=false 表示这份清单描述的是别的装置: 声明列不该对本机生效, 更不该把本机拒画
if nargin < 3 || ~applies || isempty(mf) || ~mfHasPart(mf, p.part_id), return; end

[stage, ok] = mfField(mf, p.part_id, 'transport_stage');
if ok
    rows{end+1} = mfRow(p.part_id, 'transport_stage', char(stage), p.transport_mode, ...
        char(stage), textAdopt(stage, p.transport_mode));
    if ~strcmp(char(stage), char(p.transport_mode))
        mfMismatchText(p.part_id, 'transport_stage', string(stage), string(p.transport_mode));
    end
    p.transport_mode = char(stage);
end
[en, ok] = mfField(mf, p.part_id, 'transport_enabled');
if ok && islogical(en)
    role = "passive";
    if en, role = "enter_mc"; end
    rows{end+1} = mfRow(p.part_id, 'transport_enabled', string(role), ...
        string(p.transport_role), char(role), textAdopt(role, p.transport_role));
    if role ~= string(p.transport_role)
        mfMismatchText(p.part_id, 'transport_enabled->transport_role', role, ...
            string(p.transport_role));
    end
    p.transport_role = char(role);
end
[tfe, ok1] = mfField(mf, p.part_id, 'field_enabled');
[tte, ok2] = mfField(mf, p.part_id, 'transport_enabled');
if ok1 && ok2 && islogical(tfe) && islogical(tte)
    % display_only 与三个开关不是同一根轴: 前者是"网格质量门的分流"(checkMesh 据此决定
    % 尺寸门查不查这件零件), 后者是"进哪条计算链"。位点标记不进任何链却仍要过网格门,
    % 所以这里只登记两侧取值, 不互相派生。
    rows{end+1} = mfRow(p.part_id, 'display_only', string(~(tte || tfe)), ...
        string(logical(p.display_only)), logical(p.display_only), ...
        informational(string(~(tte || tfe)), string(logical(p.display_only))));
end
[vs, ok] = mfField(mf, p.part_id, 'value_status');
if ok
    rows{end+1} = mfRow(p.part_id, 'value_status', char(vs), p.materialStatus, ...
        char(vs), textAdopt(vs, p.materialStatus));
    if ~strcmp(char(vs), char(p.materialStatus))
        mfMismatchText(p.part_id, 'value_status->materialStatus', string(vs), ...
            string(p.materialStatus));
    end
    p.materialStatus = char(vs);
end
% label 与 material 两侧口径不同 (清单按材料表 id, 本文件按配置组分拼气体名; 源类型只出现在
% 本文件的 label 里), 所以只登记不断言 —— 分叉会出现在 spec.manifest.rows 里, 不是静默。
[lb, ok] = mfField(mf, p.part_id, 'label');
if ok
    rows{end+1} = mfRow(p.part_id, 'label', char(lb), p.label, p.label, ...
        informational(lb, p.label));
end
[mid, ok] = mfField(mf, p.part_id, 'material_id');
if ok
    rows{end+1} = mfRow(p.part_id, 'material_id', char(mid), p.material, p.material, ...
        informational(mid, p.material));
end
[par, ok] = mfField(mf, p.part_id, 'parent_id');
if ok
    rows{end+1} = mfRow(p.part_id, 'parent_id', char(par), p.coincident_with, ...
        p.coincident_with, informational(par, p.coincident_with));
end
end

function v = textAdopt(a, b)
if strcmp(char(string(a)), char(string(b))), v = 'adopted_text_match';
else, v = 'conflict'; end
end

function v = informational(a, b)
if strcmp(char(string(a)), char(string(b))), v = 'informational_match';
else, v = 'informational_diff'; end
end

function mfMismatch(id, nm, mv, cv, band)
error("tepc:geometry:ManifestMismatch", ...
    ['装置清单与构建值不一致: 零件 %s 的字段 %s\n' ...
     '  清单声明 (geometry/device_v2.json) %.17g\n' ...
     '  构建侧 (由配置解析)             %.17g\n' ...
     '  差 %.3e, 容差 %.3e —— 超出该量的声明带宽, 两侧已不是同一台装置'], ...
    char(id), char(nm), mv, cv, abs(mv - cv), band);
end

function mfMismatchText(id, nm, mv, cv)
error("tepc:geometry:ManifestMismatch", ...
    ['装置清单与构建值不一致: 零件 %s 的字段 %s\n' ...
     '  清单声明 "%s", 构建侧 "%s" —— 身份列与代码里的实际用法分叉'], ...
    char(id), char(nm), char(mv), char(cv));
end

function p = mkPart(id, label, shape, material, materialStatus, role, evidence, ...
    displayOnly, centre, coincidentWith, note)
p = struct('part_id',char(id),'label',char(label),'shape',shape, ...
    'material',char(material),'materialStatus',char(materialStatus), ...
    'transport_role',char(role),'transport_evidence',char(evidence), ...
    'units',"SI",'display_only',displayOnly,'star_centre_m',double(centre(:).'), ...
    'coincident_with',char(coincidentWith),'note',char(note), ...
    'V',zeros(0,3),'F',zeros(0,3),'meshVertices',0,'meshFaces',0, ...
    'analyticVolume_m3',NaN,'analyticArea_m2',NaN);
end

function s = volShape(gt, r_m, h_m, dh_m)
% 敏感体积形状 -> 零件 shape (球: 高度不参与; 有限圆柱: h_m=长度, dh_m=轴向增量)
if gt == "sphere"
    s = struct('type',"sphere",'radius_m',r_m,'height_m',NaN);
else
    h = h_m;
    if ~isnan(dh_m), h = h_m + dh_m; end     % 壁外皮的轴向也各加一个壁厚
    s = struct('type',"cylinder",'radius_m',r_m,'height_m',h);
end
end

function lbl = gasLabel(cfg)
% 气体名: 由配置的摩尔分数拼出 (不引入 config 之外的成分/名称)。
try
    fn = fieldnames(cfg.gas.composition_molfrac);
    fn = fn(~startsWith(fn,'_'));
    parts = cell(numel(fn),1);
    for i = 1:numel(fn)
        parts{i} = sprintf('%s:%.2f', fn{i}, cfg.gas.composition_molfrac.(fn{i}));
    end
    lbl = ['TE gas (' strjoin(parts, ' ') ')'];
catch
    lbl = 'TE gas';
end
end

function o = explodeOffsets(b_m, t_m)
% 爆炸视图位移: 只沿 z 平移, 不缩放 => 不改变任何 V/S/lbar 审计量。
dz = 1.6*(b_m + t_m);                        % 分离量: 显示约定, 非尺寸
o = struct('gas_cavity',[0 0 0],'wall',[0 0 dz],'cathode',[0 0 2*dz], ...
    'anode',[0 0 -dz],'equivalent_site_realized',[0 0 -2*dz], ...
    'equivalent_site_requested',[0 0 -3*dz],'world_envelope',[0 0 0], ...
    'source_cone',[0 0 0]);
end

function tf = isSha256Hex(v)
tf = false;
c = charIfText(v);
if numel(c) == 64
    tf = all((c >= '0' & c <= '9') | (c >= 'a' & c <= 'f') | (c >= 'A' & c <= 'F'));
end
end

function m = transportModeOf(id)
% "怎么进输运" 的诚实标注 (逐条回查过代码, 见文件头 transport_role 一节):
%   mc_chord_and_csda    气腔: sampleChord 抽弦 + csdaTransport 在腔内步进
%   energy_loss_table    壁: 只以 wallEscape 的射程/能量损失表进入 (不是 MC 几何体)
%   field_model_only     阳极: 半径只进 fieldModel/Diethorn 增益, 不进输运
%   not_used             其余: 解析基线完全不消费
switch lower(char(id))
    case 'gas_cavity',                    m = 'mc_chord_and_csda';
    case 'wall',                          m = 'energy_loss_table';
    case 'anode',                         m = 'field_model_only';
    otherwise,                            m = 'not_used';
end
end

function r = nominalRadius(shape)
% 零件的特征半径 [m]: 球/圆柱/圆锥用 radius_m; 盒用 half_m (半边长)。
if isfield(shape,'radius_m') && isfinite(shape.radius_m)
    r = shape.radius_m;
elseif isfield(shape,'half_m') && isfinite(shape.half_m)
    r = shape.half_m;
else
    r = NaN;
end
end


function c = charIfText(v)
c = "";
if ischar(v) || (isstring(v) && isscalar(v)), c = char(string(v)); end
end

function V = analyticVolume(shape)
% 闭式体积 (手算基准, 不由网格算得): 球 4/3 pi r^3; 圆柱 pi r^2 h;
% 盒 (2h)^3; 圆锥 1/3 pi r^2 h。
switch lower(string(shape.type))
    case "sphere",   V = 4/3*pi*shape.radius_m^3;
    case "cylinder", V = pi*shape.radius_m^2*shape.height_m;
    case "box",      V = 8*shape.half_m^3;
    case "cone",     V = 1/3*pi*shape.radius_m^2*shape.height_m;
    otherwise, error("tepc:geometry:BadShape", "未知 shape.type=%s", string(shape.type));
end
end

function A = analyticArea(shape)
% 闭式表面积: 球 4 pi r^2; 闭口圆柱 2 pi r h + 2 pi r^2; 盒 6(2h)^2;
% 闭口圆锥 侧 pi r sqrt(r^2+h^2) + 底 pi r^2。
switch lower(string(shape.type))
    case "sphere",   A = 4*pi*shape.radius_m^2;
    case "cylinder", A = 2*pi*shape.radius_m*shape.height_m + 2*pi*shape.radius_m^2;
    case "box",      A = 24*shape.half_m^2;
    case "cone"
        A = pi*shape.radius_m*sqrt(shape.radius_m^2 + shape.height_m^2) + pi*shape.radius_m^2;
    otherwise, error("tepc:geometry:BadShape", "未知 shape.type=%s", string(shape.type));
end
end

function M = buildMeshAt(shape, n)
%BUILDMESHAT 解析曲面 -> 闭合三角网格。确定性: 只用网格索引, **无任何随机数**。
%
%  为什么不用 `sphere(n)` + surf 网格:
%    sphere(n) 返回 (n+1)x(n+1) 点阵, 两个极点各重复 n+1 次、接缝列 (phi=0 与 phi=2pi)
%    整列重复。按 surf 的四边形直接拆三角 => 零面积三角形 + 非流形边 + 开边
%    (checkMesh 的 convexhull_note 里给出本机实测数字), 网格因此既不闭合也非流形。
%    本函数的 UV 网格**从源头去重**: 极点只留 1 个顶点, 经度按模取列 (不留接缝列),
%    极区用三角扇而非退化四边形 => 天然闭合、流形、朝外, 无需事后再焊接。
%
%  法向: n_f = cross(v2-v1, v3-v1)。顶点绕序按"从形外看为逆时针"排布, checkMesh 用
%  dot(n_f, centroid_f - star_centre) > 0 逐面验证 (本处零件都是凸体/星形体)。
if nargin < 2 || isempty(n), n = 96; end
n = max(4, round(double(n)));
switch lower(string(shape.type))
    case "sphere",   [V,F] = uvSphere(shape.radius_m, n);
    case "cylinder", [V,F] = closedCylinder(shape.radius_m, shape.height_m, n);
    case "box",      [V,F] = boxMesh(shape.half_m);
    case "cone",     [V,F] = closedCone(shape.radius_m, shape.height_m, ...
                        shape.apex_m, shape.base_m, n);
    otherwise, error("tepc:geometry:BadShape", "未知 shape.type=%s", string(shape.type));
end
% 整块翻转以匹配"有向体积为正 = 法向朝外"。注意: 这只统一**全局**手性; 逐面绕序是否
% 自洽 (有没有局部反 hand 的面) 仍然由 checkMesh 的 normals_consistent_outward 把关,
% 所以这里不是把门禁糊掉。
F = orientOutward(V, F);
M = struct('V',V,'F',F,'n',n,'type',lower(string(shape.type)));
end

function F = orientOutward(V, F)
a = V(F(:,1),:); b = V(F(:,2),:); c = V(F(:,3),:);
vol = sum(a(:,1).*(b(:,2).*c(:,3) - b(:,3).*c(:,2)) + ...
        a(:,2).*(b(:,3).*c(:,1) - b(:,1).*c(:,3)) + ...
        a(:,3).*(b(:,1).*c(:,2) - b(:,2).*c(:,1)))/6;
if vol < 0
    F = F(:,[1 3 2]);
end
end

function [V,F] = uvSphere(r, n)
% 顶点 = 北极 1 + 纬圈 (n-1) x 经度 n + 南极 1; 纬度 theta_i = pi*i/n (i=1..n-1,
% 不含极点), 经度 phi_j = 2pi*j/n (j=0..n-1, 接缝不重复成列)。
%
% 绕序约定 (必须全局一致, 否则 checkMesh 的 normals_consistent_outward 会红):
%   纬度索引 i 从北极向南极递增, 经度索引 j 递增 = 逆时针 (从 +z 俯视)。
%   北盖: [poleN, v(1,j),   v(1,j+1)]
%   带内: [v(i,j), v(i+1,j), v(i+1,j+1)] 与 [v(i,j), v(i+1,j+1), v(i,j+1)]
%   南盖: [poleS, v(n-1,j+1), v(n-1,j)]
% 三个式子用的是同一个 (i 递增, j 递增) 定向, 因此整块网格手性一致; 最后由
% orientOutward 按有向体积的符号统一翻转一次 (只统一全局手性, 不修复局部反 hand)。
idxPoleN = 1;
idxPoleS = 2 + (n-1)*n;
th = pi*(1:n-1)/n;                           % 内圈纬度 (不含两极), 长度 n-1
ph = 2*pi*(0:n-1)/n;                         % 经度, 长度 n (接缝不重复成列)
% 点阵按"纬度为列、经度为行"排布: 列优先展平后的线性索引 = (i-1)*n + j + 1,
% 与下面 v(i,j) 的编号一致。(旧版用 ndgrid 的列序去配行序索引 => 面片连错顶点,
%  体积掉 19%、面积翻 2 倍, 是实测抓出来的。)
PH = repmat(ph(:), 1, n-1);                  % n x (n-1): 行 = 经度 j, 列 = 纬圈 i
TH = repmat(th(:).', n, 1);
st = sin(TH);
ring = [reshape(r*st.*cos(PH), [], 1), reshape(r*st.*sin(PH), [], 1), ...
        reshape(r*cos(TH), [], 1)];
V = [[0 0 r]; ring; [0 0 -r]];
v = @(i,j) 2 + (i-1)*n + mod(j, n);          % i = 1..n-1, j = 0..n (j=n 回绕)
F = zeros(2*n*(n-1), 3);                     % 带 2*n*(n-2) + 两极盖 2*n = 2n(n-1)
k = 0;
for j = 0:n-1
    k = k+1; F(k,:) = [idxPoleN v(1,j) v(1,j+1)];           % 北极扇
    k = k+1; F(k,:) = [idxPoleS v(n-1,j+1) v(n-1,j)];       % 南极扇
end
for i = 1:n-2
    for j = 0:n-1
        a = v(i,j); b = v(i+1,j); c = v(i+1,j+1); d = v(i,j+1);
        k = k+1; F(k,:) = [a b c];
        k = k+1; F(k,:) = [a c d];
    end
end
F = F(1:k,:);
end

function [V,F] = closedCylinder(r, h, n)
% 侧面 n 个四边形 + 上下底各一个三角扇 (含圆心顶点)。星心 = 原点。
z0 = -h/2; z1 = h/2;
ph = 2*pi*(0:n-1)/n;
top = [r*cos(ph(:)), r*sin(ph(:)), z1*ones(n,1)];
bot = [r*cos(ph(:)), r*sin(ph(:)), z0*ones(n,1)];
V = [[0 0 z1]; [0 0 z0]; top; bot];
cT = 1; cB = 2;
iT = @(j) 2 + mod(j-1, n) + 1;
iB = @(j) 2 + n + mod(j-1, n) + 1;
F = zeros(4*n, 3);
k = 0;
for j = 1:n
    t1 = iT(j); t2 = iT(j+1); b1 = iB(j); b2 = iB(j+1);
    k = k+1; F(k,:) = [t1 b1 b2];                       % 侧壁 (法向朝外)
    k = k+1; F(k,:) = [t1 b2 t2];
    k = k+1; F(k,:) = [cT t1 t2];                       % 顶盖 (+z)
    k = k+1; F(k,:) = [cB b2 b1];                       % 底盖 (-z)
end
F = F(1:k,:);
end

function [V,F] = boxMesh(h)
% 盒体 8 顶点 / 12 三角形: 对平面体网格是**精确**的, 故其体积/面积相对误差恒为 0,
% 不参与收敛阶判定 (checkMesh 按 display_only 分流, 尺寸门只查被测量件)。
V = h*[1 -1  1; 1  1  1; -1 1  1; -1 -1  1; ...
       1 -1 -1; 1  1 -1; -1 1 -1; -1 -1 -1];
F = [1 2 3; 1 3 4; 6 5 8; 6 8 7; ...                    % +z, -z
     1 5 6; 1 6 2; 2 6 7; 2 7 3; ...                    % -y, +x
     3 7 8; 3 8 4; 4 8 5; 4 5 1];                       % +y, -x
end

function [V,F] = closedCone(r, hh, apex, base, n)
% 圆锥展示网格: 构造式在 tepc.geometry.coneMesh (唯一实现; exportGeometry 的期望包络
% 走同一个函数, 所以这里不再自带一份顶点算法)。
[V, F] = tepc.geometry.coneMesh(r, apex, base, n);
end

function note = srcRoleNote(dirOk, coneOk)
% 零件表里的"为什么这条只是显示"要按实际来源说: 两项都来自配置时不能再写"不在配置里"。
if dirOk && coneOk
    note = '源方向/锥角取自配置 source.* (仅显示几何; 输运角分布仍各向同性)';
elseif dirOk
    note = '源方向取自配置, 锥角缺字段兜底 15 deg (见 spec.assumed)';
elseif coneOk
    note = '锥角取自配置, 源方向缺字段兜底 [0 0 -1] (见 spec.assumed)';
else
    note = '源方向/锥角都不在配置里 (见 spec.assumed)';
end
end

function note = srcGeomNote(dirUnit, halfDeg, dirOk, coneOk)
% 零件表里给出的数值必须连带给出**这一项的实际来源**: 缺字段时用的是兜底常量, 写成
% "取自配置"就是把硬编码说成测量值。半角用 %.6g: %.0f 会把 15.4 印成 15, 与配置不等还自称取自配置。
dFrom = '兜底常量 [0 0 -1]';
if dirOk
    dFrom = '配置 source.direction';
end
hFrom = '兜底常量 15 deg';
if coneOk
    hFrom = '配置 source.coneHalfAngle_deg';
end
note = sprintf(['方向 [%+.6g %+.6g %+.6g] 来自 %s, 半角 %.6g deg 来自 %s; ' ...
    '解析基线的入射角分布仍是各向同性 (sampleChord isotropic_external)'], ...
    dirUnit(1), dirUnit(2), dirUnit(3), dFrom, halfDeg, hFrom);
end
