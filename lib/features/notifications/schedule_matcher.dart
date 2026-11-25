import '../itinerary/itinerary.dart';
import '../itinerary/plan_controller.dart';
import 'notification_analysis.dart';
import 'notification_event.dart';
import 'notification_inbox.dart';

class ScheduleCandidate {
  const ScheduleCandidate(this.day, this.task, this.evidence);

  final DateTime day;
  final ItineraryTask task;
  final List<String> evidence;
}

class ScheduleMatch {
  const ScheduleMatch(this.candidates, {this.automatic});

  final List<ScheduleCandidate> candidates;
  final ScheduleCandidate? automatic;
}

/// Matches AI-extracted facts against the local plan. Calendar rules and the
/// decision to link automatically stay in Dart.
class ScheduleMatcher {
  const ScheduleMatcher();

  DateTime dayOf(AndroidNotice notice, ExtractedEvent event) {
    final received = notice.localPostedAt;
    final original = _originalEvidence(event);
    final relative = RegExp(r'昨天|今天|明天|后天').firstMatch(original)?.group(0);
    final offset = switch (relative) {
      '昨天' => -1,
      '明天' => 1,
      '后天' => 2,
      _ => 0,
    };
    return eventDate(event.originalDate) ??
        (relative == null && event.kind == EventKind.cancelled
            ? eventDate(event.date)
            : null) ??
        DateTime(received.year, received.month, received.day + offset);
  }

  ScheduleMatch match(
    AndroidNotice notice,
    ExtractedEvent event,
    DateTime day,
    SavedPlan plan,
  ) {
    final original = _originalEvidence(event);
    final normalizedOriginal = _normalize(original);
    final period = RegExp(r'凌晨|早上|上午|中午|下午|傍晚|晚上')
        .firstMatch(original)
        ?.group(0);
    final time = eventMinutes(event.originalTime);
    final oldLocation = _normalize(
      event.originalLocation ??
          (event.kind == EventKind.changed ? null : event.location),
    );
    final reference = _normalize(event.reference);
    final referenceInNotice =
        reference.length >= 3 &&
        [
          notice.title,
          notice.text,
        ].map(_normalize).any((text) => text.contains(reference));
    final specificActivity = _normalize(event.activity);
    final subjects = [event.activity, event.title]
        .map(_normalize)
        .where((subject) => subject.length >= 2 && !_generic.contains(subject))
        .toSet();
    final people = <String>{
      for (final person in event.people)
        if (notice.title.contains(person) || notice.text.contains(person))
          _normalize(person),
      if (RegExp(
            r'^[\p{L}·]{2,12}$',
            unicode: true,
          ).hasMatch(notice.title.trim()) &&
          (event.kind == EventKind.delayed ||
              RegExp(r'我|本人').hasMatch(original)))
        _normalize(notice.title.trim()),
    }..removeWhere((person) => person.length < 2);
    final ownId = notificationTaskId(notice, event);
    final ranked = <({ScheduleCandidate candidate, int score, bool strong})>[];

    for (final task in plan.tasks) {
      if (task.id == ownId ||
          (time != task.start && !_inPeriod(task.start, period))) {
        continue;
      }
      final title = _normalize(task.title);
      final place = _normalize(task.location);
      final knownPeople = task.people
          .map(_normalize)
          .where((person) => person.length >= 2);
      final personMatch =
          people.any(
            (person) => knownPeople.contains(person) || title.contains(person),
          ) ||
          knownPeople.any(normalizedOriginal.contains);
      final numberMatch = referenceInNotice && title.contains(reference);
      final timeMatch = time == task.start;
      final placeMatch = oldLocation.length >= 2 && oldLocation == place;
      final titleMatch = subjects.any(
        (subject) =>
            title == subject ||
            (subject.length >= 3 && title.contains(subject)),
      );
      final semanticMatch =
          !titleMatch &&
          _activities.any(
            (aliases) =>
                aliases.any(title.contains) &&
                aliases.any(
                  (alias) => subjects.any((subject) => subject.contains(alias)),
                ),
          );
      if (!(numberMatch ||
          personMatch ||
          titleMatch ||
          placeMatch ||
          timeMatch ||
          semanticMatch)) {
        continue;
      }

      final evidence = [
        if (numberMatch) '行程编号一致',
        if (personMatch) '人物一致',
        if (titleMatch) '活动名称一致',
        if (semanticMatch) '活动类型相近',
        if (placeMatch) '地点一致',
        if (timeMatch) '原时间一致',
        if (period != null) '同一时段',
      ];
      final score =
          (numberMatch ? 12 : 0) +
          (personMatch ? 5 : 0) +
          (titleMatch ? 5 : 0) +
          (semanticMatch ? 2 : 0) +
          (placeMatch ? 4 : 0) +
          (timeMatch ? 4 : 0) +
          (period != null ? 1 : 0) -
          (time != null && !timeMatch ? 4 : 0);
      final strong =
          numberMatch ||
          ((time == null || timeMatch) &&
              (titleMatch ||
                  (personMatch &&
                      (specificActivity.isEmpty ||
                          semanticMatch ||
                          timeMatch ||
                          placeMatch)) ||
                  (timeMatch && placeMatch)));
      ranked.add((
        candidate: ScheduleCandidate(day, task, evidence),
        score: score,
        strong: strong,
      ));
    }

    ranked.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.candidate.task.start.compareTo(b.candidate.task.start);
    });
    if (ranked.isEmpty) return const ScheduleMatch([]);
    final first = ranked.first;
    final clear =
        first.strong &&
        (ranked.length == 1 || first.score - ranked[1].score >= 3);
    return ScheduleMatch([
      for (final row in ranked) row.candidate,
    ], automatic: clear ? first.candidate : null);
  }

  static String _originalEvidence(ExtractedEvent event) =>
      event.evidence.split(RegExp(r'改到|改为|调整到|推迟到|提前到|延期至|改去|换到')).first;

  static final _separators = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  static String _normalize(String? text) =>
      (text ?? '').toLowerCase().replaceAll(_separators, '');

  static const _generic = {'迟到', '晚到', '延误', '改期', '变更', '行程调整', '取消', '行程取消'};

  static const _activities = [
    ['看展', '观展', '展览', '入场'],
    ['集合', '会合', '碰面', '见面'],
    ['评审', '审核', '审查'],
    ['聚餐', '吃饭', '午餐', '晚餐'],
    ['航班', '登机', '起飞'],
    ['火车', '高铁', '列车', '乘车'],
  ];

  static bool _inPeriod(int start, String? period) => switch (period) {
    '凌晨' => start < 6 * 60,
    '早上' || '上午' => start >= 5 * 60 && start < 12 * 60,
    '中午' => start >= 11 * 60 && start < 14 * 60,
    '下午' => start >= 12 * 60 && start < 19 * 60,
    '傍晚' || '晚上' => start >= 17 * 60,
    _ => true,
  };
}

