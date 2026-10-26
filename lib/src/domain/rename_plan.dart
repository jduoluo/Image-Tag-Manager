import 'filename_tags.dart';
import 'tag_groups.dart';

/// One image's requested edit. A stem is optional and applies only to this image.
final class RenameEdit {
  RenameEdit({
    this.addRaw = const {},
    this.removeRaw = const {},
    this.addGroups = const {},
    this.removeGroups = const {},
    this.stem,
  });

  final Set<String> addRaw;
  final Set<String> removeRaw;
  final Set<String> addGroups;
  final Set<String> removeGroups;
  final String? stem;

  ParsedFilename apply(ParsedFilename filename, TagGroups groups) {
    var result = filename;
    for (final id in removeGroups) {
      result = groups.removeGroup(result, id);
    }
    for (final raw in removeRaw) {
      result = result.removeRawTag(raw);
    }
    for (final id in addGroups) {
      result = groups.addGroup(result, id);
    }
    for (final raw in addRaw) {
      result = result.addRawTag(raw);
    }
    if (stem != null) result = result.withStem(stem!);
    return result;
  }
}

/// Windows name rules are checked before touching any image.
String? validateWindowsFilename(String name) {
  if (name.isEmpty || name == '.' || name == '..') return '文件名为空或无效';
  if (name.length > 255) return '文件名超过 255 个 UTF-16 字符';
  if (name.endsWith(' ') || name.endsWith('.')) return '文件名不能以空格或句点结尾';
  if (RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(name)) {
    return '包含 Windows 禁止的字符';
  }
  final base = name.split('.').first.toUpperCase();
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(base)) {
    return '使用了 Windows 保留设备名';
  }
  return null;
}

String windowsNameKey(String name) => name.toUpperCase();

final class RenamePlanItem {
  const RenamePlanItem({
    required this.original,
    required this.temporary,
    required this.target,
    required this.fileId,
    required this.reason,
  });

  final String original;
  final String temporary;
  final String target;
  final String fileId;
  final String reason;

  Map<String, Object> toJson() => {
    'original': original,
    'temporary': temporary,
    'target': target,
    'fileId': fileId,
    'reason': reason,
  };

  factory RenamePlanItem.fromJson(Map<String, dynamic> json) => RenamePlanItem(
    original: json['original'] as String,
    temporary: json['temporary'] as String,
    target: json['target'] as String,
    fileId: json['fileId'] as String,
    reason: json['reason'] as String,
  );
}

final class RenamePlan {
  const RenamePlan({
    required this.id,
    required this.directory,
    required this.items,
    required this.unchanged,
    required this.issues,
  });

  final String id;
  final String directory;
  final List<RenamePlanItem> items;
  final List<String> unchanged;
  final List<String> issues;

  bool get canExecute => items.isNotEmpty && issues.isEmpty;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'directory': directory,
    'items': items.map((item) => item.toJson()).toList(),
    'unchanged': unchanged,
  };

  factory RenamePlan.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) throw const FormatException('不支持的事务版本');
    return RenamePlan(
      id: json['id'] as String,
      directory: json['directory'] as String,
      items: (json['items'] as List)
          .map((item) => RenamePlanItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      unchanged: (json['unchanged'] as List).cast<String>(),
      issues: const [],
    );
  }
}
