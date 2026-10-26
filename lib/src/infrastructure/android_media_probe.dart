import 'package:flutter/services.dart';

enum MediaAccess { full, partial, denied }

final class MediaFolder {
  const MediaFolder(this.id, this.name, {this.volume = ''});
  final String id;
  final String name;
  final String volume;
  static MediaFolder fromMap(Map<Object?, Object?> value) => MediaFolder(
    value['id'] as String,
    value['name'] as String,
    volume: value['volume'] as String? ?? '',
  );
}

final class MediaAlbum {
  const MediaAlbum(
    this.name,
    this.count, {
    String? id,
    this.volume = '',
    this.folders = const [],
  }) : id = id ?? name;
  final String id;
  final String name;
  final int count;
  final String volume;
  final List<MediaFolder> folders;
  List<MediaFolder> get hierarchy =>
      folders.isEmpty ? [MediaFolder(id, name, volume: volume)] : folders;
  static MediaAlbum fromMap(Map<Object?, Object?> value) => MediaAlbum(
    value['name'] as String,
    value['count'] as int,
    id: value['id'] as String?,
    volume: value['volume'] as String? ?? '',
    folders: (value['folders'] as List? ?? const [])
        .map((row) => MediaFolder.fromMap(row as Map<Object?, Object?>))
        .toList(),
  );
}

final class MediaImage {
  const MediaImage(
    this.id,
    this.name, {
    this.path,
    this.fileId,
    this.changeToken,
    this.modifiedTime = 0,
  });

  final int id;
  final String name;

  final String? path;
  final String? fileId;
  final String? changeToken;
  final int modifiedTime;

  static MediaImage fromMap(Map<Object?, Object?> value) => MediaImage(
    value['id'] as int,
    value['name'] as String,
    path: value['path'] as String?,
    fileId: value['fileId'] as String?,
    changeToken: value['changeToken'] as String?,
    modifiedTime: value['modifiedTime'] as int? ?? 0,
  );
}

final class MediaAlbumImage {
  const MediaAlbumImage(this.album, this.image);

  final String album;
  final MediaImage image;

  static MediaAlbumImage fromMap(Map<Object?, Object?> value) =>
      MediaAlbumImage(value['album'] as String, MediaImage.fromMap(value));
}

final class MediaExportIssue {
  const MediaExportIssue(this.name, this.reason);

  final String name;
  final String reason;

  static MediaExportIssue fromMap(Map<Object?, Object?> value) =>
      MediaExportIssue(value['name'] as String, value['reason'] as String);
}

final class MediaExportReport {
  const MediaExportReport(this.copied, this.skipped, this.issues);

  final int copied;
  final int skipped;
  final List<MediaExportIssue> issues;

  static MediaExportReport fromMap(Map<Object?, Object?> value) =>
      MediaExportReport(
        value['copied'] as int,
        value['skipped'] as int,
        (value['issues'] as List)
            .map(
              (row) => MediaExportIssue.fromMap(row as Map<Object?, Object?>),
            )
            .toList(growable: false),
      );
}

/// Android MediaStore bridge. The source images are never modified by this API.
final class AndroidMediaProbe {
  const AndroidMediaProbe();

  static const _channel = MethodChannel(
    'image_tag_manager/android_media_probe',
  );

  Future<String?> loadImageSort() =>
      _channel.invokeMethod<String>('loadImageSort');
  Future<void> saveImageSort(String value) =>
      _channel.invokeMethod<void>('saveImageSort', {'value': value});

  Future<MediaAccess> permissionState() async =>
      _parseAccess(await _channel.invokeMethod<String>('permissionState'));

  Future<MediaAccess> requestImages() async =>
      _parseAccess(await _channel.invokeMethod<String>('requestImages'));

  Stream<String> watchChanges() =>
      const EventChannel('image_tag_manager/media_changes')
          .receiveBroadcastStream()
          .map((event) => event as String);

  Future<String?> mediaRevision() =>
      _channel.invokeMethod<String>('mediaRevision');
  Future<void> invalidateMediaCache() =>
      _channel.invokeMethod<void>('invalidateMediaCache');
  Future<List<MediaAlbum>> listAlbums() async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listAlbums',
    );
    return rows?.map(MediaAlbum.fromMap).toList(growable: false) ?? const [];
  }

  Future<List<MediaAlbumImage>> listAllImages() async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listAllImages',
    );
    return rows?.map(MediaAlbumImage.fromMap).toList(growable: false) ??
        const [];
  }

  Future<List<MediaImage>> listImages(String album) async {
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listImages',
      {'album': album},
    );
    return rows?.map(MediaImage.fromMap).toList(growable: false) ?? const [];
  }

  Future<Map<Object?, Object?>> openOriginalImage(int id) async =>
      await _channel.invokeMapMethod<Object?, Object?>('openOriginalImage', {
        'id': id,
      }) ??
      (throw StateError('无法读取原图'));

  Future<void> closeOriginalImage(String token) =>
      _channel.invokeMethod<void>('closeOriginalImage', {'token': token});

  Future<Uint8List> thumbnail(int id) async =>
      await _channel.invokeMethod<Uint8List>('thumbnail', {'id': id}) ??
      (throw StateError('缩略图为空'));

  Future<String> privateConfigDirectory() async =>
      await _channel.invokeMethod<String>('privateConfigDirectory') ??
      (throw StateError('无法取得配置目录'));

  Future<bool> requestExportPermission() async =>
      await _channel.invokeMethod<bool>('requestExportPermission') ?? false;

  Future<MediaExportReport> exportImages(Iterable<int> ids) async {
    final row = await _channel.invokeMapMethod<Object?, Object?>(
      'exportImages',
      {'ids': ids.toList(growable: false)},
    );
    if (row == null) throw StateError('复制结果为空');
    return MediaExportReport.fromMap(row);
  }

  Future<Map<Object?, Object?>> previewExportCleanup() async =>
      await _channel.invokeMapMethod<Object?, Object?>(
        'previewExportCleanup',
      ) ??
      (throw StateError('清理预览为空'));

  Future<Map<Object?, Object?>> deleteExportCopies(
    String token,
    List<int> ids,
  ) async =>
      await _channel.invokeMapMethod<Object?, Object?>('deleteExportCopies', {
        'token': token,
        'ids': ids,
      }) ??
      (throw StateError('清理结果未知，请重新预览'));

  /// Opens Android's document creation UI for a single tag-group JSON file.
  /// Returns false when the user cancels.
  Future<bool> exportConfig(String contents) async =>
      await _channel.invokeMethod<bool>('exportConfig', {
        'contents': contents,
      }) ??
      false;
  static MediaAccess _parseAccess(String? value) => switch (value) {
    'full' => MediaAccess.full,
    'partial' => MediaAccess.partial,
    'denied' => MediaAccess.denied,
    _ => throw FormatException('未知照片授权状态：$value'),
  };
}
