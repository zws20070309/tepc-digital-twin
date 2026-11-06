function tests = test_gui_3d_workbench
%TEST_GUI_3D_WORKBENCH 独立三维审计工作台的落地证据 (按句柄/属性读回, 不靠截图判对错)。
%   驱动真实控件: 打开窗口、数 UIAxes 里的 patch、切复选框改 patch 数、开真剖切证明
%   审计读数不变 (显示层不变量的数值断言)、开示意档证明水印文本对象存在、点七预设证明
%   相机逐次改变、两点测距证明单位因子生效、干涉/蒙卡按钮证明"要么出数要么报错误信息"。
%
%   约定: 只有 test* 函数带形参。functiontests 按 (tc) 单输入签名收集局部函数当用例,
%   所以除用例外的辅助函数一律 0 参 (1 参的会被收走并塞进 TestCase)。控件句柄与动作全在
%   setappdata(fig,'wb',...) 里, 测试通过它无窗驱动; 需要 ax 的小逻辑 (水印探测) 就地内联。
tests = functiontests(localfunctions);
end

%% ==================== 共享 fixture (0 参, 不取 tc) ====================

function cfg = demoCfg()
cfg = tepc.config.load(fullfile(tepc.io.projectRoot(), 'config', 'defaults', 'demo_only.json'));
end

function fig = openWB()
% headless 式打开: Visible=false, 返回 uifigure 句柄供 findall 驱动。
fig = TEPC3DWorkbench(demoCfg(), 'Visible', false);
end

function n = clipCaseCount()
% 本配置 (config/defaults/demo_only.json) 下 meshSpec 的零件数 —— 只用来把断言写成
% 非零下限, 换配置不会让断言悄悄退化成"恒真"。
cfg = demoCfg();
spec = tepc.geometry.meshSpec(cfg, tepc.config.resolve(cfg), "");
n = numel(spec.parts);
end

%% ==================== 用例 ====================

function test_finder_is_not_vacuous(tc)
% 控件计数守卫: 本机 findall(fig,'Type','button') 恒返回 0 (uifigure 控件的 Type 不是
% 'button'), 用它做断言等于什么都没断言。按类找控件一律走 isa, 这条用例把"isa 找得到"
% 钉成硬要求, 一旦有别处退回 Type 写法或控件根本没被构造出来, 这里就会红。
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
all0 = findall(fig);
isA = @(objs, cls) objs(arrayfun(@(o) isa(o, cls), objs));
nBtnIsa = numel(isA(all0, 'matlab.ui.control.Button'));
nCbIsa = numel(isA(all0, 'matlab.ui.control.CheckBox'));
nLabIsa = numel(isA(all0, 'matlab.ui.control.Label'));
nDdIsa = numel(isA(all0, 'matlab.ui.control.DropDown'));
% 两种废弃写法钉成断言而不是 try/catch 兜住: 'Type','button' 不报错但恒返回 0 (静默空
% 断言的来源), 带 '-recursive' 的写法本机当场抛 MATLAB:findall:InvalidParameter。
nBtnType = numel(findall(fig, 'Type', 'button'));
tc.verifyEqual(nBtnType, 0, ...
    "findall(fig,'Type','button') 返回 0 是本机事实: 用它做控件断言必然空转");
recThrows = false;
try
    findall(fig, '-recursive', 'Type', 'button');
catch e
    recThrows = strcmp(e.identifier, 'MATLAB:findall:InvalidParameter');
end
tc.verifyTrue(recThrows, ...
    "findall(fig,'-recursive',...) 必须当场抛 InvalidParameter (证明这写法在本机不可用)");
nExpBtn = numel(wb.btnCam) + 6;         % 七视角 + 测距 + 复位 + 干涉 + 蒙卡 + 导出 + 放大取景
% 相机第二维: 只有七个 (az,el) 预设时, 既不能正交/透视切换, 也不能把视野收到零件上
% (mm 腔与 µm 丝同屏, 零件只占几个像素)。这两条把 D-16 的真缺口钉成断言。
tc.verifyTrue(isfield(wb, 'ddProj') && isfield(wb, 'btnFit') && ...
    isfield(wb, 'labFit') && isfield(wb, 'labProj'), ...
    '工作台缺投影下拉/放大取景按钮或两行各自的标签: 多尺度零件无法看清');
wb.ddProj.Value = '透视'; wb.ddProj.ValueChangedFcn(wb.ddProj, []);
tc.verifyEqual(string(wb.ax.Projection), "perspective", '切到透视没改 ax.Projection');
wb.ddProj.Value = '正交'; wb.ddProj.ValueChangedFcn(wb.ddProj, []);
tc.verifyEqual(string(wb.ax.Projection), "orthographic", '切回正交没生效 (正交是工程图口径, 必须是默认)');
% 测试侧独立算一遍"画出来的零件"的中心, 不复用工作台的 drawnPartCtr (共用就成了自证)。
% 两条排除都是判据的一部分, 所以这里要按同样的理由各自再判一次:
%   * 比例尺 line/text 的位置是从轴范围反推的, 算进来取景中心会自己漂;
%   * world_envelope 是给外部 MC 适配器预留的合同位 (半宽 5*bboxR), 算进来框的是空盒子
%     —— 实测含它时基准 254 mm 而装置只有 50.8 mm, 第 1 级几乎不放大。
vx = []; vy = []; vz = [];
chs = wb.ax.Children;
for kc = 1:numel(chs)
    hc = chs(kc);
    if ~isa(hc, 'matlab.graphics.primitive.Patch') || ~strcmp(hc.Visible, 'on')
        continue;
    end
    ud = hc.UserData;
    if isstruct(ud) && isfield(ud, 'part_id') ...
            && strcmp(char(string(ud.part_id)), 'world_envelope')
        continue;
    end
    V = hc.Vertices;
    if isnumeric(V) && size(V, 2) >= 3
        vx = [vx; V(:,1)]; vy = [vy; V(:,2)]; vz = [vz; V(:,3)]; %#ok<AGROW>
    end
end
tc.verifyGreaterThan(numel(vx), 0, ...
    'UIAxes 里必须找得到可见的 patch (零件面): 找不到就说明取景中心是空断言');
