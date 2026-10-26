import 'android_media_probe.dart';

final class MediaDirectoryNode {
  const MediaDirectoryNode(
    this.folder,
    this.depth,
    this.directCount,
    this.totalCount,
    this.album, {
    this.displayName,
  });
  final MediaFolder folder;
  final int depth;
  final int directCount;
  final int totalCount;
  final MediaAlbum? album;
  final String? displayName;
  String get shortName =>
      displayName ??
      (folder.name.split('/').where((part) => part.isNotEmpty).lastOrNull ??
          folder.name);
}

List<MediaDirectoryNode> mediaDirectoryTree(
  List<MediaAlbum> albums, {
  bool compact = false,
}) {
  final folders = <String, MediaFolder>{};
  final parents = <String, String?>{};
  final totals = <String, int>{};
  final direct = {for (final album in albums) album.id: album};
  for (final album in albums) {
    String? parent;
    for (final folder in album.hierarchy) {
      folders.putIfAbsent(folder.id, () => folder);
      parents.putIfAbsent(folder.id, () => parent);
      totals.update(
        folder.id,
        (count) => count + album.count,
        ifAbsent: () => album.count,
      );
      parent = folder.id;
    }
  }
  final children = <String?, List<String>>{};
  for (final id in folders.keys) {
    children.putIfAbsent(parents[id], () => []).add(id);
  }
  for (final ids in children.values) {
    ids.sort((a, b) {
      final order = folders[a]!.name.toLowerCase().compareTo(
        folders[b]!.name.toLowerCase(),
      );
      return order == 0 ? a.compareTo(b) : order;
    });
  }
  final result = <MediaDirectoryNode>[];
  final visited = <String>{};
  void append(String? parent, int depth) {
    for (final childId in children[parent] ?? <String>[]) {
      var id = childId;
      if (!visited.add(id)) continue;
      final labels = <String>[
        folders[id]!.name.split('/').where((part) => part.isNotEmpty).last,
      ];
      // Preserve roots, branches and every directory containing its own images.
      while (compact &&
          depth > 0 &&
          direct[id] == null &&
          (children[id]?.length ?? 0) == 1) {
        final next = children[id]!.single;
        if (!visited.add(next)) break;
        id = next;
        labels.add(
          folders[id]!.name.split('/').where((part) => part.isNotEmpty).last,
        );
      }
      result.add(
        MediaDirectoryNode(
          folders[id]!,
          depth,
          direct[id]?.count ?? 0,
          totals[id] ?? 0,
          direct[id],
          displayName: labels.join('/'),
        ),
      );
      append(id, depth + 1);
    }
  }

  append(null, 0);
  return result;
}
