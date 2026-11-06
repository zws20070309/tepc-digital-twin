function txt = depthLine(s, sep)
%DEPTHLINE 摘要/控制台/报告/GUI 状态带共用的不确定度传播深度行。
%   措辞只有这一处产出: 报告与界面各自拼一句是该缺陷家族的根因 (同 doseLine 的先例)。
%   必须挡住的误读: 看到"档位: screening"就把读数的不确定度当成了精度损失, 或反过来
%   以为选高档会让中心量更准。档位改的是"算不算不确定度传播"与墙钟, 不改任何物理量。
if nargin < 2, sep = ", "; end
tier = "未设";
if isfield(s, 'uncertainty_depth_tier') && ~isempty(s.uncertainty_depth_tier)
    tier = strtrim(string(s.uncertainty_depth_tier));
end
lab = "";
if isfield(s, 'uncertainty_depth_label') && ~isempty(s.uncertainty_depth_label)
    lab = strtrim(string(s.uncertainty_depth_label));
end
if lab ~= ""
    txt = sprintf('不确定度传播深度: %s (%s)', char(tier), char(lab));
else
    txt = sprintf('不确定度传播深度: %s', char(tier));
end
kn = "";
if isfield(s, 'uncertainty_depth_knobs_json') && ~isempty(s.uncertainty_depth_knobs_json)
    kn = strtrim(string(s.uncertainty_depth_knobs_json));
end
if kn ~= ""
    txt = [txt sprintf('%s生效旋钮 %s', sep, char(kn))];
end
% 中心量不变的口径来自逐位回归锁, 不是这里的自述: 措辞写成"由锁承担"以免文档自证。
txt = [txt sprintf('%s已发布中心量逐位相同 (逐位锁覆盖 screening/standard 两档), 档位只改不确定度陈述与墙钟', sep)];
st = "";
if isfield(s, 'uq_status') && ~isempty(s.uq_status)
    st = upper(strtrim(string(s.uq_status)));
end
if st == "DISABLED"
    % "不得进结论"只能由**档位**触发: uq_status=DISABLED 也可能来自用户自己把
    % uq.enabled 写成 false (或与旧产物没有档位字段), 那时把它说成"本档"是假归因。
    if tier == "screening"
        txt = [txt sprintf('%s本档不生成 uq.json: 只可用于量级与趋势, 不得进报告结论', sep)];
    else
        txt = [txt sprintf('%s本次未评估不确定度 (来自配置本身, 不是档位)', sep)];
    end
elseif isfield(s, 'uncertainty_depth_note') && ~isempty(s.uncertainty_depth_note)
    nt = strtrim(string(s.uncertainty_depth_note));
    if nt ~= ""
        txt = [txt sprintf('%s%s', sep, char(nt))];
    end
end
cf = "";
if isfield(s, 'uncertainty_depth_conflicted') && ~isempty(s.uncertainty_depth_conflicted)
    cf = strtrim(string(s.uncertainty_depth_conflicted));
end
if cf ~= "" && cf ~= "无"
    txt = [txt sprintf('%s档位被配置显式值覆写: %s', sep, char(cf))];
end
end
