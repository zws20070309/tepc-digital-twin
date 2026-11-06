function issues = validate(cfg)
%CONFIGVALIDATE 配置校验, 返回问题列表 (level: "error"/"warn")。
%   红线相关: 组分和=1、正尺寸、温压域、W/Fano 非空、电子学完整、枚举值合法、
%   VALIDATED 模式下禁止 ASSUMED 参数。
issues = {};
% --- 枚举 (显式平行列表, 避免嵌套 cell 拍平陷阱) ---
eflds = {'run.mode'; 'geometry.type'; 'source.type'; 'source.arrivalModel'; ...
         'electronics.shaperType'; 'electronics.deadTimeMode'; 'geometry.electrodeTopology'; ...
         'detector.avalancheStartMode'};
evals = cell(numel(eflds),1);   % 逐个赋值, 规避大括号拼接拍平陷阱
evals{1} = ["RESEARCH_DEMO","VALIDATED"];
evals{2} = ["sphere","cylinder_endless","cylinder_finite","slab"];
evals{3} = ["mono_neutron","mono_gamma","mixed"];
evals{4} = ["poisson","fixed"];
evals{5} = ["cr_rc","double_exp","trapezoid"];
evals{6} = ["nonparalyzable","paralyzable"];
evals{7} = ["axialWire","centerSphere"];   % 与 geometry.electrode 的唯一映射同源
evals{8} = ["fixed","sampled"];            % 雪崩起点: 回归模式 / 逐事件抽样
for i = 1:numel(eflds)
    parts = strsplit(eflds{i}, '.');
    val = getSub(cfg, parts);
    if isempty(val) || ~any(strcmpi(char(string(val)), evals{i}))
        issues{end+1} = struct('level',"error", 'code',"ENUM_INVALID", ...
            'message', sprintf("%s = %s 不在允许值内", eflds{i}, char(string(val)))); %#ok<AGROW>
    end
end
% --- 增益模式: schema 允许 "fixed", 但全项目没有任何实现读 detector.gainMode ---
% (GUI "增益模式"文本框因此是个假开关: 填什么都一样跑)。与 SPACE_CHARGE_UNIMPLEMENTED
% 同一纪律 —— 未实现的选择必须显式拒绝, 不允许静默忽略。
gm = getSub(cfg, {'detector','gainMode'});
if ~isempty(gm) && ~any(strcmpi(char(string(gm)), "analytic_diethorn"))
    msgM = sprintf(['detector.gainMode=%s 没有实现: 代码里无人读该字段, 唯一实现的路径是 ' ...
        'Diethorn 解析增益。请填 analytic_diethorn。'], char(string(gm)));
    issues{end+1} = struct('level',"error", 'code',"GAIN_MODE_UNIMPLEMENTED", 'message', msgM);
end
% --- 注量: 只有源归一链声明可用时才进 k_norm, 否则确实不被任何输出消费 ---
if isfield(cfg,'source') && isfield(cfg.source,'fluence_m2') && ...
        isfinite(cfg.source.fluence_m2) && cfg.source.fluence_m2 > 0
    % 声明状态决定这句话该不该说"不影响任何输出" —— 不看状态就断言, 会对声明了
    % REFERENCE/MEASURED 的配置给出假陈述 (那时 Phi 已经在决定宏观剂量了)。
    nrmSt = "";
    if isfield(cfg.source,'normalization') && isstruct(cfg.source.normalization) && ...
            isscalar(cfg.source.normalization) && isfield(cfg.source.normalization,'status')
        nrmSt = upper(strtrim(string(cfg.source.normalization.status)));
    end
    inUse = any(nrmSt == ["REFERENCE","MEASURED"]);
    if inUse
        msgF = "source.fluence_m2 是时间积分注量: 它经 sourceNormalization 的 k_norm = Phi*A_eff*f_geo*p_int 进入 D_macro_Gy/H_macro_Sv (还直接作 R_H 的分母)。当前 source.normalization.status=" + nrmSt + " 声明该链可用, 所以这个注量值正在决定宏观剂量与辐射权重后的量。";
    else
        if nrmSt == ""
            nrmTxt = "未给 (ABSENT)";
        else
            nrmTxt = nrmSt;
        end
        msgF = "source.fluence_m2 是时间积分注量: 它经 sourceNormalization 的 k_norm = Phi*A_eff*f_geo*p_int 进入 D_macro_Gy/H_macro_Sv (还直接作 R_H 的分母)。当前 normalization 块状态 = " + nrmTxt + ", k_norm=NaN, 因此这个注量值不影响任何输出; 一旦声明 REFERENCE/MEASURED 并补齐其余因子, 它就开始决定宏观剂量。";
    end
    issues{end+1} = struct('level',"warn", 'code',"FLUENCE_CONSUMED_ONLY_VIA_NORMALIZATION", ...
        'message', msgF); %#ok<AGROW>
end
% --- 组分和 ---
if isfield(cfg,'gas') && isfield(cfg.gas,'composition_molfrac')
    comp = cfg.gas.composition_molfrac;
    s = 0; fn = fieldnames(comp);
    for i = 1:numel(fn), s = s + comp.(fn{i}); end
    if abs(s-1) > 1e-6
        issues{end+1} = struct('level',"error", 'code',"COMPOSITION", ...
            'message', sprintf("组分摩尔分数和 = %.6f (要求 1)", s)); %#ok<AGROW>
    end
