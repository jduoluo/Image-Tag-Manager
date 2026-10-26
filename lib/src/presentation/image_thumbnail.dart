import 'dart:io';

import 'package:flutter/material.dart';

/// 只为已构建的网格卡片加载图片；GIF 固定显示解码后的第一帧。
final class ImageThumbnail extends StatefulWidget {
  const ImageThumbnail({required this.path, super.key});

  final String path;

  @override
  State<ImageThumbnail> createState() => _ImageThumbnailState();
}

final class _ImageThumbnailState extends State<ImageThumbnail> {
  ImageInfo? _gifFrame;
  ImageStream? _gifStream;
  ImageStreamListener? _gifListener;
  bool _gifFailed = false;

  bool get _isGif => widget.path.toLowerCase().endsWith('.gif');

  @override
  void initState() {
    super.initState();
    if (_isGif) _loadGifFrame();
  }

  @override
  void didUpdateWidget(ImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path == widget.path) return;
    _detachGifStream();
    _gifFrame?.dispose();
    _gifFrame = null;
    _gifFailed = false;
    if (_isGif) _loadGifFrame();
  }

  void _detachGifStream() {
    final stream = _gifStream;
    final listener = _gifListener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _gifStream = null;
    _gifListener = null;
  }

  void _loadGifFrame() {
    final path = widget.path;
    final stream = ResizeImage(
      FileImage(File(path)),
      width: 320,
      height: 320,
      allowUpscaling: false,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, _) {
        if (!mounted || widget.path != path) return;
        final firstFrame = image.clone();
        _detachGifStream();
        setState(() => _gifFrame = firstFrame);
      },
      onError: (error, stackTrace) {
        if (!mounted || widget.path != path) return;
        _detachGifStream();
        setState(() => _gifFailed = true);
      },
      reportErrors: false,
    );
    _gifStream = stream;
    _gifListener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    _detachGifStream();
    _gifFrame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isGif) {
      if (_gifFailed) return const _ThumbnailUnavailable();
      final frame = _gifFrame;
      return frame == null
          ? const _ThumbnailLoading()
          : RawImage(image: frame.image, fit: BoxFit.cover);
    }

    return Image.file(
      File(widget.path),
      cacheWidth: 320,
      cacheHeight: 320,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
          wasSynchronouslyLoaded || frame != null
          ? child
          : const _ThumbnailLoading(),
      errorBuilder: (context, error, stackTrace) =>
          const _ThumbnailUnavailable(),
    );
  }
}

final class _ThumbnailLoading extends StatelessWidget {
  const _ThumbnailLoading();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Icon(Icons.image_outlined, color: Colors.grey));
}

final class _ThumbnailUnavailable extends StatelessWidget {
  const _ThumbnailUnavailable();

  @override
  Widget build(BuildContext context) => const Center(
    child: Tooltip(
      message: '无法预览此图片',
      child: Icon(Icons.broken_image_outlined),
    ),
  );
}
