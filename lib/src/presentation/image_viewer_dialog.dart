import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../infrastructure/windows_file_reveal.dart';

typedef RevealImageFile = Future<void> Function(String path);

Future<void> showImageViewer(
  BuildContext context, {
  required String path,
  required String filename,
  RevealImageFile revealFile = revealFileInExplorer,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ImageViewerDialog(
    path: path,
    filename: filename,
    revealFile: revealFile,
  ),
);

final class _ImageViewerDialog extends StatefulWidget {
  const _ImageViewerDialog({
    required this.path,
    required this.filename,
    required this.revealFile,
  });

  final String path;
  final String filename;
  final RevealImageFile revealFile;

  @override
  State<_ImageViewerDialog> createState() => _ImageViewerDialogState();
}

final class _ImageViewerDialogState extends State<_ImageViewerDialog> {
  final TransformationController _transform = TransformationController();
  bool _openingExplorer = false;

  Future<void> _revealFile() async {
    if (_openingExplorer) return;
    setState(() => _openingExplorer = true);
    try {
      await widget.revealFile(widget.path);
    } catch (error) {
      if (mounted) {
        _showMessage('无法在文件资源管理器中定位图片：$error');
      }
    } finally {
      if (mounted) setState(() => _openingExplorer = false);
    }
  }

  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  void _showMessage(String message) {
    final messenger = _messengerKey.currentState;
    messenger?.removeCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _copy(String value, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) _showMessage('已复制$label');
    } catch (error) {
      if (mounted) _showMessage('复制$label失败：$error');
    }
  }

  Widget _copyChip({
    required String value,
    required String copyValue,
    required String copiedLabel,
    required String tooltip,
  }) => Tooltip(
    message: tooltip,
    child: OutlinedButton(
      onPressed: () => _copy(copyValue, copiedLabel),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 48),
      ),
      child: Text(
        value,
        maxLines: 2,
        softWrap: true,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 950;
    final folder = File(widget.path).parent.path;
    final folderLabel = folder.endsWith(Platform.pathSeparator)
        ? folder
        : '$folder${Platform.pathSeparator}';
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 1100,
        height: 800,
        child: ScaffoldMessenger(
          key: _messengerKey,
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              toolbarHeight: 72,
              titleSpacing: 12,
              title: Row(
                children: [
                  Flexible(
                    flex: 3,
                    child: _copyChip(
                      value: folderLabel,
                      copyValue: widget.path,
                      copiedLabel: '完整路径',
                      tooltip: '点击复制图片完整路径',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    flex: 2,
                    child: _copyChip(
                      value: widget.filename,
                      copyValue: widget.filename,
                      copiedLabel: '文件名',
                      tooltip: '点击复制文件名',
                    ),
                  ),
                ],
              ),
              actions: [
                if (!compact) const Center(child: Text('点击方块复制 · 滚轮缩放')),
                IconButton(
                  tooltip: '重置缩放',
                  onPressed: () => _transform.value = Matrix4.identity(),
                  icon: const Icon(Icons.center_focus_strong),
                ),
                IconButton(
                  tooltip: '在文件资源管理器中显示',
                  onPressed: _openingExplorer ? null : _revealFile,
                  icon: const Icon(Icons.folder_open),
                ),
                if (compact)
                  IconButton(
                    tooltip: '返回图片列表',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                  )
                else
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回图片列表'),
                  ),
                const SizedBox(width: 8),
              ],
            ),
            backgroundColor: Colors.black,
            body: InteractiveViewer(
              transformationController: _transform,
              minScale: 0.5,
              maxScale: 8,
              child: Center(
                child: Image.file(
                  File(widget.path),
                  fit: BoxFit.contain,
                  errorBuilder: (_, error, stackTrace) => const Text(
                    '无法打开此图片',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
