import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../itinerary/itinerary.dart';
import '../itinerary/plan_controller.dart';
import '../notifications/notification_analysis.dart';
import '../notifications/notification_event.dart';

/// Stable task id for an event extracted from an image. The hash includes the
/// OCR text, so importing the same screenshot twice does not duplicate tasks.
String imageTaskId(String imageKey, ExtractedEvent event) {
  final key = jsonEncode([
    imageKey,
    event.title,
    event.date,
    event.time,
    event.durationMinutes,
    event.location,
  ]);
  return 'image-${sha256.convert(utf8.encode(key))}';
}

class ImageImportResult {
  const ImageImportResult({
    required this.added,
    required this.skipped,
    required this.days,
  });

  final int added;

  /// Events that already existed or had no usable start time.
  final int skipped;

  /// Days that received at least one task, oldest first.
  final List<DateTime> days;
}

/// Writes confirmed image events into their days through [PlanWrites], the same
/// serialization used by the editor, notification import and replanning.
class ImageScheduleImporter {
  ImageScheduleImporter({
    required this.repository,
    required this.writes,
    required this.onChanged,
  });

  final PlanRepository repository;
  final PlanWrites writes;
  final void Function(DateTime day) onChanged;

  Future<ImageImportResult> add(
    String imageText,
    List<ExtractedEvent> events,
  ) => writes.run(() async {
    final imageKey = sha256.convert(utf8.encode(imageText)).toString();
    final days = <DateTime>{};
    var added = 0;
    var skipped = 0;
    for (final event in events) {
      final start = eventMinutes(event.time);
      if (start == null) {
        skipped++;
        continue;
      }
      final day = eventDate(event.date) ?? planDay(DateTime.now());
      final id = imageTaskId(imageKey, event);
      final plan = await repository.load(day);
      if (plan.tasks.any((task) => task.id == id)) {
        skipped++;
        continue;
      }
      final task = ItineraryTask(
        id: id,
        title: event.title,
        start: start,
        duration: event.durationMinutes ?? 0,
        location: event.location ?? '',
        timing: Timing.flexible,
        people: event.people,
      );
      await repository.save(
        day,
        plan.withTasks([...plan.tasks, task], appliedTitle: plan.appliedTitle),
      );
      onChanged(day);
      added++;
      days.add(day);
    }
    final ordered = days.toList()..sort((a, b) => a.compareTo(b));
    return ImageImportResult(added: added, skipped: skipped, days: ordered);
  });
}

final imageScheduleImporterProvider = Provider<ImageScheduleImporter>(
  (ref) => ImageScheduleImporter(
    repository: ref.watch(planRepositoryProvider),
    writes: ref.watch(planWritesProvider),
    onChanged: (day) => ref.invalidate(itineraryProvider(day)),
  ),
);
