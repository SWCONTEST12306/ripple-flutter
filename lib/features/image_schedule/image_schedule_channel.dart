import 'dart:convert';

import 'package:flutter/services.dart';

import '../notifications/notification_analysis.dart';

/// 一次图片识别的结果：OCR 原文 + 模型整理后的日程。
class ImageScheduleAnalysis {
  const ImageScheduleAnalysis({required this.text, required this.analysis});

  final String text;
  final NotificationAnalysis analysis;
}

/// 原生层或模型返回的可读错误。
class ImageScheduleFailure implements Exception {
  const ImageScheduleFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 「ripple/image-schedule」通道：选图、取分享图片、OCR + AI 解析。
class ImageScheduleChannel {
  const ImageScheduleChannel._();

  static const _methods = MethodChannel('ripple/image-schedule');
  static const _shares = EventChannel('ripple/image-schedule/share');

  /// 有新的分享图片时推送事件，Dart 收到后再调用 [consumeShared] 取路径。
  static final shares = _shares.receiveBroadcastStream();

  /// 打开系统图片选择器；用户取消时返回 null。
  static Future<String?> pick() async {
    try {
      return await _methods.invokeMethod<String>('pick');
    } on MissingPluginException {
      throw const ImageScheduleFailure('unavailable', '图片识别只在 Android 版可用。');
    } on PlatformException catch (error) {
      throw ImageScheduleFailure(
        error.code,
        error.message ?? '无法打开图片选择器。',
      );
    }
  }

  /// 取走待处理的分享图片；没有时返回 null。
  static Future<String?> consumeShared() async {
    try {
      return await _methods.invokeMethod<String>('consumeShared');
    } on MissingPluginException {
      throw const ImageScheduleFailure('unavailable', '图片识别只在 Android 版可用。');
    } on PlatformException catch (error) {
      throw ImageScheduleFailure(
        error.code,
        error.message ?? '读取分享图片失败。',
      );
    }
  }

  /// OCR 后交给 AI 整理。模型配置与通知解析共用「ripple/model」。
  static Future<ImageScheduleAnalysis> analyze(String path) async {
    Map<String, Object?>? data;
    try {
      data = await _methods.invokeMapMethod<String, Object?>('analyze', {
        'path': path,
      });
    } on MissingPluginException {
      throw const ImageScheduleFailure('unavailable', '图片识别只在 Android 版可用。');
    } on PlatformException catch (error) {
      throw ImageScheduleFailure(
        error.code,
        error.message ?? '图片识别失败，请重试。',
      );
    }
    if (data == null) {
      throw const ImageScheduleFailure('invalid_response', '模型返回的日程格式有误。');
    }
    try {
      final decoded = jsonDecode(data['analysis']! as String);
      return ImageScheduleAnalysis(
        text: data['text']! as String,
        analysis: NotificationAnalysis.fromJson(
          decoded as Map<String, dynamic>,
        ),
      );
    } catch (_) {
      throw const ImageScheduleFailure('invalid_response', '模型返回的日程格式有误。');
    }
  }
}
