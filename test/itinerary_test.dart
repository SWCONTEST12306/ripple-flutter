import 'package:flutter_test/flutter_test.dart';
import 'package:ripple_app/features/itinerary/itinerary.dart';

void main() {
  const planner = Planner();

  test('the day summary follows the main task and recognizes the exhibition example', () {
    expect(planner.summaryTitle([]), isNull);
    expect(planner.summaryTitle(planner.example()), '周末看展');

    final shorter = _task('取票', 13 * 60, 15);
    final longer = _task('复习', 14 * 60, 90);
    final equalButEarlier = _task('写报告', 10 * 60, 90);
    final reservation = _task('看电影', 17 * 60, 60, timing: Timing.reservation);
    expect(planner.summaryTitle([shorter, longer]), '复习');
    expect(planner.summaryTitle([shorter, longer, equalButEarlier]), '写报告');
    expect(planner.summaryTitle([shorter, longer, reservation]), '看电影');
  });

  test('a 40 minute delay propagates to the exhibition and return', () {
    final baseline = planner.example();
    expect(planner.analyze(baseline).conflicts, isEmpty);

    final tasks = [
      baseline.first.reschedule(start: 14 * 60 + 40),
      ...baseline.skip(1),
    ];
    final result = planner.analyze(tasks);
    expect(result.conflicts.map((issue) => issue.task.id), [
      Planner.demoExhibition,
      Planner.demoReturn,
    ]);
    expect(result.earliestStarts[Planner.demoExhibition], 14 * 60 + 50);
    expect(result.earliestStarts[Planner.demoReturn], 17 * 60 + 10);

    final options = planner.options(tasks, result);
    expect(options, hasLength(2));
    for (final option in options) {
      expect(planner.analyze(option.tasks).conflicts, isEmpty);
      expect(option.tasks.last.start, 17 * 60);
    }
    expect(options.first.tasks[1].start, 15 * 60);
    expect(options.first.tasks[1].duration, 90);
    expect(options.last.tasks.first.start, 16 * 60 + 30);
    expect(options.last.tasks[1].start, 14 * 60 + 30);
    expect(options.last.tasks.last.after, contains(Planner.demoMeeting));
    expect(tasks[1].start, 14 * 60 + 30);
  });

  test(
    'the later reservation is filtered out when the group cannot reach it',
    () {
      final baseline = planner.example();
      final late = [
        baseline.first.reschedule(start: 15 * 60 + 10),
        ...baseline.skip(1),
      ];
      final options = planner.options(late, planner.analyze(late));
      expect(options, hasLength(1));
      expect(options.single.tasks[1].start, Planner.originalEntry);
      final tooLate = [
        baseline.first.reschedule(start: 17 * 60),
        ...baseline.skip(1),
      ];
      expect(planner.options(tooLate, planner.analyze(tooLate)), isEmpty);
    },
  );

  test('loops are rejected and independent overlapping tasks are flagged', () {
    final baseline = planner.example();
    expect(
      () => planner.analyze([
        baseline.first.reschedule(after: [Planner.demoReturn]),
        ...baseline.skip(1),
      ]),
      throwsFormatException,
    );
    final overlapping = [
      baseline.first.reschedule(start: 15 * 60),
      baseline[1].reschedule(after: []),
      baseline.last,
    ];
    expect(
      planner.analyze(overlapping).conflicts.single.issue,
      TaskIssue.overlap,
    );
  });

  test('the generic option shifts flexible dependencies while treating a fixed follow-up as a deadline', () {
    final tasks = [
      _task('a', 13 * 60, 40),
      _task('b', 13 * 60 + 20, 25, after: ['a']),
      _task('c', 15 * 60, 0, after: ['b'], timing: Timing.fixed),
    ];
    final option = planner.options(tasks, planner.analyze(tasks)).single;
    expect(option.tasks[1].start, 13 * 60 + 45);
    expect(option.tasks.last.start, tasks.last.start);

    final tight = [
      tasks.first,
      tasks[1],
      tasks.last.reschedule(start: 14 * 60),
    ];
    expect(planner.options(tight, planner.analyze(tight)), isEmpty);
  });

  test('overlap options prefer moving lower-priority tasks and preserve fixed times', () {
    final high = _task('会面', 11 * 60, 30, priority: TaskPriority.high);
    final low = _task('购物', 11 * 60, 30, priority: TaskPriority.low);
    final fixed = _task('返程', 17 * 60, 0, timing: Timing.fixed);
    final tasks = [high, low, fixed];
    final options = planner.options(tasks, planner.analyze(tasks));

    expect(options.length, greaterThanOrEqualTo(2));
    expect(options.take(2).map((option) => option.tasks[1].start).toSet(), {
      10 * 60 + 30,
      11 * 60 + 30,
    });
    expect(
      options.take(2).every((option) => option.tasks.first.start == high.start),
      isTrue,
    );
    for (final option in options) {
      expect(option.tasks.last, same(fixed));
      expect(planner.analyze(option.tasks).conflicts, isEmpty);
    }

    final sameTime = [
      fixed,
      _task('另一趟车', fixed.start, 0, timing: Timing.fixed),
    ];
    expect(planner.options(sameTime, planner.analyze(sameTime)), isEmpty);
  });

  test('a delayed task stays at or after the time in the notification', () {
    final meeting = _task('集合', 14 * 60 + 40, 10);
    final reservation = _task(
      '预约',
      14 * 60 + 45,
      30,
      timing: Timing.reservation,
    );
    final tasks = [meeting, reservation];
    final options = planner.options(
      tasks,
      planner.analyze(tasks),
      anchorId: meeting.id,
    );
    expect(options.single.tasks.first.start, 15 * 60 + 15);
    expect(options.single.tasks.last, same(reservation));
    expect(
      planner.options(
        tasks,
        planner.analyze(tasks),
        anchorId: meeting.id,
        lockAnchor: true,
      ),
      isEmpty,
    );
  });

  test('priorities survive plan changes and older tasks default to normal', () {
    final high = _task('集合', 14 * 60, 0, priority: TaskPriority.high);
    final revised = high.reschedule(start: 14 * 60 + 40);
    final saved = revised.toJson();
    expect(ItineraryTask.fromJson(saved).priority, TaskPriority.high);
    expect(
      ItineraryTask.fromJson({...saved}..remove('priority')).priority,
      TaskPriority.normal,
    );
  });
}

ItineraryTask _task(
  String id,
  int start,
  int duration, {
  List<String> after = const [],
  Timing timing = Timing.flexible,
  TaskPriority priority = TaskPriority.normal,
}) => ItineraryTask(
  id: id,
  title: id,
  start: start,
  duration: duration,
  location: '',
  timing: timing,
  priority: priority,
  after: after,
  transfer: 5,
);
