function md = genPositioning(root, outFile)
%GENPOSITIONING 由能力登记表生成 docs/positioning.md。
%   README / GUI 标题带 / HTML 报告里的"项目定位"段落只能嵌入本文件的输出, 不允许
%   自己造句子: 让"能声称什么"只有一个来源, 且能被测试反查。
%   规则: DONE 进"可以声称"; PARTIAL 进"只能部分声称"并附未覆盖原因;
%   BLOCKED 进"未实现"并写明缺什么; EXCLUDED 只进附录。
%   只要参考场槽为空或任何证据 kind=synthetic, 正文顶部强制写"不可发布绝对剂量"。
if nargin < 1 || isempty(root)
    root = tepc.io.projectRoot();
end
J = readRegisterJson(root);
reg = J.entries;

lines = strings(0, 1);
lines(end+1) = "# 项目定位（由 config/capability_register.json 生成，勿手改）";
lines(end+1) = "";
stamp = char(string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm')));
lines(end+1) = sprintf("生成时间: %s | 登记表 schema: %s | 条目 %d 条", ...
    stamp, string(J.schema), numel(reg));
lines(end+1) = "";
if needsReleaseWarning(reg)
    lines(end+1) = "**当前不可发布绝对剂量**：参考场数据缺位，或存在合成（非实测）证据。";
    lines(end+1) = "";
end

lines(end+1) = "## 可以声称";
lines(end+1) = "";
n0 = numel(lines);
lines = appendSection(lines, reg, "DONE", false);
if numel(lines) == n0
    lines(end+1) = "- （无：没有任何条目达到可声称状态）";
end
lines(end+1) = "";

lines(end+1) = "## 只能部分声称（附未覆盖原因）";
lines(end+1) = "";
lines = appendSection(lines, reg, "PARTIAL", true);
lines(end+1) = "## 未实现（缺外部软件或实测数据）";
lines(end+1) = "";
lines = appendSection(lines, reg, "BLOCKED", true);
lines(end+1) = "## 附录：本轮排除项";
lines(end+1) = "";
lines = appendSection(lines, reg, "EXCLUDED", true);

if nargin < 2 || isempty(outFile)
    outFile = fullfile(root, 'docs', 'positioning.md');
end
fid = fopen(outFile, 'w', 'n', 'UTF-8');
if fid < 0
    error('tepc:io:WriteFailed', '无法写入 %s', outFile);
end
% 逐行 fprintf 而不是 fwrite(unicode2native(char(txt))): char(含换行的 string 标量)
% 会展开成多行字符矩阵, unicode2native 对它的输出是按行分段的 cell, 写盘会报错。
for i = 1:numel(lines)
    fprintf(fid, '%s\n', lines(i));
end
fclose(fid);
fprintf('positioning.md 已生成: %s (%d 行)\n', outFile, numel(lines));
md = outFile;
end

%% ---------------- 辅助 ----------------

function J = readRegisterJson(root)
p = fullfile(root, 'config', 'capability_register.json');
if ~isfile(p)
    error('tepc:config:NoRegister', '缺 %s', p);
end
fid = fopen(p, 'r', 'n', 'UTF-8');
if fid < 0
    error('tepc:io:ReadFailed', '打不开 %s', p);
end
raw = fread(fid, inf, 'uint8=>uint8');
fclose(fid);
% fread 默认返回列向量, 而 native2unicode 对二维 char 输入是按行返回 cell 数组,
% 于是 string() 得到的是非标量字符串数组, jsondecode 会拒绝它。先压成一行。
txt = string(native2unicode(raw(:)', 'UTF-8'));
J = jsondecode(txt);
end

function tf = needsReleaseWarning(reg)
tf = true;                      % 默认阻断: 拿不到证据就当不可发布
for i = 1:numel(reg)
    slots = getFieldOr(reg(i), 'reference_field_slots');
    if ~isempty(slots) && ~isemptyFieldnames(slots)
        continue;               % 该条目有填好的参考场槽
    end
    ev = getFieldOr(reg(i), 'evidence');
    if ~isempty(ev) && any(strcmp({ev.kind}, 'synthetic'))
        return;
    end
end
haveAny = false;
for i = 1:numel(reg)
    slots = getFieldOr(reg(i), 'reference_field_slots');
    if ~isempty(slots) && ~isemptyFieldnames(slots)
        haveAny = true;
    end
end
tf = ~haveAny;
end

function tf = isemptyFieldnames(s)
tf = isstruct(s) && isempty(fieldnames(s));
end

function lines = appendSection(lines, reg, want, withReason)
for i = 1:numel(reg)
    if string(getFieldOr(reg(i), 'status')) ~= string(want)
        continue;
    end
    ph = phrases(reg(i));
    id = string(getFieldOr(reg(i), 'id'));
    if strcmp(want, "DONE")
        for j = 1:numel(ph)
            lines(end+1) = sprintf("- %s （%s）", ph(j), id);
        end
    else
        lines(end+1) = sprintf("- %s [%s] %s", id, want, strjoin(ph, '; '));
        if withReason
            why = noteOf(reg(i));
            if ~isempty(why)
                lines(end+1) = sprintf("  - 原因: %s", why);
            end
        end
    end
end
end

function v = getFieldOr(e, f)
v = [];
if isstruct(e) && isfield(e, f)
    v = e.(f);
end
end

function ph = phrases(e)
raw = getFieldOr(e, 'allowed_phrases');
ph = strings(0, 1);
if ~isempty(raw)
    if iscell(raw)
        ph = string(raw(:));
    else
        ph = string(raw);
    end
end
if isempty(ph)
    ph = string(getFieldOr(e, 'title'));
end
end

function w = noteOf(e)
why = getFieldOr(e, 'reason');
if ~isempty(why)
    w = string(why);
    return;
end
rq = getFieldOr(e, 'requires');
if ~isempty(rq)
    if iscell(rq)
        w = strjoin(string(rq), ', ');
    else
        w = string(rq);
    end
    return;
end
w = "";
end
