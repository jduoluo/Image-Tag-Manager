import 'dart:convert';
import 'dart:io';

import 'android_media_probe.dart';

final class HiddenMediaFolder {
  const HiddenMediaFolder({
    required this.id,
    required this.name,
    this.volume = '',
    this.includeChildren = true,
  });
  final String id;
  final String name;
  final String volume;
  final bool includeChildren;
  bool hides(MediaAlbum album) {
    final candidates = includeChildren
        ? album.hierarchy
        : [album.hierarchy.last];
    return candidates.any(
      (folder) =>
          folder.id == id ||
          (volume.isNotEmpty && folder.volume == volume && folder.name == name),
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'volume': volume,
    'includeChildren': includeChildren,
  };
  static HiddenMediaFolder fromJson(Map<String, dynamic> value) {
    if (value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['name'] is! String ||
        value['volume'] is! String ||
        value['includeChildren'] is! bool) {
      throw const FormatException('隐藏目录规则无效');
    }
    return HiddenMediaFolder(
      id: value['id'] as String,
      name: value['name'] as String,
      volume: value['volume'] as String,
      includeChildren: value['includeChildren'] as bool,
    );
  }
}

abstract interface class MediaVisibilityStore {
  Future<List<HiddenMediaFolder>> load();
  Future<void> save(List<HiddenMediaFolder> rules);
}

final class MemoryMediaVisibilityStore implements MediaVisibilityStore {
  List<HiddenMediaFolder> _rules = const [];
  @override
  Future<List<HiddenMediaFolder>> load() async => List.of(_rules);
  @override
  Future<void> save(List<HiddenMediaFolder> rules) async {
    _rules = List.of(rules);
  }
}

final class LocalMediaVisibilityStore implements MediaVisibilityStore {
  const LocalMediaVisibilityStore(this.file);
  final File file;
  @override
  Future<List<HiddenMediaFolder>> load() async {
    final source = await file.exists() ? file : File('${file.path}.previous');
    if (!await source.exists()) return const [];
    final data =
        jsonDecode(await source.readAsString()) as Map<String, dynamic>;
    if (data['schemaVersion'] != 1 || data['hidden'] is! List) {
      throw const FormatException('隐藏目录设置版本或格式不支持');
    }
    return (data['hidden'] as List)
        .map((row) => HiddenMediaFolder.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> save(List<HiddenMediaFolder> rules) async {
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.pending');
    final backup = File('${file.path}.previous');
    await pending.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'hidden': rules.map((rule) => rule.toJson()).toList(),
      }),
      flush: true,
    );
    // Settings only: keep the previous file until the new file is in place.
    if (await file.exists()) {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    }
    try {
      await pending.rename(file.path);
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }
}
