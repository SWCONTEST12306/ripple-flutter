import 'package:material_ui/material_ui.dart';

import '../itinerary/itinerary.dart';
import 'notification_import.dart';

/// Asks which automatically added events should stay in the itinerary.
///
/// Pops with the ids the user turned off, or with `null` when the review is
/// postponed.
class NotificationReviewDialog extends StatefulWidget {
  const NotificationReviewDialog({super.key, required this.items});

  final List<PendingAddition> items;

  @override
  State<NotificationReviewDialog> createState() =>
      _NotificationReviewDialogState();
}

class _NotificationReviewDialogState extends State<NotificationReviewDialog> {
  late final Set<String> _keep = {for (final item in widget.items) item.id};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.event_available_outlined),
      title: const Text('已自动加入日程'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI 从通知里解析到 ${widget.items.length} 项安排，已经放进日程。'
                '关掉不想保留的安排，完成后会从日程中删除。',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              for (final item in widget.items)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${_dayLabel(item.day)} ${clockTime(item.start)}'
                    '${item.source.isEmpty ? '' : ' · ${item.source}'}',
                  ),
                  value: _keep.contains(item.id),
                  onChanged: (value) => setState(() {
                    if (value) {
                      _keep.add(item.id);
                    } else {
                      _keep.remove(item.id);
                    }
                  }),
                ),
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
          onPressed: () => Navigator.of(context).pop({
            for (final item in widget.items)
              if (!_keep.contains(item.id)) item.id,
          }),
          child: const Text('完成'),
        ),
      ],
    );
  }

  String _dayLabel(DateTime day) => '${day.month}月${day.day}日';
}
