function tests = test_gui_components
%TEST_GUI_COMPONENTS 四个 GUI 展示件的公开面 (AppState 在 test_gui_state.m)。
%   每个组件三类断言: (a) 构造, (b) 可观测输出 (返回结构体字段 / 控件 .Text /
%   抛出 identifier), (c) 负对照 —— 故意喂坏输入, 断言文档写明的拒绝确实发生,
%   否则 (b) 可能只是脚手架自证。
%   本机控件口径 (实测): findall(fig,'Type','button') 静默给 0 个、
%   findall(fig,'-recursive',...) 抛 MATLAB:findall:InvalidParameter;
%   只能全量 findall(fig) 再按 isa 筛。无头 uifigure 里改 .Value 不触发
%   ValueChangedFcn, 所以"控件已接线"只能靠显式调回调来证。
%   handle 类的 delete(obj) 会让对象本身失效, 因此"控件被销毁"这条路径
%   用 delete(chip.Label) 造, 不用 chip.delete()。
%   本文件自己把 app/components 挂上路径 (ensureGuiPath): addpath(app) 只覆盖一层,
%   缺这一条时四个组件在运行时都找不到, 整个文件 0/22 且首条错误只说"未定义函数"。
ensureGuiPath();
tests = functiontests(localfunctions);
end

% ===================== ParameterCard =====================

function test_parameter_card_construction_two_flavors(tc)
[fig, g, keepFig] = newGrid();
num = ParameterCard(g, struct('Tag','A1','Kind','num','Unit','mm','Min',10, ...
    'Max',100,'Value',42), struct('EditorFlavor','numeric'));
txt = ParameterCard(g, struct('Tag','A2','Kind','num','Unit','mm','Min',10, ...
    'Max',100,'Value',42), struct('EditorFlavor','text'));
sN = num.state(); sT = txt.state();
tc.verifyEqual(sN.tag, 'A1');
tc.verifyEqual(sT.tag, 'A2');
tc.verifyEqual(sN.editor_flavor, 'numeric');
tc.verifyEqual(sT.editor_flavor, 'text');
tc.verifyEqual(sN.uses_numeric_editor, true);
tc.verifyEqual(sT.uses_numeric_editor, false, ...
    'EditorFlavor=''text'' 必须真的换掉承载控件');
% 负对照: 两档拿到的是不同控件类, 说明 flavor 不是"存了个字段但没生效"
tc.verifyEqual(class(num.Editor), 'matlab.ui.control.NumericEditField', ...
    sprintf('数值档控件类实得 %s', class(num.Editor)));
tc.verifyEqual(class(txt.Editor), 'matlab.ui.control.EditField', ...
    sprintf('文本档控件类实得 %s', class(txt.Editor)));
tc.verifyEqual(num.Min, 10);
tc.verifyEqual(num.Max, 100);
tc.verifyTrue(sN.open_height > 0, sprintf('open_height 实得 %g', sN.open_height));
tc.verifyEqual(sN.n_issues, 0);
tc.verifyEqual(numel(sN.property_errors), 0, ...
    sprintf('构造期不得留属性错误: %s', strjoin(sN.property_errors, ' | ')));
tc.verifyFalse(isempty(sN.badge_text), '徽标必须带文字通道, 不能只靠颜色');
tc.verifyEqual(num.Unit, 'mm');
% 徽标三通道跟着来源状态走: ASSUMED 与 MEASURED 的文字必须不同
c2 = ParameterCard(g, struct('Tag','A3','Kind','num','ValueStatus','MEASURED'), ...
    struct('EditorFlavor','text'));
tc.verifyNotEqual(c2.state().badge_text, sN.badge_text, ...
    '不同来源状态必须给出不同的徽标文字, 否则只剩颜色一个通道');

end

function test_parameter_card_bad_editor_flavor_is_rejected(tc)
%   未知 flavor 必须当场报错而不是悄悄退回缺省档 —— 退回会让调用方以为选项生效了。
[fig, g, keepFig] = newGrid();
for bad = {'number', 'txt', ' Text ', 'numberic'}
    f = bad{1};
    tc.verifyError(@() ParameterCard(g, struct('Tag','F','Kind','num'), ...
        struct('EditorFlavor', f)), 'tepc:gui:BadEditorFlavor', ...
        sprintf('EditorFlavor=''%s'' 必须被拒', f));
end
% 归一化范围只有大小写 (本机实现不 trim), 空串走类内缺省
c2 = ParameterCard(g, struct('Tag','F2','Kind','num'), struct('EditorFlavor','TEXT'));
tc.verifyEqual(c2.EditorFlavor, 'text');
c3 = ParameterCard(g, struct('Tag','F3','Kind','num'), struct('EditorFlavor',''));
tc.verifyEqual(c3.EditorFlavor, 'numeric', '空 flavor 按缺省处理, 不报错');
% 拒绝必须是"具名 + 点名收到值"的拒绝: 只断言"抛了东西"会让任何一条无关错误跑绿
hit = false; id = ''; ms = '';
try
    ParameterCard(g, struct('Tag','F4','Kind','num'), struct('EditorFlavor','number'));
catch e
    hit = true; id = e.identifier; ms = e.message;
end
tc.verifyTrue(hit, 'EditorFlavor=''number'' 必须当场抛错, 不许静默退回缺省档');
tc.verifyEqual(id, 'tepc:gui:BadEditorFlavor', sprintf('实得标识符 <%s>', id));
tc.verifyTrue(contains(string(ms), 'number'), ...
    sprintf('错误文本要点名被拒的值, 实得: %s', ms));
tc.verifyTrue(contains(string(ms), 'numeric') && contains(string(ms), 'text'), ...
    sprintf('错误文本要给出合法取值, 实得: %s', ms));
delete(c2); delete(c3);
end

function test_components_resolve_to_the_repo_copy(tc)
%   本文件所有断言都建立在"解析到的是仓库自己那一份组件"上: 同名旧副本 (缺 flavor
%   校验的那一类) 排在路径前面时, 坏选项会被静默收下, 用例于是跑在另一份代码上。
    w = which('ParameterCard');
    tc.verifyFalse(isempty(w), 'app/components 必须由本文件自己挂上路径');
    tc.verifyEqual(fileparts(w), fullfile(projectRoot(), 'app', 'components'), ...
        sprintf('实得 %s', w));
    txt = readUtf8Own(w);
    tc.verifyTrue(contains(txt, 'BadEditorFlavor'), ...
        '解析到的这份必须真的带 EditorFlavor 校验 (旧副本没有)');
    tc.verifyFalse(isempty(which('EvidencePanel')), 'EvidencePanel 也要能解析到');
