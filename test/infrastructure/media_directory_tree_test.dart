import 'package:flutter_test/flutter_test.dart';
import 'package:image_tag_manager/src/infrastructure/android_media_probe.dart';
import 'package:image_tag_manager/src/infrastructure/media_directory_tree.dart';

void main() {
  test('compact browser merges empty unary chains and preserves branching and image directories', () {
    MediaAlbum album(String path, int count) {
      final parts = path.split('/').where((part) => part.isNotEmpty).toList();
      return MediaAlbum(
        path,
        count,
        id: path,
        folders: [
          for (var i = 1; i <= parts.length; i++)
            MediaFolder(
              '${parts.take(i).join('/')}/',
              '${parts.take(i).join('/')}/',
            ),
        ],
      );
    }

    final nodes = mediaDirectoryTree([
      album('Download/', 8),
      album('Download/Division2Build/', 1),
      album('Download/netease/cloudmusic/网易云音乐相册/', 33),
      album('Download/netease/其他1/', 2),
      album('Download/netease/其他2/相册1/', 3),
      album('Download/netease/其他2/相册2/特殊/', 4),
      album('Download/X/', 2),
    ], compact: true);
    expect(nodes.map((node) => node.shortName), [
      'Download',
      'Division2Build',
      'netease',
      'cloudmusic/网易云音乐相册',
      '其他1',
      '其他2',
      '相册1',
      '相册2/特殊',
      'X',
    ]);
    expect(nodes.map((node) => node.depth), [0, 1, 1, 2, 2, 2, 3, 3, 1]);
    expect(nodes.where((node) => node.album != null).length, 7);
    expect(nodes[2].directCount, 0);
    expect(nodes[3].folder.id, 'Download/netease/cloudmusic/网易云音乐相册/');
  });
  test('tree distinguishes direct pictures from descendants and shortens child labels', () {
    const root = MediaFolder('r', 'LovelyReader/', volume: 'primary');
    const child = MediaFolder('c', 'LovelyReader/cover/', volume: 'primary');
    final nodes = mediaDirectoryTree(const [
      MediaAlbum('LovelyReader/cover/', 31, id: 'c', folders: [root, child]),
    ]);
    expect(nodes.map((node) => node.shortName), ['LovelyReader', 'cover']);
    expect(nodes.map((node) => node.depth), [0, 1]);
    expect(nodes.first.directCount, 0);
    expect(nodes.first.totalCount, 31);
    expect(nodes.first.album, isNull);
    expect(nodes.last.directCount, 31);
  });
  test('same names in distinct volumes stay separate', () {
    final nodes = mediaDirectoryTree(const [
      MediaAlbum('Pictures/', 2, id: 'a', volume: 'primary'),
      MediaAlbum('Pictures/', 3, id: 'b', volume: 'sd'),
    ]);
    expect(nodes.map((node) => node.folder.id), ['a', 'b']);
    expect(nodes.map((node) => node.totalCount), [2, 3]);
  });
}
