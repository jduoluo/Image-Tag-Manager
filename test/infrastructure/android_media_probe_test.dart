import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/android_media_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('image_tag_manager/android_media_probe');
  const probe = AndroidMediaProbe();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('distinguishes full, partial, and denied media access', () async {
    for (final entry in {
      'full': MediaAccess.full,
      'partial': MediaAccess.partial,
      'denied': MediaAccess.denied,
    }.entries) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => entry.key);
      expect(await probe.permissionState(), entry.value);
      expect(await probe.requestImages(), entry.value);
    }
  });

  test('reads album and image identities returned by Android', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listAlbums') {
            return [
              {'name': 'Pictures/ChatGPT/', 'count': 2},
              {'name': 'DCIM/Camera/', 'count': 3},
            ];
          }
          expect(call.method, 'listImages');
          expect((call.arguments as Map)['album'], 'Pictures/ChatGPT/');
          return [
            {'id': 73, 'name': '[例]图片.jpg'},
            {'id': 74, 'name': '另一张.png'},
          ];
        });
    final albums = await probe.listAlbums();
    expect(albums.map((album) => album.name), [
      'Pictures/ChatGPT/',
      'DCIM/Camera/',
    ]);
    expect(albums.map((album) => album.count), [2, 3]);
    final images = await probe.listImages(albums.first.name);
    expect(images.map((image) => image.id), [73, 74]);
    expect(images.map((image) => image.name), ['[例]图片.jpg', '另一张.png']);
  });

  test(
    'exports config through Android document creation and handles cancel',
    () async {
      final payloads = <String>[];
      var accepted = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'exportConfig');
            payloads.add((call.arguments as Map)['contents'] as String);
            return accepted;
          });
      expect(await probe.exportConfig('{"schemaVersion":2}\n'), isFalse);
      accepted = true;
      expect(await probe.exportConfig('{"schemaVersion":2}\n'), isTrue);
      expect(payloads, ['{"schemaVersion":2}\n', '{"schemaVersion":2}\n']);
    },
  );
  test('reads cross-album image metadata for global filtering', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'listAllImages');
          return [
            {'id': 73, 'name': '[例]图片.jpg', 'album': 'Pictures/ChatGPT/'},
            {'id': 74, 'name': '另一张.png', 'album': 'DCIM/Camera/'},
          ];
        });
    final images = await probe.listAllImages();
    expect(images.map((row) => row.album), [
      'Pictures/ChatGPT/',
      'DCIM/Camera/',
    ]);
    expect(images.map((row) => row.image.id), [73, 74]);
  });
  test('exports selected IDs and reports partial failure separately', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'requestExportPermission') return true;
          expect(call.method, 'exportImages');
          expect((call.arguments as Map)['ids'], [73, 74, 75]);
          return {
            'copied': 1,
            'skipped': 1,
            'issues': [
              {'name': 'same.jpg', 'reason': '目标目录已有同名图片'},
              {'name': 'broken.jpg', 'reason': '无法读取原图'},
            ],
          };
        });
    expect(await probe.requestExportPermission(), isTrue);
    final report = await probe.exportImages([73, 74, 75]);
    expect(report.copied, 1);
    expect(report.skipped, 1);
    expect(report.issues.map((issue) => issue.name), [
      'same.jpg',
      'broken.jpg',
    ]);
  });
}