end
% --- 正尺寸 ---
g = cfg.geometry;
if ~(g.gasRadius_mm > 0) || ~(g.wallThickness_mm >= 0) || ~(g.anodeRadius_um > 0)
    issues{end+1} = struct('level',"error", 'code',"SIZE", ...
        'message', "几何尺寸必须为正"); %#ok<AGROW>
end
% 阳极半径必须小于气腔半径: 旧实现只对 sphere 判, cylinder_finite 配超大阳极要
% 等到 fieldModel 抛 tepc:field:BadRadii 才暴露 (校验层就该拦)。
if isfield(g,'gasRadius_mm') && g.gasRadius_mm > 0 && g.anodeRadius_um*1e-3 >= g.gasRadius_mm
    issues{end+1} = struct('level',"error", 'code',"ANODE_TOO_BIG", ...
        'message', sprintf("阳极半径 %.3f mm >= 气腔半径 %.3f mm (所有几何均无定义)", ...
        g.anodeRadius_um*1e-3, g.gasRadius_mm)); %#ok<AGROW>
end
% --- 电极拓扑: 唯一真相源, 且必须与场模型一致 ---
el = tepc.geometry.electrode(cfg);
if ~el.valid
    % code 用去前缀的短名 (与 ENUM_INVALID 等同列表一致), 完整标识符留在 message 里
    issues{end+1} = struct('level',"error", 'code', char(erase(el.errId, "tepc:config:")), ...
        'message', sprintf('%s (标识符 %s)', char(el.reason), char(el.errId))); %#ok<AGROW>
end
% 旧字段 fieldGeometry 已删除: 它可以与阳极拓扑各说各话 (曾两字段并存时
% resolve 优先读它, 于是 centerSphere 的球壳场被静默降级成圆柱场)。
if isfield(cfg.geometry,'fieldGeometry')
    issues{end+1} = struct('level',"error", 'code',"FIELD_GEOMETRY_FIELD_REMOVED", ...
        'message', "geometry.fieldGeometry 已废除: 场类型现在只能由 " + ...
        "geometry.electrodeTopology 唯一导出 (axialWire=>cylinder, centerSphere=>sphere), " + ...
        "请删除该字段, 不要留下两个可互相矛盾的开关。"); %#ok<AGROW>
end
% --- 温压域 (模型适用域) ---
T = cfg.gas.temperature_K; p = cfg.gas.pressure_Pa;
if ~(T > 200 && T < 400)
    issues{end+1} = struct('level',"error", 'code',"TEMP_DOMAIN", ...
        'message', sprintf("温度 %.1f K 超出气体模型域 [200,400] K", T)); %#ok<AGROW>
end
if ~(p > 100 && p < 2e4)
    issues{end+1} = struct('level',"warn", 'code',"PRESSURE_DOMAIN", ...
        'message', sprintf("压强 %.0f Pa: 低能锚定拼接表未在全部低压段验证", p)); %#ok<AGROW>
end
% --- W/Fano 非空 ---
if isempty(cfg.gas.W_eV.value) || ~isfinite(cfg.gas.W_eV.value) || cfg.gas.W_eV.value <= 0
    issues{end+1} = struct('level',"error", 'code',"W_MISSING", ...
        'message', "W_eV.value 未填写(null) — strict 模式拒绝运行"); %#ok<AGROW>
end
if isempty(cfg.gas.fano.value) || ~(cfg.gas.fano.value > 0 && cfg.gas.fano.value < 1)
    issues{end+1} = struct('level',"error", 'code',"FANO_MISSING", ...
        'message', "fano.value 未填写或越域(0,1)"); %#ok<AGROW>
end
% --- 电子学完整性 ---
e = cfg.electronics;
chk = { e.Cf_F>0, 'Cf_F'; e.Rf_Ohm>0, 'Rf_Ohm'; e.shaping_s>0, 'shaping_s'; ...
        e.sampleTime_s>0, 'sampleTime_s'; e.deadTime_s>=0, 'deadTime_s' };
for i = 1:size(chk,1)
    if ~chk{i,1}
        issues{end+1} = struct('level',"error", 'code',"ELEC_PARAM", ...
            'message', sprintf("电子学参数 %s 非法", chk{i,2})); %#ok<AGROW>
    end
end
if isempty(e.trigger.threshold_V) || ~(e.trigger.threshold_V > 0)
    issues{end+1} = struct('level',"error", 'code',"THRESHOLD", ...
        'message', "触发阈值未设置或非正"); %#ok<AGROW>
end
if e.adc.bits < 8 || e.adc.bits > 24
    issues{end+1} = struct('level',"error", 'code',"ADC_BITS", ...
        'message', "adc.bits 必须在 [8,24]"); %#ok<AGROW>
end
if e.sampleTime_s > e.shaping_s/50
    issues{end+1} = struct('level',"warn", 'code',"TS_TOO_COARSE", ...
        'message', "Ts > shaping/50: 成形离散精度可能不满足门禁"); %#ok<AGROW>
end
% --- 源 ---
if ~(cfg.source.energy_MeV > 0)
    issues{end+1} = struct('level',"error", 'code',"SOURCE_E", ...
        'message', "源能量必须为正"); %#ok<AGROW>
