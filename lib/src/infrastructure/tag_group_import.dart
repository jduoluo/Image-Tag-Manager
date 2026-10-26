import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../domain/tag_group_config.dart';
import '../domain/tag_groups.dart';

/// Imports only the selected file. Some Android providers report size zero;
/// file_selector then supplies empty memory bytes despite a populated cache copy.
final class TagGroupImport {
  const TagGroupImport._();

  static Future<TagGroups> read(XFile selected) async {
    var bytes = await selected.readAsBytes();
    if (bytes.isEmpty && selected.path.isNotEmpty) {
      final cached = File(selected.path);
      if (await cached.exists()) bytes = await cached.readAsBytes();
    }
    if (bytes.isEmpty) {
      throw const FormatException('所选文件没有读到内容，请检查文件是否为空，或将文件保存到本机后重试。');
    }
    String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('配置文件不是 UTF-8 文本，请重新导出 JSON 配置。');
    }
    if (source.startsWith('\uFEFF')) source = source.substring(1);
    if (source.trim().isEmpty) {
      throw const FormatException('配置文件只有空白内容，请检查原文件或重新导出。');
    }
    Object? value;
    try {
      value = jsonDecode(source);
    } on FormatException {
      throw const FormatException('配置内容不是完整有效的 JSON，请检查原文件或重新导出。');
    }
    if (value is Map<String, dynamic>) {
      if (value.containsKey('profiles') && !value.containsKey('groups')) {
        throw const FormatException(
          '这是整份多配置存档。请在原软件中“导出当前配置”，再导入该单份 JSON；当前配置未改变。',
        );
      }
      if (value['schemaVersion'] != 1 && value['schemaVersion'] != 2) {
        throw const FormatException(
          '不支持此配置格式版本，当前支持 v1、v2 单份配置。请确认文件类型，或更新软件后再试。',
        );
      }
    }
    return TagGroupConfig.decode(source);
  }
}
