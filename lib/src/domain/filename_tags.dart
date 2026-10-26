// 文件名标签协议版本 1 的纯逻辑，不读取或修改磁盘文件。

/// 解析后的文件名。标签保持原顺序、原大小写及历史重复项。
final class ParsedFilename {
  ParsedFilename(this.tags, this.stem, this.extension);

  final List<String> tags;
  final String stem;
  final String extension;

  /// 不做规范化，直接按原始标签、主体和扩展名重新拼接。
  String serialize() => '${tags.map((tag) => '[$tag]').join()}$stem$extension';

  /// 精确值已存在时不追加；其他历史标签保持不变。
  ParsedFilename addRawTag(String tag) {
    if (!isValidTag(tag)) throw ArgumentError.value(tag, 'tag');
    if (tags.contains(tag)) return this;
    return ParsedFilename([...tags, tag], stem, extension);
  }

  /// 删除所有精确匹配的片段，不影响其他标签或其顺序。
  ParsedFilename removeRawTag(String tag) => ParsedFilename(
    tags.where((value) => value != tag).toList(),
    stem,
    extension,
  );

  /// 只替换主体；平台文件名限制和目标冲突由文件系统层校验。
  ParsedFilename withStem(String newStem) {
    if (newStem.isEmpty) throw ArgumentError.value(newStem, 'newStem');
    return ParsedFilename(tags, newStem, extension);
  }
}

/// 判断历史标签片段是否符合协议语法；不施加新建标签的推荐字符集。
bool isValidTag(String value) {
  if (value.isEmpty || value.trim() != value) return false;
  for (final rune in value.runes) {
    if (rune == 0x5b ||
        rune == 0x5d ||
        rune == 0x2f ||
        rune == 0x5c ||
        rune < 0x20 ||
        (rune >= 0x7f && rune <= 0x9f)) {
      return false;
    }
  }
  return true;
}

/// 只解析文件名开头连续的合法 `[标签]`；异常片段及其后内容留在主体中。
ParsedFilename parseFilename(String filename) {
  final tags = <String>[];
  var offset = 0;
  while (offset < filename.length && filename.codeUnitAt(offset) == 0x5b) {
    final close = filename.indexOf(']', offset + 1);
    if (close < 0) break;
    final candidate = filename.substring(offset + 1, close);
    if (!isValidTag(candidate)) break;
    tags.add(candidate);
    offset = close + 1;
  }
  final remainder = filename.substring(offset);
  final dot = remainder.lastIndexOf('.');
  final hasExtension = dot > 0 && dot < remainder.length - 1;
  return ParsedFilename(
    tags,
    hasExtension ? remainder.substring(0, dot) : remainder,
    hasExtension ? remainder.substring(dot) : '',
  );
}
