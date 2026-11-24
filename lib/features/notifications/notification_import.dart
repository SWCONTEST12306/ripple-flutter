import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../itinerary/itinerary.dart';
import '../itinerary/plan_controller.dart';
import 'notification_analysis.dart';
import 'notification_event.dart';
import 'notification_inbox.dart';

/// Why an item is waiting for the user.
enum PendingKind {
  /// The event was added to the itinerary automatically.
  added,

  /// A notification repeated an event whose time no longer matches the
  /// itinerary, because the user changed it.
  repeat,
}

/// What the user decided about a pending item.
enum ImportDecision {
  /// Keep the itinerary as it is.
  keep,

  /// Delete an automatically added event.
  remove,

  /// Move the existing event to the time in the notification.
  updateTime,

  /// Add the notification as a second event next to the existing one.
  addCopy,
}

/// An event that was added to the itinerary automatically, or a repeated
/// notification that disagrees with the itinerary, waiting for review.
class PendingAddition {
  const PendingAddition({
    required this.id,
    required this.day,
    required this.title,
    required this.start,
    required this.source,
    this.kind = PendingKind.added,
    this.currentStart,
    this.duration = 0,
    this.location = '',
    String? key,
  }) : key = key ?? id;

  /// Identifies the review row. Repeats of the same notification keep their
  /// own key so they do not collide with the auto-added event.
  final String key;

  /// Identifies the itinerary task this item refers to.
  final String id;

  final DateTime day;
  final String title;

  /// Start time in minutes taken from the notification.
  final int start;

  /// Start time the itinerary has now, when the notification is a repeat.
  final int? currentStart;
  final int duration;
  final String location;
  final String source;
  final PendingKind kind;

  Map<String, Object> toJson() => {
    'key': key,
    'id': id,
    'day': planDayKey(day),
    'title': title,
    'start': start,
    'currentStart': ?currentStart,
    'duration': duration,
    'location': location,
    'source': source,
    'kind': kind.name,
  };

  factory PendingAddition.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    return PendingAddition(
      id: id,
      key: json['key'] as String?,
      day: DateTime.tryParse(json['day'] as String? ?? '') ?? DateTime.now(),
      title: json['title'] as String? ?? '',
      start: json['start'] as int? ?? 0,
      currentStart: json['currentStart'] as int?,
      duration: json['duration'] as int? ?? 0,
      location: json['location'] as String? ?? '',
      source: json['source'] as String? ?? '',
      kind: json['kind'] == PendingKind.repeat.name
          ? PendingKind.repeat
          : PendingKind.added,
    );
  }
}

/// Remembers which events were already imported, which repeats were already
/// reported and which items are still waiting for review.
abstract class NotificationImportStore {
  Future<List<PendingAddition>> pending();
  Future<void> writePending(List<PendingAddition> items);
  Future<Set<String>> imported();
  Future<void> markImported(Iterable<String> ids);
  Future<Set<String>> reminders();
  Future<void> markReminded(Iterable<String> keys);
}

class SharedPreferencesImportStore implements NotificationImportStore {
  static const _pendingKey = 'ripple.notice.pending.v1';
  static const _importedKey = 'ripple.notice.imported.v1';
  static const _remindersKey = 'ripple.notice.reminders.v1';
  static const _limit = 800;
  final _preferences = SharedPreferencesAsync();

