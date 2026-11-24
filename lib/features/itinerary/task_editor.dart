import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'itinerary.dart';
import 'plan_controller.dart';

class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({super.key, required this.tasks, this.task});

  final List<ItineraryTask> tasks;
  final ItineraryTask? task;

  @override
  ConsumerState<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<TaskEditor> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.task?.title);
  late final _location = TextEditingController(text: widget.task?.location);
  late final _duration = TextEditingController(
    text: '${widget.task?.duration ?? 30}',
  );
  late final _transfer = TextEditingController(
    text: '${widget.task?.transfer ?? 0}',
  );
  late int _start = widget.task?.start ?? 14 * 60;
  late Timing _timing = widget.task?.timing ?? Timing.flexible;
  late final _after = {...?widget.task?.after};
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _duration.dispose();
    _transfer.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _start ~/ 60, minute: _start % 60),
      initialEntryMode: TimePickerEntryMode.input,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time != null && mounted) {
      setState(() => _start = time.hour * 60 + time.minute);
    }
  }

  Future<void> _change(Future<void> Function(PlanController) operation) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await operation(ref.read(itineraryProvider.notifier));
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context, true);
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final task = ItineraryTask(
      id: widget.task?.id ?? 'task-${DateTime.now().microsecondsSinceEpoch}',
      title: _title.text.trim(),
      start: _start,
      duration: int.parse(_duration.text),
      location: _location.text.trim(),
      timing: _timing,
      transfer: _after.isEmpty ? 0 : int.parse(_transfer.text),
      after: _after,
    );
    _change((controller) => controller.saveTask(task));
  }

  Future<void> _delete() async {
    final task = widget.task!;
    final used = widget.tasks.any((item) => item.after.contains(task.id));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${task.title}」？'),
        content: Text(used ? '以这项为前置行程的关联也会解除。' : '这项行程将从时间轴移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _change((controller) => controller.deleteTask(task));
    }
  }

  Widget _minutes(String label, TextEditingController controller) =>
      TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: label, suffixText: '分钟'),
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(4),
        ],
        validator: (value) {
          final number = int.tryParse(value ?? '');
          return number != null && number < minutesPerDay
              ? null
              : '请输入 0–1439 分钟';
        },
      );

  @override
  Widget build(BuildContext context) {
    final otherTasks = widget.tasks.where((task) => task.id != widget.task?.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.task == null ? '添加行程' : '编辑行程'),
        actions: [
          if (widget.task != null)
            IconButton(
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除行程',
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _title,
                      maxLength: 48,
                      decoration: const InputDecoration(labelText: '行程名称'),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '请输入行程名称'
                          : null,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _location,
                      maxLength: 64,
                      decoration: const InputDecoration(labelText: '地点（选填）'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _pickTime,
                      icon: const Icon(Icons.schedule),
                      label: Text('开始时间　${clockTime(_start)}'),
                    ),
                    const SizedBox(height: 16),
                    _minutes('时长', _duration),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<Timing>(
                      initialValue: _timing,
                      decoration: const InputDecoration(labelText: '时间约束'),
                      items: [
                        for (final timing in Timing.values)
                          DropdownMenuItem(
                            value: timing,
                            child: Text(timing.label),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _timing = value!),
                    ),
                    if (otherTasks.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text(
                        '前置行程',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Text('勾选必须先完成的行程。'),
                      for (final task in otherTasks)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(task.title),
                          subtitle: Text(clockTime(task.start)),
                          value: _after.contains(task.id),
                          onChanged: _saving
                              ? null
                              : (selected) => setState(() {
                                  if (selected == true) {
                                    _after.add(task.id);
                                  } else {
                                    _after.remove(task.id);
                                  }
                                }),
                        ),
                    ],
                    if (_after.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _minutes('前置行程结束后的转场时间', _transfer),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? '正在保存…' : '保存行程'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
