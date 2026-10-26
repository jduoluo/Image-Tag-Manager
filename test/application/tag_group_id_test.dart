import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/application/tag_group_id.dart';

void main() {
  test('generates short opaque IDs and retries an existing one', () {
    final first = TagGroupId.name(const [], random: Random(7));
    final second = TagGroupId.name([first], random: Random(7));
    expect(first, matches(RegExp(r'^tg_[0-9a-f]{16}$')));
    expect(second, matches(RegExp(r'^tg_[0-9a-f]{16}$')));
    expect(second, isNot(first));
    expect(
      TagGroupId.category(const [], random: Random(7)),
      matches(RegExp(r'^tc_[0-9a-f]{16}$')),
    );
  });
}
