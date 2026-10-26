import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/domain/tag_group_config.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';

void main() {
  test('round trips versioned groups and aliases', () {
    final original = TagGroups([
      TagGroup(
        id: 'arknights',
        displayName: '明日方舟',
        writeTag: 'mrfz',
        aliases: ['mrfz', '方舟'],
      ),
    ]);
    final decoded = TagGroupConfig.decode(TagGroupConfig.encode(original));
    expect(decoded.all.single.displayName, '明日方舟');
    expect(decoded.all.single.writeTag, 'mrfz');
    expect(decoded.identity('方舟'), 'group:arknights');
  });

  test('rejects unknown schema and conflicting aliases', () {
    expect(
      () => TagGroupConfig.decode('{"schemaVersion":2,"groups":[]}'),
      throwsFormatException,
    );
    expect(
      () => TagGroupConfig.decode('''{"schemaVersion":1,"groups":[
        {"id":"a","displayName":"A","writeTag":"x","aliases":["x"]},
        {"id":"b","displayName":"B","writeTag":"x","aliases":["x"]}
      ]}'''),
      throwsArgumentError,
    );
  });

  test('version 1 keeps tag groups and gains no categories', () {
    final decoded = TagGroupConfig.decode('''{
      "schemaVersion":1,
      "groups":[{"id":"a","displayName":"A","writeTag":"a","aliases":["a"]}]
    }''');
    expect(decoded.all.single.id, 'a');
    expect(decoded.categories, isEmpty);
    expect(
      TagGroupConfig.decode(TagGroupConfig.encode(decoded)).all.single.id,
      'a',
    );
  });

  test(
    'category references may overlap but must exist and put default first',
    () {
      final groups = [
        TagGroup(id: 'a', displayName: 'A', writeTag: 'a', aliases: ['a']),
        TagGroup(id: 'b', displayName: 'B', writeTag: 'b', aliases: ['b']),
      ];
      final collection = TagGroups(
        groups,
        categories: [
          TagCategory(
            id: 'one',
            displayName: 'One',
            defaultGroupId: 'a',
            memberGroupIds: ['a', 'b'],
          ),
          TagCategory(
            id: 'two',
            displayName: 'Two',
            defaultGroupId: 'b',
            memberGroupIds: ['b'],
          ),
        ],
      );
      expect(
        TagGroupConfig.decode(TagGroupConfig.encode(collection))
            .categories
            .length,
        2,
      );
      expect(
        () => TagGroups(
          groups,
          categories: [
            TagCategory(
              id: 'bad',
              displayName: 'Bad',
              defaultGroupId: null,
              memberGroupIds: ['missing'],
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => TagCategory(
          id: 'bad',
          displayName: 'Bad',
          defaultGroupId: 'b',
          memberGroupIds: ['a', 'b'],
        ),
        throwsArgumentError,
      );
    },
  );
}
