import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/application/rename_service.dart';
import 'package:image_tag_manager/src/domain/rename_plan.dart';
import 'package:image_tag_manager/src/presentation/directory_browser_page.dart';

void main() {
  const item = RenamePlanItem(
    original: 'old.jpg',
    temporary: '~itm-test-0000.jpg',
    target: 'new.jpg',
    fileId: 'file-id',
    reason: 'test',
  );

  testWidgets('unchanged result never claims a restoration', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RenameResultDialog(
            outcome: RenameOutcome('notChanged', '系统拒绝安全改名', 0, 1),
          ),
        ),
      ),
    );
    expect(find.text('未改名，文件保持原名'), findsOneWidget);
    expect(find.textContaining('已处理 0 / 1'), findsOneWidget);
    expect(find.text('已恢复原名'), findsNothing);
  });
  testWidgets('manual result shows the faulty item before offering safe work', (
    tester,
  ) async {
    final outcome = RenameOutcome(
      'manual',
      '发现 1 项异常；请逐项核对。',
      0,
      2,
      issues: const [
        '原名：old.jpg；计划临时名：~itm-test-0000.jpg；目标名：new.jpg；'
            '当前：无法确认；原因：文件缺失',
      ],
      canContinueSafe: true,
    );
    bool? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showDialog<bool>(
                  context: context,
                  builder: (_) => RenameResultDialog(
                    outcome: outcome,
                    statuses: const [RenameItemStatus(item, 'unknown')],
                    offerSafeContinuation: true,
                  ),
                );
              },
              child: const Text('打开结果'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开结果'));
    await tester.pumpAndSettle();
    expect(find.text('需要人工核对'), findsOneWidget);
    expect(find.textContaining('原因：文件缺失'), findsOneWidget);
    expect(find.textContaining('计划临时名：~itm-test-0000.jpg'), findsWidgets);
    expect(find.text('跳过异常项，继续安全项'), findsOneWidget);
    await tester.tap(find.text('跳过异常项，继续安全项'));
    await tester.pumpAndSettle();
    expect(selected, isTrue);
  });

  testWidgets('manual result hides safe continuation when none is available', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RenameResultDialog(
            outcome: RenameOutcome('manual', '没有安全项目', 0, 1),
            offerSafeContinuation: true,
          ),
        ),
      ),
    );
    expect(find.text('跳过异常项，继续安全项'), findsNothing);
  });
}
