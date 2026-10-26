import 'filename_tags.dart';
import 'rename_plan.dart';

/// Explicit short-name generation; never guesses whether an old name is junk.
final class BatchStem {
  BatchStem({required this.prefix, this.start = 1, this.padding = 3}) {
    if (prefix.isEmpty ||
        prefix.trim() != prefix ||
        prefix.contains('[') ||
        prefix.contains(']') ||
        validateWindowsFilename(prefix) != null) {
      throw const FormatException('主体名不能为空、含方括号、首尾空白或文件名禁用字符');
    }
    if (start < 0 || start > 999999999) {
      throw const FormatException('起始序号须为 0 至 999999999 的整数');
    }
    if (padding < 1 || padding > 9) {
      throw const FormatException('序号位数须为 1 至 9（不足补零，超出不截断）');
    }
  }

  final String prefix;
  final int start;
  final int padding;

  String stemAt(int index) {
    if (index < 0 || start + index > 999999999) {
      throw const FormatException('生成序号超出 999999999，请减小起始值');
    }
    return '$prefix${(start + index).toString().padLeft(padding, '0')}';
  }

  /// Stable, case-sensitive original filename order, independent of click order.
  Map<String, RenameEdit> edits(Map<String, String> names, RenameEdit edit) {
    final ids = names.keys.toList()
      ..sort((a, b) {
        final byName = names[a]!.compareTo(names[b]!);
        return byName != 0 ? byName : a.compareTo(b);
      });
    return {
      for (final (index, id) in ids.indexed)
        id: RenameEdit(
          addRaw: edit.addRaw,
          removeRaw: edit.removeRaw,
          addGroups: edit.addGroups,
          removeGroups: edit.removeGroups,
          stem: stemAt(index),
        ),
    };
  }

  String example(ParsedFilename filename, int index) =>
      filename.withStem(stemAt(index)).serialize();
}