end
if strcmp(cfg.source.type,"mixed") && (~isfield(cfg.source,'classPrior') || isempty(cfg.source.classPrior))
    issues{end+1} = struct('level',"error", 'code',"PRIOR", ...
        'message', "mixed 源需要 classPrior"); %#ok<AGROW>
end
% --- 源方向与锥束半角 ---
% 这两个字段现在真的被 meshSpec 消费 (三维源锥的轴向、底半径都由它们算), 所以坏值必须在
% 配置层就拒掉, 而不是让 tan()/norm() 在几何层给出 NaN 或零尺寸锥体。
% 归一在这里**不做** —— 消费点自己归一并因此能报告原始向量; 校验只判"能不能归一"。
if isfield(cfg.source, 'direction') && ~isempty(cfg.source.direction)
    dirV = cfg.source.direction;
    % 类型判定必须在 double() 之前: double('abc') = [97 98 99] 会通过"3 个有限数", double(true)
    % = 1 会伪装成一个方向分量 —— 那时校验层放行、几何层照抄, 坏配置就成了"配置来源的几何值"。
    if ~isnumeric(dirV) || islogical(dirV)
        issues{end+1} = struct('level',"error", 'code',"SOURCE_DIR", ...
            'message', sprintf("source.direction 必须是数值三元组, 实得 %s 类型", class(dirV))); %#ok<AGROW>
    else
        dv = double(dirV);
        if ~(numel(dv) == 3 && all(isfinite(dv(:))))
            issues{end+1} = struct('level',"error", 'code',"SOURCE_DIR", ...
                'message', sprintf("source.direction 必须是 3 个有限数, 实得 %s", mat2str(dv))); %#ok<AGROW>
        elseif norm(dv(:)) <= 0
            issues{end+1} = struct('level',"error", 'code',"SOURCE_DIR", ...
                'message', "source.direction 是零向量: 无法定义入射方向 (零向量归一会得 NaN)"); %#ok<AGROW>
        end
    end
    % 方向今天只被 meshSpec 的三维源锥**显示**消费, 输运侧拿不到它。理由不是"忘了接线",
    % 而是模型本身没有可依赖的方向性: 敏感体积是球、壁厚是标量、雪崩起点 r0 是常数,
    % 于是 csdaTransport 能看到的只有 |P0| 与 dot(P0,dirv), 任何可观测量对束方向旋转都不变。
    % 不把这条说出来, 改这个字段就会被当成"换了一种辐照几何"来解读。
    issues{end+1} = struct('level',"warn", 'code',"SOURCE_DIR_NOT_CONSUMED_BY_TRANSPORT", ...
        'message', "source.direction 只影响三维显示 (源锥), 不改变输运量: 敏感体积为球、" ...
        + "壁厚为标量、雪崩起点 r0 为常数, 故 y_F/y_D/谱对入射方向旋转不变"); %#ok<AGROW>
end
if isfield(cfg.source, 'coneHalfAngle_deg') && ~isempty(cfg.source.coneHalfAngle_deg)
    haV = cfg.source.coneHalfAngle_deg;
    if ~isnumeric(haV) || islogical(haV)
        issues{end+1} = struct('level',"error", 'code',"SOURCE_CONE", ...
            'message', sprintf("source.coneHalfAngle_deg 必须是数值标量, 实得 %s 类型", class(haV))); %#ok<AGROW>
    else
        ha = double(haV);
        % 下界开区间: 半角 0 会让底半径 = h*tan(0) = 0, 锥退化成一条线段 —— 环上全部顶点重合,
        % checkMesh 会数出 n-1 个重复顶点与 2n 个零面积面, 整次运行被降级成 3D_NOT_AUDITED。
        % 上界 90 度: 到 90 度底半径发散 (tan->inf), 超过就没有有限的锥底可言。
        if ~(isscalar(ha) && isfinite(ha) && ha > 0 && ha < 90)
            issues{end+1} = struct('level',"error", 'code',"SOURCE_CONE", ...
                'message', sprintf("source.coneHalfAngle_deg 须落在 (0, 90) 度内, 实得 %s", mat2str(ha))); %#ok<AGROW>
        end
    end
