import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/domain/batch_stem.dart';
import 'package:image_tag_manager/src/domain/filename_tags.dart';
import 'package:image_tag_manager/src/domain/rename_plan.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';

void main() {
  test(
    'numbering is stable across click order and preserves tags/extensions',
    () {
      final batch = BatchStem(prefix: '表情_', start: 9, padding: 2);
      final names = {'b': '[旧]zzz.JPG', 'a': '[旧]aaa.png'};
      final edit = RenameEdit(addRaw: {'new'});
      final first = batch.edits(names, edit);
      final second = batch.edits({'a': names['a']!, 'b': names['b']!}, edit);
      final groups = TagGroups([]);
      for (final id in names.keys) {
        expect(first[id]!.stem, second[id]!.stem);
      }
      expect(
        first['a']!.apply(parseFilename(names['a']!), groups).serialize(),
        '[旧][new]表情_09.png',
      );
      expect(
        first['b']!.apply(parseFilename(names['b']!), groups).serialize(),
        '[旧][new]表情_10.JPG',
      );
    },
  );

  test('width never truncates numbers; zero start and single item work', () {
    expect(BatchStem(prefix: '图', start: 99, padding: 1).stemAt(1), '图100');
    expect(BatchStem(prefix: '图', start: 0, padding: 3).stemAt(0), '图000');
  });

  test('rejects ambiguous prefixes, invalid options and overflowing end', () {
    for (final prefix in [
      '',
      ' ',
      '[tag]图',
      '图]',
      '../图',
      'a/b',
      'a\\b',
      'a:',
      'a.',
      'CON',
    ]) {
      expect(
        () => BatchStem(prefix: prefix),
        throwsFormatException,
        reason: prefix,
      );
    }
    for (final start in [-1, 1000000000]) {
      expect(() => BatchStem(prefix: '图', start: start), throwsFormatException);
    }
    for (final width in [0, 10]) {
      expect(
        () => BatchStem(prefix: '图', padding: width),
        throwsFormatException,
      );
    }
    expect(
      () => BatchStem(prefix: '图', start: 999999999).stemAt(1),
      throwsFormatException,
    );
  });
}
