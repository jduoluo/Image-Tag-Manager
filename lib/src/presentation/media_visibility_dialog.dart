import '../infrastructure/media_directory_tree.dart';

import 'package:flutter/material.dart';

import '../infrastructure/android_media_probe.dart';
import '../infrastructure/media_visibility_store.dart';

/// Edits local browsing rules only. No media file is changed.
final class MediaVisibilityDialog extends StatefulWidget {
  const MediaVisibilityDialog({
    required this.albums,
    required this.hidden,
    super.key,
  });
  final List<MediaAlbum> albums;
  final List<HiddenMediaFolder> hidden;
  @override
  State<MediaVisibilityDialog> createState() => _MediaVisibilityDialogState();
}

final class _MediaVisibilityDialogState extends State<MediaVisibilityDialog> {
  late final Map<String, HiddenMediaFolder> _hidden = {
    for (final rule in widget.hidden) rule.id: rule,
  };
  final _search = TextEditingController();
  bool _includeChildren = true;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final folders = <String, MediaFolder>{};
    final counts = <String, int>{};
    for (final album in widget.albums) {
      for (final folder in album.hierarchy) {
        final existing = folders[folder.id];
        if (existing == null || folder.name.compareTo(existing.name) < 0) {
          folders[folder.id] = folder;
        }
        counts.update(
          folder.id,
          (value) => value + album.count,
          ifAbsent: () => album.count,
        );
      }
    }
    for (final rule in _hidden.values) {
      folders.putIfAbsent(
        rule.id,
        () => MediaFolder(rule.id, rule.name, volume: rule.volume),
      );
    }
    final nodes = mediaDirectoryTree(widget.albums);
    final depth = {for (final node in nodes) node.folder.id: node.depth};
    final directCounts = {
      for (final node in nodes) node.folder.id: node.directCount,
    };
    final order = {
      for (final (index, node) in nodes.indexed) node.folder.id: index,
    };
    final sorted =
        folders.values
            .where(
              (folder) => folder.name.toLowerCase().contains(
                _search.text.toLowerCase(),
              ),
            )
            .toList()
          ..sort(
            (a, b) => (order[a.id] ?? 999999).compareTo(order[b.id] ?? 999999),
          );
    return AlertDialog(
      title: const Text('管理可见目录'),
      content: SizedBox(
        width: 650,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            const Text('隐藏仅影响本应用的目录、筛选统计与全选；不会修改图片。隐藏时会清空当前图片选择。'),
            TextField(
              controller: _search,
              decoration: const InputDecoration(labelText: '搜索目录'),
              onChanged: (_) => setState(() {}),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('新隐藏的目录包含子目录'),
              value: _includeChildren,
              onChanged: (value) => setState(() => _includeChildren = value),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: sorted.length,
                itemBuilder: (context, index) {
                  final folder = sorted[index];
                  final direct = _hidden[folder.id];
                  final inherited = widget.albums
                      .where(
                        (album) => album.hierarchy.any(
                          (parent) => parent.id == folder.id,
                        ),
                      )
                      .any(
                        (album) => _hidden.values.any(
                          (rule) =>
                              rule.id != folder.id &&
                              rule.includeChildren &&
                              album.hierarchy
                                  .takeWhile((parent) => parent.id != folder.id)
                                  .any((parent) => parent.id == rule.id),
                        ),
                      );
                  return ListTile(
                    title: Padding(
                      padding: EdgeInsets.only(
                        left: ((depth[folder.id] ?? 0) * 10.0).clamp(0, 50),
                      ),
                      child: Tooltip(
                        message: folder.name,
                        child: Text(
                          '${(depth[folder.id] ?? 0) > 0 ? "↳ " : ""}${folder.name.split("/").where((part) => part.isNotEmpty).lastOrNull ?? folder.name}',
                        ),
                      ),
                    ),
                    subtitle: Text(
                      '${folder.volume.isEmpty ? '' : '${folder.volume} · '}本目录 ${directCounts[folder.id] ?? 0} 张 · 含子目录 ${counts[folder.id] ?? 0} 张'
                      '${direct != null
                          ? (direct.includeChildren ? ' · 已隐藏（含子目录）' : ' · 已隐藏（仅本目录）')
                          : inherited
                          ? ' · 被上级目录隐藏'
                          : ''}',
                    ),
                    trailing: TextButton(
                      key: ValueKey('visibility:${folder.id}'),
                      onPressed: inherited && direct == null
                          ? null
                          : () => setState(() {
                              if (direct != null) {
                                _hidden.remove(folder.id);
                              } else {
                                _hidden[folder.id] = HiddenMediaFolder(
                                  id: folder.id,
                                  name: folder.name,
                                  volume: folder.volume,
                                  includeChildren: _includeChildren,
                                );
                              }
                            }),
                      child: Text(direct == null ? '隐藏' : '恢复'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => setState(_hidden.clear),
          child: const Text('全部恢复'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _hidden.values.toList()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
