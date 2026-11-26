import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../notifications/notification_analysis.dart';
import '../notifications/notification_model_page.dart';
import 'image_schedule_channel.dart';
import 'image_schedule_import.dart';
import 'image_schedule_review_dialog.dart';

/// Picks or accepts an image, parses it on device + with the AI model, asks
/// which events to keep and writes the confirmed ones into the itinerary.
///
/// Returns the earliest day that received events, if any, so the caller can
/// switch the timeline to it.
Future<DateTime?> startImageScheduleFlow(
  BuildContext context,
  WidgetRef ref, {
  String? path,
}) async {
  var imagePath = path;
  if (imagePath == null) {
    try {
      imagePath = await ImageScheduleChannel.pick();
    } on ImageScheduleFailure catch (error) {
      if (context.mounted) await _showFailure(context, error);
      return null;
    }
  }
  if (imagePath == null || !context.mounted) return null;

  final result = await _analyze(context, imagePath);
  if (result == null || !context.mounted) return null;

  final events = result.analysis.events;
  if (events.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('没有从图片里识别到日程。')),
    );
    return null;
  }

  final selected = await showDialog<List<ExtractedEvent>>(
    context: context,
    builder: (_) => ImageScheduleReviewDialog(
      summary: result.analysis.summary,
      ocrText: result.text,
      events: events,
    ),
  );
  if (selected == null || selected.isEmpty || !context.mounted) return null;

  try {
    final imported = await ref
        .read(imageScheduleImporterProvider)
        .add(result.text, selected);
    if (!context.mounted) return null;
    final skipped = imported.skipped;
    final message = imported.added == 0
        ? '这些日程已经存在，没有重复加入。'
        : '已加入 ${imported.added} 项日程'
              '${skipped > 0 ? '，跳过 $skipped 项' : ''}。';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    return imported.days.isEmpty ? null : imported.days.first;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('日程保存失败，请重试。')));
    }
    return null;
  }
}

Future<ImageScheduleAnalysis?> _analyze(
  BuildContext context,
  String path,
) async {
  var open = true;
  void close() {
    if (!open) return;
    open = false;
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  // showDialog pushes the route synchronously, so close() can always pop it.
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _AnalyzingDialog(),
    ),
  );
  try {
    final result = await ImageScheduleChannel.analyze(path);
    close();
    return result;
  } on ImageScheduleFailure catch (error) {
    close();
    if (context.mounted) await _showFailure(context, error);
    return null;
  } catch (_) {
    close();
    if (context.mounted) {
      await _showFailure(
        context,
        const ImageScheduleFailure('unknown', '图片识别失败，请重试。'),
      );
    }
    return null;
  }
}

Future<void> _showFailure(
  BuildContext context,
  ImageScheduleFailure error,
) async {
  if (error.code == 'debug_blocked') {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('调试模式已开启'),
        content: const Text(
          '已生成请求日志，但没有发送模型请求。'
          '可在「设置 → 开发 → 日志」里查看提示词和参数。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return;
  }
  if (error.code == 'model_missing' ||
      error.code == 'model_storage_unavailable') {
    final configure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('还没有配置 AI 模型'),
        content: const Text(
          '图片里的文字会发送给 AI 整理成日程。'
          '请先在「设置 · AI 模型设置」里填写模型服务。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (configure == true && context.mounted) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const NotificationModelPage()),
      );
    }
    return;
  }
  if (error.code == 'busy') {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.message)));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('图片识别失败'),
      content: Text(error.message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

class _AnalyzingDialog extends StatelessWidget {
  const _AnalyzingDialog();

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: const AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(width: 20),
          Flexible(child: Text('正在识别图片里的日程…')),
        ],
      ),
    ),
  );
}
