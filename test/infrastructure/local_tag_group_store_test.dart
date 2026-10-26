import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/domain/tag_group_config.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';
import 'package:image_tag_manager/src/domain/tag_group_profiles.dart';
import 'package:image_tag_manager/src/infrastructure/local_tag_group_store.dart';

void main() {
  late Directory directory;
  late File config;

  setUp(() async {
    directory = await Directory('temp').createTemp('tag_group_store_test_');
    config = File(
      '${directory.path}${Platform.pathSeparator}config${Platform.pathSeparator}tag_groups.json',
    );
  });

  tearDown(() async => directory.delete(recursive: true));

  test('starts with an empty named profile when no config exists', () async {
    final profiles = await LocalTagGroupStore.atFile(config).loadProfiles();
    expect(profiles.active.name, '空配置');
    expect(profiles.active.groups.all, isEmpty);
  });

  test('creates portable config and reloads it', () async {
    final store = LocalTagGroupStore.atFile(config);
    expect((await store.load()).all, isEmpty);
    await store.save(
      TagGroups([
        TagGroup(
          id: 'red',
          displayName: '红色',
          writeTag: 'red',
          aliases: ['red', 'RED'],
        ),
      ]),
    );
    expect((await store.load()).identity('RED'), 'group:red');
    expect(await File('${config.path}.bak').exists(), isFalse);
  });

  test('portable path follows executable rather than working directory', () {
    final executable =
        '${directory.path}${Platform.pathSeparator}ImageTagManager.exe';
    final store = LocalTagGroupStore(executable);
    expect(store.file.path, config.path);
  });

  test('invalid config reports error rather than becoming empty', () async {
    await config.parent.create(recursive: true);
    await config.writeAsString('{invalid');
    final store = LocalTagGroupStore.atFile(config);
    await expectLater(store.load(), throwsFormatException);
  });

  test('recovers backup left between rename steps', () async {
    final store = LocalTagGroupStore.atFile(config);
    await store.save(TagGroups(const []));
    await config.rename('${config.path}.bak');
    expect((await store.load()).all, isEmpty);
  });

  test(
    'preserves original version 1 config in dedicated backups directory',
    () async {
      const original = '{"schemaVersion":1,"groups":[]}';
      await config.parent.create(recursive: true);
      await config.writeAsString(original);
      final store = LocalTagGroupStore.atFile(config);
      await store.save(TagGroups(const []));
      final backups = Directory(
        '${config.parent.path}${Platform.pathSeparator}backups',
      );
      final entries = await backups.list().toList();
      expect(entries, hasLength(1));
      expect(await File(entries.single.path).readAsString(), original);
      expect(
        TagGroupConfig.decode(await config.readAsString()).categories,
        isEmpty,
      );
    },
  );

  test('failed version 1 backup leaves original config untouched', () async {
    const original = '{"schemaVersion":1,"groups":[]}';
    await config.parent.create(recursive: true);
    await config.writeAsString(original);
    await File('${config.parent.path}${Platform.pathSeparator}backups')
        .writeAsString('occupied');
    final store = LocalTagGroupStore.atFile(config);
    await expectLater(
      store.save(TagGroups(const [])),
      throwsA(isA<FileSystemException>()),
    );
    expect(await config.readAsString(), original);
  });

  test(
    'migrates the legacy config into one profile without changing it',
    () async {
      final store = LocalTagGroupStore.atFile(config);
      await store.save(
        TagGroups([
          TagGroup(
            id: 'red',
            displayName: '红色',
            writeTag: 'red',
            aliases: ['red'],
          ),
        ]),
      );
      final legacy = await config.readAsString();
      final profiles = await store.loadProfiles();
      expect(profiles.profiles, hasLength(1));
      expect(profiles.active.name, '原有配置');
      expect(profiles.active.groups.identity('red'), 'group:red');
      await store.saveProfiles(profiles);
      expect(await config.readAsString(), legacy);
      expect(
        (await store.loadProfiles()).active.groups.identity('red'),
        'group:red',
      );
    },
  );

  test('persists multiple profiles and active selection', () async {
    final store = LocalTagGroupStore.atFile(config);
    final profiles = TagGroupProfiles(
      profiles: [
        TagGroupProfile(id: 'one', name: '第一份', groups: TagGroups(const [])),
        TagGroupProfile(
          id: 'two',
          name: '第二份',
          groups: TagGroups([
            TagGroup(
              id: 'blue',
              displayName: '蓝色',
              writeTag: 'blue',
              aliases: ['blue'],
            ),
          ]),
        ),
      ],
      activeId: 'two',
    );
    await store.saveProfiles(profiles);
    final loaded = await store.loadProfiles();
    expect(loaded.profiles.map((profile) => profile.name), ['第一份', '第二份']);
    expect(loaded.active.groups.identity('blue'), 'group:blue');
    expect(await File('${store.profilesFile.path}.bak').exists(), isFalse);
  });

  test('invalid profiles never silently fall back to legacy config', () async {
    final store = LocalTagGroupStore.atFile(config);
    await store.save(TagGroups(const []));
    await store.profilesFile.writeAsString('{invalid');
    await expectLater(store.loadProfiles(), throwsFormatException);
  });
}
