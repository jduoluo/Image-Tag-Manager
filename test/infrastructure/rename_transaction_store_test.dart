import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/domain/rename_plan.dart';
import 'package:image_tag_manager/src/infrastructure/rename_transaction_store.dart';

void main() {
  late Directory root;
  late RenameTransactionStore store;
  const id = 'itm-20260924091500000000-a1b2c3d4';

  RenamePlan plan() => RenamePlan(
    id: id,
    directory: root.path,
    items: const [
      RenamePlanItem(
        original: 'old.jpg',
        temporary: '~itm-20260924091500000000-a1b2c3d4-0000.jpg',
        target: 'new.jpg',
        fileId: 'test-file-id',
        reason: 'test',
      ),
    ],
    unchanged: const [],
    issues: const [],
  );

  setUp(() async {
    root = await Directory('temp').absolute
        .createTemp('transaction_store_test_');
    store = RenameTransactionStore(
      await Directory('${root.path}${Platform.pathSeparator}transactions')
          .create(),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'an orphan event log names the missing plan and blocks resume',
    () async {
      final batch = plan();
      await store.savePlan(batch);
      await store.event(id, 'stage1');
      final planFile = File(
        '${store.directory.path}${Platform.pathSeparator}$id.json',
      );
      final reserved = await planFile.rename('${planFile.path}.bak');

      final pending = await store.pending();
      expect(pending, hasLength(1));
      expect(pending.single.plan, isNull);
      expect(pending.single.recordIssue, RenameRecordIssue.missingPlan);
      expect(pending.single.error, contains(planFile.path));
      expect(pending.single.error, contains('$id.events'));

      await reserved.rename(planFile.path);
      expect((await store.pending()).single.recordIssue, isNull);
    },
  );

  test('a plan without its event log is reported as incomplete', () async {
    await store.savePlan(plan());
    final savedOnly = await store.pending();
    expect(savedOnly.single.recordIssue, RenameRecordIssue.missingEvents);
    expect(savedOnly.single.error, contains('尚未生成'));

    await store.event(id, 'stage1');
    expect((await store.pending()).single.recordIssue, isNull);
    final events = File(
      '${store.directory.path}${Platform.pathSeparator}$id.events',
    );
    final reserved = await events.rename('${events.path}.bak');
    final missing = await store.pending();
    expect(missing.single.plan?.id, id);
    expect(missing.single.recordIssue, RenameRecordIssue.missingEvents);
    expect(missing.single.error, contains(events.path));
    await reserved.rename(events.path);
  });

  test(
    'visible temporary names only suggest loss when both files are absent',
    () async {
      final filenames = ['~$id-0000.jpg', '~$id-0001.jpg', 'ordinary.jpg'];
      final absent = await store.suspectedMissingRecords(filenames);
      expect(absent, hasLength(1));
      expect(absent.single.id, id);
      expect(absent.single.filenames, hasLength(2));
      expect(await store.suspectedMissingRecords(['ordinary.jpg']), isEmpty);

      await store.savePlan(plan());
      expect(await store.suspectedMissingRecords(filenames), isEmpty);
      await store.event(id, 'stage1');
      final planFile = File(
        '${store.directory.path}${Platform.pathSeparator}$id.json',
      );
      final reservedPlan = await planFile.rename('${planFile.path}.bak');
      expect(await store.suspectedMissingRecords(filenames), isEmpty);
      final events = File(
        '${store.directory.path}${Platform.pathSeparator}$id.events',
      );
      final reservedEvents = await events.rename('${events.path}.bak');
      expect((await store.suspectedMissingRecords(filenames)).single.id, id);
      await reservedPlan.rename(planFile.path);
      await reservedEvents.rename(events.path);
      expect(await store.suspectedMissingRecords(filenames), isEmpty);
    },
  );

  test('deletes complete records but rejects pending and manual records', () async {
    await store.savePlan(plan());
    await store.event(id, 'complete');
    expect(await store.completed(), hasLength(1));
    await store.deleteCompleted([id]);
    expect(await store.completed(), isEmpty);
    expect(await store.pending(), isEmpty);

    await store.savePlan(plan());
    await store.event(id, 'stage1');
    await expectLater(store.deleteCompleted([id]), throwsStateError);
    expect(await store.pending(), hasLength(1));
    await store.closeManually(plan(), abandoned: true);
    await expectLater(store.deleteCompleted([id]), throwsStateError);
    expect(await store.manuallyClosed(), hasLength(1));
  });
}
