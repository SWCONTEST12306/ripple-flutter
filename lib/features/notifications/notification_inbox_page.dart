import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../itinerary/day_picker.dart';
import '../itinerary/itinerary.dart';
import '../itinerary/plan_controller.dart';
import '../itinerary/task_editor.dart';
import 'notification_analysis.dart';
import 'notification_association.dart';
import 'notification_event.dart';
import 'notification_impact.dart';
import 'notification_inbox.dart';
import 'notification_model_page.dart';
import 'schedule_matcher.dart';

class NotificationInboxPage extends ConsumerStatefulWidget {
  const NotificationInboxPage({
    super.key,
    required this.onViewPlan,
    this.associationsFirst = false,
  });

  final ValueChanged<DateTime> onViewPlan;
  final bool associationsFirst;

  @override
  ConsumerState<NotificationInboxPage> createState() =>
      _NotificationInboxPageState();
}

class _NotificationInboxPageState extends ConsumerState<NotificationInboxPage> {
  final _inbox = ValueNotifier<NotificationInbox?>(null);
  late final AppLifecycleListener _lifecycle;
  late final StreamSubscription<dynamic> _changes;
  String? _error;
  int _refreshVersion = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _changes = NotificationInbox.changes.listen(
      (_) => _refresh(),
      onError: (Object _) => _refresh(),
    );
    _refresh();
  }

  @override
  void dispose() {
    _changes.cancel();
    _lifecycle.dispose();
    _inbox.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool match = false}) async {
    final version = ++_refreshVersion;
    final NotificationInbox inbox;
    try {
      inbox = await NotificationInbox.read();
      if (!mounted || version != _refreshVersion) return;
      setState(() {
        _inbox.value = inbox;
        _error = null;
      });
    } catch (_) {
      if (!mounted || version != _refreshVersion) return;
      setState(() {
        _inbox.value = null;
        _error = '本机通知读取失败，请重试。';
      });
      return;
    }
    if (match) {
      try {
        await ref
            .read(notificationAssociationsProvider.notifier)
            .refresh(inbox);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('暂时无法更新关联，请重试。')));
        }
      }
    }
  }

  Future<void> _openSettings() async {
    try {
      await NotificationInbox.openSettings();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开系统的通知读取设置。')));
      }
    }
  }

  void _view(AndroidNotice notice) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _NotificationDetail(
        noticeKey: notice.key,
        inbox: _inbox,
        onViewPlan: widget.onViewPlan,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('最近通知')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _content(),
        ),
      ),
    ),
  );

  Widget _content() {
    if (_error case final error?) {
      return _empty(
        error,
        action: TextButton(onPressed: _refresh, child: const Text('重试')),
      );
    }
    final inbox = _inbox.value;
    if (inbox == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!inbox.authorized) {
      return _empty(
        '开启系统通知读取权限后，可以查看最近的通知。',
        action: FilledButton(
          onPressed: _openSettings,
          child: const Text('开启通知读取权限'),
        ),
      );
    }
    final links = ref.watch(notificationAssociationsProvider);
    final statuses = {
      for (final notice in inbox.entries)
        notice.key: [
          for (final event in notice.analysis?.events ?? <ExtractedEvent>[])
            ?links[notificationTaskId(notice, event)],
        ],
    };
    bool needsAttention(AndroidNotice notice) =>
        statuses[notice.key]!.any((link) => link.needsAttention);
    final entries = widget.associationsFirst
        ? [
            ...inbox.entries.where(needsAttention),
            ...inbox.entries.where((notice) => !needsAttention(notice)),
          ]
        : inbox.entries;
    return RefreshIndicator(
      onRefresh: () => _refresh(match: true),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: entries.isEmpty ? 1 : entries.length,
        itemBuilder: (context, index) {
          if (entries.isEmpty) {
            return const ListTile(
              leading: Icon(Icons.notifications_none),
              title: Text('还没有读取到通知'),
              subtitle: Text('在设置中打开需要读取的应用后，收到的新通知会显示在这里。'),
            );
          }
          final notice = entries[index];
          final result = notice.analysis;
          final status = statuses[notice.key]!;
          return Card.filled(
            child: ListTile(
              title: Text(
                notice.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  '${notice.source} · ${_postedAt(notice)}',
                  if (result != null)
                    result.summary
                  else
                    _extractionStatus(notice),
                  if (result == null &&
                      !notice.sensitive &&
                      notice.text.isNotEmpty)
                    notice.text,
                  if (status.any((link) => link.needsChoice))
                    '待选择关联行程'
                  else if (status.any((link) => link.impact.needsAttention))
                    '有关联行程需要核对'
                  else if (status.any((link) => link.target != null))
                    '已关联行程',
                ].join('\n'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _view(notice),
            ),
          );
        },
      ),
    );
  }

  Widget _empty(String message, {required Widget action}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          action,
        ],
      ),
    ),
  );
}