% 与实现的口径逐项对齐 (drawnPartCtr 取的是有限顶点的包围盒): 这里少一道 mask 的话,
% 一旦有 NaN 顶点进来, 两边算出的 ext 就不是一回事, 断言会以"测试自己的错"的形式红。
mB = isfinite(vx) & isfinite(vy) & isfinite(vz);
tc.verifyGreaterThan(nnz(mB), 0, '可见零件顶点里必须至少有一个有限点');
vx = vx(mB); vy = vy(mB); vz = vz(mB);
ctrB = [(min(vx)+max(vx))/2 (min(vy)+max(vy))/2 (min(vz)+max(vz))/2];
extB = max([max(vx)-min(vx) max(vy)-min(vy) max(vz)-min(vz)]);
lim0 = [wb.ax.XLim wb.ax.YLim wb.ax.ZLim];
cp0 = wb.ax.CameraPosition;
v0 = view(wb.ax);
span0 = max(lim0(2:2:end) - lim0(1:2:end));
wb.btnFit.ButtonPushedFcn([], []);
lim1 = [wb.ax.XLim wb.ax.YLim wb.ax.ZLim];
span1 = max(lim1(2:2:end) - lim1(1:2:end));
% 第 1 级的定义写在零件上而不是轴范围上: 隐藏窗口里 drawnow 会把 auto 轴范围打成
% 默认的 [0 1] (本机实测), 以"当前视野"为基准算倍数会得到与零件无关的数。
tc.verifyTrue(abs(span1 - 1.1*extB) <= 1e-9*extB, ...
    sprintf('取景第 1 级不是"框住零件 (1.1 x 零件最长边)": 视野跨度 %.6g, 零件最长边 %.6g', ...
        span1, extB));
% 相机坐标在本机随轴范围重算, 挪不挪它不是"真假放大"的分界; 能钉住的是视线方向与投影:
% 二者被改的话, "放大"就变成了走近视点 (透视下那会带出近大远小, 不再是同一份图)。
tc.verifyEqual(string(wb.ax.Projection), "orthographic", ...
    '取景偷改了投影方式');
v1 = view(wb.ax);
tc.verifyEqual(v1, v0, 'RelTol', 1e-9, 'AbsTol', 1e-9, ...
    '取景改了相机变换: 那是走视点假装放大, 不是同一视角下的放大');
fprintf('FITDBG span0=%.6g extB=%.6g span1=%.6g azelSame=%d cam %s -> %s\n', span0, extB, ...
    span1, isequaln(v1, v0), mat2str(cp0, 6), mat2str(wb.ax.CameraPosition, 6));
ctr1 = (lim1(1:2:end) + lim1(2:2:end)) / 2;
tc.verifyEqual(ctr1, ctrB, 'RelTol', 1e-9, 'AbsTol', 1e-9, ...
    sprintf('取景中心不等于画出来的零件包围盒中心: 视角 (%.6g %.6g %.6g) vs 零件 (%.6g %.6g %.6g)', ...
        ctr1(1), ctr1(2), ctr1(3), ctrB(1), ctrB(2), ctrB(3)));
tc.verifyEqual(string({wb.ax.XLimMode, wb.ax.YLimMode, wb.ax.ZLimMode}), ...
    ["manual" "manual" "manual"], '取景后轴范围模式没停在 manual: 下一次重绘会把放大冲掉');
wb.btnFit.ButtonPushedFcn([], []);
lim2 = [wb.ax.XLim wb.ax.YLim wb.ax.ZLim];
span2 = max(lim2(2:2:end) - lim2(1:2:end));
tc.verifyTrue(abs(span2 - 0.5*span1) <= 1e-9*span1, ...
    sprintf('取景第 2 级不是"再放大 2 倍" (%.6g -> %.6g): 级数被每次重置, 按钮就成了装饰', ...
        span1, span2));
tc.verifyEqual(string({wb.ax.XLim(1) < wb.ax.XLim(2), wb.ax.YLim(1) < wb.ax.YLim(2), ...
    wb.ax.ZLim(1) < wb.ax.ZLim(2)}), ["true" "true" "true"], '连按后轴范围反向或退化');
wb.api.resetView();
tc.verifyEqual(string({wb.ax.XLimMode, wb.ax.YLimMode, wb.ax.ZLimMode}), ...
    ["auto" "auto" "auto"], '复位没把取景写下的 manual 轴范围收回去: 只复位了一半');
tc.verifyEqual(string(wb.ax.Projection), "orthographic", '复位后投影不是正交');
tc.verifyEqual(wb.api.state().fitN, 0, ...
    '复位后 state.fitN 必须归零: 标签说归零, 状态也得真归零 (否则级数是隐形的)');
% 下面四条是落地复核抓出来的真缺口: redraw 末尾有 axis tight、比例尺位置由轴范围反推、
% 投影与取景共用过一个标签、零件可以全隐。只看"按下去那一刻"的轴范围发现不了任何一条。
wb.btnFit.ButtonPushedFcn([], []);
wb.btnFit.ButtonPushedFcn([], []);
lim3 = [wb.ax.XLim wb.ax.YLim wb.ax.ZLim];
span3 = max(lim3(2:2:end) - lim3(1:2:end));
tc.verifyEqual(wb.api.state().fitN, 2, '连按两次取景后级数应为 2');
tc.verifyTrue(abs(span3 - 0.55 * extB) <= 1e-9 * extB, ...
    sprintf('取景第 2 级视野不是"1.1x 零件跨度的一半": %.6g vs %.6g', span3, 0.55*extB));
wb.api.redraw();
spanR = max([wb.ax.XLim(2)-wb.ax.XLim(1) wb.ax.YLim(2)-wb.ax.YLim(1) wb.ax.ZLim(2)-wb.ax.ZLim(1)]);
tc.verifyTrue(abs(spanR - span3) <= 1e-9*span3, ...
    sprintf('重绘把取景冲掉了 (级数 2 的视野 %.6g -> 重绘后 %.6g): 勾一个复选框就丢放大', ...
        span3, spanR));
sb = findall(wb.ax, 'Tag', 'tepcScaleBar');
tc.verifyGreaterThan(numel(sb), 0, '取景之后必须仍然画得出比例尺 (Tag=tepcScaleBar)');
% 第 3 级: 视野再减半。这里不能断言"尺子一定变短" —— niceRound 把长度量化到
% {1,2,5,10}x10^k, 视野减半时比例尺完全可以合法地停在同一档 (例 1.49e -> 1e 与
% 0.745e -> 1e)。真正的判据是"尺子必须还是当前视野的尺子": 若取景后没重画,
% 旧的尺是按上一级(更宽)的视野生成的, 相对当前跨度就会超出 0.4 倍上限并跑到视野外。
wb.btnFit.ButtonPushedFcn([], []);
tc.verifyEqual(wb.api.state().fitN, 3, '第 3 次按下后级数应为 3');
lim4 = [wb.ax.XLim wb.ax.YLim wb.ax.ZLim];
span4 = max(lim4(2:2:end) - lim4(1:2:end));
tc.verifyTrue(abs(span4 - 0.5*span3) <= 1e-9*span3, ...
    sprintf('第 3 级视野没有再减半: %.6g vs %.6g', span4, 0.5*span3));
