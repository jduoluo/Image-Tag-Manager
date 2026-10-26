import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/application/directory_browser.dart';
import 'package:image_tag_manager/src/domain/filename_tags.dart';
import 'package:image_tag_manager/src/domain/rename_plan.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';
import 'package:image_tag_manager/src/presentation/rename_editor_dialog.dart';

ImageEntry _entry(String name) =>
    ImageEntry(id: name, filename: name, parsedFilename: parseFilename(name));

void main() {
  testWidgets(
    'numbered stem is opt-in, draft survives preview and disabling restores old stems',
    (tester) async {
      RenameEditorResult? result;
      RenameEditorDraft? draft;
      final selected = [_entry('z.JPG'), _entry('a.png')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: selected,
                      groups: TagGroups([]),
                      draft: draft,
                    ),
                  );
                  draft = result?.draft;
                },
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('batch-prefix')), findsNothing);
      await tester.tap(find.text('批量生成简短主体名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('batch-prefix')), '图_');
      await tester.enterText(find.byKey(const ValueKey('batch-start')), '8');
      await tester.enterText(find.byKey(const ValueKey('batch-padding')), '2');
      await tester.tap(find.text('生成预演'));
      await tester.pumpAndSettle();
      expect(result!.editsFor(selected)['a.png']!.stem, '图_08');
      expect(result!.editsFor(selected)['z.JPG']!.stem, '图_09');
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('batch-start')))
            .controller!
            .text,
        '8',
      );
      await tester.tap(find.text('批量生成简短主体名'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成预演'));
      await tester.pumpAndSettle();
      expect(
        result!.editsFor(selected).values.every((edit) => edit.stem == null),
        isTrue,
      );
    },
  );

  testWidgets('invalid numbering keeps editor open without creating a result', (
    tester,
  ) async {
    RenameEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: [_entry('a.png')],
                      groups: TagGroups([]),
                    ),
                  ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量生成简短主体名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('batch-start')), '-1');
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byType(RenameEditorDialog), findsOneWidget);
    expect(find.textContaining('编辑无效'), findsOneWidget);
  });

  testWidgets('restores editor inputs when reopening from preview', (
    tester,
  ) async {
    RenameEditorResult? result;
    RenameEditorDraft? draft;
    final selected = [_entry('[old]one.jpg')];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<RenameEditorResult>(
                  context: context,
                  builder: (_) => RenameEditorDialog(
                    selected: selected,
                    groups: TagGroups(const []),
                    draft: draft,
                  ),
                );
                draft = result?.draft;
              },
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '添加标签（不存在时新建标签名组；中英文逗号分隔）'),
      'new',
    );
    await tester.enterText(find.widgetWithText(TextField, '主体文件名'), 'renamed');
    await tester.tap(find.byKey(const ValueKey('remove-raw:old')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.widgetWithText(TextField, '添加标签（不存在时新建标签名组；中英文逗号分隔）'),
          )
          .controller!
          .text,
      'new',
    );
    expect(
      tester
          .widget<FilterChip>(find.byKey(const ValueKey('remove-raw:old')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '主体文件名'))
          .controller!
          .text,
      'renamed',
    );
  });

  testWidgets('single image accepts tag edit and individual stem', (
    tester,
  ) async {
    RenameEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: [_entry('one.jpg')],
                      groups: TagGroups(const []),
                    ),
                  ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('已选图片没有文件名前缀标签'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, '添加标签（不存在时新建标签名组；中英文逗号分隔）'),
      'RED，red',
    );
    await tester.enterText(find.widgetWithText(TextField, '主体文件名'), 'renamed');
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    expect(result?.created.map((group) => group.writeTag).toSet(), {
      'RED',
      'red',
    });
    expect(
      result?.created.every(
        (group) => RegExp(r'^tg_[0-9a-f]{16}$').hasMatch(group.id),
      ),
      isTrue,
    );
    expect(result?.edit.stem, 'renamed');
  });

  testWidgets('batch edit offers group changes without a shared stem', (
    tester,
  ) async {
    final groups = TagGroups([
      TagGroup(id: 'red', displayName: '红色', writeTag: 'red', aliases: ['red']),
    ]);
    RenameEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: [_entry('one.jpg'), _entry('two.jpg')],
                      groups: groups,
                    ),
                  ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '主体文件名'), findsNothing);
    await tester.tap(find.text('红色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    expect(result?.edit.addGroups, {'red'});
    expect(result?.edit.stem, isNull);
  });

  testWidgets(
    'raw removal chips come from selected filenames and affect only matches',
    (tester) async {
      RenameEditorResult? result;
      final selected = [_entry('[a][b]one.png'), _entry('[b][c]two.png')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await showDialog<RenameEditorResult>(
                      context: context,
                      builder: (_) => RenameEditorDialog(
                        selected: selected,
                        groups: TagGroups(const []),
                      ),
                    ),
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '删除原始标签（中英文逗号分隔）'), findsNothing);
      for (final raw in ['a', 'b', 'c']) {
        expect(find.byKey(ValueKey('remove-raw:$raw')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('remove-raw:a')));
      await tester.tap(find.byKey(const ValueKey('remove-raw:c')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成预演'));
      await tester.pumpAndSettle();
      expect(result?.edit.removeRaw, {'a', 'c'});
      expect(
        result!.edit
            .apply(selected.first.parsedFilename, result!.groups)
            .serialize(),
        '[b]one.png',
      );
      expect(
        result!.edit
            .apply(selected.last.parsedFilename, result!.groups)
            .serialize(),
        '[b]two.png',
      );
    },
  );

  testWidgets('alias chips show their group while keeping exact removal', (
    tester,
  ) async {
    final groups = TagGroups([
      TagGroup(
        id: 'test-group',
        displayName: 'test',
        writeTag: 'test1',
        aliases: ['test1', 'test2'],
      ),
    ]);
    RenameEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: [_entry('[test1][test2][unknown]one.jpg')],
                      groups: groups,
                    ),
                  ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('按原始写法删除（只删除点选的写法）'), findsOneWidget);
    expect(find.text('test1（test 组）'), findsOneWidget);
    expect(find.text('test2（test 组）'), findsOneWidget);
    expect(find.text('unknown'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('remove-raw:test1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    expect(result?.edit.removeRaw, {'test1'});
    expect(
      result!.edit
          .apply(
            parseFilename('[test1][test2][unknown]one.jpg'),
            result!.groups,
          )
          .serialize(),
      '[test2][unknown]one.jpg',
    );
  });

  testWidgets('group menu explains and removes all aliases', (tester) async {
    final groups = TagGroups([
      TagGroup(
        id: 'test-group',
        displayName: 'test',
        writeTag: 'test1',
        aliases: ['test1', 'test2'],
      ),
    ]);
    RenameEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: [_entry('[test1][test2][unknown]one.jpg')],
                      groups: groups,
                    ),
                  ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除本组全部写法'));
    await tester.pumpAndSettle();
    expect(find.text('test · 删除整组'), findsOneWidget);
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    expect(result?.edit.removeGroups, {'test-group'});
    expect(
      result!.edit
          .apply(
            parseFilename('[test1][test2][unknown]one.jpg'),
            result!.groups,
          )
          .serialize(),
      '[unknown]one.jpg',
    );
  });

  testWidgets('category only expands and shared member has one edit state', (
    tester,
  ) async {
    final groups = TagGroups(
      [
        TagGroup(
          id: 'work',
          displayName: '明日方舟',
          writeTag: 'mrfz',
          aliases: ['mrfz'],
        ),
        TagGroup(
          id: 'character',
          displayName: '能天使',
          writeTag: 'nts',
          aliases: ['nts'],
        ),
      ],
      categories: [
        TagCategory(
          id: 'one',
          displayName: '作品',
          defaultGroupId: 'work',
          memberGroupIds: ['work', 'character'],
        ),
        TagCategory(
          id: 'two',
          displayName: '角色',
          defaultGroupId: 'character',
          memberGroupIds: ['character'],
        ),
      ],
    );
    RenameEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: [_entry('one.jpg')],
                      groups: groups,
                    ),
                  ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('作品 · 类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('作品 · 类'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.ensureVisible(find.text('能天使'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('能天使'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('角色 · 类'));
    await tester.tap(find.text('角色 · 类'));
    await tester.pumpAndSettle();
    expect(find.text('默认标签：能天使 · 添加'), findsOneWidget);
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    expect(result?.edit.addGroups, {'character'});
  });

  testWidgets('input matching an alias reuses its tag group', (tester) async {
    final groups = TagGroups([
      TagGroup(
        id: 'work',
        displayName: '明日方舟',
        writeTag: 'mrfz',
        aliases: ['mrfz', '方舟'],
      ),
    ]);
    RenameEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: [_entry('one.jpg')],
                      groups: groups,
                    ),
                  ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '添加标签（不存在时新建标签名组；中英文逗号分隔）'),
      '方舟',
    );
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    expect(result?.created, isEmpty);
    expect(result?.edit.addGroups, {'work'});
  });

  testWidgets(
    'display-name match shows full aliases and asks which action to take',
    (tester) async {
      final groups = TagGroups([
        TagGroup(
          id: 'older',
          displayName: 'test',
          writeTag: 'test1',
          aliases: ['test1', 'test2', 'test3'],
        ),
      ]);
      RenameEditorResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await showDialog<RenameEditorResult>(
                      context: context,
                      builder: (_) => RenameEditorDialog(
                        selected: [_entry('one.jpg')],
                        groups: groups,
                      ),
                    ),
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '添加标签（不存在时新建标签名组；中英文逗号分隔）'),
        'test',
      );
      await tester.tap(find.text('生成预演'));
      await tester.pumpAndSettle();
      expect(find.text('发现同名标签名组'), findsOneWidget);
      expect(find.text('默认写入标签：test1'), findsOneWidget);
      expect(find.text('可识别写法（含默认写入）：test1、test2、test3'), findsOneWidget);
      await tester.tap(find.text('使用此组'));
      await tester.pumpAndSettle();
      expect(result?.created, isEmpty);
      expect(result?.edit.addGroups, {'older'});
    },
  );

  testWidgets('display-name match may still create a separate tag', (
    tester,
  ) async {
    final groups = TagGroups([
      TagGroup(
        id: 'older',
        displayName: 'test',
        writeTag: 'test1',
        aliases: ['test1'],
      ),
    ]);
    RenameEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<RenameEditorResult>(
                    context: context,
                    builder: (_) => RenameEditorDialog(
                      selected: [_entry('one.jpg')],
                      groups: groups,
                    ),
                  ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '添加标签（不存在时新建标签名组；中英文逗号分隔）'),
      'test',
    );
    await tester.tap(find.text('生成预演'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍新建独立标签'));
    await tester.pumpAndSettle();
    expect(result?.created.single.writeTag, 'test');
    expect(result?.edit.addGroups, {result!.created.single.id});
  });

  testWidgets('preview disables execution when collisions are listed', (
    tester,
  ) async {
    final plan = RenamePlan(
      id: 'example',
      directory: 'fixture',
      items: const [
        RenamePlanItem(
          original: 'a.jpg',
          temporary: 'temp.jpg',
          target: 'b.jpg',
          fileId: 'id',
          reason: 'test',
        ),
      ],
      unchanged: const [],
      issues: const ['目标被占用'],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRenamePreview(context, plan),
              child: const Text('预演'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('预演'));
    await tester.pumpAndSettle();
    expect(find.text('目标被占用'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认执行'))
          .onPressed,
      isNull,
    );
  });
}
