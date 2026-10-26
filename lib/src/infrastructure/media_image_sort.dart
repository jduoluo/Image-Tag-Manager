import 'android_media_probe.dart';

enum MediaImageSort {
  modifiedNewest('修改时间 · 最新优先'),
  modifiedOldest('修改时间 · 最早优先'),
  nameAscending('文件名 · 升序'),
  nameDescending('文件名 · 降序');

  const MediaImageSort(this.label);
  final String label;

  int compare(MediaImage a, MediaImage b) {
    final byName = this == nameAscending || this == nameDescending;
    final descending = this == modifiedNewest || this == nameDescending;
    int result;
    if (byName) {
      result = naturalNameCompare(a.name, b.name);
    } else {
      final left = a.modifiedTime;
      final right = b.modifiedTime;
      // Unknown timestamps always follow known ones, in either direction.
      if ((left <= 0) != (right <= 0)) return left <= 0 ? 1 : -1;
      result = left.compareTo(right);
    }
    if (result != 0) return descending ? -result : result;
    // Stable secondary order, independent of provider row enumeration.
    return a.id.compareTo(b.id);
  }
}

int naturalNameCompare(String left, String right) {
  final parts = RegExp(r'[0-9]+|[^0-9]+');
  final a = parts.allMatches(left.toLowerCase()).map((m) => m[0]!).toList();
  final b = parts.allMatches(right.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < a.length && i < b.length; i++) {
    var x = a[i], y = b[i];
    if (RegExp(r'^[0-9]+$').hasMatch(x) && RegExp(r'^[0-9]+$').hasMatch(y)) {
      x = x.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
      y = y.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
      final length = x.length.compareTo(y.length);
      if (length != 0) return length;
    }
    final result = x.compareTo(y);
    if (result != 0) return result;
  }
  final count = a.length.compareTo(b.length);
  return count != 0 ? count : left.compareTo(right);
}
