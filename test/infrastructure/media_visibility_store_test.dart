import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/android_media_probe.dart';
import 'package:image_tag_manager/src/infrastructure/media_visibility_store.dart';

void main() {
  const parent = MediaFolder('parent', 'Pictures/', volume: 'primary');
  const leaf = MediaFolder('leaf', 'Pictures/Game/', volume: 'primary');
  const album = MediaAlbum(
    'Pictures/Game/',
    31,
    id: 'leaf',
    volume: 'primary',
    folders: [parent, leaf],
  );
  test(
    'hidden ancestors exclude descendants while direct rules remain local',
    () {
      expect(
        const HiddenMediaFolder(id: 'parent', name: 'Pictures/').hides(album),
        isTrue,
      );
      expect(
        const HiddenMediaFolder(
          id: 'parent',
          name: 'Pictures/',
          includeChildren: false,
        ).hides(album),
        isFalse,
      );
      expect(
        const HiddenMediaFolder(
          id: 'leaf',
          name: 'pictures/game/',
        ).hides(album),
        isTrue,
      );
      expect(
        const HiddenMediaFolder(
          id: 'different',
          name: 'pictures/game/',
          volume: 'primary',
        ).hides(album),
        isFalse,
      );
      expect(
        const HiddenMediaFolder(
          id: 'different',
          name: 'Pictures/Game/',
          volume: 'sdcard',
        ).hides(album),
        isFalse,
      );
      expect(
        const HiddenMediaFolder(
          id: 'old-inode',
          name: 'Pictures/Game/',
          volume: 'primary',
        ).hides(album),
        isTrue,
      );
    },
  );
  test(
    'settings survive replacement, restoration and interrupted replacement',
    () async {
      final directory = await Directory('temp').absolute
          .createTemp('visibility_test_');
      try {
        final file = File('${directory.path}/visibility.json');
        final store = LocalMediaVisibilityStore(file);
        expect(await store.load(), isEmpty);
        await store.save([
          const HiddenMediaFolder(
            id: 'parent',
            name: 'Pictures/',
            volume: 'primary',
          ),
        ]);
        expect(
          (await LocalMediaVisibilityStore(file).load()).single.hides(album),
          isTrue,
        );
        await store.save([]);
        expect(await store.load(), isEmpty);
        // Simulate interruption after moving the previous settings aside.
        await file.delete();
        expect((await store.load()).single.id, 'parent');
        await store.save([]);
        expect(await store.load(), isEmpty);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
