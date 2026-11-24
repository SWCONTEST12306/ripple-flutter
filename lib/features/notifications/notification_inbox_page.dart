import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../itinerary/plan_controller.dart';
import '../itinerary/task_editor.dart';
import 'notification_analysis.dart';
import 'notification_inbox.dart';
import 'notification_model_page.dart';

class NotificationInboxPage extends StatefulWidget {
  const NotificationInboxPage({super.key, required this.onViewPlan});

  final ValueChanged<DateTime> onViewPlan;

  @override
  State<NotificationInboxPage> createState() => _NotificationInboxPageState();
}

class _NotificationInboxPageState extends State<NotificationInboxPage> {
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

  Future<void> _refresh() async {
    final version = ++_refreshVersion;
    try {
      final inbox = await NotificationInbox.read();
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
    final entries = inbox.entries;
    return RefreshIndicator(
      onRefresh: _refresh,
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
      final time = event.time?.split(':');
      final start = time == null
          ? null
          : int.parse(time[0]) * 60 + int.parse(time[1]);
      final saved = await Navigator.of(context).push<DateTime>(
        MaterialPageRoute(
          builder: (_) => TaskEditor(
            day: day,
            draft: TaskDraft(
              id: id,
              title: event.title,
              location: event.location,
              start: start,
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
                  action: event.kind == EventKind.cancelled
                      ? null
                      : _scheduleAction(notice, event),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _scheduleAction(AndroidNotice notice, ExtractedEvent event) {
    final key = jsonEncode([
      notice.key,
      event.kind.name,
      event.title,
      event.date,
      event.time,
      event.reference,
      event.evidence,
    ]);
    final id = 'notice-${sha256.convert(utf8.encode(key))}';
    final day = _added[id] ?? DateTime.tryParse(event.date ?? '');
    return Consumer(
      builder: (context, ref, _) {
        final added =
            day != null &&
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
            if (event.durationMinutes case final minutes?)
              Text('时长　$minutes 分钟'),
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
