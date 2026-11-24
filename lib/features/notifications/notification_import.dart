import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../itinerary/itinerary.dart';
import '../itinerary/plan_controller.dart';
import 'notification_analysis.dart';
import 'notification_event.dart';
import 'notification_inbox.dart';

/// An event that was added to the itinerary automatically and is waiting for
/// the user's review.
class PendingAddition {
  const PendingAddition({
    required this.id,
    required this.day,
    required this.title,
    required this.start,
    required this.source,
  });

  final String id;
  final DateTime day;
  final String title;
  final int start;
  final String source;

  Map<String, Object> toJson() => {
    'id': id,
    'day': planDayKey(day),
    'title': title,
    'start': start,
    'source': source,
  };

  factory PendingAddition.fromJson(Map<String, dynamic> json) =>
      PendingAddition(
        id: json['id'] as String? ?? '',
        day: DateTime.tryParse(json['day'] as String? ?? '') ?? DateTime.now(),
        title: json['title'] as String? ?? '',
        start: json['start'] as int? ?? 0,
        source: json['source'] as String? ?? '',
      );
}

/// Remembers which events were already imported and which are still waiting
/// for review.
abstract class NotificationImportStore {
  Future<List<PendingAddition>> pending();
  Future<void> writePending(List<PendingAddition> items);
  Future<Set<String>> imported();
  Future<void> markImported(Iterable<String> ids);
}

class SharedPreferencesImportStore implements NotificationImportStore {
  static const _pendingKey = 'ripple.notice.pending.v1';
  static const _importedKey = 'ripple.notice.imported.v1';
  static const _importedLimit = 800;
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
  Future<void> markImported(Iterable<String> ids) async {
    final current =
        await _preferences.getStringList(_importedKey) ?? const <String>[];
    final merged = [...current];
    final known = current.toSet();
    for (final id in ids) {
      if (known.add(id)) merged.add(id);
    }
    final limited = merged.length > _importedLimit
        ? merged.sublist(merged.length - _importedLimit)
        : merged;
    await _preferences.setStringList(_importedKey, limited);
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

/// Adds freshly parsed notification events to the itinerary and keeps a list of
/// additions the user has not confirmed yet.
class NotificationImporter {
  NotificationImporter({
    required this.repository,
    required this.store,
    required this.onChanged,
  });

  final PlanRepository repository;
  final NotificationImportStore store;
  final void Function(DateTime day) onChanged;
  Future<List<PendingAddition>>? _running;

  Future<List<PendingAddition>> pending() => store.pending();

  /// Imports every parsed event that is not in the itinerary yet.
  Future<List<PendingAddition>> sync() =>
      _running ??= _sync().whenComplete(() => _running = null);

  Future<List<PendingAddition>> _sync() async {
    final inbox = await NotificationInbox.read();
    if (!inbox.authorized) return const [];
    final imported = await store.imported();
    final handled = <String>[];
    final added = <PendingAddition>[];
    for (final notice in inbox.entries.reversed) {
      final analysis = notice.analysis;
      if (analysis == null) continue;
      for (final event in analysis.events) {
        if (event.kind == EventKind.cancelled) continue;
        final start = _minutes(event.time);
        if (start == null) continue;
        final id = notificationTaskId(notice, event);
        if (imported.contains(id)) continue;
        final day = _dayOf(event.date, notice.localPostedAt);
        final plan = await repository.load(day);
        if (plan.tasks.any((task) => task.id == id)) {
          handled.add(id);
          continue;
        }
        await repository.save(
          day,
          SavedPlan([
            ...plan.tasks,
            ItineraryTask(
              id: id,
              title: event.title,
              start: start,
              duration: event.durationMinutes ?? 0,
              location: event.location ?? '',
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
            source: notice.source,
          ),
        );
        onChanged(day);
      }
    }
    if (handled.isNotEmpty) await store.markImported(handled);
    if (added.isNotEmpty) {
      final existing = await store.pending();
      final known = {for (final item in existing) item.id};
      await store.writePending([
        ...existing,
        for (final item in added)
          if (known.add(item.id)) item,
      ]);
    }
    return added;
  }

  /// Removes the additions the user turned off and clears the review list.
  Future<void> resolve(List<PendingAddition> items, Set<String> removed) async {
    for (final item in items) {
      if (!removed.contains(item.id)) continue;
      final plan = await repository.load(item.day);
      if (!plan.tasks.any((task) => task.id == item.id)) continue;
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
    final resolved = {for (final item in items) item.id};
    final pending = await store.pending();
    await store.writePending([
      for (final item in pending)
        if (!resolved.contains(item.id)) item,
    ]);
  }
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
