function tests = test_gui_state
%TEST_GUI_STATE AppState (GUI 单一状态源) 的公开面。
%   锁五件事: (1) 批量写入只排一次延后重算、只派发一个事件;
%   (2) 延后通道真的排上了一个可查的装载器 (对象在、Running 在跑、没留下退化原因),
%       以及到期回调确实落到 recomputeNow;
%   (3) 就地/跨字段校验的可观测输出 (问题码、级别、"未校验"话术);
%   (4) markClean 之后不留待同步标记; (5) 字段路径的唯一形状 (点号串具名拒绝) 与
%   关闭后的行为边界 (哪些方法拒写、哪些只读路径仍可用), 按代码实际做的断言而不是
%   希望它做的。
%   可观测计数走 derived()/summary() 暴露的 compute_count / debounce_armed /
%   timer, 事件次数走订阅者计数器 (AppState 自带 SubscriberCount 未公开)。
%   每个用例结束都要 close(): 延时装载器是活的 timer, 不删会在后面的用例里回调。
tests = functiontests(localfunctions);
end

function test_app_state_construction_defaults(tc)
s = AppState(cfgFixture());
sm = s.summary();
tc.verifyEqual(sm.revision, 0);
tc.verifyEqual(numel(sm.dirty), 0);
tc.verifyTrue(sm.compute_count <= 1, ...
    sprintf('构造期至多一次重算 (本机 timer 建不出来时会退化为同步重算), 实得 %d', sm.compute_count));
tc.verifyEqual(sm.closed, false);
tc.verifyEqual(sm.subscribers, 0);
tc.verifyEqual(sm.subscriber_errors, 0);
tc.verifyEqual(sm.timer, 'none', '延时装载器必须惰性创建, 构造期不得有 timer 对象');
tc.verifyEqual(sm.debounce_armed, false);
tc.verifyEqual(sm.debounce_delay, 0.3, ...
    sprintf('延时常量实得 %g 秒 (文档口径 250ms 与实现不符时以本断言为准)', sm.debounce_delay));
tc.verifyEqual(s.issueSummary(), '未校验', '从没校验过时不得写成"0 个问题"');
tc.verifyEqual(s.openBlockersText(), '未取数', '未登记出处时不得显示 0');
tc.verifyEqual(s.revision(), 0);
tc.verifyEqual(numel(s.schema()), 0, '映射表唯一来源是应用层, 构造期应为空');
end

function test_app_state_batched_setfields_defer_exactly_one_recompute(tc)
%   整张表单收集一次配置走 setFields: 延时装载器只排一次, 事件只派发一个。
s = stateWithSchema();
s.setDebounceDelay(30);        % 排上但本用例内绝不到期: 结算改由显式 recomputeNow 走
s.recomputeNow();
% 合成配置过不了服务层: 重算必须显式报 FAILED + 原因, 不许停在"看起来正常"的空值上
d0s = s.derived();
tc.verifyEqual(d0s.state, 'FAILED', sprintf('实得 %s', d0s.state));
tc.verifyFalse(isempty(d0s.error), '重算失败必须留下原因');
c0 = s.derived().compute_count;
box = events('batch');
s.subscribe(@(evt) bumpKind(box, evt.Reason), {});
n0 = getCount(box);
d0 = getDerived(box);
s.setFields({'gwidth', 'gcount', 'sname'}, {50, 9, 'rigB'}, 'gather');
mid = getCount(box);
tc.verifyEqual(mid - n0, 1, ...
    sprintf('一次 setFields 只应派发一个字段事件, 实得 %d', mid - n0));
% 排期必须留下三件可查的事: 有对象、在跑、没留下"退化了"的原因。只断言"要么排上要么
%   留下原因"会让 ExecutionMode 写错导致定时器永远建不出来这条路跑绿 (实见过)。
sm = s.summary();
tc.verifyEqual(sm.timer, 'on', ...
    sprintf('批量写入后延时装载器必须真的排上 (timer=%s, debounce_error=<%s>)', ...
        sm.timer, sm.debounce_error));
