import 'package:flutter/material.dart';

import '../infrastructure/guide_preferences.dart';

/// Platform-specific Markdown and local images are bundled at build time.
final class UsageGuidePage extends StatefulWidget {
  const UsageGuidePage({
    required this.assetPath,
    this.preferences,
    this.onClose,
    super.key,
  });
  static const androidAssetPath = 'docs/ANDROID_USER_GUIDE.md';
  static const windowsAssetPath = 'docs/WINDOWS_USER_GUIDE.md';
  final String assetPath;
  final GuidePreferences? preferences;
  final VoidCallback? onClose;
  @override
  State<UsageGuidePage> createState() => _UsageGuidePageState();
}

final class _UsageGuidePageState extends State<UsageGuidePage> {
  AssetBundle? _bundle;
  Future<String>? _contents;
  bool _suppressed = false;
  bool _loadingPreference = true;
  bool _savingPreference = false;
  String? _preferenceError;

  @override
  void initState() {
    super.initState();
    _loadPreference();
  }

  Future<void> _loadPreference() async {
    try {
      final value = await widget.preferences?.loadSuppressed() ?? false;
      if (mounted) setState(() => _suppressed = value);
    } catch (_) {
      if (mounted) setState(() => _preferenceError = '启动设置读取失败，可重新切换开关保存。');
    } finally {
      if (mounted) setState(() => _loadingPreference = false);
    }
  }

  Future<void> _savePreference(bool value) async {
    setState(() => _savingPreference = true);
    try {
      await widget.preferences!.saveSuppressed(value);
      if (mounted) {
        setState(() {
          _suppressed = value;
          _preferenceError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _preferenceError = '启动设置保存失败，请重试；本次更改未确认。');
    } finally {
      if (mounted) setState(() => _savingPreference = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = DefaultAssetBundle.of(context);
    if (_bundle != bundle) {
      _bundle = bundle;
      _contents = bundle.loadString(widget.assetPath);
    }
  }

  @override
  void didUpdateWidget(covariant UsageGuidePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetPath != widget.assetPath) {
      _bundle = DefaultAssetBundle.of(context);
      _contents = _bundle!.loadString(widget.assetPath);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('使用指南'),
      leading: widget.onClose == null
          ? null
          : IconButton(
              tooltip: '进入图片列表',
              icon: const Icon(Icons.arrow_back),
              onPressed: _savingPreference ? null : widget.onClose,
            ),
    ),
    bottomNavigationBar: widget.preferences == null
        ? null
        : SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('下次打开不再自动弹出'),
                  value: _suppressed,
                  onChanged: _loadingPreference || _savingPreference
                      ? null
                      : _savePreference,
                ),
                if (_preferenceError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Text(_preferenceError!),
                  ),
              ],
            ),
          ),
    body: FutureBuilder<String>(
      future: _contents,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('使用指南加载失败'),
                TextButton(
                  onPressed: () => setState(() {
                    _contents = _bundle!.loadString(
                      widget.assetPath,
                      cache: false,
                    );
                  }),
                  child: const Text('重试'),
                ),
              ],
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return GuideMarkdown(contents: snapshot.data!);
      },
    ),
  );
}

/// Offline subset: headings, paragraphs, lists, bold, inline code and local images.
/// Unsupported syntax stays plain text. No HTML, remote resources or link execution.
final class GuideMarkdown extends StatelessWidget {
  const GuideMarkdown({required this.contents, super.key});
  final String contents;

  String? _imageAsset(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.startsWith('guide_images/') ||
        uri.pathSegments.any((part) => part == '..' || part.contains('\\')) ||
        !RegExp(
          r'\.(png|jpe?g|webp|gif)$',
          caseSensitive: false,
        ).hasMatch(uri.path)) {
      return null;
    }
    return 'docs/${uri.path}';
  }

  Widget _image(BuildContext context, String caption, String source) {
    final asset = _imageAsset(source);
    final label = caption.isEmpty ? '指南图片' : caption;
    Widget failure() => Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text('$label：图片无法显示，请检查本地图片资源。'),
    );
    Widget picture() => Image.asset(
      asset!,
      fit: BoxFit.contain,
      semanticLabel: label,
      errorBuilder: (_, error, stack) => failure(),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (asset == null)
            failure()
          else
            Semantics(
              button: true,
              label: '放大查看：$label',
              child: InkWell(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(label),
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭图片',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        Expanded(
                          child: ClipRect(
                            child: InteractiveViewer(
                              minScale: 1,
                              maxScale: 5,
                              child: Center(child: picture()),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                child: picture(),
              ),
            ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                caption,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  List<InlineSpan> _inline(String text) {
    final spans = <InlineSpan>[];
    final expression = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var end = 0;
    for (final match in expression.allMatches(text)) {
      if (match.start > end) {
        spans.add(TextSpan(text: text.substring(end, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(1) ?? match.group(2),
          style: TextStyle(
            fontWeight: match.group(1) != null ? FontWeight.w700 : null,
            fontFamily: match.group(2) != null ? 'monospace' : null,
          ),
        ),
      );
      end = match.end;
    }
    if (end < text.length) spans.add(TextSpan(text: text.substring(end)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    final paragraph = <String>[];
    final textStyle = Theme.of(context).textTheme.bodyLarge!
        .copyWith(height: 1.6);
    Widget text(String value, {TextStyle? style}) => Text.rich(
      TextSpan(children: _inline(value)),
      style: style ?? textStyle,
    );
    void flush() {
      if (paragraph.isEmpty) return;
      blocks.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: text(paragraph.join('\n')),
        ),
      );
      paragraph.clear();
    }

    for (final raw in contents.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      final image = RegExp(r'^!\[([^\]]*)\]\(([^)]+)\)$').firstMatch(line);
      final heading = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(line);
      final list = RegExp(r'^(?:[-*]\s+|(\d+)[.)]\s+)(.+)$').firstMatch(line);
      if (line.isEmpty) {
        flush();
      } else if (image != null) {
        flush();
        blocks.add(_image(context, image.group(1)!, image.group(2)!));
      } else if (heading != null) {
        flush();
        final level = heading.group(1)!.length;
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 12),
            child: text(
              heading.group(2)!,
              style: textStyle.copyWith(
                fontSize: level == 1
                    ? 24
                    : level == 2
                    ? 21
                    : 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      } else if (list != null) {
        flush();
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    list.group(1) == null ? '•' : '${list.group(1)}.',
                    style: textStyle,
                  ),
                ),
                Expanded(child: text(list.group(2)!)),
              ],
            ),
          ),
        );
      } else {
        paragraph.add(line);
      }
    }
    flush();
    return SelectionArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: blocks,
          ),
        ),
      ),
    );
  }
}
