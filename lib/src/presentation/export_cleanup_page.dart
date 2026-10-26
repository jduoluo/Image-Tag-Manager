import 'package:flutter/material.dart';

import '../infrastructure/android_media_probe.dart';

final class ExportCleanupPage extends StatefulWidget {
  const ExportCleanupPage({required this.probe, this.onChanged, super.key});
  final AndroidMediaProbe probe;
  final void Function(Set<int> deletedIds, bool uncertain)? onChanged;
  @override
  State<ExportCleanupPage> createState() => _ExportCleanupPageState();
}

final class _ExportCleanupPageState extends State<ExportCleanupPage> {
  List<Map<Object?, Object?>> _items = [];
  final _selected = <int>{};
  final _scroll = ScrollController();
  String? _token;
  String? _error;
  String? _result;
  int _excluded = 0;
  bool _busy = false;
  bool _deleting = false;
  bool _stop = false;
  int _processed = 0;
  int _total = 0;
  @override
  void initState() {
    super.initState();
    _preview();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _size(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(2)} MiB';
  Future<void> _preview() async {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _busy = true;
      _error = null;
      _selected.clear();
      _items = [];
      _token = null;
    });
    try {
      final row = await widget.probe.previewExportCleanup();
      if (!mounted) return;
      setState(() {
        _items = (row['items'] as List)
            .map((item) => Map<Object?, Object?>.from(item as Map))
            .toList();
        _token = row['token'] as String;
        _excluded = row['excluded'] as int;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final token = _token;
    if (_selected.isEmpty || token == null || _busy) return;
    final ids = _selected.toList();
    final size = _items
        .where((row) => _selected.contains(row['id']))
        .fold<int>(0, (sum, row) => sum + (row['size'] as int));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除导出副本'),
        content: Text(
          '永久删除选中的 ${ids.length} 张导出副本（${_size(size)}）？\n仅处理 Pictures/TagQuickShare/ 中本应用拥有且核对未变化的副本，不递归、不删除原图或整个目录。此操作不能从应用内撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除选中副本'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _deleting = true;
      _stop = false;
      _processed = 0;
      _total = ids.length;
      _result = null;
      _error = null;
    });
    var deleted = 0;
    final issues = <String>[];
    try {
      for (var start = 0; start < ids.length && !_stop; start += 50) {
        final end = (start + 50).clamp(0, ids.length);
        final row = await widget.probe.deleteExportCopies(
          token,
          ids.sublist(start, end),
        );
        final count = row['deleted'] as int;
        deleted += count;
        final returnedIds = row['deletedIds'];
        if (returnedIds is List) {
          final confirmedIds = returnedIds.cast<int>().toSet();
          final batch = ids.sublist(start, end).toSet();
          if (confirmedIds.length != count ||
              !batch.containsAll(confirmedIds)) {
            widget.onChanged?.call(batch, true);
            throw StateError('清理结果不一致');
          }
          if (confirmedIds.isNotEmpty) {
            widget.onChanged?.call(confirmedIds, false);
          }
        } else if (count > 0) {
          // Older bridge/fakes may not identify which items were deleted.
          widget.onChanged?.call(
            ids.sublist(start, end).toSet(),
            count != end - start,
          );
        }
        issues.addAll(
          (row['issues'] as List).map(
            (item) => '${(item as Map)['name']}：${item['reason']}',
          ),
        );
        if (mounted) setState(() => _processed = end);
      }
    } catch (error) {
      issues.add('后续清理已停止：$error；请重新预览核对实际状态。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _deleting = false;
          _result =
              '已删除 $deleted 张 · 已处理 $_processed/$_total 项${_stop ? ' · 已停止' : ''}\n${issues.join('\n')}';
        });
      }
    }
    if (mounted) await _preview();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_deleting,
    child: Scaffold(
      appBar: AppBar(title: const Text('清理导出副本')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('只列出本应用能核对归属的已导出副本。默认不选中；清理不会影响原图。没有定期自动清理。'),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
          if (_result != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 100),
              child: SingleChildScrollView(child: SelectableText(_result!)),
            ),
          Text('可清理 ${_items.length} 张 · 排除归属不明或不可核对 $_excluded 张'),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(
                        () => _selected.addAll(
                          _items.map((row) => row['id'] as int),
                        ),
                      ),
                child: const Text('全选可清理副本'),
              ),
              TextButton(
                onPressed: _busy ? null : () => setState(_selected.clear),
                child: const Text('清空选择'),
              ),
              TextButton(
                onPressed: _busy ? null : _preview,
                child: const Text('刷新列表'),
              ),
              FilledButton(
                onPressed: _busy || _selected.isEmpty ? null : _delete,
                child: Text('清理已选（${_selected.length}）'),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_deleting)
            TextButton(
              onPressed: () => setState(() => _stop = true),
              child: Text(_stop ? '正在停止…' : '停止后续清理'),
            ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('export-cleanup-list'),
              controller: _scroll,
              itemCount: _items.length,
              itemBuilder: (_, index) {
                final item = _items[index];
                final id = item['id'] as int;
                return CheckboxListTile(
                  value: _selected.contains(id),
                  title: Text(item['name'] as String),
                  subtitle: Text(_size(item['size'] as int)),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _selected.add(id);
                          } else {
                            _selected.remove(id);
                          }
                        }),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
