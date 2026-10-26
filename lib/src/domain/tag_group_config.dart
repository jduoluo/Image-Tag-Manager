import 'dart:convert';

import 'tag_groups.dart';

/// Versioned, platform-independent tag group interchange format.
final class TagGroupConfig {
  const TagGroupConfig._();

  static const schemaVersion = 2;

  static bool isVersion1(String source) {
    final value = jsonDecode(source);
    return value is Map<String, dynamic> && value['schemaVersion'] == 1;
  }

  static String encode(TagGroups groups) =>
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': schemaVersion,
        'groups': [
          for (final group in groups.all)
            {
              'id': group.id,
              'displayName': group.displayName,
              'writeTag': group.writeTag,
              'aliases': group.aliases.toList(),
            },
        ],
        'categories': [
          for (final category in groups.categories)
            {
              'id': category.id,
              'displayName': category.displayName,
              'defaultGroupId': category.defaultGroupId,
              'memberGroupIds': category.memberGroupIds,
            },
        ],
      });

  static TagGroups decode(String source) {
    final Object? value = jsonDecode(source);
    if (value is! Map<String, dynamic> ||
        (value['schemaVersion'] != 1 &&
            value['schemaVersion'] != schemaVersion) ||
        value['groups'] is! List) {
      throw const FormatException('Unsupported or invalid tag group config');
    }
    final groups = <TagGroup>[];
    for (final item in value['groups'] as List) {
      if (item is! Map<String, dynamic> ||
          item['id'] is! String ||
          item['displayName'] is! String ||
          item['writeTag'] is! String ||
          item['aliases'] is! List ||
          (item['aliases'] as List).any((alias) => alias is! String)) {
        throw const FormatException('Invalid tag group entry');
      }
      groups.add(
        TagGroup(
          id: item['id'] as String,
          displayName: item['displayName'] as String,
          writeTag: item['writeTag'] as String,
          aliases: (item['aliases'] as List).cast<String>(),
        ),
      );
    }
    final categories = <TagCategory>[];
    if (value['schemaVersion'] == schemaVersion) {
      if (value['categories'] is! List) {
        throw const FormatException('Invalid category list');
      }
      for (final item in value['categories'] as List) {
        if (item is! Map<String, dynamic> ||
            item['id'] is! String ||
            item['displayName'] is! String ||
            (item['defaultGroupId'] != null &&
                item['defaultGroupId'] is! String) ||
            item['memberGroupIds'] is! List ||
            (item['memberGroupIds'] as List).any((id) => id is! String)) {
          throw const FormatException('Invalid category entry');
        }
        categories.add(
          TagCategory(
            id: item['id'] as String,
            displayName: item['displayName'] as String,
            defaultGroupId: item['defaultGroupId'] as String?,
            memberGroupIds: (item['memberGroupIds'] as List).cast<String>(),
          ),
        );
      }
    }
    return TagGroups(groups, categories: categories);
  }
}