end
% --- 伽马/混合源: 可测事件数预估 (实测 1000 Pa 气体对 662 keV 光子 pInt~4e-6,
%     200 事件必然零作用, 过去只抛一个不透明的 NoWeight)
if isfield(cfg.source,'type') && any(strcmpi(char(string(cfg.source.type)), ...
        ["mono_gamma","mixed"]))
    if isfield(cfg.source,'gamma_massatt_cm2_g')
        gm = cfg.source.gamma_massatt_cm2_g;
        % 0.08 cm^2/g = 0.08 * 1e-4 m^2 / 1e-3 kg = 8e-3 m^2/kg  (因子 0.1)
        mu = (gm.value - 0) * 0.1;                                  % m^2/kg
        Lch = 2*cfg.geometry.gasRadius_mm*1e-3;
        try
            [rho,~] = tepc.geometry.gasDensity(cfg.gas.pressure_Pa, ...
                cfg.gas.temperature_K, cfg.gas.composition_molfrac, ...
                cfg.gas.compressibility_Z);
            % 输运链现在按"入射壁 -> 气腔 -> 出射壁"整条线路抽样作用点, 所以这条预估也必须
            % 算上壁: 只算气体的话它对发货工况报 ~4e-6 并拒绝配置, 而真实响应由壁主导
            % (同一张 μ/ρ 下壁比气容易作用约 9.4e3 倍)。两侧壁厚按直径弦取 2t (保守近似:
            % 斜射的壁程更长, 所以这是下界)。
            rhoW = double(tepc.config.constants('transport.a150.density_g_cm3')) * 1000;  % kg/m^3
            tauGas = mu*rho*Lch;
            tauWall = mu*rhoW*2*cfg.geometry.wallThickness_mm*1e-3;
            pInt = 1 - exp(-(tauGas + tauWall));
            nExp = cfg.run.nEvents*pInt;
            if nExp < 100
                gmsg = sprintf(['该温压下光子作用概率 %.2e (气体 %.2e + 壁 %.2e), ' ...
                    '%d 事件预期仅 %.1f 次作用 (需 >=100 才能成型谱)。' ...
                    '请增大 run.nEvents 或提高气压。'], ...
                    pInt, 1 - exp(-tauGas), 1 - exp(-tauWall), ...
                    cfg.run.nEvents, nExp);
                issues{end+1} = struct('level',"error", 'code',"GAMMA_TOO_FEW_INTERACTIONS", ...
                    'message', gmsg); %#ok<AGROW>
            end
        catch e
            issues{end+1} = struct('level',"warn", 'code',"GAMMA_GUARD_INCOMPLETE", ...
                'message', sprintf('伽马作用概率预估失败, 未能核查: %s', e.message)); %#ok<AGROW>
        end
    end
end
% --- 空间电荷增益压制: 需要逐事件电荷闭环, 本实现未接入 -> 禁止静默忽略
if isfield(cfg,'detector') && isfield(cfg.detector,'spaceCharge') && ...
        isfield(cfg.detector.spaceCharge,'enabled') && cfg.detector.spaceCharge.enabled
    issues{end+1} = struct('level',"error", 'code',"SPACE_CHARGE_UNIMPLEMENTED", ...
        'message', "detector.spaceCharge.enabled=true 但增益-电荷闭环未实现; 旧实现静默把 Q_ion_C 置 0 (假装生效)。请保持 false 或补实现。"); %#ok<AGROW>
end
% --- 事件波形开关: 判据字段要在这里就核掉, 不要等到 run 尾 ----------------
% waveformStage 在事件循环与全部产物都写完之后才读 waveform.enabled / waveform.nSub,
% 非法值会晚到一个 run 的最后一步才炸。这里一律要求"存在即合法":
%   * JSON 的 null 经 jsondecode 是 0x0 double, 而 `if ~([])` 在 MATLAB 里走假分支
%     (本机实测), 于是空值不会关掉开关反而进入写盘路径 —— 因此空值必须判错;
%   * 字符串实参与数值比较是逐元素比较, 结果不是标量逻辑值 (实测 'true'==1 得 1x4),
%     所以类型判定必须排在数值比较之前。
if isfield(cfg,'waveform')
    if ~isstruct(cfg.waveform)
        issues{end+1} = struct('level',"error", 'code',"WAVEFORM_BAD_BLOCK", ...
            'message', sprintf('waveform 必须是 struct, 实得 %s', class(cfg.waveform))); %#ok<AGROW>
    else
        wf = cfg.waveform;
        if isfield(wf,'enabled')
            en = wf.enabled;
            okE = (islogical(en) || (isnumeric(en) && isreal(en))) && isscalar(en);
            if okE, okE = (double(en) == 0) || (double(en) == 1); end
            if ~okE
                issues{end+1} = struct('level',"error", 'code',"WAVEFORM_BAD_ENABLED", ...
                    'message', sprintf(['waveform.enabled 必须是 0/1 的实数或逻辑标量 ' ...
                    '(JSON 里写 true/false); 空值 (null)、字符串与数组一律拒绝, 实得 %s %s'], ...
                    class(en), mat2str(size(en)))); %#ok<AGROW>
            end
        end
        if isfield(wf,'nSub')
            ns = wf.nSub;
            okS = isnumeric(ns) && isreal(ns) && isscalar(ns) && isfinite(ns) && ns >= 1;
            if okS, okS = abs(ns - round(ns)) < 1e-9; end   % 会被 round, 非整数说明意图不明
            if ~okS
                issues{end+1} = struct('level',"error", 'code',"WAVEFORM_BAD_NSUB", ...
                    'message', sprintf('waveform.nSub 必须是 >=1 的整数值实数标量 (不接受空值), 实得 %s %s', ...
                    class(ns), mat2str(size(ns)))); %#ok<AGROW>
            end
        end
        % 键名白名单: 拼成 waveform.enable 时上面两条都不触发, 而 waveformStage 把
        % "没有 enabled 字段"按关闭处理 —— 开关被静默吃掉, 正是本守卫要防的事。
        % 散文键放行: JSON 里写 _note, 但 jsondecode 会把以下划线开头的键改名成 x_note
        % (MATLAB 字段名必须以字母开头), 所以两种前缀都要认。
        keys = string(fieldnames(wf))';
        prose = startsWith(keys, "_") | startsWith(keys, "x_");
        known = ["enabled", "nSub"];
        badKeys = setdiff(keys(~prose), known, 'stable');
        if ~isempty(badKeys)
            issues{end+1} = struct('level',"error", 'code',"WAVEFORM_UNKNOWN_FIELD", ...
                'message', sprintf(['waveform 块里有未知字段 %s (可参与计算的只有 %s); ' ...
                '拼错的开关名会被当成"没有这个开关"从而静默关闭, 所以直接拒绝'], ...
                strjoin(badKeys, ', '), strjoin(known, ', '))); %#ok<AGROW>
        end
    end