end

function test_parameter_card_other_construction_gates(tc)
tc.verifyError(@() ParameterCard([], struct('Tag','X','Kind','num')), ...
    'tepc:gui:NoParent');
[fig, g, keepFig] = newGrid();
% 没有 Tag 的卡无法被映射表寻址 -> 必须拒绝而不是建出一张无名卡
tc.verifyError(@() ParameterCard(g, struct('Kind','num')), 'tepc:gui:BadSpec');
tc.verifyError(@() ParameterCard(g, struct('Tag','U','Kind','num'), ...
    struct('UnitMode','nope')), 'tepc:gui:BadUnitMode');

end

function test_parameter_card_text_flavor_roundtrips_numeric_string(tc)
%   出厂应用全部按 'text' 建卡 (TEPCApp.addParamCard), 因为数值承载格装不下
%   回填用的字符。这条锁的就是那个理由本身: 文本档必须能原样吃进数字样字符串。
[fig, g, keepFig] = newGrid();
card = ParameterCard(g, struct('Tag','RT','Kind','num','Unit','mm','Min',0, ...
    'Max',1000,'Value',77), struct('EditorFlavor','text'));
tc.verifyEqual(card.value(), 77, '缺省值 77 必须能被读回成数值');
tc.verifyTrue(ischar(card.Editor.Value) || isstring(card.Editor.Value), ...
    sprintf('文本档控件里必须存字符, 实得 %s', class(card.Editor.Value)));
ok = card.writeValue('88.5');
tc.verifyEqual(ok, true);
tc.verifyEqual(card.value(), 88.5);
tc.verifyEqual(strtrim(string(card.Editor.Value)), "88.5", ...
    sprintf('回填串必须原样落在控件里, 实得 <%s>', card.Editor.Value));
tc.verifyEqual(card.state().value, 88.5);
tc.verifyEqual(numel(card.PropertyErrors), 0, ...
    sprintf('合法回填不得留痕: %s', strjoin(card.PropertyErrors, ' | ')));
% 负对照: 非有限 / 不可解析必须被拒并点名 Tag, 而不是悄悄写 0
tc.verifyEqual(card.writeValue(NaN), false, 'NaN 必须被拒绝');
tc.verifyEqual(card.writeValue('不是数'), false, '不可解析文本必须被拒绝');
e = card.state().property_errors;
tc.verifyEqual(numel(e), 2, sprintf('被拒的写值要留痕, 实得 %d 条: %s', ...
    numel(e), strjoin(e, ' | ')));
tc.verifyEqual(nnz(cellfun(@(x) contains(string(x), 'RT'), e)), 2, ...
    '留痕必须点出是哪个 Tag 被拒');
tc.verifyEqual(card.value(), 88.5, '被拒之后上一个好值必须还在');
delete(card);
end

function test_parameter_card_numeric_editor_rejects_char(tc)
%   主机行为: uieditfield('numeric') 的 .Value 只接数值, 赋字符抛
%   MATLAB:ui:NumericEditField:invalidValue。组件 writeValue 走 asNumber 换算,
%   所以数字样字符串能写进去 —— 这里同时锁住这两条边界, 并锁住"换算失败必留痕"。
[fig, g, keepFig] = newGrid();
card = ParameterCard(g, struct('Tag','NN','Kind','num','Value',5, ...
    'Min',0,'Max',100), struct('EditorFlavor','numeric'));
tc.verifyError(@() assignCharToEditor(card), 'MATLAB:ui:NumericEditField:invalidValue', ...
    '数值承载格直接赋字符必须被本机拒绝');
before = numel(card.PropertyErrors);
tc.verifyEqual(card.writeValue('77'), true);
tc.verifyEqual(numel(card.PropertyErrors), before, ...
    '换算成功时不得留下错误痕迹 (否则错误列表失去信号量)');
tc.verifyEqual(card.value(), 77);
tc.verifyEqual(card.Editor.Value, 77, '数值档控件里存的必须是数值本身');
% 负对照: 换算不了的字符必须被拒 + 留痕, 不能静默当成 0
tc.verifyEqual(card.writeValue('7x7'), false);
tc.verifyEqual(numel(card.PropertyErrors), before + 1);
tc.verifyEqual(card.value(), 77, '非法写值后旧值必须保留');
% 步长只有 uispinner 认 (uieditfield 没有 Step 属性)
sp = ParameterCard(g, struct('Tag','SS','Kind','num','Step',2,'Min',0,'Max',10, ...
    'Value',4), struct('EditorFlavor','numeric'));
tc.verifyEqual(class(sp.Spinner), 'matlab.ui.control.Spinner');
tc.verifyEqual(sp.Spinner.Step, 2);
tc.verifyEqual(sp.Spinner.Value, 4);
sp.syncSpinner();
tc.verifyEqual(sp.Spinner.Value, 4);
delete(card); delete(sp);
end

function test_parameter_card_change_mount_is_wired(tc)
%   无头 uifigure 里改 .Value 不触发 ValueChangedFcn, 所以只能显式调回调 ——
%   这一调同时也证明了控件确实挂上了回调。
[fig, g, keepFig] = newGrid();
card = ParameterCard(g, struct('Tag','EV','Kind','num','Value',1), ...
    struct('EditorFlavor','text'));
tc.verifyFalse(isempty(card.Editor.ValueChangedFcn), '控件必须挂 ValueChangedFcn');
tc.verifyEqual(card.state().changes, 0);
card.Editor.ValueChangedFcn([], []);
tc.verifyEqual(card.state().changes, 1, ...
    '回调被调用一次 -> 改动计数必须 +1 (证明控件与卡片确实接线)');
% 负对照: writeValue 是程序回填, 不得被当成用户输入
c0 = card.state().changes;
card.writeValue(9);
tc.verifyEqual(card.state().changes, c0, '回填不得计入用户改动');
tc.verifyEqual(card.value(), 9);
% 负对照 2: 未挂 OnChange 时改动仍计数、也不抛错
delete(card);
card2 = ParameterCard(g, struct('Tag','EV2','Kind','num','Value',1), ...
    struct('EditorFlavor','text'));
card2.Editor.ValueChangedFcn([], []);
tc.verifyEqual(card2.state().changes, 1);
delete(card2);
end

