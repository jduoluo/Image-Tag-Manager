import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import 'package:image_tag_manager/src/infrastructure/media_visibility_store.dart';

import 'package:image_tag_manager/src/application/rename_service.dart';
import 'package:image_tag_manager/src/infrastructure/android_rename_port.dart';
import 'package:image_tag_manager/src/infrastructure/rename_transaction_store.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/presentation/android_media_probe_page.dart';
import 'package:image_tag_manager/src/infrastructure/local_tag_group_store.dart';
import 'package:image_tag_manager/src/domain/tag_group_profiles.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';
import 'package:image_tag_manager/src/presentation/usage_guide_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('image_tag_manager/android_media_probe');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('image_tag_manager/media_changes'),
          (call) async => null,
        );
  });
  final pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==',
  );

  void mockSimpleBrowser({int count = 2, bool tagged = false}) {
    final rows = [
      for (var i = 1; i <= count; i++)
        {
          'id': i,
          'name':
              '${tagged ? '[tag]' : ''}image_${i.toString().padLeft(3, '0')}.png',
          'album': 'a',
        },
    ];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'loadImageSort' => 'nameAscending',
        'permissionState' => 'full',
        'listAlbums' => [
          {'id': 'a', 'name': 'Pictures/A/', 'count': count},
        ],
        'listImages' || 'listAllImages' => rows,
        'thumbnail' => pixel,
        _ => throw MissingPluginException(call.method),
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  testWidgets(
    'manual toolbar toggle preserves filters, selection and scroll offset',
    (tester) async {
      mockSimpleBrowser(count: 50, tagged: true);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
      );
      await tester.pumpAndSettle();
      expect(find.text('排序：文件名 · 升序 ▾').hitTestable(), findsOneWidget);
      expect(find.text('编辑并打标'), findsNothing);
      expect(find.textContaining('照片权限：'), findsNothing);
      expect(
        tester.getCenter(find.text('仅显示无标签')).dy,
        closeTo(tester.getCenter(find.text('标签名组')).dy, 1),
      );
      await tester.tap(find.text('组合筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('android-filter:raw:tag')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AND  必须有'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.text('清空筛选')).dy,
        closeTo(tester.getCenter(find.text('组合筛选（1）')).dy, 1),
      );
      await tester.drag(
        find.byKey(const ValueKey('media-scroll')),
        const Offset(0, -450),
      );
      await tester.pumpAndSettle();
      expect(find.text('排序：文件名 · 升序 ▾').hitTestable(), findsOneWidget);
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('media-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final offset = scrollable.position.pixels;
      await tester.tap(find.byTooltip('收起工具栏'));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, offset);
      expect(find.text('组合筛选（1）'), findsNothing);
      await tester.tap(find.byTooltip('展开工具栏'));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, offset);
      expect(find.text('组合筛选（1）').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('media-active-filters')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('清空筛选').hitTestable(), findsOneWidget);

      await tester.tap(find.text('全选本页'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 50/50 · 已选 50'), findsOneWidget);
      final actions = tester.getRect(
        find.byKey(const ValueKey('media-selection-actions')),
      );
      expect(actions.bottom, lessThanOrEqualTo(800));
      expect(find.text('编辑并打标').hitTestable(), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('media-scroll')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('media-selection-actions'))),
        actions,
      );
      await tester.tap(find.text('清空全部'));
      await tester.pumpAndSettle();
      expect(find.text('编辑并打标'), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('media-scroll')),
        const Offset(0, 2000),
      );
      await tester.pumpAndSettle();
      expect(find.text('排序：文件名 · 升序 ▾').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty import preserves profile and selection; a legacy retry adds a new profile',
    (tester) async {
      mockSimpleBrowser();
      final store = _MemoryStore();
      final original = store.profiles;
      var selected = XFile.fromData(Uint8List(0));
      await tester.pumpWidget(
        MaterialApp(
          home: AndroidMediaProbePage(
            groupStore: store,
            selectConfig: () async => selected,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('image_001.png'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('配置与标签组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入单份 JSON 配置'));
      await tester.pumpAndSettle();
      expect(store.profiles, same(original));
      expect(find.textContaining('本文件夹 2/2 · 已选 1'), findsOneWidget);
      final error = tester.widget<Text>(find.textContaining('导入配置失败：'));
      expect(error.maxLines, 1);
      await tester.tap(find.byTooltip('查看错误详情'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      selected = XFile.fromData(
        Uint8List.fromList(
          utf8.encode(
            '{"schemaVersion":1,"groups":[{"id":"legacy","displayName":"旧标签","writeTag":"tag","aliases":["tag"]}]}',
          ),
        ),
        path: 'legacy.json',
      );
      await tester.tap(find.byTooltip('配置与标签组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入单份 JSON 配置'));
      await tester.pumpAndSettle();
      expect(find.text('导入单份标签组配置'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(store.profiles.profiles, hasLength(2));
      expect(store.profiles.active.groups.all.single.id, 'legacy');
      expect(find.textContaining('导入配置失败：'), findsNothing);
      expect(find.textContaining('本文件夹 2/2 · 已选 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact controls keep results visible and guide preserves selection',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'loadImageSort':
            return null;
          case 'permissionState':
            return 'full';
          case 'listAlbums':
            return [
              {'id': 'a', 'name': 'Pictures/LongFolderName/', 'count': 6323},
            ];
          case 'listAllImages':
          case 'listImages':
            return [
              {'id': 1, 'name': '[tag]first.png', 'album': 'a'},
              {'id': 2, 'name': 'second.png', 'album': 'a'},
            ];
          case 'thumbnail':
            return pixel;
          default:
            throw MissingPluginException(call.method);
        }
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      tester.view.devicePixelRatio = 1;
      for (final scenario in [
        (const Size(360, 800), 1.0),
        (const Size(320, 700), 1.6),
        (const Size(640, 360), 1.3),
      ]) {
        tester.view.physicalSize = scenario.$1;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scenario.$2)),
              child: child!,
            ),
            home: AndroidMediaProbePage(groupStore: _MemoryStore()),
          ),
        );
        await tester.pumpAndSettle();
        final viewport = tester.getRect(
          find.byKey(const ValueKey('media-scroll')),
        );
        expect(viewport.height, greaterThan(90));
        if (scenario.$2 == 1.0) {
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('media-tile-1'))).dy,
            lessThan(440),
          );
          expect(find.text('编辑并打标'), findsNothing);
          final buttons = [
            '全选本页',
            '全选全部',
            '清空本页',
            '清空全部',
          ].map((label) => tester.getRect(find.text(label))).toList();
          expect(buttons.every((rect) => rect.width > 0), isTrue);
          expect(find.byTooltip('收起工具栏').hitTestable(), findsOneWidget);
        }
        await tester.ensureVisible(find.text('全选本页'));
        await tester.tap(find.text('全选本页'));
        await tester.pumpAndSettle();
        final actions = tester.getRect(
          find.byKey(const ValueKey('media-selection-actions')),
        );
        expect(actions.bottom, lessThanOrEqualTo(scenario.$1.height));
        expect(find.text('编辑并打标').hitTestable(), findsOneWidget);
        await tester.tap(find.text('清空全部'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('组合筛选'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('android-filter:raw:tag')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('AND  必须有'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('media-active-filters')),
          findsOneWidget,
        );
        expect(find.text('清空筛选').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('清空筛选'));
        await tester.pumpAndSettle();
      }

      // Verify navigation after the small-screen/large-font layout checks.
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpWidget(
        MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('[tag]first.png'));
      await tester.pump();
      expect(find.textContaining('已选 1'), findsWidgets);
      await tester.tap(find.byTooltip('使用指南'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<UsageGuidePage>(find.byType(UsageGuidePage)).assetPath,
        UsageGuidePage.androidAssetPath,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 1'), findsWidgets);
      await tester.tap(find.byTooltip('配置与标签组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关于图签'));
      await tester.pumpAndSettle();
      expect(find.text('Image Tag Manager'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 1'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sorting restores preference, changes locally and keeps selection',
    (tester) async {
      var queries = 0;
      String? saved;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'loadImageSort':
            return 'nameAscending';
          case 'saveImageSort':
            saved = (call.arguments as Map)['value'] as String;
            return null;
          case 'permissionState':
            return 'full';
          case 'listAlbums':
            return [
              {'id': 'a', 'name': 'Pictures/A/', 'count': 2},
            ];
          case 'listAllImages':
          case 'listImages':
            queries++;
            return [
              {'id': 1, 'name': '图10.png', 'album': 'a', 'createdTime': 200},
              {'id': 2, 'name': '图2.png', 'album': 'a', 'createdTime': 100},
            ];
          case 'thumbnail':
            return pixel;
          default:
            throw MissingPluginException(call.method);
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
      );
      await tester.pumpAndSettle();
      expect(find.text('排序：文件名 · 升序 ▾'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('图2.png')).dx,
        lessThan(tester.getTopLeft(find.text('图10.png')).dx),
      );
      await tester.tap(find.text('图2.png'));
      await tester.pump();
      final before = queries;
      await tester.tap(find.text('排序：文件名 · 升序 ▾'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('文件名 · 降序'),
          matching: find.byWidgetPredicate(
            (widget) => widget is CheckedPopupMenuItem,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(saved, 'nameDescending');
      expect(queries, before);
      expect(find.textContaining('已选 1'), findsWidgets);
      expect(
        tester.getTopLeft(find.text('图10.png')).dx,
        lessThan(tester.getTopLeft(find.text('图2.png')).dx),
      );
    },
  );

  testWidgets(
    'removed creation preference falls back to modification and menu has four choices',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'loadImageSort':
            return 'createdNewest';
          case 'saveImageSort':
            return null;
          case 'permissionState':
            return 'full';
          case 'listAlbums':
            return [
              {'id': 'a', 'name': 'Pictures/A/', 'count': 2},
            ];
          case 'listAllImages':
          case 'listImages':
            return [
              {'id': 1, 'name': '图10.png', 'album': 'a', 'createdTime': 200},
              {'id': 2, 'name': '图2.png', 'album': 'a', 'createdTime': 100},
            ];
          case 'thumbnail':
            return pixel;
          default:
            throw MissingPluginException(call.method);
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
      );
      await tester.pumpAndSettle();
      expect(find.text('排序：修改时间 · 最新优先 ▾'), findsOneWidget);
      await tester.tap(find.text('排序：修改时间 · 最新优先 ▾'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((widget) => widget is CheckedPopupMenuItem),
        findsNWidgets(4),
      );
      expect(find.textContaining('创建时间'), findsNothing);
    },
  );

  testWidgets(
    'preparing edit reports progress and cancel preserves selection without opening editor or writing',
    (tester) async {
      final root = Directory('temp').absolute.createTempSync('prepare_cancel_');
      addTearDown(() => root.deleteSync(recursive: true));
      const native = MethodChannel('image_tag_manager/android_safe_rename');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final pending = Completer<List<Map<String, Object>>>();
      String? requestId;
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'entries') {
          requestId = (call.arguments as Map)['requestId'] as String;
          return pending.future;
        }
        if (call.method == 'cancelPreparation') {
          pending.completeError(
            PlatformException(code: 'preparation_cancelled'),
          );
          return null;
        }
        throw StateError('Unexpected operation before editor: ${call.method}');
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'permissionState':
            return 'full';
          case 'listAlbums':
            return [
              {'id': 'a', 'name': 'Pictures/A/', 'count': 1},
            ];
          case 'listAllImages':
          case 'listImages':
            return [
              {'id': 1, 'name': 'a.png', 'album': 'a'},
            ];
          case 'thumbnail':
            return pixel;
          default:
            throw MissingPluginException(call.method);
        }
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(native, null);
        messenger.setMockMethodCallHandler(channel, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AndroidMediaProbePage(
            groupStore: _MemoryStore(),
            renameService: RenameService(
              port: const AndroidRenamePort(),
              store: RenameTransactionStore(root),
            ),
          ),
        ),
      );
      for (
        var attempt = 0;
        attempt < 100 && find.text('a.png').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('a.png'));
      await tester.pump();
      await tester.tap(find.text('编辑并打标'));
      await tester.pump();
      expect(find.text('正在准备编辑 0/1 张'), findsOneWidget);
      tester.binding.channelBuffers.push(
        'image_tag_manager/android_safe_rename',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('entryPreparationProgress', {
            'requestId': requestId,
            'done': 1,
            'total': 1,
          }),
        ),
        (_) {},
      );
      await tester.pump();
      expect(find.text('正在准备编辑 1/1 张'), findsOneWidget);
      await tester.tap(find.text('取消准备'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);
      expect(find.text('编辑 1 张图片的文件名'), findsNothing);
      expect(root.listSync(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final sameDirectory in [true, false]) {
    testWidgets(
      'album aliases use real parent identity before edit; same=$sameDirectory',
      (tester) async {
        final root = Directory('temp').absolute
            .createTempSync('album_alias_ui_');
        addTearDown(() => root.deleteSync(recursive: true));
        final rows = [
          {
            'id': 1,
            'name': 'a.png',
            'album': 'a',
            'path': '/storage/emulated/0/Pictures/HeyBox/a.png',
            'fileId': 'v@27:100:27:201:78:1:0',
          },
          {
            'id': 2,
            'name': 'b.png',
            'album': 'a',
            'path': '/storage/emulated/0/pictures/heybox/b.png',
            'fileId': sameDirectory
                ? 'v@27:100:27:202:78:1:0'
                : 'v@27:101:27:202:78:1:0',
          },
        ];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'permissionState':
              return 'full';
            case 'listAlbums':
              return [
                {'id': 'a', 'name': 'Pictures/HeyBox/', 'count': 2},
              ];
            case 'listAllImages':
            case 'listImages':
              return rows;
            case 'thumbnail':
              return pixel;
            default:
              throw MissingPluginException(call.method);
          }
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.pumpWidget(
          MaterialApp(
            home: AndroidMediaProbePage(
              groupStore: _MemoryStore(),
              renameService: RenameService(
                port: const AndroidRenamePort(),
                store: RenameTransactionStore(root),
              ),
            ),
          ),
        );
        for (
          var attempt = 0;
          attempt < 100 && find.textContaining('本文件夹 2/2').evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选本页'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑并打标'));
        await tester.pumpAndSettle();
        if (sameDirectory) {
          expect(find.text('编辑 2 张图片的文件名'), findsOneWidget);
          await tester.tap(find.text('取消'));
        } else {
          expect(find.textContaining('目录身份不同'), findsOneWidget);
          expect(find.text('编辑 2 张图片的文件名'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'independent original viewer keeps selection unchanged and releases private copy on return',
    (tester) async {
      var opens = 0;
      var closes = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'permissionState':
            return 'full';
          case 'listAlbums':
            return [
              {'id': 'a', 'name': 'Pictures/A/', 'count': 1},
            ];
          case 'listImages':
            return [
              {'id': 1, 'name': 'original.gif'},
            ];
          case 'listAllImages':
            return [
              {'id': 1, 'name': 'original.gif', 'album': 'a'},
            ];
          case 'thumbnail':
            return pixel;
          case 'openOriginalImage':
            opens++;
            return {
              'token': 'viewer',
              'path': File('test/fixtures/thumbnails/red.gif').absolute.path,
            };
          case 'closeOriginalImage':
            closes++;
            return null;
          default:
            throw MissingPluginException(call.method);
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/1 · 已选 0'), findsOneWidget);
      await tester.tap(find.byTooltip('查看原图'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(opens, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/1 · 已选 0'), findsOneWidget);
      expect(closes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'change bursts reconcile external names without clearing unchanged thumbnails or self-refreshing',
    (tester) async {
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var revision = '1';
      var name = 'old.jpg';
      var indexReads = 0;
      var thumbnailReads = 0;
      var invalidations = 0;
      var permissions = 'full';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'permissionState':
            return permissions;
          case 'mediaRevision':
            return revision;
          case 'invalidateMediaCache':
            invalidations++;
            return null;
          case 'listAlbums':
            return [
              {'id': 'a', 'name': 'Pictures/A/', 'count': 1},
              {'id': 'b', 'name': 'Pictures/B/', 'count': 1},
            ];
          case 'listAllImages':
            indexReads++;
            return [
              {'id': 1, 'name': name, 'album': 'a', 'changeToken': 'content-1'},
              {
                'id': 2,
                'name': 'b.jpg',
                'album': 'b',
                'changeToken': 'content-2',
              },
            ];
          case 'listImages':
            return [
              {'id': 1, 'name': name, 'changeToken': 'content-1'},
            ];
          case 'thumbnail':
            thumbnailReads++;
            return pixel;
        }
        throw MissingPluginException(call.method);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('old.jpg'));
      await tester.pump();
      void signal() => tester.binding.channelBuffers.push(
        'image_tag_manager/media_changes',
        const StandardMethodCodec().encodeSuccessEnvelope('changed'),
        (_) {},
      );
      revision = '2';
      name = '[tag]renamed.jpg';
      signal();
      signal();
      signal();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.text('[tag]renamed.jpg'), findsOneWidget);
      expect(find.textContaining('本文件夹 1/1 · 已选 0'), findsOneWidget);
      expect(indexReads, 2);
      expect(thumbnailReads, 1);
      expect(invalidations, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      signal();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(indexReads, 2);
      expect(invalidations, 1);
      // A missed notification is detected when selecting another directory.
      revision = '3';
      name = 'after-missed-event.jpg';
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B  1 张').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A  1 张').last);
      await tester.pumpAndSettle();
      expect(find.text('after-missed-event.jpg'), findsOneWidget);
      expect(indexReads, 3);
      permissions = 'denied';
      revision = '4';
      signal();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.text('after-missed-event.jpg'), findsNothing);
      expect(find.text('请授权照片访问'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final keepOtherAlbum in [true, false]) {
    testWidgets(
      'clearing selected export album drops its selection and rejects stale menu events; other=$keepOtherAlbum',
      (tester) async {
        var deleted = false;
        final refreshed = Completer<List<Map<String, Object>>>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              switch (call.method) {
                case 'permissionState':
                  return 'full';
                case 'mediaRevision':
                  return 'revision';
                case 'invalidateMediaCache':
                  return null;
                case 'listAlbums':
                  if (deleted) return refreshed.future;
                  return [
                    {
                      'id': 'exports',
                      'name': 'Pictures/TagQuickShare/',
                      'count': 2,
                    },
                    if (keepOtherAlbum)
                      {'id': 'main', 'name': 'Pictures/Main/', 'count': 1},
                  ];
                case 'listImages':
                  return (call.arguments as Map)['album'] == 'exports'
                      ? [
                          {'id': 2, 'name': 'old2.jpg'},
                          {'id': 3, 'name': 'old3.jpg'},
                        ]
                      : [
                          {'id': 1, 'name': 'main.jpg'},
                        ];
                case 'listAllImages':
                  return [
                    {'id': 2, 'name': 'old2.jpg', 'album': 'exports'},
                    {'id': 3, 'name': 'old3.jpg', 'album': 'exports'},
                    if (keepOtherAlbum)
                      {'id': 1, 'name': 'main.jpg', 'album': 'main'},
                  ];
                case 'thumbnail':
                  return pixel;
                case 'previewExportCleanup':
                  return {
                    'token': 'preview',
                    'excluded': 0,
                    'items': [
                      if (!deleted) ...[
                        {'id': 2, 'name': 'old2.jpg', 'size': 10},
                        {'id': 3, 'name': 'old3.jpg', 'size': 10},
                      ],
                    ],
                  };
                case 'deleteExportCopies':
                  deleted = true;
                  return {
                    'deleted': 2,
                    'deletedIds': [2, 3],
                    'issues': [],
                  };
              }
              throw MissingPluginException(call.method);
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        await tester.pumpWidget(
          MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
        );
        await tester.pumpAndSettle();
        final staleSelection = tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .onChanged!;
        await tester.tap(find.byTooltip('配置与标签组'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清理导出副本'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选可清理副本'));
        await tester.pump();
        await tester.tap(find.text('清理已选（2）'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除选中副本'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.byType(DropdownButton<String>),
              )
              .onChanged,
          isNull,
        );
        staleSelection('exports');
        await tester.pump();
        refreshed.complete([
          if (keepOtherAlbum)
            {'id': 'main', 'name': 'Pictures/Main/', 'count': 1},
        ]);
        await tester.pumpAndSettle();
        staleSelection('exports');
        await tester.pumpAndSettle();
        expect(find.text('old2.jpg'), findsNothing);
        if (keepOtherAlbum) {
          expect(
            tester
                .widget<DropdownButton<String>>(
                  find.byType(DropdownButton<String>),
                )
                .value,
            'main',
          );
          expect(find.text('main.jpg'), findsOneWidget);
        } else {
          expect(find.byType(DropdownButton<String>), findsNothing);
          expect(find.textContaining('全部 0/0 ·'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'cleanup return preserves browsing caches and patches only confirmed deletions',
    (tester) async {
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var albums = 0;
      var images = 0;
      var indexes = 0;
      var thumbnails = 0;
      var invalidations = 0;
      var deleted = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'permissionState':
                return 'full';
              case 'mediaRevision':
                return 'revision';
              case 'invalidateMediaCache':
                invalidations++;
                return null;
              case 'listAlbums':
                albums++;
                return [
                  {'id': 'main', 'name': 'Pictures/Main/', 'count': 1},
                  {
                    'id': 'exports',
                    'name': 'Pictures/TagQuickShare/',
                    'count': deleted ? 1 : 2,
                  },
                ];
              case 'listImages':
                images++;
                return [
                  {'id': 1, 'name': 'main.jpg'},
                ];
              case 'listAllImages':
                indexes++;
                return [
                  {'id': 1, 'name': 'main.jpg', 'album': 'main'},
                  if (!deleted)
                    {'id': 2, 'name': 'export.jpg', 'album': 'exports'},
                  {'id': 3, 'name': 'other.jpg', 'album': 'exports'},
                ];
              case 'thumbnail':
                thumbnails++;
                return pixel;
              case 'previewExportCleanup':
                return {
                  'token': 'preview',
                  'excluded': 0,
                  'items': [
                    if (!deleted) {'id': 2, 'name': 'export.jpg', 'size': 10},
                    {'id': 3, 'name': 'other.jpg', 'size': 10},
                  ],
                };
              case 'deleteExportCopies':
                deleted = true;
                return {
                  'deleted': 1,
                  'deletedIds': [2],
                  'issues': [],
                };
            }
            throw MissingPluginException(call.method);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('main.jpg'));
      await tester.pump();
      Future<void> open() async {
        await tester.tap(find.byTooltip('配置与标签组'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清理导出副本'));
        await tester.pumpAndSettle();
      }

      await open();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        [albums, images, indexes, thumbnails, invalidations],
        [1, 1, 1, 1, 0],
      );
      await open();
      await tester.tap(find.text('export.jpg'));
      await tester.pump();
      await tester.tap(find.text('清理已选（1）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中副本'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        [albums, images, indexes, thumbnails, invalidations],
        [2, 1, 1, 1, 1],
      );
      expect(find.textContaining('全部 2/2 ·'), findsOneWidget);
      expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'hidden directories clear selection, leave global counts and can be restored',
    (tester) async {
      tester.view.physicalSize = const Size(360, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final visibility = MemoryMediaVisibilityStore();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'permissionState':
                return 'full';
              case 'listAlbums':
                return [
                  {'id': 'game', 'name': 'Game/', 'count': 1},
                  {'id': 'photos', 'name': 'Pictures/', 'count': 1},
                ];
              case 'listAllImages':
                return [
                  {'id': 1, 'name': 'resource.png', 'album': 'game'},
                  {'id': 2, 'name': 'photo.png', 'album': 'photos'},
                ];
              case 'listImages':
                return (call.arguments as Map)['album'] == 'game'
                    ? [
                        {'id': 1, 'name': 'resource.png'},
                      ]
                    : [
                        {'id': 2, 'name': 'photo.png'},
                      ];
              case 'thumbnail':
                return pixel;
            }
            throw MissingPluginException(call.method);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AndroidMediaProbePage(
            groupStore: _MemoryStore(),
            visibilityStore: visibility,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全选全部文件夹匹配（2 张）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/1 · 已选 2'), findsOneWidget);
      for (final label in ['编辑并打标', '复制到公共相册']) {
        final rectangle = tester.getRect(find.text(label));
        expect(rectangle.left, greaterThanOrEqualTo(0));
        expect(rectangle.right, lessThanOrEqualTo(360));
      }
      await tester.tap(find.byTooltip('管理可见目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('visibility:game')));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/1 · 已选 0'), findsOneWidget);
      expect(find.byTooltip('全选全部文件夹匹配（1 张）'), findsOneWidget);
      expect(find.text('resource.png'), findsNothing);
      expect((await visibility.load()).single.id, 'game');
      await tester.tap(find.byTooltip('全选全部文件夹匹配（1 张）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);
      await tester.tap(find.byTooltip('管理可见目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部恢复'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('全选全部文件夹匹配（2 张）'), findsOneWidget);
      expect(await visibility.load(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Android media browser filters and selects without exporting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var exportCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'permissionState':
              return 'full';
            case 'listAlbums':
              return [
                {'name': 'Pictures/', 'count': 2},
              ];
            case 'listAllImages':
              return [
                {'id': 1, 'name': '[tag]first.jpg', 'album': 'Pictures/'},
                {'id': 2, 'name': 'second.jpg', 'album': 'Pictures/'},
              ];
            case 'listImages':
              return [
                {'id': 1, 'name': '[tag]first.jpg'},
                {'id': 2, 'name': 'second.jpg'},
              ];
            case 'thumbnail':
              return pixel;
            case 'requestExportPermission':
              return true;
            case 'exportImages':
              exportCalls++;
              return {'copied': 1, 'skipped': 0, 'issues': []};
          }
          throw MissingPluginException(call.method);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.textContaining('本文件夹 2/2 · 已选 0'), findsOneWidget);
    await tester.tap(find.text('组合筛选'));
    await tester.pumpAndSettle();
    expect(find.text('组合筛选'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('android-filter:raw:tag')));
    await tester.pumpAndSettle();
    expect(find.text('AND  必须有'), findsOneWidget);
    await tester.tap(find.text('AND  必须有'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/2 · 已选 0'), findsOneWidget);
    await tester.tap(find.text('组合筛选（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('android-filter:raw:tag')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NOT  必须无'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/2 · 已选 0'), findsOneWidget);
    expect(find.text('second.jpg'), findsOneWidget);
    await tester.tap(find.text('清空筛选'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 2/2 · 已选 0'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/2 · 已选 0'), findsOneWidget);
    await tester.tap(find.text('second.jpg'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/2 · 已选 1'), findsOneWidget);
    await tester.ensureVisible(find.text('复制到公共相册'));
    await tester.tap(find.text('复制到公共相册'));
    await tester.pumpAndSettle();
    expect(find.textContaining('原图不变'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(exportCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection survives album changes and exports both albums', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final exported = <int>[];
    final albumReads = <String, int>{};
    var thumbnailReads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'permissionState':
              return 'full';
            case 'listAlbums':
              return [
                {'name': 'Pictures/A/', 'count': 1},
                {'name': 'Pictures/B/', 'count': 1},
              ];
            case 'listAllImages':
              return [
                {'id': 1, 'name': 'first.jpg', 'album': 'Pictures/A/'},
                {'id': 2, 'name': 'second.jpg', 'album': 'Pictures/B/'},
              ];
            case 'listImages':
              final album = (call.arguments as Map)['album'] as String;
              albumReads.update(album, (count) => count + 1, ifAbsent: () => 1);
              return (call.arguments as Map)['album'] == 'Pictures/A/'
                  ? [
                      {'id': 1, 'name': 'first.jpg'},
                    ]
                  : [
                      {'id': 2, 'name': 'second.jpg'},
                    ];
            case 'thumbnail':
              thumbnailReads++;
              return pixel;
            case 'requestExportPermission':
              return true;
            case 'exportImages':
              exported.addAll(
                ((call.arguments as Map)['ids'] as List).cast<int>(),
              );
              return {'copied': 1, 'skipped': 0, 'issues': []};
          }
          throw MissingPluginException(call.method);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.text('first.jpg'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B  1 张').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);
    expect(find.text('已选 1 张 · 本目录 0 · 其他目录 1'), findsOneWidget);
    await tester.tap(find.text('second.jpg'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 2'), findsOneWidget);
    await tester.tap(find.text('清空本页'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);
    expect(find.text('已选 1 张 · 本目录 0 · 其他目录 1'), findsOneWidget);
    await tester.tap(find.text('second.jpg'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 2'), findsOneWidget);
    await tester.tap(find.text('清空全部'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 0'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A  1 张').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('first.jpg'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B  1 张').last);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 张 · 本目录 0 · 其他目录 1'), findsOneWidget);
    await tester.tap(find.text('second.jpg'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 2'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A  1 张').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B  1 张').last);
    await tester.pumpAndSettle();
    expect(albumReads, {'Pictures/A/': 1, 'Pictures/B/': 1});
    expect(thumbnailReads, 2);
    await tester.ensureVisible(find.text('复制到公共相册'));
    await tester.tap(find.text('复制到公共相册'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将 2 张图片复制'), findsOneWidget);
    await tester.tap(find.text('开始复制'));
    await tester.pumpAndSettle();
    expect(exported, [1, 2]);
    expect(find.textContaining('已处理 2 / 2 张'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'global filter counts and selects matching images across albums',
    (tester) async {
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'permissionState':
                return 'full';
              case 'listAlbums':
                return [
                  {'name': 'Pictures/A/', 'count': 2},
                  {'name': 'Pictures/B/', 'count': 2},
                ];
              case 'listAllImages':
                return [
                  {
                    'id': 1,
                    'name': '[shared]first.jpg',
                    'album': 'Pictures/A/',
                  },
                  {'id': 2, 'name': 'other.jpg', 'album': 'Pictures/A/'},
                  {
                    'id': 3,
                    'name': '[shared]third.jpg',
                    'album': 'Pictures/B/',
                  },
                  {
                    'id': 4,
                    'name': '[remote]fourth.jpg',
                    'album': 'Pictures/B/',
                  },
                ];
              case 'listImages':
                return (call.arguments as Map)['album'] == 'Pictures/A/'
                    ? [
                        {'id': 1, 'name': '[shared]first.jpg'},
                        {'id': 2, 'name': 'other.jpg'},
                      ]
                    : [
                        {'id': 3, 'name': '[shared]third.jpg'},
                        {'id': 4, 'name': '[remote]fourth.jpg'},
                      ];
              case 'thumbnail':
                return pixel;
            }
            throw MissingPluginException(call.method);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await tester.pumpWidget(
        MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('全部 4/4 ·'), findsOneWidget);
      await tester.tap(find.text('组合筛选'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('android-filter:raw:remote')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('android-filter:raw:shared')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AND  必须有'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/2 · 已选 0'), findsOneWidget);
      expect(find.textContaining('全部 2/4 ·'), findsOneWidget);
      expect(find.text('A'), findsWidgets);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('B  匹配 1/2 张'), findsOneWidget);
      await tester.tap(find.text('B  匹配 1/2 张').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/2 · 已选 0'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('全选全部文件夹匹配（2 张）'));
      await tester.tap(find.byTooltip('全选全部文件夹匹配（2 张）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/2 · 已选 2'), findsOneWidget);
      expect(find.text('已选 2 张 · 本目录 1 · 其他目录 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('global query failure keeps current album usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'permissionState':
              return 'full';
            case 'listAlbums':
              return [
                {'name': 'Pictures/', 'count': 1},
              ];
            case 'listImages':
              return [
                {'id': 1, 'name': 'first.jpg'},
              ];
            case 'listAllImages':
              throw PlatformException(
                code: 'query_failed',
                message: 'test failure',
              );
            case 'thumbnail':
              return pixel;
          }
          throw MissingPluginException(call.method);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(home: AndroidMediaProbePage(groupStore: _MemoryStore())),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('first.jpg'), findsOneWidget);
    expect(find.textContaining('全部目录匹配统计失败'), findsOneWidget);
    final globalButton = tester.widget<TextButton>(
      find.byKey(const ValueKey('select-all-media')),
    );
    expect(globalButton.onPressed, isNull);
    await tester.tap(find.text('first.jpg'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Android formal edit handles preview cancel, denied grant, execution and undo',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final root = Directory('temp').absolute.createTempSync('m43_page_');
      expect(root.path, startsWith(Directory('temp').absolute.path));
      addTearDown(() => root.deleteSync(recursive: true));
      final pictures = Directory(
        '${root.path}${Platform.pathSeparator}pictures',
      )..createSync();
      final source = File(
        '${pictures.path}${Platform.pathSeparator}sample.jpg',
      );
      source.writeAsStringSync('fixture-content');
      final identities = <String, String>{source.path: 'fixture-identity'};
      final store = RenameTransactionStore(
        Directory('${root.path}/transactions'),
      );
      const port = AndroidRenamePort();
      final service = RenameService(
        port: port,
        store: store,
        maxPathLength: null,
        maxFilenameBytes: 255,
      );
      var grant = false;
      var writes = 0;
      var fullIndexCalls = 0;
      final identityBatches = <List<int>>[];
      final refreshedPaths = <List<String>>[];
      const native = MethodChannel('image_tag_manager/android_safe_rename');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(native, (call) async {
        final args = call.arguments as Map;
        switch (call.method) {
          case 'entries':
            identityBatches.add(List<int>.from(args['ids'] as List));
            final path = identities.keys.single;
            return [
              {
                'id': 1,
                'name': File(path).uri.pathSegments.last,
                'path': path,
                'fileId': identities[path],
              },
            ];
          case 'identity':
            final path = args['path'] as String;
            if (!File(path).existsSync() || identities[path] == null) {
              throw PlatformException(code: 'missing');
            }
            return identities[path];
          case 'authorize':
            return grant;
          case 'refresh':
            refreshedPaths.add(List<String>.from(args['paths'] as List));
            return '';
          case 'rename':
            final from = args['source'] as String;
            final to = args['target'] as String;
            expect(identities[from], args['expectedId']);
            expect(File(to).existsSync(), isFalse);
            File(from).renameSync(to);
            identities[to] = identities.remove(from)!;
            writes++;
            return true;
        }
        throw MissingPluginException(call.method);
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        final path = identities.keys.single;
        final row = {
          'id': 1,
          'name': File(path).uri.pathSegments.last,
          'path': path,
        };
        switch (call.method) {
          case 'permissionState':
            return 'full';
          case 'listAlbums':
            return [
              {'name': 'Pictures/Test/', 'count': 1},
            ];
          case 'listAllImages':
            fullIndexCalls++;
            return [
              {...row, 'album': 'Pictures/Test/'},
            ];
          case 'listImages':
            return [row];
          case 'thumbnail':
            return pixel;
        }
        throw MissingPluginException(call.method);
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(native, null);
        messenger.setMockMethodCallHandler(channel, null);
      });
      Future<void> settleIO() async {
        for (var i = 0; i < 200; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: AndroidMediaProbePage(
            groupStore: _MemoryStore(),
            renameService: service,
          ),
        ),
      );
      await settleIO();
      await tester.tap(find.text('sample.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑并打标'));
      await tester.pumpAndSettle();
      final stem = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '主体文件名',
      );
      await tester.enterText(stem, 'renamed');
      await tester.tap(find.text('生成预演'));
      await settleIO();
      expect(find.text('文件名变更预演'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('编辑 1 张图片的文件名'), findsOneWidget);
      expect((tester.widget<TextField>(stem).controller!).text, 'renamed');
      expect(writes, 0);
      await tester.tap(find.text('生成预演'));
      await settleIO();
      await tester.tap(find.text('确认执行'));
      await settleIO();
      expect(find.text('操作已取消'), findsOneWidget);
      expect(writes, 0);
      expect(await tester.runAsync(store.pending), isEmpty);
      expect(source.readAsStringSync(), 'fixture-content');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);
      grant = true;
      await tester.tap(find.text('编辑并打标'));
      await tester.pumpAndSettle();
      await tester.enterText(stem, 'renamed');
      await tester.tap(find.text('生成预演'));
      await settleIO();
      await tester.tap(find.text('确认执行'));
      await settleIO();
      expect(find.text('文件名修改完成'), findsOneWidget);
      expect(writes, 2);
      expect(
        File('${pictures.path}/renamed.jpg').readAsStringSync(),
        'fixture-content',
      );
      expect(await tester.runAsync(store.pending), isEmpty);
      expect(await tester.runAsync(store.completed), hasLength(1));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('renamed.jpg'), findsOneWidget);
      await tester.tap(find.byTooltip('历史操作'));
      await settleIO();
      await tester.tap(find.textContaining('修改主体文件名'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销这批操作'));
      await settleIO();
      await tester.tap(find.text('确认执行'));
      await settleIO();
      expect(find.text('文件名修改完成'), findsOneWidget);
      expect(writes, 4);
      expect(refreshedPaths, hasLength(2));
      expect(
        refreshedPaths.every(
          (paths) => paths.length == 1 && !paths.single.contains('~itm-'),
        ),
        isTrue,
      );
      expect(
        fullIndexCalls,
        1,
        reason: 'Renames and undo update touched rows, without rebuilding the global index',
      );
      expect(identityBatches, isNotEmpty);
      expect(
        identityBatches.every((ids) => ids.length == 1 && ids.single == 1),
        isTrue,
      );
      expect(source.readAsStringSync(), 'fixture-content');
      expect(await tester.runAsync(store.completed), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android profile rename, export, and delete', (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final store = _MemoryStore();
    final originalId = store.profiles.activeId;
    String? exportedConfig;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'permissionState':
              return 'full';
            case 'listAlbums':
              return [
                {'name': 'Pictures/', 'count': 1},
              ];
            case 'listAllImages':
              return [
                {'id': 1, 'name': 'first.jpg', 'album': 'Pictures/'},
              ];
            case 'listImages':
              return [
                {'id': 1, 'name': 'first.jpg'},
              ];
            case 'thumbnail':
              return pixel;
            case 'exportConfig':
              exportedConfig = (call.arguments as Map)['contents'] as String;
              return true;
          }
          throw MissingPluginException(call.method);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      MaterialApp(home: AndroidMediaProbePage(groupStore: store)),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.text('first.jpg'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);

    await tester.tap(find.byTooltip('配置与标签组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名当前配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '我的配置');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(store.profiles.active.name, '我的配置');
    expect(store.profiles.activeId, originalId);
    expect(find.textContaining('本文件夹 1/1 · 已选 1'), findsOneWidget);

    await tester.tap(find.byTooltip('配置与标签组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出当前配置'));
    await tester.pumpAndSettle();
    expect(jsonDecode(exportedConfig!)['schemaVersion'], 2);
    expect(exportedConfig!.endsWith('\n'), isTrue);
    expect(store.profiles.active.name, '我的配置');

    await tester.tap(find.byTooltip('配置与标签组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除当前配置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('只删除这份标签组配置'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.profiles.active.name, '我的配置');

    await tester.tap(find.byTooltip('配置与标签组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除当前配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(store.profiles.profiles, hasLength(1));
    expect(store.profiles.active.name, '空配置');
    expect(store.profiles.activeId, isNot(originalId));
    expect(find.textContaining('本文件夹 1/1 · 已选 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _MemoryStore implements TagGroupStore {
  var profiles = TagGroupProfiles.initial(TagGroups(const []));
  @override
  Future<TagGroups> load() async => profiles.active.groups;
  @override
  Future<void> save(TagGroups groups) async {}
  @override
  Future<TagGroupProfiles> loadProfiles() async => profiles;
  @override
  Future<void> saveProfiles(TagGroupProfiles value) async {
    profiles = value;
  }
}
