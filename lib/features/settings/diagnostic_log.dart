import 'package:flutter/services.dart';

/// 一条本机开发日志。日志由 Android 原生层在调用模型前后写入。
class DiagnosticLogEntry {
  const DiagnosticLogEntry({
    required this.seq,
    required this.at,
    required this.tag,
    required this.title,
    required this.body,
  });

  factory DiagnosticLogEntry.fromMap(Map<Object?, Object?> map) =>
      DiagnosticLogEntry(
        seq: map['seq'] as int? ?? 0,
        at: map['at'] as int? ?? 0,
        tag: map['tag'] as String? ?? '',
        title: map['title'] as String? ?? '',
        body: map['body'] as String? ?? '',
      );

  final int seq;

  /// 写入时间，毫秒时间戳。
  final int at;

  /// 分类，例如「模型请求」「模型返回」。
  final String tag;
  final String title;
  final String body;

  DateTime get localTime => DateTime.fromMillisecondsSinceEpoch(at);
}

class DiagnosticLog {
  const DiagnosticLog._();

  static const _channel = MethodChannel('ripple/diagnostics');

  static Future<List<DiagnosticLogEntry>> read() async {
    final entries = await _channel.invokeListMethod<Object?>('read');
    return [
      for (final entry in entries ?? const [])
        if (entry is Map) DiagnosticLogEntry.fromMap(entry),
    ];
  }

  static Future<void> clear() => _channel.invokeMethod('clear');
}
