import 'package:flutter/services.dart';

/// Debug-only single-item experiment, not a safe production rename API.
final class AndroidRenameProbe {
  const AndroidRenameProbe();
  static const album = 'Pictures/ITM-M43-Test/';
  static const _channel = MethodChannel('image_tag_manager/m43_probe');

  Future<({String token, String details})> prepare(
    int id,
    String target,
  ) async {
    final result = await _channel.invokeMapMethod<String, Object?>('prepare', {
      'id': id,
      'target': target,
    });
    if (result == null) throw StateError('验证计划为空');
    return (
      token: result['token'] as String,
      details: result['details'] as String,
    );
  }

  Future<bool> authorize(String token) async =>
      await _channel.invokeMethod<bool>('authorize', {'token': token}) ?? false;
  Future<String> execute(String token) async =>
      await _channel.invokeMethod<String>('execute', {'token': token}) ??
      (throw StateError('验证结果为空，请核对记录'));
  Future<String> inspect() async =>
      await _channel.invokeMethod<String>('inspect') ??
      (throw StateError('无法取得验证记录'));
}
