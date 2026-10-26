import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/domain/rename_plan.dart';
import 'package:image_tag_manager/src/infrastructure/rename_transaction_store.dart';
import 'package:image_tag_manager/src/presentation/manual_closed_history_dialog.dart';

void main() {
  testWidgets('manual closure remains readable without a restore action', (
    tester,
  ) async {
    final record = ManuallyClosedRenameTransaction(
      const RenamePlan(
        id: 'itm-20260924080352085608-3bdaeff8',
        directory: 'D:\\test\\pictures',
        items: [
          RenamePlanItem(
            original: 'old.jpg',
            temporary: '~itm-test-0000.jpg',
            target: 'new.jpg',
            fileId: 'file-id',
            reason: 'test',
          ),
        ],
        unchanged: [],
        issues: [],
      ),
      true,
      DateTime(2026, 9, 24, 16, 45),
      '旧计划不再恢复',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ManualClosedHistoryDialog(records: [record])),
      ),
    );
    expect(find.textContaining('放弃处理'), findsOneWidget);
    expect(find.text('旧计划不再恢复'), findsOneWidget);
    await tester.tap(find.textContaining('放弃处理'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('事务 ID：itm-20260924080352085608-3bdaeff8'),
      findsOneWidget,
    );
    expect(find.text('old.jpg → new.jpg'), findsOneWidget);
    expect(find.text('计划临时名：~itm-test-0000.jpg'), findsOneWidget);
    expect(find.text('核对并继续处理'), findsNothing);
  });
}
