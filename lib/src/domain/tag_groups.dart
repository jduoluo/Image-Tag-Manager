import 'filename_tags.dart';

/// 一个显示概念及其精确匹配的历史别名；写入值必须属于别名集合。
final class TagGroup {
  TagGroup({
    required this.id,
    required this.displayName,
    required this.writeTag,
    required Iterable<String> aliases,
  }) : aliases = Set.unmodifiable(aliases) {
    if (id.isEmpty ||
        displayName.isEmpty ||
        !isValidTag(writeTag) ||
        !this.aliases.contains(writeTag) ||
        this.aliases.any((alias) => !isValidTag(alias))) {
      throw ArgumentError('Invalid tag group');
    }
  }

  final String id;
  final String displayName;
  final String writeTag;
  final Set<String> aliases;
}

/// A display-only collection of tag groups. It never writes a tag itself.
final class TagCategory {
  TagCategory({
    required this.id,
    required this.displayName,
    required this.defaultGroupId,
    required Iterable<String> memberGroupIds,
  }) : memberGroupIds = List.unmodifiable(memberGroupIds) {
    if (id.isEmpty ||
        displayName.isEmpty ||
        this.memberGroupIds.toSet().length != this.memberGroupIds.length ||
        (defaultGroupId != null &&
            (this.memberGroupIds.isEmpty ||
                this.memberGroupIds.first != defaultGroupId))) {
      throw ArgumentError('Invalid tag category');
    }
  }

  final String id;
  final String displayName;
  final String? defaultGroupId;
  final List<String> memberGroupIds;
}

/// 标签组索引。重复组 ID 或跨组别名冲突会被拒绝。
final class TagGroups {
  TagGroups(
    Iterable<TagGroup> groups, {
    Iterable<TagCategory> categories = const [],
  }) {
    for (final group in groups) {
      if (_byId.containsKey(group.id)) {
        throw ArgumentError('Duplicate group id');
      }
      _byId[group.id] = group;
      for (final alias in group.aliases) {
        if (_byAlias.containsKey(alias)) {
          final owner = _byAlias[alias]!;
          throw ArgumentError(
            '别名“$alias”已属于标签名组“${owner.displayName}”（${owner.id}）',
          );
        }
        _byAlias[alias] = group;
      }
    }
    for (final category in categories) {
      if (_categories.any((item) => item.id == category.id) ||
          category.memberGroupIds.any((id) => !_byId.containsKey(id))) {
        throw ArgumentError('Invalid category membership or duplicate id');
      }
      _categories.add(category);
    }
  }

  final Map<String, TagGroup> _byId = {};
  final Map<String, TagGroup> _byAlias = {};
  final List<TagCategory> _categories = [];

  List<TagGroup> get all => List.unmodifiable(_byId.values);
  List<TagCategory> get categories => List.unmodifiable(_categories);

  TagGroup? findAlias(String alias) => _byAlias[alias];

  TagGroup group(String id) =>
      _byId[id] ?? (throw ArgumentError.value(id, 'id'));

  /// 已知别名变成组身份；未知标签保留为区分大小写的原始身份。
  String identity(String rawTag) {
    final group = _byAlias[rawTag];
    return group == null ? 'raw:$rawTag' : 'group:${group.id}';
  }

  /// 同组多个别名在筛选时只产生一个身份，不修改文件名。
  Set<String> identities(Iterable<String> rawTags) =>
      rawTags.map(identity).toSet();

  /// 文件已有该组任一别名时无变化，否则追加默认写入标签。
  ParsedFilename addGroup(ParsedFilename filename, String id) {
    final selected = group(id);
    if (filename.tags.any(selected.aliases.contains)) return filename;
    return filename.addRawTag(selected.writeTag);
  }

  /// 删除该组全部别名，保留未知标签和其他组的原始写法。
  ParsedFilename removeGroup(ParsedFilename filename, String id) {
    final selected = group(id);
    return ParsedFilename(
      filename.tags.where((tag) => !selected.aliases.contains(tag)).toList(),
      filename.stem,
      filename.extension,
    );
  }
}
