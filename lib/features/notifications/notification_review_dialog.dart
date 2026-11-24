import 'package:material_ui/material_ui.dart';

import '../itinerary/itinerary.dart';
import 'notification_import.dart';

/// Asks what to do with automatically added events and with repeated
/// notifications that disagree with the itinerary.
///
/// Pops with the decision of every item, or with `null` when the review is
/// postponed.
class NotificationReviewDialog extends StatefulWidget {
  const NotificationReviewDialog({super.key, required this.items});

  final List<PendingAddition> items;

  @override
  State<NotificationReviewDialog> createState() =>
      _NotificationReviewDialogState();
}

class _NotificationReviewDialogState extends State<NotificationReviewDialog> {
  late final Map<String, ImportDecision> _decisions = {
    for (final item in widget.items) item.key: ImportDecision.keep,
  };

  List<PendingAddition> get _added => [
    for (final item in widget.items)
      if (item.kind == PendingKind.added) item,
  ];

  List<PendingAddition> get _repeats => [
    for (final item in widget.items)
      if (item.kind == PendingKind.repeat) item,
  ];

  void _decide(PendingAddition item, ImportDecision decision) =>
      setState(() => _decisions[item.key] = decision);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final added = _added;
    final repeats = _repeats;
    return AlertDialog(
      icon: Icon(
        repeats.isEmpty
            ? Icons.event_available_outlined
            : Icons.notification_important_outlined,
      ),
      title: Text(
        repeats.isEmpty
            ? '已自动加入日程'
            : added.isEmpty
            ? '又收到相同的通知'
            : '日程有新变化',
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (added.isNotEmpty)
                Text(
                  'AI 从通知里解析到 ${added.length} 项安排，已经放进日程。'
                  '关掉不想保留的安排，完成后会从日程中删除。',
                  style: theme.textTheme.bodyMedium,
                ),
              if (repeats.isNotEmpty) ...[
                if (added.isNotEmpty) const SizedBox(height: 12),
                Text(
                  '有 ${repeats.length} 条通知和当前日程的时间不一样：'
                  '可能是另一项安排，也可能是时间又改了回去。请选择怎么处理。',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              for (final item in added) _addedTile(item),
              for (final item in repeats) _repeatTile(theme, item),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            Map<String, ImportDecision>.of(_decisions),
          ),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Widget _addedTile(PendingAddition item) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(_details(item)),
    value: _decisions[item.key] == ImportDecision.keep,
    onChanged: (value) => _decide(
      item,
      value ? ImportDecision.keep : ImportDecision.remove,
    ),
  );

  Widget _repeatTile(ThemeData theme, PendingAddition item) {
    final decision = _decisions[item.key] ?? ImportDecision.keep;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '又收到相同通知：${item.title}',
            style: theme.textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text('通知　${_details(item)}', style: theme.textTheme.bodySmall),
          Text(
            '当前日程　${clockTime(item.currentStart ?? item.start)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: const Text('保持现状'),
                selected: decision == ImportDecision.keep,
                onSelected: (_) => _decide(item, ImportDecision.keep),
              ),
              ChoiceChip(
                label: Text('改为 ${clockTime(item.start)}'),
                selected: decision == ImportDecision.updateTime,
                onSelected: (_) => _decide(item, ImportDecision.updateTime),
              ),
              ChoiceChip(
                label: const Text('另加一项'),
                selected: decision == ImportDecision.addCopy,
                onSelected: (_) => _decide(item, ImportDecision.addCopy),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _details(PendingAddition item) =>
      '${_dayLabel(item.day)} ${clockTime(item.start)}'
      '${item.source.isEmpty ? '' : ' · ${item.source}'}';

  String _dayLabel(DateTime day) => '${day.month}月${day.day}日';
}