function test_parameter_card_issues_and_filter(tc)
[fig, g, keepFig] = newGrid();
card = ParameterCard(g, struct('Tag','IS','Kind','num','Value',1, ...
    'ValueStatus','ASSUMED'), struct('EditorFlavor','text'));
tc.verifyEqual(card.isAssumed(), true);
tc.verifyEqual(card.matchesFilter('assumed'), true);
tc.verifyEqual(card.matchesFilter('issue'), false);
card.showIssues({struct('level','error','code','RANGE','message','超出范围','tag','IS')});
tc.verifyEqual(card.issueCount(), 1);
tc.verifyEqual(card.matchesFilter('issue'), true);
hint = card.state().hint_text;
tc.verifyTrue(contains(string(hint), 'RANGE'), ...
    sprintf('提示行必须带问题码: %s', hint));
tc.verifyTrue(contains(string(hint), '超出范围'), ...
    sprintf('提示行必须带问题原文: %s', hint));
card.clearIssues();
tc.verifyEqual(card.issueCount(), 0);
tc.verifyEqual(card.matchesFilter('issue'), false);
% 负对照: 未知筛选模式当场拒绝, 不静默当成 all
tc.verifyError(@() card.matchesFilter('maybe'), 'tepc:gui:BadFilterMode');
delete(card);
end

% ===================== StatusChip =====================

function test_status_chip_construction_and_unmeasured_word(tc)
[fig, g, keepFig] = newGrid();
chip = StatusChip(g, '后端', 'MATLAB', 'MEASURED');
s = chip.state();
tc.verifyEqual(s.key, '后端');
tc.verifyEqual(s.value, 'MATLAB');
tc.verifyEqual(s.status, 'MEASURED');
tc.verifyEqual(s.in_sync, true, 'Text 与控件 Text 必须同时被写入');
tc.verifyEqual(strtrim(string(chip.Label.Text)), strtrim(string(chip.Text)));
empty1 = StatusChip(g, '位点', '');
tc.verifyEqual(empty1.state().value, '未取数');
empty1.setText('');
tc.verifyEqual(empty1.state().value, '未取数');
tc.verifyFalse(contains(empty1.state().text, '0'), '缺数不得被显示成 0');
% 负对照: 状态词缺省走 UNKNOWN, 不借用通过色
noStatus = StatusChip(g, '哈希', 'abc', '');
tc.verifyEqual(noStatus.state().status, 'UNKNOWN');
bare = StatusChip(g, 'x', 'y');
tc.verifyEqual(bare.state().status, 'UNKNOWN');
tc.verifyEqual(bare.state().clicks, 0);

end

function test_status_chip_click_mount(tc)
[fig, g, keepFig] = newGrid();
box = counter(fig, 'chip');
chip = StatusChip(g, '未关闭阻塞项', '3', 'PARTIAL', ...
    struct('OnClick', @(evt) bump(box, evt.key)));
% 构造期已有的错误条目作基线: 胶囊一出生就带一条 EdgeColor 噪声 (另一条用例锁它),
% 这里只关心"点击路径新增了几条"。
base = numel(chip.Errors);
tc.verifyEqual(chip.click(), true);
tc.verifyEqual(chip.Clicks, 1);
tc.verifyEqual(getCount(box), 1, 'OnClick 挂载点必须真的被调用');
tc.verifyEqual(chip.state().clicks, 1);
% 负对照: 摘掉挂载点后点击不记账、也不抛错 —— 上一条断言因此不是脚手架造的
chip.OnClick = [];
tc.verifyEqual(chip.click(), true);
tc.verifyEqual(getCount(box), 1, '无挂载点时不得新增计数');
% 负对照 2: 挂载点抛错时进 Errors 而不是冲出 GUI 路径
chip.OnClick = @(evt) error('tepc:test:Chip', '挂载点炸了');
threw = false;
try
    chip.click();
catch
    threw = true;
end
tc.verifyFalse(threw, '点击路径不得把挂载点异常抛给界面');
s = chip.state();
tc.verifyEqual(numel(s.errors), base + 1, ...
    sprintf('挂载点异常必须再留一条痕 (基线 %d, 现 %d): %s', base, numel(s.errors), strjoin(s.errors,' | ')));
tc.verifyTrue(contains(string(s.errors{end}), '挂载点炸了'), ...
    sprintf('留痕必须带上根因文本: %s', s.errors{end}));
tc.verifyTrue(contains(string(s.errors{end}), '未关闭阻塞项'), ...
    sprintf('留痕必须点出胶囊名: %s', s.errors{end}));
delete(chip);
end

function test_status_chip_recorded_errors_are_exposed_by_state(tc)
%   "记了但从不暴露"是静默失败陷阱: 这里断言 Errors 与 state().errors 同源。
[fig, g, keepFig] = newGrid();
chip = StatusChip(g, '模式', '交互', 'MEASURED');
s0 = chip.state();
tc.verifyEqual(numel(s0.errors), 0, sprintf(['构造后的错误列表必须是空的, 实得 %d 条: %s —— ' ...
    'StatusChip 往 uilabel 上写了本机不支持的属性, 每个胶囊一出生就自带一条噪声, ' ...
    '真故障会被它埋掉'], numel(s0.errors), strjoin(s0.errors, ' | ')));
delete(chip.Label);           % 控件没了: refresh 必须留痕而不是静默
chip.setText('第二轮');
s = chip.state();
tc.verifyGreaterThanOrEqual(numel(s.errors), 1, ...
    '控件销毁后写控件失败必须进 Errors');
tc.verifyEqual(numel(s.errors), numel(chip.Errors), ...
    'state().errors 必须与内部 Errors 同长度 (否则暴露的是另一份拷贝)');
tc.verifyEqual(numel(s.errors), numel(s0.errors) + 1, ...
    sprintf('控件销毁后必须新增一条留痕 (前 %d 后 %d)', numel(s0.errors), numel(s.errors)));
tc.verifyTrue(contains(string(s.errors{end}), '模式'), ...
    sprintf('留痕必须点出胶囊名, 实得: %s', s.errors{end}));
tc.verifyTrue(contains(string(s.errors{end}), 'refresh'), ...
    sprintf('留痕必须点出出错位置, 实得: %s', s.errors{end}));
% 文本逻辑仍要正确: 窗口已关不等于 setText 没生效
tc.verifyEqual(s.value, '第二轮');
tc.verifyEqual(s.label_text, '', '控件没了时 label_text 必须是空串而不是旧文本');
tc.verifyEqual(s.in_sync, false, '控件销毁后 in_sync 必须报 false, 不得假装同步');
delete(chip);
end

