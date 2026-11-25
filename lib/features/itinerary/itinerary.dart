import 'dart:convert';

const minutesPerDay = 24 * 60;

String clockTime(int minutes) {
  final days = minutes ~/ minutesPerDay;
  final hours = (minutes ~/ 60 % 24).toString().padLeft(2, '0');
  final remainder = (minutes % 60).toString().padLeft(2, '0');
  final day = switch (days) {
    0 => '',
    1 => '次日 ',
    _ => '$days 天后 ',
  };
  return '$day$hours:$remainder';
}

enum Timing {
  flexible('可调整'),
  reservation('预约时段'),
  fixed('固定时间');

  const Timing(this.label);
  final String label;
}

enum TaskPriority {
  high('高'),
  normal('普通'),
  low('低');

  const TaskPriority(this.label);
  final String label;
}

class ItineraryTask {
  ItineraryTask({
    required this.id,
    required this.title,
    required this.start,
    required this.duration,
    required this.location,
    required this.timing,
    this.priority = TaskPriority.normal,
    Iterable<String> people = const [],
    this.transfer = 0,
    Iterable<String> after = const [],
  }) : people = List.unmodifiable(people),
       after = List.unmodifiable(after);

  final String id;
  final String title;
  final int start;
  final int duration;
  final String location;
  final Timing timing;
  final TaskPriority priority;
  final List<String> people;
  final int transfer;
  final List<String> after;

  int get end => start + duration;

  ItineraryTask reschedule({
    int? start,
    int? duration,
    String? location,
    List<String>? after,
    int? transfer,
  }) => ItineraryTask(
    id: id,
    title: title,
    start: start ?? this.start,
    duration: duration ?? this.duration,
    location: location ?? this.location,
    timing: timing,
    priority: priority,
    people: people,
    transfer: transfer ?? this.transfer,
    after: after ?? this.after,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'start': start,
    'duration': duration,
    'location': location,
    'timing': timing.name,
    'priority': priority.name,
    if (people.isNotEmpty) 'people': people,
    'transfer': transfer,
    'after': after,
  };

  factory ItineraryTask.fromJson(Map<String, dynamic> json) => ItineraryTask(
    id: json['id'] as String,
    title: json['title'] as String,
    start: json['start'] as int,
    duration: json['duration'] as int,
    location: json['location'] as String,
    timing: Timing.values.byName(json['timing'] as String),
    priority: TaskPriority.values.firstWhere(
      (priority) => priority.name == json['priority'],
      orElse: () => TaskPriority.normal,
    ),
    people: (json['people'] as List?)?.cast<String>() ?? const [],
    transfer: json['transfer'] as int,
    after: (json['after'] as List).cast<String>(),
  );
}

enum TaskIssue { dependency, overlap, beyondDay }

class TaskConflict {
  const TaskConflict(this.task, this.earliest, this.issue, {this.predecessor});

  final ItineraryTask task;
  final int earliest;
  final TaskIssue issue;
  final ItineraryTask? predecessor;

  String get summary => switch (issue) {
    TaskIssue.dependency =>
      '「${predecessor!.title}」结束并完成转场后，最早 ${clockTime(earliest)} 开始。',
    TaskIssue.overlap => '和「${predecessor!.title}」的时间重叠。',
    TaskIssue.beyondDay => '按当前安排，${task.title} 会跨到次日。',
  };
}

class PlanAnalysis {
  const PlanAnalysis(this.conflicts, this.earliestStarts);
  final List<TaskConflict> conflicts;
  final Map<String, int> earliestStarts;
}

class ReplanOption {
  const ReplanOption(this.title, this.description, this.tasks);
  final String title;
  final String description;
  final List<ItineraryTask> tasks;
}

class Planner {
  const Planner();

  static const demoMeeting = 'demo-meeting';
  static const demoExhibition = 'demo-exhibition';
  static const demoReturn = 'demo-return';
  static const _demoExhibitionTitle = '展馆入场';
  static const originalEntry = 14 * 60 + 30;
  static const laterEntry = 15 * 60;
  static const laterDuration = 90;

  List<ItineraryTask> example() => [
    ItineraryTask(
      id: demoMeeting,
      title: '与朋友集合',
      start: 14 * 60,
      duration: 0,
      location: '地铁站 A 口',
      timing: Timing.flexible,
      priority: TaskPriority.high,
      people: ['小明'],
    ),
    ItineraryTask(
      id: demoExhibition,
      title: _demoExhibitionTitle,
      start: originalEntry,
      duration: 120,
      location: '城市美术馆',
      timing: Timing.reservation,
      priority: TaskPriority.high,
      transfer: 10,
      after: [demoMeeting],
    ),
    ItineraryTask(
      id: demoReturn,
      title: '乘车返程',
      start: 17 * 60,
      duration: 0,
      location: '返程车站',
      timing: Timing.fixed,
      priority: TaskPriority.high,
      transfer: 20,
      after: [demoExhibition],
    ),
  ];

