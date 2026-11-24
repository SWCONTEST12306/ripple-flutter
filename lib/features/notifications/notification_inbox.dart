import 'dart:convert';

import 'package:flutter/services.dart';

import 'notification_analysis.dart';

class AndroidNotice {
  AndroidNotice.fromMap(Map<Object?, Object?> map)
    : key = map['key'] as String,
      packageName = map['packageName'] as String? ?? '',
      source = map['source'] as String,
      title = map['title'] as String,
      text = map['text'] as String,
      postedAt = map['postedAt'] as int,
      utcOffsetMinutes = map['utcOffsetMinutes'] as int,
      automatic = map['automatic'] == true,
      retrying = map['retrying'] == true,
      error = map['error'] as String? ?? '',
      analysis = _parseAnalysis(map['analysis'] as String?);

  final String key;
  final String packageName;
  final String source;
  final String title;
  final String text;
  final int postedAt;
  final int utcOffsetMinutes;
  final bool automatic;
  final bool retrying;
  final String error;
  final NotificationAnalysis? analysis;

  String get displayTitle => title.isEmpty ? text : title;

  DateTime get localPostedAt => DateTime.fromMillisecondsSinceEpoch(
    postedAt + utcOffsetMinutes * Duration.millisecondsPerMinute,
    isUtc: true,
  );

  static NotificationAnalysis? _parseAnalysis(String? data) {
    if (data == null || data.isEmpty) return null;
    try {
      return NotificationAnalysis.fromJson(
        jsonDecode(data) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
}

class NotificationInbox {
  const NotificationInbox(this.authorized, this.entries);

  final bool authorized;
  final List<AndroidNotice> entries;

  static const _methods = MethodChannel('ripple/notifications');
  static const _updates = EventChannel('ripple/notifications/changes');

  static final changes = _updates.receiveBroadcastStream();

  static Future<NotificationInbox> read() async {
    final data = await _methods.invokeMapMethod<Object?, Object?>('inbox');
    return NotificationInbox(data!['authorized'] as bool, [
      for (final entry in data['entries'] as List)
        AndroidNotice.fromMap(entry as Map<Object?, Object?>),
    ]);
  }

  static Future<void> openSettings() => _methods.invokeMethod('openSettings');
}