function test_status_chip_band_keeps_all_seats(tc)
[fig, g, keepFig] = newGrid();
chips = StatusChip.band(g, StatusChip.defaultSpecs());
tc.verifyEqual(numel(chips), 6, '缺省席位是显示契约: 六个');
names = cellfun(@(c) c.state().key, chips, 'UniformOutput', false);
tc.verifyEqual(strjoin(names, '|'), ...
    '模式|后端|配置哈希|位点|未关闭阻塞项|是否允许发布');
for i = 1:numel(chips)
    tc.verifyEqual(chips{i}.state().value, '未取数', sprintf('%d 号席位初值', i));
end
tc.verifyEqual(numel(strfind(StatusChip.allText(chips), '未取数')), 6, ...
    sprintf('六个空席位都要显式写未取数: %s', StatusChip.allText(chips)));
% 负对照: 描述形状不对必须报错, 而不是建出半个带
tc.verifyError(@() StatusChip.band(g, 7), 'tepc:gui:BadChipSpec');
tc.verifyError(@() StatusChip([], 'x', 'y'), 'tepc:gui:NoParent');
band1 = cell(1,3); band1{1}='模式'; band1{2}='交互'; band1{3}='MEASURED';
one = StatusChip.band(g, band1);
tc.verifyEqual(numel(one), 1);
tc.verifyEqual(one{1}.state().status, 'MEASURED');

end

% ===================== PlotToolbar =====================

function test_plot_toolbar_construction_and_defaults(tc)
[fig, g, keepFig] = newGrid();
tb = PlotToolbar(g);
s = tb.state();
tc.verifyEqual(strjoin(tb.layerNames(), ','), 'truth,instrument,experiment');
tc.verifyEqual(numel(tb.presets()), 6);
tc.verifyEqual(tb.viewPreset(), 'home');
tc.verifyEqual(strjoin(s.visible_layers, ','), 'truth,instrument', ...
    sprintf('缺省可见层实得: %s', strjoin(s.visible_layers, ',')));
tc.verifyEqual(numel(s.errors), 0, sprintf('构造期不得留错: %s', strjoin(s.errors,' | ')));
tc.verifyEqual(s.last_action, '');
tc.verifyEqual(s.action, '');
tc.verifyEqual(tb.commandText(), '');
% 三个复选框 + 一个下拉真的建成了控件 (全量 findall 再 isa 筛)
all = findall(fig);
tc.verifyGreaterThanOrEqual(nnz(arrayfun(@(o) isa(o, 'matlab.ui.control.CheckBox'), all)), 3, ...
    '三层必须各有一个复选框');
tc.verifyTrue(any(arrayfun(@(o) isa(o, 'matlab.ui.control.DropDown'), all)), ...
    '视角预设必须是下拉');
tc.verifyError(@() PlotToolbar([], struct()), 'tepc:gui:NoParent');
delete(tb);
end

function test_plot_toolbar_rejected_hide_keeps_layer_list(tc)
%   拒绝一个无数据层的打开请求: 既要留痕、要回显, 又不得把好层的列表改坏。
[fig, g, keepFig] = newGrid();
tb = PlotToolbar(g);
good = tb.state();
tc.verifyEqual(tb.layerAvailable('experiment'), false, ...
    '本仓库没有实测数据, experiment 层必须缺省判无数据');
tc.verifyEqual(tb.layerVisible('experiment'), false);
tb.setLayerVisible('experiment', true);
s = tb.state();
tc.verifyEqual(numel(s.errors), numel(good.errors) + 1, ...
    sprintf('被拒操作必须新增一条错误记录 (前 %d 后 %d)', numel(good.errors), numel(s.errors)));
tc.verifyTrue(contains(string(s.errors{end}), 'experiment'), ...
    sprintf('留痕必须点出层名, 实得: %s', s.errors{end}));
tc.verifyEqual(strjoin(s.visible_layers, ','), strjoin(good.visible_layers, ','), ...
    '被拒之后可见层集合必须一字不动');
tc.verifyEqual(numel(s.visible_layers), 2);
tc.verifyEqual(s.available.experiment, false);
tc.verifyEqual(tb.layerVisible('experiment'), false);
tc.verifyFalse(isempty(s.status_text), '拒绝原因必须回显给用户而不是只进内部列表');
tc.verifyEqual(s.last_action, '', '被拒的改层不得被记成一次动作');
tc.verifyEqual(tb.Notes.experiment, '无实测数据 (NOT_AVAILABLE)', ...
    sprintf('拒绝理由必须来自登记过的说明, 实得: %s', tb.Notes.experiment));
% 负对照: 声明该层确实有数据之后, 同一请求必须成功且不产生新错误
e1 = numel(tb.Errors);
tb.setLayerAvailable('experiment', true);
tb.setLayerVisible('experiment', true);
tc.verifyEqual(tb.layerVisible('experiment'), true);
tc.verifyEqual(numel(tb.Errors), e1, ...
    sprintf('放行路径不得再报错, 新增: %s', strjoin(tb.Errors(e1+1:end), ' | ')));
tc.verifyEqual(numel(tb.state().visible_layers), 3);
% 负对照 2: 重新判无数据必须同时把该层关掉 (不能留着"无数据但可见")
tb.setLayerAvailable('experiment', false, '实验谱未接入');
tc.verifyEqual(tb.layerVisible('experiment'), false);
tc.verifyEqual(numel(tb.state().visible_layers), 2);
tc.verifyEqual(tb.Notes.experiment, '实验谱未接入');
delete(tb);
end

function test_plot_toolbar_bad_view_preset_and_layers(tc)
[fig, g, keepFig] = newGrid();
tb = PlotToolbar(g);
before = tb.viewPreset();
tc.verifyError(@() tb.setViewPreset('bogus'), 'tepc:gui:BadViewPreset');
tc.verifyEqual(tb.viewPreset(), before, '被拒的预设不得改状态');
tb.setViewPreset('ISO');
tc.verifyEqual(tb.viewPreset(), 'iso', '大小写归一是文档口径');
tc.verifyEqual(tb.state().view_label, '等轴');
tc.verifyEqual(tb.state().last_action, 'view');
tc.verifyError(@() tb.layerVisible('nope'), 'tepc:gui:BadLayer');
% 负对照: 层描述形状不对必须报错, 不静默退化成缺省三层
rows = cell(2, 1);
rows{1} = {'a'};                 % 只给了 token, 少一个显示名
rows{2} = {'b', 'B'};
tc.verifyError(@() PlotToolbar.asLayers(rows), 'tepc:gui:BadLayers');
tc.verifyError(@() PlotToolbar.asLayers('x'), 'tepc:gui:BadLayers');
oneRow = cell(1, 1);
oneRow{1} = {'ok', 'OK 层'};              % 外层再包一层: 单行描述
one = PlotToolbar.asLayers(oneRow);
tc.verifyEqual(one{1}{1}, 'ok');
tc.verifyEqual(one{1}{2}, 'OK 层');
delete(tb);
end

