import 'dart:io';

import '../domain/tag_group_config.dart';
import '../domain/tag_groups.dart';
import '../domain/tag_group_profiles.dart';

abstract interface class TagGroupStore {
  Future<TagGroups> load();
  Future<void> save(TagGroups groups);
  Future<TagGroupProfiles> loadProfiles();
  Future<void> saveProfiles(TagGroupProfiles profiles);
}

/// Windows portable config beside the executable, never the process cwd.
final class LocalTagGroupStore implements TagGroupStore {
  LocalTagGroupStore(String executablePath)
    : file = File(
        '${File(executablePath).parent.path}${Platform.pathSeparator}config${Platform.pathSeparator}tag_groups.json',
      );

  LocalTagGroupStore.atFile(this.file);

  final File file;

  File get profilesFile => File(
    '${file.parent.path}${Platform.pathSeparator}tag_group_profiles.json',
  );

  @override
  Future<TagGroupProfiles> loadProfiles() async {
    final backup = File('${profilesFile.path}.bak');
    if (await profilesFile.exists()) {
      return TagGroupProfiles.decode(await profilesFile.readAsString());
    }
    if (await backup.exists()) {
      return TagGroupProfiles.decode(await backup.readAsString());
    }
    final legacyExists =
        await file.exists() || await File('${file.path}.bak').exists();
    return TagGroupProfiles.initial(
      await load(),
      name: legacyExists ? '原有配置' : '空配置',
    );
  }

  @override
  Future<void> saveProfiles(TagGroupProfiles profiles) async {
    final target = profilesFile;
    final backup = File('${target.path}.bak');
    final pending = File('${target.path}.tmp');
    await target.parent.create(recursive: true);
    if (await target.exists()) {
      TagGroupProfiles.decode(await target.readAsString());
    }
    if (await pending.exists()) await pending.delete();
    await pending.writeAsString(
      '${TagGroupProfiles.encode(profiles)}\n',
      flush: true,
    );
    var movedOriginal = false;
    try {
      if (await target.exists()) {
        if (await backup.exists()) await backup.delete();
        await target.rename(backup.path);
        movedOriginal = true;
      }
      await pending.rename(target.path);
    } catch (_) {
      if (movedOriginal && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    if (await backup.exists()) {
      try {
        await backup.delete();
      } on FileSystemException {
        // The new profiles file is valid; stale backup cleanup can wait.
      }
    }
  }

  @override
  Future<TagGroups> load() async {
    final backup = File('${file.path}.bak');
    if (await file.exists()) {
      return TagGroupConfig.decode(await file.readAsString());
    }
    if (await backup.exists()) {
      return TagGroupConfig.decode(await backup.readAsString());
    }
    return TagGroups(const []);
  }

  @override
  Future<void> save(TagGroups groups) async {
    final directory = file.parent;
    await directory.create(recursive: true);
    if (await file.exists()) {
      final original = await file.readAsString();
      TagGroupConfig.decode(original);
      if (TagGroupConfig.isVersion1(original)) {
        final backups = Directory(
          '${directory.path}${Platform.pathSeparator}backups',
        );
        await backups.create(recursive: true);
        final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
        var suffix = 0;
        File backup;
        do {
          backup = File(
            '${backups.path}${Platform.pathSeparator}tag_groups-v1-$stamp-$suffix.json',
          );
          suffix++;
        } while (await backup.exists());
        await backup.writeAsString(original, flush: true);
      }
    }
    final pending = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    if (await pending.exists()) await pending.delete();
    await pending.writeAsString(
      '${TagGroupConfig.encode(groups)}\n',
      flush: true,
    );
    var movedOriginal = false;
    try {
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
        movedOriginal = true;
      }
      await pending.rename(file.path);
    } catch (_) {
      if (movedOriginal && !await file.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
    if (await backup.exists()) {
      try {
        await backup.delete();
      } on FileSystemException {
        // The new config is valid; stale backup cleanup can wait.
      }
    }
  }
}
