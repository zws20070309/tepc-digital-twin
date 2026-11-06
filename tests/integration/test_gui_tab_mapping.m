function tests = test_gui_tab_mapping
%TEST_GUI_TAB_MAPPING 结构性锁住"控件所在页 <-> 页标题"的对应关系。
%   背景缺陷: buildUI 曾按 tg.Children(end-k) 反序索引取页, 而 Children 实测为正序
%   -> 8 个页签内容整体镜像错配, 且不抛错 (只是控件全部挂到隔壁页)。
%   本测试不依赖实现方式: 从每个控件的 Parent 链反推其祖先 Tab 的 Title, 与期望
%   逐条比对; 再出现错配/漏挂/新增未登记控件都会被点名。
tests = functiontests(localfunctions);
end

function setup(~)
root = tepc.io.projectRoot();
addpath(fullfile(root, 'app'));
end

function test_all_tabs_present_and_unique(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
tabs = app.allTabs();
tc.verifyEqual(numel(tabs), 9, '页签数量应为 9 (含三维几何)');
titles = cell(1, numel(tabs));
for i = 1:numel(tabs)
    titles{i} = char(string(tabs(i).Title));
end
want = {'项目','几何与气体','电场与增益','源','电子学','运行','谱与剂量','三维几何','验证与报告'};
for i = 1:numel(want)
    n = 0;
    for j = 1:numel(titles)
        if strcmp(titles{j}, want{i}), n = n + 1; end
    end
    tc.verifyEqual(n, 1, sprintf('页签 "%s" 必须恰好存在一个 (重复=镜像错配伴生症状)', want{i}));
end
end

function test_tab_by_title_is_position_independent(tc)
% 标题寻址必须逐个给出正确对象; 未知标题必须报错 (不得退化为顺序索引)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
for k = 1:numel(app.TabTitles)
    t = app.tabByTitle(app.TabTitles{k});
    tc.verifyEqual(char(string(t.Title)), app.TabTitles{k}, sprintf('tabByTitle 第 %d 项', k));
end
tc.verifyError(@() app.tabByTitle('不存在的页签'), 'tepc:gui:NoTab');
end

function test_field_controls_on_expected_page(tc)
% 每个界面控件的祖先 Tab 标题必须等于期望页标题 (反序索引错配的直接捕手)
exp = { ...
 'run_nEvents', '项目';        'run_seed',   '项目';      'run_mode',   '项目'; ...
 'run_chunk',   '项目';        'cfg_path',   '项目';      'provenance', '项目'; ...
 'geo_type',    '几何与气体';  'geo_R',      '几何与气体'; 'geo_wall',   '几何与气体'; ...
 'geo_len',     '几何与气体';  'geo_anode',  '几何与气体'; 'site_d',     '几何与气体'; ...
 'gas_p',       '几何与气体';  'gas_T',      '几何与气体'; 'gas_W',      '几何与气体'; ...
 'gas_F',       '几何与气体';  'gas_ch4',    '几何与气体'; 'gas_co2',    '几何与气体'; ...
 'gas_n2',      '几何与气体';  'site_mode',  '几何与气体'; 'geom_out',   '几何与气体'; ...
 'field_hv',    '电场与增益';  'field_dV',   '电场与增益'; 'field_mode', '电场与增益'; ...
 'field_out',   '电场与增益'; ...
 'src_type',    '源';          'src_E',      '源';        'src_rate',   '源'; ...
 'src_flu',     '源';          'src_arr',    '源'; ...
 'el_cf',       '电子学';      'el_thr',     '电子学';    'el_bits',    '电子学'; ...
 'el_rf',       '电子学';      'el_hyst',    '电子学';    'el_fs',      '电子学'; ...
 'el_tau',      '电子学';      'el_dt',      '电子学';    'el_g2',      '电子学'; ...
 'el_ts',       '电子学';      'el_wwin',    '电子学';    'el_pu',      '电子学'; ...
 'el_dtmode',   '电子学'; ...
 'spec_mode',   '谱与剂量';    'spec_out',   '谱与剂量'; ...
 'geo3_view',   '三维几何';    'geo3_out',   '三维几何'};
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
have = fieldnames(app.Fields);
tags = cell(size(exp, 1), 1);
for i = 1:size(exp, 1)
    tags{i} = exp{i,1};
end
% 双向覆盖: 登记的控件必须真的存在, 界面新增控件必须登记
for i = 1:size(exp, 1)
    tc.verifyTrue(any(strcmp(have, tags{i})), ...
        sprintf('期望表中的 %s 在 app.Fields 中不存在 (界面/测试已失步)', tags{i}));
end
for i = 1:numel(have)
    tc.verifyTrue(any(strcmp(tags, have{i})), ...
        sprintf('app.Fields.%s 未登记期望页标题 -> 请加入本测试期望表', have{i}));
end
for i = 1:size(exp, 1)
    ttl = '<无祖先页签>';
    p = app.Fields.(exp{i,1}).Parent;
    guard = 0;
    while ~isempty(p) && guard < 30
        guard = guard + 1;
        if endsWith(class(p), '.Tab')
            ttl = char(string(p.Title));
            break;
        end
        p = p.Parent;
    end
    tc.verifyEqual(ttl, exp{i,2}, sprintf('控件 %s 挂错页 (应在 "%s")', tags{i}, exp{i,2}));
end
end

function test_axes_tables_and_buttons_on_expected_page(tc)
% 关键对象与按钮的归属页 (这些不在 Fields 里, 同样曾经整体错页)
expObj = { ...
 'AxGeom',     '几何与气体'; 'AxField',   '电场与增益'; 'AxSpectrum', '谱与剂量'; ...
 'GatesTable', '验证与报告'; 'LogList',   '运行';       'ProgBar',    '运行'; ...
 'AxGeom3D',   '三维几何'};
expBtn = { ...
 'run', '运行'; 'pause', '运行'; 'cancel', '运行'; ...
 'load', '项目'; 'validate', '项目'; 'export', '验证与报告'; ...
 'preview3d', '三维几何'; 'export3d', '三维几何'};
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
for i = 1:size(expObj, 1)
    obj = app.(expObj{i,1});
    tc.verifyTrue(isobject(obj) && isvalid(obj), sprintf('%s 应为有效对象', expObj{i,1}));
    if ~isobject(obj) || ~isvalid(obj), continue; end
    ttl = '<无祖先页签>';
    p = obj.Parent;
    guard = 0;
    while ~isempty(p) && guard < 30
        guard = guard + 1;
        if endsWith(class(p), '.Tab')
            ttl = char(string(p.Title));
            break;
        end
        p = p.Parent;
    end
    tc.verifyEqual(ttl, expObj{i,2}, sprintf('%s 挂错页 (应在 "%s")', expObj{i,1}, expObj{i,2}));
end
for i = 1:size(expBtn, 1)
    key = expBtn{i,1};
    tc.verifyTrue(isfield(app.Buttons, key), sprintf('Buttons 缺少 %s', key));
    if ~isfield(app.Buttons, key), continue; end
    ttl = '<无祖先页签>';
    p = app.Buttons.(key).Parent;
    guard = 0;
    while ~isempty(p) && guard < 30
        guard = guard + 1;
        if endsWith(class(p), '.Tab')
            ttl = char(string(p.Title));
            break;
        end
        p = p.Parent;
    end
    tc.verifyEqual(ttl, expBtn{i,2}, sprintf('按钮 %s 挂错页 (应在 "%s")', key, expBtn{i,2}));
end

% 进度量规的"量程"与"写入值"必须同代: 量规缺省量程是 [0 100], 而 onProgress 写的是 prog(frac)
% 的 0..1 分数, 两边不同代时 0.92 只填 0.92% —— 整轮运行进度条看着一直是 0, 且 1030 px 上会印
% 51 个刻度标签互相挤压。这里把两端钉在一起: 只改任意一端都会红。
code = stripComments(fileread(fullfile(tepc.io.projectRoot(), 'app', 'TEPCApp.m')));
tok = regexp(code, 'ProgBar\.Value\s*=\s*min\(max\(double\(f\)\s*,\s*([-0-9.eE]+)\)\s*,\s*([-0-9.eE]+)\)', 'tokens', 'once');
tc.verifyFalse(isempty(tok), '找不到 onProgress 里 ProgBar.Value 的 min(max(...)) 钳位写法, 本锁失效');
if ~isempty(tok)
    lo = str2double(tok{1}); hi = str2double(tok{2});
    lim = app.ProgBar.Limits;
    tc.verifyEqual(double(lim(1)), lo, 'RelTol', 1e-12, ...
        sprintf('量规下界 %.6g 与写入下界 %.6g 不同代', lim(1), lo));
    tc.verifyEqual(double(lim(2)), hi, 'RelTol', 1e-12, ...
        sprintf('量规上界 %.6g 与写入上界 %.6g 不同代 (不同代则进度条永远看着像 0)', lim(2), hi));
    tc.verifyGreaterThan(double(lim(2)), double(lim(1)), '量规量程退化, 填充比会除零');
end
end

function test_source_does_not_use_positional_child_index(tc)
% 源码级守卫: 页签寻址必须按标题, 不得再出现 Children(end-k)。
% 必须先剥掉注释行 —— TEPCApp.m 的文件头注释里就在"引用"这个禁用的写法,
% 直接 contains(整份源码) 会把文档说明当成违规 (实测假阳性)。
root = tepc.io.projectRoot();
code = stripComments(fileread(fullfile(root, 'app', 'TEPCApp.m')));
tc.verifyFalse(contains(code, 'Children(end'), ...
    'TEPCApp.m 不得用 Children(end-k) 反序索引取页签 (Children 顺序不保证)');
tc.verifyTrue(contains(code, 'tabByTitle'), ...
    'TEPCApp.m 必须经 tabByTitle 按标题挂载页签内容');
% 页签标题必须在白名单 TabTitles 里逐个可寻址 (防止把标题拼错后静默退化)
tc.verifyTrue(contains(code, 'self.TabTitles'), '必须维护 TabTitles 白名单');
end

function src = stripComments(src)
%STRIPCOMMENTS 去掉每行 % 之后的内容与整行注释 (仅用于源码级守卫比对)
lines = strsplit(string(src), "\n");
for i = 1:numel(lines)
    t = strtrim(lines(i));
    if startsWith(t, "%"), lines(i) = ""; continue; end
    k = find(lines(i) == "%", 1);
    if ~isempty(k)
        row = lines(i); row = row{1};
        lines(i) = row(1:max(1, k-1));
    end
end
src = join(lines, "\n");
end