function test_plot_toolbar_command_copy_export_mounts(tc)
[fig, g, keepFig] = newGrid();
tb = PlotToolbar(g);
% 空命令时的复制: 拒绝 + 留痕 + 从 state() 暴露
tc.verifyEqual(tb.copyCommand(), false);
s = tb.state();
tc.verifyEqual(nnz(cellfun(@(x) contains(string(x), '命令文本为空'), s.errors)), 1, ...
    sprintf('空命令复制必须留痕并可从 state() 读到: %s', strjoin(s.errors,' | ')));
tc.verifyEqual(s.last_action, '', '被拒的复制不得被记成一次动作');
% 挂上命令文本 + 应用层挂载点: 交出去并记动作
box = counter(fig, 'copy');
tb.setCommandText('tepc run --cfg x.json');
tc.verifyEqual(tb.commandText(), 'tepc run --cfg x.json');
tb.OnCopyCommand = @(req) bump(box, req.action);
tc.verifyEqual(tb.copyCommand(), true);
tc.verifyEqual(getCount(box), 1, '挂载点必须收到复制请求');
tc.verifyEqual(tb.state().last_action, 'copy');
tc.verifyEqual(numel(tb.state().actions), 1);
% 负对照: 挂载点抛错 -> 进 Errors 且不谎报"已复制"
tb.OnCopyCommand = @(req) error('tepc:test:Copy', '剪贴板不可用');
tc.verifyEqual(tb.copyCommand(), false, ...
    '挂载点抛错时 copied 必须是 false, 不能把失败报成成功');
tc.verifyTrue(contains(string(tb.Errors{end}), '剪贴板不可用'), ...
    sprintf('挂载点原因必须进 Errors: %s', tb.Errors{end}));
% 导出请求带着层与视角给应用层
tb.setViewPreset('iso');
tb.setExportName('谱图_01');
tb.OnExport = @(req) bump(box, req.name);
tb.requestExport();
tc.verifyEqual(getCount(box), 2);
req = tb.request();
tc.verifyEqual(req.name, '谱图_01');
tc.verifyEqual(req.view, 'iso');
tc.verifyEqual(req.action, '', 'request() 本身不带动作, 动作只在 fire 时记');
delete(tb);
end

% ===================== EvidencePanel =====================

function test_evidence_panel_counts_match_independent_decode(tc)
%   面板按字节 UTF-8 读表; 这里用同一套字节读 + jsondecode 自己数一遍,
%   断言四态计数一致 —— 否则面板显示的数字与登记表可以各说各话。
[fig, g, keepFig] = newGrid();
root = projectRoot();
ep = EvidencePanel(g, struct('AutoLoad', false));
tc.verifyEqual(ep.state().loaded, false, 'AutoLoad=false 时不得偷偷读表');
ok = ep.loadRegister(root);
tc.verifyEqual(ok, true);
s = ep.state();
tc.verifyEqual(s.loaded, true);
tc.verifyEqual(s.load_error, '');
path = fullfile(root, 'config', 'capability_register.json');
tc.verifyEqual(s.path, path, sprintf('实得路径 %s', s.path));
ind = independentCounts(path);
tc.verifyEqual(s.counts.DONE, ind.DONE, ...
    sprintf('DONE 面板 %d vs 独立 %d', s.counts.DONE, ind.DONE));
tc.verifyEqual(s.counts.PARTIAL, ind.PARTIAL, ...
    sprintf('PARTIAL 面板 %d vs 独立 %d', s.counts.PARTIAL, ind.PARTIAL));
tc.verifyEqual(s.counts.BLOCKED, ind.BLOCKED, ...
    sprintf('BLOCKED 面板 %d vs 独立 %d', s.counts.BLOCKED, ind.BLOCKED));
tc.verifyEqual(s.counts.EXCLUDED, ind.EXCLUDED, ...
    sprintf('EXCLUDED 面板 %d vs 独立 %d', s.counts.EXCLUDED, ind.EXCLUDED));
tc.verifyEqual(s.n_entries, ind.total);
tc.verifyEqual(s.open_blockers, ind.total - ind.DONE, ...
    '"未关闭"必须等于 DONE 以外的条目数');
tc.verifyTrue(isfield(s.counts, 'DONE'), '四态槽位必须恒在 (缺位也要显式给 0)');
% 中文原文没被按系统字符集读成乱码 (乱码说明走了 fileread 那条路)
tc.verifyTrue(contains(string(s.line_text), '登记表'), ...
    sprintf('计数行应是中文原文, 实得: %s', s.line_text));
tc.verifyTrue(contains(string(s.line_text), sprintf('DONE %d', ind.DONE)), ...
    sprintf('计数行必须把 DONE 实数印出来, 实得: %s', s.line_text));
tc.verifyEqual(numel(s.errors), 0, sprintf('读表路径不得留错: %s', strjoin(s.errors,' | ')));
% 措辞只能来自表内: DONE 条目的 allowed_phrases 原文
ph = ep.phrases('D-01');
tc.verifyGreaterThanOrEqual(numel(ph), 1);
tc.verifyTrue(any(cellfun(@(x) strcmp(x, ind.done_phrase), ph)), ...
    'claimable 必须能在表内找到同一句原文');
tc.verifyEqual(numel(ep.blockers), ind.total - ind.DONE);
delete(ep);
end

