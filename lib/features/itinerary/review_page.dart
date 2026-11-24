import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'itinerary.dart';
import 'plan_controller.dart';

class ReviewPage extends ConsumerStatefulWidget {
  const ReviewPage({
    super.key,
    required this.plan,
    required this.analysis,
    required this.options,
  });

  final SavedPlan plan;
  final PlanAnalysis analysis;
  final List<ReplanOption> options;

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  ReplanOption? _selection;
  bool _working = false;

  Future<void> _apply() async {
    setState(() => _working = true);
    try {
      await ref
          .read(itineraryProvider.notifier)
          .applyOption(_selection!, widget.plan);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : '应用失败，请重试。',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = {for (final task in widget.plan.tasks) task.id: task.title};
    final originals = {for (final task in widget.plan.tasks) task.id: task};
    return Scaffold(
      appBar: AppBar(title: const Text('调整行程')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 630),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 25),
              children: [
                Text('时间冲突', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                for (final conflict in widget.analysis.conflicts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule),
                    iconColor: theme.colorScheme.error,
                    title: Text(
                      '${clockTime(conflict.task.start)}　${conflict.task.title}',
                    ),
                    subtitle: Text(conflict.summary),
                  ),
                const Divider(height: 30),
                if (widget.options.isEmpty) ...[
                  Text('需要手动调整', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text('当前行程没有符合所有时间约束的方案。返回时间轴编辑时间、时长或前置行程。'),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('返回时间轴'),
                    ),
                  ),
                ] else ...[
                  Text('选择一个方案', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 10),
                  RadioGroup<ReplanOption>(
                    groupValue: _selection,
                    onChanged: (option) => setState(() => _selection = option),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final option in widget.options)
                          Card.filled(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                RadioListTile<ReplanOption>(
                                  enabled: !_working,
                                  value: option,
                                  selected: option == _selection,
                                  title: Text(option.title),
                                  subtitle: Text(option.description),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    0,
                                    20,
                                    14,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      for (final task in option.tasks)
                                        if (!identical(
                                          task,
                                          originals[task.id],
                                        ))
                                          ..._changes(
                                            originals[task.id]!,
                                            task,
                                            names,
                                            theme.colorScheme,
                                          ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: widget.options.isEmpty
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 590),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _working || _selection == null ? null : _apply,
                      child: Text(_working ? '正在应用…' : '确认并更新行程'),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  List<Widget> _changes(
    ItineraryTask before,
    ItineraryTask after,
    Map<String, String> names,
    ColorScheme scheme,
  ) {
    final changes = [
      if (before.start != after.start)
        '${clockTime(before.start)} → ${clockTime(after.start)}',
      if (before.duration != after.duration)
        '${before.duration} → ${after.duration} 分钟',
      if (before.location != after.location) '地点改为 ${after.location}',
      if (before.after.toSet().difference(after.after.toSet()).isNotEmpty ||
          after.after.toSet().difference(before.after.toSet()).isNotEmpty)
        after.after.isEmpty
            ? '解除前置行程'
            : '改为在 ${after.after.map((id) => names[id]).join('、')} 之后',
    ];
    if (changes.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '${after.title}　${changes.join('　')}',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ),
    ];
  }
}
