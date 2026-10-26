import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/guide_preferences.dart';
import 'package:image_tag_manager/src/presentation/guide_startup.dart';
import 'package:image_tag_manager/src/presentation/usage_guide_page.dart';

class _Preferences implements GuidePreferences {
  bool suppressed = false;
  bool failRead = false;
  bool failWrite = false;
  @override
  Future<bool> loadSuppressed() async {
    if (failRead) throw StateError('read failure');
    return suppressed;
  }

  @override
  Future<void> saveSuppressed(bool value) async {
    if (failWrite) throw StateError('write failure');
    suppressed = value;
  }
}

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw StateError(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) async => '# 指南正文';
}

void main() {
  testWidgets('first launch, opt out, restart, manual re-enable and restart', (
    tester,
  ) async {
    final preferences = _Preferences();
    var browserBuilds = 0;
    Widget app() => DefaultAssetBundle(
      bundle: _Bundle(),
      child: MaterialApp(
        home: GuideStartup(
          preferences: preferences,
          assetPath: UsageGuidePage.windowsAssetPath,
          browserBuilder: (context) {
            browserBuilds++;
            return Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => UsageGuidePage(
                      assetPath: UsageGuidePage.windowsAssetPath,
                      preferences: preferences,
                    ),
                  ),
                ),
                child: const Text('手动打开指南'),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(browserBuilds, 0);
    expect(find.text('指南正文'), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(preferences.suppressed, isTrue);
    await tester.tap(find.byTooltip('进入图片列表'));
    await tester.pumpAndSettle();
    expect(find.text('手动打开指南'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(UsageGuidePage), findsNothing);
    await tester.tap(find.text('手动打开指南'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(preferences.suppressed, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('指南正文'), findsOneWidget);
  });

  testWidgets(
    'read and save failures remain visible and do not claim success',
    (tester) async {
      final preferences = _Preferences()
        ..failRead = true
        ..failWrite = true;
      await tester.pumpWidget(
        DefaultAssetBundle(
          bundle: _Bundle(),
          child: MaterialApp(
            home: GuideStartup(
              preferences: preferences,
              assetPath: UsageGuidePage.androidAssetPath,
              browserBuilder: (_) => const Text('browser'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('指南正文'), findsOneWidget);
      expect(find.textContaining('读取失败'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(preferences.suppressed, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('browser'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'local preference persists independently and rejects corrupt content',
    () async {
      final root = await Directory('temp').absolute
          .createTemp('guide-preference-');
      addTearDown(() async {
        expect(root.path.startsWith(Directory('temp').absolute.path), isTrue);
        await root.delete(recursive: true);
      });
      final file = File('${root.path}/config/guide_startup.txt');
      final store = LocalGuidePreferences(resolveFile: () async => file);
      expect(await store.loadSuppressed(), isFalse);
      await store.saveSuppressed(true);
      expect(
        await LocalGuidePreferences(resolveFile: () async => file)
            .loadSuppressed(),
        isTrue,
      );
      await store.saveSuppressed(false);
      expect(await store.loadSuppressed(), isFalse);
      await file.writeAsString('invalid');
      await expectLater(store.loadSuppressed(), throwsFormatException);
    },
  );
}
