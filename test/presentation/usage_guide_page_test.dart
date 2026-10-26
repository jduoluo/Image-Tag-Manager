import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/presentation/usage_guide_page.dart';

class _GuideBundle extends CachingAssetBundle {
  var fail = true;
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    expect(key, UsageGuidePage.androidAssetPath);
    if (fail) throw StateError('missing');
    return '## 操作步骤\n\n1. 选择图片\n2. 查看 **预演**\n\n- 副本保存在 `TagQuickShare`\n\n普通说明。';
  }
}

class _LoadedGuideBundle extends CachingAssetBundle {
  _LoadedGuideBundle(this.path, this.contents);
  final String path;
  final String contents;
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) {
    expect(key, path);
    return SynchronousFuture(contents);
  }
}

void main() {
  test(
    'guide asset is packaged as editable Markdown with short sections',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final guide = await rootBundle.loadString(
        UsageGuidePage.androidAssetPath,
      );
      expect(guide, contains('## 1. 原理与注意事项'));
      expect(guide, contains('### 复制到公共相册与清理副本'));
      expect(guide, contains('- '));
      expect(guide, isNot(contains('## 应用显示')));
    },
  );
  testWidgets(
    'guide handles load failure and retry then renders narrow-screen steps and inline formatting',
    (tester) async {
      tester.view.physicalSize = const Size(360, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final bundle = _GuideBundle();
      await tester.pumpWidget(
        DefaultAssetBundle(
          bundle: bundle,
          child: const MaterialApp(
            home: UsageGuidePage(assetPath: UsageGuidePage.androidAssetPath),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('使用指南加载失败'), findsOneWidget);
      bundle.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('操作步骤'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('查看 预演'), findsOneWidget);
      expect(find.text('副本保存在 TagQuickShare'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'both bundled guides show a local image and allow zoom then close',
    (tester) async {
      tester.view.physicalSize = const Size(360, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      for (final path in [
        UsageGuidePage.androidAssetPath,
        UsageGuidePage.windowsAssetPath,
      ]) {
        final contents = await tester.runAsync(
          () => rootBundle.loadString(path),
        );
        await tester.pumpWidget(
          DefaultAssetBundle(
            bundle: _LoadedGuideBundle(path, contents!),
            child: MaterialApp(home: UsageGuidePage(assetPath: path)),
          ),
        );
        final firstImage = path == UsageGuidePage.windowsAssetPath
            ? 'docs/guide_images/windows-tagging-1.png'
            : 'docs/guide_images/android-tagging-1.png';
        await tester.runAsync(
          () => precacheImage(
            AssetImage(firstImage),
            tester.element(find.byType(UsageGuidePage)),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          RegExp(
            r'^!\[.*\]\(.*\)$',
            multiLine: true,
          ).allMatches(contents).length,
          path == UsageGuidePage.windowsAssetPath ? 7 : 9,
        );
        await tester.scrollUntilVisible(
          find.byWidgetPredicate(
            (widget) =>
                widget is Image &&
                widget.image is AssetImage &&
                (widget.image as AssetImage).assetName == firstImage,
          ),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('图片无法显示'), findsNothing);
        final imageSize = tester.getSize(find.byType(Image).first);
        expect(imageSize.width, lessThanOrEqualTo(320));
        expect(imageSize.height, greaterThan(0));
        await tester.tap(find.byType(Image).first);
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(viewer.maxScale, greaterThan(1));
        await tester.tap(find.byTooltip('关闭图片'));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(find.byType(UsageGuidePage), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'invalid image paths stay offline and do not hide following text',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GuideMarkdown(
              contents:
                  '![远程图片](https://example.invalid/image.png)\n\n'
                  '![越界图片](guide_images/../secret.png)\n\n'
                  '![绝对路径](C:/private/image.png)\n\n'
                  '后续说明仍然显示。',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('图片无法显示'), findsNWidgets(3));
      expect(find.text('后续说明仍然显示。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing bundled image shows a readable fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GuideMarkdown(
            contents: '![缺失图片](guide_images/missing.png)\n\n后续说明。',
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      try {
        await rootBundle.load('docs/guide_images/missing.png');
      } catch (_) {
        // Allow the image stream's asset read to complete as well.
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('缺失图片：图片无法显示'), findsOneWidget);
    expect(find.text('后续说明。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
