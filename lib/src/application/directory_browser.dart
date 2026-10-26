import 'dart:async';

import '../domain/filename_tags.dart';

/// 扫描结果只包含文件身份和文件名信息，不读取图片内容。
final class ImageEntry {
  const ImageEntry({
    required this.id,
    required this.filename,
    required this.parsedFilename,
    this.fileId,
  });

  final String id;
  final String filename;
  final ParsedFilename parsedFilename;

  /// Platform file identity captured during the directory scan, if available.
  final String? fileId;
}

/// 目录选择与目录读取由各平台实现，界面只依赖这两个能力。
abstract interface class DirectoryChooser {
  Future<String?> chooseDirectory();
}

abstract interface class ImageDirectorySource {
  Stream<ImageEntry> scanCurrentDirectory(String path);
  Stream<String> listSubdirectories(String path);
}

final class ScanRoot {
  const ScanRoot(this.path, {this.recursive = false});
  final String path;
  final bool recursive;
}

final class FolderScanEvent {
  const FolderScanEvent(
    this.root,
    this.path, {
    this.entry,
    this.done = false,
    this.error,
  });
  final String root;
  final String path;
  final ImageEntry? entry;
  final bool done;
  final Object? error;
}

final class DirectoryBrowser {
  const DirectoryBrowser({required this.chooser, required this.source});

  final DirectoryChooser chooser;
  final ImageDirectorySource source;

  Future<String?> chooseDirectory() => chooser.chooseDirectory();

  Stream<ImageEntry> scanCurrentDirectory(String path) =>
      source.scanCurrentDirectory(path);

  Stream<FolderScanEvent> scanRoots(Iterable<ScanRoot> roots) {
    late StreamController<FolderScanEvent> controller;
    StreamSubscription<dynamic>? active;
    Completer<void>? pending;
    var cancelled = false;

    void emit(FolderScanEvent event) {
      if (!cancelled && !controller.isClosed) controller.add(event);
    }

    Future<void> scanFolder(String root, String path) async {
      if (cancelled) return;
      emit(FolderScanEvent(root, path));
      final done = Completer<void>();
      pending = done;
      try {
        active = source
            .scanCurrentDirectory(path)
            .listen(
              (entry) => emit(FolderScanEvent(root, path, entry: entry)),
              onError: (Object error) =>
                  emit(FolderScanEvent(root, path, error: error)),
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
            );
        await done.future;
      } catch (error) {
        emit(FolderScanEvent(root, path, error: error));
      } finally {
        active = null;
        pending = null;
      }
      if (!cancelled) emit(FolderScanEvent(root, path, done: true));
    }

    Future<List<String>> childrenOf(String root) async {
      final children = <String>[];
      final done = Completer<void>();
      pending = done;
      try {
        active = source
            .listSubdirectories(root)
            .listen(
              children.add,
              onError: (Object error) =>
                  emit(FolderScanEvent(root, root, error: error)),
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
            );
        await done.future;
      } catch (error) {
        emit(FolderScanEvent(root, root, error: error));
      } finally {
        active = null;
        pending = null;
      }
      children.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return children;
    }

    Future<void> run() async {
      try {
        for (final root in roots) {
          if (cancelled) break;
          await scanFolder(root.path, root.path);
          if (cancelled || !root.recursive) continue;
          final children = await childrenOf(root.path);
          for (final child in children) {
            if (cancelled) break;
            await scanFolder(root.path, child);
          }
        }
      } finally {
        if (!cancelled && !controller.isClosed) await controller.close();
      }
    }

    controller = StreamController<FolderScanEvent>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        cancelled = true;
        await active?.cancel();
        if (pending != null && !pending!.isCompleted) pending!.complete();
      },
    );
    return controller.stream;
  }
}