tc.verifyEqual(sm.debounce_armed, true, '排上后 armed 标记必须为真');
tc.verifyEqual(sm.debounce_error, '', ...
    sprintf('排上了就不该同时留下不可用原因: <%s>', sm.debounce_error));
tc.verifyEqual(getDerived(box) - d0, 0, ...
    sprintf('延后未到期时不得已经派发过 derived 事件, 实得 %d', getDerived(box) - d0));
tc.verifyEqual(numel(s.dirty()), 3);
tc.verifyEqual(s.summary().revision, 1, '批量写入只递增一次版本号');
% 负对照: 第二次批量写入复用同一个对象, 不出现第二个装载器
t1 = s.DebounceTimer;
s.setFields({'gwidth', 'gcount'}, {51, 10}, 'gather2');
tc.verifyEqual(s.DebounceTimer, t1, '延时装载器必须复用同一个对象');
tc.verifyEqual(s.summary().revision, 2);
tc.verifyEqual(numel(s.dirty()), 3, '两批合起来的待同步集合并集');
% 同步兜底 (与回调同一个落点): 排期解除、派生量落到明确状态、只一次 derived 事件
s.recomputeNow();
sm2 = s.summary();
tc.verifyEqual(sm2.debounce_armed, false, '结算后必须解除排期标记');
tc.verifyEqual(sm2.compute_count, c0 + 1, ...
    sprintf('一次显式结算恰好一次重算尝试, 实得 %d (基线 %d)', sm2.compute_count, c0));
tc.verifyEqual(getDerived(box) - d0, 1, ...
    sprintf('一次结算只能有一次派生量事件, 实得 %d', getDerived(box) - d0));
tc.verifyEqual(sm2.timer, 'off', sprintf('未到期时对象停着但还在, 实得 %s', sm2.timer));
% 负对照 2: 逐项 setField 三次 -> 字段事件三次 (与批量的"只一个"形成可观测差异)
box2 = events('onebyone');
s.subscribe(@(evt) bump(box2, evt.Reason), {});
n1 = getCount(box2);
s.setField('gwidth', 52); s.setField('gcount', 11); s.setField('sname', 'rigC');
tc.verifyGreaterThanOrEqual(getCount(box2) - n1, 3, ...
    sprintf('逐项 setField 每次输入至少派发一个字段事件, 实得 %d', getCount(box2) - n1));

% 负对照 3: 形状不匹配的批量写入必须当场拒绝, 不能部分写入
rev = s.summary().revision;
dirtyBefore = numel(s.dirty());
tc.verifyError(@() s.setFields({'gwidth'}, {1, 2}), 'tepc:gui:BadBatchShape');
tc.verifyEqual(s.summary().revision, rev, '被拒的批量写入不得推进版本号');
tc.verifyEqual(numel(s.dirty()), dirtyBefore, '被拒的批量写入不得留下脏标记');
tc.verifyEqual(s.fieldValue('gwidth'), 52, '被拒的批量写入不得改动配置值');
s.close();
end

function test_app_state_debounce_fires_and_collapses_bursts(tc)
%   延后通道的另一头: 到期回调落在 recomputeNow。本机实测主线程一旦空闲 (pause 让出)
%   就会派发, 所以连续输入只结算最后一次; 长时间不空闲时排期保持 armed, 不会丢。
s = stateWithSchema();
s.recomputeNow();
c0 = s.summary().compute_count;
% 延后必须**大于三次写入的突发时长**, 否则"合并成一次"这件事根本不可观测:
% 夹到实现允许的最小值 0.01 s 时, 定时器会在两次 setField 之间就到期派发,
% 于是走"未排上即同步重算"的兜底通道 —— 实测 compute_count 从基线 1 涨到 4
% (三次输入各算一次), 而 timerState 在三次写入后已是 'off' (派发完了)。
% 那是用例把被测性质自己消灭后仍然断言它, 不是产品没防抖。取 0.5 s: 远大于突发,
% 又远小于下面的 6 s 结算窗口。
s.setDebounceDelay(0.5);
s.setField('gwidth', 60);
s.setField('gcount', 12);
s.setField('sname', 'rigE');
tc.verifyEqual(s.timerState(), 'on', ...
    sprintf('三次写入后应仍有一个在排的装载器 (延后 0.5 s) —— 实得 %s, armed=%s, 兜底原因: %s', ...
    s.timerState(), mat2str(s.summary().debounce_armed), ...
    char(string(s.summary().debounce_error))));
