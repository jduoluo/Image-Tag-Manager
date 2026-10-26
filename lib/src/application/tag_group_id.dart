import 'dart:math';

/// Creates opaque IDs for new config entries. Existing IDs are never rewritten.
final class TagGroupId {
  const TagGroupId._();

  static String name(Iterable<String> existingIds, {Random? random}) =>
      _generate('tg_', existingIds.toSet(), random ?? Random.secure());

  static String category(Iterable<String> existingIds, {Random? random}) =>
      _generate('tc_', existingIds.toSet(), random ?? Random.secure());

  static String _generate(String prefix, Set<String> existing, Random random) {
    while (true) {
      final first = random
          .nextInt(0x100000000)
          .toRadixString(16)
          .padLeft(8, '0');
      final second = random
          .nextInt(0x100000000)
          .toRadixString(16)
          .padLeft(8, '0');
      final id = '$prefix$first$second';
      if (!existing.contains(id)) return id;
    }
  }
}
