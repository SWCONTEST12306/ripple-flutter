import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripple_app/features/itinerary/plan_controller.dart';
import 'package:ripple_app/features/notifications/notification_analysis.dart';
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

    await tester.pumpWidget(
      _app(repository, store),
    );
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
    await tester.pageBack();
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
      model: () => {'url': 'https://api.deepseek.com', 'model': 'deepseek-flash'},
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

    await tester.tap(
      find.descendant(of: dialog, matching: find.text('项目评审')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(repository.days[plannedDay]!.tasks, isEmpty);
    expect(store.pendingItems, isEmpty);
    expect(store.importedIds, hasLength(1));
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
    final parsed = jsonDecode(notice['analysis'] as String) as Map<String, dynamic>;
    final event = ExtractedEvent.fromJson(
      (parsed['events'] as List).first as Map<String, dynamic>,
    );
    final store = _MemoryImportStore(
      imported: [notificationTaskId(AndroidNotice.fromMap(notice), event)],
    );

    _mockChannels(
      messenger,
      model: () => {'url': 'https://api.deepseek.com', 'model': 'deepseek-flash'},
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
    expect(find.text('已自动加入日程'), findsNothing);
    await tester.tap(find.widgetWithText(NavigationDestination, '设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看最近通知'));
    await tester.pumpAndSettle();
    expect(find.text('项目评审改期'), findsOneWidget);
    expect(settingsOpened, 0);

    await tester.tap(find.text('项目评审改期'));
    await tester.pumpAndSettle();
    expect(find.text('新时间　2026-11-25 15:30'), findsOneWidget);
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
}

Widget _app(PlanRepository repository, NotificationImportStore store) =>
    ProviderScope(
      overrides: [
        planRepositoryProvider.overrideWithValue(repository),
        notificationImportStoreProvider.overrideWithValue(store),
      ],
      child: const RippleApp(),
    );

Map<String, Object?> _notice() => {
  'key': 'notice-1',
  'packageName': 'example.meetings',
  'source': '会务应用',
  'title': '项目评审改期',
  'text': '明天的项目评审改到 15:30，会议室 A。晚餐预约取消。',
  'postedAt': DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch,
  'utcOffsetMinutes': 480,
  'automatic': true,
  'analysis': jsonEncode({
    'summary': '评审改到明天下午，晚餐取消',
    'events': [
      {
        'kind': 'changed',
        'title': '项目评审',
        'date': '2026-11-25',
        'time': '15:30',
        'location': '会议室 A',
        'duration_minutes': 45,
        'evidence': '明天的项目评审改到 15:30，会议室 A。',
      },
      {'kind': 'cancelled', 'title': '晚餐预约', 'evidence': '晚餐预约取消。'},
    ],
  }),
};

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

  messenger.setMockMethodCallHandler(changes, (_) async => null);
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
  });
}

class _MemoryImportStore implements NotificationImportStore {
  _MemoryImportStore({Iterable<String> imported = const []}) {
    importedIds.addAll(imported);
  }

  final pendingItems = <PendingAddition>[];
  final importedIds = <String>{};

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
}

class _MemoryPlans implements PlanRepository {
  final days = <DateTime, SavedPlan>{};

  @override
  Future<SavedPlan> load(DateTime day) async => days[day] ?? SavedPlan([]);

  @override
  Future<void> save(DateTime day, SavedPlan plan) async => days[day] = plan;
}
