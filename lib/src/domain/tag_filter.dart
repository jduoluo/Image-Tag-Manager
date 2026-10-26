import 'filename_tags.dart';
import 'tag_groups.dart';

/// 结构化筛选条件：三组条件整体取 AND；空条件命中全部图片。
final class TagFilter {
  TagFilter({
    Iterable<String> allOf = const [],
    Iterable<String> anyOf = const [],
    Iterable<String> noneOf = const [],
    this.onlyUntagged = false,
  }) : allOf = Set.unmodifiable(allOf),
       anyOf = Set.unmodifiable(anyOf),
       noneOf = Set.unmodifiable(noneOf) {
    if (onlyUntagged &&
        (this.allOf.isNotEmpty ||
            this.anyOf.isNotEmpty ||
            this.noneOf.isNotEmpty)) {
      throw ArgumentError('无标签快捷筛选不能与标签条件并用');
    }
  }

  final Set<String> allOf;
  final Set<String> anyOf;
  final Set<String> noneOf;
  final bool onlyUntagged;

  /// allOf 全满足、anyOf 非空时至少满足一项、noneOf 全不满足。
  bool matches(ParsedFilename filename, TagGroups groups) {
    if (onlyUntagged) return filename.tags.isEmpty;
    final present = groups.identities(filename.tags);
    return present.containsAll(allOf) &&
        (anyOf.isEmpty || anyOf.any(present.contains)) &&
        !noneOf.any(present.contains);
  }
}