sb3 = findall(wb.ax, 'Tag', 'tepcScaleBar');
tc.verifyEqual(numel(sb3), 1, '取景重绘后应只留一条比例尺 (cla 没清掉旧的就是画在别处)');
barLen = double(sb3(1).XData(2)) - double(sb3(1).XData(1));
tc.verifyTrue(barLen > 0 && barLen <= 0.4*span4, ...
    sprintf('比例尺仍是上一级视野的刻度: 尺长 %.6g, 当前视野跨度 %.6g (上限 %.6g)', ...
        barLen, span4, 0.4*span4));
sbx = double(sb3(1).XData);
tc.verifyTrue(all(sbx >= wb.ax.XLim(1)) && all(sbx <= wb.ax.XLim(2)), ...
    sprintf('比例尺跑到视野外了: x=%s 对 xlim=%s (比例尺要在取景之后画)', ...
        mat2str(sbx, 6), mat2str(wb.ax.XLim, 6)));
wb.ddProj.Value = '透视'; wb.ddProj.ValueChangedFcn(wb.ddProj, []);
tc.verifyTrue(contains(string(wb.labFit.Text), '第 3 级'), ...
    sprintf('切投影抹掉了取景那行的级数记录: labFit=%s', char(string(wb.labFit.Text))));
tc.verifyTrue(contains(string(wb.labProj.Text), '透视'), ...
    sprintf('投影措辞没写进自己的标签: labProj=%s', char(string(wb.labProj.Text))));
wb.ddProj.Value = '正交'; wb.ddProj.ValueChangedFcn(wb.ddProj, []);
for kc2 = 1:numel(wb.cbParts)
    wb.cbParts(kc2).Value = false;
end
wb.api.redraw();
% 这一条单独钉住"重绘自己就会收掉取景": 零件全隐时 redraw 末尾的 applyFit 走空对象分支,
% 级数归零并把轴范围交还 auto。若不先断这一步, 后面按下按钮的那几条早在重绘时就已成立,
% 等于把"按下取景"这一步验成了空断言。
tc.verifyEqual(wb.api.state().fitN, 0, '零件全隐后重绘应把取景级数收归 0');
tc.verifyEqual(string({wb.ax.XLimMode, wb.ax.YLimMode, wb.ax.ZLimMode}), ...
    ["auto" "auto" "auto"], '零件全隐后重绘应把轴范围交还 auto');
wb.btnFit.ButtonPushedFcn([], []);
tc.verifyEqual(wb.api.state().fitN, 0, ...
    '零件全部隐藏后按取景, 级数必须留在 0: 无对象时不许假前进');
tc.verifyEqual(string({wb.ax.XLimMode, wb.ax.YLimMode, wb.ax.ZLimMode}), ...
    ["auto" "auto" "auto"], '零件全隐后取景要把轴范围交还 auto, 不能留着空的 manual');
tc.verifyTrue(contains(string(wb.labFit.Text), '没有可定位的零件'), ...
    sprintf('零件全隐时取景没说实话: %s', char(string(wb.labFit.Text))));
for kc2 = 1:numel(wb.cbParts)
    wb.cbParts(kc2).Value = true;
end
wb.api.redraw();
tc.verifyGreaterThan(nBtnIsa, 0, 'isa 方式必须找得到按钮, 否则后续按钮断言全是空断言');
tc.verifyEqual(nBtnIsa, nExpBtn, ...
    sprintf('isa 找到的按钮数必须等于工作台构造的按钮数 (期望 %d)', nExpBtn));
tc.verifyGreaterThanOrEqual(nCbIsa, clipCaseCount() + 2, ...
    '复选框数必须 >= 零件数 + 示意档 + 剖切档');
tc.verifyGreaterThan(nLabIsa, 5, 'isa 方式必须找得到右侧读数标签');
tc.verifyGreaterThanOrEqual(nDdIsa, 3, ...
    sprintf('下拉框至少要 3 个 (切面法向/单位/投影), 实测 %d 个: 少于 3 个说明投影档没建出来', nDdIsa));
tc.verifyGreaterThan(numel(wb.labTol), 0, 'appdata 必须把公差面板句柄也交出来 (可核对 D4)');
end