function test_evidence_panel_register_note_matches_entry_counts(tc)
%   登记表是定位语的唯一来源 (note 自己就是这么声明的)。note 里写的 DONE 数
%   必须与 entries 实数一致, 否则 README / GUI / HTML 三处定位话术继承同一个假数。
[fig, g, keepFig] = newGrid();
path = fullfile(projectRoot(), 'config', 'capability_register.json');
ind = independentCounts(path);
ep = EvidencePanel(g, struct('AutoLoad', false));
ep.loadRegister(projectRoot());
s = ep.state();
tok = regexp(ind.note, 'DONE\s*=\s*(\d+)', 'tokens', 'once');
if isempty(tok)
    % note 不写静态条数也是一种合法口径 (条数由 entries 实时算, 面板与文档同一来源)。
    % 这里只保证一件事: 一旦出现 "DONE=" 就必须被上面那条正则抓到, 否则是判据自己漏形。
    tc.verifyFalse(contains(string(ind.note), "DONE="), ...
        'note 里有 "DONE=" 字样却没被正则抓到 —— 锁本身漏形, 会放过假数');
else
    claimed = str2double(tok{1});
    tc.verifyEqual(claimed, double(ind.DONE), ...
        sprintf('登记表 note 声称 DONE=%g, entries 实数 DONE=%d (面板读到 %d) —— 措辞唯一来源必须自洽', ...
            claimed, ind.DONE, s.counts.DONE));
end
delete(ep);
end

function test_evidence_panel_missing_register_is_not_zero_blockers(tc)
%   缺表时不得渲染成"0 阻塞项": 0 会被读成"已经干净了"。
[fig, g, keepFig] = newGrid();
dir0 = safeTempDir('tepc_no_reg_');
mkdir(fullfile(dir0, 'config'));          % 目录在、表不在 -> 走 NoRegister 分支
ep = EvidencePanel(g, struct('AutoLoad', false));
ok = ep.loadRegister(dir0);
tc.verifyEqual(ok, false);
s = ep.state();
tc.verifyEqual(s.loaded, false);
tc.verifyTrue(contains(string(s.load_error), 'tepc:config:NoRegister'), ...
    sprintf('缺表必须是具名错误, 实得: %s', s.load_error));
tc.verifyTrue(isempty(s.open_blockers), ...
    sprintf('未取数时 open_blockers 必须是空而不是 0, 实得 %s', mat2str(s.open_blockers)));
tc.verifyTrue(contains(string(s.line_text), '不可得'), ...
    sprintf('计数行必须写"不可得", 实得: %s', s.line_text));
tc.verifyTrue(contains(string(s.line_text), 'NOT_AVAILABLE'), ...
    sprintf('计数行必须写 NOT_AVAILABLE, 实得: %s', s.line_text));
% 负对照: 计数全 0 也不许被显示成"干净", 且声称措辞不得凭空长出来
tc.verifyEqual(s.counts.total, 0);
tc.verifyEqual(s.counts.BLOCKED, 0);
tc.verifyFalse(contains(string(s.line_text), '正常'), ...
    sprintf('读不到表时计数行不得出现"正常", 实得: %s', s.line_text));
tc.verifyFalse(isempty(s.claimable), ...
    '读不到表时 claimable 必须显式说明没有可声称措辞, 不能是空');
delete(ep);
end

function test_evidence_panel_constructor_options_are_honored(tc)
%   构造选项契约: opts 的 Root / Filter / AutoLoad 三项都要真的生效。
%   本用例是负对照的载体: 传了选项却不生效的面板会读到"别人的"登记表数字。
[fig, g, keepFig] = newGrid();
dir0 = safeTempDir('tepc_ep_opt_');
mkdir(fullfile(dir0, 'config'));
o = struct();
o.AutoLoad = false;
o.Root = dir0;
o.Filter = 'blocked';
ep = EvidencePanel(g, o);
s = ep.state();
tc.verifyEqual(s.filter, 'blocked', ...
    sprintf('opts.Filter 必须生效, 实得 %s', s.filter));
tc.verifyEqual(s.loaded, false, 'opts.AutoLoad=false 时不得读表');
tc.verifyEqual(s.load_error, '', ...
    sprintf('AutoLoad=false 仍读了表并留下错误: %s', s.load_error));
tc.verifyTrue(isempty(s.path) || contains(string(s.path), 'tepc_ep_opt_'), ...
    sprintf('opts.Root 必须决定读哪份表, 实得路径 %s', s.path));
delete(ep);
end

function test_evidence_panel_filter_and_selection(tc)
[fig, g, keepFig] = newGrid();
ep = EvidencePanel(g, struct('AutoLoad', false));
ep.loadRegister(projectRoot());
nAll = numel(ep.visibleIds());
tc.verifyTrue(nAll > 0, sprintf('读不到表时筛选集合必为空 (见 BOM 判定那条红灯), 实得 %d', nAll));
ep.setFilter('blocked');
nb = numel(ep.visibleIds());
tc.verifyEqual(nb, ep.state().counts.BLOCKED, ...
    sprintf('blocked 筛选命中数 %d 应等于 BLOCKED 计数 %d', nb, ep.state().counts.BLOCKED));
tc.verifyTrue(nb < nAll, sprintf('筛选必须真的改变命中集合 (blocked %d vs all %d), 否则筛选是空转', nb, nAll));
% 表内显示名也算入参 (中文档), 未知模式必须拒绝
ep.setFilter('受阻');
tc.verifyEqual(ep.state().filter, 'blocked', sprintf('实得 %s', ep.state().filter));
tc.verifyError(@() ep.setFilter('nope'), 'tepc:gui:BadFilterMode');
ep.setFilter('all');
tc.verifyEqual(numel(ep.visibleIds()), nAll);
ep.selectId('D-01');
tc.verifyEqual(ep.selectedId(), 'D-01');
tc.verifyEqual(ep.state().selected, 'D-01');
tc.verifyTrue(numel(ep.reason('D-01')) > 0);
tc.verifyEqual(ep.reason('不存在的条目'), '', '表里没有的 id 不得编造 reason');
tc.verifyEqual(ep.phrases('不存在的条目'), {}, '表里没有的 id 不得编造措辞');
delete(ep);
end

function test_evidence_panel_bom_compare_needs_row_shape(tc)
%   读表第一步的 BOM 判定形状: fread 交回来的是**列**向量, 与 1x3 的 [239 187 191]
%   比较会走隐式扩展 (3x1 == 1x3 -> 3x3 逻辑阵), all(...) 只得一个 1x3, 再用 && 串
%   就抛 MATLAB:nonLogicalConditional —— 任何 >=3 字节的无 BOM 登记表都读不进来
%   (出厂表 19756 字节)。两面都钉住: 列形状确实不收敛, 行形状判定才是标量。
head = uint8([123 10 32 34 10]);           % 出厂登记表开头 5 字节 (无 BOM)
col = freadColumnLike(head);               % fread 的实际形状
bad = all(col(1:3) == uint8([239 187 191]));
tc.verifyFalse(isscalar(bad), ...
    sprintf('列向量直接比会得到标量吗? 实得形状 %s —— 这就是当年读表全量失败的表达式', ...
        mat2str(size(bad))));
