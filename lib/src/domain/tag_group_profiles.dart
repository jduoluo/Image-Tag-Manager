import 'dart:convert';
import 'dart:math';

import 'tag_group_config.dart';
import 'tag_groups.dart';

final class TagGroupProfile {
  const TagGroupProfile({
    required this.id,
    required this.name,
    required this.groups,
  });

  final String id;
  final String name;
  final TagGroups groups;
}

final class TagGroupProfiles {
  TagGroupProfiles({
    required Iterable<TagGroupProfile> profiles,
    required this.activeId,
  }) : profiles = List.unmodifiable(profiles) {
    if (this.profiles.isEmpty ||
        this.profiles.any(
          (profile) => profile.id.isEmpty || profile.name.trim().isEmpty,
        ) ||
        this.profiles.map((profile) => profile.id).toSet().length !=
            this.profiles.length ||
        !this.profiles.any((profile) => profile.id == activeId)) {
      throw ArgumentError('Invalid tag group profiles');
    }
  }

  final List<TagGroupProfile> profiles;
  final String activeId;

  TagGroupProfile get active =>
      profiles.firstWhere((profile) => profile.id == activeId);

  static String newId(Iterable<String> existing) {
    final ids = existing.toSet();
    final random = Random.secure();
    while (true) {
      final id =
          'profile_${random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0')}'
          '${random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0')}';
      if (!ids.contains(id)) return id;
    }
  }

  static TagGroupProfiles initial(TagGroups groups, {String name = '空配置'}) =>
      TagGroupProfiles(
        profiles: [TagGroupProfile(id: 'default', name: name, groups: groups)],
        activeId: 'default',
      );

  static String encode(TagGroupProfiles value) =>
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'activeId': value.activeId,
        'profiles': [
          for (final profile in value.profiles)
            {
              'id': profile.id,
              'name': profile.name,
              'config': jsonDecode(TagGroupConfig.encode(profile.groups)),
            },
        ],
      });

  static TagGroupProfiles decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic> ||
        value['schemaVersion'] != 1 ||
        value['activeId'] is! String ||
        value['profiles'] is! List) {
      throw const FormatException('Invalid tag group profiles');
    }
    final profiles = <TagGroupProfile>[];
    for (final item in value['profiles'] as List) {
      if (item is! Map<String, dynamic> ||
          item['id'] is! String ||
          item['name'] is! String ||
          item['config'] is! Map<String, dynamic>) {
        throw const FormatException('Invalid tag group profile');
      }
      profiles.add(
        TagGroupProfile(
          id: item['id'] as String,
          name: item['name'] as String,
          groups: TagGroupConfig.decode(jsonEncode(item['config'])),
        ),
      );
    }
    try {
      return TagGroupProfiles(
        profiles: profiles,
        activeId: value['activeId'] as String,
      );
    } on ArgumentError {
      throw const FormatException('Invalid tag group profiles');
    }
  }
}
