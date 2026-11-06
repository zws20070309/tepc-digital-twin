function tests = test_gui_chip_band
%TEST_GUI_CHIP_BAND 界面交互壳 (tests_ui) 的真实控件用例。
%   这一层与 tests/unit 的差别: 用例必须在**已 realize 的 uifigure** 里跑,
%   断言对象是窗口上的控件本身 (findall 全量取回后按 isa 筛), 而不只是组件属性。
%   用例收集口径: 只有 test 开头、单入参 tc 的函数被收; 助手一律不带 tc 形参。
%   实测: 函数式用例拿到的 tc 是 matlab.unittest.FunctionTestCase, 它没有 addCleanup
%   (抛 MATLAB:noSuchMethodOrField), 所以窗口销毁走 onCleanup 局部变量。
%
%   为什么不是 'TestType','uitest': 本机 matlab -batch 下 uitest 夹具起不来
%   (同一份用例按 functiontests(...,'TestType','uitest') 建套件后实测
%   pass=0 / fail=2 / inc=2, 两个用例都在夹具阶段就没了), 而 runUiTests 的
%   "收不到用例/跑了但没通过"都必须能被区分出来。所以这里用普通 TestCase +
%   无头 uifigure + 显式调回调驱动真实控件 (无头窗口里改 .Value 不触发
%   ValueChangedFcn, 显式调它同时也是"控件已接线"的证明)。
tests = functiontests(localfunctions);
end

function test_chip_band_text_and_control_stay_in_sync(tc)
%   状态带的硬约定: Chip.Text 与 Chip.Label.Text 必须同时由 setText 写入。
%   只声明属性不写控件时属性会永远停在空串, 读它的测试与禁语扫描会一路放行。
fig = uifigure('Visible', 'off');
cleanupObj = onCleanup(@() closeFig(fig));
g = uigridlayout(fig, [2, 1]);
band1 = cell(1, 3);
band1{1} = '模式'; band1{2} = '交互'; band1{3} = 'MEASURED';
band2 = cell(1, 3);
band2{1} = '后端'; band2{2} = ''; band2{3} = 'NOT_AVAILABLE';
chips = StatusChip.band(g, [band1; band2]);
tc.verifyEqual(numel(chips), 2, '状态带要按行数建满, 少一个席位就少一项可见判定');
s1 = chips{1}.state();
s2 = chips{2}.state();
tc.verifyEqual(s1.value, '交互');
tc.verifyEqual(s1.in_sync, true, sprintf('实得 label=[%s] text=[%s]', s1.label_text, s1.text));
tc.verifyEqual(s2.value, '未取数', '空值必须显示未取数, 不显示空串也不显示 0');
tc.verifyEqual(s2.in_sync, true);
baseErr = numel(s1.errors);
% 控件发现口径: findall(fig,'Type','label') / 'uicontrol' 在本机静默给 0 个
labels = pickByClass(fig, 'matlab.ui.control.Label');
tc.verifyGreaterThanOrEqual(numel(labels), 2, ...
    sprintf('窗口上应能看到两个胶囊标签, 实得 %d', numel(labels)));
% labels 是句柄数组而不是元胞: cellfun 会抛 MATLAB:cellfun:NotACell, 只能逐个取
shown = strings(0, 1);
for i = 1:numel(labels)
    shown(end+1, 1) = string(labels(i).Text); %#ok<AGROW>
end
tc.verifyEqual(any(shown == string(chips{1}.Text)), true, ...
    sprintf('胶囊文本 %s 必须真的出现在窗口控件上', chips{1}.Text));
% 改写值后控件必须跟着改: 只改属性不改控件是这条约定的另一半
chips{2}.setText('HDF5');
tc.verifyEqual(chips{2}.Label.Text, chips{2}.Text);
tc.verifyEqual(chips{2}.state().in_sync, true);
% 构造期是否自带错误条目由 test_gui_components 专门锁 (本机 uilabel 不支持 EdgeColor);
%   这里只要求 setText 不再新增错误条目。
tc.verifyEqual(numel(chips{2}.state().errors), baseErr, ...
    sprintf('改写值不得新增错误条目 (%d -> %d)', baseErr, numel(chips{2}.state().errors)));