tc.verifyTrue(isscalar(all(head(1:3) == uint8([239 187 191]))), ...
    '收成行向量后 BOM 判定必须是标量');
tc.verifyEqual(all(head(1:3) == uint8([239 187 191])), false, '无 BOM 要判假');
bom = [uint8([239 187 191]) head];
tc.verifyEqual(all(bom(1:3) == uint8([239 187 191])), true, '带 BOM 要判真');
end

function test_evidence_panel_shipped_register_counts_match_byte_recount(tc)
%   修好的字节读路径必须真的把出厂登记表读进来: 面板四态计数 == 用例自己按字节
%   UTF-8 复算的结果, 且复算的绝对数与面板显示一致 (表被改坏时这条先红)。
[fig, g, keepFig] = newGrid();
path = fullfile(projectRoot(), 'config', 'capability_register.json');
ep = EvidencePanel(g, struct('AutoLoad', false));
tc.verifyEqual(ep.loadRegister(projectRoot()), true, '出厂表读不进来时后面全是空话');
s = ep.state();
tc.verifyEqual(s.load_error, '', sprintf('实得 <%s>', s.load_error));
ind = independentCounts(path);
c = ep.counts();
tc.verifyEqual([c.DONE c.PARTIAL c.BLOCKED c.EXCLUDED c.total], ...
    [ind.DONE ind.PARTIAL ind.BLOCKED ind.EXCLUDED ind.total], ...
    sprintf('面板 [%d %d %d %d %d] vs 字节复算 [%d %d %d %d %d]', ...
        c.DONE, c.PARTIAL, c.BLOCKED, c.EXCLUDED, c.total, ...
        ind.DONE, ind.PARTIAL, ind.BLOCKED, ind.EXCLUDED, ind.total));
tc.verifyEqual(numel(s.errors), 0, sprintf('读表路径不得留错: %s', strjoin(s.errors, ' | ')));
tc.verifyEqual(s.n_entries, ind.total);
% 绝对数一起钉住: 表被改坏 (加/删条目、改 status) 时这条先红, 而不是跟着改口径。
% 翻转 status 时这里必须同步改, 但前提是 test_report_semantics 的
% test_register_evidence_pointers_resolve 能打开新写的证据指针 (DONE 条目要自带证据)。
% 本轮 D-12 与 T-13-1 由 PARTIAL 转 DONE 的前置已满足: 两条的新证据指针
% (modelParams.m / checkParamIdentity.m 的 inherited 判据 / test_slx_config_identity.m 的烘入用例,
%  以及 test_geometry_transport_identity.m 的两头判据用例) 都能在盘上打开并命中锚文本,
% report_semantics 与 positioning_claims 均绿 —— 也就是说这里改数是被两条锁共同允许的。
% 2026-09-30 第二次按同一规矩改数: 新增条目 D-21 (发布谱两层成因分解, status=PARTIAL)，
% 它的 6 条 evidence 指针已由 test_report_semantics 的 test_register_evidence_pointers_resolve
% 逐条打开并命中锚文本, 所以 total 33->34、PARTIAL 19->20 是"加了条目就必须改这里"的同步,
% 不是把红判据放宽。
tc.verifyEqual([c.DONE c.PARTIAL c.BLOCKED c.EXCLUDED c.total], ...
    [4 20 8 2 34], sprintf('实得 [%d %d %d %d %d]', ...
        c.DONE, c.PARTIAL, c.BLOCKED, c.EXCLUDED, c.total));
tc.verifyEqual(numel(ep.blockers), ind.total - ind.DONE);
delete(ep);
end

function test_evidence_panel_load_failure_is_visible_in_errors_too(tc)
%   负对照 (存在但不对的目录): 失败必须同时落在 LoadError 与 Errors 两条通道上 ——
%   只写 LoadError 时 state().errors 恒空, "面板知道自己坏了"对上层完全不可见。
[fig, g, keepFig] = newGrid();
ep = EvidencePanel(g, struct('AutoLoad', false));
ok = ep.loadRegister(tempdir);
s = ep.state();
tc.verifyEqual(ok, false, '指错目录时 loadRegister 必须返回 false');
tc.verifyEqual(s.loaded, false);
tc.verifyTrue(contains(string(s.load_error), 'tepc:config:NoRegister'), ...
    sprintf('LoadError 要带具名标识符, 实得: %s', s.load_error));
tc.verifyGreaterThanOrEqual(numel(s.errors), 1, ...
    '同一次失败必须也进 state().errors (否则上层永远看不到)');
tc.verifyTrue(any(cellfun(@(x) contains(string(x), 'loadRegister'), s.errors)), ...
    sprintf('Errors 里的条目要点名出错位置, 实得: %s', strjoin(s.errors, ' | ')));
tc.verifyTrue(any(cellfun(@(x) contains(string(x), s.load_error), s.errors)), ...
    sprintf('Errors 要带上与 LoadError 同一条原因, 实得: %s', strjoin(s.errors, ' | ')));
% 读不到表时不得被显示成"干净"
tc.verifyEqual(s.counts.total, 0);
tc.verifyTrue(isempty(s.open_blockers), ...
    sprintf('未取数必须是空而不是 0, 实得 %s', mat2str(s.open_blockers)));
tc.verifyTrue(contains(string(s.line_text), 'NOT_AVAILABLE'), ...
    sprintf('计数行要显式标 NOT_AVAILABLE, 实得: %s', s.line_text));
delete(ep);
end

function test_plot_toolbar_host_options_are_honored(tc)
%   宿主页 (TEPCApp 的 3D 工具条) 靠 opts 传层集合、可复现命令与导出名。
%   这些选项没生效时界面会安静地退回缺省三层 + 空命令, 用户看到的层与真实图层无关。
[fig, g, keepFig] = newGrid();
o = struct();
o.Layers = {{'mesh', '● 网格 Mesh', [0.2 0.4 0.8]}, {'fit', '▲ 拟合 Fit', [0.8 0.4 0.2]}};
o.CommandText = 'tepc run --cfg cfg/site.json --run 7';
o.ExportName = 'tepc_geom3d';
o.Unavailable = {'fit'};
tb = PlotToolbar(g, o);
tc.verifyEqual(strjoin(tb.layerNames(), ','), 'mesh,fit', ...
    sprintf('opts.Layers 必须决定层集合, 实得 %s', strjoin(tb.layerNames(), ',')));