class _NotificationDetail extends StatefulWidget {
  const _NotificationDetail({
    required this.noticeKey,
    required this.inbox,
    required this.onViewPlan,
  });

  final String noticeKey;
  final ValueNotifier<NotificationInbox?> inbox;
  final ValueChanged<DateTime> onViewPlan;

  @override
  State<_NotificationDetail> createState() => _NotificationDetailState();
}

class _NotificationDetailState extends State<_NotificationDetail> {
  final _added = <String, DateTime>{};
  bool _editing = false;

  Future<void> _add(String id, ExtractedEvent event, DateTime? day) async {
    if (_editing) return;
    _editing = true;
    try {
      final saved = await Navigator.of(context).push<DateTime>(
        MaterialPageRoute(
          builder: (_) => TaskEditor(
            day: day,
            draft: TaskDraft(
              id: id,
              title: event.title,
              location: event.location,
              people: event.people,
              start: eventMinutes(event.time),
              duration: event.durationMinutes,
            ),
          ),
        ),
      );
      if (mounted && saved != null) setState(() => _added[id] = saved);
    } finally {
      _editing = false;
    }
  }

  void _viewPlan(DateTime day) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    widget.onViewPlan(day);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('通知详情')),
    body: SafeArea(
      child: ValueListenableBuilder(
        valueListenable: widget.inbox,
        builder: (context, inbox, _) {
          if (inbox == null) return const Center(child: Text('本机通知读取失败。'));
          if (!inbox.authorized) return const Center(child: Text('通知读取权限已关闭。'));
          final notice = inbox.entries
              .where((entry) => entry.key == widget.noticeKey)
              .firstOrNull;
          if (notice == null) return const Center(child: Text('这条通知已不在收件箱中。'));
          return _content(context, notice);
        },
      ),
    ),
  );

  Widget _content(BuildContext context, AndroidNotice notice) {
    final theme = Theme.of(context);
    final result = notice.analysis;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              '${notice.source} · ${_postedAt(notice)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (notice.title.isNotEmpty)
              SelectableText(notice.title, style: theme.textTheme.titleLarge),
            if (notice.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(notice.text),
            ],
            const SizedBox(height: 24),
            if (result == null) ...[
              Semantics(
                liveRegion: true,
                child: Text(_extractionStatus(notice)),
              ),
              if (!notice.automatic && !notice.sensitive)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _openModelSettings(context),
                    child: const Text('打开 AI 模型设置'),
                  ),
                ),
            ],
            if (result != null) ...[
              Text('AI 提取结果', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(result.summary),
              for (final event in result.events)
                _EventCard(
                  event,
                  action: event.kind == EventKind.newEvent
                      ? _scheduleAction(notice, event)
                      : _associationAction(notice, event),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _scheduleAction(AndroidNotice notice, ExtractedEvent event) {
    final id = notificationTaskId(notice, event);
    final day =
        _added[id] ?? eventDate(event.date) ?? planDay(notice.localPostedAt);
    return Consumer(
      builder: (context, ref, _) {
        final added =
            ref
                .watch(itineraryProvider(day))
                .asData
                ?.value
                .tasks
                .any((task) => task.id == id) ==
            true;
        return added
            ? TextButton.icon(
                onPressed: () => _viewPlan(day),
                icon: const Icon(Icons.check),
                label: const Text('已加入 · 查看行程'),
              )
            : FilledButton.tonalIcon(
                onPressed: () => _add(id, event, day),
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('加入行程'),
              );
      },
    );
  }

  Widget _associationAction(AndroidNotice notice, ExtractedEvent event) {
    final id = notificationTaskId(notice, event);
    return Consumer(
      builder: (context, ref, _) {
        final association = ref.watch(
          notificationAssociationsProvider.select((links) => links[id]),
        );
        if (association == null) return const SizedBox.shrink();
        final target = association.target;
        if (target == null) {
          if (association.needsChoice) {
            return FilledButton.tonalIcon(
              onPressed: () => _choose(ref, id, event, association.candidates),
              icon: const Icon(Icons.link),
              label: const Text('选择关联行程'),
            );
          }
          return Text(association.dismissed ? '已忽略此关联' : '未找到相关行程');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '已关联：${target.task.title}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(_candidateDetails(target)),
            if (target.evidence.isNotEmpty) Text(target.evidence.join('、')),
            if (association.impact.alerts.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '请核对行程',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              for (final alert in association.impact.alerts) Text(alert),
            ],
            TextButton.icon(
              onPressed: () => _viewPlan(target.day),
              icon: const Icon(Icons.event_outlined),
              label: const Text('查看关联行程'),
            ),
            if (association.impact.steps.isNotEmpty)
              _ImpactPreview(association.impact.steps),
          ],
        );
      },
    );
  }

  Future<void> _choose(
    WidgetRef ref,
    String id,
    ExtractedEvent event,
    List<ScheduleCandidate> candidates,
  ) async {
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择关联行程'),
        children: [
          for (final (index, candidate) in candidates.indexed)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, index),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(candidate.task.title),
                subtitle: Text(
                  [
                    _candidateDetails(candidate),
                    ...candidate.evidence,
                  ].join(' · '),
                ),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, -1),
            child: const Text('忽略关联'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    try {
      await ref
          .read(notificationAssociationsProvider.notifier)
          .choose(id, event, choice < 0 ? null : candidates[choice]);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : '保存关联失败，请重试。',
            ),
          ),
        );
      }
    }
  }

  String _candidateDetails(ScheduleCandidate candidate) => [
    '${planDayLabel(candidate.day)} ${clockTime(candidate.task.start)}',
    if (candidate.task.location.isNotEmpty) candidate.task.location,
  ].join(' · ');
}

