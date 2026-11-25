import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../itinerary/plan_controller.dart';
import 'notification_analysis.dart';
import 'notification_event.dart';
import 'notification_impact.dart';
import 'notification_inbox.dart';
import 'schedule_matcher.dart';

typedef ScheduleLink = ({DateTime day, String taskId});

class NotificationAssociation {
  const NotificationAssociation({
    this.candidates = const [],
    this.target,
    this.impact = const NotificationImpact(),
    this.dismissed = false,
    this.applied = false,
  });

  final List<ScheduleCandidate> candidates;
  final ScheduleCandidate? target;
  final NotificationImpact impact;
  final bool dismissed;
  final bool applied;

  bool get needsChoice => target == null && candidates.isNotEmpty;
  bool get needsAttention => needsChoice || impact.needsAttention;
}

class NotificationLinkStore {
  static const _key = 'ripple.notice.links.v1';
  final _preferences = SharedPreferencesAsync();

  Future<Map<String, ScheduleLink?>> read() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return {};
    final entries = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final MapEntry(:key, :value) in entries.entries)
        key: value == null
            ? null
            : (
                day: DateTime.parse(value[0] as String),
                taskId: value[1] as String,
              ),
    };
  }

  Future<void> write(Map<String, ScheduleLink?> links) =>
      _preferences.setString(
        _key,
        jsonEncode({
          for (final key in links.keys.skip(
            links.length > 800 ? links.length - 800 : 0,
          ))
            key: switch (links[key]) {
              final link? => [planDayKey(link.day), link.taskId],
              null => null,
            },
        }),
      );
}

final notificationLinkStoreProvider = Provider<NotificationLinkStore>(
  (ref) => NotificationLinkStore(),
);

final notificationAssociationsProvider =
    NotifierProvider<
      NotificationAssociations,
      Map<String, NotificationAssociation>
    >(NotificationAssociations.new);

class NotificationAssociations
    extends Notifier<Map<String, NotificationAssociation>> {
  static const _matcher = ScheduleMatcher();
  Future<void> _tail = Future.value();

  @override
  Map<String, NotificationAssociation> build() => const {};

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<int> refresh(NotificationInbox inbox) => _serialize(() async {
    if (!ref.mounted) return 0;
    final events = {
      if (inbox.authorized)
        for (final notice in inbox.entries.reversed)
          for (final event in notice.analysis?.events ?? <ExtractedEvent>[])
            if (event.kind != EventKind.newEvent)
              notificationTaskId(notice, event): (notice: notice, event: event),
    };
    if (events.isEmpty) {
      state = const {};
      return 0;
    }
    final repository = ref.read(planRepositoryProvider);
    final store = ref.read(notificationLinkStoreProvider);
    final links = await store.read();
    final plans = <DateTime, SavedPlan>{};
    final next = <String, NotificationAssociation>{};
    var savedLink = false;

    for (final MapEntry(key: id, value: value) in events.entries) {
      final (:notice, :event) = value;
      final link = links[id];
      if (link == null && links.containsKey(id)) {
        next[id] = const NotificationAssociation(dismissed: true);
        continue;
      }
      final day = link?.day ?? _matcher.dayOf(notice, event);
      final plan = plans[day] ??= await repository.load(day);
      final match = _matcher.match(notice, event, day, plan);
      if (link != null) {
        final task = plan.tasks
            .where((task) => task.id == link.taskId)
            .firstOrNull;
        if (task == null) {
          next[id] = plan.appliedNotices.contains(id)
              ? const NotificationAssociation(applied: true)
              : NotificationAssociation(candidates: match.candidates);
          continue;
        }
        final candidate =
            match.candidates
                .where((candidate) => candidate.task.id == link.taskId)
                .firstOrNull ??
            ScheduleCandidate(day, task, const []);
        next[id] = _linked(id, event, candidate, plan);
      } else if (match.automatic case final candidate?) {
        next[id] = _linked(id, event, candidate, plan);
        links[id] = (day: day, taskId: candidate.task.id);
        savedLink = true;
      } else {
        next[id] = NotificationAssociation(candidates: match.candidates);
      }
    }

    if (savedLink) await store.write(links);
    if (!ref.mounted) return 0;
    final newAlerts = next.entries
        .where(
          (entry) =>
              entry.value.needsAttention &&
              state[entry.key]?.needsAttention != true,
        )
        .length;
    state = next;
    return newAlerts;
  });

  Future<void> choose(
    String id,
    ExtractedEvent event,
    ScheduleCandidate? candidate,
  ) => _serialize(() async {
    if (!ref.mounted || state[id]?.needsChoice != true) return;
    final repository = ref.read(planRepositoryProvider);
    final store = ref.read(notificationLinkStoreProvider);
    final links = await store.read();
    NotificationAssociation result;
    if (candidate == null) {
      links[id] = null;
      result = const NotificationAssociation(dismissed: true);
    } else {
      final plan = await repository.load(candidate.day);
      final task = plan.tasks
          .where((task) => task.id == candidate.task.id)
          .firstOrNull;
      if (task == null) throw const FormatException('该行程已删除，请重新读取通知。');
      final current = ScheduleCandidate(
        candidate.day,
        task,
        candidate.evidence,
      );
      links[id] = (day: candidate.day, taskId: task.id);
      result = _linked(id, event, current, plan);
    }
    await store.write(links);
    if (ref.mounted) state = {...state, id: result};
  });

  NotificationAssociation _linked(
    String id,
    ExtractedEvent event,
    ScheduleCandidate candidate,
    SavedPlan plan,
  ) => plan.appliedNotices.contains(id)
      ? NotificationAssociation(target: candidate, applied: true)
      : NotificationAssociation(
          target: candidate,
          impact: notificationImpact(event, candidate, plan.tasks),
        );
}
