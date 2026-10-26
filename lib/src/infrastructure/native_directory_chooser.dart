import 'package:file_selector/file_selector.dart';

import '../application/directory_browser.dart';

/// 使用系统目录选择窗口；取消选择时返回 null。
final class NativeDirectoryChooser implements DirectoryChooser {
  const NativeDirectoryChooser();

  @override
  Future<String?> chooseDirectory() => getDirectoryPath();
}
