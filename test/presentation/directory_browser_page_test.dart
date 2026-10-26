import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/application/directory_browser.dart';
import 'package:image_tag_manager/src/application/rename_service.dart';
import 'package:image_tag_manager/src/domain/filename_tags.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';
import 'package:image_tag_manager/src/domain/tag_group_profiles.dart';
import 'package:image_tag_manager/src/infrastructure/local_tag_group_store.dart';
import 'package:image_tag_manager/src/infrastructure/rename_transaction_store.dart';
import 'package:image_tag_manager/src/infrastructure/windows_rename_port.dart';
import 'package:image_tag_manager/src/infrastructure/windows_image_copy.dart';
import 'package:image_tag_manager/src/presentation/directory_browser_page.dart';
import 'package:image_tag_manager/src/presentation/image_thumbnail.dart';
import 'package:image_tag_manager/src/presentation/usage_guide_page.dart';

final class _Chooser implements DirectoryChooser {
  @override
  Future<String?> chooseDirectory() async => 'fixture';
}

final class _Source implements ImageDirectorySource {
  _Source(this.stream);

  final Stream<ImageEntry> stream;

  @override
  Stream<String> listSubdirectories(String path) =>
      const Stream<String>.empty();

  @override
  Stream<ImageEntry> scanCurrentDirectory(String path) {
    expect(path, 'fixture');
    return stream;
  }
}

final class _MultiChooser implements DirectoryChooser {
  _MultiChooser(this.paths);
  final List<String> paths;
  var _next = 0;
  @override
  Future<String?> chooseDirectory() async =>
      _next < paths.length ? paths[_next++] : null;
}

final class _MultiSource implements ImageDirectorySource {
  _MultiSource(this.entries, {this.children = const {}});
  final Map<String, List<ImageEntry>> entries;
  final Map<String, List<String>> children;

  @override
  Stream<ImageEntry> scanCurrentDirectory(String path) =>
      Stream.fromIterable(entries[path] ?? const []);

  @override
  Stream<String> listSubdirectories(String path) =>
      Stream.fromIterable(children[path] ?? const []);
}

ImageEntry _at(String folder, String filename) => ImageEntry(
  id: '$folder/$filename',
  filename: filename,
  parsedFilename: parseFilename(filename),
  fileId: 'id',
);

Widget _multiApp(
  _MultiChooser chooser,
  _MultiSource source, {
  ImageCopyService? copyService,
  Future<String?> Function()? chooseCopyDestination,
  bool withRename = false,
}) => MaterialApp(
  home: DirectoryBrowserPage(
    browser: DirectoryBrowser(chooser: chooser, source: source),
    copyService: copyService ?? const ImageCopyService(WindowsImageCopyPort()),
    chooseCopyDestination: chooseCopyDestination,
    renameService: withRename
        ? RenameService(
            port: const WindowsRenamePort(),
            store: RenameTransactionStore(
              Directory('test/fixtures/missing_transactions'),
            ),
          )
        : null,
  ),
);

final class _GroupStore implements TagGroupStore {
  TagGroups current = TagGroups(const []);
  TagGroupProfiles? profiles;

  @override
  Future<TagGroups> load() async => current;

  @override
  Future<void> save(TagGroups groups) async => current = groups;

  @override
  Future<TagGroupProfiles> loadProfiles() async =>
      profiles ?? TagGroupProfiles.initial(current);

  @override
  Future<void> saveProfiles(TagGroupProfiles value) async {
    profiles = value;
    current = value.active.groups;
  }
}

Widget _app(
  Stream<ImageEntry> stream, {
  TagGroups? groups,
  TagGroupStore? store,
  ImageCopyService? copyService,
  Future<String?> Function()? chooseCopyDestination,
}) => MaterialApp(
  home: DirectoryBrowserPage(
    browser: DirectoryBrowser(chooser: _Chooser(), source: _Source(stream)),
    groups: groups,
    groupStore: store,
    copyService: copyService ?? const ImageCopyService(WindowsImageCopyPort()),
    chooseCopyDestination: chooseCopyDestination,
  ),
);

ImageEntry _entry(String filename) => ImageEntry(
  id: 'fixture/$filename',
  filename: filename,
  parsedFilename: parseFilename(filename),
);

