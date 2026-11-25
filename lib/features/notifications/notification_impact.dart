import '../itinerary/itinerary.dart';
import 'notification_analysis.dart';
import 'notification_event.dart';
import 'schedule_matcher.dart';

class ImpactStep {
  const ImpactStep({
    required this.task,
    required this.baseline,
    this.earliest,
    this.predecessor,
    this.absorbed = false,
  });

  final ItineraryTask task;
  final int baseline;
  final int? earliest;
  final ItineraryTask? predecessor;
  final bool absorbed;

  int get lateMinutes => (earliest ?? task.start) - task.start;
  bool get worsens => earliest != null && earliest! > baseline;
}

class NotificationImpact {
  const NotificationImpact({this.steps = const [], this.alerts = const []});

  final List<ImpactStep> steps;
  final List<String> alerts;

  bool get needsAttention =>
      alerts.isNotEmpty || steps.skip(1).any((step) => step.worsens);
}

/// Reuses the itinerary's dependency calculation for the plan and its preview.
NotificationImpact notificationImpact(
  ExtractedEvent event,
  ScheduleCandidate candidate,
  List<ItineraryTask> tasks,
) {
  const planner = Planner();
  final source = candidate.task;
  final children = <String, List<ItineraryTask>>{};
  for (final task in tasks) {
    for (final id in task.after) {
      (children[id] ??= []).add(task);
    }
  }

  final newDate = eventDate(event.date);
  final start = eventMinutes(event.time);
  final relativeDelay = event.delayMinutes;
  final newStart =
      start ??
      (relativeDelay == null
          ? null
          : (eventMinutes(event.originalTime) ?? source.start) + relativeDelay);
  final movesToAnotherDay = newDate != null && newDate != candidate.day;
  final alerts = <String>[
    if (event.kind == EventKind.cancelled) '通知提到取消，请核对原行程。',
    if (movesToAnotherDay || (newStart != null && newStart >= minutesPerDay))
      '通知涉及跨日调整，请核对原行程和新日期。',
  ];
  final location = event.location?.trim();
  if (event.kind == EventKind.changed &&
      location != null &&
      location.isNotEmpty &&
      location != source.location.trim()) {
    alerts.add('通知地点为$location，请核对原地点。');
  }
  if (event.kind == EventKind.cancelled ||
      (movesToAnotherDay && start == null)) {
    final order = <ItineraryTask>[source];
    final visited = {source.id};
    final steps = [ImpactStep(task: source, baseline: source.start)];
    for (var index = 0; index < order.length; index++) {
      final parent = order[index];
      for (final child in children[parent.id] ?? <ItineraryTask>[]) {
        if (!visited.add(child.id)) continue;
        order.add(child);
        steps.add(
          ImpactStep(task: child, baseline: child.start, predecessor: parent),
        );
      }
    }
    return NotificationImpact(steps: steps, alerts: alerts);
  }

  if (newStart == null) return NotificationImpact(alerts: alerts);
  final offset = movesToAnotherDay
      ? DateTime.utc(newDate.year, newDate.month, newDate.day)
                .difference(
                  DateTime.utc(
                    candidate.day.year,
                    candidate.day.month,
                    candidate.day.day,
                  ),
                )
                .inDays *
            minutesPerDay
      : 0;
  final revisedStart = newStart + offset;
  // Negative offsets are valid for a plan moved to an earlier date. The
  // preview can still calculate the starts of the other tasks on the old day.
  if (revisedStart == source.start) return NotificationImpact(alerts: alerts);
  if (source.timing != Timing.flexible &&
      !movesToAnotherDay &&
      newStart < minutesPerDay) {
    alerts.add('通知时间为 ${clockTime(newStart)}，请核对原${source.timing.label}。');
  }
  final before = planner.analyze(tasks);
  final revised = [
    for (final task in tasks)
      task.id == source.id ? task.reschedule(start: revisedStart) : task,
  ];
  final after = planner.analyze(revised);
  final steps = [
    ImpactStep(
      task: source,
      baseline: before.earliestStarts[source.id]!,
      earliest: after.earliestStarts[source.id]!,
    ),
  ];
  final queue = <ItineraryTask>[source];
  final visited = {source.id};
  final byId = {for (final task in tasks) task.id: task};
  final blockers = {
    for (final conflict in after.conflicts)
      if (conflict.issue == TaskIssue.dependency)
        conflict.task.id: conflict.predecessor!,
  };
  final earlierBlockers = {
    for (final conflict in before.conflicts)
      if (conflict.issue == TaskIssue.dependency)
        conflict.task.id: conflict.predecessor!,
  };

  for (var index = 0; index < queue.length; index++) {
    final parent = queue[index];
    for (final child in children[parent.id] ?? <ItineraryTask>[]) {
      if (!visited.add(child.id)) continue;
      final prior = before.earliestStarts[child.id]!;
      final next = after.earliestStarts[child.id]!;
      if (next != prior) {
        final cause = next > prior
            ? blockers[child.id]
            : earlierBlockers[child.id];
        steps.add(
          ImpactStep(
            task: child,
            baseline: prior,
            earliest: next,
            predecessor: cause ?? parent,
          ),
        );
        queue.add(child);
      } else if (next == child.start) {
        // The other predecessors may have changed too. Use the one that
        // leaves the least buffer after this notification.
        ItineraryTask? cause;
        var latestReady = -1;
        for (final id in child.after) {
          final previous = before.earliestStarts[id]!;
          final projected = after.earliestStarts[id]!;
          if (projected <= previous) continue;
          final task = byId[id]!;
          final ready = projected + task.duration + child.transfer;
          if (ready > latestReady) {
            cause = task;
            latestReady = ready;
          }
        }
        if (cause != null) {
          steps.add(
            ImpactStep(
              task: child,
              baseline: prior,
              earliest: next,
              predecessor: cause,
              absorbed: true,
            ),
          );
        }
      }
    }
  }

  // Preserve the association stage's direct overlap warnings without
  // duplicating the dependency explanations in the forecast.
  bool directlyRelated(TaskConflict issue) =>
      issue.task.id == source.id || issue.predecessor?.id == source.id;
  String overlapKey(TaskConflict issue) =>
      ([issue.task.id, issue.predecessor!.id]..sort()).join('|');
  final existingOverlap = before.conflicts
      .where(
        (issue) => issue.issue == TaskIssue.overlap && directlyRelated(issue),
      )
      .map(overlapKey)
      .toSet();
  final wasBeyondDay = before.conflicts.any(
    (issue) => issue.issue == TaskIssue.beyondDay && issue.task.id == source.id,
  );
  for (final issue in after.conflicts.where(directlyRelated)) {
    if (issue.issue == TaskIssue.overlap &&
        !existingOverlap.contains(overlapKey(issue))) {
      alerts.add('「${issue.task.title}」${issue.summary}');
    } else if (issue.issue == TaskIssue.beyondDay &&
        !wasBeyondDay &&
        newStart < minutesPerDay &&
        !movesToAnotherDay) {
      alerts.add(issue.summary);
    }
  }

  return NotificationImpact(steps: steps, alerts: alerts);
}
