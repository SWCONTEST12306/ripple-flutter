import 'dart:typed_data';

import 'package:flutter/services.dart';

class InstalledApp {
  const InstalledApp(this.packageName, this.label);

  final String packageName;
  final String label;
}

/// Which applications Ripple may read notifications from, plus the application
/// list offered by the settings page.
class NotificationSources {
  const NotificationSources(
    this.master,
    this.apps, {
    this.authorized = false,
  });

  static const _channel = MethodChannel('ripple/notification-sources');

  final bool master;

  /// Package name to application label.
  final Map<String, String> apps;
  final bool authorized;

  static Future<NotificationSources> read() async {
    final data = await _channel.invokeMapMethod<String, Object?>('read');
    final apps = data?['apps'];
    return NotificationSources(
      data?['master'] == true,
      apps is Map ? Map<String, String>.from(apps) : const {},
      authorized: data?['authorized'] == true,
    );
  }

  Future<void> save() =>
      _channel.invokeMethod('save', {'master': master, 'apps': apps});

  static Future<List<InstalledApp>> installedApps() async {
    final data = await _channel.invokeListMethod<Object?>('apps') ?? const [];
    return [
      for (final entry in data)
        if (entry is Map && (entry['packageName'] as String?)?.isNotEmpty == true)
          InstalledApp(
            entry['packageName'] as String,
            entry['label'] as String? ?? '',
          ),
    ];
  }

  static Future<Uint8List?> icon(String packageName) async {
    try {
      return await _channel.invokeMethod<Uint8List>('icon', packageName);
    } catch (_) {
      return null;
    }
  }
}
