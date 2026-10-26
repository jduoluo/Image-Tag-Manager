import 'dart:io';

/// Opens the parent folder with this file selected in Windows Explorer.
Future<void> revealFileInExplorer(String path) async {
  final file = File(path);
  if (!Platform.isWindows || !file.isAbsolute) {
    throw const FileSystemException('仅支持 Windows 本地文件');
  }
  if (!await file.exists()) {
    throw FileSystemException('图片文件已不存在', path);
  }
  await Process.start('explorer.exe', [
    '/select,',
    file.path,
  ], mode: ProcessStartMode.detached);
}