tc.verifyEqual(tb.commandText(), 'tepc run --cfg cfg/site.json --run 7', ...
    sprintf('opts.CommandText 必须生效, 实得 <%s>', tb.commandText()));
tc.verifyEqual(tb.request().name, 'tepc_geom3d', ...
    sprintf('opts.ExportName 必须生效, 实得 %s', tb.request().name));
tc.verifyEqual(tb.layerAvailable('fit'), false, ...
    sprintf('opts.Unavailable 必须把该层判为无数据, 实得 %d', tb.layerAvailable('fit')));
delete(tb);
end

% ===================== 助手 (非 test 前缀, 不参与收集) =====================

function raw = freadColumnLike(v)
%FREADCOLUMNLIKE 造出 fread 的实际形状 (列向量) —— BOM 判定的坑就在这个形状上。
raw = reshape(uint8(v), [], 1);
end

function assignCharToEditor(card)
%ASSIGNCHARTOEDITOR 直接给数值承载格赋字符 (本机拒绝路径)。
card.Editor.Value = '77';
end

function [fig, g, keepFig] = newGrid()
%NEWGRID 共享的无头窗口 + 本用例私有网格。
%   两个坑都实测过:
%   * onCleanup 必须交给**调用方**持有, 在本函数内创建会在返回的那一刻析构,
%     窗口被立刻删掉, 之后所有构造都抛 MATLAB:ui:GridLayout:unknownInput。
%   * 每个用例开一个 uifigure 在这台 16.8GB 的机器上会把进程压穿 (实测: 22 个
%     用例连开 22 个窗口时 MATLAB 静默退出、日志停在用例中途), 所以窗口在会话内
%     复用, 用例结束时只销毁自己那一格网格 (子控件随父网格一起销毁)。
persistent PF
if isempty(PF) || ~isvalid(PF)
    PF = uifigure('Visible', 'off');
end
fig = PF;
g = uigridlayout(fig, [60, 1]);
keepFig = onCleanup(@() deleteGrid(g));
end

function deleteGrid(g)
try
    if isvalid(g)
        delete(g);
    end
catch
    % 清理路径不得抛错
end
end

function d = safeTempDir(prefix)
%SAFETEMPDIR tempname 带路径分隔符, 直接拼进 mkdir 会抛 MATLAB:MKDIR:OSError。
raw = char(string(tempname));
d = fullfile(tempdir, [prefix regexprep(raw, '[^A-Za-z0-9]', '')]);
if ~isfolder(d), mkdir(d); end
end

function b = counter(fig, tag)
%COUNTER 挂载点调用计数器: 记在窗口 appdata 上 (随窗口一起销毁, 用例之间不串)。
b = struct('fig', fig, 'key', ['tepcHits_' tag]);
setappdata(fig, b.key, 0);
end

function bump(b, ~)
v = getappdata(b.fig, b.key);
if isempty(v), v = 0; end
setappdata(b.fig, b.key, double(v) + 1);
end

function n = getCount(b)
v = getappdata(b.fig, b.key);
if isempty(v), n = 0; else, n = double(v); end
end

function root = projectRoot()
root = tepc.io.projectRoot();
end

function ensureGuiPath()
%ENSUREGUIPATH 把 app/components 挂上路径 (幂等)。
%   缺这一条时四个组件类在运行时都解析不到, 首条错误是
%   "未定义与 'matlab.ui.container.GridLayout' 类型的输入参数相对应的函数"。
    p = fullfile(tryProjectRoot(), 'app', 'components');
    if isfolder(p)
        addpath(p);
    end
end

function root = tryProjectRoot()
%TRYPROJECTROOT 仓库根: 优先问服务层, 拿不到时从 app/ 上的类文件反推一级。
    if ~isempty(which('tepc.io.projectRoot'))
        root = tepc.io.projectRoot();
        return;
    end
    w = which('AppState');
    if isempty(w)
        error('tepc:test:NoPath', ...
            'AppState 不在路径上: 本文件需要 src/ 与 app/ 先进路径');
    end
    root = fileparts(fileparts(w));
end

function txt = readUtf8Own(path)
%READUTF8OWN 用例自己的按字节 UTF-8 读文件 (与组件同一条字节口径, 不用 fileread)。
%   本机 fileread 会按系统字符集解 UTF-8 中文, 把结构读坏而 jsondecode 仍成功。
    fid = fopen(path, 'r', 'n', 'UTF-8');
    if fid < 0, error('tepc:test:NoFile', '读不到 %s', path); end
    raw = fread(fid, inf, 'uint8=>uint8');
    fclose(fid);
    raw = raw(:)';
    if numel(raw) >= 3 && all(raw(1:3) == uint8([239 187 191]))
        raw = raw(4:end);
    end
    txt = native2unicode(raw, 'UTF-8');
end

function ind = independentCounts(path)
%INDEPENDENTCOUNTS 自己按字节 UTF-8 读表并数四态, 不复用被测组件的代码路径。
fid = fopen(path, 'r', 'n', 'UTF-8');
if fid < 0, error('tepc:test:NoFile', '读不到 %s', path); end
raw = fread(fid, inf, 'uint8=>uint8');
fclose(fid);
raw = raw(:)';      % fread 给列向量: 不转成行向量时 (1:3)==[239 187 191] 会走隐式扩展
if numel(raw) >= 3 && all(raw(1:3) == uint8([239 187 191]))
    raw = raw(4:end);
end
J = jsondecode(string(native2unicode(raw(:)', 'UTF-8')));
ind = struct('DONE', 0, 'PARTIAL', 0, 'BLOCKED', 0, 'EXCLUDED', 0, ...
    'total', 0, 'done_phrase', '', 'note', '');
for i = 1:numel(J.entries)
    stg = char(string(J.entries(i).status));
    if isfield(ind, stg), ind.(stg) = ind.(stg) + 1; end
end
ind.total = numel(J.entries);
for i = 1:numel(J.entries)
    if strcmp(char(string(J.entries(i).status)), 'DONE')
        ap = J.entries(i).allowed_phrases;
        if ~isempty(ap) && isempty(ind.done_phrase)
            ind.done_phrase = char(string(ap(1)));
        end
    end
end
if isfield(J, 'note'), ind.note = char(string(J.note)); end
end
