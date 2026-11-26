import 'package:material_ui/material_ui.dart';

import '../itinerary/day_picker.dart';
import '../itinerary/itinerary.dart';
import '../itinerary/plan_controller.dart';
import '../notifications/notification_analysis.dart';
import '../notifications/notification_event.dart';

/// Shows what the image parsing found and lets the user uncheck events that
/// should not be added. Pops with the selected events, or null on cancel.
///
/// Events without a concrete start time cannot be added here; the user can
/// still create them manually from the plus menu.
class ImageScheduleReviewDialog extends StatefulWidget {
  const ImageScheduleReviewDialog({
    super.key,
    required this.summary,
    required this.ocrText,
    required this.events,
  });

  final String summary;
  final String ocrText;
  final List<ExtractedEvent> events;

  @override
  State<ImageScheduleReviewDialog> createState() =>
      _ImageScheduleReviewDialogState();
}

class _ImageScheduleReviewDialogState extends State<ImageScheduleReviewDialog> {
  late final List<bool> _selected = [
    for (final event in widget.events) eventMinutes(event.time) != null,
  ];

  int get _count => _selected.where((selected) => selected).length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.image_search),
      title: Text('识别到 ${widget.events.length} 项日程'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.summary, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(
                '勾选要加入的日程。加入后仍可在时间轴上修改；'
                '没有识别到具体时间的安排需要手动添加。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < widget.events.length; index++)
                _eventTile(theme, index, widget.events[index]),
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: Text('查看识别到的文字', style: theme.textTheme.bodyMedium),
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        widget.ocrText,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _count == 0
              ? null
              : () => Navigator.of(context).pop([
                  for (var index = 0; index < widget.events.length; index++)
                    if (_selected[index]) widget.events[index],
                ]),
          child: Text(_count == 0 ? '加入日程' : '加入日程（$_count）'),
        ),
      ],
    );
  }

  Widget _eventTile(ThemeData theme, int index, ExtractedEvent event) {
    final start = eventMinutes(event.time);
    final day = eventDate(event.date) ?? planDay(DateTime.now());
    final details = <String>[
      if (start == null)
        '未识别到具体时间'
      else
        '${planDayLabel(day)} ${clockTime(start)}',
      if (event.location?.isNotEmpty == true) event.location!,
      if (event.durationMinutes != null) '${event.durationMinutes} 分钟',
      if (event.people.isNotEmpty) '参与：${event.people.join('、')}',
      if (event.tentative) '时间待定',
    ];
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(event.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        details.join(' · '),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      value: start != null && _selected[index],
      onChanged: start == null
          ? null
          : (value) => setState(() => _selected[index] = value == true),
    );
  }
}
