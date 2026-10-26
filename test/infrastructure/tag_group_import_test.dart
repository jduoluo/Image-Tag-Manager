import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/tag_group_import.dart';

const _v1 =
    '{"schemaVersion":1,"groups":['
    '{"id":"a","displayName":"测试","writeTag":"a","aliases":["a","别名"]}]}';
const _v2 =
    '{"schemaVersion":2,"groups":['
    '{"id":"a","displayName":"测试","writeTag":"a","aliases":["a"]}],'
    '"categories":[{"id":"c","displayName":"分类","defaultGroupId":"a","memberGroupIds":["a"]}]}';

void main() {
  for (final source in [_v1, _v2]) {
    test(
      'imports supported config without depending on app build mode: $source',
      () async {
        final groups = await TagGroupImport.read(
          XFile.fromData(Uint8List.fromList(utf8.encode(source))),
        );
        expect(groups.all.single.id, 'a');
        expect(groups.categories.length, source == _v1 ? 0 : 1);
      },
    );
  }

  test('zero provider bytes fall back to the selected cached file', () async {
    final directory = Directory('temp').absolute
        .createTempSync('config_import_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/selected.json')
      ..writeAsStringSync(_v2);
    final selected = XFile.fromData(Uint8List(0), path: file.path, length: 0);
    expect(await selected.readAsString(), isEmpty);
    final groups = await TagGroupImport.read(selected);
    expect(groups.all.single.id, 'a');
    expect(groups.categories.single.id, 'c');
    expect(file.readAsStringSync(), _v2);
  });

  test('empty selection gives a readable error', () async {
    await expectLater(
      TagGroupImport.read(XFile.fromData(Uint8List(0))),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('没有读到内容'),
        ),
      ),
    );
  });

  test('BOM from other editors does not break a valid legacy config', () async {
    final groups = await TagGroupImport.read(
      XFile.fromData(Uint8List.fromList(utf8.encode('\uFEFF$_v1'))),
    );
    expect(groups.identity('别名'), 'group:a');
  });

  for (final entry in <String, String>{
    '   \n': '空白',
    '{': 'JSON',
    '{"schemaVersion":1,"profiles":[],"activeId":"a"}': '整份多配置存档',
    '{"schemaVersion":99,"groups":[]}': '不支持此配置格式版本',
  }.entries) {
    test(
      'reports import problem without silently changing format: ${entry.value}',
      () async {
        await expectLater(
          TagGroupImport.read(
            XFile.fromData(Uint8List.fromList(utf8.encode(entry.key))),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(entry.value),
            ),
          ),
        );
      },
    );
  }
}