end
% --- run 节键名白名单 + 不确定度传播深度档 ---
% 白名单这条与 waveform 块同一族: 拼错的档位名会被读成"没有这个档位"从而静默回到
% 默认档, 开关看着生效其实没生效, 所以直接拒绝而不是警告。
if isfield(cfg, 'run')
    rk = string(fieldnames(cfg.run))';
    rprose = startsWith(rk, "_") | startsWith(rk, "x_");
    rknown = ["nEvents", "chunkSize", "mode", "uncertaintyDepth"];
    rbad = setdiff(rk(~rprose), rknown, 'stable');
    if ~isempty(rbad)
        issues{end+1} = struct('level',"error", 'code',"RUN_UNKNOWN_FIELD", ...
            'message', sprintf(['run 块里有未知字段 %s (可参与计算的只有 %s); ' ...
            '拼错的档位名会被当成"没有这个档位"从而静默回到默认档'], ...
            strjoin(rbad, ', '), strjoin(rknown, ', '))); %#ok<AGROW>
    end
    % 档位覆盖判据只有一份: tepc.config.depthConflicts (applyDepthTier 用的就是它)。
    % 键没写的配置同样要扫 —— 缺省补的是 standard 档, 它照样覆写 uq 的这两条旋钮。此前整段
    % 扫描挂在"键存在"上, 于是没写档名的旧配置里 uq.nSamples=64 被保住却一声不响, 而
    % 两边的参照规则也不等价 (这里连"等于档位值"也放过, applyDepthTier 只比发货值)。
    [eTier, ~, decTier] = tepc.config.depthConflicts(cfg);
    if isempty(eTier)
        TD = tepc.config.uncertaintyDepthTiers();
        badName = '';
        if isfield(cfg, 'run') && ~isempty(cfg.run) && isfield(cfg.run, 'uncertaintyDepth')
            badName = char(string(cfg.run.uncertaintyDepth));
        end
        issues{end+1} = struct('level',"error", 'code',"DEPTH_UNKNOWN", ...
            'message', sprintf(['run.uncertaintyDepth=%s 定不到档位表里的任何一档 ' ...
            '(可用: %s; 表里若连 standard 都没有, 默认档也无从谈起)'], ...
            badName, strjoin(cellstr(TD.ids), ', '))); %#ok<AGROW>
    else
        for j = 1:numel(decTier)
            if ~strcmp(decTier(j).from, 'preset_conflict')
                continue;
            end
            issues{end+1} = struct('level',"warn", 'code',"DEPTH_KNOB_OVERRIDDEN", ...
                'message', sprintf(['档位 %s 管着 %s(= %s), 但配置里显式给了 %s: ' ...
                '显式值优先, 档位这一条不生效, 所以这份产物不是干净的 %s 档'], eTier.id, ...
                decTier(j).path, mat2str(decTier(j).tier_val), ...
                depthValText(decTier(j).cfg_val), eTier.id)); %#ok<AGROW>
        end
    end
end
% --- 运行级必填数值 (过去拼错的高压/seed/事件数会一路跑到 parfeval 才炸)
numreq = {'run.nEvents','run.chunkSize','provenance.seed','field.hv_V', ...
    'site.targetDiameter_um','source.rate_cps','source.energy_MeV', ...
    'electronics.adc.fullScale_V','electronics.adc.bits', ...
    'electronics.adc.range2Gain', ...
    'detector.startPositionJitter', ...
    'electronics.trigger.threshold_V','electronics.trigger.hysteresis_V'};
for i = 1:numel(numreq)
    v = getSub(cfg, strsplit(numreq{i}, '.'));
    okN = ~isempty(v) && isnumeric(v) && isscalar(v) && isfinite(v);
    % 注意: 必须用 string 数组比较。strcmp(char, cell) 在各元素长度不同时
    % **不广播**而返回标量 0, 会让这些域检查静默失效 (实测 nEvents=-5 通过)。
    nmS = string(numreq{i});
    if okN && nmS == "provenance.seed"
        okN = v >= 0;
    end
    if okN && nmS == "detector.startPositionJitter"
        % 相对对数标准差: 0 = 关闭 (fixed 等价), >=1 会把抽样推到电极外, 无物理意义
        okN = v >= 0 && v < 1;
    end
    if okN && any(nmS == ["run.nEvents", "run.chunkSize"])
        okN = v >= 1 && abs(v - round(v)) < eps;
    end
    if okN && any(nmS == ["electronics.adc.bits", "site.targetDiameter_um", ...
                          "source.rate_cps", "source.energy_MeV", ...
                          "electronics.adc.fullScale_V", "field.hv_V", ...
                          "electronics.adc.range2Gain"])
        % hv_V 必须为正: 0 或负高压下 fieldModel 仍"合法"返回, 但载流子漂移方向
        % 反转/停止, ramoWaveform 的 dq 被 max(dq,0) 归零 -> 整条仪器链静默输出全零。
        okN = v > 0;
    end
    if okN && nmS == "electronics.adc.bits"
        okN = v >= 8 && v <= 24;
    end
    if okN && nmS == "electronics.adc.range2Gain"
        % extCode = code*(1+(r-1)*(g2-1)): g2<1 会让量程2 的等效码**低于**同幅值的
        % 量程1 码 => 跨量程非单调, 刻度直线拟合失效 (GUI 的 el_g2 框可填 0/负数)。
        okN = v >= 1;
    end
    if ~okN
        issues{end+1} = struct('level',"error", 'code',"NUM_REQUIRED", ...
            'message', sprintf("%s 必须是有限数值且落在合法域内, 实得 %s", ...
            numreq{i}, mat2str(v))); %#ok<AGROW>
    end
