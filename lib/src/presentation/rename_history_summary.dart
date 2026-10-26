import '../domain/filename_tags.dart';
import '../domain/rename_plan.dart';

String renameHistorySummary(RenamePlan plan) {
  if (plan.items.isEmpty) return '无改名项目';
  String? common;
  for (final item in plan.items) {
    final description = _itemChange(item);
    if (common != null && common != description) return '混合修改';
    common = description;
  }
  return common ?? '混合修改';
}

/// Existing reverse plans identify their source in each item's saved reason.
/// Do not infer an undo merely because its file changes happen to be inverse.
String? renameHistoryUndoSourceId(RenamePlan plan) {
  if (plan.items.isEmpty) return null;
  String? sourceId;
  final pattern = RegExp(r'^撤销事务 (itm-[a-zA-Z0-9_-]+)$');
  for (final item in plan.items) {
    final id = pattern.firstMatch(item.reason)?.group(1);
    if (id == null || id == plan.id) return null;
    if (sourceId != null && sourceId != id) return null;
    sourceId = id;
  }
  return sourceId;
}

String renameHistoryDisplaySummary(
  RenamePlan plan,
  Map<String, RenamePlan> completedById,
) {
  final sourceId = renameHistoryUndoSourceId(plan);
  if (sourceId == null) return renameHistorySummary(plan);
  final source = completedById[sourceId];
  if (source == null || source.directory != plan.directory) {
    return '撤销历史操作';
  }
  return '撤销「${renameHistorySummary(source)}」';
}

String _itemChange(RenamePlanItem item) {
  final before = parseFilename(item.original);
  final after = parseFilename(item.target);
  if (before.stem != after.stem || before.extension != after.extension) {
    return _sameTags(before.tags, after.tags) ? '修改主体文件名' : '混合修改';
  }
  final oldCounts = _counts(before.tags);
  final newCounts = _counts(after.tags);
  final added = <String>[];
  final removed = <String>[];
  for (final tag in {...oldCounts.keys, ...newCounts.keys}) {
    final delta = (newCounts[tag] ?? 0) - (oldCounts[tag] ?? 0);
    if (delta > 0) added.add(tag);
    if (delta < 0) removed.add(tag);
  }
  added.sort();
  removed.sort();
  if (added.isNotEmpty && removed.isEmpty) return '新增标签 ${added.join('、')}';
  if (removed.isNotEmpty && added.isEmpty) return '删除标签 ${removed.join('、')}';
  return '混合修改';
}

bool _sameTags(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, int> _counts(List<String> tags) {
  final result = <String, int>{};
  for (final tag in tags) {
    result.update(tag, (count) => count + 1, ifAbsent: () => 1);
  }
  return result;
}

String renameHistoryTime(String id) {
  final match = RegExp(r'^itm-(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\d{6}-')
      .firstMatch(id);
  if (match == null) return '时间未知';
  final utc = DateTime.tryParse(
    '${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}Z',
  );
  if (utc == null) return '时间未知';
  final local = utc.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String renameHistoryDirectoryName(String directory) {
  final parts = directory
      .split(RegExp(r'[\\/]'))
      .where((part) => part.isNotEmpty);
  return parts.isEmpty ? directory : parts.last;
}
