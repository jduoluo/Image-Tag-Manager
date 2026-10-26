import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/domain/tag_groups.dart';
import 'package:image_tag_manager/src/presentation/tag_group_editor.dart';

void main() {
  testWidgets('first newly typed category member becomes default', (
    tester,
  ) async {
    TagGroups? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TagGroupEditor(
                  groups: TagGroups(const []),
                  mode: TagGroupEditorMode.categories,
                  onSave: (next) async => saved = next,
                ),
              ),
              child: const Text('管理'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签类组'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '稳定 ID'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), '作品');
    await tester.enterText(
      find.widgetWithText(TextField, '添加新成员标签（中英文逗号分隔）'),
      '明日方舟，能天使',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final category = saved!.categories.single;
    expect(category.id, matches(RegExp(r'^tc_[0-9a-f]{16}$')));
    expect(
      saved!.all.every(
        (group) => RegExp(r'^tg_[0-9a-f]{16}$').hasMatch(group.id),
      ),
      isTrue,
    );
    expect(saved!.group(category.defaultGroupId!).writeTag, '明日方舟');
    expect(category.defaultGroupId, category.memberGroupIds.first);
    expect(find.textContaining('★ 明日方舟 · 能天使'), findsOneWidget);
  });

  testWidgets('tag name groups use compact chips and open their edit form', (
    tester,
  ) async {
    final groups = TagGroups([
      TagGroup(id: 'red', displayName: '红色', writeTag: 'red', aliases: ['red']),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TagGroupEditor(
                  groups: groups,
                  mode: TagGroupEditorMode.names,
                  onSave: (_) async {},
                ),
              ),
              child: const Text('管理'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsOneWidget);
    expect(tester.widget<InputChip>(find.byType(InputChip)).onDeleted, isNull);
    expect(find.textContaining('ID: red'), findsNothing);
    await tester.tap(find.text('红色'));
    await tester.pumpAndSettle();
    expect(find.text('编辑标签名组'), findsOneWidget);
    expect(find.text('内部 ID：red'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('cancelled deletion keeps the existing group and unsaved edits', (
    tester,
  ) async {
    final groups = TagGroups([
      TagGroup(id: 'red', displayName: '红色', writeTag: 'red', aliases: ['red']),
    ]);
    TagGroups? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TagGroupEditor(
                  groups: groups,
                  mode: TagGroupEditorMode.names,
                  onSave: (next) async => saved = next,
                ),
              ),
              child: const Text('管理'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('红色'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), '蓝色');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除标签名组“红色”？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('编辑标签名组'), findsOneWidget);
    expect(saved, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('红色'), findsOneWidget);
    expect(find.text('蓝色'), findsNothing);
  });

  testWidgets('confirmed deletion updates category members and defaults', (
    tester,
  ) async {
    final groups = TagGroups(
      [
        TagGroup(
          id: 'red',
          displayName: '红色',
          writeTag: 'red',
          aliases: ['red'],
        ),
        TagGroup(
          id: 'blue',
          displayName: '蓝色',
          writeTag: 'blue',
          aliases: ['blue'],
        ),
      ],
      categories: [
        TagCategory(
          id: 'mixed',
          displayName: '混合',
          defaultGroupId: 'red',
          memberGroupIds: ['red', 'blue'],
        ),
        TagCategory(
          id: 'single',
          displayName: '单色',
          defaultGroupId: 'red',
          memberGroupIds: ['red'],
        ),
      ],
    );
    TagGroups? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TagGroupEditor(
                  groups: groups,
                  mode: TagGroupEditorMode.names,
                  onSave: (next) async => saved = next,
                ),
              ),
              child: const Text('管理'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('红色'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), '未保存');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除标签名组“红色”？'), findsOneWidget);
    expect(find.textContaining('当前未保存的编辑内容不会生效'), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(saved?.all.map((group) => group.id), ['blue']);
    expect(saved?.categories.first.memberGroupIds, ['blue']);
    expect(saved?.categories.first.defaultGroupId, 'blue');
    expect(saved?.categories.last.memberGroupIds, isEmpty);
    expect(saved?.categories.last.defaultGroupId, isNull);
    expect(find.text('红色'), findsNothing);
    expect(find.text('未保存'), findsNothing);
  });

  testWidgets(
    'edit form omits default from other aliases and retains old write tag',
    (tester) async {
      final groups = TagGroups([
        TagGroup(
          id: 'legacy',
          displayName: '塔科夫',
          writeTag: 'TKF',
          aliases: ['tkf', '塔科夫', 'TKF'],
        ),
      ]);
      TagGroups? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => TagGroupEditor(
                    groups: groups,
                    mode: TagGroupEditorMode.names,
                    onSave: (next) async => saved = next,
                  ),
                ),
                child: const Text('管理'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('塔科夫'));
      await tester.pumpAndSettle();
      final aliases = tester.widget<TextField>(
        find.widgetWithText(TextField, '其他兼容写法（不含默认写入标签；中英文逗号分隔）'),
      );
      expect(aliases.controller!.text, 'tkf, 塔科夫');
      await tester.enterText(find.widgetWithText(TextField, '默认写入标签'), 'eft');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved!.all.single.aliases, {'tkf', '塔科夫', 'TKF', 'eft'});
      expect(saved!.all.single.id, 'legacy');
    },
  );

  testWidgets('category member input asks before duplicating a display name', (
    tester,
  ) async {
    final groups = TagGroups([
      TagGroup(
        id: 'older',
        displayName: 'test',
        writeTag: 'test1',
        aliases: ['test1', 'test2', 'test3'],
      ),
    ]);
    TagGroups? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TagGroupEditor(
                  groups: groups,
                  mode: TagGroupEditorMode.categories,
                  onSave: (next) async => saved = next,
                ),
              ),
              child: const Text('管理'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签类组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '显示名称'), '作品');
    await tester.enterText(
      find.widgetWithText(TextField, '添加新成员标签（中英文逗号分隔）'),
      'test',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('默认写入标签：test1'), findsOneWidget);
    expect(find.text('可识别写法（含默认写入）：test1、test2、test3'), findsOneWidget);
    await tester.tap(find.text('使用此组'));
    await tester.pumpAndSettle();
    expect(saved?.all, hasLength(1));
    expect(saved?.categories.single.memberGroupIds, ['older']);
  });

  testWidgets(
    'category can select and create members without changing filenames',
    (tester) async {
      TagGroups? saved;
      final groups = TagGroups([
        TagGroup(
          id: 'work',
          displayName: '明日方舟',
          writeTag: 'mrfz',
          aliases: ['mrfz'],
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => TagGroupEditor(
                    groups: groups,
                    onSave: (next) async => saved = next,
                    mode: TagGroupEditorMode.categories,
                  ),
                ),
                child: const Text('管理'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建标签类组'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '稳定 ID'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, '显示名称'), '明日方舟');
      expect(find.byType(FilterChip), findsOneWidget);
      expect(
        tester
            .getTopLeft(find.widgetWithText(TextField, '添加新成员标签（中英文逗号分隔）'))
            .dy,
        lessThan(
          tester.getTopLeft(find.widgetWithText(TextField, '搜索成员标签名组')).dy,
        ),
      );
      await tester.tap(find.byType(FilterChip));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '添加新成员标签（中英文逗号分隔）'),
        '能天使',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved?.categories.single.defaultGroupId, 'work');
      expect(
        saved?.categories.single.id,
        matches(RegExp(r'^tc_[0-9a-f]{16}$')),
      );
      expect(saved?.categories.single.memberGroupIds.first, 'work');
      expect(saved?.all.map((group) => group.writeTag), contains('能天使'));
      expect(find.textContaining('★ 明日方舟'), findsOneWidget);
    },
  );
}
