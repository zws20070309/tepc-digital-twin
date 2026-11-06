function tests = test_gui_honest_positioning
%TEST_GUI_HONEST_POSITIONING 界面措辞与位点常驻带的回归锁。
%   这三件事此前只能靠人开一次界面看: (1) 窗口标题与横幅把"解析代理模型"说清楚;
%   (2) 校验后请求位点与实现位点同时常驻显示; (3) 点 [刷新三维] 不在日志里留假告警。
%   全部通过真实控件回调驱动 (按按钮文本找 uibutton 再调 ButtonPushedFcn), 不去调
%   私有方法 —— 私有方法改名会让测试跟着改, 而用户看到的恰恰只有按钮和文字。
tests = functiontests(localfunctions);
end

%% ==================== 用例 ====================

function test_window_title_is_surrogate_not_twin(tc)
app = newApp(tc);
title = string(app.UIFigure.Name);
tc.verifyTrue(contains(title, "Fast Surrogate"), ...
    sprintf('窗口标题没有标出解析代理模型身份: %s', char(title)));
tc.verifyTrue(contains(title, "非真实装置复现"), ...
    sprintf('窗口标题没有"非真实装置复现"限定语: %s', char(title)));
tc.verifyFalse(contains(title, "数字孪生"), ...
    sprintf('窗口标题仍用"数字孪生"称谓, 会把代理模型读成装置复现: %s', char(title)));
end

function test_banner_carries_surrogate_tail(tc)
app = newApp(tc);
pushButton(app, '校验配置');
b = string(app.Banner.Text);
tc.verifyTrue(contains(b, "Fast Surrogate"), ...
    sprintf('校验后横幅丢了代理模型尾巴: %s', char(b)));
tc.verifyFalse(contains(b, "绝对剂量已验证"), ...
    sprintf('横幅出现禁语: %s', char(b)));
% 横幅尾巴与位点带同源: 请求值/实现值/相对偏差三件必须同时出现。
% 数值间的自洽 (|请求-实现|/请求 == 显示的偏差百分数) 是更强的断言, 但它依赖横幅的
% 措辞形状; 本轮先锁"三件都在 + 无禁语", 自洽核对留给位点计算侧的用例。
tc.verifyTrue(contains(b, "请求") && contains(b, "实现") && contains(b, "偏差"), ...
    sprintf('校验后横幅没有同时给出请求/实现/偏差: %s', char(b)));
nums = regexp(b, '\d+\.\d+', 'match');
tc.verifyGreaterThanOrEqual(numel(nums), 2, ...
    sprintf('横幅里读不到两个位点数值: %s', char(b)));
if numel(nums) >= 2
    vals = unique(str2double(nums));
    tc.verifyGreaterThan(numel(vals), 1, ...
        sprintf('横幅里的两个位点数值相同, 说明请求/实现被写成了同一个数: %s', char(b)));
end
% 位点席位与横幅必须同源。此前 tests/ 下没有任何一处读 app.Chips —— 组件层的
% StatusChip.band 有锁 (六个席位、键序、空值写"未取数") 只证明"带子建得对",
% 不证明校验之后 4 号席位真的收到了同一份派生量; 而用户抬头看的是那行胶囊。
tc.verifyGreaterThanOrEqual(numel(app.Chips), 4, '主 GUI 顶部状态带必须有 4 号席位');
st4 = app.Chips{4}.state();
tc.verifyEqual(string(st4.key), "位点", ...
    sprintf('4 号席位不是位点席 (键=%s): 席位次序是显示契约, 不能漂', char(string(st4.key))));
v4 = string(st4.value);
tc.verifyFalse(v4 == "" || v4 == "未取数", ...
    sprintf('校验配置后位点席位仍空着 (值=%s): 横幅有数而席位没数, 接线断了', char(v4)));
nums4 = regexp(v4, '\d+\.\d+', 'match');
tc.verifyEqual(numel(nums4), 2, ...
    sprintf('位点席位必须同时给出请求与实现两个数: %s', char(v4)));
if numel(nums4) == 2 && numel(nums) >= 2
    tc.verifyTrue(all(ismember(nums4, nums)), ...
        sprintf('位点席位与横幅不同源 (席位 %s vs 横幅 %s): 两条显示路径必须读同一份派生量', ...
            strjoin(nums4, '/'), strjoin(nums, '/')));
end
% 状态带的公开只读口必须被用一次: statusStripText 存在但无人调用时, "整行文本程序化可取"
% 这句话只是 API 形状, 不是行为契约 —— 它可以悄悄只返回其中一段而没人发现。
strip = string(app.statusStripText());
tc.verifyGreaterThan(strlength(strip), 0, 'statusStripText 返回空串: 公开读取口没接上数据');
if numel(nums) >= 2
    tc.verifyTrue(contains(strip, nums{1}) && contains(strip, nums{2}), ...
        sprintf('整行文本里读不到横幅那两个位点数值 (strip=%s | 横幅 %s): 公开读取口与席位/横幅不是同源同一次写入', ...
            char(strip), strjoin(nums, '/')));
