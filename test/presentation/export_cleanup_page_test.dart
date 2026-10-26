import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/android_media_probe.dart';
import 'package:image_tag_manager/src/presentation/export_cleanup_page.dart';

void main() {
  const channel = MethodChannel('image_tag_manager/android_media_probe');
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  testWidgets(
    'repeated cleanup keeps list viewport and refresh resets scrolling without reopening',
    (tester) async {
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final remaining = List.generate(24, (i) => i);
      final confirmed = <int>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'previewExportCleanup') {
              return {
                'token': 'preview',
                'excluded': 0,
                'items': [
                  for (final id in remaining)
                    {'id': id, 'name': '$id.jpg', 'size': 10},
                ],
              };
            }
            if (call.method == 'deleteExportCopies') {
              final ids = List<int>.from((call.arguments as Map)['ids']);
              remaining.removeWhere(ids.contains);
              return {'deleted': ids.length, 'deletedIds': ids, 'issues': []};
            }
            throw MissingPluginException(call.method);
          });
      await tester.pumpWidget(
        MaterialApp(
          home: ExportCleanupPage(
            probe: const AndroidMediaProbe(),
            onChanged: (ids, unknown) {
              expect(unknown, isFalse);
              confirmed.addAll(ids);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('export-cleanup-list'));
      final height = tester.getSize(list).height;
      for (final id in [0, 1]) {
        await tester.tap(find.text('$id.jpg'));
        await tester.pump();
        await tester.tap(find.text('清理已选（1）'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除选中副本'));
        await tester.pumpAndSettle();
        expect(tester.getSize(list).height, greaterThan(height - 100));
        expect(
          find.textContaining('可清理 ${remaining.length} 张'),
          findsOneWidget,
        );
      }
      expect(confirmed, {0, 1});
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(
        find.text('23.jpg'),
        300,
        scrollable: scrollable,
      );
      expect(find.text('23.jpg'), findsOneWidget);
      await tester.tap(find.text('刷新列表'));
      await tester.pumpAndSettle();
      expect(find.text('2.jpg'), findsOneWidget);
      expect(remaining, hasLength(22));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cleanup defaults to none, cancellation writes nothing, confirmed selection only is deleted',
    (tester) async {
      var deleted = false;
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'previewExportCleanup') {
              return {
                'token': 'preview',
                'excluded': 1,
                'items': [
                  if (!deleted) {'id': 1, 'name': 'one.jpg', 'size': 100},
                  {'id': 2, 'name': 'two.jpg', 'size': 200},
                ],
              };
            }
            if (call.method == 'deleteExportCopies') {
              calls++;
              expect(call.arguments, {
                'token': 'preview',
                'ids': [1],
              });
              deleted = true;
              return {'deleted': 1, 'issues': []};
            }
            throw MissingPluginException(call.method);
          });
      await tester.pumpWidget(
        const MaterialApp(home: ExportCleanupPage(probe: AndroidMediaProbe())),
      );
      await tester.pumpAndSettle();
      expect(find.text('清理已选（0）'), findsOneWidget);
      expect(calls, 0);
      await tester.tap(find.text('one.jpg'));
      await tester.pump();
      await tester.tap(find.text('清理已选（1）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('此操作不能从应用内撤销'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.text('清理已选（1）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中副本'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('one.jpg'), findsNothing);
      expect(find.text('two.jpg'), findsOneWidget);
      expect(find.textContaining('已删除 1 张'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'stop finishes current batch without deleting later selected copies',
    (tester) async {
      var calls = 0;
      final first = Completer<Map<String, Object>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'previewExportCleanup') {
              return {
                'token': 'preview',
                'excluded': 0,
                'items': [
                  for (var i = 0; i < 51; i++)
                    {'id': i, 'name': '$i.jpg', 'size': 10},
                ],
              };
            }
            if (call.method == 'deleteExportCopies') {
              calls++;
              expect(((call.arguments as Map)['ids'] as List).length, 50);
              return first.future;
            }
            throw MissingPluginException(call.method);
          });
      await tester.pumpWidget(
        const MaterialApp(home: ExportCleanupPage(probe: AndroidMediaProbe())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选可清理副本'));
      await tester.pump();
      await tester.tap(find.text('清理已选（51）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中副本'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('停止后续清理'));
      await tester.pump();
      first.complete({
        'deleted': 49,
        'issues': [
          {'name': 'changed.jpg', 'reason': '副本已变化'},
        ],
      });
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.textContaining('已处理 50/51 项 · 已停止'), findsOneWidget);
      expect(find.textContaining('副本已变化'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
