function ident = checkParamIdentity(cfg, mdl)
%CHECKPARAMIDENTITY .slx 里的参数与解析后的 config 是否同源 (可失败的核对)。
%   输入
%     cfg  tepc.config.load 得到的配置 (参数的唯一字面量来源)
%     mdl  已加载的模型名, 或 .slx 路径 (给路径则本函数自行 load/close, 不保存)
%   输出 ident
%     .rows     逐对话框记录: block dialog kind expected stored cfgValue resolved
%               与三条判据 nameOk bakedOk valueOk
%     .ok / .nRows / .nBad / .messages
%     .symbols  modelParams 提供的符号名
%     .unusedSymbols 配置给了、却没被任何 param 行引用的符号 (参数断线的证据)
%     .uncovered     模型里带 SampleTime 却不在 spec 表中的块 (核对不覆盖新块的证据)
%
%   三条判据各自抓一类失效, 少一条就漏:
%     nameOk  对话框里的符号名 == spec 期望名        -> 吃的是配置里的哪一条
%     bakedOk 存的是符号 (结构上该继承的存 -1)       -> 数值没被烘进文件
%     valueOk 符号在工作区里**实际解析出的数值** == 由 cfg 算出的期望值
%   valueOk 刻意读工作区实际值而不是再推导一遍期望值: 后者会让注入环节
%   (inject/applyParams) 的错误同时污染两侧, 判据恒真。

isPath = ischar(mdl) && endsWith(mdl, '.slx');
loadedName = '';
if isPath
    loadedName = modelName(mdl);
    load_system(mdl);
    name = loadedName;
else
    name = mdl;
end
release = onCleanup(@() closeIf(loadedName, isPath)); %#ok<NASGU>

[p, spec] = tepc.simulink.modelParams(cfg);
rows = struct('block', {}, 'dialog', {}, 'kind', {}, 'expected', {}, 'stored', {}, ...
    'cfgValue', {}, 'resolved', {}, 'nameOk', {}, 'bakedOk', {}, 'valueOk', {});
msgs = {};
for k = 1:size(spec, 1)
    blk = spec{k,1};  dlg = spec{k,2};
    expS = strtrim(spec{k,3});  kind = spec{k,4};
    obj = blk2obj(name, blk);
    stored = '';
    try
        v = get_param(obj, dlg);
        if ischar(v), stored = strtrim(v); end
    catch e
        msgs{end+1} = sprintf('%s.%s 读不到: %s', blk, dlg, e.message); %#ok<AGROW>
    end
    expVal = expValue(p, expS);
    isSym = ~isempty(regexp(stored, '^[A-Za-z]\w*$', 'once'));
    nameOk = strcmp(stored, expS);
    if strcmp(kind, 'inherited')
        bakedOk = strcmp(stored, '-1');
    else
        bakedOk = isSym;
    end
    res = NaN;
    if isSym
        try
            res = evalin('base', stored);
        catch
            msgs{end+1} = sprintf('%s.%s 引用的符号 %s 不在工作区 (未注入)', ...
                blk, dlg, stored); %#ok<AGROW>
        end
    elseif ~isempty(stored) && isempty(regexp(stored, '[^0-9eE\.\+\-\s\[\],]', 'once'))
        res = str2num(stored);   %#ok<ST2NM> % 对话框里只可能是数值字面量
        if ~strcmp(kind, 'inherited')
            msgs{end+1} = sprintf('%s.%s 存的是字面量 [%s] 而不是符号 %s: 参数被烘进模型', ...
                blk, dlg, stored, expS); %#ok<AGROW>
        end
    end
    valueOk = sameValue(res, expVal);
    if bakedOk && ~nameOk
        msgs{end+1} = sprintf('%s.%s 存 [%s], spec 要求符号 %s (期望值 %s)', ...
            blk, dlg, stored, expS, valText(expVal)); %#ok<AGROW>
    end
    if nameOk && ~valueOk
        msgs{end+1} = sprintf('%s.%s: 符号 %s 现值 %s != config 算得 %s', ...
            blk, dlg, stored, valText(res), valText(expVal)); %#ok<AGROW>
    end
    rows(end+1) = struct('block', blk, 'dialog', dlg, 'kind', kind, 'expected', expS, ...
        'stored', stored, 'cfgValue', {expVal}, 'resolved', {num(res)}, ...
        'nameOk', nameOk, 'bakedOk', bakedOk, 'valueOk', valueOk); %#ok<AGROW>
end

