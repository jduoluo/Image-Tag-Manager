import 'dart:io';

import 'package:flutter/services.dart';

import '../application/directory_browser.dart';
import '../domain/filename_tags.dart';
import 'android_media_probe.dart';
import 'windows_rename_port.dart';

final class AndroidEntryPreparation {
  static int _counter = 0;
  final String requestId =
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
  bool cancelled = false;
  Future<void> cancel() async {
    cancelled = true;
    try {
      await AndroidRenamePort._channel.invokeMethod<void>('cancelPreparation', {
        'requestId': requestId,
      });
    } on MissingPluginException {
      // Older bridges finish their read; the result is still discarded below.
    } on PlatformException {
      // Local cancellation still discards the result if the engine is shutting down.
    }
  }
}

final class AndroidPreparationCancelled implements Exception {
  const AndroidPreparationCancelled();
}

/// MediaStore compatibility renames verify the exact name and actual file identity.
final class AndroidRenamePort implements RenamePort, RenameDirectoryListing {
  const AndroidRenamePort();
  static const _channel = MethodChannel(
    'image_tag_manager/android_safe_rename',
  );

  static final _progress = <String, void Function(int, int)>{};

  Future<List<ImageEntry>> entries(
    Iterable<int> ids, {
    AndroidEntryPreparation? preparation,
    void Function(int done, int total)? onProgress,
  }) async {
    final requested = ids.toList();
    if (requested.isEmpty) return const [];
    final request = preparation ?? AndroidEntryPreparation();
    if (request.cancelled) throw const AndroidPreparationCancelled();
    if (_progress.isEmpty) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'entryPreparationProgress') {
          final args = call.arguments as Map;
          _progress[args['requestId']]?.call(
            args['done'] as int,
            args['total'] as int,
          );
        }
      });
    }
    _progress[request.requestId] = onProgress ?? (_, _) {};
    try {
      final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'entries',
        {'ids': requested, 'requestId': request.requestId},
      );
      if (request.cancelled) throw const AndroidPreparationCancelled();
      if (rows == null || rows.length != requested.length) {
        throw const RenamePortException('无法取得完整媒体身份');
      }
      final byId = <int, MediaImage>{};
      for (final row in rows) {
        final image = MediaImage.fromMap(row);
        if (byId.containsKey(image.id) ||
            image.path == null ||
            image.fileId == null) {
          throw const RenamePortException('媒体 ID 重复或来源不支持安全打标');
        }
        byId[image.id] = image;
      }
      if (byId.length != requested.toSet().length ||
          !requested.every(byId.containsKey)) {
        throw const RenamePortException('媒体身份与选择项不匹配');
      }
      return [
        for (final id in requested)
          ImageEntry(
            id: byId[id]!.path!,
            filename: byId[id]!.name,
            parsedFilename: parseFilename(byId[id]!.name),
            fileId: byId[id]!.fileId,
          ),
      ];
    } on PlatformException catch (error) {
      if (error.code == 'preparation_cancelled' || request.cancelled) {
        throw const AndroidPreparationCancelled();
      }
      rethrow;
    } finally {
      _progress.remove(request.requestId);
      if (_progress.isEmpty) _channel.setMethodCallHandler(null);
    }
  }

  /// Post-operation UI refresh; transaction inspection has already checked file identities.
  Future<List<MediaImage>> readNames(Iterable<int> ids) async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'entries',
      {'ids': ids.toList(), 'includeIdentity': false},
    );
    if (rows == null) throw const RenamePortException('无法刷新媒体名称');
    return rows.map(MediaImage.fromMap).toList(growable: false);
  }

  @override
  Future<List<String>> directoryNames(String directory) async {
    try {
      return await _channel.invokeListMethod<String>('directoryNames', {
            'directory': directory,
          }) ??
          (throw const RenamePortException('无法核对目录名称'));
    } on MissingPluginException {
      // Compatibility with older native bridges and host fixtures; no relaxed fallback.
      return Directory(directory)
          .list(followLinks: false)
          .map((entry) => entry.path.split(Platform.pathSeparator).last)
          .toList();
    }
  }

  Future<bool> authorize(Iterable<String> paths) async {
    final values = paths.toSet().toList();
    for (var offset = 0; offset < values.length; offset += 2000) {
      final end = (offset + 2000).clamp(0, values.length);
      if (await _channel.invokeMethod<bool>('authorize', {
            'paths': values.sublist(offset, end),
          }) !=
          true) {
        return false;
      }
    }
    return true;
  }

  Future<String> refresh(Iterable<String> paths) async =>
      await _channel.invokeMethod<String>('refresh', {
        'paths': paths.toSet().toList(),
      }) ??
      '媒体库刷新结果未知';

  @override
  Future<String> identity(String path, {bool requireDelete = false}) async {
    try {
      final value = await _channel.invokeMethod<String>('identity', {
        'path': path,
      });
      if (value == null || value.isEmpty) {
        throw const RenamePortException('文件身份不可用');
      }
      return value;
    } on PlatformException catch (error) {
      throw RenamePortException(error.message ?? error.code);
    }
  }

  @override
  Future<void> renameNoReplace(
    String source,
    String target,
    String expectedId,
  ) async {
    try {
      if (await _channel.invokeMethod<bool>('rename', {
            'source': source,
            'target': target,
            'expectedId': expectedId,
          }) !=
          true) {
        throw const RenamePortException('改名结果未知，请核对记录', null, true);
      }
    } on PlatformException catch (error) {
      // Linux errno must never be interpreted as a Windows transient error code.
      throw RenamePortException(
        error.message ?? error.code,
        null,
        error.details is Map &&
            (error.details as Map)['requiresInspection'] == true,
      );
    }
  }
}

/// Normalize only aliases whose already-read native parent identities agree.
/// Never infer Android directory equality by lowercasing path text.
List<ImageEntry> normalizeAndroidRenameSelection(List<ImageEntry> entries) {
  if (entries.isEmpty) return entries;
  String parent(ImageEntry entry) {
    final suffix = '/${entry.filename}';
    if (!entry.id.endsWith(suffix)) {
      // Host fixtures use Windows separators; unchanged one-directory entries are valid.
      final windowsSuffix = '\\${entry.filename}';
      if (!entry.id.endsWith(windowsSuffix)) {
        throw const RenamePortException('媒体路径与文件名不一致，请刷新后重新选择');
      }
    }
    return entry.id.substring(0, entry.id.length - entry.filename.length - 1);
  }

  final parents = entries.map(parent).toSet();
  if (parents.length == 1) return entries;
  String? parentIdentity(ImageEntry entry) {
    final id = entry.fileId;
    if (id == null) return null;
    final separator = id.lastIndexOf('@');
    if (separator <= 0) return null;
    final parts = id.substring(separator + 1).split(':');
    if (parts.length != 7 ||
        int.tryParse(parts[0]) == null ||
        int.tryParse(parts[1]) == null ||
        parts[1] == '0') {
      return null;
    }
    return '${id.substring(0, separator)}@${parts[0]}:${parts[1]}';
  }

  final identities = entries.map(parentIdentity).toSet();
  if (identities.contains(null) || identities.length != 1) {
    throw const RenamePortException(
      '原图改名每次限一个实际目录。所选图片的目录身份不同或无法确认，请清空其他目录选择后再打标。',
    );
  }
  final directory = parents.first;
  return [
    for (final entry in entries)
      ImageEntry(
        id: '$directory/${entry.filename}',
        filename: entry.filename,
        parsedFilename: entry.parsedFilename,
        fileId: entry.fileId,
      ),
  ];
}
