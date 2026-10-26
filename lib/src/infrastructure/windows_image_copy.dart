import 'package:flutter/services.dart';

import '../application/directory_browser.dart';

abstract interface class ImageCopyPort {
  Future<String> identity(String path);
  Future<void> copyNoReplace(String source, String target, String expectedId);
}

final class WindowsImageCopyPort implements ImageCopyPort {
  const WindowsImageCopyPort();

  static const _channel = MethodChannel('image_tag_manager/safe_rename');

  @override
  Future<String> identity(String path) async {
    final id = await _channel.invokeMethod<String>('identity', {
      'source': path,
    });
    if (id == null || id.isEmpty) throw StateError('文件身份不可用');
    return id;
  }

  @override
  Future<void> copyNoReplace(
    String source,
    String target,
    String expectedId,
  ) async {
    await _channel.invokeMethod<String>('copyNoReplace', {
      'source': source,
      'target': target,
      'expectedId': expectedId,
    });
  }
}

final class ImageCopyIssue {
  const ImageCopyIssue(this.filename, this.source, this.reason);
  final String filename;
  final String source;
  final String reason;
}

final class ImageCopyReport {
  const ImageCopyReport(this.copied, this.skipped, this.issues);
  final int copied;
  final int skipped;
  final List<ImageCopyIssue> issues;
}

final class ImageCopyService {
  const ImageCopyService(this.port);
  final ImageCopyPort port;

  Future<ImageCopyReport> copySelected(
    List<ImageEntry> images,
    String destination,
  ) async {
    var copied = 0;
    var skipped = 0;
    final issues = <ImageCopyIssue>[];
    for (final image in images) {
      try {
        final id = image.fileId ?? await port.identity(image.id);
        final target =
            '$destination${destination.endsWith('\\') || destination.endsWith('/') ? '' : '\\'}${image.filename}';
        await port.copyNoReplace(image.id, target, id);
        copied++;
      } on PlatformException catch (error) {
        if (error.message == '80' || error.message == '183') {
          skipped++;
          issues.add(
            ImageCopyIssue(image.filename, image.id, '目标目录已有同名文件，未覆盖'),
          );
        } else {
          issues.add(
            ImageCopyIssue(
              image.filename,
              image.id,
              '复制失败：${error.message ?? error.code}',
            ),
          );
        }
      } catch (error) {
        issues.add(ImageCopyIssue(image.filename, image.id, '复制失败：$error'));
      }
    }
    return ImageCopyReport(copied, skipped, issues);
  }
}