function test_window_opens_with_axes_and_appdata(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
tc.verifyTrue(isgraphics(fig, 'figure'), 'TEPC3DWorkbench 必须返回一个图句柄');
tc.verifyEqual(char(fig.Visible), 'off', '自检模式应无窗 (Visible=off)');
% UIAxes 用 isa 找 (Type 写法在本机对 uifigure 控件不可靠, 见 test_finder_is_not_vacuous)。
% 本机 uiaxes 的类是 matlab.ui.control.UIAxes (实测控件普查: 一个 figure 下
% class matlab.ui.control.UIAxes 计数 1), 它不是 matlab.graphics.axis.Axes 的子类,
% 所以既不能按 'matlab.ui.axes.UIAxes' 判, 也不能用 isgraphics(h,'axes') 分类。
axAll = findall(fig);
axesFound = axAll(arrayfun(@(o) isa(o, 'matlab.ui.control.UIAxes'), axAll));
tc.verifyGreaterThanOrEqual(numel(axesFound), 1, '必须能在 figure 上按类找到 UIAxes');
wb = getappdata(fig, 'wb');
tc.verifyTrue(isgraphics(wb.ax) && isa(wb.ax, 'matlab.ui.control.UIAxes') && ...
    any(axesFound == wb.ax), ...
    'appdata 里的 ax 必须就是按类找到的那个 UIAxes');
tc.verifyTrue(isfield(wb, 'ax') && isfield(wb, 'audit') && isfield(wb, 'cbParts'), ...
    'appdata(wb) 必须暴露 ax/audit/cbParts 供无窗驱动');
% 零件标签必须逐字等于 meshSpec 的 part_id。被截断或被改写的名字抄不回代码, 而
% "实现位点/请求位点"这类语义对立的键名一旦切开, 读者只能靠猜。真值取 meshSpec 这一份
% 独立来源, 不用 wb.ids —— 那正是标签的数据源, 拿它对自己永远绿。
% 定位只认"复选框所在的那个格栅": 工作台里另有一处按行放零件名的色表, 全图 findall
% 会把两份一起抓走 (实测 16 个而不是 8 个)。
sp = tepc.geometry.meshSpec(demoCfg(), tepc.config.resolve(demoCfg()), "");
validId = string({sp.parts.part_id});
lgLeft = wb.cbParts(1).Parent;
txt = strings(0, 1);
for i = 1:numel(lgLeft.Children)
    ch = lgLeft.Children(i);
    if isa(ch, 'matlab.ui.control.Label') && all(ch.Layout.Row <= numel(wb.ids)) && ...
            all(ch.Layout.Column == 1)
        txt(end+1) = string(ch.Text); %#ok<AGROW>
    end
end
tc.verifyEqual(numel(txt), numel(wb.ids), sprintf( ...
    '按 (列=1 且 行<=零件数) 只找到 %d 个零件标签, 应为 %d 个: 定位方式与建栏代码脱节了', ...
    numel(txt), numel(wb.ids)));
tc.verifyEqual(numel(unique(txt)), numel(txt), '零件标签有重复: 两个零件在屏上成了同一个名字');
tc.verifyEqual(sort(txt(:).'), sort(validId(:).'), ...
    '零件标签集合与 meshSpec 的 part_id 集合不一致 (截断/改写/漏件都会落在这里)');
tc.verifyFalse(any(contains(txt, '…')), ...
    '零件标签里仍有省略号: 标识符被切开就不是合法 part_id');
% 反例腿: 把同一批标签按旧写法截断, 判据必须翻红。少了这条, 上面的 verifySameSet
% 可能只是在复述产品自己写下的字符串。
trunc = txt;
for i = 1:numel(trunc)
    if strlength(trunc(i)) > 22
        trunc(i) = extractBefore(trunc(i), 23) + "…";
    end
end
tc.verifyFalse(isequal(sort(trunc), sort(validId)), ...
    '截断版标签仍与 part_id 全集相等: 这条判据抓不到截断本身');
tc.verifyGreaterThan(nnz(contains(trunc, '…')), 0, ...
    '按旧写法截断后没有任何标签带省略号: 零件名都短于 23 字符, 这条锁的判据面已失效');
end

function test_axes_patch_count_matches_visible_parts(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
nP = @(ax) nnz(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Patch'), findall(ax)));
nVis = nnz([wb.cbParts.Value]);
tc.verifyEqual(nVis, numel(wb.parts), '默认所有零件可见');
tc.verifyEqual(nP(wb.ax), nVis, ...
    sprintf('UIAxes 里的 patch 数必须等于可见零件数 (%d)', nVis));
end

function test_toggling_checkbox_changes_patch_count(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
nP = @(ax) nnz(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Patch'), findall(ax)));
before = nP(wb.ax);
visBefore = nnz([wb.cbParts.Value]);
% 本机 headless uifigure 里程序化改 .Value 不触发 ValueChangedFcn —— 显式调用该控件的
% ValueChangedFcn 正是用户点击时走的那条路径, 既模拟真实交互又证明控件确实接了线。
wb.cbParts(1).Value = false;
wb.cbParts(1).ValueChangedFcn([], []);
after = nP(wb.ax);
visAfter = nnz([wb.cbParts.Value]);
tc.verifyEqual(before, visBefore, '初始 patch=可见数');
tc.verifyEqual(after, visAfter, '切换后 patch 仍等于可见数');
tc.verifyEqual(after, before - 1, '关掉一个可见零件必须少一个 patch');
for k = 1:numel(wb.cbParts)
    wb.cbParts(k).Value = false;
end
wb.cbParts(1).ValueChangedFcn([], []);
tc.verifyEqual(nP(wb.ax), 0, '全部隐藏后视口不得残留几何 patch');
end

function test_clipping_does_not_change_audit_numbers(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
txtOff = wb.labAudit.Text;
numsOff = [];
for tok = regexp(txtOff, '-?\d\.\d+e[-+]\d+', 'match')
    numsOff(end+1) = str2double(tok{1}); %#ok<AGROW>
end
spec = wb.spec;
refOff = [spec.V_m3, spec.S_m2, spec.lbar_gas_m, spec.meanChord_4V_over_S_m];
% 打开真剖切 (中心切, d/R=0) -> 必须真的切开补盖面 (显示层), 否则这条断言没意义。
wb.cbClip.Value = true;
wb.cbClip.ValueChangedFcn([], []);
txtOn = wb.labAudit.Text;
numsOn = [];
for tok = regexp(txtOn, '-?\d\.\d+e[-+]\d+', 'match')
    numsOn(end+1) = str2double(tok{1}); %#ok<AGROW>
end
clipTxt = wb.labClip.Text;
clipEngaged = contains(clipTxt, '真剖切已生效');
stateOn = wb.api.state();
tc.verifyTrue(stateOn.clipRequested, 'api.state() 必须实时反映剖切开关 (点击后的值)');
tc.verifyEqual(logical(stateOn.clipped), clipEngaged, ...
    'state.clipped 与面板"真剖切已生效"措辞必须一致 (都由逐零件 cut 计数推出)');
tc.verifyGreaterThan(numel(stateOn.clip.ids), 0, 'state.clip 必须逐零件记录状态');
tc.verifyEqual(numel(stateOn.clip.ids), numel(stateOn.clip.states), ...
    '逐零件状态与明细条数必须一一对应');
% 请求剖切后系统必须诚实回应: 要么真的切开, 要么明说退回原因 (clipVolume 的偏距/多回路
% 档正被并行修改, 中心档当前也可能退回; 两种都要走通, 且都不得改变审计量)。
tc.verifyTrue(clipEngaged || contains(clipTxt, '不可用'), ...
    '请求剖切必须要么切开生效要么诚实退回, 不得静默');
if clipEngaged
    ta = findall(wb.ax);
    tMark = ta(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Text'), ta));
    tc.verifyTrue(any(contains(string({tMark.String}), 'DISPLAY CLIP')), ...
        '剖切生效时画布必须标注 DISPLAY CLIP — 输运几何未变');
end
% 显示层不变量 (与剖切是否成功无关): 读数文本与数值逐个相等。
tc.verifyEqual(txtOn, txtOff, '剖切开/关的审计读数文本必须完全一致');
tc.verifyEqual(numsOn, numsOff, '剖切开/关解析出的审计数值必须逐个相等');
tc.verifyGreaterThanOrEqual(numel(numsOff), 4, '读数里必须能解析出 V/S/lbar/4VS 四个数');
for i = 1:4
    % 读数以 %.6e 显示, 与 spec 双精度真值比对取 1e-6 相对容差 (显示位数决定的下限)。
    tc.verifyEqual(numsOff(i), refOff(i), 'RelTol', 1e-6, ...
        sprintf('读数第 %d 项必须等于 spec 真值 %.6e', i, refOff(i)));
end
end

function test_offset_clip_degrades_honestly(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
% 偏距切 (clipVolume 的偏距/多回路档正被并行修改): 工作台不得崩, 必须给出原因或成功。
wb.cbClip.Value = true;
wb.edD.Value = 0.6;
wb.cbClip.ValueChangedFcn([], []);
txt = wb.labClip.Text;
tc.verifyTrue(contains(txt, '真剖切已生效') || contains(txt, '真剖切当前不可用'), ...
    sprintf('偏距切必须要么成功要么落回透明并说明原因, 实得: %s', txt));
tc.verifyTrue(contains(wb.labAudit.Text, 'm^3'), '退回路径下审计读数仍必须存在');
end

function test_schematic_mode_makes_watermark_text(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
% 水印探测就地内联 (不能写成 1 参局部函数, 否则被当用例收走)。
textsOff = findall(wb.ax);
textsOff = textsOff(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Text'), textsOff));
hasOff = any(contains(string({textsOff.String}), 'NOT TO SCALE'));
tc.verifyFalse(hasOff, '真实比例下不应出现 NOT TO SCALE 水印');
wb.cbSchem.Value = true;
wb.cbSchem.ValueChangedFcn([], []);
textsOn = findall(wb.ax);
textsOn = textsOn(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Text'), textsOn));
hasOn = any(contains(string({textsOn.String}), 'NOT TO SCALE'));
tc.verifyTrue(hasOn, '示意比例档必须产生 NOT TO SCALE 水印文本对象');
end

function test_seven_presets_each_change_camera(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
ax = wb.ax;
cam = zeros(7, 3);
for i = 1:7
    cb = wb.btnCam(i).ButtonPushedFcn;
    cb(wb.btnCam(i), []);           % 真实按下第 i 个预设按钮
    cam(i, :) = ax.CameraPosition;  % UIAxes 不暴露 CameraAzimuth, 用相机位置读回视角
end
u = unique(cam, 'rows', 'stable');
tc.verifyEqual(size(u, 1), 7, ...
    sprintf('七个视角必须产生七个不同相机, 实得 %d 个不同 (az,el) 组合: %s', ...
    size(u, 1), mat2str(cam)));
for i = 2:7
    tc.verifyFalse(isequal(cam(i, :), cam(i - 1, :)), ...
        sprintf('第 %d 个预设相对上一个必须改变相机', i));
end
end

function test_measure_readout_uses_unit_factor(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
% 用 measure 的返回值 (struct) 直接判定, 不经嵌套 state (回调内对 state 的写入不随
% appdata 句柄读回传播)。距离按当前显示单位换算回米。
wb.uu.Value = 'mm';
mMm = wb.api.measure([0 0 0], [10 0 0]);
tc.verifyEqual(mMm.d_m, 1e-2, 'AbsTol', 1e-12, 'mm 档测距换算到米');
tc.verifyEqual(mMm.d_mm, 10, 'AbsTol', 1e-6, 'mm 档显示毫米');
wb.uu.Value = 'um';
mUm = wb.api.measure([0 0 0], [10 0 0]);
tc.verifyEqual(mUm.d_m, 1e-5, 'AbsTol', 1e-15, 'um 档测距换算到米');
tc.verifyEqual(mUm.d_um, 10, 'AbsTol', 1e-6, 'um 档显示微米');
tc.verifySubstring(wb.labMeasure.Text, 'um', '读数标签须反映当前单位');
end

function test_interference_and_tolerance_report_or_error_not_stale(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
cbI = wb.btnI.ButtonPushedFcn;
cbI(wb.btnI, []);
ti = wb.labInterf.Text;
tc.verifyFalse(contains(ti, '未运行'), '点过干涉审计后不得保留"未运行"陈旧占位');
tc.verifyTrue(contains(ti, '判定:') || contains(ti, '失败 ->'), ...
    sprintf('干涉面板必须给判定或错误信息, 实得: %s', ti));
wb.api.runTolerance(4);
tt = wb.labTol.Text;
tc.verifyFalse(contains(tt, '未运行'), '跑过公差蒙卡后不得保留"未运行"陈旧占位');
tc.verifyTrue(contains(tt, '样本 ok=') || contains(tt, '失败'), ...
    sprintf('公差面板必须给出样本数或错误信息, 实得: %s', tt));
end

function test_reset_restores_real_scale_no_watermark(tc)
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
wb.cbSchem.Value = true;
wb.cbClip.Value = true;
wb.uu.Value = 'um';
wb.api.resetView();
tc.verifyFalse(logical(wb.cbSchem.Value), '复位后示意档必须关闭');
tc.verifyFalse(logical(wb.cbClip.Value), '复位后剖切必须关闭');
tc.verifyEqual(char(wb.uu.Value), 'mm', '复位后回到 mm 单位');
texts = findall(wb.ax);
texts = texts(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Text'), texts));
tc.verifyFalse(any(contains(string({texts.String}), 'NOT TO SCALE')), '复位后不得残留示意水印');
end

function test_clip_gate_is_per_part_and_no_noop_success(tc)
% 逐零件核对剖切判定: 面板/状态里的 "cut" 必须与 clipVolume 的 stats 一致 —— 切面没穿过
% 零件要落 plane-misses-part, 穿过了却没改变网格 (面数/盖面数/顶点数全等, |dV|=0) 要落
% failed, 两者都不许被写成"真剖切已生效"。
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
vol = @(V, F) sum(dot(V(F(:, 1), :), cross(V(F(:, 2), :), V(F(:, 3), :)), 2), 'all') / 6;
dvals = {0, 0.45, -0.7};
for q = 1:numel(dvals)
    wb.cbClip.Value = true;
    wb.ddN.Value = 'x';
    wb.edD.Value = dvals{q};
    wb.cbClip.ValueChangedFcn([], []);
    cs = wb.api.state().clip;
    tc.verifyEqual(cs.requested, true, '剖切请求位必须实时可读');
    tc.verifyEqual(numel(cs.ids), numel(cs.states), '逐零件状态与 id 数必须相等');
    tc.verifyGreaterThan(numel(cs.ids), 0, sprintf('d/R=%g 下必须有逐零件判定记录', dvals{q}));
    nCutReported = 0;
    for i = 1:numel(cs.ids)
        id = cs.ids{i};
        st = cs.states{i};
        tc.verifyTrue(any(strcmp(st, {'cut', 'plane-misses-part', 'failed'})), ...
            sprintf('%s 的剖切状态必须是三态之一, 实得 %s', id, st));
        kk = find(strcmp(wb.ids, id), 1);
        Vm = []; Ft = [];
        if ~isempty(kk) && isfield(wb.parts(kk), 'V') && isfield(wb.parts(kk), 'F')
            Vm = double(wb.parts(kk).V); Ft = double(wb.parts(kk).F);
        end
        tc.verifyTrue(~isempty(Vm) && size(Ft, 1) >= 3, ...
            sprintf('%s 必须有展示网格才能核对剖切判定', id));
        nv = sqrt(sum(Vm.^2, 2)); bR = max(nv(:));
        out = tepc.geometry.clipVolume(Vm, Ft, 'Plane', [1 0 0 bR * dvals{q} 0 0], ...
            'Keep', 'normal', 'Cap', 'auto', 'PartID', id);
        misses = logical(out.stats.plane_misses_part);
        changed = (out.stats.n_faces_after ~= out.stats.n_faces_input) || ...
            out.stats.n_cap_faces > 0 || size(out.V, 1) ~= size(Vm, 1);
        dV = abs(abs(out.stats.signed_volume_after_m3) - abs(vol(Vm, Ft)));
        if strcmp(st, 'cut')
            nCutReported = nCutReported + 1;
            tc.verifyTrue(changed && ~misses, ...
                sprintf('%s 被判 cut 但 stats 说没切: misses=%d changed=%d |dV|=%.3e', ...
                id, misses, changed, dV));
            % no-op 的定义: 面数/盖面/顶点三者全等 (此时体积必然没变) —— 绝不能记成成功。
            tc.verifyFalse((~changed) && dV == 0, ...
                sprintf('%s 是 no-op (|dV|=0 且网格没变) 却被判 cut', id));
        else
            usableRes = (size(out.V, 1) >= 3) && (size(out.F, 1) >= 3);
            tc.verifyTrue(misses || (~changed) || (~usableRes), ...
                sprintf('%s 的 stats 说切开了 (faces %d->%d, 盖面 %d, misses=%d) 却报 %s (漏报)', ...
                id, out.stats.n_faces_input, out.stats.n_faces_after, ...
                out.stats.n_cap_faces, misses, st));
        end
        % 每个非 cut 零件都必须在面板上点名 (不允许只报一个整体"不可用")。
        tc.verifyTrue(contains(wb.labClip.Text, [id '[' cs.states{i} ']']), ...
            sprintf('面板状态行必须点名 %s 的三态判定, 实得: %s', id, wb.labClip.Text));
    end
    tc.verifyEqual(logical(cs.engaged), nCutReported > 0, ...
        sprintf('d/R=%g: 只有至少一个零件 cut 才允许声称生效', dvals{q}));
    engagedTxt = contains(wb.labClip.Text, '真剖切已生效');
    tc.verifyEqual(engagedTxt, nCutReported > 0, '面板措辞与 cut 计数必须一致');
    % patch 上的 display_only 必须逐零件, 不能跟装配层走。
    pa = findall(wb.ax);
    pa = pa(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Patch'), pa));
    for j = 1:numel(pa)
        ud = pa(j).UserData;
        tc.verifyEqual(logical(ud.display_only), strcmp(ud.clip_state, 'cut'), ...
            sprintf('%s 的 patch.display_only 必须由它自己的剖切状态决定', ud.part_id));
    end
    % 状态行里"已画"的零件数必须与视口 patch 数一致: 被切面整体移出的零件不许还画着。
    nP = @(ax) nnz(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Patch'), findall(ax)));
    tc.verifyEqual(nP(wb.ax), cs.n_patched, ...
        sprintf('d/R=%g: patch 数 (%d) 必须等于状态行报的已画零件数 (%d)', ...
        dvals{q}, nP(wb.ax), cs.n_patched));
    tc.verifyLessThanOrEqual(nP(wb.ax), cs.n_visible, ...
        '画出来的零件不得超过可见勾选的零件数');
    wb.cbClip.Value = false;
    wb.cbClip.ValueChangedFcn([], []);
end
% 中心切至少要真切开一个零件, 否则上面那一串断言会因"全是 misses"而空转。
wb.cbClip.Value = true; wb.ddN.Value = 'x'; wb.edD.Value = 0;
wb.cbClip.ValueChangedFcn([], []);
tc.verifyGreaterThan(wb.api.state().clip.n_cut, 0, '中心切 (d/R=0) 必须至少切开一个零件');
tc.verifyGreaterThan(wb.api.state().clip.n_patched, 0, '中心切后视口必须有零件被画出来');
end

function test_api_state_and_audit_are_live(tc)
% api 导出的 state/audit 必须是活值: 通过真实控件回调改状态后 api 要跟着变, 跑完蒙卡后
% state.tol 不得还是开窗时的空快照。
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
s0 = wb.api.state();
tc.verifyEqual(s0.units, 'mm', '初始单位 mm');
tc.verifyFalse(logical(s0.schematic), '初始为真实比例');
tc.verifyTrue(isempty(s0.tol), '未跑蒙卡前 tol 为空');
wb.uu.Value = 'um';              wb.uu.ValueChangedFcn([], []);
wb.cbSchem.Value = true;         wb.cbSchem.ValueChangedFcn([], []);
wb.spEx.Value = 0.4;             wb.spEx.ValueChangedFcn([], []);
wb.ddN.Value = 'z';              wb.ddN.ValueChangedFcn([], []);
wb.edD.Value = 0.3;              wb.edD.ValueChangedFcn([], []);
wb.cbClip.Value = true;          wb.cbClip.ValueChangedFcn([], []);
s1 = wb.api.state();
tc.verifyEqual(s1.units, 'um', '单位切换后 api.state() 必须给出当前单位');
tc.verifyEqual(s1.schematic, true, '示意档状态必须实时可读');
tc.verifyEqual(s1.explode, 0.4, 'AbsTol', 1e-9, '爆炸位移必须实时可读');
tc.verifyEqual(s1.plane, 'z', '切面法向必须实时可读');
tc.verifyEqual(s1.overr, 0.3, '偏距必须实时可读');
tc.verifyTrue(s1.clipRequested, '剖切请求位必须实时可读');
spec = wb.spec;
a = wb.api.audit();
tc.verifyEqual(a.V_m3, spec.V_m3, 'RelTol', 1e-12, 'api.audit() 必须是 spec 真值');
tc.verifyEqual(a.meanChord_4V_over_S_m, spec.meanChord_4V_over_S_m, 'RelTol', 1e-12, ...
    'api.audit() 的 4V/S 必须是 spec 真值');
tc.verifyFalse(s1.clip.engaged && ~any(strcmp(s1.clip.states, 'cut')), ...
    'engaged 与逐零件 cut 计数不得自相矛盾');
end

function test_export_keeps_tolerance_panel(tc)
% 导出提示必须落在自己的状态行上: 点导出后公差蒙卡的文本一个字都不许变。
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
wb.api.runTolerance(4);
tolBefore = wb.labTol.Text;
tc.verifyTrue(contains(tolBefore, '蒙卡') || contains(tolBefore, '样本'), ...
    sprintf('跑完蒙卡后面板应有结果文本, 实得: %s', tolBefore));
tc.verifyFalse(contains(tolBefore, '导出'), '蒙卡面板不得混进导出措辞');
cb = wb.btnP.ButtonPushedFcn;
cb(wb.btnP, []);
tolAfter = wb.labTol.Text;
tc.verifyEqual(tolAfter, tolBefore, '导出后公差面板文本必须逐字符不变');
st = wb.api.state();
tc.verifyTrue(contains(wb.labStatus.Text, '视图导出'), ...
    sprintf('导出状态必须落在独立状态行上, 实得: %s', wb.labStatus.Text));
tc.verifyTrue(contains(wb.labStatus.Text, '成功') || contains(wb.labStatus.Text, '失败'), ...
    '导出状态行必须给出成功或失败');
% 状态行与 state 里的路径/错误必须同向, 且 labTol 全程没被碰过 (上面已逐字符比过)。
tc.verifyEqual(~isempty(st.exportPath), contains(wb.labStatus.Text, '成功'), ...
    'exportPath 的有无必须与状态行的成功/失败一致');
tc.verifyEqual(~isempty(st.exportErr), contains(wb.labStatus.Text, '失败'), ...
    'exportErr 的有无必须与状态行的成功/失败一致');
end

function test_interference_failure_is_explained_and_panel_usable(tc)
% overlapCheck 的网格路线本机不通: 面板必须给出失败原因 (而不是陈旧/空表格), 且工作台
% 其余功能照常可用、可重复点击。
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
nP = @(ax) nnz(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Patch'), findall(ax)));
auditBefore = wb.labAudit.Text;
nBefore = nP(wb.ax);
cb = wb.btnI.ButtonPushedFcn;
cb(wb.btnI, []);
ti = wb.labInterf.Text;
st = wb.api.state();
tc.verifyFalse(contains(ti, '运行中'), '点完后不得停在"运行中"占位');
tc.verifyFalse(contains(ti, '未运行'), '点完后不得保留"未运行"陈旧占位');
tc.verifyGreaterThan(numel(strtrim(char(ti))), 20, '面板必须有实质内容而不是空表格');
if contains(ti, '失败')
    % 长度按字符数算: numel(string 标量) 恒为 1, 拿来断言长度是假断言。
    tiFlat = char(join(string(ti).', ' '));
    tiFlat = strtrim(tiFlat);
    marker = '干涉审计: 失败 -> ';
    ix = strfind(tiFlat, marker);
    tc.verifyFalse(isempty(ix), sprintf('失败文本必须带 "-> 原因" 段, 实得: %s', tiFlat));
    reason = '';
    if ~isempty(ix)
        reason = strtrim(tiFlat(ix(1) + numel(marker) : end));
    end
    tc.verifyGreaterThan(numel(reason), 10, ...
        sprintf('失败必须带原因文本而不是光一句"失败", 实得: %s', reason));
    tc.verifyFalse(isempty(st.interfErr), '失败原因必须同时进 state.interfErr');
    tc.verifyTrue(isempty(st.interf), '失败后不得留下半截的陈旧结果表');
end
tc.verifyEqual(wb.labAudit.Text, auditBefore, '干涉算子失败不得污染审计读数');
tc.verifyEqual(nP(wb.ax), nBefore, '干涉算子失败不得改变视口');
cb(wb.btnI, []);          % 再按一次: 面板必须重跑而不是卡死
tc.verifyEqual(wb.api.state().interfRuns, 2, '干涉按钮必须可重复触发 (面板没被卡死)');
wb.api.runTolerance(4);
tc.verifyFalse(contains(wb.labTol.Text, '未运行'), '干涉失败后公差按钮仍要能出结果');
end

function test_scale_bar_agrees_with_watermark_in_schematic(tc)
% 示意档下比例尺不许冒充物理长度 (否则画布说 NOT TO SCALE、标尺说 50 µm 自相矛盾)。
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
% 句柄在下次 redraw (cla) 后就失效: 文本必须当场取成 char, 不能留着句柄事后读。
tReal = findall(wb.ax, 'Tag', 'tepcScaleBarLabel');
tc.verifyEqual(numel(tReal), 1, '真实比例下必须有且只有一个比例尺标签');
sReal = '';
if ~isempty(tReal), sReal = char(string(tReal(1).String)); end
tc.verifyFalse(contains(sReal, '非物理长度'), ...
    sprintf('真实比例下比例尺不该自称示意段: %s', sReal));
tc.verifyTrue(any(contains(sReal, {'mm', 'um'})), ...
    sprintf('真实比例下比例尺必须给出物理长度: %s', sReal));
wb.cbSchem.Value = true;
wb.cbSchem.ValueChangedFcn([], []);
tSch = findall(wb.ax, 'Tag', 'tepcScaleBarLabel');
tc.verifyEqual(numel(tSch), 1, '示意档下比例尺标签仍必须存在 (不能被悄悄删掉)');
sSch = '';
if ~isempty(tSch), sSch = char(string(tSch(1).String)); end
tc.verifyTrue(contains(sSch, '非物理长度'), ...
    sprintf('示意档下比例尺必须声明不是物理长度, 实得: %s', sSch));
tc.verifyNotEqual(sSch, sReal, '两档的比例尺文案必须真的不同');
ta = findall(wb.ax);
tx = ta(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Text'), ta));
tc.verifyTrue(any(contains(string({tx.String}), 'NOT TO SCALE')), ...
    '示意档比例尺改口的同时水印必须在, 两者口径一致');
end

function test_hidden_all_clip_note_gives_reason(tc)
% 全隐藏 + 开着剖切: 状态行不能写成 "真剖切当前不可用 -> (空)", 必须说是没有可见零件。
fig = openWB();
cleanupObj = onCleanup(@() delete(fig));
wb = getappdata(fig, 'wb');
nP = @(ax) nnz(arrayfun(@(o) isa(o, 'matlab.graphics.primitive.Patch'), findall(ax)));
wb.cbClip.Value = true;
wb.cbClip.ValueChangedFcn([], []);
for k = 1:numel(wb.cbParts)
    wb.cbParts(k).Value = false;
end
wb.cbParts(1).ValueChangedFcn([], []);
tc.verifyEqual(nP(wb.ax), 0, '全隐藏后不得有 patch');
txt = wb.labClip.Text;
tc.verifyTrue(contains(txt, '没有可见零件'), ...
    sprintf('全隐藏时状态行必须说明是显隐导致的, 实得: %s', txt));
tc.verifyFalse(contains(txt, '->  '), '不得留下空原因 (指向空白的原因串)');
tc.verifyEqual(wb.api.state().clip.n_visible, 0, 'state 必须如实报可见数为 0');
wb.cbParts(3).Value = true;
wb.cbParts(3).ValueChangedFcn([], []);
tc.verifyEqual(wb.api.state().clip.n_visible, 1, '再显示一个零件后可见数必须跟上');
tc.verifyFalse(contains(wb.labClip.Text, '没有可见零件'), '有可见零件后不得再报无零件');
end

function test_gridlayout_rows_all_fit_in_window(tc)
% 行高是**声明值**, uigridlayout 不会因为"声明和 > 容器高"报错 —— 它把多出来的行整行推到
% 可视区之外。实测缺陷态: 右面板 13 行声明和 782, 加行距 48 + 上下内边距 16 = 需 846 px,
% 而 1300x800 窗口里可用只有 758 px ⇒ "导出当前视图 PNG"按钮与它下面的导出状态行整行不可见
% (用户看不见也就点不到)。这条锁量的是真实像素布局, 不读实现自己写的常数, 所以不是镜像判据。
%
% 三个必须一起成立的条件, 缺一条这条锁就退化成装饰:
%   (1) 真实布局下所有格栅的子控件都完整落在父格栅可视区内 (正控);
%   (2) 把右面板行高临时换回缺陷态旧向量, 同一段检查必须报出 >=1 个越界 (判据自带反例);
%   (3) 必须先证明布局真的算过: 'Visible',false 时 MATLAB 不做布局, 栅格高停在默认 100、
%       子控件停在默认 [100 100 31 22] (本机实测), 拿那种状态量越界会恒绿。
fig = TEPC3DWorkbench(demoCfg(), 'Visible', true);
cleanupObj = onCleanup(@() delete(fig));
drawnow; pause(0.9); drawnow;
g = findall(fig, 'Type', 'uigridlayout');
tc.verifyGreaterThan(numel(g), 2, sprintf('只找到 %d 个格栅, 面板结构不像建起来了', numel(g)));
outN = @(pg) sum(arrayfun(@(k) (k.Position(2) < -0.5) || ...
    (k.Position(2) + k.Position(4) > pg.Position(4) + 0.5), pg.Children));
rg = [];
for i = 1:numel(g)
    if numel(g(i).RowHeight) == 13
        rg = g(i);
    end
end
tc.verifyFalse(isempty(rg), ...
    '没找到 13 行的右面板: 面板行数改了要同步改这条锁的认面板方式');
if isempty(rg)
    return
end
% 布局是异步的: 同一次 runtests 里前一个用例的收尾会挤掉这一次, 单次 pause(0.9) 实测不够
% (面板停在默认 100 px, 这条锁当场红; 单独跑同一用例则 758 px 绿)。改成**有界**轮询而不是
% 加大固定 sleep —— 等不到仍然按"布局没算"红, 不会把量不到写成通过。
% 上限用**帧数 + 墙钟双限**: 只给墙钟时, 慢主机上 6 s 到点就把"环境忙"报成"实现错"
% (本机实测过: 两个父进程已死的孤儿 MATLABWindow 空转, 把这个文件的耗时从 65.8 s 顶到 2044.6 s)。
% 帧数上限保证 drawnow 卡住时也不会无限转; 两条中任一条到限就停, 判据不变。
% 红的时候把**主机读数**一起报出来 (此刻的 CPU 节拍 / 还开着的 figure 数 / 有几个格栅脱离了默认高),
% 这样"布局永远不算"与"这轮跑太挤"分得开, 不用靠人再复现一遍。
maxFrames = 240; maxSec = 60;
tWait = tic; frames = 0;
while rg.Position(4) <= 400 && frames < maxFrames && toc(tWait) < maxSec
    drawnow; pause(0.05); frames = frames + 1;
end
rgH = rg.Position(4);
elW = toc(tWait);
if rgH <= 400
    tRef = tic; xh = sum(rand(1, 2e6)); refMs = toc(tRef) * 1000; %#ok<NASGU>
    nRealized = nnz(arrayfun(@(h) h.Position(4) > 100, g));
    msg = sprintf(['右面板高只有 %.1f px: 布局没算 (窗口必须 Visible=true), 这条锁此刻是恒绿的。' ...
        '等待 %d 帧 / %.1f s (上限 %d 帧 / %d s); 本会话还开着 %d 个 figure; ' ...
        '%d/%d 个格栅脱离了默认高度; 此刻主机节拍 %.1f ms (2e6 次 rand 求和)'], ...
        rgH, frames, elW, maxFrames, maxSec, numel(findall(0, 'Type', 'figure')), ...
        nRealized, numel(g), refMs);
else
    msg = sprintf('右面板高 %.1f px (等 %d 帧 / %.1f s)', rgH, frames, elW);
end
tc.verifyGreaterThan(rgH, 400, msg);
old = {30, 108, 80, 26, 96, 26, 126, 76, 86, 28, 28, 28, 44};   % 缺陷态 (声明和 782)
keep = rg.RowHeight;
states = {keep, old};
nTrip = zeros(1, 2);
for s = 1:2
    rg.RowHeight = states{s};
    drawnow; pause(0.6); drawnow;
    tot = 0;
    for i = 1:numel(g)
        tot = tot + outN(g(i));
    end
    nTrip(s) = tot;
end
rg.RowHeight = keep;
drawnow;
% (1) 正控
tc.verifyEqual(nTrip(1), 0, sprintf( ...
    '真实布局下有 %d 个控件被推到父格栅可视区外 (整行不可见): 行高声明和超过窗口可用高', nTrip(1)));
% (2) 反例: 判据必须能抓到已知缺陷态
tc.verifyGreaterThan(nTrip(2), 0, sprintf( ...
    ['判据自身失效: 换回已知缺陷态行高 (声明和 782 / 需 846 > 可用 758, 实测越界 2 个) ' ...
     '仍然报 %d —— 说明布局没算或认面板认错了, 这条锁是恒绿装饰'], nTrip(2)));
end

