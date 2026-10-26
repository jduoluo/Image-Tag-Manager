import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/android_media_probe.dart';
import 'package:image_tag_manager/src/infrastructure/media_image_sort.dart';

void main() {
  const images = [
    MediaImage(3, '图10.png', modifiedTime: 300),
    MediaImage(1, '图2.png', modifiedTime: 100),
    MediaImage(2, '图1.png', modifiedTime: 200),
  ];
  test('all four orders', () {
    final expected = [
      [3, 2, 1],
      [1, 2, 3],
      [2, 1, 3],
      [3, 1, 2],
    ];
    for (final (i, sort) in MediaImageSort.values.indexed) {
      final sorted = images.toList()..sort(sort.compare);
      expect(sorted.map((image) => image.id), expected[i], reason: sort.name);
    }
  });
  test('equal timestamps use stable IDs, rename does not move item', () {
    const a = MediaImage(1, 'z.png', modifiedTime: 100);
    const b = MediaImage(2, 'a.png', modifiedTime: 100);
    expect(MediaImageSort.modifiedNewest.compare(a, b), lessThan(0));
    expect(MediaImageSort.modifiedOldest.compare(a, b), lessThan(0));
  });
  test(
    'natural names handle large numbers, zeros and case deterministically',
    () {
      expect(naturalNameCompare('a2', 'a10'), lessThan(0));
      expect(
        naturalNameCompare('a99999999999999999999', 'a100000000000000000000'),
        lessThan(0),
      );
      expect(naturalNameCompare('a02', 'a2'), isNot(0));
      expect(naturalNameCompare('A2', 'a2'), isNot(0));
    },
  );
  test('bridge timestamps and unavailable legacy fields', () {
    expect(MediaImage.fromMap({'id': 1, 'name': 'a'}).modifiedTime, 0);
    final image = MediaImage.fromMap({
      'id': 1,
      'name': 'a',
      'modifiedTime': 456,
    });
    expect(image.modifiedTime, 456);
  });
}