end
% --- 场几何/高压/增益自洽 (球壳场在丝状阳极半径下增益会暴涨) ---
% 原实现两个洞: (1) 整段包在裸 catch 里, 任何构造错误都变成"门禁通过";
% (2) 只在 fieldGeometry=sphere 且 a<100um 时评估, cylinder 场加高压同样能超出量程。
% 现在: 按**配置的**场几何求 G_mean, 评估不了就发 WARN (不再静默), 超上界发 ERROR。
% 场类型只能来自电极拓扑: 不能再读被废除的 fieldGeometry, 否则一个已从输入中
% 删除的字段仍然驱动增益门禁 —— 静默失效。
Gs = NaN;
if ~el.valid
    issues{end+1} = struct('level',"warn", 'code',"FIELD_GAIN_GATE_NOT_EVALUATED", ...
        'message', "电极拓扑无定义, 增益-量程自洽门禁无法评估 (拓扑修好后必须能评估)"); %#ok<AGROW>
else
    try
        fmc = tepc.detector.fieldModel(cfg.geometry.anodeRadius_um*1e-6, ...
            cfg.geometry.gasRadius_mm*1e-3, cfg.field.hv_V, el.fieldKind);
        dV = cfg.detector.diethorn_deltaV_V.value;
        % 雪崩起点半径倍率必须与 resolve/avalanche 用**同一个**注册表常数: 这里曾
        % 硬编码 10*fmc.a, 于是"改 docs/constants.json 即改行为"的承诺在增益门禁上
        % 是假的 (门禁按另一套 r0 评估 G_mean)。
        fR0 = tepc.config.constants('detector.avalanche.rStartFactor');
        cUp = tepc.config.constants('detector.avalanche.rStartClampUpperFracOfB');
        cLo = tepc.config.constants('detector.avalanche.rStartClampLowerFracOfA');
        Gs = exp(fmc.gainExponent(min(max(fR0*fmc.a, fmc.a*cLo), fmc.b*cUp), dV));
    catch e
        issues{end+1} = struct('level',"warn", 'code',"FIELD_GAIN_GATE_NOT_EVALUATED", ...
            'message', sprintf('增益-量程自洽门禁无法评估 (旧实现会静默跳过): %s', e.message));
    end
end
gainMax = tepc.config.constants('detector.gain.proportionalRegionUpperBound');
if isfinite(Gs) && Gs > gainMax
    % 上界 1e4 = 正比计数区经验上界 (ASSUMED, 无参考场数据佐证); 超过则必淹没
    % 前放/ADC 量程 (发货配置设计点 G=136, range2Gain=32)。
    % 旧文案只说"降低 hv_V"却不给可行动数值, 这里给解析反解上限。
    hvMax = cfg.field.hv_V * log(gainMax)/max(log(Gs), eps);
    msgG = sprintf(['electrodeTopology=%s (场=%s), a=%.1f um, HV=%.0f V 时 G_mean=%.3e, ' ...
        '超出正比计数区上界 (ASSUMED %.0f) 并淹没前放/ADC 量程。可行动修复: ' ...
        '把 field.hv_V 降到 <= %.0f V, 或改 geometry.electrodeTopology (中心球壳场在这个' ...
        '半径比下增益远大于柱对称场)。'], ...
        char(el.topology), char(el.fieldKind), cfg.geometry.anodeRadius_um, ...
        cfg.field.hv_V, Gs, gainMax, hvMax);
    issues{end+1} = struct('level',"error", 'code',"FIELD_GAIN_RANGE_MISMATCH", 'message', msgG); %#ok<AGROW>
end
% --- 几何类型必须能给出 (lbar, 阳极半径) 且被输运层支持 ---
% 曾: cylinder_endless 的 lbar=NaN 让 siteConsistency 抛 tepc:geometry:NoLbar,
% slab 的 anode.radius_m=NaN 让 fieldModel 抛 tepc:field:BadRadii; 两者都在 GUI
% 校验页的 catch-all 里变成一句没信息量的"校验异常", 而这类配置根本跑不起来。
gt = string(cfg.geometry.type);
if any(gt == ["cylinder_endless", "slab"])
    why = "slab 无中心阳极半径 (anode.radius_m=NaN), 场模型与 E(r) 无法定义";
    if gt == "cylinder_endless"
        why = "4V/S 发散 => lbar_gas=NaN, 位点质量厚度映射无定义";
    end
    msgG = sprintf('geometry.type=%s 在解析基线里不可用: %s。请改用 sphere 或 cylinder_finite。', ...
        char(gt), why);
    issues{end+1} = struct('level',"error", 'code',"GEOM_TYPE_UNSUPPORTED", 'message', msgG); %#ok<AGROW>
