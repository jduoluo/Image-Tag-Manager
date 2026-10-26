import 'dart:io';

import 'package:image_tag_manager/src/domain/batch_stem.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/application/directory_browser.dart';
import 'package:image_tag_manager/src/application/rename_service.dart';
import 'package:image_tag_manager/src/domain/filename_tags.dart';
import 'package:image_tag_manager/src/domain/rename_plan.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';
import 'package:image_tag_manager/src/infrastructure/rename_transaction_store.dart';
import 'package:image_tag_manager/src/infrastructure/windows_rename_port.dart';

final class _FakePort implements RenamePort {
  final Map<String, String> ids = {};
  String? failFrom;
  String? failTarget;
  bool failOnce = true;
  bool unexpectedName = false;
  int writes = 0;

  @override
  Future<String> identity(String path, {bool requireDelete = false}) async {
    if (!await File(path).exists() || !ids.containsKey(path)) {
      throw const RenamePortException('not found', 2);
    }
    return ids[path]!;
  }

  @override
  Future<void> renameNoReplace(
    String source,
    String target,
    String expectedId,
  ) async {
    if (unexpectedName) {
      writes++;
      final actual = '$target.auto';
      await File(source).rename(actual);
      ids[actual] = ids.remove(source)!;
      throw RenamePortException('系统自动换名，实际路径：$actual', null, true);
    }
    if ((failFrom != null && source.endsWith(failFrom!)) ||
        (failTarget != null && target.endsWith(failTarget!))) {
      if (failOnce) {
        failOnce = false;
        throw const RenamePortException('injected failure', 5);
      }
    }
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const RenamePortException('target exists', 80);
    }
    if (ids[source] != expectedId) {
      throw const RenamePortException('identity changed');
    }
    await File(source).rename(target);
    ids[target] = ids.remove(source)!;
  }
}

final class _NamespacePort extends _FakePort implements RenameDirectoryListing {
  bool supplement = false;
  int listings = 0;
  @override
  Future<List<String>> directoryNames(String directory) async {
    listings++;
    final actual = await Directory(directory)
        .list(followLinks: false)
        .map((entry) => entry.path.split(Platform.pathSeparator).last)
        .toList();
    return supplement
        ? actual
        : actual.where((name) => name != 'unlisted.png').toList();
  }
}