settled = false;
for k = 1:60
    pause(0.1); drawnow;
    if ~s.summary().debounce_armed
        settled = true;
        break;
    end
end
sm = s.summary();
tc.verifyTrue(settled || strcmp(sm.timer, 'on'), ...
    sprintf('要么已结算 (armed=false), 要么仍排着 (timer=on); 两条都不占就是排期丢了 (timer=%s armed=%s)', ...
        sm.timer, mat2str(sm.debounce_armed)));
if settled
    tc.verifyEqual(sm.compute_count, c0 + 1, ...
        sprintf('三次输入合并成一次结算, 重算尝试实得 %d (基线 %d)', sm.compute_count, c0));
    tc.verifyNotEqual(sm.derived_state, 'STALE', ...
        sprintf('结算后派生量状态必须换成明确词, 实得 %s', sm.derived_state));
else
    tc.verifyEqual(sm.compute_count, c0, '未结算时不得偷偷重算');
end
s.close();
tc.verifyEqual(s.timerState(), 'none', '关窗必须删掉定时器, 不留在途对象');
end

function test_app_state_markclean_leaves_no_pending_sync(tc)
s = stateWithSchema();
s.setFields({'gwidth', 'gcount'}, {44, 8});
tc.verifyEqual(numel(s.dirty()), 2);
tc.verifyEqual(s.isDirty('gwidth'), true);
s.markClean();
sm = s.summary();
tc.verifyEqual(numel(sm.dirty), 0, 'markClean 后不得留任何待同步标记');
tc.verifyEqual(s.isDirty('gwidth'), false);
tc.verifyEqual(s.isDirty('gcount'), false);
% markClean 只管待同步标记; 延后重算排期是另一条通道, 它既不该清也不该被算清
tc.verifyEqual(any(strcmp(sm.derived_state, {'STALE', 'PARTIAL', 'FRESH', 'FAILED'})), true, ...
    sprintf('派生量状态必须始终有明确词, 实得 <%s>', sm.derived_state));
% 负对照: 只清一个 tag 时另一个必须还在
s.setField('gwidth', 45); s.setField('gcount', 9);
s.markClean('gwidth');
tc.verifyEqual(strjoin(s.dirty(), ','), 'gcount');
tc.verifyEqual(s.isDirty('gwidth'), false);
tc.verifyEqual(s.isDirty('gcount'), true);
% 负对照 2: 没改过的 tag 上 markClean 是空操作, 不得顺手清掉别人的
s.markClean();
s.setField('sname', 'rigD');
s.markClean('gwidth');
tc.verifyEqual(strjoin(s.dirty(), ','), 'sname');
s.close();
end

function test_app_state_validate_field_and_model(tc)
s = stateWithSchema();
s.setField('gwidth', 55);
it = s.validateField('gwidth');
tc.verifyEqual(numel(it), 0, ...
    '域内取值不得报问题 (有负对照在前, 这条才不是空话)');
s.setField('gwidth', 999);
it = s.validateField('gwidth');
tc.verifyEqual(numel(it), 1, sprintf('越界必须报 1 条, 实得 %d', numel(it)));
tc.verifyEqual(it{1}.code, 'FIELD_ABOVE_MAX');
tc.verifyEqual(it{1}.level, 'error');
tc.verifyEqual(it{1}.tag, 'gwidth');
tc.verifyTrue(contains(string(it{1}.message), '100'), ...
    sprintf('问题文本必须带上被违反的上限, 实得: %s', it{1}.message));
