import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/local_image_directory_source.dart';

void main() {
  final fixturePath = Directory('test/fixtures/directory_scan').absolute.path;

  test(
    'non-recursive scan lists supported files and parses names only',
    () async {
      final entries = await const LocalImageDirectorySource()
          .scanCurrentDirectory(fixturePath)
          .toList();
      final names = entries.map((entry) => entry.filename).toSet();

      expect(names, {'root.jpg', '[x]name.PNG'});
      expect(
        entries
            .singleWhere((entry) => entry.filename == '[x]name.PNG')
            .parsedFilename
            .tags,
        ['x'],
      );
      expect(
        entries.every((entry) => entry.id.startsWith(fixturePath)),
        isTrue,
      );
    },
  );

  test('recursive directory discovery keeps child scanning separate', () async {
    final source = const LocalImageDirectorySource();
    final children = await source.listSubdirectories(fixturePath).toList();
    expect(children, contains('$fixturePath${Platform.pathSeparator}nested'));
    final childEntries = await source
        .scanCurrentDirectory('$fixturePath${Platform.pathSeparator}nested')
        .toList();
    expect(childEntries.map((entry) => entry.filename), ['child.gif']);
  });

  test('missing directory reports an error without creating it', () async {
    final missing = Directory('test/fixtures/directory_scan/missing').absolute;
    expect(missing.existsSync(), isFalse);
    expect(
      const LocalImageDirectorySource()
          .scanCurrentDirectory(missing.path)
          .toList(),
      throwsA(isA<FileSystemException>()),
    );
    expect(missing.existsSync(), isFalse);
  });
}