class _ImpactPreview extends StatelessWidget {
  const _ImpactPreview(this.steps);

  final List<ImpactStep> steps;

  String _time(int minutes) {
    if (minutes >= 0) return clockTime(minutes);
    final daysBack = (-minutes + minutesPerDay - 1) ~/ minutesPerDay;
    final day = daysBack == 1 ? '前一日' : '$daysBack 天前';
    return '$day ${clockTime(minutes % minutesPerDay)}';
  }

  String? _reason(ImpactStep step) {
    final predecessor = step.predecessor;
    if (predecessor == null) return null;
    if (step.earliest == null) return '请先核对前置行程「${predecessor.title}」。';
    if (step.absorbed) return '「${predecessor.title}」的延误已被本段缓冲吸收。';
    if (!step.worsens) return '「${predecessor.title}」更早就绪。';
    final transfer = step.task.transfer;
    return transfer == 0
        ? '需要等「${predecessor.title}」完成。'
        : '「${predecessor.title}」完成后需转场 $transfer 分钟。';
  }

  String? _timeRisk(ImpactStep step) {
    if (!step.worsens || step.lateMinutes <= 0) return null;
    final late = '晚 ${step.lateMinutes} 分钟';
    return switch (step.task.timing) {
      Timing.flexible => '预计$late',
      Timing.reservation => '可能错过预约（$late）',
      Timing.fixed => '可能赶不上固定时间（$late）',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('事件影响预览', style: theme.textTheme.titleMedium),
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '「${step.task.title}」',
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    [
                      '原定 ${_time(step.task.start)}',
                      if (step.earliest != null &&
                          step.baseline != step.task.start)
                        '变动前最早 ${_time(step.baseline)}',
                      if (step.earliest case final earliest?)
                        '预计最早 ${_time(earliest)}'
                      else
                        '时间待核对',
                    ].join(' · '),
                  ),
                  if (_reason(step) case final reason?) Text(reason),
                  if (_timeRisk(step) case final risk?)
                    Text(
                      risk,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _extractionStatus(AndroidNotice notice) {
  if (notice.sensitive) return '包含验证码，这条通知只保存在本机。';
  if (!notice.automatic) return '尚未解析，检查通知读取开关和 AI 模型设置。';
  if (notice.retrying) return '${notice.error} 稍后会自动重试。';
  return notice.error.isNotEmpty ? notice.error : '正在用 AI 解析…';
}

class _EventCard extends StatelessWidget {
  const _EventCard(this.event, {this.action});

  final ExtractedEvent event;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final original = [
      event.originalDate,
      event.originalTime,
    ].nonNulls.join(' ');
    final time = [event.date, event.time].nonNulls.join(' ');
    return Card.filled(
      semanticContainer: false,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.kind.label, style: theme.textTheme.labelLarge),
            Text(event.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (original.isNotEmpty) Text('原时间　$original'),
            if (time.isNotEmpty)
              Text('${event.kind == EventKind.newEvent ? '时间' : '新时间'}　$time'),
            if (time.isEmpty &&
                original.isEmpty &&
                event.kind == EventKind.newEvent)
              const Text('时间待确认'),
            if (event.delayMinutes case final minutes?)
              Text('预计延后　$minutes 分钟'),
            if (event.tentative ||
                RegExp(r'可能|大概|不确定').hasMatch(event.evidence))
              const Text('变动待确认'),
            if (event.durationMinutes case final minutes?)
              Text('时长　$minutes 分钟'),
            if (event.originalLocation case final location?)
              Text('原地点　$location'),
            if (event.location case final location?) Text('地点　$location'),
            if (event.reference case final reference?) Text('行程编号　$reference'),
            const SizedBox(height: 8),
            Text('原文依据', style: theme.textTheme.labelMedium),
            SelectableText(event.evidence),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

String _postedAt(AndroidNotice notice) {
  final at = notice.localPostedAt;
  final hour = at.hour.toString().padLeft(2, '0');
  final minute = at.minute.toString().padLeft(2, '0');
  return '${at.month}月${at.day}日 $hour:$minute';
}

Future<void> _openModelSettings(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const NotificationModelPage()));
