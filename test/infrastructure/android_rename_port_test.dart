import 'dart:async';

import 'package:flutter/services.dart';
import 'package:image_tag_manager/src/application/directory_browser.dart';
import 'package:image_tag_manager/src/domain/filename_tags.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/android_rename_port.dart';
import 'package:image_tag_manager/src/infrastructure/windows_rename_port.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('image_tag_manager/android_safe_rename');
  const port = AndroidRenamePort();
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'Android namespace uses native names and propagates permission failure',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'directoryNames');
        expect(
          (call.arguments as Map)['directory'],
          '/storage/emulated/0/Pictures/HeyBox',
        );
        return ['visible.png', 'unlisted.png'];
      });
      expect(await port.directoryNames('/storage/emulated/0/Pictures/HeyBox'), [
        'visible.png',
        'unlisted.png',
      ]);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        throw PlatformException(code: 'denied');
      });
      await expectLater(
        port.directoryNames('/storage/emulated/0/Pictures/HeyBox'),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'preparation preserves requested IDs when native rows arrive unordered',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => [
          {'id': 2, 'name': 'b.png', 'path': '/b.png', 'fileId': 'b'},
          {'id': 1, 'name': 'a.png', 'path': '/a.png', 'fileId': 'a'},
        ],
      );
      final entries = await port.entries([1, 2]);
      expect(entries.map((entry) => entry.id), ['/a.png', '/b.png']);
    },
  );

  test('preparation rejects incomplete or wrong-ID responses instead of shifting identities', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => [
        {'id': 2, 'name': 'b.png', 'path': '/b.png', 'fileId': 'b'},
      ],
    );
    await expectLater(port.entries([1]), throwsA(isA<RenamePortException>()));
    await expectLater(
      port.entries([1, 2]),
      throwsA(isA<RenamePortException>()),
    );
  });

  test(
    'progress routes by request ID; cancelling discards a late successful read',
    () async {
      final pending = Completer<List<Map<String, Object>>>();
      final request = AndroidEntryPreparation();
      var cancelled = false;
      final progress = <int>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'entries') return pending.future;
        if (call.method == 'cancelPreparation') {
          expect((call.arguments as Map)['requestId'], request.requestId);
          cancelled = true;
          return null;
        }
        throw MissingPluginException(call.method);
      });
      final future = port.entries(
        [1],
        preparation: request,
        onProgress: (done, total) => progress.add(done),
      );
      void signal(String id, int done) => binding.channelBuffers.push(
        'image_tag_manager/android_safe_rename',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('entryPreparationProgress', {
            'requestId': id,
            'done': done,
            'total': 1,
          }),
        ),
        (_) {},
      );
      signal('old-request', 0);
      signal(request.requestId, 1);
      await Future<void>.delayed(Duration.zero);
      expect(progress, [1]);
      await request.cancel();
      final rejected = expectLater(
        future,
        throwsA(isA<AndroidPreparationCancelled>()),
      );
      pending.complete([
        {'id': 1, 'name': 'a.png', 'path': '/a.png', 'fileId': 'a'},
      ]);
      await rejected;
      expect(cancelled, isTrue);
    },
  );

  ImageEntry entry(String parent, String name, String identity) => ImageEntry(
    id: '$parent/$name',
    filename: name,
    parsedFilename: parseFilename(name),
    fileId: identity,
  );

  test('same-parent spelling aliases normalize by native identity without losing file identity', () {
    final entries = normalizeAndroidRenameSelection([
      entry(
        '/storage/emulated/0/Pictures/HeyBox',
        'a.png',
        'v@27:100:27:201:78:1:0',
      ),
      entry(
        '/storage/emulated/0/pictures/heybox',
        'b.png',
        'v@27:100:27:202:79:1:0',
      ),
    ]);
    expect(entries.last.id, '/storage/emulated/0/Pictures/HeyBox/b.png');
    expect(entries.last.fileId, 'v@27:100:27:202:79:1:0');
  });

  test('similar path spelling never merges distinct or unverified directory identities', () {
    for (final identity in [
      'v@27:101:27:202:79:1:0',
      'other@27:100:27:202:79:1:0',
      'unknown',
    ]) {
      expect(
        () => normalizeAndroidRenameSelection([
          entry(
            '/storage/emulated/0/Pictures/HeyBox',
            'a.png',
            'v@27:100:27:201:78:1:0',
          ),
          entry('/storage/emulated/0/pictures/heybox', 'b.png', identity),
        ]),
        throwsA(isA<RenamePortException>()),
      );
    }
  });

  test(
    'uncertain provider results retain their manual-inspection requirement',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls++;
            throw PlatformException(
              code: 'rename_failed',
              message: '系统自动换名，实际路径 /target(1).png',
              details: {'requiresInspection': true},
            );
          });
      await expectLater(
        port.renameNoReplace('/a.png', '/b.png', 'identity'),
        throwsA(
          isA<RenamePortException>()
              .having((error) => error.isTransient, 'retry', isFalse)
              .having(
                (error) => error.requiresInspection,
                'manual inspection',
                isTrue,
              )
              .having(
                (error) => error.message,
                'message',
                contains('/target(1).png'),
              ),
        ),
      );
      expect(calls, 1);
    },
  );
  test(
    'splits system write grants at 2000 items and stops after refusal',
    () async {
      final batches = <List<String>>[];
      var accepted = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'authorize');
            batches.add(
              List<String>.from((call.arguments as Map)['paths'] as List),
            );
            return accepted;
          });
      final paths = List.generate(
        2001,
        (index) => '/storage/emulated/0/Pictures/$index.png',
      );
      expect(await port.authorize(paths), isTrue);
      expect(batches.map((values) => values.length), [2000, 1]);
      batches.clear();
      accepted = false;
      expect(await port.authorize(paths), isFalse);
      expect(batches, hasLength(1));
      expect(await port.authorize([]), isTrue);
    },
  );

  test(
    'Linux errors never inherit Windows automatic retry semantics',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(
              (call.arguments as Map)['source'],
              '/storage/emulated/0/Pictures/精灵😀.png',
            );
            throw PlatformException(
              code: 'rename_failed',
              message: 'unsupported (errno 32)',
            );
          });
      await expectLater(
        port.renameNoReplace(
          '/storage/emulated/0/Pictures/精灵😀.png',
          '/storage/emulated/0/Pictures/[x]精灵😀.png',
          'identity',
        ),
        throwsA(
          isA<RenamePortException>().having(
            (error) => error.isTransient,
            'transient',
            isFalse,
          ),
        ),
      );
    },
  );

  test(
    'uncertain native results cannot be reported as successful renames',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      await expectLater(
        port.renameNoReplace('/source.png', '/target.png', 'identity'),
        throwsA(isA<RenamePortException>()),
      );
      await expectLater(
        port.identity('/source.png'),
        throwsA(isA<RenamePortException>()),
      );
    },
  );
}