  String? summaryTitle(List<ItineraryTask> tasks) {
    if (tasks.isEmpty) return null;
    final main = tasks.reduce(
      (a, b) => _compareSummaryPriority(a, b) <= 0 ? a : b,
    );
    if (main.id == demoExhibition && main.title == _demoExhibitionTitle) {
      return '周末看展';
    }
    return main.title;
  }

  int _compareSummaryPriority(ItineraryTask a, ItineraryTask b) {
    final aReservation = a.timing == Timing.reservation;
    final bReservation = b.timing == Timing.reservation;
    if (aReservation != bReservation) return aReservation ? -1 : 1;
    final byDuration = b.duration.compareTo(a.duration);
    return byDuration == 0 ? a.start.compareTo(b.start) : byDuration;
  }

  PlanAnalysis analyze(List<ItineraryTask> tasks) {
    final byId = {for (final task in tasks) task.id: task};
    if (byId.length != tasks.length) throw const FormatException('行程编号重复。');
    final visiting = <String>{};
    final earliest = <String, int>{};
    final ancestors = <String, Set<String>>{};
    final conflicts = <TaskConflict>[];

    int calculate(ItineraryTask task) {
      final cached = earliest[task.id];
      if (cached != null) return cached;
      if (!visiting.add(task.id)) {
        throw const FormatException('行程依赖形成了循环，请调整前置行程。');
      }
      var start = task.start;
      ItineraryTask? blocking;
      final preceding = <String>{};
      for (final id in task.after) {
        final predecessor = byId[id];
        if (predecessor == null) throw const FormatException('有一项前置行程已不存在。');
        final ready =
            calculate(predecessor) + predecessor.duration + task.transfer;
        preceding.add(id);
        preceding.addAll(ancestors[id]!);
        if (ready > start) {
          start = ready;
          blocking = predecessor;
        }
      }
      if (blocking != null) {
        conflicts.add(
          TaskConflict(
            task,
            start,
            TaskIssue.dependency,
            predecessor: blocking,
          ),
        );
      }
      if (start >= minutesPerDay || start + task.duration > minutesPerDay) {
        conflicts.add(TaskConflict(task, start, TaskIssue.beyondDay));
      }
      visiting.remove(task.id);
      ancestors[task.id] = preceding;
      return earliest[task.id] = start;
    }

    for (final task in tasks) {
      calculate(task);
    }
    final ordered = [...tasks]..sort((a, b) => a.start.compareTo(b.start));
    for (var index = 0; index < ordered.length; index++) {
      final current = ordered[index];
      final occupiedUntil =
          current.start + (current.duration == 0 ? 1 : current.duration);
      for (final next
          in ordered
              .skip(index + 1)
              .takeWhile((next) => next.start < occupiedUntil)) {
        if (ancestors[next.id]!.contains(current.id) ||
            ancestors[current.id]!.contains(next.id)) {
          continue;
        }
        conflicts.add(
          TaskConflict(
            next,
            occupiedUntil,
            TaskIssue.overlap,
            predecessor: current,
          ),
        );
      }
    }
    return PlanAnalysis(
      List.unmodifiable(conflicts),
      Map.unmodifiable(earliest),
    );
  }

