import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../notifications/notification_association.dart';
import '../notifications/notification_import.dart';
import '../notifications/notification_inbox.dart';
import '../notifications/notification_inbox_page.dart';
import '../notifications/notification_review_dialog.dart';
import '../settings/settings_page.dart';
import 'day_picker.dart';
import 'itinerary.dart';
import 'plan_controller.dart';
import 'review_page.dart';
import 'task_editor.dart';

class ItineraryPage extends ConsumerStatefulWidget {
  const ItineraryPage({super.key});

  @override
  ConsumerState<ItineraryPage> createState() => _ItineraryPageState();
}

class _ItineraryPageState extends ConsumerState<ItineraryPage> {
  bool _working = false;
  bool _scrolling = false;
  int _destinationIndex = 0;
  DateTime _day = planDay(DateTime.now());
  AppLifecycleListener? _notificationLifecycle;
  StreamSubscription<dynamic>? _notificationChanges;
  bool _syncingNotifications = false;
  bool _syncAgain = false;
  bool _reviewAfterSync = false;
  bool _reviewingNotifications = false;

  bool get _notificationsAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (!_notificationsAvailable) return;
    _notificationLifecycle = AppLifecycleListener(
      onResume: () => _syncNotifications(review: true),
    );
    _notificationChanges = NotificationInbox.changes.listen(
      (_) => _syncNotifications(),
      onError: (Object _) => _syncNotifications(),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncNotifications(review: true),
    );
  }

  @override
  void dispose() {
    _notificationChanges?.cancel();
    _notificationLifecycle?.dispose();
    super.dispose();
  }

  Future<void> _syncNotifications({bool review = false}) async {
    if (!mounted || !_notificationsAvailable) return;
    if (_syncingNotifications) {
      _syncAgain = true;
      _reviewAfterSync |= review;
      return;
    }
    _syncingNotifications = true;
    var reminders = 0;
    try {
      final inbox = await NotificationInbox.read();
      if (!mounted) return;
      try {
        final importer = ref.read(notificationImporterProvider);
        reminders = (await importer.sync(inbox: inbox)).reminders;
      } catch (_) {
        // 写入失败时，下次同步重试。
      }
      if (!mounted) return;
      final alerts = await ref
          .read(notificationAssociationsProvider.notifier)
          .refresh(inbox);
      if (alerts > 0 && mounted && ModalRoute.of(context)?.isCurrent == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$alerts 条通知需要核对关联行程'),
            action: SnackBarAction(
              label: '查看关联',
              onPressed: _openAssociationInbox,
            ),
          ),
        );
      }
    } catch (_) {
      // 保留上次结果，等待下一次同步。
    } finally {
      _syncingNotifications = false;
      if (_syncAgain && mounted) {
        final review = _reviewAfterSync;
        _syncAgain = false;
        _reviewAfterSync = false;
        unawaited(_syncNotifications(review: review));
      }
    }
    if ((review || reminders > 0) && mounted) {
      try {
        await _reviewImports();
      } catch (_) {
        // 保留待确认项目，等待下一次打开。
      }
    }
  }

  /// Asks once per app start which automatic additions should stay.
  Future<void> _reviewImports() async {
    if (_reviewingNotifications || !mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final importer = ref.read(notificationImporterProvider);
    final pending = await importer.pending();
    if (pending.isEmpty || !mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    if (_reviewingNotifications) return;
    _reviewingNotifications = true;
    try {
      final decisions = await showDialog<Map<String, ImportDecision>>(
        context: context,
        builder: (_) => NotificationReviewDialog(items: pending),
      );
      if (decisions == null) return;
      await importer.resolve(pending, decisions);
    } finally {
      _reviewingNotifications = false;
    }
  }

  Future<void> _change(Future<void> Function(PlanController) operation) async {
    setState(() => _working = true);
    try {
      await operation(ref.read(itineraryProvider(_day).notifier));
      unawaited(_syncNotifications());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : '保存失败，请重试。',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _edit([ItineraryTask? task]) async {
    final day = _day;
    final saved = await Navigator.of(context).push<DateTime>(
      MaterialPageRoute(
        builder: (_) => TaskEditor(day: day, task: task),
      ),
    );
    if (saved != null) unawaited(_syncNotifications());
  }

  void _viewPlan(DateTime day) {
    setState(() {
      _day = planDay(day);
      _destinationIndex = 0;
      _scrolling = false;
    });
  }

  void _openAssociationInbox() {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NotificationInboxPage(
          onViewPlan: _viewPlan,
          associationsFirst: true,
        ),
      ),
    );
  }

  void _review(SavedPlan plan, PlanAnalysis analysis) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ReviewPage(
            day: _day,
            plan: plan,
            analysis: analysis,
            options: PlanController.planner.options(plan.tasks, analysis),
          ),
        ),
      );

  bool _handleScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification && !_scrolling) {
      setState(() => _scrolling = true);
    }
    if (notification is ScrollEndNotification && _scrolling) {
      setState(() => _scrolling = false);
    }
    return false;
  }

  void _selectDestination(int index) {
    if (index == _destinationIndex) return;
    setState(() {
      _destinationIndex = index;
      _scrolling = false;
    });
  }

  // Keep the layout stable while the add button is out of sight.
  Widget _duringRest(Widget child) => Visibility(
    visible: !_scrolling,
    maintainState: true,
    maintainAnimation: true,
    maintainSize: true,
    child: child,
  );

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: Theme.of(context).brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark,
    child: ref
        .watch(itineraryProvider(_day))
        .when(
          loading: () => const Scaffold(
            body: Center(
              child: CircularProgressIndicator(semanticsLabel: '正在读取行程'),
            ),
          ),
          error: (_, _) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('行程读取失败。'),
                  TextButton(
                    onPressed: () => ref.invalidate(itineraryProvider(_day)),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
          data: _content,
        ),
  );

  Widget _content(SavedPlan plan) {
    final isSchedule = _destinationIndex == 0;
    final associationAlerts = _notificationsAvailable
        ? ref.watch(
            notificationAssociationsProvider.select(
              (links) =>
                  links.values.where((link) => link.needsAttention).length,
            ),
          )
        : 0;
    final sideInset =
        (MediaQuery.sizeOf(context).width - 640).clamp(0.0, double.infinity) /
            2 +
        16;
    return PopScope(
      canPop: isSchedule,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selectDestination(0);
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 48,
          actions: [
            if (associationAlerts > 0 && _destinationIndex != 2)
              IconButton(
                tooltip: '查看通知关联',
                onPressed: _openAssociationInbox,
                icon: Badge.count(
                  count: associationAlerts,
                  child: const Icon(Icons.notifications_outlined),
                ),
              ),
          ],
          title: _destinationIndex == 2
              ? const Text('设置')
              : TextButton.icon(
                  onPressed: _working
                      ? null
                      : () async {
                          final selected = await pickPlanDay(context, _day);
                          if (mounted && selected != null) {
                            setState(() => _day = selected);
                          }
                        },
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(planDayLabel(_day)),
                ),
        ),
        floatingActionButton: isSchedule
            ? _duringRest(
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FloatingActionButton(
                    tooltip: '添加行程',
                    onPressed: _working ? null : _edit,
                    child: const Icon(Icons.add),
                  ),
                ),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _destinationIndex,
          onDestinationSelected: _selectDestination,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.calendar_today_outlined),
              selectedIcon: Icon(Icons.calendar_today),
              label: '日程',
            ),
            const NavigationDestination(
              icon: Icon(Icons.account_tree_outlined),
              selectedIcon: Icon(Icons.account_tree),
              label: '关系',
            ),
            if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
              const NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: '设置',
              ),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: switch (_destinationIndex) {
            0 => _schedule(
              plan,
              PlanController.planner.analyze(plan.tasks),
              sideInset,
            ),
            1 => _relationships(plan, sideInset),
            _ => SettingsPage(onViewPlan: _viewPlan),
          },
        ),
      ),
    );
  }

  Widget _schedule(SavedPlan plan, PlanAnalysis analysis, double sideInset) {
    final theme = Theme.of(context);
    final summaryTitle = PlanController.planner.summaryTitle(plan.tasks);
    if (summaryTitle == null) return _empty(sideInset);

    final tasks = [...plan.tasks]
      ..sort((a, b) {
        final byTime = a.start.compareTo(b.start);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    final impacts = <String, List<TaskConflict>>{};
    for (final conflict in analysis.conflicts) {
      (impacts[conflict.task.id] ??= []).add(conflict);
    }
    final hasExample = tasks.any((task) => task.id == Planner.demoExhibition);
    final exampleMeeting = tasks
        .where(
          (task) => task.id == Planner.demoMeeting && task.start == 14 * 60,
        )
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(sideInset, 12, sideInset, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card.filled(
                child: ListTile(
                  title: Semantics(
                    header: true,
                    child: Text(
                      summaryTitle,
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  subtitle: Text('${tasks.length} 项行程'),
                ),
              ),
              if (impacts.isNotEmpty)
                Card.filled(
                  child: ListTile(
                    leading: Icon(
                      Icons.warning_amber_rounded,
                      color: theme.colorScheme.error,
                    ),
                    title: Text('${impacts.length} 项行程有时间冲突'),
                    trailing: TextButton(
                      onPressed: _working
                          ? null
                          : () => _review(plan, analysis),
                      child: const Text('查看冲突'),
                    ),
                  ),
                ),
              if (plan.appliedTitle != null)
                Semantics(
                  liveRegion: true,
                  child: Card.filled(
                    child: ListTile(
                      leading: const Icon(Icons.check_circle_outline),
                      title: Text('已应用方案：${plan.appliedTitle}'),
                    ),
                  ),
                ),
              if (exampleMeeting != null &&
                  hasExample &&
                  plan.appliedTitle == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('模拟朋友晚到 40 分钟'),
                    onPressed: _working
                        ? null
                        : () => _change(
                            (controller) => controller.saveTask(
                              exampleMeeting.reschedule(start: 14 * 60 + 40),
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _handleScroll,
            child: ListView.builder(
              key: const PageStorageKey('itinerary-timeline'),
              padding: EdgeInsets.fromLTRB(sideInset, 0, sideInset, 88),
              itemCount: tasks.length,
              itemBuilder: (_, index) {
                final task = tasks[index];
                return _TimelineRow(
                  task: task,
                  conflicts: impacts[task.id] ?? const [],
                  first: index == 0,
                  last: index == tasks.length - 1,
                  onPressed: _working ? null : () => _edit(task),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _relationships(SavedPlan plan, double sideInset) {
    final theme = Theme.of(context);
    final tasksById = {for (final task in plan.tasks) task.id: task};
    final linked = plan.tasks.where((task) => task.after.isNotEmpty).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return ListView(
      key: const PageStorageKey('itinerary-relationships'),
      padding: EdgeInsets.fromLTRB(sideInset, 16, sideInset, 16),
      children: [
        Semantics(
          header: true,
          child: Text('行程关系', style: theme.textTheme.titleLarge),
        ),
        const SizedBox(height: 12),
        if (linked.isEmpty)
          const ListTile(
            leading: Icon(Icons.account_tree_outlined),
            title: Text('暂无前置关系'),
            subtitle: Text('编辑行程时，可以选择需要先完成的行程。'),
          ),
        for (final task in linked)
          Card.filled(
            child: ListTile(
              title: Text('${clockTime(task.start)}　${task.title}'),
              subtitle: Text(
                '在 ${task.after.map((id) {
                  final previous = tasksById[id]!;
                  return '${clockTime(previous.start)} ${previous.title}';
                }).join('、')} 之后开始'
                '${task.transfer > 0 ? '\n预留 ${task.transfer} 分钟转场' : ''}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _working ? null : () => _edit(task),
            ),
          ),
      ],
    );
  }

  Widget _empty(double sideInset) {
    final theme = Theme.of(context);
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(sideInset, 24, sideInset, 80),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.event_available_outlined,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text('这一天还没有安排', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  '点右下角添加行程，或先试试看展示例。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _working
                      ? null
                      : () => _change((controller) => controller.addExample()),
                  child: const Text('创建看展示例'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.task,
    required this.conflicts,
    required this.first,
    required this.last,
    required this.onPressed,
  });

  final ItineraryTask task;
  final List<TaskConflict> conflicts;
  final bool first;
  final bool last;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = [
      if (task.location.isNotEmpty) task.location,
      if (task.duration > 0) '${task.duration} 分钟',
      if (task.timing != Timing.flexible) task.timing.label,
    ].join('　');
    return CustomPaint(
      painter: _TrackPainter(
        first: first,
        last: last,
        line: scheme.outlineVariant,
        node: conflicts.isEmpty ? scheme.primary : scheme.error,
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: ListTile(
          onTap: onPressed,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          trailing: const Icon(Icons.chevron_right),
          title: Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                clockTime(task.start),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(task.title),
            ],
          ),
          subtitle: detail.isEmpty && conflicts.isEmpty
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (detail.isNotEmpty) Text(detail),
                    for (final conflict in conflicts)
                      Text(
                        conflict.summary,
                        style: TextStyle(color: scheme.error),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.first,
    required this.last,
    required this.line,
    required this.node,
  });

  final bool first;
  final bool last;
  final Color line;
  final Color node;

  @override
  void paint(Canvas canvas, Size size) {
    const center = Offset(7, 28);
    canvas.drawLine(
      Offset(center.dx, first ? center.dy : 0),
      Offset(center.dx, last ? center.dy : size.height),
      Paint()
        ..color = line
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(center, 4, Paint()..color = node);
  }

  @override
  bool shouldRepaint(covariant _TrackPainter oldDelegate) =>
      first != oldDelegate.first ||
      last != oldDelegate.last ||
      line != oldDelegate.line ||
      node != oldDelegate.node;
}
