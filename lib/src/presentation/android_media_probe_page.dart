import 'app_about_page.dart';
import '../infrastructure/guide_preferences.dart';
import '../infrastructure/media_image_sort.dart';

import 'package:flutter/services.dart';

import '../infrastructure/media_directory_tree.dart';
import 'export_cleanup_page.dart';
import 'usage_guide_page.dart';
import 'android_image_viewer_page.dart';

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../application/directory_browser.dart';
import '../domain/filename_tags.dart';
import '../domain/tag_group_config.dart';
import '../domain/tag_filter.dart';
import '../domain/tag_group_profiles.dart';
import '../domain/tag_groups.dart';
import '../infrastructure/android_media_probe.dart';
import '../infrastructure/local_tag_group_store.dart';
import '../infrastructure/tag_group_import.dart';
import 'rename_editor_dialog.dart';
import 'tag_group_editor.dart';
import 'media_visibility_dialog.dart';
import '../infrastructure/media_visibility_store.dart';
import '../application/rename_service.dart';
import '../domain/rename_plan.dart';
import '../infrastructure/android_rename_port.dart';
import '../infrastructure/rename_transaction_store.dart';
import 'rename_history_dialog.dart';
import 'manual_closed_history_dialog.dart';
import 'directory_browser_page.dart' show RenameResultDialog;

enum _Role { ignored, all, any, none }

/// Android MediaStore browser. Only explicit export creates app-owned copies.
final class AndroidMediaProbePage extends StatefulWidget {
  const AndroidMediaProbePage({
    this.probe = const AndroidMediaProbe(),
    this.groupStore,
    this.visibilityStore,
    this.renameService,
    this.renamePort = const AndroidRenamePort(),
    this.selectConfig,
    super.key,
  });

  final AndroidMediaProbe probe;
  final TagGroupStore? groupStore;
  final MediaVisibilityStore? visibilityStore;
  final RenameService? renameService;
  final AndroidRenamePort renamePort;
  final Future<XFile?> Function()? selectConfig;

  @override
  State<AndroidMediaProbePage> createState() => _AndroidMediaProbePageState();
}

