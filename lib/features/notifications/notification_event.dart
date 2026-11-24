import 'dart:convert';

import 'package:crypto/crypto.dart';

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
