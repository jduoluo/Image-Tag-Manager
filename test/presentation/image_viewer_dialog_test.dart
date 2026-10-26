import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/presentation/image_viewer_dialog.dart';

void main() {
  testWidgets('GIF viewer loads the original file without thumbnail resizing', (
    tester,
  ) async {
    final path = File('test/fixtures/thumbnails/red.gif').absolute.path;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showImageViewer(context, path: path, filename: 'red.gif'),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    final viewer = tester.getRect(find.byType(Scaffold).last);
    expect(viewer.left, greaterThan(0));
    expect(
      viewer.right,
      lessThan(tester.view.physicalSize.width / tester.view.devicePixelRatio),
    );
    final image = tester.widget<Image>(find.byType(Image).last);
    expect(image.image, isA<FileImage>());
    expect(image.fit, BoxFit.contain);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回图片列表'), findsNothing);
  });

  testWidgets('long filename stays in a two-line toolbar chip', (tester) async {
    final path = File('test/fixtures/thumbnails/valid.png').absolute.path;
    final longName = '${List.filled(12, 'very-long-name-').join()}.png';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showImageViewer(context, path: path, filename: longName),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    final label = tester.widget<Text>(find.text(longName));
    expect(label.maxLines, 2);
    expect(label.overflow, TextOverflow.ellipsis);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('shows full file details and requests Explorer selection', (
    tester,
  ) async {
    final path = File('test/fixtures/thumbnails/valid.png').absolute.path;
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
            return null;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    String? revealed;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showImageViewer(
                context,
                path: path,
                filename: 'valid.png',
                revealFile: (value) async => revealed = value,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    final folder = File(path).parent.path;
    final folderLabel = folder.endsWith(Platform.pathSeparator)
        ? folder
        : '$folder${Platform.pathSeparator}';
    expect(find.text(folderLabel), findsOneWidget);
    expect(find.text('valid.png'), findsOneWidget);
    expect(find.text('完整文件名'), findsNothing);
    await tester.tap(find.text(folderLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已复制完整路径'), findsOneWidget);
    expect(copied, path);
    await tester.tap(find.text('valid.png'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已复制文件名'), findsOneWidget);
    expect(copied, 'valid.png');
    await tester.tap(find.byTooltip('在文件资源管理器中显示'));
    await tester.pump();
    expect(revealed, path);
  });
}
