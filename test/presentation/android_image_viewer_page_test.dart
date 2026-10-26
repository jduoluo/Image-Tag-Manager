import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/android_media_probe.dart';
import 'package:image_tag_manager/src/presentation/android_image_viewer_page.dart';

void main() {
  const channel = MethodChannel('image_tag_manager/android_media_probe');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final closed = <String>[];
  late Future<Map<String, String>> Function() open;
  setUp(() {
    closed.clear();
    open = () async => {
      'token': 'viewer-token',
      'path': File('test/fixtures/thumbnails/red.gif').absolute.path,
    };
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'openOriginalImage') {
        expect((call.arguments as Map)['id'], 12);
        return open();
      }
      if (call.method == 'closeOriginalImage') {
        closed.add((call.arguments as Map)['token'] as String);
        return null;
      }
      throw MissingPluginException(call.method);
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );
  Widget page() => const MaterialApp(
    home: AndroidImageViewerPage(
      image: MediaImage(12, '原图.gif'),
      probe: AndroidMediaProbe(),
    ),
  );

  testWidgets(
    'loads original GIF with bounded decoding, zoom reset and no filesystem actions',
    (tester) async {
      await tester.pumpWidget(page());
      await tester.pump();
      await tester.pump();
      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image as ResizeImage;
      expect(provider.imageProvider, isA<FileImage>());
      expect(provider.policy, ResizeImagePolicy.fit);
      expect(provider.width, 4096);
      expect(image.fit, BoxFit.contain);
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      viewer.transformationController!.value = Matrix4.diagonal3Values(2, 2, 1);
      await tester.tap(find.byTooltip('重置缩放'));
      expect(viewer.transformationController!.value, Matrix4.identity());
      expect(find.byTooltip('在文件资源管理器中定位'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(closed, ['viewer-token']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing before read finishes releases late original', (
    tester,
  ) async {
    final pending = Completer<Map<String, String>>();
    open = () => pending.future;
    await tester.pumpWidget(page());
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete({
      'token': 'late-token',
      'path': File('test/fixtures/thumbnails/red.gif').absolute.path,
    });
    await tester.pump();
    await tester.pump();
    expect(closed, ['late-token']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'permission or missing-file failure keeps return available without a dangling token',
    (tester) async {
      open = () async => throw PlatformException(code: 'denied');
      await tester.pumpWidget(page());
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('无法读取原图'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(closed, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