fiW = s.fieldIssues('gwidth');
tc.verifyEqual(numel(fiW), 1, '问题必须能在状态源里回读');
al = s.allFieldIssues();
tc.verifyEqual(numel(al), 1);
tc.verifyEqual(al{1}.field, 'gwidth', 'allFieldIssues 的每项要带字段名');
% 负对照: 回到域内后问题必须清空, 不能留着上一条
s.setField('gwidth', 55);
tc.verifyEqual(numel(s.fieldIssues('gwidth')), 0, ...
    '修正后旧问题必须消失, 否则提示行永远红着');
% 空文本格: 必须报错而不是"没问题"
s.setField('sname', '   ');
tc.verifyEqual(numel(s.validateField('sname')), 1);
fiS = s.fieldIssues('sname');
tc.verifyEqual(fiS{1}.code, 'TEXT_EMPTY');
% 跨字段校验整段委托服务层; 没有配置时必须报问题而不是返回空列表
im = s.validateModel();
tc.verifyTrue(isnumeric(im) || iscell(im), 'validateModel 必须返回列表');
tc.verifyEqual(numel(s.issueSummary()) > 0, true);
e = AppState();
tc.verifyEqual(numel(e.validateModel()), 1, ...
    '空配置时不得返回空列表 —— 空列表会被界面读成"没有问题"');
tc.verifyEqual(e.Issues{1}.code, 'NO_CONFIG');
tc.verifyEqual(e.issueSummary(), '错误 1 / 警告 0');
s.close();
e.close();
end

function test_app_state_open_blockers_never_shows_bare_zero(tc)
s = stateWithSchema();
tc.verifyEqual(s.openBlockersText(), '未取数');
tc.verifyTrue(isempty(s.openBlockers()));
s.setOpenBlockers(3, 'capability_register');
tc.verifyEqual(s.openBlockers(), 3);
tc.verifyEqual(s.openBlockersText(), '3 (出处: capability_register)');
% 负对照: 0 必须带出处才有"已经干净"的含义
s.setOpenBlockers(0, 'capability_register');
tc.verifyEqual(s.openBlockersText(), '0 (出处: capability_register)');
% 负对照 2: 传空回到未取数, 不得停在 0
s.setOpenBlockers([]);
tc.verifyEqual(s.openBlockersText(), '未取数');
tc.verifyTrue(isempty(s.openBlockers()));
% 负对照 3: 负数被夹到 0, 不出现"负阻塞项"
s.setOpenBlockers(-4, 'probe');
tc.verifyEqual(s.openBlockers(), 0);
end

function test_app_state_closed_gates(tc)
s = stateWithSchema();
s.subscribe(@(evt) 0);
tc.verifyEqual(s.isClosed(), false);
tc.verifyEqual(numel(s.Subscribers), 1);
s.close('窗口关闭');
tc.verifyEqual(s.isClosed(), true);
tc.verifyEqual(s.summary().close_reason, '窗口关闭');
tc.verifyEqual(numel(s.Subscribers), 0, '关窗必须断开订阅者 (回调句柄里存着 self)');
tc.verifyEqual(s.timerState(), 'none', '关窗必须删掉定时器, 不能只停');
tc.verifyTrue(isempty(s.DebounceTimer), 'DebounceTimer 属性必须置空, 否则对象永不回收');
% 写入路径: 按代码实际做法断言 —— 抛 tepc:gui:StateClosed (界面路径靠先查
% isClosed() 拦住, 见 TEPCApp.onCardChange), 不是静默丢弃。
for w = {'setField', 'setFields', 'subscribe', 'validateModel'}
    switch w{1}
        case 'setField'
            f = @() s.setField('gwidth', 1);
        case 'setFields'
            f = @() s.setFields({'gwidth'}, {1});
        case 'subscribe'
            f = @() s.subscribe(@(evt) 0);
        otherwise
            f = @() s.validateModel();
    end
    tc.verifyError(f, 'tepc:gui:StateClosed', sprintf('%s 必须拒绝写入已关闭状态源', w{1}));