final class _AndroidMediaProbePageState extends State<AndroidMediaProbePage>
    with WidgetsBindingObserver {
  MediaImageSort _imageSort = MediaImageSort.modifiedNewest;
  bool _sortChosen = false;
  MediaAccess? _access;
  List<MediaAlbum> _albums = const [];
  List<MediaAlbum> _allAlbums = const [];
  List<HiddenMediaFolder> _hiddenFolders = const [];
  MediaVisibilityStore? _visibilityStore;
  String? _album;
  List<MediaImage> _images = const [];
  final Map<String, List<MediaImage>> _albumImageCache = {};
  String? _mediaRevision;
  StreamSubscription<String>? _mediaChanges;
  Timer? _changeTimer;
  bool _checkingChanges = false;
  List<MediaAlbumImage>? _indexedImages;
  final Map<String, int> _matchedByAlbum = {};
  final Map<int, MediaImage> _matchedImages = {};
  final Map<String, String> _globalFilterOptions = {};
  bool _indexing = false;
  String? _indexError;
  int _indexGeneration = 0;
  final Map<int, MediaImage> _selected = {};
  final Map<int, Future<Uint8List>> _thumbnails = {};
  final Map<String, _Role> _roles = {};
  TagGroupProfiles? _profiles;
  TagGroupStore? _store;
  bool _onlyUntagged = false;
  bool _toolsExpanded = true;
  RenameService? _renameService;
  List<PendingRenameTransaction> _pendingRenames = const [];
  List<SuspectedMissingRenameRecord> _suspectedRecords = const [];
  bool _renaming = false;
  bool _busy = false;
  AndroidEntryPreparation? _preparation;
  int _preparedImages = 0;
  int _preparationTotal = 0;
  bool _exporting = false;
  bool _cancelExport = false;
  int _exportDone = 0;
  int _exportTotal = 0;
  String? _error;

  TagGroups get _groups => _profiles?.active.groups ?? TagGroups(const []);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mediaChanges = widget.probe.watchChanges().listen(
      (_) => _queueMediaCheck(),
      onError: (Object error) {
        if (error is! MissingPluginException) {
          debugPrint(
            'Media change notifications unavailable: ${error.runtimeType}',
          );
        }
      },
    );
    unawaited(_loadImageSort());
    _initialize();
  }

  Future<void> _loadImageSort() async {
    try {
      final saved = await widget.probe.loadImageSort();
      if (!mounted || saved == null || _sortChosen) return;
      final matches = MediaImageSort.values.where((sort) => sort.name == saved);
      if (matches.isNotEmpty) setState(() => _imageSort = matches.first);
    } on MissingPluginException {
      // Older bridges and host fixtures retain the default.
    } catch (error) {
      debugPrint('Unable to restore image sorting: ${error.runtimeType}');
    }
  }

  Future<void> _changeImageSort(MediaImageSort sort) async {
    _sortChosen = true;
    setState(() => _imageSort = sort);
    try {
      await widget.probe.saveImageSort(sort.name);
    } catch (error) {
      if (mounted) setState(() => _error = '排序已切换，但保存偏好失败：$error');
    }
  }

  @override
  void dispose() {
    _preparation?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _changeTimer?.cancel();
    _mediaChanges?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !_busy &&
        !_renaming &&
        !_exporting) {
      unawaited(_checkExternalChanges(checkPartial: true));
    }
  }

  void _queueMediaCheck() {
    _changeTimer?.cancel();
    _changeTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      if (_busy || _renaming || _exporting || _checkingChanges) {
        _queueMediaCheck();
        return;
      }
      unawaited(_checkExternalChanges());
    });
  }

  Future<void> _checkExternalChanges({bool checkPartial = false}) async {
    if (_checkingChanges) {
      _queueMediaCheck();
      return;
    }
    _checkingChanges = true;
    try {
      final revision = await widget.probe.mediaRevision();
      if (!mounted) return;
      if ((_mediaRevision != null && revision != _mediaRevision) ||
          (checkPartial && _access == MediaAccess.partial)) {
        await widget.probe.invalidateMediaCache();
        final access = await widget.probe.permissionState();
        if (!mounted) return;
        if (access == MediaAccess.denied) {
          setState(() {
            _access = access;
            _albums = [];
            _allAlbums = [];
            _images = [];
            _album = null;
            _indexedImages = null;
            _selected.clear();
            _albumImageCache.clear();
            _thumbnails.clear();
            _indexGeneration++;
            _indexing = false;
            _recalculateMatches();
          });
        } else {
          await _reconcileMediaSnapshot(access);
        }
      }
      // Invalidating a cache does not change this source-data revision.
      _mediaRevision = revision;
    } on MissingPluginException {
      /* Older bridge/widget fixtures use manual refresh. */
    } catch (error) {
      if (mounted) setState(() => _error = '检查媒体库变化失败：$error');
    } finally {
      _checkingChanges = false;
    }
  }

  Future<void> _reconcileMediaSnapshot(MediaAccess access) async {
    final generation = ++_indexGeneration;
    final albums = await widget.probe.listAlbums();
    final rows = await widget.probe.listAllImages();
    if (!mounted || generation != _indexGeneration) return;
    final visible = albums
        .where((album) => !_hiddenFolders.any((rule) => rule.hides(album)))
        .toList();
    final visibleIds = visible.map((album) => album.id).toSet();
    final indexed = rows
        .where((row) => visibleIds.contains(row.album))
        .toList();
    final old = {
      for (final row in _indexedImages ?? <MediaAlbumImage>[])
        row.image.id: row.image,
    };
    final fresh = {for (final row in indexed) row.image.id: row.image};
    final byAlbum = <String, List<MediaImage>>{};
    for (final row in indexed) {
      byAlbum.putIfAbsent(row.album, () => []).add(row.image);
    }
    final next = visibleIds.contains(_album) ? _album : visible.firstOrNull?.id;
    setState(() {
      _access = access;
      _allAlbums = albums;
      _albums = visible;
      _album = next;
      // Only changed metadata/content invalidates a thumbnail; other images keep their cache.
      _thumbnails.removeWhere(
        (id, _) =>
            !fresh.containsKey(id) ||
            (old[id]?.changeToken != fresh[id]?.changeToken),
      );
      _selected.removeWhere(
        (id, image) =>
            !fresh.containsKey(id) ||
            fresh[id]!.name != image.name ||
            fresh[id]!.path != image.path ||
            old[id]?.changeToken != fresh[id]?.changeToken,
      );
      _albumImageCache.removeWhere((id, _) => !visibleIds.contains(id));
      for (final id in _albumImageCache.keys.toList()) {
        _albumImageCache[id] = byAlbum[id] ?? const [];
      }
      _images = byAlbum[next] ?? const [];
      _indexedImages = indexed;
      _indexing = false;
      _indexError = null;
      _recalculateMatches();
    });
    final suspects =
        await _renameService?.store.suspectedMissingRecords(
          _images.map((image) => image.name),
        ) ??
        <SuspectedMissingRenameRecord>[];
    if (mounted && generation == _indexGeneration) {
      setState(() => _suspectedRecords = suspects);
    }
  }

  Future<void> _initialize() async {
    try {
      final access = await widget.probe.permissionState();
      final store =
          widget.groupStore ??
          LocalTagGroupStore.atFile(
            File(
              '${await widget.probe.privateConfigDirectory()}/tag_groups.json',
            ),
          );
      final profiles = await store.loadProfiles();
      _visibilityStore =
          widget.visibilityStore ??
          (widget.groupStore == null
              ? LocalMediaVisibilityStore(
                  File(
                    '${await widget.probe.privateConfigDirectory()}/media_visibility.json',
                  ),
                )
              : MemoryMediaVisibilityStore());
      final hidden = await _visibilityStore!.load();
      _hiddenFolders = hidden;
      _renameService = widget.renameService;
      if (_renameService == null && widget.groupStore == null) {
        final privateDirectory = await widget.probe.privateConfigDirectory();
        _renameService = RenameService(
          port: widget.renamePort,
          store: RenameTransactionStore(
            Directory('$privateDirectory/transactions'),
          ),
          maxPathLength: null,
          maxFilenameBytes: 255,
        );
      }
      if (!mounted) return;
      setState(() {
        _access = access;
        _store = store;
        _profiles = profiles;
      });
      await _loadPendingRenames();
      try {
        _mediaRevision = await widget.probe.mediaRevision();
      } on MissingPluginException {
        /* fixture */
      }
      if (access != MediaAccess.denied) await _loadAlbums();
    } catch (error) {
      if (mounted) setState(() => _error = '初始化失败：$error');
    }
  }

  Future<void> _requestAndList() async {
    if (_busy || _renaming) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      try {
        await widget.probe.invalidateMediaCache();
      } on MissingPluginException {
        /* fixture */
      }
      final access = await widget.probe.requestImages();
      if (!mounted) return;
      setState(() => _access = access);
      if (access == MediaAccess.denied) {
        setState(() {
          _albums = const [];
          _allAlbums = const [];
          _images = const [];
          _album = null;
          _albumImageCache.clear();
          _thumbnails.clear();
          _selected.clear();
          _indexGeneration++;
          _indexedImages = null;
          _matchedByAlbum.clear();
          _matchedImages.clear();
          _globalFilterOptions.clear();
          _indexing = false;
          _indexError = null;
        });
      } else {
        if (_indexedImages != null) {
          await _reconcileMediaSnapshot(access);
        } else {
          await _loadAlbums();
        }
      }
      try {
        _mediaRevision = await widget.probe.mediaRevision();
      } on MissingPluginException {
        /* fixture */
      }
    } catch (error) {
      if (mounted) setState(() => _error = '读取媒体库失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openExportCleanup() async {
    await _loadPendingRenames();
    if (!mounted) return;
    if (_pendingRenames.isNotEmpty) {
      setState(() => _error = '请先核对并处理未解决改名事务，再清理导出副本。');
      return;
    }
    final deleted = <int>{};
    var uncertain = false;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ExportCleanupPage(
          probe: widget.probe,
          onChanged: (ids, unknown) {
            deleted.addAll(ids);
            uncertain = uncertain || unknown;
          },
        ),
      ),
    );
    if (!mounted || (deleted.isEmpty && !uncertain)) return;
    setState(() => _busy = true);
    try {
      await widget.probe.invalidateMediaCache();
      if (uncertain) {
        _albumImageCache.clear();
        for (final id in deleted) {
          _thumbnails.remove(id);
        }
        if (_access != MediaAccess.denied) await _loadAlbums();
        return;
      }
      final albums = await widget.probe.listAlbums();
      if (!mounted) return;
      final visible = albums
          .where((album) => !_hiddenFolders.any((rule) => rule.hides(album)))
          .toList();
      final visibleIds = visible.map((album) => album.id).toSet();
      final previous = _album;
      final next = visibleIds.contains(previous)
          ? previous
          : visible.firstOrNull?.id;
      setState(() {
        _allAlbums = albums;
        _albums = visible;
        for (final id in deleted) {
          _selected.remove(id);
          _thumbnails.remove(id);
        }
        _albumImageCache.removeWhere((id, _) => !visibleIds.contains(id));
        for (final id in _albumImageCache.keys.toList()) {
          _albumImageCache[id] = _albumImageCache[id]!
              .where((image) => !deleted.contains(image.id))
              .toList();
        }
        _images = _images
            .where((image) => !deleted.contains(image.id))
            .toList();
        _indexedImages = _indexedImages
            ?.where((row) => !deleted.contains(row.image.id))
            .toList();
        _album = next;
        if (next != previous) {
          _images = const [];
          _suspectedRecords = const [];
        }
        _recalculateMatches();
      });
      if (next != previous && next != null) {
        await _loadImages(next, checkChanges: false);
      }
      try {
        _mediaRevision = await widget.probe.mediaRevision();
      } on MissingPluginException {
        /* fixture */
      }
    } catch (error) {
      if (mounted) setState(() => _error = '清理后刷新失败：$error；请手动刷新媒体库。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manageVisibleAlbums() async {
    if (_busy || _renaming || _exporting || _visibilityStore == null) return;
    final rules = await showDialog<List<HiddenMediaFolder>>(
      context: context,
      builder: (_) =>
          MediaVisibilityDialog(albums: _allAlbums, hidden: _hiddenFolders),
    );
    if (rules == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _visibilityStore!.save(rules);
      if (!mounted) return;
      setState(() {
        _hiddenFolders = rules;
        _selected.clear();
      });
      await _loadAlbums();
    } catch (error) {
      if (mounted) setState(() => _error = '保存目录显示设置失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _albumLabel(MediaAlbum album) {
    final sameName = _albums.any(
      (other) => other.id != album.id && other.name == album.name,
    );
    final name = sameName ? '${album.name}（${album.volume}）' : album.name;
    return _indexedImages != null && (_roles.isNotEmpty || _onlyUntagged)
        ? '$name  匹配 ${_matchedByAlbum[album.id] ?? 0}/${album.count} 张'
        : '$name  ${album.count} 张';
  }

  Future<void> _loadAlbums() async {
    final generation = ++_indexGeneration;
    setState(() {
      _indexedImages = null;
      _matchedByAlbum.clear();
      _matchedImages.clear();
      _globalFilterOptions.clear();
      _indexing = true;
      _indexError = null;
    });
    late final List<MediaAlbum> albums;
    try {
      albums = await widget.probe.listAlbums();
    } catch (_) {
      if (mounted && generation == _indexGeneration) {
        setState(() => _indexing = false);
      }
      rethrow;
    }
    if (!mounted || generation != _indexGeneration) return;
    final visibleAlbums = albums
        .where((album) => !_hiddenFolders.any((rule) => rule.hides(album)))
        .toList();
    final next = visibleAlbums.any((item) => item.id == _album)
        ? _album
        : visibleAlbums.firstOrNull?.id;
    setState(() {
      _allAlbums = albums;
      _albums = visibleAlbums;
      _album = next;
      _images = const [];
      _selected.clear();
    });
    if (next != null) await _loadImages(next, checkChanges: false);
    if (mounted && generation == _indexGeneration) {
      unawaited(_loadGlobalIndex(generation));
    }
  }

  Future<void> _loadGlobalIndex(int generation) async {
    try {
      final images = await widget.probe.listAllImages();
      if (!mounted || generation != _indexGeneration) return;
      setState(() {
        final visibleIds = _albums.map((album) => album.id).toSet();
        _indexedImages = images
            .where((row) => visibleIds.contains(row.album))
            .toList();
        _indexing = false;
        _recalculateMatches();
      });
    } catch (error) {
      if (!mounted || generation != _indexGeneration) return;
      setState(() {
        _indexedImages = null;
        _indexing = false;
        _indexError = '全部目录匹配统计失败：$error';
      });
    }
  }

  void _recalculateMatches() {
    _matchedByAlbum.clear();
    _matchedImages.clear();
    _globalFilterOptions.clear();
    final images = _indexedImages;
    if (images == null) return;
    final filter = _filter;
    for (final row in images) {
      final parsed = parseFilename(row.image.name);
      for (final raw in parsed.tags) {
        final identity = _groups.identity(raw);
        _globalFilterOptions.putIfAbsent(
          identity,
          () => identity.startsWith('group:')
              ? _groups.group(identity.substring(6)).displayName
              : raw,
        );
      }
      if (!filter.matches(parsed, _groups)) continue;
      _matchedByAlbum.update(
        row.album,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      _matchedImages[row.image.id] = row.image;
    }
  }

  Future<void> _loadImages(String album, {bool checkChanges = true}) async {
    if (checkChanges && !_checkingChanges && _mediaRevision != null) {
      await _checkExternalChanges();
    }
    if (!mounted) return;
    // A dropdown route can outlive the album snapshot used to create it.
    if (!_albums.any((item) => item.id == album)) return;
    setState(() {
      _busy = true;
      _error = null;
      _album = album;
      _images = const [];
    });
    try {
      final cached = _albumImageCache.remove(album);
      final images = cached ?? await widget.probe.listImages(album);
      _albumImageCache[album] = images;
      while (_albumImageCache.length > 1 &&
          _albumImageCache.values.fold<int>(
                0,
                (sum, rows) => sum + rows.length,
              ) >
              12000) {
        _albumImageCache.remove(_albumImageCache.keys.first);
      }
      final suspected =
          await _renameService?.store.suspectedMissingRecords(
            images.map((image) => image.name),
          ) ??
          <SuspectedMissingRenameRecord>[];
      if (mounted && _album == album) {
        setState(() => _suspectedRecords = suspected);
      }
      if (mounted && _album == album) setState(() => _images = images);
    } catch (error) {
      if (mounted) setState(() => _error = '无法打开相册：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  ImageEntry _entry(MediaImage image) => ImageEntry(
    id: image.path ?? 'media:${image.id}',
    fileId: image.fileId,
    filename: image.name,
    parsedFilename: parseFilename(image.name),
  );

  TagFilter get _filter => TagFilter(
    onlyUntagged: _onlyUntagged,
    allOf: _roles.entries
        .where((item) => item.value == _Role.all)
        .map((item) => item.key),
    anyOf: _roles.entries
        .where((item) => item.value == _Role.any)
        .map((item) => item.key),
    noneOf: _roles.entries
        .where((item) => item.value == _Role.none)
        .map((item) => item.key),
  );

  List<MediaImage> get _visible =>
      _images
          .where((image) => _filter.matches(parseFilename(image.name), _groups))
          .toList(growable: false)
        ..sort(_imageSort.compare);

  Map<String, String> get _filterOptions {
    final options = <String, String>{};
    if (_indexedImages != null) {
      options.addAll(_globalFilterOptions);
    } else {
      for (final image in _images) {
        for (final raw in parseFilename(image.name).tags) {
          final identity = _groups.identity(raw);
          options.putIfAbsent(
            identity,
            () => identity.startsWith('group:')
                ? _groups.group(identity.substring(6)).displayName
                : raw,
          );
        }
      }
    }
    for (final identity in _roles.keys) {
      options.putIfAbsent(identity, () {
        if (identity.startsWith('raw:')) return identity.substring(4);
        final id = identity.substring(6);
        for (final group in _groups.all) {
          if (group.id == id) return group.displayName;
        }
        return identity;
      });
    }
    return Map.fromEntries(
      options.entries.toList()..sort((a, b) => a.value.compareTo(b.value)),
    );
  }

  String _roleLabel(_Role role) => switch (role) {
    _Role.ignored => '不参与',
    _Role.all => 'AND  必须有',
    _Role.any => 'OR  任一有',
    _Role.none => 'NOT  必须无',
  };

  String _filterButtonText(String name, _Role role) => switch (role) {
    _Role.ignored => name,
    _Role.all => '$name  AND',
    _Role.any => '$name  OR',
    _Role.none => '$name  NOT',
  };

  Color? _roleColor(_Role role) => switch (role) {
    _Role.ignored => null,
    _Role.all => const Color(0xFFDDF3DE),
    _Role.any => const Color(0xFFDDEEFF),
    _Role.none => const Color(0xFFF9DFE1),
  };

  void _setRole(String identity, _Role role) {
    setState(() {
      if (role == _Role.ignored) {
        _roles.remove(identity);
      } else {
        _onlyUntagged = false;
        _roles[identity] = role;
      }
      _selected.clear();
      _recalculateMatches();
    });
  }

  Future<void> _showFilterHelp() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('筛选模式说明'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AND（与）：图片必须包含全部 AND 项标签。'),
          SizedBox(height: 12),
          Text('OR（或）：图片必须包含至少一个 OR 项标签。'),
          SizedBox(height: 12),
          Text('NOT（非）：图片不能包含任何一个 NOT 项标签。'),
          SizedBox(height: 12),
          Text('不参与：该标签不影响筛选结果。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> _showRoleMenu(
    BuildContext buttonContext,
    String identity,
    VoidCallback refreshDialog,
  ) async {
    final button = buttonContext.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final group = identity.startsWith('group:')
        ? _groups.group(identity.substring(6))
        : null;
    final role = await showMenu<_Role>(
      context: buttonContext,
      position: RelativeRect.fromRect(
        topLeft & button.size,
        Offset.zero & overlay.size,
      ),
      items: [
        if (group != null) ...[
          PopupMenuItem<_Role>(
            enabled: false,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text('同组别名：${group.aliases.join(' · ')}', softWrap: true),
            ),
          ),
          const PopupMenuDivider(),
        ],
        for (final value in _Role.values)
          PopupMenuItem<_Role>(
            value: value,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if ((_roles[identity] ?? _Role.ignored) == value)
                  const Icon(Icons.check, size: 18),
                if ((_roles[identity] ?? _Role.ignored) == value)
                  const SizedBox(width: 6),
                Text(_roleLabel(value)),
              ],
            ),
          ),
      ],
    );
    if (role == null || !mounted) return;
    _setRole(identity, role);
    refreshDialog();
  }

  Future<void> _showFilterDialog(Map<String, String> options) =>
      showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, refreshDialog) => AlertDialog(
            title: Row(
              children: [
                const Flexible(child: Text('组合筛选')),
                IconButton(
                  tooltip: '筛选模式说明',
                  onPressed: _showFilterHelp,
                  icon: const Icon(Icons.info_outline),
                ),
              ],
            ),
            content: SizedBox(
              width: 460,
              height: MediaQuery.sizeOf(context).height * 0.45,
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in options.entries)
                      Builder(
                        builder: (buttonContext) => OutlinedButton(
                          key: ValueKey('android-filter:${option.key}'),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: _roleColor(
                              _roles[option.key] ?? _Role.ignored,
                            ),
                          ),
                          onPressed: () => _showRoleMenu(
                            buttonContext,
                            option.key,
                            () => refreshDialog(() {}),
                          ),
                          child: Text(
                            _filterButtonText(
                              option.value,
                              _roles[option.key] ?? _Role.ignored,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      );

  Future<void> _saveGroups(TagGroups groups) async {
    final profiles = _profiles!;
    final updated = TagGroupProfiles(
      profiles: [
        for (final item in profiles.profiles)
          item.id == profiles.activeId
              ? TagGroupProfile(id: item.id, name: item.name, groups: groups)
              : item,
      ],
      activeId: profiles.activeId,
    );
    await _store!.saveProfiles(updated);
    if (mounted) {
      setState(() {
        _profiles = updated;
        _roles.clear();
        _recalculateMatches();
      });
    }
  }

  static const _renameNotice =
      'Android 使用系统媒体库改名；执行前检查同名，执行后核对实际名称。请勿同时在其他应用修改此目录：系统接口不能保证并发时原子不覆盖；出现自动换名或身份异常会停止。';
  Future<void> _editGroups(TagGroupEditorMode mode) async {
    if (_profiles == null || _store == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) =>
          TagGroupEditor(groups: _groups, onSave: _saveGroups, mode: mode),
    );
  }

  Future<void> _saveProfileList(TagGroupProfiles updated) async {
    await _store!.saveProfiles(updated);
    if (mounted) {
      setState(() {
        _profiles = updated;
        _roles.clear();
        _onlyUntagged = false;
        _selected.clear();
        _recalculateMatches();
      });
    }
  }

  Future<String?> _askProfileName(
    String title, {
    String initial = '',
    String? excludeProfileId,
  }) async {
    var name = initial;
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: '配置名称'),
          onChanged: (text) => name = text,
          onFieldSubmitted: (text) => Navigator.pop(context, text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty || !mounted) return null;
    if (_profiles!.profiles.any(
      (profile) => profile.id != excludeProfileId && profile.name == value,
    )) {
      setState(() => _error = '配置名称已存在');
      return null;
    }
    return value;
  }

  Future<void> _newProfile() async {
    final name = await _askProfileName('新建空配置');
    if (name == null) return;
    final previous = _profiles!;
    final id = TagGroupProfiles.newId(
      previous.profiles.map((profile) => profile.id),
    );
    try {
      await _saveProfileList(
        TagGroupProfiles(
          profiles: [
            ...previous.profiles,
            TagGroupProfile(id: id, name: name, groups: TagGroups(const [])),
          ],
          activeId: id,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '新建配置失败：$error');
    }
  }

  Future<void> _renameProfile() async {
    final previous = _profiles!;
    final active = previous.active;
    final name = await _askProfileName(
      '重命名当前配置',
      initial: active.name,
      excludeProfileId: active.id,
    );
    if (name == null || name == active.name) return;
    final updated = TagGroupProfiles(
      profiles: [
        for (final profile in previous.profiles)
          profile.id == active.id
              ? TagGroupProfile(
                  id: profile.id,
                  name: name,
                  groups: profile.groups,
                )
              : profile,
      ],
      activeId: active.id,
    );
    try {
      await _store!.saveProfiles(updated);
      if (mounted) setState(() => _profiles = updated);
    } catch (error) {
      if (mounted) setState(() => _error = '重命名配置失败：$error');
    }
  }

  Future<void> _exportGroups() async {
    try {
      final exported = await widget.probe.exportConfig(
        '${TagGroupConfig.encode(_groups)}\n',
      );
      if (exported && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('标签组配置已导出')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '导出配置失败：$error');
    }
  }

  Future<void> _deleteProfile() async {
    final previous = _profiles!;
    final active = previous.active;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('删除配置“${active.name}”？'),
        content: const Text('只删除这份标签组配置，不修改图片文件名。删除后无法从软件内恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final remaining = previous.profiles
        .where((profile) => profile.id != active.id)
        .toList();
    if (remaining.isEmpty) {
      remaining.add(
        TagGroupProfile(
          id: TagGroupProfiles.newId(
            previous.profiles.map((profile) => profile.id),
          ),
          name: '空配置',
          groups: TagGroups(const []),
        ),
      );
    }
    try {
      await _saveProfileList(
        TagGroupProfiles(profiles: remaining, activeId: remaining.first.id),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '删除配置失败：$error');
    }
  }

  Future<void> _importGroups() async {
    setState(() => _error = null);
    try {
      final selected =
          await (widget.selectConfig?.call() ??
              openFile(
                acceptedTypeGroups: [
                  const XTypeGroup(label: 'JSON', extensions: ['json']),
                ],
              ));
      if (selected == null || !mounted) return;
      final groups = await TagGroupImport.read(selected);
      if (!mounted) return;
      final name = await _askProfileName(
        '导入单份标签组配置',
        initial: selected.name.replaceFirst(
          RegExp(r'\.json$', caseSensitive: false),
          '',
        ),
      );
      if (name == null) return;
      final previous = _profiles!;
      final id = TagGroupProfiles.newId(
        previous.profiles.map((profile) => profile.id),
      );
      await _saveProfileList(
        TagGroupProfiles(
          profiles: [
            ...previous.profiles,
            TagGroupProfile(id: id, name: name, groups: groups),
          ],
          activeId: id,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '导入配置失败：$error');
    }
  }

  Future<void> _switchProfile(String id) async {
    if (id == _profiles!.activeId) return;
    try {
      await _saveProfileList(
        TagGroupProfiles(profiles: _profiles!.profiles, activeId: id),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '切换配置失败：$error');
    }
  }

  Future<void> _loadPendingRenames() async {
    final service = _renameService;
    if (service == null) return;
    final pending = await service.store.pending();
    if (mounted) setState(() => _pendingRenames = pending);
  }

  Future<Set<String>?> _acknowledgePending(String directory) async {
    await _loadPendingRenames();
    if (!mounted) return null;
    if (_pendingRenames.isEmpty) return <String>{};
    final current = _pendingRenames
        .where((record) => record.plan?.directory == directory)
        .length;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('仍有未解决事务'),
        content: Text(
          '现有 ${_pendingRenames.length} 笔未解决事务，其中 $current 笔在本目录。继续新批次可能使旧计划无法原样恢复；记录会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认继续新批次'),
          ),
        ],
      ),
    );
    return accepted == true
        ? _pendingRenames.map((record) => record.path).toSet()
        : null;
  }

  Future<void> _previewEdit() async {
    if (_selected.isEmpty || _renaming || _busy) return;
    final service = _renameService;
    if (service == null) {
      setState(() => _error = '此环境尚未初始化安全改名服务，当前可浏览和导出。');
      return;
    }
    var selected = _selected.values.toList();
    if (selected.any((image) => image.fileId == null || image.path == null)) {
      final preparation = AndroidEntryPreparation();
      setState(() {
        _busy = true;
        _preparation = preparation;
        _preparedImages = 0;
        _preparationTotal = selected.length;
      });
      try {
        final entries = await widget.renamePort.entries(
          selected.map((image) => image.id),
          preparation: preparation,
          onProgress: (done, total) {
            if (mounted &&
                _preparation == preparation &&
                !preparation.cancelled) {
              setState(() {
                _preparedImages = done;
                _preparationTotal = total;
              });
            }
          },
        );
        if (!mounted || preparation.cancelled) return;
        if (entries.length != selected.length) throw StateError('选中图片身份不完整');
        selected = [
          for (final (index, entry) in entries.indexed)
            MediaImage(
              selected[index].id,
              entry.filename,
              path: entry.id,
              fileId: entry.fileId,
            ),
        ];
      } on AndroidPreparationCancelled {
        return;
      } catch (error) {
        if (mounted) setState(() => _error = '无法核对选中图片：$error');
        return;
      } finally {
        if (mounted) {
          setState(() {
            _busy = false;
            _preparation = null;
          });
        }
      }
      if (!mounted) return;
    }
    if (selected.any((image) => image.path == null || image.fileId == null)) {
      setState(() => _error = '所选来源无法获取普通文件路径或可靠身份，仅支持浏览和导出。');
      return;
    }
    late List<ImageEntry> entries;
    try {
      entries = normalizeAndroidRenameSelection(selected.map(_entry).toList());
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    final directory = File(entries.first.id).parent.path;
    RenameEditorDraft? draft;
    while (mounted) {
      if (!mounted) return;
      final result = await showDialog<RenameEditorResult>(
        context: context,
        builder: (_) => RenameEditorDialog(
          selected: entries,
          groups: _groups,
          draft: draft,
        ),
      );
      if (result == null || !mounted) return;
      draft = result.draft;
      late RenamePlan plan;
      setState(() => _busy = true);
      try {
        plan = await service.preview(
          directory: directory,
          selected: entries,
          edits: result.editsFor(entries),
          groups: result.groups,
        );
      } catch (error) {
        if (mounted) setState(() => _error = '无法生成改名预演：$error');
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
      if (!await showRenamePreview(
        context,
        plan,
        created: result.created,
        platformNotice: _renameNotice,
      )) {
        continue;
      }
      final pending = await _acknowledgePending(plan.directory);
      if (pending == null || !mounted) return;
      if (result.created.isNotEmpty) {
        try {
          await _saveGroups(result.groups);
        } catch (error) {
          if (mounted) setState(() => _error = '保存新标签组失败，未开始改名：$error');
          return;
        }
      }
      if (!mounted) return;
      await _runMediaRename(plan, acknowledged: pending);
      return;
    }
  }

  Future<void> _refreshRenamedImages(RenamePlan plan) async {
    final names = plan.items.map((item) => item.original).toSet();
    final candidates = <int, MediaImage>{
      for (final row in _indexedImages ?? <MediaAlbumImage>[])
        row.image.id: row.image,
      for (final image in _selected.values) image.id: image,
      for (final image in _images) image.id: image,
    };
    final touched = candidates.values
        .where(
          (image) =>
              image.path != null &&
              File(image.path!).parent.path == plan.directory &&
              names.contains(image.name),
        )
        .toList();
    if (touched.length != plan.items.length) {
      _albumImageCache.clear();
      await _loadAlbums();
      return;
    }
    try {
      final entries = await widget.renamePort.readNames(
        touched.map((image) => image.id),
      );
      if (!mounted) return;
      if (entries.length != touched.length) throw StateError('改名后记录不完整');
      final ids = touched.map((image) => image.id).toSet();
      if (entries.map((image) => image.id).toSet().length != ids.length ||
          entries.any((image) => !ids.contains(image.id))) {
        throw StateError('改名后媒体 ID 不匹配');
      }
      final updated = {
        for (final image in entries)
          image.id: MediaImage(
            image.id,
            image.name,
            path: image.path,
            fileId: image.fileId,
            changeToken: image.changeToken,
            modifiedTime: image.modifiedTime,
          ),
      };
      setState(() {
        _images = [for (final image in _images) updated[image.id] ?? image];
        for (final id in _albumImageCache.keys.toList()) {
          _albumImageCache[id] = [
            for (final image in _albumImageCache[id]!)
              updated[image.id] ?? image,
          ];
        }
        if (_indexedImages != null) {
          _indexedImages = [
            for (final row in _indexedImages!)
              MediaAlbumImage(row.album, updated[row.image.id] ?? row.image),
          ];
        }
        _selected.clear();
        _recalculateMatches();
      });
      try {
        _mediaRevision = await widget.probe.mediaRevision();
      } on MissingPluginException {
        /* fixture */
      }
    } catch (_) {
      // Ambiguous/provider-only names need a fresh lightweight index, never invented names.
      _albumImageCache.clear();
      if (mounted) await _loadAlbums();
    }
  }

  Future<void> _runMediaRename(
    RenamePlan plan, {
    bool resume = false,
    bool continueSafe = false,
    Set<String> acknowledged = const {},
  }) async {
    final service = _renameService;
    if (service == null || _renaming || !mounted) return;
    var cancelled = false;
    var attempted = false;
    final operationTimer = Stopwatch();
    final inspectTimer = Stopwatch();
    final mediaTimer = Stopwatch();
    final updateTimer = Stopwatch();
    final progress = ValueNotifier<(String, int, int)>((
      '准备修改授权',
      0,
      plan.items.length,
    ));
    setState(() {
      _renaming = true;
      _error = null;
    });
    final progressClosed = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<(String, int, int)>(
          valueListenable: progress,
          builder: (context, state, _) => AlertDialog(
            title: const Text('正在处理文件名'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(state.$1),
                Text('${state.$2} / ${state.$3}'),
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                const Text('第一阶段停止会尝试恢复原名；第二阶段停止保留已完成项，其余项目可从未解决事务处理。'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: cancelled
                    ? null
                    : () {
                        cancelled = true;
                        progress.value = (
                          '正在停止，请等待当前操作核对完成',
                          state.$2,
                          state.$3,
                        );
                      },
                child: const Text('停止'),
              ),
            ],
          ),
        ),
      ),
    );
    late RenameOutcome outcome;
    try {
      final paths = <String>[];
      if (resume) {
        final statuses = await service.inspect(plan);
        for (final status in statuses) {
          if (status.location == 'temporary') {
            paths.add(
              '${plan.directory}${Platform.pathSeparator}${status.item.temporary}',
            );
          }
        }
      } else {
        paths.addAll(
          plan.items.map(
            (item) =>
                '${plan.directory}${Platform.pathSeparator}${item.original}',
          ),
        );
      }
      if (cancelled || !await widget.renamePort.authorize(paths) || cancelled) {
        outcome = RenameOutcome(
          'cancelled',
          '修改授权已取消或停止，未开始本次文件写入。',
          0,
          plan.items.length,
        );
      } else {
        attempted = true;
        operationTimer.start();
        void onProgress(String stage, int done, int total) {
          progress.value = (stage, done, total);
        }

        outcome = resume
            ? await service.resume(
                plan,
                progress: onProgress,
                cancelled: () => cancelled,
                continueSafe: continueSafe,
              )
            : await service.execute(
                plan,
                progress: onProgress,
                cancelled: () => cancelled,
                acknowledgedPendingPaths: acknowledged,
              );
      }
    } catch (error) {
      outcome = RenameOutcome(
        'manual',
        '本次处理已停止：$error。已执行项目以实际核对为准；请保留事务记录。',
        0,
        plan.items.length,
      );
    } finally {
      operationTimer.stop();
      cancelled = true;
      if (mounted) progress.value = ('正在核对结果', 0, plan.items.length);
    }
    if (!mounted) {
      progress.dispose();
      return;
    }
    var mediaWarning = '';
    List<RenameItemStatus> statuses = const [];
    inspectTimer.start();
    if (attempted) {
      try {
        statuses = await service.inspect(plan);
      } catch (error) {
        mediaWarning = '逐项状态无法完整核对：$error';
      }
    }
    inspectTimer.stop();
    mediaTimer.start();
    if (attempted && statuses.isNotEmpty) {
      try {
        mediaWarning += await widget.renamePort.refresh([
          for (final status in statuses)
            if (['original', 'temporary', 'target'].contains(status.location))
              '${plan.directory}${Platform.pathSeparator}${switch (status.location) {
                'original' => status.item.original,
                'temporary' => status.item.temporary,
                _ => status.item.target,
              }}',
        ]);
      } catch (error) {
        mediaWarning += '\n媒体库刷新失败：$error；请稍后刷新，事务记录保留。';
      }
    }
    mediaTimer.stop();
    updateTimer.start();
    try {
      if (attempted) {
        await _loadPendingRenames();
        if (mounted) await _refreshRenamedImages(plan);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '刷新失败：$error');
    }
    updateTimer.stop();
    assert(() {
      debugPrint(
        'Android rename timing ms: operation=${operationTimer.elapsedMilliseconds}, inspect=${inspectTimer.elapsedMilliseconds}, media=${mediaTimer.elapsedMilliseconds}, ui=${updateTimer.elapsedMilliseconds}',
      );
      return true;
    }());
    if (!mounted) {
      progress.dispose();
      return;
    }
    Navigator.of(context, rootNavigator: true).pop();
    await progressClosed;
    progress.dispose();
    if (!mounted) return;
    setState(() => _renaming = false);
    if (mediaWarning.isNotEmpty) {
      outcome = RenameOutcome(
        outcome.state,
        '${outcome.details}\n$mediaWarning',
        outcome.done,
        outcome.total,
        issues: outcome.issues,
        canContinueSafe: outcome.canContinueSafe,
      );
    }
    final safe = await showDialog<bool>(
      context: context,
      builder: (_) => RenameResultDialog(
        outcome: outcome,
        statuses: statuses,
        offerSafeContinuation: resume && !continueSafe,
      ),
    );
    if (safe == true &&
        mounted &&
        await _confirmMediaAction(
          '只继续安全项目？',
          '将重新核对整个批次，只处理可确认安全的项目；异常项保留为未解决，不会把整批显示为完成。',
        )) {
      await _runMediaRename(plan, resume: true, continueSafe: true);
    }
  }

  Future<bool> _confirmMediaAction(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _showPendingRenames() async {
    try {
      await _loadPendingRenames();
    } catch (error) {
      if (mounted) setState(() => _error = '读取事务失败：$error');
      return;
    }
    if (!mounted) return;
    final record = await showDialog<PendingRenameTransaction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未解决事务'),
        content: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: _pendingRenames.isEmpty
              ? const Center(child: Text('没有未解决事务'))
              : ListView.builder(
                  itemCount: _pendingRenames.length,
                  itemBuilder: (_, index) {
                    final record = _pendingRenames[index];
                    return ListTile(
                      title: Text(record.plan?.id ?? '记录缺失或损坏'),
                      subtitle: Text(
                        record.plan == null
                            ? record.error ?? record.path
                            : '${record.plan!.directory}\n${record.plan!.items.length} 张',
                      ),
                      onTap: () => Navigator.pop(context, record),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (record == null || !mounted) return;
    final plan = record.plan;
    List<RenameItemStatus> statuses = const [];
    String? inspectError;
    String? uncertainDetail;
    if (plan != null) {
      try {
        statuses = await _renameService!.inspect(plan);
        uncertainDetail = await _renameService!.store.lastUncertainDetail(
          plan.id,
        );
      } catch (error) {
        inspectError = '无法核对：$error';
      }
    }
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('事务状态与恢复'),
        content: SizedBox(
          width: 600,
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: ListView(
            children: [
              SelectableText(record.path),
              if (record.error != null) Text(record.error!),
              if (inspectError != null) Text(inspectError),
              if (uncertainDetail != null) SelectableText(uncertainDetail),
              if (plan != null)
                for (final (index, item) in plan.items.indexed)
                  ListTile(
                    title: Text(item.original),
                    subtitle: Text(
                      '临时名：${item.temporary}\n目标：${item.target}\n'
                      '当前：${statuses.length == plan.items.length ? _mediaPosition(statuses[index].location) : '无法确认'}'
                      '${statuses.length == plan.items.length && statuses[index].problem != null ? '\n${statuses[index].problem}' : ''}',
                    ),
                  ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (plan != null) ...[
            TextButton(
              onPressed: () => Navigator.pop(context, 'resolved'),
              child: const Text('人工已处理'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'abandoned'),
              child: const Text('放弃处理'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'resume'),
              child: const Text('核对并处理'),
            ),
          ],
        ],
      ),
    );
    if (plan == null || !mounted) return;
    if (action == 'resume') {
      if (await _confirmMediaAction(
        '处理这笔未解决事务？',
        '会先核对实际名称与身份，再恢复第一阶段原名或续做第二阶段；无法确认的项目会停止并报告。',
      )) {
        await _runMediaRename(plan, resume: true);
      }
    } else if (action == 'resolved' || action == 'abandoned') {
      final abandoned = action == 'abandoned';
      if (await _confirmMediaAction(
        abandoned ? '放弃处理这笔事务？' : '标记为人工已处理？',
        '只追加结案记录，不修改图片。原计划保留，这笔记录不进入自动撤销历史。',
      )) {
        try {
          await _renameService!.store.closeManually(plan, abandoned: abandoned);
          await _loadPendingRenames();
        } catch (error) {
          if (mounted) setState(() => _error = '结案失败：$error');
        }
      }
    }
  }

  String _mediaPosition(String value) => switch (value) {
    'original' => '原名',
    'temporary' => '临时名',
    'target' => '目标名',
    _ => '无法确认',
  };

  Future<void> _showMediaHistory() async {
    final service = _renameService;
    if (service == null || _renaming) return;
    RenamePlan? selected;
    try {
      while (mounted) {
        final completed = await service.store.completed();
        final closed = await service.store.manuallyClosed();
        if (!mounted) return;
        final source = await showRenameHistory(
          context,
          completed,
          initialSelected: selected,
          onDelete: (ids) => service.store.deleteCompleted(ids),
          manualClosedCount: closed.length,
          onShowManualClosed: () {
            Navigator.pop(context);
            showDialog<void>(
              context: context,
              builder: (_) => ManualClosedHistoryDialog(records: closed),
            );
          },
        );
        if (source == null || !mounted) return;
        final reverse = await service.previewReverse(source);
        if (!mounted) return;
        if (!await showRenamePreview(
          context,
          reverse,
          platformNotice: _renameNotice,
        )) {
          selected = source;
          continue;
        }
        final acknowledged = await _acknowledgePending(reverse.directory);
        if (acknowledged != null && mounted) {
          await _runMediaRename(reverse, acknowledged: acknowledged);
        }
        return;
      }
    } catch (error) {
      if (mounted) setState(() => _error = '读取历史或撤销预演失败：$error');
    }
  }

  Future<void> _exportSelected() async {
    if (_selected.isEmpty || _exporting || _renaming) return;
    final selected = _selected.values.toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('复制到公共相册'),
        content: Text(
          '将 ${selected.length} 张图片复制到 Pictures/TagQuickShare/。原图不变；同名图片会跳过。复制品会保留原文件名，其他应用的最近照片排序可能不会置顶。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始复制'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _exporting = true;
      _cancelExport = false;
      _exportDone = 0;
      _exportTotal = selected.length;
      _error = null;
    });
    try {
      if (!await widget.probe.requestExportPermission()) {
        throw StateError('未取得公共目录写入权限');
      }
      var copied = 0;
      var skipped = 0;
      final issues = <MediaExportIssue>[];
      for (final image in selected) {
        if (_cancelExport || !mounted) break;
        try {
          final report = await widget.probe.exportImages([image.id]);
          copied += report.copied;
          skipped += report.skipped;
          issues.addAll(report.issues);
        } catch (error) {
          issues.add(MediaExportIssue(image.name, '$error'));
        }
        if (mounted) setState(() => _exportDone++);
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('复制结果'),
          content: SizedBox(
            width: 520,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  '已处理 $_exportDone / $_exportTotal 张 · 成功 $copied 张 · 同名跳过 $skipped 张 · 其他失败 ${issues.length - skipped} 张',
                ),
                if (_cancelExport) const Text('用户已停止，未处理的图片未复制。'),
                for (final issue in issues)
                  Text('${issue.name}：${issue.reason}'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      try {
        _albumImageCache.clear();
        await _loadAlbums();
      } catch (error) {
        if (mounted) setState(() => _error = '刷新媒体库失败：$error');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '复制失败：$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _tile(MediaImage image) {
    final selected = _selected.containsKey(image.id);
    final future =
        _thumbnails.remove(image.id) ?? widget.probe.thumbnail(image.id);
    _thumbnails[image.id] = future;
    while (_thumbnails.length > 256) {
      _thumbnails.remove(_thumbnails.keys.first);
    }
    return InkWell(
      onTap: _renaming || _exporting
          ? null
          : () => setState(() {
              if (!selected) {
                _selected[image.id] = image;
              } else {
                _selected.remove(image.id);
              }
            }),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List>(
              future: future,
              builder: (_, snapshot) => snapshot.hasData
                  ? Image.memory(
                      snapshot.data!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    )
                  : Center(
                      child: snapshot.hasError
                          ? const Icon(Icons.broken_image_outlined)
                          : const CircularProgressIndicator(strokeWidth: 2),
                    ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                color: Colors.black54,
                width: double.infinity,
                padding: const EdgeInsets.all(4),
                child: Text(
                  image.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? Colors.tealAccent : Colors.white,
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                tooltip: '查看原图',
                padding: const EdgeInsets.all(10),
                style: IconButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.transparent,
                ),
                icon: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(Icons.open_in_full, size: 15),
                  ),
                ),
                onPressed: _renaming || _exporting
                    ? null
                    : () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => AndroidImageViewerPage(
                            image: image,
                            probe: widget.probe,
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final directoryNodes = mediaDirectoryTree(_albums, compact: true);
    final options = _filterOptions;
    final compactButton = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 8),
      ),
      textStyle: WidgetStatePropertyAll(
        Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
      ),
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    final controlsTheme = Theme.of(context).copyWith(
      textButtonTheme: TextButtonThemeData(style: compactButton),
      outlinedButtonTheme: OutlinedButtonThemeData(style: compactButton),
      filledButtonTheme: FilledButtonThemeData(style: compactButton),
    );
    final summary =
        '全部 ${_indexedImages == null ? '…' : '${_matchedImages.length}/${_indexedImages!.length}'} · 本文件夹 ${visible.length}/${_images.length} · 已选 ${_selected.length}';
    final locked = _busy || _renaming || _exporting || _preparation != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('图签', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '使用指南',
            icon: const Icon(Icons.error_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => UsageGuidePage(
                  preferences: LocalGuidePreferences(),
                  assetPath: UsageGuidePage.androidAssetPath,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '管理可见目录',
            icon: const Icon(Icons.folder_off_outlined),
            onPressed: _busy || _renaming || _exporting
                ? null
                : _manageVisibleAlbums,
          ),
          IconButton(
            tooltip: '历史操作',
            icon: const Icon(Icons.history),
            onPressed: _renaming || _busy ? null : _showMediaHistory,
          ),
          if (_profiles == null) const AppAboutMenuButton(),
          if (_profiles != null)
            PopupMenuButton<String>(
              tooltip: '配置与标签组',
              enabled: !_renaming && !_busy && !_exporting,
              onSelected: (value) {
                if (value == 'about') {
                  openAppAbout(context);
                } else if (value == 'cleanup') {
                  _openExportCleanup();
                } else if (value == 'new') {
                  _newProfile();
                } else if (value == 'import') {
                  _importGroups();
                } else if (value == 'rename') {
                  _renameProfile();
                } else if (value == 'export') {
                  _exportGroups();
                } else if (value == 'delete') {
                  _deleteProfile();
                } else if (value == 'names') {
                  _editGroups(TagGroupEditorMode.names);
                } else if (value == 'categories') {
                  _editGroups(TagGroupEditorMode.categories);
                } else {
                  _switchProfile(value);
                }
              },
              itemBuilder: (_) => [
                for (final profile in _profiles!.profiles)
                  PopupMenuItem(
                    value: profile.id,
                    child: Text(
                      '${profile.id == _profiles!.activeId ? '✓ ' : ''}${profile.name}',
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'new', child: Text('新建空配置')),
                const PopupMenuItem(value: 'rename', child: Text('重命名当前配置')),
                const PopupMenuItem(value: 'export', child: Text('导出当前配置')),
                const PopupMenuItem(value: 'delete', child: Text('删除当前配置')),
                const PopupMenuItem(
                  value: 'import',
                  child: Text('导入单份 JSON 配置'),
                ),
                const PopupMenuItem(value: 'cleanup', child: Text('清理导出副本')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'about', child: Text('关于图签')),
              ],
            ),
        ],
      ),
      bottomNavigationBar:
          _selected.isNotEmpty || _preparation != null || _exporting
          ? Theme(
              data: controlsTheme,
              child: Material(
                elevation: 8,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    key: const ValueKey('media-selection-actions'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '已选 ${_selected.length} 张 · 本目录 ${_images.where((item) => _selected.containsKey(item.id)).length} · 其他目录 ${_selected.length - _images.where((item) => _selected.containsKey(item.id)).length}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: _selected.isEmpty || locked
                                  ? null
                                  : _previewEdit,
                              child: const Text('编辑并打标'),
                            ),
                            FilledButton(
                              onPressed: _selected.isEmpty || locked
                                  ? null
                                  : _exportSelected,
                              child: const Text('复制到公共相册'),
                            ),
                          ],
                        ),
                        if (_preparation != null) ...[
                          LinearProgressIndicator(
                            value: _preparationTotal == 0
                                ? null
                                : _preparedImages / _preparationTotal,
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _preparation!.cancelled
                                      ? '正在取消准备…'
                                      : '正在准备编辑 $_preparedImages/$_preparationTotal 张',
                                ),
                              ),
                              TextButton(
                                onPressed: _preparation!.cancelled
                                    ? null
                                    : () {
                                        final pending = _preparation!;
                                        pending.cancel();
                                        setState(() {});
                                      },
                                child: const Text('取消准备'),
                              ),
                            ],
                          ),
                        ],
                        if (_exporting)
                          Row(
                            children: [
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: _exportTotal == 0
                                      ? null
                                      : _exportDone / _exportTotal,
                                ),
                              ),
                              Text(' $_exportDone/$_exportTotal '),
                              TextButton(
                                onPressed: _cancelExport
                                    ? null
                                    : () =>
                                          setState(() => _cancelExport = true),
                                child: Text(_cancelExport ? '停止中…' : '停止'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : null,
      body: Theme(
        data: controlsTheme,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final textScaler = MediaQuery.textScalerOf(context);
            final rowHeight = (textScaler.scale(16) * 1.5 + 16).clamp(
              48.0,
              80.0,
            );
            final summaryStyle = Theme.of(context).textTheme.bodySmall!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_toolsExpanded)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.4,
                    ),
                    child: SingleChildScrollView(
                      key: const ValueKey('media-preparation-controls'),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    PopupMenuButton<MediaImageSort>(
                                      tooltip: '选择图片排序',
                                      enabled:
                                          !_busy && !_renaming && !_exporting,
                                      onSelected: _changeImageSort,
                                      itemBuilder: (_) => [
                                        for (final sort
                                            in MediaImageSort.values)
                                          CheckedPopupMenuItem(
                                            value: sort,
                                            checked: sort == _imageSort,
                                            child: Text(sort.label),
                                          ),
                                      ],
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          minHeight: 48,
                                        ),
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            '排序：${_imageSort.label} ▾',
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Tooltip(
                                message: '授权并刷新媒体库',
                                child: TextButton.icon(
                                  onPressed: _busy || _exporting || _renaming
                                      ? null
                                      : _requestAndList,
                                  icon: const Icon(Icons.refresh, size: 20),
                                  label: Text(
                                    _busy
                                        ? '读取中…'
                                        : _access == MediaAccess.full
                                        ? '刷新'
                                        : '授权/刷新',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_images.isNotEmpty) ...[
                            Wrap(
                              spacing: 8,
                              runSpacing: 0,
                              children: [
                                OutlinedButton(
                                  onPressed:
                                      _profiles == null ||
                                          _busy ||
                                          _renaming ||
                                          _exporting
                                      ? null
                                      : () => _editGroups(
                                          TagGroupEditorMode.names,
                                        ),
                                  child: const Text('标签名组'),
                                ),
                                OutlinedButton(
                                  onPressed:
                                      _profiles == null ||
                                          _busy ||
                                          _renaming ||
                                          _exporting
                                      ? null
                                      : () => _editGroups(
                                          TagGroupEditorMode.categories,
                                        ),
                                  child: const Text('标签类组'),
                                ),
                                Align(
                                  widthFactor: 1,
                                  alignment: Alignment.centerLeft,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Checkbox(
                                        value: _onlyUntagged,
                                        onChanged: (value) => setState(() {
                                          _onlyUntagged = value ?? false;
                                          if (_onlyUntagged) _roles.clear();
                                          _selected.clear();
                                          _recalculateMatches();
                                        }),
                                      ),
                                      Text(
                                        '仅显示无标签',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge
                                            ?.copyWith(fontSize: 13),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (_indexing) const Text('正在统计全部文件夹的匹配数…'),
                          if (_indexError != null)
                            Text(
                              _indexError!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          SizedBox(
                            height: rowHeight,
                            child: Row(
                              children: [
                                Expanded(
                                  child: _albums.isNotEmpty
                                      ? DropdownButton<String>(
                                          isExpanded: true,
                                          value:
                                              directoryNodes.any(
                                                (node) =>
                                                    node.folder.id == _album &&
                                                    node.album != null,
                                              )
                                              ? _album
                                              : null,
                                          itemHeight: null,
                                          selectedItemBuilder: (_) => [
                                            for (final node in directoryNodes)
                                              Align(
                                                alignment: Alignment.centerLeft,
                                                child: Text(
                                                  node.shortName,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                          ],
                                          items: [
                                            for (final node in directoryNodes)
                                              DropdownMenuItem(
                                                value: node.folder.id,
                                                enabled: node.album != null,
                                                child: Padding(
                                                  padding: EdgeInsets.only(
                                                    top: 4,
                                                    bottom: 4,
                                                    left: (node.depth * 12.0)
                                                        .clamp(0, 60),
                                                  ),
                                                  child: Tooltip(
                                                    message: node.folder.name,
                                                    child: Text(
                                                      '${node.depth > 0 ? '↳ ' : ''}${node.album == null ? '${node.shortName}/  0 张' : _albumLabel(node.album!).replaceFirst(node.album!.name, node.shortName)}',
                                                      style: TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            node.album != null
                                                            ? FontWeight.w600
                                                            : FontWeight.normal,
                                                        color:
                                                            node.album != null
                                                            ? Theme.of(context)
                                                                  .colorScheme
                                                                  .onSurface
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .onSurfaceVariant
                                                                  .withValues(
                                                                    alpha: 0.65,
                                                                  ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                          onChanged:
                                              _busy || _exporting || _renaming
                                              ? null
                                              : (value) {
                                                  if (value != null &&
                                                      !_busy &&
                                                      _albums.any(
                                                        (item) =>
                                                            item.id == value,
                                                      )) {
                                                    _loadImages(value);
                                                  }
                                                },
                                        )
                                      : const Text('暂无可用目录'),
                                ),
                                const SizedBox(width: 8),
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: (constraints.maxWidth - 80).clamp(
                                      0.0,
                                      double.infinity,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: OutlinedButton.icon(
                                          onPressed:
                                              options.isEmpty ||
                                                  _exporting ||
                                                  _renaming
                                              ? null
                                              : () =>
                                                    _showFilterDialog(options),
                                          icon: const Icon(Icons.filter_list),
                                          label: Text(
                                            '组合筛选${_roles.isEmpty ? '' : '（${_roles.length}）'}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      if (_roles.isNotEmpty || _onlyUntagged)
                                        TextButton(
                                          onPressed: _exporting
                                              ? null
                                              : () => setState(() {
                                                  _roles.clear();
                                                  _onlyUntagged = false;
                                                  _selected.clear();
                                                  _recalculateMatches();
                                                }),
                                          child: const Text('清空筛选'),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_roles.isNotEmpty)
                            SizedBox(
                              height: 40,
                              key: const ValueKey('media-active-filters'),
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  for (final option in options.entries)
                                    if (_roles.containsKey(option.key))
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: Builder(
                                          builder: (buttonContext) =>
                                              OutlinedButton(
                                                style: OutlinedButton.styleFrom(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 0,
                                                      ),
                                                  minimumSize: const Size(
                                                    0,
                                                    32,
                                                  ),
                                                  tapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                  backgroundColor: _roleColor(
                                                    _roles[option.key]!,
                                                  ),
                                                ),
                                                onPressed: () => _showRoleMenu(
                                                  buttonContext,
                                                  option.key,
                                                  () {},
                                                ),
                                                child: Text(
                                                  _filterButtonText(
                                                    option.value,
                                                    _roles[option.key]!,
                                                  ),
                                                ),
                                              ),
                                        ),
                                      ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  key: const ValueKey('media-controls'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_pendingRenames.isNotEmpty ||
                          _suspectedRecords.isNotEmpty)
                        SizedBox(
                          height: 48,
                          child: TextButton.icon(
                            icon: const Icon(Icons.warning_amber_rounded),
                            onPressed: _pendingRenames.isNotEmpty
                                ? _showPendingRenames
                                : () => showDialog<void>(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      title: const Text('疑似事务记录缺失'),
                                      content: SingleChildScrollView(
                                        child: SelectableText(
                                          _suspectedRecords
                                              .map(
                                                (record) =>
                                                    '批次：${record.id ?? "无法识别"} · ${record.filenames.length} 张临时名图片。请保留现场并核查备份；程序不会自动重建。',
                                              )
                                              .join('\n\n'),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          child: const Text('关闭'),
                                        ),
                                      ],
                                    ),
                                  ),
                            label: Text(
                              _pendingRenames.isNotEmpty
                                  ? '未解决事务（${_pendingRenames.length}）'
                                  : '疑似事务记录缺失（${_suspectedRecords.length}）',
                            ),
                          ),
                        ),
                      if (_error != null)
                        SizedBox(
                          height: 48,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _error!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '查看错误详情',
                                icon: const Icon(Icons.info_outline),
                                onPressed: () => showDialog<void>(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: const Text('操作提示'),
                                    content: SingleChildScrollView(
                                      child: SelectableText(_error!),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('关闭'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '关闭提示',
                                icon: const Icon(Icons.close),
                                onPressed: () => setState(() => _error = null),
                              ),
                            ],
                          ),
                        ),

                      Text(summary, style: summaryStyle),
                      Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 4,
                              children: [
                                TextButton(
                                  onPressed: locked || visible.isEmpty
                                      ? null
                                      : () => setState(
                                          () => _selected.addEntries(
                                            visible.map(
                                              (item) => MapEntry(item.id, item),
                                            ),
                                          ),
                                        ),
                                  child: const Text('全选本页'),
                                ),
                                Tooltip(
                                  message:
                                      '全选全部文件夹匹配（${_indexedImages == null ? '…' : _matchedImages.length} 张）',
                                  child: TextButton(
                                    key: const ValueKey('select-all-media'),
                                    onPressed:
                                        locked ||
                                            _indexedImages == null ||
                                            _indexing ||
                                            _matchedImages.isEmpty
                                        ? null
                                        : () => setState(
                                            () => _selected.addAll(
                                              _matchedImages,
                                            ),
                                          ),
                                    child: const Text('全选全部'),
                                  ),
                                ),
                                TextButton(
                                  onPressed:
                                      locked ||
                                          !_images.any(
                                            (item) =>
                                                _selected.containsKey(item.id),
                                          )
                                      ? null
                                      : () => setState(() {
                                          for (final item in _images) {
                                            _selected.remove(item.id);
                                          }
                                        }),
                                  child: const Text('清空本页'),
                                ),
                                TextButton(
                                  onPressed: locked || _selected.isEmpty
                                      ? null
                                      : () => setState(_selected.clear),
                                  child: const Text('清空全部'),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('media-toggle-tools'),
                            tooltip: _toolsExpanded ? '收起工具栏' : '展开工具栏',
                            isSelected: _toolsExpanded,
                            onPressed: () => setState(
                              () => _toolsExpanded = !_toolsExpanded,
                            ),
                            icon: Icon(
                              _toolsExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: CustomScrollView(
                    key: const ValueKey('media-scroll'),
                    slivers: [
                      if (_busy && _images.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (visible.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text(
                              _access == MediaAccess.denied
                                  ? '请授权照片访问'
                                  : _allAlbums.isNotEmpty && _albums.isEmpty
                                  ? '目录均已隐藏，可从顶栏管理可见目录恢复'
                                  : '此目录没有匹配的图片',
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.all(8),
                          sliver: SliverGrid(
                            key: const ValueKey('media-results'),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 160,
                                  mainAxisSpacing: 4,
                                  crossAxisSpacing: 4,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (_, index) => KeyedSubtree(
                                key: ValueKey(
                                  'media-tile-${visible[index].id}',
                                ),
                                child: _tile(visible[index]),
                              ),
                              childCount: visible.length,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
