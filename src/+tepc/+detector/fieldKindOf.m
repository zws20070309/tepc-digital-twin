function kind = fieldKindOf(field)
%FIELDKINDOF field 结构体里的电极场类型, 缺省 'cylinder' (历史行为)。
%   单一实现: 曾 avalanche / ramoWaveform 各写一份同样的 isfield+判空,
%   driftCollect / ramoCurrent 则干脆没有该入参、硬编码圆柱。

if isfield(field, 'kind') && ~isempty(field.kind)
    kind = field.kind;
else
    kind = 'cylinder';
end
end
