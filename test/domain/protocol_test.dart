import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/domain/filename_tags.dart';
import 'package:image_tag_manager/src/domain/tag_filter.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';

void main() {
  group('filename protocol', () {
    const cases = <String, List<Object>>{
      'image.jpg': [<String>[], 'image', '.jpg'],
      '[mrfz]image.jpg': [
        <String>['mrfz'],
        'image',
        '.jpg',
      ],
      '[mrfz][nts][bqb]20260904_001.jpg': [
        <String>['mrfz', 'nts', 'bqb'],
        '20260904_001',
        '.jpg',
      ],
      '[方舟]图片.JPG': [
        <String>['方舟'],
        '图片',
        '.JPG',
      ],
      '[x]name.part.01.png': [
        <String>['x'],
        'name.part.01',
        '.png',
      ],
      'name[tag].jpg': [<String>[], 'name[tag]', '.jpg'],
      '[x]name[tag].jpg': [
        <String>['x'],
        'name[tag]',
        '.jpg',
      ],
      '[]name.jpg': [<String>[], '[]name', '.jpg'],
      '[x][]name.jpg': [
        <String>['x'],
        '[]name',
        '.jpg',
      ],
      '[broken-name.jpg': [<String>[], '[broken-name', '.jpg'],
      '.hidden': [<String>[], '.hidden', ''],
      '.hidden.config': [<String>[], '.hidden', '.config'],
      '[x]README': [
        <String>['x'],
        'README',
        '',
      ],
      '[x]file.': [
        <String>['x'],
        'file.',
        '',
      ],
      '[a][a] file [x].webp': [
        <String>['a', 'a'],
        ' file [x]',
        '.webp',
      ],
      '[x]': [
        <String>['x'],
        '',
        '',
      ],
      '[x].hidden': [
        <String>['x'],
        '.hidden',
        '',
      ],
      '[A][a][A]name.GIF': [
        <String>['A', 'a', 'A'],
        'name',
        '.GIF',
      ],
      '[a b] spaced name.webp': [
        <String>['a b'],
        ' spaced name',
        '.webp',
      ],
      '[bad/name]x.gif': [<String>[], '[bad/name]x', '.gif'],
      '[x][bad/name]rest.png': [
        <String>['x'],
        '[bad/name]rest',
        '.png',
      ],
      '[x][broken-name.jpg': [
        <String>['x'],
        '[broken-name',
        '.jpg',
      ],
    };

    for (final entry in cases.entries) {
      test('parses and round-trips ${entry.key}', () {
        final parsed = parseFilename(entry.key);
        expect(parsed.tags, entry.value[0]);
        expect(parsed.stem, entry.value[1]);
        expect(parsed.extension, entry.value[2]);
        expect(parsed.serialize(), entry.key);
      });
    }

    test('rejects invalid tag values', () {
      for (final bad in [
        '',
        ' x',
        'x ',
        'a[b',
        'a]b',
        'a/b',
        'a\\b',
        'a\u0000b',
        'a\u001fb',
        'a\u007fb',
        '\tname',
        'name\n',
      ]) {
        expect(isValidTag(bad), isFalse, reason: bad);
      }
    });

    test(
      'accepts historical Unicode and internal spaces without rewriting',
      () {
        expect(isValidTag('方舟'), isTrue);
        expect(isValidTag('a b'), isTrue);
        const name = '[方舟][a b]图片 [x].JPG';
        expect(parseFilename(name).serialize(), name);
      },
    );

    test('keeps a long stem unchanged without path-level truncation', () {
      final name = '[x]${'a' * 240}.jpg';
      final parsed = parseFilename(name);
      expect(parsed.stem, 'a' * 240);
      expect(parsed.serialize(), name);
    });
  });

  group('tag operations and filtering', () {
    final groups = TagGroups([
      TagGroup(
        id: 'arknights',
        displayName: '明日方舟',
        writeTag: 'mrfz',
        aliases: ['mrfz', 'MRFZ', '方舟'],
      ),
    ]);
    final original = parseFilename('[MRFZ][mrfz][other]image.jpg');

    test(
      'group add preserves existing alias and remove deletes every alias',
      () {
        expect(
          identical(groups.addGroup(original, 'arknights'), original),
          isTrue,
        );
        expect(
          groups.removeGroup(original, 'arknights').serialize(),
          '[other]image.jpg',
        );
      },
    );

    test('raw operations preserve other tags and order', () {
      expect(
        original.removeRawTag('mrfz').serialize(),
        '[MRFZ][other]image.jpg',
      );
      expect(original.addRawTag('other').serialize(), original.serialize());
      expect(
        original.addRawTag('new').serialize(),
        '[MRFZ][mrfz][other][new]image.jpg',
      );
      expect(
        original.withStem('renamed').serialize(),
        '[MRFZ][mrfz][other]renamed.jpg',
      );
    });

    test('raw equality is case-sensitive and deletion removes duplicates', () {
      final filename = parseFilename('[A][a][A][unknown]image.png');
      expect(filename.addRawTag('A').serialize(), filename.serialize());
      expect(filename.addRawTag('a').serialize(), filename.serialize());
      expect(filename.removeRawTag('A').serialize(), '[a][unknown]image.png');
      expect(
        filename.removeRawTag('A').removeRawTag('A').serialize(),
        '[a][unknown]image.png',
      );
      expect(
        filename.addRawTag('new').serialize(),
        '[A][a][A][unknown][new]image.png',
      );
      expect(() => filename.addRawTag('bad/name'), throwsArgumentError);
    });

    test('adding an absent group uses its default tag exactly once', () {
      final filename = parseFilename('[unknown]image.png');
      final added = groups.addGroup(filename, 'arknights');
      expect(added.serialize(), '[unknown][mrfz]image.png');
      expect(
        groups.addGroup(added, 'arknights').serialize(),
        added.serialize(),
      );
      expect(
        groups.removeGroup(added, 'arknights').serialize(),
        '[unknown]image.png',
      );
      expect(
        groups.removeGroup(filename, 'arknights').serialize(),
        filename.serialize(),
      );
    });

    test('aliases collapse to one identity while unknown tags stay exact', () {
      expect(groups.identities(['mrfz', 'MRFZ', '方舟', 'unknown']), {
        'group:arknights',
        'raw:unknown',
      });
      expect(groups.identity('MRFZ'), 'group:arknights');
      expect(groups.identity('mrfz'), 'group:arknights');
      expect(groups.identity('Unknown'), 'raw:Unknown');
      expect(groups.identity('unknown'), 'raw:unknown');
    });

    test('AND, OR, NOT and empty filters', () {
      expect(
        TagFilter(
          allOf: ['group:arknights'],
          noneOf: ['raw:missing'],
        ).matches(original, groups),
        isTrue,
      );
      expect(
        TagFilter(anyOf: ['raw:missing', 'raw:other'])
            .matches(original, groups),
        isTrue,
      );
      expect(
        TagFilter(noneOf: ['raw:other']).matches(original, groups),
        isFalse,
      );
      expect(
        TagFilter().matches(parseFilename('untagged.png'), groups),
        isTrue,
      );
    });

    test('only untagged matches the parsed raw tag list', () {
      final filter = TagFilter(onlyUntagged: true);
      expect(filter.matches(parseFilename('plain.png'), groups), isTrue);
      expect(filter.matches(parseFilename('name[tag].png'), groups), isTrue);
      expect(filter.matches(parseFilename('[]name.png'), groups), isTrue);
      expect(
        filter.matches(parseFilename('[unknown]name.png'), groups),
        isFalse,
      );
      expect(filter.matches(parseFilename('[方舟]name.png'), groups), isFalse);
      expect(
        () => TagFilter(onlyUntagged: true, noneOf: ['raw:x']),
        throwsArgumentError,
      );
    });

    test('allOf requires every identity and anyOf needs at least one', () {
      expect(
        TagFilter(allOf: ['group:arknights', 'raw:other'])
            .matches(original, groups),
        isTrue,
      );
      expect(
        TagFilter(allOf: ['group:arknights', 'raw:missing'])
            .matches(original, groups),
        isFalse,
      );
      expect(
        TagFilter(anyOf: ['raw:missing']).matches(original, groups),
        isFalse,
      );
      expect(
        TagFilter(noneOf: ['group:arknights']).matches(original, groups),
        isFalse,
      );
    });

    test('rejects aliases claimed by multiple groups', () {
      expect(
        () => TagGroups([
          TagGroup(id: 'a', displayName: 'A', writeTag: 'x', aliases: ['x']),
          TagGroup(id: 'b', displayName: 'B', writeTag: 'x', aliases: ['x']),
        ]),
        throwsArgumentError,
      );
    });

    test('rejects duplicate ids and invalid group definitions', () {
      expect(
        () => TagGroups([
          TagGroup(id: 'same', displayName: 'A', writeTag: 'a', aliases: ['a']),
          TagGroup(id: 'same', displayName: 'B', writeTag: 'b', aliases: ['b']),
        ]),
        throwsArgumentError,
      );
      expect(
        () => TagGroup(
          id: 'x',
          displayName: 'X',
          writeTag: 'x',
          aliases: ['other'],
        ),
        throwsArgumentError,
      );
      expect(
        () => TagGroup(
          id: 'x',
          displayName: 'X',
          writeTag: 'x',
          aliases: ['x', 'bad/name'],
        ),
        throwsArgumentError,
      );
    });
  });
}