end
end

function test_3d_preview_leaves_no_false_alarm(tc)
% 回归锁: 早先预览路径从 resolve 的结果里取 config_sha256 (该字段只由运行链产出),
% 于是每次点 [刷新三维] 都在日志里留一条 nonExistentField 假告警。
app = newApp(tc);
pushButton(app, '校验配置');
pushButton(app, '⟳ 刷新三维');
logTxt = strjoin(string(app.LogList.Value), " || ");
tc.verifyFalse(contains(logTxt, "未取得"), ...
    sprintf('三维预览又出现"未取得"式假告警: %s', char(logTxt)));
tc.verifyGreaterThan(numel(app.AxGeom3D.Children), 0, ...
    '刷新三维后坐标轴里没有任何图元: 预览其实没画出来');
end

%% ==================== 逐席位 (状态带是显示契约) ====================

function test_every_seat_key_and_value_is_in_the_strip(tc)
% 席位少一个, 使用者就少看见一项判定, 而这个缺陷今天能全绿: app/TEPCApp.m 的刷新入口写着
% `if numel(self.Chips) < 6, return`, 六席变成五席时整条刷新静默 no-op, 而旧锁只判 >=4。
% 两条语言事实决定了这里能判什么 (都是读源码才敢写的, 也是本轮先写错再改回来的地方):
%   * StatusChip.setText 把空值强制写成"未取数" => "值非空串"是恒真断言, 不能当判据;
%   * statusStripText 在 Chips 非空时**当场重算** allText(Chips), 而 refresh 令
%     Text = 图标 + ' ' + Key + ' ' + Value => "strip 含 键+空格+值"是构造性恒真, 挡不住
%     refreshStatusStrip 把两个席位的量对调。真正有判别力的是**逐席语义形状**: 每席的值必须
%     长成它自己那个来源的样子 (位点两个小数 / 阻塞项纯计数 / 发布是判定词), 对调就会在这里红。
app = newApp(tc);
specs = StatusChip.defaultSpecs();
keys = string(specs(:, 1));
strip = string(app.statusStripText());
nChips = numel(app.Chips);
tc.verifyEqual(nChips, numel(keys), ...
    sprintf('状态带席位数 %d 与 defaultSpecs 的 %d 不一致: 刷新入口在少一席时静默 return', ...
        nChips, numel(keys)));
parts = strsplit(strip, ' | ');
tc.verifyEqual(numel(parts), numel(keys), ...
    sprintf('整行按 " | " 拆出 %d 段而席位有 %d 个: 有席位没进这一行, 或某个值里混进了分隔符 (strip=%s)', ...
        numel(parts), numel(keys), char(strip)));
for i = 1:numel(keys)
    key = keys(i);
    st = app.Chips{i}.state();
    tc.verifyEqual(string(st.key), key, ...
        sprintf('%d 号席位不是「%s」(实为 %s): 席位次序是显示契约, 不能漂', i, char(key), char(string(st.key))));
    % strfind 对 string 输入返回 cell, 未命中时仍是 1×1 cell 包一个空 -> numel 恒为 1 (判据恒真);
    % 必须落到 char 上才数得出出现次数, 与 tests/unit/test_gui_components.m 的同一口径。
    hits = numel(strfind(char(strip), char(key)));
    tc.verifyEqual(hits, 1, ...
        sprintf('「%s」在整行文本里出现 %d 次 (应为 1): 席位丢了、重了或被拆成两段', char(key), hits));
    if i > numel(parts)
        continue
    end
    tc.verifyTrue(contains(parts(i), key), ...
        sprintf('%d 号段里没有本段该有的「%s」: 段序与席位序没对上 (%s)', i, char(key), char(parts(i))));
    vStrip = string(extractAfter(parts(i), key + " "));
    tc.verifyMatches(vStrip, seatShape(i), ...
        sprintf('%d 号席位「%s」的值不像它自己的来源: strip 侧 %s / 席位侧 %s —— 把两席的量对调就在这里红', ...
            i, char(key), char(vStrip), char(string(st.value))));
    tc.verifyEqual(vStrip, string(st.value), ...
        sprintf('%d 号席位: strip 段里读到 %s 而席位对象是 %s: 两条读法不同源', ...
            i, char(vStrip), char(string(st.value))));
end
% StripText 是刷新时写下的镜像, getter 走的是当场重算 —— 两者必须同一份, 否则"整行文本程序化
% 可取"这句话里有一条写入路径永远没人读 (本轮之前全仓确实无人读 StripText)。
tc.verifyEqual(string(app.StripText), strip, ...
    'StripText 镜像与 statusStripText 不同: 写入路径与读取路径已分叉');
end