end
% 只读与清理路径不得抛错 (关窗后的在途回调要能安静走完)
tc.verifyEqual(s.isClosed(), true);
tc.verifyEqual(s.summary().closed, true);
s.markClean();
tc.verifyTrue(isempty(s.openBlockers()) || isnumeric(s.openBlockers()));
s.setOpenBlockers(2, 'probe');
tc.verifyEqual(s.openBlockers(), 2, '计数登记不依赖状态源开放');
tc.verifyEqual(numel(s.dirty()), 0);
% 延时装载器在关闭后不得复排
armed = s.armDebounce();
tc.verifyEqual(armed, false, 'armDebounce 在关闭后必须直接返回 false');
tc.verifyEqual(s.summary().debounce_armed, false);
tc.verifyEqual(s.timerState(), 'none');
% 负对照: 关闭前同样的调用是允许的
s2 = stateWithSchema();
armedOpen = s2.armDebounce();
tc.verifyTrue(armedOpen || ~isempty(s2.summary().debounce_error), ...
    sprintf('开放状态下要么排上定时器, 要么留下不可用原因 (timer=%s)', s2.timerState()));
s2.close();
tc.verifyEqual(s2.armDebounce(), false, '关闭后不得再排期');
end

function test_app_state_debounce_delay_is_validated(tc)
s = stateWithSchema();
tc.verifyError(@() s.setDebounceDelay('x'), 'tepc:gui:BadDebounceDelay');
tc.verifyError(@() s.setDebounceDelay([0.1 0.2]), 'tepc:gui:BadDebounceDelay');
tc.verifyError(@() s.setDebounceDelay(NaN), 'tepc:gui:BadDebounceDelay');
tc.verifyError(@() s.setDebounceDelay({}), 'tepc:gui:BadDebounceDelay');
% 负对照: 合法值生效, 且非法值没把它改掉
before = s.summary().debounce_delay;
s.setDebounceDelay(0.05);
tc.verifyEqual(s.summary().debounce_delay, 0.05);
tc.verifyNotEqual(s.summary().debounce_delay, before);
% 夹到下限而不是接受 0 (0 秒延后等于没有延后)
s.setDebounceDelay(0);
tc.verifyEqual(s.summary().debounce_delay, 0.01);
end

function test_app_state_field_path_contract_rejects_dotted_tags(tc)
%   字段路径只有一个合法形状: tag 是一个合法 MATLAB 字段名, 多层路径由描述表的
%   path 列用字段名元胞表达。点号串一律具名拒绝 —— 之前它会在 validateField 往
%   FieldIssues 写键时抛裸的 MATLAB:AddField:InvalidFieldName, 既不点名合法形状,
%   也会把整条写入路径打断。
s = stateWithSchema();
% 正向半边: 合法形状端到端可用 (嵌套路径由 path 元胞给)
tc.verifyEqual(strjoin(s.pathFor('gwidth'), '.'), 'geometry.width');
s.setField('gwidth', 46);
tc.verifyEqual(s.fieldValue('gwidth'), 46, '嵌套路径的写入必须落到配置里那一层');
tc.verifyEqual(numel(s.validateField('gwidth')), 0);
s.setField('gwidth', 999);
tc.verifyEqual(numel(s.fieldIssues('gwidth')), 1, '越界问题要按同一个 tag 回读');
% 每个入口都要用同一个标识符拒绝, 而不是只在某一层挡住
bad = {'geo.width', 'a b', '', '1st', 'geometry.width.count'};
for i = 1:numel(bad)
    t = bad{i};
    expectBadPath(tc, 'validateField', @() s.validateField(t), t);
    expectBadPath(tc, 'fieldIssues', @() s.fieldIssues(t), t);
    expectBadPath(tc, 'fieldValue', @() s.fieldValue(t), t);
    expectBadPath(tc, 'pathFor', @() s.pathFor(t), t);
    expectBadPath(tc, 'schemaFor', @() s.schemaFor(t), t);
    expectBadPath(tc, 'setField', @() s.setField(t, 1), t);
    expectBadPath(tc, 'setFields', @() s.setFields({t}, {1}), t);