% 覆盖性: 模型里带 SampleTime 的块必须都在表里 —— 否则"每个块都被核过"是空话。
blks = find_system(name, 'SearchDepth', 1, 'Type', 'Block');
need = {};
for i = 1:numel(blks)
    b = strrep(blks{i}, [name '/'], '');
    st = [];
    try
        v = get_param(blks{i}, 'SampleTime');
        if ischar(v), st = v; end
    catch
    end
    inSpec = any(strcmp({spec{:,1}}, b) & strcmp({spec{:,2}}, 'SampleTime'));
    if ischar(st) && ~isempty(st) && ~inSpec
        need{end+1} = b; %#ok<AGROW>
        msgs{end+1} = sprintf('块 %s 的 SampleTime=[%s] 不在 spec 表里: 核对不覆盖它', b, st); %#ok<AGROW>
    end
end
paramSym = {spec{strcmp({spec{:,4}}', 'param'), 3}};
unused = setdiff(fieldnames(p)', paramSym, 'stable');

% 求解器类型: 4 行 inherited 的"与 cfg 同源"是**传递**成立的 —— 继承块的步长取自求解器,
% 而求解器的 FixedStep 由 spec 第一行核过等于 cfg 的 Ts。这条链的第一环 (模型确实是定步长)
% 先前没有任何判据: set_param 只发生在 buildElectronicsModel:45 建模的那一刻, 发货文件若被
% 换成变步长求解器, FixedStep 会被直接忽略, 上面所有行仍然全绿。
solverType = '';
solverName = '';
try
    v = get_param(name, 'SolverType');
    if ischar(v), solverType = strtrim(v); end
    v = get_param(name, 'Solver');
    if ischar(v), solverName = strtrim(v); end
catch e
    msgs{end+1} = sprintf('读不到求解器类型: %s', e.message); %#ok<AGROW>
end
solverOk = strcmp(solverType, 'Fixed-step') && ~isempty(regexp(solverName, '^FixedStep', 'once'));
if ~solverOk
    msgs{end+1} = sprintf(['求解器不是定步长 (SolverType=[%s] Solver=[%s]): spec 里 $model 那行 ' ...
        'FixedStep 会被忽略, 4 行 inherited 的"与配置采样时间同源"因此不成立'], ...
        char(string(solverType)), char(string(solverName))); %#ok<AGROW>
end

ident = struct();
ident.rows = rows;
ident.solverOk = solverOk;
ident.solverType = solverType;
ident.solver = solverName;
ident.ok = all([rows.nameOk] & [rows.bakedOk] & [rows.valueOk]) && isempty(msgs);
ident.nRows = numel(rows);
ident.nBad = nnz(~([rows.nameOk] & [rows.bakedOk] & [rows.valueOk]));
ident.messages = msgs;
ident.symbols = fieldnames(p)';
ident.unusedSymbols = unused;
ident.uncovered = need;
ident.params = p;
ident.model = name;
ident.spec = spec;
ident.fileSha256 = '';
if isPath
    ident.fileSha256 = tepc.io.hashFile(mdl);
end
end

% ------------------------------------------------------------------ helpers
function nm = modelName(slxPath)
[~, nm, ~] = fileparts(slxPath);
end

function closeIf(nm, isPath)
if isPath && ~isempty(nm) && bdIsLoaded(nm)
    close_system(nm, 0);
end
end

function obj = blk2obj(name, blk)
if strcmp(blk, '$model')
    obj = name;
else
    obj = [name '/' blk];
end
end

function v = expValue(p, symName)
v = NaN;
if isfield(p, symName)
    v = p.(symName).value;
elseif ~isempty(regexp(symName, '^[\-]?[0-9]', 'once'))
    v = str2double(symName);
end
end

function tf = sameValue(a, b)
a = num(a);  b = num(b);
if isempty(a) || isempty(b) || ~all(isfinite(a(:))) || ~all(isfinite(b(:)))
    tf = false; return;
end
if isvector(a) && isvector(b)
    a = a(:);  b = b(:);
end
tf = isequal(size(a), size(b)) && all(a(:) == b(:));
end

function x = num(v)
if isnumeric(v) || islogical(v)
    x = double(v);
else
    x = NaN;
end
end

function s = valText(v)
v = num(v);
if isempty(v) || any(~isfinite(v(:)))
    s = '无法解析';
elseif isvector(v)
    s = strtrim(sprintf('%.17g ', v(:)'));
else
    s = mat2str(v, 17);
end
end
