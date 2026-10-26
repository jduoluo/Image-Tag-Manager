import 'dart:io';

import 'package:flutter/material.dart';

import 'src/application/directory_browser.dart';
import 'src/application/rename_service.dart';
import 'src/infrastructure/local_image_directory_source.dart';
import 'src/infrastructure/native_directory_chooser.dart';
import 'src/infrastructure/local_tag_group_store.dart';
import 'src/infrastructure/rename_transaction_store.dart';
import 'src/infrastructure/windows_rename_port.dart';
import 'src/presentation/android_media_probe_page.dart';
import 'src/presentation/directory_browser_page.dart';
import 'src/presentation/guide_startup.dart';
import 'src/presentation/usage_guide_page.dart';
import 'src/infrastructure/guide_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 缩略图只保留有限的内存缓存，不在磁盘生成副本。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 * 1024 * 1024;
  final browser = DirectoryBrowser(
    chooser: const NativeDirectoryChooser(),
    source: LocalImageDirectorySource(
      identityPort: Platform.isWindows ? const WindowsRenamePort() : null,
    ),
  );
  runApp(
    ImageTagManagerApp(
      browser: browser,
      groupStore: Platform.isWindows
          ? LocalTagGroupStore(Platform.resolvedExecutable)
          : null,
      renameService: Platform.isWindows
          ? RenameService(
              port: const WindowsRenamePort(),
              store: RenameTransactionStore(
                Directory(
                  '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}config${Platform.pathSeparator}transactions',
                ),
              ),
            )
          : null,
    ),
  );
}

final class ImageTagManagerApp extends StatelessWidget {
  const ImageTagManagerApp({
    required this.browser,
    this.groupStore,
    this.renameService,
    super.key,
  });

  final DirectoryBrowser browser;
  final TagGroupStore? groupStore;
  final RenameService? renameService;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '图签',
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
    home: GuideStartup(
      preferences: LocalGuidePreferences(),
      assetPath: Platform.isAndroid
          ? UsageGuidePage.androidAssetPath
          : UsageGuidePage.windowsAssetPath,
      browserBuilder: (_) => Platform.isAndroid
          ? const AndroidMediaProbePage()
          : DirectoryBrowserPage(
              browser: browser,
              groupStore: groupStore,
              renameService: renameService,
            ),
    ),
  );
}