elseif gt ~= "sphere"
    % AnalyticAdapter 的体均匀作用点抽样只实现 sphere (tepc:transport:Geom)。
    issues{end+1} = struct('level',"warn", 'code',"TRANSPORT_GEOM_SPHERE_ONLY", ...
        'message', sprintf(['geometry.type=%s 能通过几何/场校验, 但解析输运的作用点抽样' ...
        '只实现 sphere, 运行时会以 tepc:transport:Geom 拒绝。'], char(gt))); %#ok<AGROW>
end
% --- 有限圆柱/平板必须给长度 (buildGeometry 运行时才报错, 校验层就该拦)
if any(string(cfg.geometry.type) == ["cylinder_finite", "slab"])
    if ~isfield(cfg.geometry,'cylinderLength_mm') || isempty(cfg.geometry.cylinderLength_mm) ...
            || ~(cfg.geometry.cylinderLength_mm > 0)
        issues{end+1} = struct('level',"error", 'code',"GEOM_LENGTH_MISSING", ...
            'message', sprintf("geometry.type=%s 需要正的 geometry.cylinderLength_mm", ...
            char(string(cfg.geometry.type)))); %#ok<AGROW>
    end
end
% --- 填了却不生效的开关 (两条, 判据都是实测 grep 而不是推测) ---
% 本节的纪律与 GAIN_MODE_UNIMPLEMENTED 相同: 一个字段若能被写进配置却进不了任何计算,
% 就必须自己开口说, 否则读者会把自己"换了一个数据源/换了一种成形器"记进实验记录,
% 而实际发布量逐位未变。
% ① qualityFactor.file 只在 qualityFactor.m 的 case "table" 分支被 fopen; 发货 version 是
%    icrp60_let_on_y, 走代码里的 ICRP 60 分段闭式, 那张 CSV 一次都没被读过。
%    注意近似标志 QF_APPROX_Y_AS_LET 也是代码给的 (meta.approx), 配置里的同名字段同样无人读:
%    让配置能改写这个标签就等于允许把"y 当 LET 用"的近似标成非近似, 所以不接是有意为之。
qcv = lower(strtrim(string(getSub(cfg, {'analysis','qualityFactor','version'}))));
qcfRaw = getSub(cfg, {'analysis','qualityFactor','file'});
qcf = "";
if (ischar(qcfRaw) || isstring(qcfRaw))
    qcf = strtrim(string(qcfRaw));
end
if qcv ~= "table" && qcf ~= ""
    issues{end+1} = struct('level',"warn", 'code',"QUALITY_FACTOR_FILE_IGNORED", ...
        'message', sprintf(['analysis.qualityFactor.file=%s 没有被读取: 表文件只在 version="table" ' ...
        '时被打开 (tepc.analysis.qualityFactor 的 case "table" 分支)。当前 version=%s, %s, ' ...
        '改这张 CSV 不会改变 Qbar 或任何发布量; 要让表生效必须把 version 一并改成 table ' ...
        '(改完后文件缺失抛 tepc:qf:MissingFile, 文件在但凑不出两行数值抛 tepc:qf:BadTable, ' ...
        '缺 file 字段则取参就报错 —— 三条都不会静默退回闭式)。'], ...
        char(qcf), char(qcv), qDesc(qcv))); %#ok<AGROW>
end
% ② shaperType 过了枚举校验, 但唯一读它的 tepc.electronics.shaper 在全仓 (src/app/tools/
%    tests/workflows) 零调用。真实成形是 tepc.electronics.filters 的一阶节级联, 系数来自
%    ctx.coeffs (与 Simulink 同一套), 所以这个枚举对波形的影响是零。
if ~isempty(getSub(cfg, {'electronics','shaperType'}))
    issues{end+1} = struct('level',"warn", 'code',"SHAPER_TYPE_NOT_CONSUMED", ...
        'message', sprintf(['electronics.shaperType=%s 不参与任何计算: 唯一读该字段的 ' ...
        'tepc.electronics.shaper 零调用 (含测试), 运行链的成形由 tepc.electronics.filters 的' ...
        '一阶节级联完成 (系数取 ctx.coeffs, 与 Simulink 同源)。改这个枚举不会改变峰高、' ...
        '触发时刻、ADC 码或死时间; 它目前只是被枚举校验的占位开关。'], ...
        char(strtrim(string(getSub(cfg, {'electronics','shaperType'})))))); %#ok<AGROW>
