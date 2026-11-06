function P0 = birthPoint(geom, cfg, Pin, Pout, rs)
%BIRTHPOINT 反冲核诞生点。中子腿的弦由 sampleChord 的 internal_isotropic
%   给出: Pin 是**体积均匀**的体内点, Pout 是它沿各向同性方向到边界的出射点, 弦过该点。
%   mode = cfg.transport.birthPoint, 缺省 "chord"。
%     "chord"  : P0 = Pin。作用点与入射路径由构造相关 (旧实现另在球内重抽一点, 两者无关),
%                而边缘分布仍是体积均匀 —— 均匀注量下"发生了作用"的点必须体积均匀。
%                不得写成 P0 = Pin + u*(Pout-Pin): 那等于对半弦再取均匀, 把边缘推向腔壁
%                (实测 P(r>0.9R)=0.379 vs 体积均匀 0.271, 2e6 样本 python 复算)。
%     "volume" : 旧行为 (与入射路径无关的体均匀重抽), 只留给对照与负控。
%   随机数消耗: chord 0 次 rand, volume 3 次 —— 换缺省会移动发布值 (需重基线), 这是事实。
mode = "chord";
if isfield(cfg, 'transport') && isfield(cfg.transport, 'birthPoint') ...
        && ~isempty(cfg.transport.birthPoint)
    mode = lower(string(cfg.transport.birthPoint));
end
% 解析输运链只对球腔闭合: 弦抽样后的 CSDA 腿 (csdaTransport.m 直接取 geom.R_m 当球半径)、
% 壁壳层、4V/S 位点映射都是球方程。旧代码这条守卫住在 sampleInVolume 里, 每个中子事件都会
% 撞到它; 诞生点默认改走弦之后那条腿不再被调用 ⇒ 守卫必须搬到这里, 否则 config/validate.m
% 的 TRANSPORT_GEOM_SPHERE_ONLY 警告 (以及 GUI 上同一句话) 就成了假承诺 —— 非球腔会静默
% 按内切球出数。identifier 沿用 tepc:transport:Geom, 让"运行时会拒绝"这句话一字不改地成立。
if string(geom.type) ~= "sphere"
    error("tepc:transport:Geom", ...
        "解析输运链 (弦→CSDA→壁) 只对 sphere 闭合, 实得 geometry.type=%s", char(geom.type));
end
switch mode
    case "chord"
        P0 = Pin(:);              % 抽样器给的体内点本身就是作用点: 不另抽, 不再沿弦取点
    case "volume"
        P0 = tepc.transport.sampleInVolume(geom, 1, rs);
    otherwise
        error("tepc:transport:BadBirthMode", ...
            "transport.birthPoint 只认 chord|volume, 实得 %s", char(mode));
end
end
