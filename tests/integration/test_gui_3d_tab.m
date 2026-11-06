function tests = test_gui_3d_tab
%TEST_GUI_3D_TAB GUI 三维页签真的能跑 (落地证据, 不是"页签存在"就算落地)。
%   背景: 三维几何代码本身有单测 (test_geometry_3d_contract), 但如果 GUI 里字段名
%   对不上, 用户点 [刷新三维] 只会得到一条被吞掉的异常 —— 那等于没落地。
%   本文件驱动真实控件, 并断言: 无异常横幅、文本框里出现门禁数值、UIAxes 里真的
%   画出了对象、导出按钮产出网格文件与清单。
tests = functiontests(localfunctions);
end

function wf = workbenchFigures()
% 用 TEPC3DWorkbench 自己打的 appdata 认窗口: 按标题前缀猜会在改文案时静默失效,
% 按 findall 计数又把主界面和测试遗留窗口算进来。
fs = findall(0, 'Type', 'figure');
keep = false(numel(fs), 1);
for i = 1:numel(fs)
    d = getappdata(fs(i));
    keep(i) = isfield(d, 'tepcWorkbench');
end
wf = fs(keep);
end

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function test_3d_tab_exists_and_controls_registered(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
tc.verifyTrue(any(cellfun(@(s) strcmp(char(string(s)), '三维几何'), cellstr(app.TabTitles))), ...
    '必须有"三维几何"页签');
tc.verifyTrue(isfield(app.Fields, 'geo3_view') && isfield(app.Fields, 'geo3_out'));
tc.verifyTrue(isobject(app.AxGeom3D) && isvalid(app.AxGeom3D));
tc.verifyTrue(isfield(app.Buttons, 'preview3d') && isfield(app.Buttons, 'export3d'));
end

function test_workbench_button_is_registered_and_gated(tc)
% 主界面此前没有进三维工作台的入口 (只能另起独立启动器), "两级三维"对只用主界面的人是断的。
% 按钮要在, 且未校验配置时只提示、不开窗 —— 开一台用默认配置的工作台会让人以为看的是自己
% 刚改的那份配置, 那比没有入口更糟。
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));                       %#ok<NASGU>
tc.verifyTrue(isfield(app.Buttons, 'open3dWorkbench'), '三维页必须有"打开三维工作台"按钮');
% 本用例数的是**全局**工作台窗口数, 而 TEPC3DWorkbench 的 Unique 机制会收掉已开的那一台:
% 只要套件里前一个用例遗留了一台没关, before=1 而点完仍是 1, "before+1" 就凭空红一条
% (全量跑实测过一次, 单跑两腿都绿)。先把遗留窗口关掉, 再断言基线真的是 0 —— 否则这条
% 用例的算术依赖别人的收尾。
stale = workbenchFigures();
for i = 1:numel(stale)
    delete(stale(i));
end
before = numel(workbenchFigures());
tc.verifyEqual(before, 0, 'AbsTol', 0, ...
    sprintf('用例开头就有 %d 台遗留工作台窗口: 关不掉说明别处漏了收尾', before));
app.onOpen3dWorkbench();
b1 = string(app.Banner.Text);
tc.verifyTrue(contains(b1, "校验配置"), sprintf('未校验时点工作台必须被拦并给原因, 实得: %s', char(b1)));
tc.verifyEqual(numel(workbenchFigures()), before, 'AbsTol', 0, '未校验时不得开出工作台窗口');
app.onValidate();
app.onOpen3dWorkbench();
wf = workbenchFigures();
tc.verifyEqual(numel(wf), before + 1, 'AbsTol', 0, '校验后点按钮应开出恰好一台工作台');
app.onOpen3dWorkbench();
wf2 = workbenchFigures();
tc.verifyEqual(numel(wf2), before + 1, 'AbsTol', 0, ...
    '重复点击不得叠窗 (Unique 应当收掉上一台再开新的)');
if ~isempty(wf2), delete(wf2); end
end

