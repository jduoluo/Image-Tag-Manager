import 'dart:io';

import 'package:flutter/material.dart';

import '../infrastructure/android_media_probe.dart';

/// Read-only full-screen viewer; owns one temporary original and its decoded image.
final class AndroidImageViewerPage extends StatefulWidget {
  const AndroidImageViewerPage({
    required this.image,
    required this.probe,
    super.key,
  });
  final MediaImage image;
  final AndroidMediaProbe probe;

  @override
  State<AndroidImageViewerPage> createState() => _AndroidImageViewerPageState();
}

final class _AndroidImageViewerPageState extends State<AndroidImageViewerPage> {
  final _transform = TransformationController();
  late final Future<ImageProvider> _original = _open();
  String? _token;
  ImageProvider? _provider;
  bool _closed = false;

  Future<ImageProvider> _open() async {
    final result = await widget.probe.openOriginalImage(widget.image.id);
    _token = result['token'] as String;
    // Decode from original, never the grid thumbnail; limit peak frame dimensions.
    final provider = ResizeImage(
      FileImage(File(result['path'] as String)),
      width: 4096,
      height: 4096,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    );
    _provider = provider;
    if (_closed) await _release();
    return provider;
  }

  Future<void> _release() async {
    await _provider?.evict();
    final token = _token;
    _token = null;
    if (token != null) {
      try {
        await widget.probe.closeOriginalImage(token);
      } catch (_) {
        // Android's cache/session cleanup removes leftovers after process interruption.
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _release();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: Text(
        widget.image.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: '重置缩放',
          onPressed: () => _transform.value = Matrix4.identity(),
          icon: const Icon(Icons.center_focus_strong),
        ),
      ],
    ),
    body: FutureBuilder<ImageProvider>(
      future: _original,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text(
              '无法读取原图。请检查照片权限、文件是否存在或是否超过 128 MiB。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return InteractiveViewer(
          transformationController: _transform,
          minScale: 0.5,
          maxScale: 8,
          child: Center(
            child: Image(
              image: snapshot.data!,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  const Text('无法解码此图片', style: TextStyle(color: Colors.white)),
            ),
          ),
        );
      },
    ),
    bottomNavigationBar: const SafeArea(
      child: Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          '双指缩放 · 拖动查看 · 返回图片列表',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
      ),
    ),
  );
}
