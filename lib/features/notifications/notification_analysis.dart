class NotificationAnalysis {
  NotificationAnalysis.fromJson(Map<String, dynamic> json)
    : summary = json['summary'] as String,
      events = [
        for (final event in json['events'] as List)
          ExtractedEvent.fromJson(event as Map<String, dynamic>),
      ];

  final String summary;
  final List<ExtractedEvent> events;
}

enum EventKind {
  newEvent('新增安排'),
  changed('行程变更'),
  delayed('迟到或延误'),
  cancelled('行程取消');

  const EventKind(this.label);
  final String label;
}

class ExtractedEvent {
  ExtractedEvent.fromJson(Map<String, dynamic> json)
    : kind = json['kind'] == 'new'
          ? EventKind.newEvent
          : EventKind.values.byName(json['kind'] as String),
      title = json['title'] as String,
      date = json['date'] as String?,
      time = json['time'] as String?,
      originalDate = json['original_date'] as String?,
      originalTime = json['original_time'] as String?,
      delayMinutes = json['delay_minutes'] as int?,
      durationMinutes = json['duration_minutes'] as int?,
      location = json['location'] as String?,
      originalLocation = json['original_location'] as String?,
      people =
          (json['people'] as List?)?.whereType<String>().toList() ?? const [],
      activity = json['activity'] as String?,
      tentative = json['tentative'] == true,
      reference = json['reference'] as String?,
      evidence = json['evidence'] as String;

  final EventKind kind;
  final String title;
  final String? date;
  final String? time;
  final String? originalDate;
  final String? originalTime;
  final int? delayMinutes;
  final int? durationMinutes;
  final String? location;
  final String? originalLocation;
  final List<String> people;
  final String? activity;
  final bool tentative;
  final String? reference;
  final String evidence;
}
