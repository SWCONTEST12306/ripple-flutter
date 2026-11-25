import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'itinerary.dart';

final planRepositoryProvider = Provider<PlanRepository>(
  (ref) => PlanRepository(),
);
final planWritesProvider = Provider<PlanWrites>((ref) => PlanWrites());
final itineraryProvider =
    AsyncNotifierProvider.family<PlanController, SavedPlan, DateTime>(
      PlanController.new,
    );

DateTime planDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String planDayKey(DateTime day) =>
    planDay(day).toIso8601String().split('T').first;

class SavedPlan {
  SavedPlan(
    Iterable<ItineraryTask> tasks, {
    this.appliedTitle,
    Iterable<String> appliedNotices = const [],
  }) : tasks = List.unmodifiable(tasks),
       appliedNotices = Set.unmodifiable(appliedNotices);

  final List<ItineraryTask> tasks;
  final String? appliedTitle;
  final Set<String> appliedNotices;

  SavedPlan withTasks(
    Iterable<ItineraryTask> tasks, {
    String? appliedTitle,
    String? noticeId,
  }) => SavedPlan(
    tasks,
    appliedTitle: appliedTitle,
    appliedNotices: {...appliedNotices, ?noticeId},
  );

  Map<String, Object?> toJson() => {
    'tasks': [for (final task in tasks) task.toJson()],
    'appliedTitle': appliedTitle,
    if (appliedNotices.isNotEmpty) 'appliedNotices': appliedNotices.toList(),
  };
}

/// Serializes reads and writes that replace a day's plan, including imports.
class PlanWrites {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

class PlanRepository {
  final _preferences = SharedPreferencesAsync();
  static const _legacyKey = 'ripple.plan.v1';
  static const _legacyDayKey = 'ripple.plan.legacyDay';
  Future<String?>? _legacyAssignment;

  String _key(DateTime day) => 'ripple.plan.v2.${planDayKey(day)}';

  Future<String?> _assignLegacyDay() async {
    final assigned = await _preferences.getString(_legacyDayKey);
    if (assigned != null || !await _preferences.containsKey(_legacyKey)) {
      return assigned;
    }
    final today = planDayKey(DateTime.now());
    await _preferences.setString(_legacyDayKey, today);
    return today;
  }

  Future<SavedPlan> load(DateTime day) async {
    String? legacyDay;
    try {
      legacyDay = await (_legacyAssignment ??= _assignLegacyDay());
    } catch (_) {
      _legacyAssignment = null;
      rethrow;
    }
    final raw =
        await _preferences.getString(_key(day)) ??
        (legacyDay == planDayKey(day)
            ? await _preferences.getString(_legacyKey)
            : null);
    if (raw == null) return SavedPlan([]);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final tasks = (decoded['tasks'] as List).map(
      (task) => ItineraryTask.fromJson(task as Map<String, dynamic>),
    );
    return SavedPlan(
      tasks,
      appliedTitle: decoded['appliedTitle'] as String?,
      appliedNotices:
          (decoded['appliedNotices'] as List?)?.cast<String>() ?? const [],
    );
  }

  Future<void> save(DateTime day, SavedPlan plan) =>
      _preferences.setString(_key(day), jsonEncode(plan.toJson()));
}

class PlanController extends AsyncNotifier<SavedPlan> {
  PlanController(this.day);

  final DateTime day;
  static const planner = Planner();
  bool _saving = false;

  @override
  Future<SavedPlan> build() async {
    final plan = await ref.watch(planRepositoryProvider).load(day);
    planner.analyze(plan.tasks);
    return plan;
  }

  Future<void> addExample() => _mutate((current) {
    if (current.tasks.isNotEmpty) {
      throw const FormatException('请先清空行程，再创建看展示例。');
    }
    return current.withTasks(planner.example());
  });

  Future<void> saveTask(ItineraryTask task) => _mutate(
    (current) => current.withTasks([
      for (final item in current.tasks) item.id == task.id ? task : item,
      if (!current.tasks.any((item) => item.id == task.id)) task,
    ]),
  );

  Future<void> addImportedTask(ItineraryTask task) => _mutate((current) {
    if (current.tasks.any((item) => item.id == task.id)) {
      throw const FormatException('这条通知里的安排已加入当天行程。');
    }
    return current.withTasks([...current.tasks, task]);
  });

  Future<void> deleteTask(ItineraryTask task) => _mutate(
    (current) => current.withTasks([
      for (final item in current.tasks)
        if (item.id != task.id)
          item.reschedule(
            after: item.after.where((id) => id != task.id).toList(),
          ),
    ]),
  );

  Future<void> applyOption(
    ReplanOption option,
    SavedPlan reviewedPlan, {
    String? noticeId,
  }) => _mutate((current) {
    if (noticeId != null && current.appliedNotices.contains(noticeId)) {
      throw const FormatException('这条通知的方案已应用。');
    }
    if (jsonEncode(current.toJson()) != jsonEncode(reviewedPlan.toJson())) {
      throw const FormatException('行程已更新，请重新查看方案。');
    }
    final proposed = {for (final task in option.tasks) task.id: task};
    if (proposed.length != current.tasks.length ||
        current.tasks.any((task) {
          final next = proposed[task.id];
          return next == null ||
              next.timing != task.timing ||
              (task.timing == Timing.fixed &&
                  (next.start != task.start || next.duration != task.duration));
        })) {
      throw const FormatException('方案必须保留原行程和固定时间。');
    }
    if (planner.analyze(option.tasks).conflicts.isNotEmpty) {
      throw const FormatException('方案还有时间冲突，请重新检查。');
    }
    return current.withTasks(
      option.tasks,
      appliedTitle: option.title,
      noticeId: noticeId,
    );
  });

  Future<void> _mutate(SavedPlan Function(SavedPlan) update) async {
    if (state.asData == null || _saving) {
      throw const FormatException('行程正在保存或载入，请稍后再试。');
    }
    _saving = true;
    try {
      final repository = ref.read(planRepositoryProvider);
      await ref.read(planWritesProvider).run(() async {
        if (!ref.mounted) {
          throw const FormatException('行程已更新，请重试。');
        }
        final current = await repository.load(day);
        final next = update(current);
        planner.analyze(next.tasks);
        await repository.save(day, next);
        if (ref.mounted) state = AsyncData(next);
      });
    } finally {
      _saving = false;
    }
  }
}
