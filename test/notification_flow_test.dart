import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripple_app/features/itinerary/plan_controller.dart';
import 'package:ripple_app/main.dart';

void main() {
  testWidgets(
    'automatic results can be reviewed and added to the extracted date',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      const methods = MethodChannel('ripple/notifications');
      const changes = MethodChannel('ripple/notifications/changes');
      const modelChannel = MethodChannel('ripple/model');
      final messenger = tester.binding.defaultBinaryMessenger;
      final repository = _MemoryPlans();
      var authorized = false;
      var settingsOpened = 0;
      Map<String, Object?>? savedModel;
      final notice = <String, Object?>{
        'key': 'notice-1',
        'packageName': 'example.meetings',
        'source': '会务应用',
        'title': '项目评审改期',
        'text': '明天的项目评审改到 15:30，会议室 A。晚餐预约取消。',
        'postedAt': DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch,
        'utcOffsetMinutes': 480,
      };
      messenger.setMockMethodCallHandler(changes, (_) async => null);
      messenger.setMockMethodCallHandler(modelChannel, (call) async {
        if (call.method == 'save') {
          expect(call.arguments['credential'], 'test-key');
          expect(call.arguments['sources'], {'example.meetings': '会务应用'});
          savedModel = {
            'url': call.arguments['url'],
            'model': call.arguments['model'],
            'sources': call.arguments['sources'],
          };
          return null;
        }
        expect(call.method, 'read');
        return savedModel;
      });
      messenger.setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'openSettings') {
          settingsOpened++;
          return null;
        }
        expect(call.method, 'inbox');
        return {
          'authorized': authorized,
          'entries': [if (authorized) notice],
        };
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(methods, null);
        messenger.setMockMethodCallHandler(changes, null);
        messenger.setMockMethodCallHandler(modelChannel, null);
      });

      Future<void> signalChange() async {
        await messenger.handlePlatformMessage(
          changes.name,
          const StandardMethodCodec().encodeSuccessEnvelope(true),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [planRepositoryProvider.overrideWithValue(repository)],
          child: const RippleApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '通知'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启通知读取权限'));
      expect(settingsOpened, 1);

      authorized = true;
      await signalChange();
      await tester.tap(find.byTooltip('AI 模型设置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, 'test-key');
      await tester.ensureVisible(find.text('会务应用'));
      await tester.tap(find.text('会务应用'));
      await tester.ensureVisible(find.text('保存模型配置'));
      await tester.tap(find.text('保存模型配置'));
      await tester.pumpAndSettle();

      notice['automatic'] = true;
      await signalChange();
      await tester.tap(find.text('项目评审改期'));
      await tester.pumpAndSettle();
      expect(find.text('等待自动提取'), findsOneWidget);
      expect(find.text('用 AI 提取事件'), findsNothing);

      notice['analysis'] = jsonEncode({
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
      });
      await signalChange();
      expect(find.text('新时间　2026-11-25 15:30'), findsOneWidget);
      expect(find.text('加入行程'), findsOneWidget);
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
    },
  );
}

class _MemoryPlans implements PlanRepository {
  final days = <DateTime, SavedPlan>{};

  @override
  Future<SavedPlan> load(DateTime day) async => days[day] ?? SavedPlan([]);

  @override
  Future<void> save(DateTime day, SavedPlan plan) async => days[day] = plan;
}
