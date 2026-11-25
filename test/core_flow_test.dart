import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ripple_app/features/itinerary/day_picker.dart';
import 'package:ripple_app/features/itinerary/itinerary.dart';
import 'package:ripple_app/features/itinerary/plan_controller.dart';
import 'package:ripple_app/main.dart';

void main() {
  test(
    'a stale comparison preserves a plan changed before confirmation',
    () async {
      const planner = Planner();
      final demo = planner.example();
      final old = SavedPlan([
        demo.first.reschedule(start: 14 * 60 + 40),
        ...demo.skip(1),
      ]);
      final repository = _MemoryRepository()..plan = old;
      final container = ProviderContainer(
        overrides: [planRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final day = DateTime(2026, 11, 25);
      final provider = itineraryProvider(day);
      final reviewed = await container.read(provider.future);
      final options = planner.options(old.tasks, planner.analyze(old.tasks));
      final newer = old.withTasks([
        ...old.tasks.take(2),
        old.tasks.last.reschedule(start: 18 * 60),
      ]);
      repository.plan = newer;

      await expectLater(
        container.read(provider.notifier).applyOption(options.first, reviewed),
        throwsFormatException,
      );
      expect(repository.plan, same(newer));
    },
  );

  testWidgets('reopening the app returns the schedule to today', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    Future<void> setLifecycle(AppLifecycleState state) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        const StringCodec().encodeMessage(state.toString()),
        (_) {},
      );
    }

    final today = planDay(DateTime.now());
    final otherDay = DateTime(today.year, today.month, today.day == 1 ? 2 : 1);
    final todayButton = find.widgetWithText(TextButton, planDayLabel(today));
    final otherDayButton = find.widgetWithText(
      TextButton,
      planDayLabel(otherDay),
    );
    await setLifecycle(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          planRepositoryProvider.overrideWithValue(_MemoryRepository()),
        ],
        child: const RippleApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(todayButton, findsOneWidget);

    await tester.tap(todayButton);
    await tester.pumpAndSettle();
    final calendar = find.byType(CalendarDatePicker);
    await tester.tap(
      find.descendant(of: calendar, matching: find.text('${otherDay.day}')),
    );
    final localizations = MaterialLocalizations.of(tester.element(calendar));
    await tester.tap(
      find.widgetWithText(TextButton, localizations.okButtonLabel),
    );
    await tester.pumpAndSettle();
    expect(otherDayButton, findsOneWidget);

    await setLifecycle(AppLifecycleState.inactive);
    await setLifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(otherDayButton, findsOneWidget);

    await setLifecycle(AppLifecycleState.paused);
    await setLifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(todayButton, findsOneWidget);
  });

  testWidgets('the example can be planned, reviewed, confirmed and reloaded', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final repository = _MemoryRepository();
    Widget app(Key key) => ProviderScope(
      key: key,
      overrides: [planRepositoryProvider.overrideWithValue(repository)],
      child: const RippleApp(),
    );
    await tester.pumpWidget(app(const ValueKey(1)));
    await tester.pumpAndSettle();
    expect(find.text('涟漪 · 日程'), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('查看冲突'), findsNothing);
    await tester.tap(find.text('创建看展示例'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Card, '周末看展'), findsOneWidget);
    expect(find.text('3 项行程'), findsOneWidget);
    expect(find.text('14:30'), findsOneWidget);

    await tester.tap(find.widgetWithText(NavigationDestination, '关系'));
    await tester.pumpAndSettle();
    expect(find.text('行程关系'), findsOneWidget);
    expect(find.textContaining('在 14:00 与朋友集合 之后开始'), findsOneWidget);
    await tester.tap(find.widgetWithText(NavigationDestination, '日程'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('模拟朋友晚到 40 分钟'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.widgetWithText(Card, '2 项行程有时间冲突'),
        matching: find.widgetWithText(TextButton, '查看冲突'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('查看冲突'));
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(FilledButton, '确认并更新行程');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(find.text('改到 15:00 入场'));
    expect(repository.plan.tasks[1].start, Planner.originalEntry);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.text('已应用方案：改到 15:00 入场'), findsOneWidget);
    expect(find.text('查看冲突'), findsNothing);

    await tester.pumpWidget(app(const ValueKey(2)));
    await tester.pumpAndSettle();
    expect(find.text('15:00'), findsOneWidget);
    expect(find.text('17:00'), findsOneWidget);
  });

  testWidgets('summary and warning stay fixed while the timeline scrolls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final example = const Planner().example();
    final repository = _MemoryRepository()
      ..plan = SavedPlan([
        example.first.reschedule(start: 14 * 60 + 40),
        ...example.skip(1),
        for (var index = 0; index < 12; index++)
          ItineraryTask(
            id: 'extra-$index',
            title: '晚间行程 $index',
            start: 18 * 60 + index * 10,
            duration: 5,
            location: '',
            timing: Timing.flexible,
          ),
      ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [planRepositoryProvider.overrideWithValue(repository)],
        child: const RippleApp(),
      ),
    );
    await tester.pumpAndSettle();
    final add = find.byType(FloatingActionButton).hitTestable();
    final review = find.widgetWithText(TextButton, '查看冲突').hitTestable();
    final summary = find.text('周末看展');
    final warning = find.text('2 项行程有时间冲突');
    final summaryOrigin = tester.getTopLeft(summary);
    final warningOrigin = tester.getTopLeft(warning);
    final reviewOrigin = tester.getTopLeft(review);
    final navOrigin = tester.getTopLeft(find.byType(NavigationBar));
    expect(add, findsOneWidget);
    expect(review, findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, -30));
    await gesture.moveBy(const Offset(0, -150));
    await tester.pump();
    final timeline = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(timeline.position.pixels, greaterThan(0));
    expect(tester.getTopLeft(summary), summaryOrigin);
    expect(tester.getTopLeft(warning), warningOrigin);
    expect(tester.getTopLeft(review), reviewOrigin);
    expect(tester.getTopLeft(find.byType(NavigationBar)), navOrigin);
    expect(add, findsNothing);
    expect(review, findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(add, findsOneWidget);
    expect(review, findsOneWidget);
  });
}

class _MemoryRepository implements PlanRepository {
  SavedPlan plan = SavedPlan([]);

  @override
  Future<SavedPlan> load(DateTime day) async => plan;

  @override
  Future<void> save(DateTime day, SavedPlan next) async => plan = next;
}
