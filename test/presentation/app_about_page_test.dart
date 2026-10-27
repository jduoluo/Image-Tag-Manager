import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/app_information.dart';
import 'package:image_tag_manager/src/presentation/app_about_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('image_tag_manager/app_information');
  final calls = <MethodCall>[];
  var failOpen = false;

  setUp(() {
    calls.clear();
    failOpen = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'version') return '1.0.0+1';
          if (failOpen) throw PlatformException(code: 'open_failed');
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test(
    'native bridge rejects arbitrary addresses before platform invocation',
    () async {
      await expectLater(
        AppInformation.openUrl('file:///private.txt'),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );

  testWidgets('narrow about page opens and copies the exact project address', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    await tester.pumpWidget(const MaterialApp(home: AppAboutPage()));
    await tester.pumpAndSettle();
    expect(find.text('版本：1.0.0'), findsOneWidget);
    await tester.ensureVisible(find.text('打开项目主页'));
    await tester.tap(find.text('打开项目主页'));
    await tester.pumpAndSettle();
    expect(calls.last.arguments, AppInformation.repository);
    await tester.tap(find.text('复制项目主页地址'));
    await tester.pumpAndSettle();
    expect(copied, AppInformation.repository);
    expect(tester.takeException(), isNull);
    failOpen = true;
    await tester.tap(find.text('打开项目主页'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开浏览器，请复制地址后手动访问。'), findsOneWidget);
  });

  testWidgets('menu opens about and both offline license pages can return', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(appBar: null, body: AppAboutMenuButton()),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于图签'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('查看 GPL-3.0 完整许可'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('查看 GPL-3.0 完整许可'));
    await tester.pumpAndSettle();
    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('第三方开源许可'));
    await tester.tap(find.text('第三方开源许可'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AppAboutPage), findsOneWidget);
  });
}