end
% 描述表里出现点号 tag 时整张表都要拒, 不能收下之后再在写入时炸
S = cell(1, 8);
S{1,1} = 'geo.width'; S{1,2} = {'geometry', 'width'}; S{1,3} = 'num';
expectBadPath(tc, 'setSchema', @() s.setSchema(S), 'geo.width');
% 混合批量: 有一项非法时整批不得落笔 (版本号/脏表/配置值都不动)
s.setField('gcount', 6);
rev = s.summary().revision;
vBefore = s.fieldValue('gwidth');
tc.verifyError(@() s.setFields({'gwidth', 'geo.width'}, {70, 71}), 'tepc:gui:BadFieldPath');
tc.verifyEqual(s.summary().revision, rev, '被拒的批量写入不得推进版本号');
tc.verifyEqual(s.fieldValue('gwidth'), vBefore, '被拒的批量写入不得写入合法的那一半');
% 合法的多层 tag 换个名字就能登记并用起来
S2 = cell(1, 8);
S2{1,1} = 'geo_width'; S2{1,2} = {'geometry', 'width'}; S2{1,3} = 'num';
S2{1,4} = 10; S2{1,5} = 100; S2{1,6} = 1; S2{1,7} = 'mm'; S2{1,8} = 'ASSUMED';
s.setSchema(S2);
s.setField('geo_width', 48);
tc.verifyEqual(s.fieldValue('geo_width'), 48);
tc.verifyEqual(s.config().geometry.width, 48, ...
    '多层路径必须落到配置里那一层, 而不是在根上长出一个 geo_width 字段');
tc.verifyEqual(numel(s.validateField('geo_width')), 0);
tc.verifyEqual(numel(s.fieldIssues('geo_width')), 0, '问题要按同一个 tag 回读');
s.close();
end

function test_app_state_subscriber_error_recorded(tc)
s = stateWithSchema();
tc.verifyEqual(s.summary().subscriber_errors, 0);
s.subscribe(@(evt) error('tepc:test:Sub', '订阅者炸了'));
threw = false;
try
    s.setField('gwidth', 60);
catch
    threw = true;
end
tc.verifyFalse(threw, '订阅者异常不得冲出写入路径 (否则一格输入能让界面崩)');
sm = s.summary();
tc.verifyGreaterThanOrEqual(sm.subscriber_errors, 1, ...
    sprintf('订阅者异常必须计数留痕, 实得 %d', sm.subscriber_errors));
tc.verifyEqual(numel(s.SubscriberErrors), sm.subscriber_errors);
tc.verifyTrue(contains(string(s.SubscriberErrors{1}), '订阅者炸了'), ...
    sprintf('留痕要带根因: %s', s.SubscriberErrors{1}));
% 负对照: 退订后同样的写入不再产生新留痕
s.unsubscribe(1);
tc.verifyEqual(numel(s.Subscribers), 0);
v0 = numel(s.SubscriberErrors);
tc.verifyGreaterThanOrEqual(v0, 1, sprintf('一次写入至少派发一个事件, 实得 %d', v0));
s.unsubscribe(2);
s.setField('gwidth', 61);
tc.verifyEqual(numel(s.SubscriberErrors), v0, ...
    sprintf('退订后不得再有订阅者错误 (%d -> %d)', v0, numel(s.SubscriberErrors)));
