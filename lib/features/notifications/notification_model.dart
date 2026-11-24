import 'package:flutter/services.dart';

class NotificationModel {
  const NotificationModel(this.baseUrl, this.model, {this.sources = const {}});

  static const defaultUrl = 'https://api.deepseek.com';
  static const defaultModel = 'deepseek-flash';
  static const _channel = MethodChannel('ripple/model');

  final Uri baseUrl;
  final String model;
  final Map<String, String> sources;

  static Uri? parseUrl(String value) {
    final text = value.trim();
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(text)) {
      return null;
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(path: path);
  }

  static Future<NotificationModel?> read() async {
    final saved = await _channel.invokeMapMethod<String, Object?>('read');
    if (saved == null) return null;
    final url = parseUrl(saved['url'] as String);
    if (url == null) throw const FormatException('请重新填写模型服务地址。');
    return NotificationModel(
      url,
      saved['model'] as String,
      sources: Map<String, String>.from(saved['sources'] as Map? ?? const {}),
    );
  }

  Future<void> save(String? credential) => _channel.invokeMethod('save', {
    'url': baseUrl.toString(),
    'model': model,
    'sources': sources,
    'credential': ?credential,
  });

  static Future<void> remove() => _channel.invokeMethod('remove');
}