  @override
  Future<List<PendingAddition>> pending() async {
    final raw = await _preferences.getString(_pendingKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw) as List;
      return [
        for (final item in data)
          if (item is Map<String, dynamic>) PendingAddition.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> writePending(List<PendingAddition> items) =>
      _preferences.setString(
        _pendingKey,
        jsonEncode([for (final item in items) item.toJson()]),
      );

  @override
  Future<Set<String>> imported() async =>
      (await _preferences.getStringList(_importedKey) ?? const []).toSet();

  @override
  Future<void> markImported(Iterable<String> ids) =>
      _append(_importedKey, ids);

  @override
  Future<Set<String>> reminders() async =>
      (await _preferences.getStringList(_remindersKey) ?? const []).toSet();

  @override
  Future<void> markReminded(Iterable<String> keys) =>
      _append(_remindersKey, keys);

  Future<void> _append(String key, Iterable<String> values) async {
    final current = await _preferences.getStringList(key) ?? const <String>[];
    final merged = [...current];
    final known = current.toSet();
    for (final value in values) {
      if (known.add(value)) merged.add(value);
    }
    final limited = merged.length > _limit
        ? merged.sublist(merged.length - _limit)
        : merged;
    await _preferences.setStringList(key, limited);
  }
}

final notificationImportStoreProvider = Provider<NotificationImportStore>(
  (ref) => SharedPreferencesImportStore(),
);

final notificationImporterProvider = Provider<NotificationImporter>(
  (ref) => NotificationImporter(
    repository: ref.watch(planRepositoryProvider),
    store: ref.watch(notificationImportStoreProvider),
    onChanged: (day) => ref.invalidate(itineraryProvider(day)),
  ),
);

/// What one import pass did.
class NotificationSyncResult {
  const NotificationSyncResult({this.added = 0, this.reminders = 0});

  final int added;

  /// New reminders about repeated notifications that disagree with the
  /// itinerary.
  final int reminders;
}

/// Adds freshly parsed notification events to the itinerary, reports repeats
/// that disagree with the user's edits, and keeps the review list.
class NotificationImporter {
  NotificationImporter({
    required this.repository,
    required this.store,
    required this.onChanged,
  });

  final PlanRepository repository;
  final NotificationImportStore store;
  final void Function(DateTime day) onChanged;
  Future<NotificationSyncResult>? _running;

  Future<List<PendingAddition>> pending() => store.pending();

  Future<NotificationSyncResult> sync() =>
      _running ??= _sync().whenComplete(() => _running = null);

  Future<NotificationSyncResult> _sync() async {
    final inbox = await NotificationInbox.read();
    if (!inbox.authorized) return const NotificationSyncResult();
    final imported = await store.imported();
    final reminded = await store.reminders();
    final pending = await store.pending();
    final pendingKeys = {for (final item in pending) item.key};
    final handled = <String>[];
    final added = <PendingAddition>[];
    final reminders = <PendingAddition>[];
    final remindedKeys = <String>[];
    final plans = <DateTime, SavedPlan>{};

    Future<SavedPlan> readPlan(DateTime day) async =>
        plans[day] ??= await repository.load(day);

    Future<void> writePlan(DateTime day, SavedPlan plan) async {
      await repository.save(day, plan);
      plans[day] = plan;
    }

    for (final notice in inbox.entries.reversed) {
      final analysis = notice.analysis;
      if (analysis == null) continue;
      for (final event in analysis.events) {
        if (event.kind == EventKind.cancelled) continue;
        final start = _minutes(event.time);
        if (start == null) continue;
        final id = notificationTaskId(notice, event);
        final day = _dayOf(event.date, notice.localPostedAt);

        if (!imported.contains(id)) {
          final plan = await readPlan(day);
          if (_findTask(plan, id) != null) {
            handled.add(id);
            continue;
          }
          final duration = event.durationMinutes ?? 0;
          final location = event.location ?? '';
          await writePlan(
            day,
            SavedPlan([
              ...plan.tasks,
              ItineraryTask(
                id: id,
                title: event.title,
                start: start,
                duration: duration,
                location: location,
                timing: Timing.flexible,
              ),
            ], appliedTitle: plan.appliedTitle),
          );
          handled.add(id);
          added.add(
            PendingAddition(
              id: id,
              day: day,
              title: event.title,
              start: start,
              duration: duration,
              location: location,
              source: notice.source,
            ),
          );
          onChanged(day);
          continue;
        }

        // The event was already imported. If the user changed its time in the
        // meantime, a repeated notification is ambiguous: it may be a second
        // event or the original time coming back. Ask instead of ignoring it.
        final task = _findTask(await readPlan(day), id);
        if (task == null || task.start == start) continue;
        final key = 'repeat:$id@$start@${task.start}';
        if (reminded.contains(key) || pendingKeys.contains(key)) continue;
        reminders.add(
          PendingAddition(
            id: id,
            key: key,
            kind: PendingKind.repeat,
            day: day,
            title: event.title,
            start: start,
            currentStart: task.start,
            duration: event.durationMinutes ?? 0,
            location: event.location ?? '',
            source: notice.source,
          ),
        );
        pendingKeys.add(key);
        remindedKeys.add(key);
      }
    }

    if (handled.isNotEmpty) await store.markImported(handled);
    if (remindedKeys.isNotEmpty) await store.markReminded(remindedKeys);
    if (added.isNotEmpty || reminders.isNotEmpty) {
      // Re-read so items confirmed by the review dialog meanwhile stay gone.
      final latest = await store.pending();
      final latestKeys = {for (final item in latest) item.key};
      await store.writePending([
        ...latest,
        for (final item in added)
          if (!latestKeys.contains(item.key)) item,
        ...reminders,
      ]);
    }
    return NotificationSyncResult(
      added: added.length,
      reminders: reminders.length,
    );
  }

  /// Applies the decisions taken in the review dialog.
  Future<void> resolve(
    List<PendingAddition> items,
    Map<String, ImportDecision> decisions,
  ) async {
    for (final item in items) {
      final decision = decisions[item.key] ?? ImportDecision.keep;
      if (item.kind == PendingKind.added) {
        if (decision == ImportDecision.remove) await _deleteTask(item);
        continue;
      }
      if (decision == ImportDecision.updateTime) {
        await _moveTask(item);
      } else if (decision == ImportDecision.addCopy) {
        await _addCopy(item);
      }
    }
    final resolved = {for (final item in items) item.key};
    final pending = await store.pending();
    await store.writePending([
      for (final item in pending)
        if (!resolved.contains(item.key)) item,
    ]);
  }

  Future<void> _deleteTask(PendingAddition item) async {
    final plan = await repository.load(item.day);
    if (_findTask(plan, item.id) == null) return;
    await repository.save(
      item.day,
      SavedPlan([
        for (final task in plan.tasks)
          if (task.id != item.id)
            task.reschedule(
              after: task.after.where((id) => id != item.id).toList(),
            ),
      ], appliedTitle: plan.appliedTitle),
    );
    onChanged(item.day);
  }

  Future<void> _moveTask(PendingAddition item) async {
    final plan = await repository.load(item.day);
    final task = _findTask(plan, item.id);
    if (task == null || task.start == item.start) return;
    await repository.save(
      item.day,
      SavedPlan([
        for (final existing in plan.tasks)
          existing.id == item.id
              ? existing.reschedule(start: item.start)
              : existing,
      ], appliedTitle: plan.appliedTitle),
    );
    onChanged(item.day);
  }

  Future<void> _addCopy(PendingAddition item) async {
    final plan = await repository.load(item.day);
    final id = '${item.id}-copy-${item.currentStart ?? 0}';
    if (_findTask(plan, id) != null) return;
    await repository.save(
      item.day,
      SavedPlan([
        ...plan.tasks,
        ItineraryTask(
          id: id,
          title: item.title,
          start: item.start,
          duration: item.duration,
          location: item.location,
          timing: Timing.flexible,
        ),
      ], appliedTitle: plan.appliedTitle),
    );
    onChanged(item.day);
  }
}

ItineraryTask? _findTask(SavedPlan plan, String id) {
  for (final task in plan.tasks) {
    if (task.id == id) return task;
  }
  return null;
}

int? _minutes(String? time) {
  final parts = time?.split(':');
  if (parts == null || parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}

DateTime _dayOf(String? date, DateTime posted) {
  final parsed = date == null ? null : DateTime.tryParse(date);
  return planDay(parsed ?? posted);
}