tc.verifyEqual(s.fieldValue('gwidth'), 61, '退订后写入仍要生效');
s.close();
end

% ===================== 助手 =====================

function expectBadPath(tc, what, f, tag)
%EXPECTBADPATH 该入口必须用 tepc:gui:BadFieldPath 拒掉非法 tag, 且拒绝文本点名
%   合法形状 (单层用合法字段名, 多层用字段名元胞) —— 只断言"抛了东西"会让裸的
%   MATLAB:AddField:InvalidFieldName 也跑绿。
threw = false; id = ''; ms = '';
try
    f();
catch e
    threw = true;
    id = e.identifier;
    ms = char(string(e.message));
end
tc.verifyTrue(threw, sprintf('%s(''%s'') 必须当场拒绝, 不许静默接受', what, tag));
tc.verifyEqual(id, 'tepc:gui:BadFieldPath', ...
    sprintf('%s 的拒绝必须是具名标识符, 实得 <%s> %s', what, id, ms));
tc.verifyTrue(contains(string(ms), "{'geometry', 'width'}"), ...
    sprintf('%s 的拒绝文本要给出多层路径的合法写法, 实得: %s', what, ms));
tc.verifyTrue(contains(string(ms), '合法字段名'), ...
    sprintf('%s 的拒绝文本要点名单层 tag 的合法形状, 实得: %s', what, ms));
end

function cfg = cfgFixture()
cfg = struct('geometry', struct('width', 42, 'count', 7), ...
    'setup', struct('name', 'rigA'));
end

function s = stateWithSchema()
%STATEWITHSCHEMA 带三行字段描述的状态源。tag 一律是合法字段名, 多层路径写在 path 列
%   的字段名元胞里; 点号串的拒绝由 test_app_state_field_path_contract_rejects_dotted_tags
%   单独锁。
s = AppState(cfgFixture());
S = cell(3, 8);
S{1,1} = 'gwidth';  S{1,2} = {'geometry', 'width'}; S{1,3} = 'num';  S{1,4} = 10; S{1,5} = 100; S{1,6} = 1; S{1,7} = 'mm'; S{1,8} = 'ASSUMED';
S{2,1} = 'gcount';  S{2,2} = {'geometry', 'count'}; S{2,3} = 'int';  S{2,4} = 1;  S{2,5} = 20;  S{2,6} = 1; S{2,7} = '';   S{2,8} = 'MEASURED';
S{3,1} = 'sname';   S{3,2} = {'setup', 'name'};     S{3,3} = 'text'; S{3,4} = []; S{3,5} = []; S{3,6} = []; S{3,7} = '';   S{3,8} = 'REFERENCE';
s.setSchema(S);
end

function b = events(tag)
%EVENTS 事件计数器。计数挂在窗口 appdata 上而不是 getappdata(0,...):
%   本机根对象的 appdata 在测试进程里读不回写入值 (实测 getCount 恒为 0),
%   而窗口 appdata 与句柄同生命周期, 用例结束随驱动 sweep 一起清掉。
h = uifigure('Visible', 'off');
b = struct('fig', h, 'key', ['tepcEv_' tag]);
setappdata(h, b.key, struct('n', 0, 'd', 0));
end

function bump(b, ~)
bumpKind(b, 'field');
end

function bumpKind(b, reason)
% 按事件类别分开计数: field/model 走 n, derived 走 d。
v = getappdata(b.fig, b.key);
if isempty(v), v = struct('n', 0, 'd', 0); end
if strcmp(char(string(reason)), 'derived')
    v.d = v.d + 1;
else
    v.n = v.n + 1;
end
setappdata(b.fig, b.key, v);
end

function n = getDerived(b)
v = getappdata(b.fig, b.key);
if isempty(v), n = 0; else, n = double(v.d); end
end

function n = getCount(b)
v = getappdata(b.fig, b.key);
if isempty(v), n = 0; else, n = double(v.n); end
end