void main() {
  late Directory root;
  late Directory pictures;
  late RenameTransactionStore store;
  late _FakePort port;
  late RenameService service;

  Future<ImageEntry> create(String name) async {
    final file = File('${pictures.path}${Platform.pathSeparator}$name');
    await file.writeAsString('content:$name');
    port.ids[file.path] = 'file-${port.ids.length}';
    return ImageEntry(
      id: file.path,
      filename: name,
      parsedFilename: parseFilename(name),
      fileId: port.ids[file.path],
    );
  }

  setUp(() async {
    root = await Directory('temp').absolute.createTemp('rename_service_test_');
    pictures = await Directory('${root.path}${Platform.pathSeparator}pictures')
        .create();
    store = RenameTransactionStore(
      Directory('${root.path}${Platform.pathSeparator}transactions'),
    );
    port = _FakePort();
    service = RenameService(port: port, store: store);
  });

  tearDown(() async => root.delete(recursive: true));

  test(
    'numbered batch executes and undo restores exact original names and bytes',
    () async {
      final entries = [await create('[old]z.JPG'), await create('a.png')];
      final before = {
        for (final entry in entries)
          entry.id: await File(entry.id).readAsBytes(),
      };
      final plan = await service.preview(
        directory: pictures.path,
        selected: entries,
        edits: BatchStem(prefix: 'short_', start: 7, padding: 2).edits({
          for (final entry in entries) entry.id: entry.filename,
        }, RenameEdit(addRaw: {'new'})),
        groups: TagGroups([]),
      );
      expect(plan.canExecute, isTrue);
      expect(plan.items.map((item) => item.target), [
        '[old][new]short_07.JPG',
        '[new]short_08.png',
      ]);
      expect((await service.execute(plan)).state, 'completed');
      final reverse = await service.previewReverse(plan);
      expect(reverse.canExecute, isTrue);
      expect((await service.execute(reverse)).state, 'completed');
      for (final entry in entries) {
        expect(await File(entry.id).readAsBytes(), before[entry.id]);
      }
    },
  );

  test('platform namespace supplement is used through preview, execution and undo without dropping identity checks', () async {
    final native = _NamespacePort();
    port = native;
    service = RenameService(port: native, store: store);
    final entry = await create('unlisted.png');
    final edits = {entry.id: RenameEdit(stem: 'short')};
    final blocked = await service.preview(
      directory: pictures.path,
      selected: [entry],
      edits: edits,
      groups: TagGroups([]),
    );
    expect(blocked.canExecute, isFalse);
    native.supplement = true;
    final plan = await service.preview(
      directory: pictures.path,
      selected: [entry],
      edits: edits,
      groups: TagGroups([]),
    );
    expect(plan.canExecute, isTrue);
    expect((await service.execute(plan)).state, 'completed');
    final reverse = await service.previewReverse(plan);
    expect((await service.execute(reverse)).state, 'completed');
    expect(await File(entry.id).readAsString(), 'content:unlisted.png');
    expect(native.listings, greaterThan(5));
    final stale = await service.preview(
      directory: pictures.path,
      selected: [entry],
      edits: edits,
      groups: TagGroups([]),
    );
    native.ids[entry.id] = 'replacement';
    expect((await service.execute(stale)).state, 'manual');
    expect(await File(entry.id).exists(), isTrue);
  });

  test('source mismatch distinguishes actual spelling from a missing directory entry', () async {
    final actual = await create('case.png');
    final stale = ImageEntry(
      id: '${pictures.path}${Platform.pathSeparator}case.PNG',
      filename: 'case.PNG',
      parsedFilename: parseFilename('case.PNG'),
      fileId: actual.fileId,
    );
    final spelling = await service.preview(
      directory: pictures.path,
      selected: [stale],
      edits: {stale.id: RenameEdit(stem: 'short')},
      groups: TagGroups([]),
    );
    expect(spelling.canExecute, isFalse);
    expect(spelling.issues.single, contains('实际名称：case.png'));
    await File(actual.id)
        .rename('${pictures.path}${Platform.pathSeparator}moved.png');
    final missing = await service.preview(
      directory: pictures.path,
      selected: [actual],
      edits: {actual.id: RenameEdit(stem: 'short')},
      groups: TagGroups([]),
    );
    expect(missing.issues.single, contains('目录中未找到'));
    expect(await store.pending(), isEmpty);
  });

  test('numbering never skips existing target; preview blocks whole batch without writes', () async {
    final entries = [await create('a.jpg'), await create('b.jpg')];
    await create('short001.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: entries,
      edits: BatchStem(prefix: 'short').edits({
        for (final entry in entries) entry.id: entry.filename,
      }, RenameEdit()),
      groups: TagGroups([]),
    );
    expect(plan.canExecute, isFalse);
    expect(plan.issues, isNotEmpty);
    expect(await File(entries.first.id).exists(), isTrue);
    expect(await store.pending(), isEmpty);
  });

  test('unexpected provider names stop without rollback and persist actual location', () async {
    final a = await create('a.jpg');
    final b = await create('b.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a, b],
      edits: {
        a.id: RenameEdit(stem: 'new-a'),
        b.id: RenameEdit(stem: 'new-b'),
      },
      groups: TagGroups([]),
      batchId: 'unexpected-provider-name',
    );
    port.unexpectedName = true;
    final result = await service.execute(plan);
    expect(result.state, 'manual');
    expect(port.writes, 1);
    expect(await File(b.id).exists(), isTrue);
    expect(await store.isClosed(plan.id), isFalse);
    expect(await store.lastEventKind(plan.id), 'uncertain:stage1');
    final reloaded = RenameTransactionStore(store.directory);
    expect(await reloaded.lastUncertainDetail(plan.id), contains('.auto'));
    expect(result.details, contains('.auto'));
  });
  test(
    'first write rejection reports unchanged files rather than restoration',
    () async {
      final image = await create('a.jpg');
      final plan = await service.preview(
        directory: pictures.path,
        selected: [image],
        edits: {image.id: RenameEdit(stem: 'renamed')},
        groups: TagGroups([]),
        batchId: 'rejected-first-write',
      );
      expect(plan.issues, isEmpty);
      port.failFrom = 'a.jpg';
      final result = await service.execute(plan);
      expect(result.state, 'notChanged');
      expect(result.done, 0);
      expect(result.total, 1);
      expect(await File(image.id).readAsString(), 'content:a.jpg');
    },
  );
  test('batch group add preserves an existing alias and image bytes', () async {
    final a = await create('a.jpg');
    final b = await create('[RED]b.jpg');
    final groups = TagGroups([
      TagGroup(
        id: 'red',
        displayName: '红色',
        writeTag: 'red',
        aliases: ['red', 'RED'],
      ),
    ]);
    final edit = RenameEdit(addGroups: {'red'});
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a, b],
      edits: {a.id: edit, b.id: edit},
      groups: groups,
      batchId: 'test-batch-1',
    );
    expect(plan.issues, isEmpty);
    expect(plan.items, hasLength(1));
    expect(plan.unchanged, ['[RED]b.jpg']);
    final result = await service.execute(plan);
    expect(result.state, 'completed');
    expect(
      await File('${pictures.path}${Platform.pathSeparator}[red]a.jpg')
          .readAsString(),
      'content:a.jpg',
    );
    expect(
      await File('${pictures.path}${Platform.pathSeparator}[RED]b.jpg')
          .readAsString(),
      'content:[RED]b.jpg',
    );
    expect(await store.pending(), isEmpty);
  });

  test('preflight reports outside file and directory collisions', () async {
    final a = await create('a.jpg');
    await create('b.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a],
      edits: {a.id: RenameEdit(stem: 'b')},
      groups: TagGroups(const []),
      batchId: 'test-batch-2',
    );
    expect(plan.canExecute, isFalse);
    expect(plan.issues.join(), contains('目标被批次外项目占用'));
    expect((await service.execute(plan)).state, 'manual');
    expect(
      await File('${pictures.path}${Platform.pathSeparator}a.jpg').exists(),
      isTrue,
    );
  });

  test('preview rejects a file replaced after the directory scan', () async {
    final a = await create('a.jpg');
    port.ids[a.id] = 'replacement-id';
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a],
      edits: {
        a.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-stale-id',
    );
    expect(plan.canExecute, isFalse);
    expect(plan.issues.join(), contains('扫描后发生变化'));
  });

  test(
    'preview rejects a temporary name occupied by a non-image file',
    () async {
      final a = await create('a.jpg');
      await File('${pictures.path}${Platform.pathSeparator}~test-temp-0000.jpg')
          .writeAsString('occupied');
      final plan = await service.preview(
        directory: pictures.path,
        selected: [a],
        edits: {
          a.id: RenameEdit(addRaw: {'x'}),
        },
        groups: TagGroups(const []),
        batchId: 'test-temp',
      );
      expect(plan.canExecute, isFalse);
      expect(plan.issues.join(), contains('临时名已占用'));
    },
  );

  test('two-stage rename supports swapping names', () async {
    final a = await create('a.jpg');
    final b = await create('b.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a, b],
      edits: {
        a.id: RenameEdit(stem: 'b'),
        b.id: RenameEdit(stem: 'a'),
      },
      groups: TagGroups(const []),
      batchId: 'test-batch-3',
    );
    expect(plan.canExecute, isTrue);
    expect((await service.execute(plan)).state, 'completed');
    expect(
      await File('${pictures.path}${Platform.pathSeparator}a.jpg')
          .readAsString(),
      'content:b.jpg',
    );
    expect(
      await File('${pictures.path}${Platform.pathSeparator}b.jpg')
          .readAsString(),
      'content:a.jpg',
    );
    final reverse = await service.previewReverse(plan);
    expect(reverse.canExecute, isTrue);
    expect((await service.execute(reverse)).state, 'completed');
    expect(
      await File('${pictures.path}${Platform.pathSeparator}a.jpg')
          .readAsString(),
      'content:a.jpg',
    );
    expect(
      await File('${pictures.path}${Platform.pathSeparator}b.jpg')
          .readAsString(),
      'content:b.jpg',
    );
  });

  test('stage one failure rolls completed temporary names back', () async {
    final a = await create('a.jpg');
    final b = await create('b.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a, b],
      edits: {
        a.id: RenameEdit(addRaw: {'x'}),
        b.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-batch-4',
    );
    port.failFrom = 'b.jpg';
    final result = await service.execute(plan);
    expect(result.state, 'rolledBack');
    expect(
      await File('${pictures.path}${Platform.pathSeparator}a.jpg').exists(),
      isTrue,
    );
    expect(
      await File('${pictures.path}${Platform.pathSeparator}b.jpg').exists(),
      isTrue,
    );
    expect(await store.pending(), isEmpty);
  });

  test('cancel during first stage restores original names', () async {
    final a = await create('a.jpg');
    final b = await create('b.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a, b],
      edits: {
        a.id: RenameEdit(addRaw: {'x'}),
        b.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-cancel-1',
    );
    var checks = 0;
    final result = await service.execute(plan, cancelled: () => checks++ > 0);
    expect(result.state, 'rolledBack');
    expect(
      await File('${pictures.path}${Platform.pathSeparator}a.jpg').exists(),
      isTrue,
    );
    expect(
      await File('${pictures.path}${Platform.pathSeparator}b.jpg').exists(),
      isTrue,
    );
  });

  test('stage two failure preserves scene and resumes after recheck', () async {
    final a = await create('a.jpg');
    final b = await create('b.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a, b],
      edits: {
        a.id: RenameEdit(addRaw: {'x'}),
        b.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-batch-5',
    );
    port.failTarget = '[x]b.jpg';
    final result = await service.execute(plan);
    expect(result.state, 'pending');
    expect(
      await File('${pictures.path}${Platform.pathSeparator}[x]a.jpg').exists(),
      isTrue,
    );
    expect(
      await File(
        '${pictures.path}${Platform.pathSeparator}${plan.items[1].temporary}',
      ).exists(),
      isTrue,
    );
    expect(await store.pending(), hasLength(1));
    expect((await service.resume(plan)).state, 'completed');
    expect(await store.pending(), isEmpty);
  });

  test('recovery trusts file identity when stage-one journal lags', () async {
    final a = await create('a.jpg');
    final b = await create('b.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a, b],
      edits: {
        a.id: RenameEdit(addRaw: {'x'}),
        b.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-crash-stage1',
    );
    await store.savePlan(plan);
    await port.renameNoReplace(
      a.id,
      '${pictures.path}${Platform.pathSeparator}${plan.items.first.temporary}',
      plan.items.first.fileId,
    );
    expect((await service.resume(plan)).state, 'rolledBack');
    expect(await File(a.id).exists(), isTrue);
    expect(await File(b.id).exists(), isTrue);
  });

  test('recovery completes stage two when journal lags actual names', () async {
    final a = await create('a.jpg');
    final b = await create('b.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a, b],
      edits: {
        a.id: RenameEdit(addRaw: {'x'}),
        b.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-crash-stage2',
    );
    await store.savePlan(plan);
    for (final item in plan.items) {
      await port.renameNoReplace(
        '${pictures.path}${Platform.pathSeparator}${item.original}',
        '${pictures.path}${Platform.pathSeparator}${item.temporary}',
        item.fileId,
      );
    }
    final first = plan.items.first;
    await port.renameNoReplace(
      '${pictures.path}${Platform.pathSeparator}${first.temporary}',
      '${pictures.path}${Platform.pathSeparator}${first.target}',
      first.fileId,
    );
    expect((await service.resume(plan)).state, 'completed');
    expect(await store.pending(), isEmpty);
  });

  test(
    'recovery lists multiple faults and only continues safe stage-two items',
    () async {
      final entries = [
        await create('a.jpg'),
        await create('b.jpg'),
        await create('c.jpg'),
        await create('d.jpg'),
      ];
      final plan = await service.preview(
        directory: pictures.path,
        selected: entries,
        edits: {
          for (final entry in entries) entry.id: RenameEdit(addRaw: {'x'}),
        },
        groups: TagGroups(const []),
        batchId: 'test-partial-stage2',
      );
      await store.savePlan(plan);
      for (final item in plan.items) {
        await port.renameNoReplace(
          '${pictures.path}${Platform.pathSeparator}${item.original}',
          '${pictures.path}${Platform.pathSeparator}${item.temporary}',
          item.fileId,
        );
      }
      final first = plan.items[0];
      await port.renameNoReplace(
        '${pictures.path}${Platform.pathSeparator}${first.temporary}',
        '${pictures.path}${Platform.pathSeparator}${first.target}',
        first.fileId,
      );
      final missing = plan.items[1];
      final missingTemp =
          '${pictures.path}${Platform.pathSeparator}${missing.temporary}';
      final reserve = await Directory(
        '${root.path}${Platform.pathSeparator}reserve',
      ).create();
      final reservedPath = '${reserve.path}${Platform.pathSeparator}b.jpg';
      await File(missingTemp).rename(reservedPath);
      port.ids[reservedPath] = port.ids.remove(missingTemp)!;
      final occupied = plan.items[2];
      final occupiedTarget =
          '${pictures.path}${Platform.pathSeparator}${occupied.target}';
      await Directory(occupiedTarget).create();

      final stopped = await service.resume(plan);
      expect(stopped.state, 'manual');
      expect(stopped.issues, hasLength(2));
      expect(stopped.issues.join(), contains(missing.original));
      expect(stopped.issues.join(), contains('目标名被目录占用'));
      expect(stopped.canContinueSafe, isTrue);
      expect(
        await File(
          '${pictures.path}${Platform.pathSeparator}${plan.items[3].temporary}',
        ).exists(),
        isTrue,
      );

      final partial = await service.resume(plan, continueSafe: true);
      expect(partial.state, 'manual');
      expect(partial.issues, hasLength(2));
      expect(await store.pending(), hasLength(1));
      expect(
        await File(
          '${pictures.path}${Platform.pathSeparator}${plan.items[3].target}',
        ).readAsString(),
        'content:d.jpg',
      );
      expect(await File(missingTemp).exists(), isFalse);
      expect(await File(occupiedTarget).exists(), isFalse);

      await Directory(occupiedTarget).delete();
      await File(reservedPath).rename(missingTemp);
      port.ids[missingTemp] = port.ids.remove(reservedPath)!;
      expect((await service.resume(plan)).state, 'completed');
      expect(await store.pending(), isEmpty);
      for (final item in plan.items) {
        expect(
          await File('${pictures.path}${Platform.pathSeparator}${item.target}')
              .readAsString(),
          'content:${item.original}',
        );
      }
    },
  );

  test('recovery skips an occupied original while rolling back safe items', () async {
    final entries = [
      await create('a.jpg'),
      await create('b.jpg'),
      await create('c.jpg'),
    ];
    final plan = await service.preview(
      directory: pictures.path,
      selected: entries,
      edits: {
        for (final entry in entries) entry.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-partial-rollback',
    );
    await store.savePlan(plan);
    for (final item in plan.items.take(2)) {
      await port.renameNoReplace(
        '${pictures.path}${Platform.pathSeparator}${item.original}',
        '${pictures.path}${Platform.pathSeparator}${item.temporary}',
        item.fileId,
      );
    }
    final occupiedOriginal =
        '${pictures.path}${Platform.pathSeparator}${plan.items.first.original}';
    await Directory(occupiedOriginal).create();

    final stopped = await service.resume(plan);
    expect(stopped.issues, hasLength(1));
    expect(stopped.issues.single, contains('原名被目录占用'));
    expect(stopped.canContinueSafe, isTrue);
    final partial = await service.resume(plan, continueSafe: true);
    expect(partial.state, 'manual');
    expect(await store.pending(), hasLength(1));
    expect(
      await File('${pictures.path}${Platform.pathSeparator}b.jpg').exists(),
      isTrue,
    );
    expect(
      await File('${pictures.path}${Platform.pathSeparator}c.jpg').exists(),
      isTrue,
    );
    expect(await File(occupiedOriginal).exists(), isFalse);

    await Directory(occupiedOriginal).delete();
    expect((await service.resume(plan)).state, 'rolledBack');
    expect(await store.pending(), isEmpty);
    expect(await File(occupiedOriginal).readAsString(), 'content:a.jpg');
  });

  test(
    'missing transaction directory is reported without attempting writes',
    () async {
      final a = await create('a.jpg');
      final plan = await service.preview(
        directory: pictures.path,
        selected: [a],
        edits: {
          a.id: RenameEdit(addRaw: {'x'}),
        },
        groups: TagGroups(const []),
        batchId: 'test-missing-directory',
      );
      await store.savePlan(plan);
      final moved = await pictures.rename(
        '${root.path}${Platform.pathSeparator}pictures_moved',
      );
      final result = await service.resume(plan);
      expect(result.state, 'manual');
      expect(result.details, contains('无法读取事务目录'));
      expect(result.canContinueSafe, isFalse);
      expect(
        await File('${moved.path}${Platform.pathSeparator}a.jpg').exists(),
        isTrue,
      );
    },
  );

  test('corrupt plan is kept for manual recovery', () async {
    final a = await create('a.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [a],
      edits: {
        a.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-batch-6',
    );
    await store.savePlan(plan);
    final file = File(
      '${store.directory.path}${Platform.pathSeparator}${plan.id}.json',
    );
    await file.writeAsString('broken');
    final pending = await store.pending();
    expect(pending, hasLength(1));
    expect(pending.single.plan, isNull);
  });

  test(
    'a confirmed new batch can run while another batch stays pending',
    () async {
      final a = await create('a.jpg');
      final b = await create('b.jpg');
      final first = await service.preview(
        directory: pictures.path,
        selected: [a],
        edits: {
          a.id: RenameEdit(addRaw: {'first'}),
        },
        groups: TagGroups(const []),
        batchId: 'test-pending-first',
      );
      await store.savePlan(first);
      await store.event(first.id, 'stage1');
      final second = await service.preview(
        directory: pictures.path,
        selected: [b],
        edits: {
          b.id: RenameEdit(addRaw: {'second'}),
        },
        groups: TagGroups(const []),
        batchId: 'test-pending-second',
      );
      final blocked = await service.execute(second);
      expect(blocked.state, 'manual');
      expect(await store.pending(), hasLength(1));
      final acknowledged = await service.execute(
        second,
        acknowledgedPendingPaths: {
          '${store.directory.path}${Platform.pathSeparator}${first.id}.json',
        },
      );
      expect(acknowledged.state, 'completed');
      expect(await store.pending(), hasLength(1));
      expect((await store.completed()).single.id, second.id);
      expect(
        await File('${pictures.path}${Platform.pathSeparator}a.jpg')
            .readAsString(),
        'content:a.jpg',
      );
      expect(
        await File('${pictures.path}${Platform.pathSeparator}[second]b.jpg')
            .readAsString(),
        'content:b.jpg',
      );
    },
  );

  test(
    'multiple pending plans can be closed individually without completion',
    () async {
      final a = await create('a.jpg');
      final b = await create('b.jpg');
      final plans = <RenamePlan>[];
      for (final (index, entry) in [a, b].indexed) {
        final plan = await service.preview(
          directory: pictures.path,
          selected: [entry],
          edits: {
            entry.id: RenameEdit(addRaw: {'x'}),
          },
          groups: TagGroups(const []),
          batchId: 'test-manual-close-$index',
        );
        await store.savePlan(plan);
        await store.event(plan.id, 'stage1');
        plans.add(plan);
      }
      expect((await store.pending()).map((pending) => pending.plan!.id), [
        plans.last.id,
        plans.first.id,
      ]);
      await store.closeManually(plans.first, abandoned: false, note: '已另行改名');
      expect((await store.pending()).single.plan!.id, plans.last.id);
      expect(await store.lastEventKind(plans.first.id), 'manualResolved');
      await store.closeManually(plans.last, abandoned: true, note: '文件丢失');
      expect(await store.pending(), isEmpty);
      expect(await store.completed(), isEmpty);
      expect(await store.lastEventKind(plans.last.id), 'manualAbandoned');
      final closed = await store.manuallyClosed();
      expect(closed, hasLength(2));
      expect(
        closed.any((record) => record.note == '已另行改名' && !record.abandoned),
        isTrue,
      );
      expect(
        closed.any((record) => record.note == '文件丢失' && record.abandoned),
        isTrue,
      );
      expect((await service.resume(plans.first)).state, 'manual');
      expect(
        () => store.closeManually(plans.first, abandoned: false),
        throwsStateError,
      );
    },
  );

  test('stage two interruption before its first target resumes targets, not original names', () async {
    final entry = await create('a.jpg');
    final plan = await service.preview(
      directory: pictures.path,
      selected: [entry],
      edits: {
        entry.id: RenameEdit(addRaw: {'x'}),
      },
      groups: TagGroups(const []),
      batchId: 'test-stage2-first',
    );
    await store.savePlan(plan);
    final item = plan.items.single;
    await port.renameNoReplace(
      entry.id,
      '${pictures.path}${Platform.pathSeparator}${item.temporary}',
      item.fileId,
    );
    await store.event(plan.id, 'stage2');
    await store.event(plan.id, 'intent:stage2', item.original);
    final outcome = await service.resume(plan);
    expect(outcome.state, 'completed');
    expect(
      await File('${pictures.path}${Platform.pathSeparator}[x]a.jpg')
          .readAsString(),
      'content:a.jpg',
    );
    expect(await File(entry.id).exists(), isFalse);
    expect(await store.pending(), isEmpty);
  });

  test(
    'Android filename byte limits reject multibyte names before saving a plan',
    () async {
      final entry = await create('a.jpg');
      final androidService = RenameService(
        port: port,
        store: store,
        maxPathLength: null,
        maxFilenameBytes: 255,
      );
      final plan = await androidService.preview(
        directory: pictures.path,
        selected: [entry],
        edits: {entry.id: RenameEdit(stem: List.filled(100, '中').join())},
        groups: TagGroups(const []),
      );
      expect(plan.canExecute, isFalse);
      expect(plan.issues.any((issue) => issue.contains('长度限制')), isTrue);
      expect(await File(entry.id).readAsString(), 'content:a.jpg');
      expect(await store.pending(), isEmpty);
    },
  );
  test('1000 synthetic names complete with per-step flushed journal', () async {
    final entries = <ImageEntry>[];
    for (var index = 0; index < 1000; index++) {
      entries.add(
        await create('image_${index.toString().padLeft(4, '0')}.jpg'),
      );
    }
    final edit = RenameEdit(addRaw: {'batch'});
    final watch = Stopwatch()..start();
    final plan = await service.preview(
      directory: pictures.path,
      selected: entries,
      edits: {for (final entry in entries) entry.id: edit},
      groups: TagGroups(const []),
      batchId: 'test-batch-1000',
    );
    expect(plan.canExecute, isTrue);
    expect((await service.execute(plan)).state, 'completed');
    watch.stop();
    // This records observed time without making machine speed a correctness gate.
    // ignore: avoid_print
    print('1000 rename fixture elapsed: ${watch.elapsed}');
    expect(await store.pending(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
