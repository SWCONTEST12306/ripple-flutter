import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripple_app/features/itinerary/itinerary.dart';
import 'package:ripple_app/features/itinerary/plan_controller.dart';
import 'package:ripple_app/features/notifications/notification_analysis.dart';
import 'package:ripple_app/features/notifications/notification_association.dart';
import 'package:ripple_app/features/notifications/notification_event.dart';
import 'package:ripple_app/features/notifications/notification_import.dart';
import 'package:ripple_app/features/notifications/notification_inbox.dart';
import 'package:ripple_app/main.dart';

void main() {
  testWidgets('the settings page stores the model and the readable apps', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final messenger = tester.binding.defaultBinaryMessenger;
    final repository = _MemoryPlans();
    final store = _MemoryImportStore();
    Map<String, Object?>? savedModel;
    const authorized = true;
    var master = false;
    final enabledApps = <String, String>{};

    _mockChannels(
      messenger,
      model: () => savedModel,
      onModelSave: (arguments) {
        savedModel = arguments;
      },
      sources: () => {
        'authorized': authorized,
        'master': master,
        'apps': Map<String, String>.of(enabledApps),
      },
      onSourcesSave: (arguments) {
        master = arguments['master'] as bool;
        enabledApps
          ..clear()
          ..addAll((arguments['apps'] as Map).cast<String, String>());
      },
      inbox: () => {'authorized': authorized, 'entries': const <Object?>[]},
    );

    await tester.pumpWidget(_app(repository, store));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NavigationDestination, '设置'));
    await tester.pumpAndSettle();
    expect(find.text('允许读取通知的应用'), findsOneWidget);
    expect(find.text('查看最近通知'), findsOneWidget);
    expect(find.text('AI 模型设置'), findsOneWidget);

    await tester.tap(find.text('AI 模型设置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'test-key');
    await tester.ensureVisible(find.text('保存模型配置'));
    await tester.tap(find.text('保存模型配置'));
    await tester.pumpAndSettle();
    expect(savedModel?['credential'], 'test-key');
    expect(find.text('允许读取通知的应用'), findsOneWidget);

    await tester.tap(find.text('允许读取通知的应用'));
    await tester.pumpAndSettle();
    expect(find.text('会务应用'), findsOneWidget);
    await tester.tap(find.text('允许读取应用通知'));
    await tester.pumpAndSettle();
    expect(master, isTrue);
    await tester.tap(find.text('会务应用'));
    await tester.pumpAndSettle();
    expect(enabledApps, {'example.meetings': '会务应用'});
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('已开启 1 个应用'), findsOneWidget);
  });

  testWidgets('a parsed notification is added and reviewed on the next start', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final messenger = tester.binding.defaultBinaryMessenger;
    final repository = _MemoryPlans();
    final store = _MemoryImportStore();
    final notice = _notice();

    _mockChannels(
      messenger,
      model: () => {
        'url': 'https://api.deepseek.com',
        'model': 'deepseek-flash',
      },
      onModelSave: (_) {},
      sources: () => {
        'authorized': true,
        'master': true,
        'apps': {'example.meetings': '会务应用'},
      },
      onSourcesSave: (_) {},
      inbox: () => {
        'authorized': true,
        'entries': [notice],
      },
    );

    await tester.pumpWidget(_app(repository, store));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    final plannedDay = DateTime(2026, 11, 25);
    expect(repository.days[plannedDay]!.tasks.single.title, '项目评审');
    expect(repository.days[plannedDay]!.tasks.single.start, 15 * 60 + 30);
    expect(find.text('已自动加入日程'), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('项目评审')),
      findsOneWidget,
    );

    await tester.tap(find.descendant(of: dialog, matching: find.text('项目评审')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(repository.days[plannedDay]!.tasks, isEmpty);
    expect(store.pendingItems, isEmpty);
    expect(store.importedIds, hasLength(1));
  });

  testWidgets('a repeated notification that disagrees with the edited time', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final messenger = tester.binding.defaultBinaryMessenger;
    final repository = _MemoryPlans();
    final notice = _notice();
    final parsed =
        jsonDecode(notice['analysis'] as String) as Map<String, dynamic>;
    final event = ExtractedEvent.fromJson(
      (parsed['events'] as List).first as Map<String, dynamic>,
    );
    final id = notificationTaskId(AndroidNotice.fromMap(notice), event);
    final day = DateTime(2026, 11, 25);
    // 用户把自动加入的 15:30 改成了 16:00。
    repository.days[day] = SavedPlan([
      ItineraryTask(
        id: id,
        title: '项目评审',
        start: 16 * 60,
        duration: 45,
        location: '会议室 A',
        timing: Timing.flexible,
      ),
    ]);
    final store = _MemoryImportStore(imported: [id]);

    _mockChannels(
      messenger,
      model: () => {
        'url': 'https://api.deepseek.com',
        'model': 'deepseek-flash',
      },
      onModelSave: (_) {},
      sources: () => {
        'authorized': true,
        'master': true,
        'apps': {'example.meetings': '会务应用'},
      },
      onSourcesSave: (_) {},
      inbox: () => {
        'authorized': true,
        'entries': [notice],
      },
    );

    await tester.pumpWidget(_app(repository, store));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('又收到相同的通知'), findsOneWidget);
    expect(find.textContaining('当前日程　16:00'), findsOneWidget);
    await tester.tap(find.text('另加一项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(repository.days[day]!.tasks, hasLength(2));
    final copy = repository.days[day]!.tasks.firstWhere(
      (task) => task.id != id,
    );
    expect(copy.title, '项目评审');
    expect(copy.start, 15 * 60 + 30);
    expect(store.pendingItems, isEmpty);
  });

  testWidgets('reviewed events can still be added from the notification', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final messenger = tester.binding.defaultBinaryMessenger;
    final repository = _MemoryPlans();
    var settingsOpened = 0;
    final notice = _notice();
    final parsed =
        jsonDecode(notice['analysis'] as String) as Map<String, dynamic>;
    final event = ExtractedEvent.fromJson(
      (parsed['events'] as List).first as Map<String, dynamic>,
    );
    final store = _MemoryImportStore(
      imported: [notificationTaskId(AndroidNotice.fromMap(notice), event)],
    );

    _mockChannels(
      messenger,
      model: () => {
        'url': 'https://api.deepseek.com',
        'model': 'deepseek-flash',
      },
      onModelSave: (_) {},
      sources: () => {
        'authorized': true,
        'master': true,
        'apps': {'example.meetings': '会务应用'},
      },
      onSourcesSave: (_) {},
      inbox: () => {
        'authorized': true,
        'entries': [notice],
      },
      onOpenSettings: () => settingsOpened++,
    );

    await tester.pumpWidget(_app(repository, store));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.widgetWithText(NavigationDestination, '设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看最近通知'));
    await tester.pumpAndSettle();
    expect(find.text('项目评审安排'), findsOneWidget);
    expect(settingsOpened, 0);

    await tester.tap(find.text('项目评审安排'));
    await tester.pumpAndSettle();
    expect(find.text('时间　2026-11-25 15:30'), findsOneWidget);
    final add = find.text('加入行程');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(repository.days, isEmpty);
    expect(find.text('2026年11月25日'), findsOneWidget);
    expect(find.text('开始时间　15:30'), findsOneWidget);
    expect(find.text('会议室 A'), findsOneWidget);
    final save = find.text('保存行程');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final plannedDay = DateTime(2026, 11, 25);
    final saved = repository.days[plannedDay]!.tasks.single;
    expect(saved.title, '项目评审');
    expect(saved.start, 15 * 60 + 30);
    expect(saved.duration, 45);
    expect(saved.location, '会议室 A');
    final view = find.text('已加入 · 查看行程');
    await tester.ensureVisible(view);
    await tester.tap(view);
    await tester.pumpAndSettle();
    expect(find.text('2026年11月25日'), findsOneWidget);
    expect(find.text('15:30'), findsOneWidget);
    expect(find.text('1 项行程'), findsOneWidget);
  });

  testWidgets(
    'a delay propagates from the meeting to the exhibition and return',
    (tester) async {
      final day = DateTime(2026, 11, 25);
      final repository = _MemoryPlans()
        ..days[day] = SavedPlan(const Planner().example());
      final links = _MemoryLinkStore();
      final before = repository.days[day];
      _mockAssociationInbox(tester, _delayNotice());

      await tester.pumpWidget(_app(repository, _MemoryImportStore(), links));
      await tester.pumpAndSettle();
      expect(links.links.values.single?.taskId, Planner.demoMeeting);
      await _openAssociation(tester);
      expect(find.text('已关联：与朋友集合'), findsOneWidget);
      expect(find.text('变动待确认'), findsOneWidget);
      expect(find.text('事件影响预览'), findsOneWidget);
      expect(find.text('「展馆入场」'), findsOneWidget);
      expect(find.text('原定 14:30 · 预计最早 14:50'), findsOneWidget);
      expect(find.text('可能错过预约（晚 20 分钟）'), findsOneWidget);
      expect(find.text('「乘车返程」'), findsOneWidget);
      expect(find.text('原定 17:00 · 预计最早 17:10'), findsOneWidget);
      expect(find.text('可能赶不上固定时间（晚 10 分钟）'), findsOneWidget);
      expect(find.text('加入行程'), findsNothing);
      expect(repository.days[day], same(before));
      final view = find.text('查看关联行程');
      await tester.ensureVisible(view);
      await tester.tap(view);
      await tester.pumpAndSettle();
      expect(find.text('2026年11月25日'), findsOneWidget);
    },
  );

  testWidgets(
    'the delayed notice compares two plans and saves only the selected one',
    (tester) async {
      final day = DateTime(2026, 11, 25);
      final before = SavedPlan(const Planner().example());
      final repository = _MemoryPlans()..days[day] = before;
      final imports = _MemoryImportStore();
      final links = _MemoryLinkStore();
      final notice = _delayNotice();
      _mockAssociationInbox(tester, notice);

      await tester.pumpWidget(_app(repository, imports, links));
      await tester.pumpAndSettle();
      await _openAssociation(tester);
      final compare = find.text('对比重规划方案');
      await tester.ensureVisible(compare);
      await tester.tap(compare);
      await tester.pumpAndSettle();
      expect(find.text('智能重规划'), findsOneWidget);
      expect(find.text('保留固定时间　乘车返程 17:00'), findsOneWidget);
      expect(find.text('改到 15:00 入场'), findsOneWidget);
      final confirm = find.widgetWithText(FilledButton, '确认并更新行程');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      final alternative = find.text('按原时间入场，看完展再会合');
      await tester.drag(find.byType(ListView), const Offset(0, -460));
      await tester.pumpAndSettle();
      await tester.tap(alternative);
      await tester.pumpAndSettle();
      expect(repository.days[day], same(before));
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      final saved = repository.days[day]!;
      final [meeting, exhibition, returning] = saved.tasks;
      expect(meeting.start, 16 * 60 + 30);
      expect(exhibition.start, Planner.originalEntry);
      expect(exhibition.duration, 120);
      expect(returning.start, 17 * 60);
      expect(const Planner().analyze(saved.tasks).conflicts, isEmpty);
      expect(saved.appliedNotices, hasLength(1));
      expect(find.textContaining('已应用方案'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app(repository, imports, links));
      await tester.pumpAndSettle();
      expect(find.byTooltip('查看通知关联'), findsNothing);
      await tester.tap(find.widgetWithText(NavigationDestination, '设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看最近通知'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小明'));
      await tester.pumpAndSettle();
      expect(find.text('已按此通知调整'), findsOneWidget);
      expect(find.text('对比重规划方案'), findsNothing);
      expect(repository.days[day], same(saved));
    },
  );

  testWidgets('a sufficient buffer absorbs the delay before the next task', (
    tester,
  ) async {
    final day = DateTime(2026, 11, 25);
    final [meeting, exhibition, returning] = const Planner().example();
    final before = SavedPlan([
      meeting,
      exhibition.reschedule(start: 15 * 60),
      returning.reschedule(start: 18 * 60),
    ]);
    final repository = _MemoryPlans()..days[day] = before;
    _mockAssociationInbox(tester, _delayNotice());

    await tester.pumpWidget(_app(repository, _MemoryImportStore()));
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看通知关联'), findsNothing);
    await tester.tap(find.widgetWithText(NavigationDestination, '设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看最近通知'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    expect(find.text('「展馆入场」'), findsOneWidget);
    expect(find.text('原定 15:00 · 预计最早 15:00'), findsOneWidget);
    expect(find.textContaining('延误已被本段缓冲吸收'), findsOneWidget);
    expect(find.text('「乘车返程」'), findsNothing);
    expect(repository.days[day], same(before));
  });

  testWidgets('an unrelated itinerary is outside the impact preview', (
    tester,
  ) async {
    final day = DateTime(2026, 11, 25);
    final unrelated = ItineraryTask(
      id: 'reading',
      title: '图书馆自习',
      start: 10 * 60,
      duration: 30,
      location: '图书馆',
      timing: Timing.fixed,
    );
    final before = SavedPlan([unrelated, ...const Planner().example()]);
    final repository = _MemoryPlans()..days[day] = before;
    _mockAssociationInbox(tester, _delayNotice());

    await tester.pumpWidget(_app(repository, _MemoryImportStore()));
    await tester.pumpAndSettle();
    await _openAssociation(tester);
    expect(find.text('事件影响预览'), findsOneWidget);
    expect(find.text('「乘车返程」'), findsOneWidget);
    expect(find.textContaining('图书馆自习'), findsNothing);
    expect(repository.days[day], same(before));
    expect(repository.days[day]!.tasks.first, same(unrelated));
    expect(unrelated.start, 10 * 60);
  });

  testWidgets('two plausible events require a choice and keep it on restart', (
    tester,
  ) async {
    final day = DateTime(2026, 11, 25);
    final before = SavedPlan([
      ItineraryTask(
        id: 'exhibition',
        title: '和小明看展',
        start: 14 * 60,
        duration: 60,
        location: '美术馆',
        timing: Timing.flexible,
      ),
      ItineraryTask(
        id: 'meet',
        title: '与小明喝咖啡',
        start: 16 * 60,
        duration: 30,
        location: '咖啡馆',
        timing: Timing.flexible,
      ),
    ]);
    final repository = _MemoryPlans()..days[day] = before;
    final links = _MemoryLinkStore();
    final imports = _MemoryImportStore();
    _mockAssociationInbox(tester, _delayNotice());

    await tester.pumpWidget(_app(repository, imports, links));
    await tester.pumpAndSettle();
    expect(links.links, isEmpty);
    await _openAssociation(tester);
    final select = find.text('选择关联行程');
    await tester.ensureVisible(select);
    await tester.tap(select);
    await tester.pumpAndSettle();
    expect(find.text('和小明看展'), findsOneWidget);
    expect(find.text('与小明喝咖啡'), findsOneWidget);
    await tester.tap(find.text('与小明喝咖啡'));
    await tester.pumpAndSettle();
    expect(find.text('已关联：与小明喝咖啡'), findsOneWidget);
    expect(links.links.values.single?.taskId, 'meet');
    expect(repository.days[day], same(before));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(repository, imports, links));
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看通知关联'), findsNothing);
    expect(links.links.values.single?.taskId, 'meet');
  });

  testWidgets('ordinary chat leaves the plan and reminders unchanged', (
    tester,
  ) async {
    final day = DateTime(2026, 11, 25);
    final before = SavedPlan(const Planner().example());
    final repository = _MemoryPlans()..days[day] = before;
    final links = _MemoryLinkStore();
    final imports = _MemoryImportStore();
    _mockAssociationInbox(tester, _delayNotice(ordinary: true));

    await tester.pumpWidget(_app(repository, imports, links));
    await tester.pumpAndSettle();
    expect(links.links, isEmpty);
    expect(imports.pendingItems, isEmpty);
    expect(find.byTooltip('查看通知关联'), findsNothing);
    expect(repository.days[day], same(before));
  });

  testWidgets(
    'explicit changes use the original date and never add duplicates',
    (tester) async {
      final day = DateTime(2026, 11, 25);
      final plan = SavedPlan([
        ItineraryTask(
          id: 'review',
          title: '项目评审',
          start: 14 * 60,
          duration: 30,
          location: '会议室 A',
          timing: Timing.reservation,
        ),
        ItineraryTask(
          id: 'dinner',
          title: '晚餐预约',
          start: 18 * 60,
          duration: 60,
          location: '餐厅',
          timing: Timing.reservation,
        ),
      ]);
      final repository = _MemoryPlans()..days[day] = plan;
      final links = _MemoryLinkStore();
      final imports = _MemoryImportStore();
      _mockAssociationInbox(tester, {
        ..._notice(),
        'title': '安排有变',
        'text': '明天 14:00 的项目评审推迟到后天 15:30。明天的晚餐预约取消。',
        'analysis': jsonEncode({
          'summary': '项目评审改期，晚餐预约取消',
          'events': [
            {
              'kind': 'changed',
              'title': '项目评审',
              'original_date': '2026-11-25',
              'original_time': '14:00',
              'date': '2026-11-26',
              'time': '15:30',
              'evidence': '明天 14:00 的项目评审推迟到后天 15:30。',
            },
            {'kind': 'cancelled', 'title': '晚餐预约', 'evidence': '明天的晚餐预约取消。'},
          ],
        }),
      });

      await tester.pumpWidget(_app(repository, imports, links));
      await tester.pumpAndSettle();
      expect(links.links.values.map((link) => link?.taskId), [
        'review',
        'dinner',
      ]);
      expect(links.links.values.map((link) => link?.day), everyElement(day));
      expect(repository.days, {day: plan});
      expect(imports.pendingItems, isEmpty);
      expect(find.byTooltip('查看通知关联'), findsOneWidget);
    },
  );
}

Widget _app(
  PlanRepository repository,
  NotificationImportStore store, [
  NotificationLinkStore? links,
]) => ProviderScope(
  overrides: [
    planRepositoryProvider.overrideWithValue(repository),
    notificationImportStoreProvider.overrideWithValue(store),
    notificationLinkStoreProvider.overrideWithValue(
      links ?? _MemoryLinkStore(),
    ),
  ],
  child: const RippleApp(),
);

Map<String, Object?> _notice() => {
  'key': 'notice-1',
  'packageName': 'example.meetings',
  'source': '会务应用',
  'title': '项目评审安排',
  'text': '明天 15:30 召开项目评审，会议室 A。',
  'postedAt': DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch,
  'utcOffsetMinutes': 480,
  'automatic': true,
  'analysis': jsonEncode({
    'summary': '评审安排在明天下午',
    'events': [
      {
        'kind': 'new',
        'title': '项目评审',
        'date': '2026-11-25',
        'time': '15:30',
        'location': '会议室 A',
        'duration_minutes': 45,
        'evidence': '明天 15:30 召开项目评审，会议室 A。',
      },
    ],
  }),
};

Map<String, Object?> _delayNotice({bool ordinary = false}) {
  final message = ordinary ? '我刚看到消息，晚点聊。' : '我今天下午可能要晚到40分钟。';
  return {
    ..._notice(),
    'title': '小明',
    'text': message,
    'postedAt': DateTime.utc(2026, 11, 24, 17).millisecondsSinceEpoch,
    'analysis': jsonEncode({
      'summary': ordinary ? '未发现行程事件' : '小明可能晚到 40 分钟',
      'events': [
        if (!ordinary)
          {
            'kind': 'delayed',
            'title': '小明可能迟到',
            'people': ['小明'],
            'delay_minutes': 40,
            'tentative': true,
            'evidence': message,
          },
      ],
    }),
  };
}

void _mockAssociationInbox(WidgetTester tester, Map<String, Object?> notice) {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  _mockChannels(
    tester.binding.defaultBinaryMessenger,
    model: () => null,
    onModelSave: (_) {},
    sources: () => {'authorized': true, 'master': true},
    onSourcesSave: (_) {},
    inbox: () => {
      'authorized': true,
      'entries': [notice],
    },
  );
}

Future<void> _openAssociation(WidgetTester tester) async {
  await tester.tap(find.byTooltip('查看通知关联'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('小明'));
  await tester.pumpAndSettle();
}

class _MemoryLinkStore implements NotificationLinkStore {
  Map<String, ScheduleLink?> links = {};

  @override
  Future<Map<String, ScheduleLink?>> read() async => Map.of(links);

  @override
  Future<void> write(Map<String, ScheduleLink?> values) async =>
      links = Map.of(values);
}

void _mockChannels(
  TestDefaultBinaryMessenger messenger, {
  required Map<String, Object?>? Function() model,
  required void Function(Map<String, Object?> arguments) onModelSave,
  required Map<String, Object?> Function() sources,
  required void Function(Map<String, Object?> arguments) onSourcesSave,
  required Map<String, Object?> Function() inbox,
  void Function()? onOpenSettings,
}) {
  const methods = MethodChannel('ripple/notifications');
  const changes = MethodChannel('ripple/notifications/changes');
  const modelChannel = MethodChannel('ripple/model');
  const sourcesChannel = MethodChannel('ripple/notification-sources');
  const debugChannel = MethodChannel('ripple/debug');

  messenger.setMockMethodCallHandler(changes, (_) async => null);
  messenger.setMockMethodCallHandler(debugChannel, (call) async {
    expect(call.method, 'read');
    return {'blockApi': false};
  });
  messenger.setMockMethodCallHandler(modelChannel, (call) async {
    if (call.method == 'save') {
      onModelSave(Map<String, Object?>.from(call.arguments as Map));
      return null;
    }
    expect(call.method, 'read');
    return model();
  });
  messenger.setMockMethodCallHandler(sourcesChannel, (call) async {
    switch (call.method) {
      case 'read':
        return sources();
      case 'save':
        onSourcesSave(Map<String, Object?>.from(call.arguments as Map));
        return null;
      case 'apps':
        return [
          {'packageName': 'example.meetings', 'label': '会务应用'},
        ];
      case 'icon':
        return null;
      default:
        throw PlatformException(code: 'unexpected_sources_call');
    }
  });
  messenger.setMockMethodCallHandler(methods, (call) async {
    if (call.method == 'openSettings') {
      onOpenSettings?.call();
      return null;
    }
    expect(call.method, 'inbox');
    return inbox();
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(changes, null);
    messenger.setMockMethodCallHandler(modelChannel, null);
    messenger.setMockMethodCallHandler(sourcesChannel, null);
    messenger.setMockMethodCallHandler(debugChannel, null);
  });
}

class _MemoryImportStore implements NotificationImportStore {
  _MemoryImportStore({Iterable<String> imported = const []}) {
    importedIds.addAll(imported);
  }

  final pendingItems = <PendingAddition>[];
  final importedIds = <String>{};
  final reminderKeys = <String>{};

  @override
  Future<List<PendingAddition>> pending() async => List.of(pendingItems);

  @override
  Future<void> writePending(List<PendingAddition> items) async {
    pendingItems
      ..clear()
      ..addAll(items);
  }

  @override
  Future<Set<String>> imported() async => Set.of(importedIds);

  @override
  Future<void> markImported(Iterable<String> ids) async {
    importedIds.addAll(ids);
  }

  @override
  Future<Set<String>> reminders() async => Set.of(reminderKeys);

  @override
  Future<void> markReminded(Iterable<String> keys) async {
    reminderKeys.addAll(keys);
  }
}

class _MemoryPlans implements PlanRepository {
  final days = <DateTime, SavedPlan>{};

  @override
  Future<SavedPlan> load(DateTime day) async => days[day] ?? SavedPlan([]);

  @override
  Future<void> save(DateTime day, SavedPlan plan) async => days[day] = plan;
}
