import 'package:flutter/services.dart';

abstract interface class RenamePort {
  Future<String> identity(String path, {bool requireDelete = false});

  /// Windows guarantees native no-replace. Android MediaStore compatibility
  /// checks occupancy and results but cannot promise atomic no-replace.
  Future<void> renameNoReplace(String source, String target, String expectedId);
}

/// Optional platform namespace view; Windows keeps direct directory enumeration.
abstract interface class RenameDirectoryListing {
  Future<List<String>> directoryNames(String directory);
}

final class RenamePortException implements Exception {
  const RenamePortException(
    this.message, [
    this.win32Code,
    this.requiresInspection = false,
  ]);

  final String message;
  final int? win32Code;
  final bool requiresInspection;

  bool get isTransient => win32Code == 32 || win32Code == 33;

  @override
  String toString() =>
      win32Code == null ? message : '$message (Windows $win32Code)';
}

/// Windows runner checks file ID on the opened handle and refuses replacement.
final class WindowsRenamePort implements RenamePort {
  const WindowsRenamePort();

  static const _channel = MethodChannel('image_tag_manager/safe_rename');

  @override
  Future<String> identity(String path, {bool requireDelete = false}) async {
    try {
      final id = await _channel.invokeMethod<String>('identity', {
        'source': path,
        'requireDelete': requireDelete,
      });
      if (id == null || id.isEmpty) throw const RenamePortException('文件身份不可用');
      return id;
    } on PlatformException catch (error) {
      throw RenamePortException(
        error.message ?? error.code,
        int.tryParse(error.message ?? ''),
      );
    }
  }

  @override
  Future<void> renameNoReplace(
    String source,
    String target,
    String expectedId,
  ) async {
    try {
      await _channel.invokeMethod<String>('rename', {
        'source': source,
        'target': target,
        'expectedId': expectedId,
      });
    } on PlatformException catch (error) {
      throw RenamePortException(
        error.message ?? error.code,
        int.tryParse(error.message ?? ''),
      );
    }
  }
}
