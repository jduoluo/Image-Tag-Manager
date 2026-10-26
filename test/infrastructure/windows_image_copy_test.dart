import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/application/directory_browser.dart';
import 'package:image_tag_manager/src/domain/filename_tags.dart';
import 'package:image_tag_manager/src/infrastructure/windows_image_copy.dart';

final class _Port implements ImageCopyPort {
  final calls = <String>[];
  @override
  Future<String> identity(String path) async => 'identity';

  @override
  Future<void> copyNoReplace(
    String source,
    String target,
    String expectedId,
  ) async {
    calls.add('$source|$target|$expectedId');
    if (target.endsWith('exists.png')) {
      throw PlatformException(code: 'win32', message: '80');
    }
    if (target.endsWith('failed.png')) {
      throw PlatformException(code: 'win32', message: '5');
    }
  }
}

ImageEntry _entry(String name) => ImageEntry(
  id: 'C:\\source\\$name',
  filename: name,
  parsedFilename: parseFilename(name),
  fileId: 'identity',
);

void main() {
  test(
    'copy reports success, conflict and failure while retaining original names',
    () async {
      final port = _Port();
      final report = await ImageCopyService(port).copySelected([
        _entry('ok.png'),
        _entry('exists.png'),
        _entry('failed.png'),
      ], 'C:\\target');
      expect(report.copied, 1);
      expect(report.skipped, 1);
      expect(report.issues.length, 2);
      expect(port.calls, [
        'C:\\source\\ok.png|C:\\target\\ok.png|identity',
        'C:\\source\\exists.png|C:\\target\\exists.png|identity',
        'C:\\source\\failed.png|C:\\target\\failed.png|identity',
      ]);
    },
  );
}
