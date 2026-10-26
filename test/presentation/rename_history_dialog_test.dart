import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/domain/rename_plan.dart';
import 'package:image_tag_manager/src/presentation/rename_history_dialog.dart';
import 'package:image_tag_manager/src/presentation/rename_history_summary.dart';

RenamePlan _plan(
  List<(String, String)> names, {
  String id = 'itm-20260922122455988746-6c48a8d8',
  String reason = 'test',
}) => RenamePlan(
  id: id,
  directory: r'D:\pictures\demo',
  items: [
    for (var i = 0; i < names.length; i++)
      RenamePlanItem(
        original: names[i].$1,
        temporary: '~temp-$i.png',
        target: names[i].$2,
        fileId: '$i',
        reason: reason,
      ),
  ],
  unchanged: const [],
  issues: const [],
);

void main() {
  test('summarizes only uniform actual tag changes', () {
    expect(
      renameHistorySummary(
        _plan([('x.png', '[red][day1]x.png'), ('y.jpg', '[red][day1]y.jpg')]),
      ),
      '新增标签 day1、red',
    );
    expect(
      renameHistorySummary(
        _plan([('[red]x.png', 'x.png'), ('[red]y.jpg', 'y.jpg')]),
      ),
      '删除标签 red',
    );
    expect(renameHistorySummary(_plan([('[RED]x.png', '[red]x.png')])), '混合修改');
    expect(
      renameHistorySummary(
        _plan([('x.png', '[red]x.png'), ('y.jpg', '[blue]y.jpg')]),
      ),
      '混合修改',
    );
    expect(renameHistorySummary(_plan([('x.png', 'renamed.png')])), '修改主体文件名');
  });

  test('uses local batch time and directory name', () {
    final expected = DateTime.utc(2026, 9, 22, 12, 24, 55).toLocal();
    final time = renameHistoryTime('itm-20260922122455988746-6c48a8d8');
    expect(
      time,
      startsWith(
        '${expected.year}-${expected.month.toString().padLeft(2, '0')}',
      ),
    );
    expect(renameHistoryTime('legacy-id'), '时间未知');
    expect(renameHistoryDirectoryName(r'D:\pictures\demo'), 'demo');
  });

  test('marks a reverse transaction using its recorded source', () {
    final source = _plan([('[color]x.png', 'x.png')]);
    final reverse = _plan(
      [('x.png', '[color]x.png')],
      id: 'itm-20260922210000000000-12345678',
      reason: '撤销事务 ${source.id}',
    );
    expect(renameHistoryUndoSourceId(reverse), source.id);
    expect(
      renameHistoryDisplaySummary(reverse, {source.id: source}),
      '撤销「删除标签 color」',
    );
    expect(renameHistorySummary(reverse), '新增标签 color');
    expect(renameHistoryDisplaySummary(reverse, const {}), '撤销历史操作');
    expect(
      renameHistoryDisplaySummary(source, {source.id: source}),
      '删除标签 color',
    );
    final undoAgain = _plan(
      [('[color]x.png', 'x.png')],
      id: 'itm-20260922210100000000-87654321',
      reason: '撤销事务 ${reverse.id}',
    );
    expect(
      renameHistoryDisplaySummary(undoAgain, {reverse.id: reverse}),
      '撤销「新增标签 color」',
    );
  });

  test('does not treat inconsistent or ordinary reasons as undo', () {
    final ordinary = _plan([('x.png', '[color]x.png')]);
    expect(renameHistoryUndoSourceId(ordinary), isNull);
    final inconsistent = RenamePlan(
      id: 'itm-20260922210000000000-12345678',
      directory: ordinary.directory,
      items: [
        ordinary.items.first,
        const RenamePlanItem(
          original: 'y.png',
          temporary: '~temp-y.png',
          target: '[color]y.png',
          fileId: 'y',
          reason: '撤销事务 itm-other',
        ),
      ],
      unchanged: const [],
      issues: const [],
    );
    expect(renameHistoryUndoSourceId(inconsistent), isNull);
  });

  testWidgets('opens details before choosing undo', (tester) async {
    final plan = _plan([('[RED]x.png', '[red]x.png'), ('y.jpg', '[red]y.jpg')]);
    RenamePlan? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  selected = await showRenameHistory(context, [plan]),
              child: const Text('历史'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.textContaining('混合修改'), findsOneWidget);
    expect(find.text('x.png'), findsNothing);
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('[RED]x.png'), findsOneWidget);
    expect(find.text('→ [red]x.png'), findsOneWidget);
    expect(find.text('→ [red]y.jpg'), findsOneWidget);
    expect(find.text('撤销这批操作'), findsOneWidget);
    await tester.tap(find.text('撤销这批操作'));
    await tester.pumpAndSettle();
    expect(selected, same(plan));
  });

  testWidgets('reopens the same history detail after preview cancellation', (
    tester,
  ) async {
    final plan = _plan([('x.png', '[red]x.png')]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showRenameHistory(context, [plan], initialSelected: plan),
              child: const Text('历史'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('操作详情'), findsOneWidget);
    expect(find.text('撤销这批操作'), findsOneWidget);
    await tester.tap(find.byTooltip('返回历史列表'));
    await tester.pumpAndSettle();
    expect(find.textContaining('新增标签 red'), findsOneWidget);
  });

  testWidgets('shows undo source and actual change in details', (tester) async {
    final source = _plan([('[color]x.png', 'x.png')]);
    final reverse = _plan(
      [('x.png', '[color]x.png')],
      id: 'itm-20260922210000000000-12345678',
      reason: '撤销事务 ${source.id}',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRenameHistory(context, [reverse, source]),
              child: const Text('历史'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.textContaining('撤销「删除标签 color」'), findsOneWidget);
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('实际变更：新增标签 color'), findsOneWidget);
    expect(find.text('来源事务 ID：${source.id}'), findsOneWidget);
  });

  testWidgets('selects all completed records and confirms deletion', (
    tester,
  ) async {
    final first = _plan([('x.png', '[red]x.png')]);
    final second = _plan([
      ('y.png', '[blue]y.png'),
    ], id: 'itm-20260922210000000000-12345678');
    Set<String>? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRenameHistory(context, [
                first,
                second,
              ], onDelete: (ids) async => deleted = ids),
              child: const Text('历史'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除选中（2）'));
    await tester.pumpAndSettle();
    expect(deleted, isNull);
    expect(find.textContaining('撤销依据'), findsOneWidget);
    await tester.tap(find.text('删除记录'));
    await tester.pumpAndSettle();
    expect(deleted, {first.id, second.id});
    expect(find.text('暂无已完成的改名操作'), findsOneWidget);
  });
}
