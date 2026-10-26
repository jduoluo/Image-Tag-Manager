import 'dart:io';

import '../application/directory_browser.dart';
import '../domain/filename_tags.dart';
import 'windows_rename_port.dart';

/// Windows 普通文件夹的只读元数据扫描，不进入子目录或目录联接。
final class LocalImageDirectorySource implements ImageDirectorySource {
  const LocalImageDirectorySource({this.identityPort});

  final RenamePort? identityPort;

  static const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

  @override
  Stream<String> listSubdirectories(String path) async* {
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw FileSystemException('目录不存在或不可访问', path);
    }
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Directory) yield entity.path;
    }
  }

  @override
  Stream<ImageEntry> scanCurrentDirectory(String path) async* {
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw FileSystemException('目录不存在或不可访问', path);
    }

    await for (final entity in directory.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final filename = entity.uri.pathSegments.last;
      final dot = filename.lastIndexOf('.');
      if (dot < 0 ||
          !imageExtensions.contains(filename.substring(dot).toLowerCase())) {
        continue;
      }
      String? fileId;
      if (identityPort != null) {
        try {
          fileId = await identityPort!.identity(entity.path);
        } catch (_) {
          // Browsing remains available; preview refuses writes without identity.
        }
      }
      yield ImageEntry(
        id: entity.path,
        filename: filename,
        parsedFilename: parseFilename(filename),
        fileId: fileId,
      );
    }
  }
}
