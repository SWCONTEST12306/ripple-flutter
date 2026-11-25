import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../itinerary/plan_controller.dart';
import 'notification_analysis.dart';
import 'notification_inbox.dart';

/// Stable task id for an extracted event. The notification page and the
/// automatic import share it so an event is only ever added once.
String notificationTaskId(AndroidNotice notice, ExtractedEvent event) {
  final key = jsonEncode([
    notice.key,
    event.kind.name,
    event.title,
    event.date,
    event.time,
    event.reference,
    event.evidence,
  ]);
  return 'notice-${sha256.convert(utf8.encode(key))}';
}

int? eventMinutes(String? time) {
  if (time == null ||
      !RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(time)) {
    return null;
  }
  final parts = time.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

DateTime? eventDate(String? date) {
  if (date == null) return null;
  final day = DateTime.tryParse(date);
  return day != null && planDayKey(day) == date ? planDay(day) : null;
}
