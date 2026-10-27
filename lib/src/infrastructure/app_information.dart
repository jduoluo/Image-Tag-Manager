import 'package:flutter/services.dart';

/// Only these two project addresses may be opened by the native bridge.
final class AppInformation {
  static const repository = 'https://github.com/jduoluo/Image-Tag-Manager';
  static const issues = '$repository/issues';
  static const _channel = MethodChannel('image_tag_manager/app_information');

  static Future<String> version() async {
    final value = await _channel.invokeMethod<String>('version');
    if (value == null || value.trim().isEmpty) {
      throw const FormatException('无法读取应用版本');
    }
    return value.split('+').first;
  }

  static Future<void> openUrl(String url) async {
    if (url != repository && url != issues) {
      throw ArgumentError.value(url, 'url', '仅允许项目和反馈地址');
    }
    await _channel.invokeMethod<void>('openUrl', url);
  }
}