% 负对照: 直接改控件 (绕过 setText) 会让 in_sync 报 false, 上面的断言不是恒真
chips{1}.Label.Text = '被人手动改过的文本';
tc.verifyEqual(chips{1}.state().in_sync, false, ...
    'in_sync 必须能抓到"控件与属性分叉", 否则它是个常量');
end

function test_param_card_editor_callback_round_trip(tc)
%   卡片在真实窗口里: 控件类、可见性、回调链路都要能在窗口层面被读到。
fig = uifigure('Visible', 'off');
cleanupObj = onCleanup(@() closeFig(fig));
g = uigridlayout(fig, [4, 1]);
card = ParameterCard(g, struct('Tag', 'WIDTH', 'Kind', 'num', 'Unit', 'mm', ...
    'Min', 0, 'Max', 100, 'Step', 2, 'Value', 42, 'ValueStatus', 'MEASURED'), ...
    struct('Layout', 'compact', 'EditorFlavor', 'text'));
card.place(1, 1, 1);
ed = pickByClass(fig, 'matlab.ui.control.EditField');
tc.verifyGreaterThanOrEqual(numel(ed), 1, '文本承载格必须真的在窗口上');
tc.verifyEqual(double(card.Editor), double(ed(1)), '卡片持有的控件与窗口上的应是同一个');
tc.verifyEqual(card.value(), 42);
vis = card.visibleState();
tc.verifyEqual(vis.editor, 1, sprintf('未折叠时编辑框必须可见, 实得 %d', vis.editor));
tc.verifyTrue(vis.row_height > 0, sprintf('父网格行高必须已展开, 实得 %g', vis.row_height));
% 回调链路: 控件 -> 卡片 -> 挂载点 (无头窗口里只能显式调, 这一调也证明已接线)
tc.verifyFalse(isempty(card.Editor.ValueChangedFcn));
seen = [];
card.OnChange = @(evt) setappdata(0, 'tepc_ui_case_evt', evt.value);
setappdata(0, 'tepc_ui_case_evt', NaN);
card.Editor.Value = '55';
card.Editor.ValueChangedFcn([], []);
tc.verifyEqual(card.state().changes, 1);
tc.verifyEqual(getappdata(0, 'tepc_ui_case_evt'), 55, ...
    '挂载点收到的必须是解析后的数值, 不是控件里的原始字符');
% 负对照: 程序回填不得走同一条上报路径
card.writeValue('61');
tc.verifyEqual(card.state().changes, 1, '回填不得被当成用户输入');
tc.verifyEqual(card.value(), 61);
tc.verifyEqual(getappdata(0, 'tepc_ui_case_evt'), 55, '回填不得改挂载点收到的值');
% 折叠: 六个子控件一起隐, 本行行高归 0 (否则留一条点不到的空白)
card.setCollapsed(true);
vis2 = card.visibleState();
tc.verifyEqual(vis2.editor, 0);
tc.verifyEqual(vis2.label, 0);
tc.verifyEqual(vis2.row_height, 0);
tc.verifyEqual(card.collapsed(), true);
card.setCollapsed(false);
vis3 = card.visibleState();
tc.verifyEqual(vis3.editor, 1);
tc.verifyTrue(vis3.row_height > 0);
rmappdata(0, 'tepc_ui_case_evt');
delete(card);
end

function objs = pickByClass(fig, cls)
%PICKBYCLASS 全量 findall 后按 isa 筛。
%   实测本机: findall(fig,'Type','button') / 'uicontrol' / 'class',x 一律静默返回 0,
%   findall(fig,'-recursive',...) 抛 MATLAB:findall:InvalidParameter。
all = findall(fig);
objs = all(arrayfun(@(o) isa(o, cls), all));
end

function closeFig(fig)
try
    if isvalid(fig)
        delete(fig);
    end
catch
    % 清理路径不得抛错: 析构抛错会被吞掉并污染退出码
end
end
