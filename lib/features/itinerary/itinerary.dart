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

class ItineraryTask {
  ItineraryTask({
    required this.id,
    required this.title,
    required this.start,
    required this.duration,
    required this.location,
    required this.timing,
    this.transfer = 0,
    Iterable<String> after = const [],
  }) : after = List.unmodifiable(after);

  final String id;
  final String title;
  final int start;
  final int duration;
  final String location;
  final Timing timing;
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
    ),
    ItineraryTask(
      id: demoExhibition,
      title: _demoExhibitionTitle,
      start: originalEntry,
      duration: 120,
      location: '城市美术馆',
      timing: Timing.reservation,
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

  List<ReplanOption> options(List<ItineraryTask> tasks, PlanAnalysis analysis) {
    if (analysis.conflicts.isEmpty) return const [];
    final byId = {for (final task in tasks) task.id: task};
    final meeting = byId[demoMeeting];
    final exhibition = byId[demoExhibition];
    final options = <ReplanOption>[];

    void offer(String title, String description, List<ItineraryTask> revised) {
      final PlanAnalysis preview;
      try {
        preview = analyze(revised);
      } on FormatException {
        return;
      }
      final settled = [
        for (final task in revised)
          if (task.timing == Timing.flexible)
            task.reschedule(start: preview.earliestStarts[task.id]!)
          else
            task,
      ];
      if (settled.any((task) => task.start >= minutesPerDay)) return;
      if (analyze(settled).conflicts.isEmpty) {
        options.add(
          ReplanOption(title, description, List.unmodifiable(settled)),
        );
      }
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
        [
          for (final task in tasks)
            if (task.id == demoExhibition)
              task.reschedule(start: laterEntry, duration: revisedDuration)
            else
              task,
        ],
      );

      if (meeting.timing == Timing.flexible && meeting.after.isEmpty) {
        offer('按原时间入场，看完展再会合', '保留预约，参观结束后再和朋友碰面。', [
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
        ]);
      }
    }
    if (options.isEmpty &&
        analysis.conflicts.every(
          (item) =>
              item.issue == TaskIssue.dependency &&
              item.task.timing == Timing.flexible,
        )) {
      offer('顺延可调整的行程', '按依赖顺序顺延，保留固定时间和预约。', tasks);
    }
    return options;
  }
}
