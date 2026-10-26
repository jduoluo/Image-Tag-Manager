import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/android_rename_probe.dart';
import 'package:image_tag_manager/src/presentation/android_rename_probe_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('image_tag_manager/m43_probe');
  const media = MethodChannel('image_tag_manager/android_media_probe');
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(media, null);
  });

  test(
    'cancelled authorization and missing results never report success',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      const probe = AndroidRenameProbe();
      expect(await probe.authorize('token'), isFalse);
      await expectLater(probe.prepare(1, 'x.png'), throwsStateError);
      await expectLater(probe.execute('token'), throwsStateError);
      await expectLater(probe.inspect(), throwsStateError);
    },
  );

  testWidgets(
    'test scope, authorization, confirmation and stale plans gate execution',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final calls = <String>[];
      var grant = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(media, (call) async {
        expect(call.method, 'listImages');
        expect((call.arguments as Map)['album'], AndroidRenameProbe.album);
        return [
          {'id': 7, 'name': 'sample.png'},
        ];
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'prepare':
            expect((call.arguments as Map)['id'], 7);
            return {'token': 'plan-token', 'details': '原名 sample.png'};
          case 'authorize':
            return grant;
          case 'execute':
            return '改名后已核对';
          case 'inspect':
            return '重启后的实际状态';
        }
        throw MissingPluginException();
      });
      await tester.pumpWidget(
        const MaterialApp(home: AndroidRenameProbePage()),
      );
      await tester.tap(find.text('读取测试相册'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('读取测试相册'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sample.png'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('预演并保存验证计划'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('请求本张副本的系统修改授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认后执行单张实验改名'));
      await tester.pumpAndSettle();
      expect(calls, ['prepare', 'authorize']);
      grant = true;
      await tester.tap(find.text('请求本张副本的系统修改授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认后执行单张实验改名'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls.where((value) => value == 'execute'), isEmpty);
      await tester.enterText(find.byType(TextField), 'changed.png');
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认后执行单张实验改名'));
      await tester.pumpAndSettle();
      expect(find.text('确认实验改名'), findsNothing);
      await tester.tap(find.text('预演并保存验证计划'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('请求本张副本的系统修改授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认后执行单张实验改名'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行测试'));
      await tester.pumpAndSettle();
      expect(calls.where((value) => value == 'execute').length, 1);
      expect(find.text('改名后已核对'), findsOneWidget);
      await tester.tap(find.text('确认后执行单张实验改名'));
      await tester.pumpAndSettle();
      expect(calls.where((value) => value == 'execute').length, 1);
      await tester.tap(find.text('核对验证记录（含重启后状态）'));
      await tester.pumpAndSettle();
      expect(find.text('重启后的实际状态'), findsOneWidget);
    },
  );
}