Future<void> _setRole(
  WidgetTester tester,
  String identity,
  String label,
) async {
  await tester.tap(find.byKey(ValueKey('filter:$identity')));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining(label).last);
  await tester.pumpAndSettle();
}

final class _CopyPort implements ImageCopyPort {
  final targets = <String>[];
  @override
  Future<String> identity(String path) async => 'source-id';
  @override
  Future<void> copyNoReplace(
    String source,
    String target,
    String expectedId,
  ) async {
    targets.add(target);
  }
}

void main() {
  testWidgets(
    'Windows guide opens from toolbar and returns to current browser',
    (tester) async {
      await tester.pumpWidget(_app(const Stream<ImageEntry>.empty()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('使用指南'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<UsageGuidePage>(find.byType(UsageGuidePage)).assetPath,
        UsageGuidePage.windowsAssetPath,
      );
      expect(find.text('图签 Windows 版使用指南'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('选择图片文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tabs share filters but selection actions have page and all scopes',
    (tester) async {
      final copyPort = _CopyPort();
      final source = _MultiSource({
        'folder-a': [
          _at('folder-a', '[red]a.png'),
          _at('folder-a', '[blue]a.png'),
        ],
        'folder-b': [_at('folder-b', '[red]b.png')],
      });
      await tester.pumpWidget(
        _multiApp(
          _MultiChooser(['folder-a', 'folder-b']),
          source,
          copyService: ImageCopyService(copyPort),
          chooseCopyDestination: () async => r'C:\target',
        ),
      );
      await tester.tap(find.text('选择图片文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加图片文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('folder-a'), findsOneWidget);
      expect(find.text('folder-b'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('jump-to-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('folder-a（2）').last);
      await tester.pumpAndSettle();
      expect(find.text('[red]a.png'), findsOneWidget);
      await tester.tap(find.text('筛选标签'));
      await tester.pumpAndSettle();
      await _setRole(tester, 'raw:red', '必须有');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.textContaining('全部匹配 2 张'), findsOneWidget);
      await tester.tap(find.text('folder-a'));
      await tester.pumpAndSettle();
      expect(find.text('[red]a.png'), findsOneWidget);
      expect(find.text('[blue]a.png'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('select-all-filtered')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 1 张'), findsOneWidget);
      await tester.tap(find.text('folder-b'));
      await tester.pumpAndSettle();
      expect(find.text('[red]b.png'), findsOneWidget);
      expect(find.textContaining('已选 1 张'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select-all-folders')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 2 张'), findsOneWidget);
      await tester.tap(find.text('复制已选图片（2）'));
      await tester.pumpAndSettle();
      expect(
        copyPort.targets,
        containsAll([r'C:\target\[red]a.png', r'C:\target\[red]b.png']),
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空当前页选择'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 1 张'), findsOneWidget);
      await tester.tap(find.text('清空全部选择'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 0 张'), findsOneWidget);
    },
  );

  testWidgets(
    'zero-result tab remains and clearing filters affects every tab',
    (tester) async {
      final source = _MultiSource({
        'red-folder': [_at('red-folder', '[red]one.png')],
        'blue-folder': [_at('blue-folder', '[blue]two.png')],
      });
      await tester.pumpWidget(
        _multiApp(_MultiChooser(['red-folder', 'blue-folder']), source),
      );
      await tester.tap(find.text('选择图片文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加图片文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选标签'));
      await tester.pumpAndSettle();
      await _setRole(tester, 'raw:red', '必须有');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('blue-folder'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('tab-match:red-folder')))
            .data,
        '1',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('tab-match:blue-folder')))
            .data,
        '0',
      );
      expect(find.textContaining('显示 0 / 1 张'), findsOneWidget);
      expect(find.text('没有符合筛选条件的图片'), findsOneWidget);
      await tester.tap(find.text('清空筛选'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('tab-match:blue-folder')))
            .data,
        '1',
      );
      expect(find.text('[blue]two.png'), findsOneWidget);
      await tester.tap(find.text('red-folder'));
      await tester.pumpAndSettle();
      expect(find.text('[red]one.png'), findsOneWidget);
    },
  );

  testWidgets(
    'recursive folders become adjacent tabs and cross-folder rename is disabled',
    (tester) async {
      final source = _MultiSource(
        {
          'root': [_at('root', 'root.png')],
          'root/child': [_at('root/child', 'child.png')],
          'root/empty': [],
        },
        children: {
          'root': ['root/empty', 'root/child'],
        },
      );
      await tester.pumpWidget(
        _multiApp(_MultiChooser(['root']), source, withRename: true),
      );
      await tester.tap(find.text('选择图片文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recursive-source')));
      await tester.pumpAndSettle();
      expect(find.text('root'), findsOneWidget);
      expect(find.text('↳ child'), findsOneWidget);
      expect(find.text('↳ empty'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('select-all-filtered')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('↳ child'));
      await tester.pumpAndSettle();
      expect(find.text('child.png'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select-all-filtered')));
      await tester.pumpAndSettle();
      final rename = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('修改已选文件名（2）'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(rename.onPressed, isNull);
      expect(find.byTooltip('已选图片分属不同文件夹，请只选择同一文件夹的图片改名'), findsOneWidget);
      await tester.tap(find.text('清空当前页选择'));
      await tester.pumpAndSettle();
      final sameFolderRename = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('修改已选文件名（1）'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(sameFolderRename.onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('recursive-source')));
      await tester.pumpAndSettle();
      expect(find.text('↳ child'), findsNothing);
    },
  );

  testWidgets('removing a source keeps the other folder tab', (tester) async {
    final source = _MultiSource({
      'first': [_at('first', 'first.png')],
      'second': [_at('second', 'second.png')],
    });
    await tester.pumpWidget(
      _multiApp(_MultiChooser(['first', 'second']), source),
    );
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除当前来源'));
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);
    expect(find.text('first.png'), findsOneWidget);
  });

  testWidgets('overlapping recursive sources do not duplicate folder tabs', (
    tester,
  ) async {
    final source = _MultiSource(
      {
        'root': [_at('root', 'root.png')],
        'root/child': [_at('root/child', 'child.png')],
      },
      children: {
        'root': ['root/child'],
      },
    );
    await tester.pumpWidget(
      _multiApp(_MultiChooser(['root', 'root/child']), source),
    );
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recursive-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加图片文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('↳ child'), findsOneWidget);
    expect(find.text('该文件夹已在标签页中'), findsOneWidget);
  });

  testWidgets('copy result leaves the current image selected', (tester) async {
    final port = _CopyPort();
    await tester.pumpWidget(
      _app(
        Stream.value(_entry('one.png')),
        copyService: ImageCopyService(port),
        chooseCopyDestination: () async => r'C:\target',
      ),
    );
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('one.png'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制已选图片（1）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已复制 1 张'), findsOneWidget);
    expect(port.targets, [r'C:\target\one.png']);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1 张'), findsOneWidget);
  });

  testWidgets('view image opens without changing card selection', (
    tester,
  ) async {
    final path = File('test/fixtures/thumbnails/valid.png').absolute.path;
    final entry = ImageEntry(
      id: path,
      filename: 'valid.png',
      parsedFilename: parseFilename('valid.png'),
    );
    await tester.pumpWidget(_app(Stream.value(entry)));
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看原图'));
    await tester.pump();
    expect(find.byTooltip('返回图片列表'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('返回图片列表'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 0 张'), findsOneWidget);
  });

  testWidgets('creates a named empty profile and switches back', (
    tester,
  ) async {
    final store = _GroupStore();
    await tester.pumpWidget(
      _app(const Stream<ImageEntry>.empty(), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建空配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '手机标签');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(store.profiles!.profiles, hasLength(2));
    expect(store.profiles!.active.name, '手机标签');
    await tester.tap(find.text('配置 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('空配置'));
    await tester.pumpAndSettle();
    expect(store.profiles!.active.name, '空配置');
  });

  testWidgets('renaming a profile keeps its identity, filter and selection', (
    tester,
  ) async {
    final store = _GroupStore();
    store.profiles = TagGroupProfiles(
      profiles: [
        TagGroupProfile(id: 'one', name: '空配置', groups: TagGroups(const [])),
        TagGroupProfile(id: 'two', name: '已有配置', groups: TagGroups(const [])),
      ],
      activeId: 'one',
    );
    await tester.pumpWidget(
      _app(Stream.value(_entry('[red]one.png')), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'raw:red', '必须有');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('[red]one.png'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名当前配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '我的标签');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(store.profiles!.activeId, 'one');
    expect(store.profiles!.active.name, '我的标签');
    expect(store.profiles!.active.groups.all, isEmpty);
    expect(find.text('当前：我的标签'), findsOneWidget);
    expect(find.byKey(const ValueKey('active-filter:raw:red')), findsOneWidget);
    expect(find.textContaining('已选 1 张'), findsOneWidget);

    await tester.tap(find.text('配置 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名当前配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '已有配置');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(store.profiles!.active.name, '我的标签');
    expect(find.text('配置名称已存在'), findsOneWidget);
  });

  testWidgets('switching profiles resets filters and selection', (
    tester,
  ) async {
    final store = _GroupStore();
    store.profiles = TagGroupProfiles(
      profiles: [
        TagGroupProfile(id: 'one', name: '第一份', groups: TagGroups(const [])),
        TagGroupProfile(id: 'two', name: '第二份', groups: TagGroups(const [])),
      ],
      activeId: 'one',
    );
    await tester.pumpWidget(
      _app(Stream.value(_entry('[red]one.png')), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'raw:red', '必须有');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('[red]one.png'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二份'));
    await tester.pumpAndSettle();
    expect(store.profiles!.activeId, 'two');
    expect(find.byKey(const ValueKey('active-filter:raw:red')), findsNothing);
    expect(find.textContaining('已选 0 张'), findsOneWidget);
  });

  testWidgets('deleting the last profile leaves an empty active profile', (
    tester,
  ) async {
    final store = _GroupStore();
    await tester.pumpWidget(
      _app(const Stream<ImageEntry>.empty(), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置 ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除当前配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(store.profiles!.profiles, hasLength(1));
    expect(store.profiles!.active.groups.all, isEmpty);
    expect(find.text('当前：空配置'), findsOneWidget);
  });

  testWidgets('filter help explains all four modes', (tester) async {
    await tester.pumpWidget(_app(Stream.value(_entry('[red]one.png'))));
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();

    expect(find.text('red'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('filter-help')));
    await tester.pumpAndSettle();
    expect(find.text('AND（与）：图片必须包含全部 AND 项标签。'), findsOneWidget);
    expect(find.text('OR（或）：图片必须包含至少一个 OR 项标签。'), findsOneWidget);
    expect(find.text('NOT（非）：图片不能包含任何一个 NOT 项标签。'), findsOneWidget);
    expect(find.text('不参与：默认状态，该标签不影响筛选结果。'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('筛选模式说明'), findsNothing);
  });

  testWidgets('selected filter tiles use mode colors', (tester) async {
    await tester.pumpWidget(_app(Stream.value(_entry('[a][b][c]one.png'))));
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();

    Color? colorOf(String identity) {
      final button = tester.widget<OutlinedButton>(
        find.byKey(ValueKey('filter:$identity')),
      );
      return button.style?.backgroundColor?.resolve({});
    }

    expect(colorOf('raw:a'), isNull);
    await _setRole(tester, 'raw:a', '必须有');
    await _setRole(tester, 'raw:b', '任一有');
    await _setRole(tester, 'raw:c', '必须无');
    expect(colorOf('raw:a'), const Color(0xFFDDF3DE));
    expect(colorOf('raw:b'), const Color(0xFFDDEEFF));
    expect(colorOf('raw:c'), const Color(0xFFF9DFE1));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    final active = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('active-filter:raw:a')),
    );
    expect(active.style?.backgroundColor?.resolve({}), const Color(0xFFDDF3DE));
  });

  testWidgets('lists filename and raw tags after explicit selection', (
    tester,
  ) async {
    final entry = ImageEntry(
      id: 'fixture/[x]image.jpg',
      filename: '[x]image.jpg',
      parsedFilename: parseFilename('[x]image.jpg'),
    );
    await tester.pumpWidget(_app(Stream.value(entry)));
    expect(find.text('请选择一个文件夹开始浏览'), findsOneWidget);

    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('[x]image.jpg'), findsOneWidget);
    expect(find.text('[x]'), findsOneWidget);
    expect(find.text('找到 1 张图片'), findsOneWidget);
    expect(find.text('仅当前文件夹，不包含子文件夹'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ImageThumbnail), findsOneWidget);
  });

  testWidgets('reports scan failure without presenting an empty directory', (
    tester,
  ) async {
    await tester.pumpWidget(_app(Stream.error(FileSystemException('denied'))));
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();

    expect(find.textContaining('读取目录失败'), findsOneWidget);
    expect(find.text('当前文件夹没有找到支持格式的图片'), findsNothing);
  });

  testWidgets('cancel stops an ongoing scan', (tester) async {
    var cancelled = false;
    final controller = StreamController<ImageEntry>(
      onCancel: () {
        cancelled = true;
      },
    );
    await tester.pumpWidget(_app(controller.stream));
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('取消扫描'), findsOneWidget);
    await tester.tap(find.text('取消扫描'));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    expect(find.textContaining('扫描已取消'), findsOneWidget);
  });

  testWidgets('grid builds only cards near the visible area', (tester) async {
    final entries = List.generate(
      200,
      (index) => ImageEntry(
        id: 'fixture/image_$index.jpg',
        filename: 'image_$index.jpg',
        parsedFilename: parseFilename('image_$index.jpg'),
      ),
    );
    await tester.pumpWidget(_app(Stream.fromIterable(entries)));
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('找到 200 张图片'), findsOneWidget);
    expect(find.byType(ImageThumbnail).evaluate().length, lessThan(200));
  });

  testWidgets('combines required, any and excluded tags', (tester) async {
    final entries = [
      _entry('[red][square]one.png'),
      _entry('[red]two.png'),
      _entry('[blue][square]three.png'),
      _entry('[blue]four.png'),
      _entry('plain.png'),
      _entry('[RED]upper.png'),
    ];
    await tester.pumpWidget(_app(Stream.fromIterable(entries)));
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 6 / 6 张'), findsOneWidget);

    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'raw:square', '必须有');
    await _setRole(tester, 'raw:red', '任一有');
    await _setRole(tester, 'raw:blue', '任一有');
    await _setRole(tester, 'raw:blue', '必须无');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.textContaining('显示 1 / 6 张'), findsOneWidget);
    expect(find.text('[red][square]one.png'), findsOneWidget);
    expect(find.text('[blue][square]three.png'), findsNothing);
    expect(find.text('[RED]upper.png'), findsNothing);
    expect(
      find.byKey(const ValueKey('active-filter:raw:square')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('active-filter:raw:red')), findsOneWidget);
  });

  testWidgets('changing filters clears selected images', (tester) async {
    await tester.pumpWidget(
      _app(Stream.fromIterable([_entry('[red]one.png'), _entry('plain.png')])),
    );
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('[red]one.png'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1 张'), findsOneWidget);

    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'raw:red', '必须无');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 1 / 2 张 · 已选 0 张'), findsOneWidget);
    expect(find.text('plain.png'), findsOneWidget);
  });

  testWidgets(
    'untagged shortcut clears conditions and selection, then selects its results',
    (tester) async {
      await tester.pumpWidget(
        _app(
          Stream.fromIterable([
            _entry('[red]one.png'),
            _entry('plain.png'),
            _entry('name[tag].png'),
            _entry('[unknown]other.png'),
          ]),
        ),
      );
      await tester.tap(find.text('选择图片文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选标签'));
      await tester.pumpAndSettle();
      await _setRole(tester, 'raw:red', '必须有');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('[red]one.png'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('untagged-filter')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('active-filter:raw:red')), findsNothing);
      expect(find.textContaining('显示 2 / 4 张 · 已选 0 张'), findsOneWidget);
      expect(find.text('plain.png'), findsOneWidget);
      expect(find.text('name[tag].png'), findsOneWidget);
      expect(find.text('[unknown]other.png'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('select-all-filtered')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 2 张'), findsOneWidget);

      await tester.tap(find.text('筛选标签'));
      await tester.pumpAndSettle();
      await _setRole(tester, 'raw:red', '必须有');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('untagged-filter')))
            .selected,
        isFalse,
      );
      expect(find.textContaining('显示 1 / 4 张 · 已选 0 张'), findsOneWidget);
    },
  );

  testWidgets('untagged shortcut works when no tag options exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(Stream.fromIterable([_entry('one.png'), _entry('two.png')])),
    );
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '筛选标签'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('untagged-filter')));
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 2 / 2 张'), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(find.byKey(const ValueKey('untagged-filter')))
          .selected,
      isTrue,
    );
  });

  testWidgets('active filter can change mode and be removed on main page', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(Stream.fromIterable([_entry('[red]one.png'), _entry('plain.png')])),
    );
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'raw:red', '必须有');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.textContaining('显示 1 / 2 张'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('active-filter:raw:red')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('必须无').last);
    await tester.pumpAndSettle();
    expect(find.text('plain.png'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('active-filter:raw:red')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('不参与').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('active-filter:raw:red')), findsNothing);
    expect(find.textContaining('显示 2 / 2 张'), findsOneWidget);
  });

  testWidgets('known aliases share one filter choice', (tester) async {
    final groups = TagGroups([
      TagGroup(
        id: 'red',
        displayName: '红色',
        writeTag: 'red',
        aliases: ['red', 'RED'],
      ),
    ]);
    await tester.pumpWidget(
      _app(
        Stream.fromIterable([_entry('[red]one.png'), _entry('[RED]two.png')]),
        groups: groups,
      ),
    );
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();

    expect(find.text('红色'), findsOneWidget);
    expect(find.byKey(const ValueKey('filter:group:red')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('filter:group:red')));
    await tester.pumpAndSettle();
    expect(find.text('同组别名（2）'), findsOneWidget);
    expect(find.text('red · RED'), findsOneWidget);
    await tester.tap(find.textContaining('不参与').last);
    await tester.pumpAndSettle();
    await _setRole(tester, 'group:red', '必须有');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 2 / 2 张'), findsOneWidget);
  });

  testWidgets('select all includes offscreen filtered images and toggles off', (
    tester,
  ) async {
    final entries = List.generate(
      200,
      (index) =>
          _entry(index.isEven ? '[red]image_$index.jpg' : 'image_$index.jpg'),
    );
    await tester.pumpWidget(_app(Stream.fromIterable(entries)));
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'raw:red', '必须有');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final box = find.byKey(const ValueKey('select-all-filtered'));
    expect(tester.widget<Checkbox>(box).value, false);
    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 100 张'), findsOneWidget);
    expect(tester.widget<Checkbox>(box).value, true);
    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 0 张'), findsOneWidget);
  });

  testWidgets('partial selection shows mixed checkbox then selects all', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(Stream.fromIterable([_entry('one.jpg'), _entry('two.jpg')])),
    );
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('one.jpg'));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('select-all-filtered'));
    expect(tester.widget<Checkbox>(box).value, isNull);
    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(box).value, true);
  });

  testWidgets('select all waits for scan completion', (tester) async {
    final controller = StreamController<ImageEntry>();
    await tester.pumpWidget(_app(controller.stream));
    await tester.tap(find.text('选择图片文件夹'));
    controller.add(_entry('one.jpg'));
    await tester.pump(const Duration(milliseconds: 120));
    final box = find.byKey(const ValueKey('select-all-filtered'));
    expect(tester.widget<Checkbox>(box).onChanged, isNull);
    await controller.close();
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(box).onChanged, isNotNull);
  });

  testWidgets('creates a group and uses its display name for existing alias', (
    tester,
  ) async {
    final store = _GroupStore();
    await tester.pumpWidget(
      _app(Stream.value(_entry('[RED]one.png')), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('标签名组'), findsOneWidget);
    expect(find.text('标签类组'), findsOneWidget);
    await tester.tap(find.text('标签名组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签名组'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '稳定 ID'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), '红色');
    await tester.enterText(find.widgetWithText(TextField, '默认写入标签'), 'red');
    await tester.enterText(
      find.widgetWithText(TextField, '其他兼容写法（不含默认写入标签；中英文逗号分隔）'),
      'RED，red',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final generatedId = store.current.all.single.id;
    expect(generatedId, matches(RegExp(r'^tg_[0-9a-f]{16}$')));
    expect(store.current.identity('RED'), 'group:$generatedId');
    expect(store.current.all.single.aliases, {'RED', 'red'});
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('[红色]'), findsOneWidget);
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('filter:group:$generatedId')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter:raw:RED')), findsNothing);
  });

  testWidgets('group save keeps untagged filter but clears image selection', (
    tester,
  ) async {
    final store = _GroupStore();
    await tester.pumpWidget(
      _app(Stream.value(_entry('plain.png')), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('untagged-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('plain.png'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签名组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签名组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), '红色');
    await tester.enterText(find.widgetWithText(TextField, '默认写入标签'), 'red');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(find.byKey(const ValueKey('untagged-filter')))
          .selected,
      isTrue,
    );
    expect(find.textContaining('显示 1 / 1 张 · 已选 0 张'), findsOneWidget);
  });

  testWidgets('group save migrates a raw filter to its new group', (
    tester,
  ) async {
    final store = _GroupStore();
    await tester.pumpWidget(
      _app(Stream.value(_entry('[RED]one.png')), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'raw:RED', '必须有');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('[RED]one.png'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签名组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签名组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), '红色');
    await tester.enterText(find.widgetWithText(TextField, '默认写入标签'), 'red');
    await tester.enterText(
      find.widgetWithText(TextField, '其他兼容写法（不含默认写入标签；中英文逗号分隔）'),
      'RED',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    final id = store.current.all.single.id;
    expect(find.byKey(const ValueKey('active-filter:raw:RED')), findsNothing);
    expect(find.byKey(ValueKey('active-filter:group:$id')), findsOneWidget);
    expect(find.textContaining('显示 1 / 1 张 · 已选 0 张'), findsOneWidget);
  });

  testWidgets('conflicting migrated modes are cleared with a warning', (
    tester,
  ) async {
    final store = _GroupStore();
    await tester.pumpWidget(
      _app(Stream.value(_entry('[a][b]one.png')), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'raw:a', '必须有');
    await _setRole(tester, 'raw:b', '必须无');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签名组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签名组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), '同组');
    await tester.enterText(find.widgetWithText(TextField, '默认写入标签'), 'a');
    await tester.enterText(
      find.widgetWithText(TextField, '其他兼容写法（不含默认写入标签；中英文逗号分隔）'),
      'b',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已清除 2 项条件'), findsOneWidget);
    expect(find.byKey(const ValueKey('active-filter:raw:a')), findsNothing);
    expect(find.byKey(const ValueKey('active-filter:raw:b')), findsNothing);
    expect(find.textContaining('显示 1 / 1 张'), findsOneWidget);
  });

  testWidgets('deleted group with split aliases clears ambiguous filter', (
    tester,
  ) async {
    final store = _GroupStore()
      ..current = TagGroups([
        TagGroup(
          id: 'old',
          displayName: '旧组',
          writeTag: 'a',
          aliases: ['a', 'b'],
        ),
      ]);
    await tester.pumpWidget(
      _app(Stream.value(_entry('[a][b]one.png')), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'group:old', '必须有');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签名组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已清除 1 项条件'), findsOneWidget);
    expect(find.byKey(const ValueKey('active-filter:group:old')), findsNothing);
  });

  testWidgets('active group filter stays removable when its alias disappears', (
    tester,
  ) async {
    final store = _GroupStore()
      ..current = TagGroups([
        TagGroup(
          id: 'old',
          displayName: '旧组',
          writeTag: 'a',
          aliases: ['a', 'b'],
        ),
      ]);
    await tester.pumpWidget(
      _app(Stream.value(_entry('[b]one.png')), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选标签'));
    await tester.pumpAndSettle();
    await _setRole(tester, 'group:old', '必须有');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签名组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧组'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '其他兼容写法（不含默认写入标签；中英文逗号分隔）'),
      '',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 0 / 1 张'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('active-filter:group:old')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('active-filter:group:old')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('不参与').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('显示 1 / 1 张'), findsOneWidget);
  });
}
