import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'itinerary.dart';

final planRepositoryProvider = Provider<PlanRepository>(
  (ref) => PlanRepository(),
);
final itineraryProvider = AsyncNotifierProvider<PlanController, SavedPlan>(
  PlanController.new,
);

class SavedPlan {
  SavedPlan(Iterable<ItineraryTask> tasks, {this.appliedTitle})
    : tasks = List.unmodifiable(tasks);

  final List<ItineraryTask> tasks;
  final String? appliedTitle;
}

class PlanRepository {
  final _preferences = SharedPreferencesAsync();
  static const _key = 'ripple.plan.v1';

  Future<SavedPlan> load() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return SavedPlan([]);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final tasks = (decoded['tasks'] as List).map(
      (task) => ItineraryTask.fromJson(task as Map<String, dynamic>),
    );
    return SavedPlan(tasks, appliedTitle: decoded['appliedTitle'] as String?);
  }

  Future<void> save(SavedPlan plan) => _preferences.setString(
    _key,
    jsonEncode({
      'tasks': plan.tasks.map((task) => task.toJson()).toList(),
      'appliedTitle': plan.appliedTitle,
    }),
  );
}

class PlanController extends AsyncNotifier<SavedPlan> {
  static const planner = Planner();
  bool _saving = false;

  @override
  Future<SavedPlan> build() async {
    final plan = await ref.watch(planRepositoryProvider).load();
    planner.analyze(plan.tasks);
    return plan;
  }

  Future<void> addExample() => _mutate((current) {
    if (current.tasks.isNotEmpty) {
      throw const FormatException('请先清空行程，再创建看展示例。');
    }
    return SavedPlan(planner.example());
  });

  Future<void> saveTask(ItineraryTask task) => _mutate(
    (current) => SavedPlan([
      for (final item in current.tasks) item.id == task.id ? task : item,
      if (!current.tasks.any((item) => item.id == task.id)) task,
    ]),
  );

  Future<void> deleteTask(ItineraryTask task) => _mutate(
    (current) => SavedPlan([
      for (final item in current.tasks)
        if (item.id != task.id)
          item.reschedule(
            after: item.after.where((id) => id != task.id).toList(),
          ),
    ]),
  );

  Future<void> applyOption(ReplanOption option, SavedPlan reviewedPlan) =>
      _mutate((current) {
        if (!identical(current, reviewedPlan)) {
          throw const FormatException('行程已更新，请重新查看方案。');
        }
        if (planner.analyze(option.tasks).conflicts.isNotEmpty) {
          throw const FormatException('方案还有时间冲突，请重新检查。');
        }
        return SavedPlan(option.tasks, appliedTitle: option.title);
      });

  Future<void> _mutate(SavedPlan Function(SavedPlan) update) async {
    final current = state.asData?.value;
    if (current == null || _saving) {
      throw const FormatException('行程正在保存或载入，请稍后再试。');
    }
    _saving = true;
    try {
      final next = update(current);
      planner.analyze(next.tasks);
      await ref.read(planRepositoryProvider).save(next);
      if (ref.mounted) state = AsyncData(next);
    } finally {
      _saving = false;
    }
  }
}
