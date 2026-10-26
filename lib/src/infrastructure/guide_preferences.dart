import 'dart:io';

import 'android_media_probe.dart';

abstract interface class GuidePreferences {
  Future<bool> loadSuppressed();
  Future<void> saveSuppressed(bool value);
}

/// Separate from tag configuration exports and transaction history.
final class LocalGuidePreferences implements GuidePreferences {
  LocalGuidePreferences({Future<File> Function()? resolveFile})
    : _resolveFile = resolveFile ?? _defaultFile;
  final Future<File> Function() _resolveFile;

  static Future<File> _defaultFile() async {
    final folder = Platform.isAndroid
        ? await const AndroidMediaProbe().privateConfigDirectory()
        : '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}config';
    return File('$folder${Platform.pathSeparator}guide_startup.txt');
  }

  @override
  Future<bool> loadSuppressed() async {
    final file = await _resolveFile();
    if (!await file.exists()) return false;
    final value = (await file.readAsString()).trim();
    if (value != 'show' && value != 'hide') {
      throw const FormatException('启动指南设置格式无效');
    }
    return value == 'hide';
  }

  @override
  Future<void> saveSuppressed(bool value) async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(value ? 'hide\n' : 'show\n', flush: true);
  }
}