end
% ③ trigger.preTrigSamples 全仓零消费者 (grep 过 src/app/tests): 波形链从 t=0 起就是
%    成形后的信号, 没有任何"无信号前置段"。后果不是"少了一个装饰参数"而是可测性损失:
%    真实 DAQ 用前置段估 pedestal/噪声地板, 本链只能改用峰后拖尾段 (见 writeWaveformsH5
%    的 baseline_rule 属性), 而发货波形有 round(waveWindow_s/Ts)+1 = 1201 个采样点 (ramoWaveform 取 round(tEnd/Ts)+1), 小于收集窗 Nwin=1400, 拖尾
%    段也不存在 —— 所以噪声地板在发货配置下量不出来。
if ~isempty(getSub(cfg, {'electronics','trigger','preTrigSamples'}))
    issues{end+1} = struct('level',"warn", 'code',"PRETRIGGER_NOT_IMPLEMENTED", ...
        'message', sprintf(['electronics.trigger.preTrigSamples=%s 没有被任何代码读取: 波形从 ' ...
        't=0 起就是成形后的信号, 不存在无信号前置段, 因而无法按真实 DAQ 的做法在触发前估 pedestal/噪声地板。' ...
        'tepc.io.writeWaveformsH5 的 baseline_rule 属性改按峰后拖尾段给出口径, 并在 ' ...
        'baseline_n_tail_short 里数出该段不足的事件数。要真正闭上这条, 需要把波形窗延长并在 ' ...
        'simulate 里接上前置段估计 —— 两者都会改变发布量, 不在配置层能做主。'], ...
        mat2str(getSub(cfg, {'electronics','trigger','preTrigSamples'})))); %#ok<AGROW>
end
% --- VALIDATED 模式与 ASSUMED ---
if strcmp(cfg.run.mode,"VALIDATED")
    st = tepc.config.statusScan(cfg);
    if any(strcmp(st.status, 'ASSUMED'))
        issues{end+1} = struct('level',"error", 'code',"ASSUMED_IN_VALIDATED", ...
            'message', "VALIDATED 模式存在 ASSUMED 参数 — 红线禁止"); %#ok<AGROW>
    end
end
% --- 场来源开关 field.mode (词表与 tepc.detector.fieldModeOf 同一套) ---
% field.kind 只表达电极拓扑 (cylinder|sphere), field.mode 只表达"场从哪里来"
% (解析闭式 | 有限元场图), 两个开关不得互相顶替。值域外的模式必须显式拒绝:
% 历史上 schema 里写着 "map" 却没有任何代码读 field.mode, 于是那个开关填什么
% 都一样跑, 是个假开关。
fmS = getSub(cfg, {'field','mode'});
fmode = "analytic";
if ~isempty(fmS) && (ischar(fmS) || isstring(fmS))
    fmode = lower(strtrim(string(fmS)));
end
if ~any(fmode == ["analytic", "fem_map"])
    issues{end+1} = struct('level',"error", 'code',"FIELD_MODE_UNSUPPORTED", ...
        'message', sprintf(['field.mode=%s 不在值域 {analytic, fem_map} 内。' ...
        'fem_map 需要 tepc.detector.solveElectrostatic 产出的场图 (field.mapFile)。'], ...
        char(string(fmS)))); %#ok<AGROW>
elseif fmode == "fem_map"
    mp = getSub(cfg, {'field','mapFile'});
    okM = false; mpath = '';
    if ~isempty(mp) && (ischar(mp) || isstring(mp))
        mpath = char(string(mp));
        okM = isfile(mpath) || isfile(fullfile(tepc.io.projectRoot(), mpath));
    end
    if ~okM
        issues{end+1} = struct('level',"error", 'code',"FIELD_MAP_MISSING", ...
            'message', sprintf(['field.mode=fem_map 但没有可读的场图: field.mapFile=%s ' ...
            '(仓库根下也没找到)。运行链会在 tepc.detector.fieldOf 处直接抛 ' ...
            'tepc:field:MapMissing/MapFileMissing, 不会静默退回解析场。'], ...
            char(string(mpath)))); %#ok<AGROW>
    end
    % 上面的增益-量程自洽门禁是按解析场算 G_mean 的 (它必须先于场图存在),
    % 两条链不同源就要说出来, 否则"门禁通过"会被读成"场图也通过了门禁"。
    issues{end+1} = struct('level',"warn", 'code',"FIELD_MAP_GAIN_GATE_ANALYTIC", ...
        'message', "增益-量程自洽门禁 (FIELD_GAIN_RANGE_MISMATCH) 按解析场 fieldModel 评估, 与 fem_map 场图不是同一个场; 用场图跑发布前必须单独核对该几何下的 G_mean。"); %#ok<AGROW>
end
end

function d = qDesc(qcv)
%QDESC 当前 version 下 Q(y) 到底是什么 —— 这句必须按分支给, 否则 WARN 自己会说假话:
%   version="none" 时 qualityFactor 交回的是 Q=NaN (Qbar=NA), 不是 ICRP 60 闭式。
if qcv == "none"
    d = 'Q(y) 恒为 NaN (未配置 Q, Qbar 输出 NA)';
else
    d = sprintf('Q(y) 取代码内 %s 的分段闭式', char(qcv));
end
end

function s = depthValText(v)
% 把配置里的显式值原样写成消息文本。mat2str 对 string / 非标量形态会抛错, 而这段代码在
% 诊断生成的路上 —— "报覆盖"这件事本身不许把 validate 炸掉, 所以兜一层退回 string 文本。
try
    s = mat2str(v);
catch
    s = char(string(v));
end
end

function v = getSub(s, parts)
v = [];
try
    v = s.(parts{1});
    for i = 2:numel(parts)
        v = v.(parts{i});
    end
catch
    v = [];
end
end
