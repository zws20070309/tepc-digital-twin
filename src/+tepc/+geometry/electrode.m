function e = electrode(cfg)
%ELECTRODE 电极拓扑的唯一真相源: geometry.electrodeTopology -> 阳极形状 + 场类型。
%   axialWire    : 轴向丝状阳极   -> 场 = 同轴圆柱 (p=2, K=1/ln(b/a))
%   centerSphere : 中心球阳极     -> 场 = 同心球壳 (p=3, K=1/(1/a-1/b))
%   返回 e = struct(topology, fieldKind, anodeType, sensitiveVolume, valid, errId, reason)。
%   **本函数不抛错**: validate 需要"收集问题而不中断", 抛错由 resolve/meshSpec 负责
%   (用 e.errId/e.reason)。判定只在这里一份。
%
%   为什么只允许一处判定: 曾出现 resolve / validate / buildGeometry 各写一份拓扑->场
%   映射, 其中 resolve.m 的 centerSphere 分支是**空操作** (两支都返回 'cylinder'),
%   于是"中心球阳极 + 圆柱场"一路通过校验并静默给出错误的 E(r)、Diethorn 增益与
%   Ramo 权重。同一几何下两种场的 G 相差约 1182 倍
%   (700 V、a=50um、b=25.4mm: 柱 136.013 vs 球 1.6073e5 —— 已实测)。
%
%   两层语义不要混淆:
%     geometry.type      = 微剂量学**敏感体积** (弦长/体积/轨迹几何, Cauchy 4V/S);
%     electrodeTopology  = **电极场结构** (E(r)、权重场、雪崩区)。
%   两者可以不同 (球腔 + 丝状阳极 = 乘法区取柱对称理想化), 但必须在图例/报告中同时
%   标注; 反向 centerSphere 只能与球形敏感体积共存 (同心球壳场要求球对称边界)。
%
%   模型适用范围声明 (不是"已验证的真实器件"): 丝状阳极柱对称理想化只在乘法区
%   (r ≲ 10a) 内成立; b/a=508 时端帽/支撑引起的远端场畸变不进入增益积分, 但会进入
%   离子收集项。未找到可引用来源支持"球腔+轴向丝"这一具体构型, 因此它是**标注为
%   ASSUMED 的模型选择**, 不宣称对应任何型号仪器的图纸。
gt = char(string(getF(cfg, {'geometry','type'})));
topo = lower(char(string(getF(cfg, {'geometry','electrodeTopology'}))));

e = struct('topology', topo, 'fieldKind', '', 'anodeType', '', ...
    'sensitiveVolume', gt, 'valid', false, 'errId', "tepc:config:BadTopology", ...
    'reason', sprintf("geometry.electrodeTopology 只允许 axialWire|centerSphere, 实得 '%s'", topo));
if isempty(topo)
    e.errId = "tepc:config:TopologyMissing";
    e.reason = sprintf(['geometry.electrodeTopology 必填: 它同时决定阳极形状与场类型 ' ...
        '(丝状->柱对称场, 中心球->球壳场)。不填即拒绝, 不再猜默认值。']);
    return
end
if any(strcmp(gt, {'cylinder_endless','slab'}))
    e.errId = "tepc:config:TopologyUnsupported";
    e.reason = sprintf(['geometry.type=%s 没有可用的电极拓扑 (无限圆柱无阴极端盖, ' ...
        '平板无中心阳极半径), 解析基线在校验层就拒绝该几何。'], gt);
    return
end
switch topo
    case 'axialwire'
        e = okAssign(e, 'cylinder', 'axialWire');
    case 'centersphere'
        if ~strcmp(gt, 'sphere')
            e.errId = "tepc:config:TopologyMismatch";
            e.reason = sprintf(['electrodeTopology=centerSphere 只与 geometry.type=sphere ' ...
                '组合有定义 (同心球壳场需要球对称边界); 实得 type=%s。'], gt);
            return
        end
        e = okAssign(e, 'sphere', 'centerSphere');
    otherwise
        return          % 保持上面的 BadTopology
end
end

function e = okAssign(e, kind, atype)
e.fieldKind = kind; e.anodeType = atype; e.valid = true;
e.errId = ""; e.reason = "";
end

function v = getF(s, parts)
v = [];
for i = 1:numel(parts)
    if ~isfield(s, parts{i}), return; end
    s = s.(parts{i});
end
v = s;
end