  List<ReplanOption> options(
    List<ItineraryTask> tasks,
    PlanAnalysis analysis, {
    String? anchorId,
    bool lockAnchor = false,
  }) {
    if (analysis.conflicts.isEmpty && anchorId == null) return const [];
    final byId = {for (final task in tasks) task.id: task};
    final anchor = byId[anchorId];
    if (anchorId != null && anchor?.timing != Timing.flexible) return const [];
    final meeting = byId[demoMeeting];
    final exhibition = byId[demoExhibition];
    final options = <String, ReplanOption>{};

    List<ItineraryTask>? settle(List<ItineraryTask> revised) {
      final PlanAnalysis preview;
      try {
        preview = analyze(revised);
      } on FormatException {
        return null;
      }
      final settled = [
        for (final task in revised)
          if (task.timing == Timing.flexible &&
              task.start < preview.earliestStarts[task.id]!)
            task.reschedule(start: preview.earliestStarts[task.id]!)
          else
            task,
      ];
      if (settled.any(
        (task) =>
            task.start < 0 ||
            task.start >= minutesPerDay ||
            task.duration < 0 ||
            task.end > minutesPerDay ||
            (lockAnchor && task.id == anchorId && task.start != anchor!.start),
      )) {
        return null;
      }
      return settled;
    }

    void offer(String title, String description, List<ItineraryTask>? settled) {
      if (settled == null || analyze(settled).conflicts.isNotEmpty) return;
      final key = jsonEncode([for (final task in settled) task.toJson()]);
      options.putIfAbsent(
        key,
        () => ReplanOption(title, description, List.unmodifiable(settled)),
      );
    }

    final hasExhibitionConflict = analysis.conflicts.any(
      (item) =>
          item.task.id == demoExhibition && item.predecessor?.id == demoMeeting,
    );
    if (meeting != null &&
        exhibition != null &&
        hasExhibitionConflict &&
        exhibition.timing == Timing.reservation &&
        exhibition.start == originalEntry) {
      final revisedDuration = exhibition.duration.clamp(0, laterDuration);
      offer(
        '改到 ${clockTime(laterEntry)} 入场',
        '使用演示预约的可用场次，参观 $revisedDuration 分钟。',
        settle([
          for (final task in tasks)
            if (task.id == demoExhibition)
              task.reschedule(start: laterEntry, duration: revisedDuration)
            else
              task,
        ]),
      );

      if (meeting.timing == Timing.flexible && meeting.after.isEmpty) {
        offer(
          '按原时间入场，看完展再会合',
          '保留预约，参观结束后再和朋友碰面。',
          settle([
            for (final task in tasks)
              switch (task.id) {
                demoExhibition => task.reschedule(
                  after: task.after.where((id) => id != demoMeeting).toList(),
                ),
                demoMeeting => task.reschedule(
                  start: meeting.start > exhibition.end
                      ? meeting.start
                      : exhibition.end,
                  location:
                      '${exhibition.location.isEmpty ? exhibition.title : exhibition.location}出口',
                  after: [demoExhibition],
                  transfer: 0,
                ),
                demoReturn
                    when task.after.contains(demoExhibition) &&
                        !task.after.contains(demoMeeting) =>
                  task.reschedule(after: [...task.after, demoMeeting]),
                _ => task,
              },
          ]),
        );
      }
    }

    final queue = [tasks];
    final visited = <String>{};
    // Only move flexible tasks around independent conflicts. Dependencies,
    // fixed times and real reservations are checked again after each move.
    const searchLimit = 64;
    for (var index = 0; index < queue.length && index < searchLimit; index++) {
      final requested = queue[index];
      final key = requested.map((task) => task.start).join(',');
      if (!visited.add(key)) continue;
      final revised = settle(requested);
      if (revised == null) continue;
      final conflicts = analyze(revised).conflicts;
      if (conflicts.isEmpty) {
        final changed = revised.where(
          (task) => task.start != byId[task.id]!.start,
        );
        final first = changed.firstOrNull;
        final title = index == 0
            ? (first == null ? '按通知时间调整' : '顺延可调整的行程')
            : '调整「${first!.title}」至 ${clockTime(first.start)}';
        offer(title, '保留固定时间和预约，按前置关系安排可调整的行程。', revised);
        continue;
      }
      final overlap = conflicts
          .where((issue) => issue.issue == TaskIssue.overlap)
          .firstOrNull;
      if (overlap == null) continue;
      final pair = [overlap.task, overlap.predecessor!];
      for (final (i, task) in pair.indexed) {
        if (task.timing != Timing.flexible ||
            (lockAnchor && task.id == anchorId)) {
          continue;
        }
        final other = pair[1 - i];
        for (final start in [
          other.start - (task.duration == 0 ? 1 : task.duration),
          other.start + (other.duration == 0 ? 1 : other.duration),
        ]) {
          if (start < 0 ||
              start >= minutesPerDay ||
              (anchor?.id == task.id && start < anchor!.start)) {
            continue;
          }
          queue.add([
            for (final item in requested)
              item.id == task.id ? item.reschedule(start: start) : item,
          ]);
        }
      }
    }

    final ranked =
        [
          for (final option in options.values)
            (option: option, cost: _replanCost(byId, option.tasks)),
        ]..sort((a, b) {
          for (final priority in TaskPriority.values) {
            final change = a.cost[priority.index].compareTo(
              b.cost[priority.index],
            );
            if (change != 0) return change;
          }
          return a.option.title.compareTo(b.option.title);
        });
    return [for (final row in ranked.take(3)) row.option];
  }

  List<int> _replanCost(
    Map<String, ItineraryTask> original,
    List<ItineraryTask> revised,
  ) {
    final cost = List.filled(TaskPriority.values.length, 0);
    for (final task in revised) {
      final before = original[task.id]!;
      final sameDependencies =
          task.after.length == before.after.length &&
          task.after.every(before.after.contains);
      cost[before.priority.index] +=
          (task.start - before.start).abs() +
          (task.duration - before.duration).abs() +
          (task.transfer - before.transfer).abs() +
          (task.location == before.location ? 0 : 15) +
          (sameDependencies ? 0 : 15);
    }
    return cost;
  }
}
