import 'package:flutter/services.dart';

/// 「开发」里的调试开关。开启后原生层在生成请求日志后直接中止，
/// 不发送模型请求，避免调试时消耗 token。
class DebugSettings {
  const DebugSettings._();

  static const _channel = MethodChannel('ripple/debug');

  static Future<bool> readBlockApi() async {
    final data = await _channel.invokeMapMethod<String, Object?>('read');
    return data?['blockApi'] == true;
  }

  static Future<void> saveBlockApi(bool value) =>
      _channel.invokeMethod('save', {'blockApi': value});
}