function test_preview_requires_validated_config(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
% 未校验: 必须明确拒绝并留痕, 不得画一张"看着像"的空图
app.onPreview3d();
b = char(string(app.Banner.Text));
tc.verifyTrue(contains(b, '三维预览失败') || contains(b, '校验配置'), ...
    sprintf('未校验时刷新三维必须被拒绝, 实得横幅: %s', b));
end

function test_preview_after_validate_shows_mesh_verdict(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.onValidate();
tc.verifyEqual(char(app.Controller.state()), 'Validated');
app.onPreview3d();
b = string(app.Banner.Text);
tc.verifyFalse(contains(b, "三维预览失败"), ...
    sprintf('刷新三维不得抛错, 横幅: %s', char(b)));
txt = strjoin(string(app.Fields.geo3_out.Value), ' | ');
tc.verifyTrue(contains(txt, "网格门禁"), '必须显示 checkMesh 结论');
tc.verifyTrue(contains(txt, "非流形边=0"), sprintf('非流形边必须为 0, 实得: %s', txt));
tc.verifyTrue(contains(txt, "零面积面=0"), sprintf('零面积面必须为 0, 实得: %s', txt));
tc.verifyTrue(contains(txt, "闭合=1"));
% 位点请求/实现必须同屏: 只显示 realized 会让用户不知道请求被覆写
tc.verifyTrue(contains(txt, "请求") && contains(txt, "实现"), ...
    sprintf('必须同时显示请求与实现位点: %s', txt));
% 拓扑三方一致: 文本里打印的场必须就是解析模型用的那个
R = tepc.config.resolve(demoCfg());
tc.verifyTrue(contains(txt, char(R.field.kind)), ...
    sprintf('页签显示的场类型必须等于 R.field.kind (%s), 实得: %s', R.field.kind, txt));
ch = app.AxGeom3D.Children;
tc.verifyGreaterThan(numel(ch), 0, 'UIAxes 里必须真的画上几何对象 (空坐标区=没渲染)');

% --- 三维页零件图例必须整条落在窗口里, 且不压按钮 ---
%   图例的父级是页签网格而不是坐标区那一格, 'southoutside' 会一路向下长出网格外:
%   实测 25 项两列时高 166 px、下溢网格 111 px, 约 18 条被窗口下沿裁掉, 同时压住按钮行。
%   排版只在 Visible 之后才发生, 所以这里必须先把窗口亮起来再重算一次图例列数。
app.UIFigure.Visible = 'on';
layStable(app.UIFigure);
app.fitGeom3dLegend();
drawnow; pause(0.3); drawnow;
ud = app.AxGeom3D.UserData;
tc.verifyTrue(isfield(ud, 'legend_box_px'), 'UserData 里没有 legend_box_px: 图例收编没跑到, 下面全部判据无输入');
nEnt = 0;
if isfield(ud, 'legend_entries'), nEnt = double(ud.legend_entries); end
tc.verifyTrue(nEnt >= 10, sprintf( ...
    '图例条目只有 %d 条 (<10): 判据落在空集上, "不越界"就成了恒绿装饰', nEnt));
tc.verifyEqual(string(ud.legend_units), "pixels", sprintf( ...
    '图例 Position 单位是 %s 而不是 pixels: 下面的像素判据口径不成立', string(ud.legend_units)));
tc.verifyTrue(logical(ud.legend_axes_same_parent), ...
    '坐标区与图例不同父: 两者的像素框不在同一坐标系, 越界量没有意义');
btns = {app.Buttons.preview3d, app.Buttons.export3d, app.Buttons.open3dWorkbench};
bb = zeros(numel(btns), 4);
for q = 1:numel(btns)
    bb(q, :) = btns{q}.Position;
end
v = legendBandViolations(ud.legend_box_px, ud.legend_grid_px(4), ud.legend_max_width_px, bb);
tc.verifyEmpty(v, sprintf('三维页图例越界/压按钮 (列数 %d, 条目 %d, 框 [%s], 网格高 %.0f, 允许宽 %.0f): %s', ...
    ud.legend_cols, nEnt, sprintf('%.1f ', ud.legend_box_px), ...
    ud.legend_grid_px(4), ud.legend_max_width_px, strjoin(v, '; ')));

% 反例腿: 单列把同一张图例拉长, 判据必须报红 —— 否则上面那条 verifyEmpty 无从判真。
lg = app.tabLegend();
tc.verifyTrue(isgraphics(lg), '取不到三维页图例, 反例腿无从注入');
if isgraphics(lg)
    lg.NumColumns = 1;
    g3 = app.AxGeom3D.Parent;
    bandKeep = g3.RowHeight{4};
    g3.RowHeight(4) = {60};
    drawnow; pause(0.3); drawnow;
    boxBad = lg.Position;
    vBad = legendBandViolations(boxBad, g3.Position(4), ud.legend_max_width_px, bb);
    g3.RowHeight(4) = {bandKeep};
    drawnow; pause(0.3); drawnow;
    tc.verifyGreaterThan(numel(vBad), 0, sprintf( ...
        '把预留行压回 60 px 后单列图例 (框 [%s]) 仍被判"不越界": 这条锁抓不到已知破坏', ...
        sprintf('%.1f ', boxBad)));
    lg.NumColumns = ud.legend_cols;
    drawnow;
    vOk = legendBandViolations(lg.Position, ud.legend_grid_px(4), ud.legend_max_width_px, bb);
    tc.verifyEmpty(vOk, '复原列数后判据仍报违规: 反例腿与正例不是同一口径, 红绿都不可信');
end
end

function v = legendBandViolations(box, gridH, maxW, btnBoxes)
%LEGENDBANDVIOLATIONS 图例像素框相对页签网格与按钮行的三条越界判据 (返回违规清单)。
%   box/btnBoxes 同为"相对页签网格"的像素框 [x y w h]; gridH 是网格像素高; maxW 是网格
%   可用宽 (减去左右 Padding)。三条各自独立, 便于定位是哪一向出的问题。
v = strings(0, 1);
if numel(box) < 4 || numel(gridH) < 1 || numel(maxW) < 1
    v(1) = "输入不是四条像素数, 无法判"; return
end
if box(2) < 0
    v(end+1) = sprintf("图例下溢网格 %.1f px (被窗口下沿裁掉)", -box(2)); %#ok<AGROW>
end
if box(2) + box(4) > gridH
    v(end+1) = sprintf("图例上溢网格 %.1f px", box(2) + box(4) - gridH); %#ok<AGROW>
end
if box(3) > maxW
    v(end+1) = sprintf("图例宽 %.1f px 超过网格可用 %.1f px", box(3), maxW); %#ok<AGROW>
end
for q = 1:size(btnBoxes, 1)
    bx = btnBoxes(q, :);
    xOv = min(box(1) + box(3), bx(1) + bx(3)) - max(box(1), bx(1));
    yOv = min(box(2) + box(4), bx(2) + bx(4)) - max(box(2), bx(2));
    if xOv > 1 && yOv > 1
        v(end+1) = sprintf("图例与按钮格重叠 %.1fx%.1f px", xOv, yOv); %#ok<AGROW>
    end
end
end

function layStable(fig)
%LAYSTABLE 等排版真的跑完: 只 drawnow 一次时读到的是上一轮的旧框 (本机实测 31 px 起步)。
for q = 1:12
    drawnow; pause(0.08); drawnow;
end
end

function test_export_produces_meshes_and_manifest(tc)
app = TEPCApp(false);
cleanupObj = onCleanup(@() delete(app));
app.onValidate();
app.onExport3d();
b = string(app.Banner.Text);
tc.verifyFalse(contains(b, "三维导出失败"), ...
    sprintf('导出不得抛错, 横幅: %s', char(b)));
txt = strjoin(string(app.Fields.geo3_out.Value), ' | ');
tc.verifyTrue(contains(txt, "schema=tepc-geometry-manifest"), ...
    sprintf('必须给出清单 schema, 实得: %s', txt));
% 横幅说"导出到 X"就必须真有一个 X 目录: 曾把 outBase 当目录传给 exportGeometry,
% 它内部 fileparts 一拆, 产物全平铺进 tempdir, 而横幅仍报那个不存在的目录。
guiDir = extractAfter(string(app.Fields.geo3_out.Value(1)), "导出到 ");
tc.verifyTrue(isfolder(char(guiDir)), ...
    sprintf('横幅宣称的导出目录必须真实存在, 实得: %s', char(guiDir)));
% 直接复算一遍到临时目录, 校验文件真的落盘且带单位后缀。
% 注意 exportGeometry 的第 2 参是**文件基名** (内部 fileparts 拆目录+前缀),
% 只给目录会把所有产物平铺进 tempdir, 于是本断言会在一个不存在的位置找清单。
outBase = fullfile(tempdir, sprintf('tepc_gui3d_%s_%d', char(string(datetime('now','TimeZone','UTC','Format','yyyyMMdd_HHmmssSSS'))), feature('getpid')), 'tepc_geometry');
outDir = fileparts(outBase);
spec = tepc.geometry.meshSpec(demoCfg(), tepc.config.resolve(demoCfg()));
man = tepc.geometry.exportGeometry(spec, outBase);
tc.verifyTrue(isfolder(outDir) && ~isempty(dir(fullfile(outDir, '*_geometry_manifest.json'))), ...
    sprintf('清单必须写入导出目录 %s (期望 *_geometry_manifest.json)', outDir));
tc.verifyTrue(isfile(man.manifest_path), '返回结构的 manifest_path 必须指向真实文件');
tc.verifyEqual(man.manifest_bytes, dir(man.manifest_path).bytes, ...
    '清单自记字节数必须与盘上实际一致 (哈希=内容的前提)');
tc.verifyEqual(numel(man.manifest_sha256), 64, '清单必须有 64 位 sha256');
pf = fieldnames(man);
tc.verifyTrue(any(strcmp(pf,'parts')), '清单必须有 parts 段');
n = 0;
for i = 1:numel(man.parts)
    pth = '';
    if isfield(man.parts(i), 'path_stl'), pth = char(man.parts(i).path_stl); end
    if pth ~= "" && isfile(pth)
        n = n + 1;
        tc.verifyTrue(contains(pth, "unit_mm") || contains(pth, "unit_m") || ...
            contains(pth, "unit_um"), ...
            sprintf('STL 文件名必须自带单位 (STL 格式本身无单位): %s', pth));
    end
end
tc.verifyGreaterThan(n, 0, '至少要有一个零件的 STL 真实存在');
try, rmdir(outDir, 's'); catch, end
end