function sh = seatShape(i)
% 逐席期望形状, 按 StatusChip.defaultSpecs() 的键序 (1 模式 / 2 后端 / 3 配置哈希 / 4 位点 /
% 5 未关闭阻塞项 / 6 是否允许发布)。中文常量与 app 产出的串都由 MATLAB 按同一码页解析, 所以这里
% 判中文是自洽的 (跨文件扫 UTF-8 文本时才不行)。"未取数"放行的是**本席自己的**空态。
switch i
    case 1
        sh = "(未取数|RESEARCH_DEMO|VALIDATED|DEMO)$";
    case 2
        sh = "(未取数|解析代理模型)$";
    case 3
        sh = "(未取数|[0-9a-f]{6,})$";
    case 4
        sh = "(未取数|\d+\.\d+.*\d+\.\d+)";
    case 5
        sh = "(未取数|\d+)$";
    otherwise
        sh = "(未判定|允许发布|禁止发布)";
end
end

function test_seat_values_move_after_validate(tc)
% 上一条锁形状, 这一条锁"校验之后真的换数": 只有形状时, 六席永远显示同一份初值也能全绿。
% 未运行态里 3 号席位仍应是"未取数" (配置身份哈希只在运行链里产出), 不得被校验伪造成有数。
app = newApp(tc);
specs = StatusChip.defaultSpecs();
keys = string(specs(:, 1));
before = strings(1, numel(keys));
for i = 1:numel(keys)
    before(i) = string(app.Chips{i}.state().value);
end
pushButton(app, '校验配置');
after = strings(1, numel(keys));
for i = 1:numel(keys)
    after(i) = string(app.Chips{i}.state().value);
end
moved = before ~= after;
tc.verifyTrue(any(moved), ...
    sprintf('校验配置后六个席位的值一个都没变: 状态带不响应校验 (%s)', strjoin(after, ' | ')));
% 按键名定位而不是写死下标: 席位次序一旦漂动, after(3) 会指向另一个席位, 判据就变成跟着实现走。
iSha = find(keys == "配置哈希", 1);
iSite = find(keys == "位点", 1);
tc.verifyFalse(isempty(iSha) || isempty(iSite), ...
    sprintf('defaultSpecs 里找不到配置哈希或位点席 (键序: %s): 按语义定位的判据没有落点', strjoin(keys, '/')));
if ~isempty(iSha)
    tc.verifyEqual(after(iSha), "未取数", ...
        sprintf('未运行就被填上了配置哈希 (值=%s): 该哈希只由运行链产出, 填出来的是假数', char(after(iSha))));
end
% 不要求"至少两席换数": 其余席位在未运行时按设计就是常量或空态 (后端称谓固定、发布为未判定、
% 阻塞项要跑过才有数), 硬要求两席换数是没根据的猜测。这里判的是**该换的那席真的换**,
% 以及每席换完之后的**形状**仍是自己那个来源 (形状判据能抓住把 A 席的量写进 B 席)。
if ~isempty(iSite)
    tc.verifyTrue(moved(iSite), ...
        sprintf('校验后位点席位没换数 (前后都是 %s): 校验没算位点, 或算了没写进席位', char(after(iSite))));
    tc.verifyMatches(after(iSite), seatShape(iSite), ...
        sprintf('位点席位换数后的形状不像位点 (%s): 换进来的是别的量', char(after(iSite))));
end
strip = string(app.statusStripText());
parts = strsplit(strip, ' | ');
tc.verifyEqual(numel(parts), numel(keys), ...
    sprintf('校验后整行按 " | " 拆出 %d 段而席位有 %d 个: 换数走的是另一条路径而这一行没跟着写', ...
        numel(parts), numel(keys)));
for i = 1:numel(keys)
    if i > numel(parts)
        continue
    end
    vStrip = string(extractAfter(parts(i), keys(i) + " "));
    tc.verifyEqual(vStrip, after(i), ...
        sprintf('校验后 %d 号席位: 席位对象是 %s 而整行里是 %s: 公开读取口与席位不同源', ...
            i, char(after(i)), char(vStrip)));
    tc.verifyMatches(vStrip, seatShape(i), ...
        sprintf('校验后 %d 号席位「%s」的值不像它自己的来源: %s', i, char(keys(i)), char(vStrip)));
end
end

%% ==================== 辅助 (首参不叫 tc, 不计入用例数) ====================

function app = newApp(tc)
app = TEPCApp(false);
% addTeardown 的首个位置参就是被调句柄 (condition 形式要显式写 'Condition' 名值对);
% 删除时再查 isvalid, 因为用例可能已经自己关掉了窗口。
tc.addTeardown(@() safeDelete(app));
end

function safeDelete(app)
if isobject(app) && isvalid(app)
    delete(app);
end
end

function pushButton(app, name)
% 按界面上的文字找按钮并调用它的回调: 这是用户唯一的入口, 也顺带锁住按钮文字本身。
bs = findall(app.UIFigure, 'Type', 'uibutton');
ix = find(strcmp(string({bs.Text}), string(name)));
if isempty(ix)
    error('tepc:test:NoButton', '界面上找不到按钮「%s」(现有: %s)', name, ...
        strjoin(string({bs.Text}), ', '));
end
cb = bs(ix(1)).ButtonPushedFcn;
if isempty(cb)
    error('tepc:test:NoCallback', '按钮「%s」没有回调', name);
end
cb(bs(ix(1)), []);
drawnow;
pause(0.6);
end