/// Preview only. Report changes to the selected task and its direct neighbors.
List<String> scheduleAlert(
  ExtractedEvent event,
  ScheduleCandidate candidate,
  SavedPlan plan,
) {
  final task = candidate.task;
  if (event.kind == EventKind.cancelled) {
    return [
      '通知提到取消，请核对原行程。',
      for (final other in plan.tasks)
        if (other.after.contains(task.id)) '「${other.title}」在它之后开始。',
    ];
  }

  final day = eventDate(event.date);
  final start =
      eventMinutes(event.time) ??
      (event.delayMinutes == null ? null : task.start + event.delayMinutes!);
  final crossDay =
      (day != null && day != candidate.day) ||
      (start != null && start >= minutesPerDay);
  if (crossDay) return ['通知涉及跨日调整，请核对原行程和新日期。'];
  final location = event.location?.trim();
  final locationAlerts = [
    if (event.kind == EventKind.changed &&
        location != null &&
        location.isNotEmpty &&
        location != task.location.trim())
      '通知地点为$location，请核对原地点。',
  ];
  if (start == null || start == task.start) return locationAlerts;

  const planner = Planner();
  bool affects(TaskConflict conflict) =>
      conflict.task.id == task.id || conflict.predecessor?.id == task.id;
  String key(TaskConflict issue) {
    final ids = [issue.task.id, issue.predecessor?.id ?? ''];
    if (issue.issue == TaskIssue.overlap) ids.sort();
    return '${issue.issue.name}:${ids.join('|')}';
  }

  final before = {
    for (final issue in planner.analyze(plan.tasks).conflicts.where(affects))
      key(issue): issue.earliest,
  };
  final preview = [
    for (final other in plan.tasks)
      other.id == task.id ? task.reschedule(start: start) : other,
  ];
  final conflicts = planner.analyze(preview).conflicts.where(affects);
  return [
    ...locationAlerts,
    if (task.timing != Timing.flexible)
      '通知时间为 ${clockTime(start)}，请核对原${task.timing.label}。',
    for (final conflict in conflicts)
      if (!before.containsKey(key(conflict)) ||
          (conflict.issue == TaskIssue.dependency &&
              conflict.earliest > before[key(conflict)]!))
        conflict.issue == TaskIssue.beyondDay
            ? conflict.summary
            : '「${conflict.task.title}」${conflict.summary}',
  ];
}
