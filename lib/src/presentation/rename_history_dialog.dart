import 'package:flutter/material.dart';

import '../domain/rename_plan.dart';
import 'rename_history_summary.dart';

Future<RenamePlan?> showRenameHistory(
  BuildContext context,
  List<RenamePlan> completed, {
  Future<void> Function(Set<String>)? onDelete,
  VoidCallback? onShowManualClosed,
  int manualClosedCount = 0,
  RenamePlan? initialSelected,
}) => showDialog<RenamePlan>(
  context: context,
  builder: (_) => _RenameHistoryDialog(
    completed: completed,
    onDelete: onDelete,
    onShowManualClosed: onShowManualClosed,
    manualClosedCount: manualClosedCount,
    initialSelected: initialSelected,
  ),
);

final class _RenameHistoryDialog extends StatefulWidget {
  const _RenameHistoryDialog({
    required this.completed,
    this.onDelete,
    this.onShowManualClosed,
    required this.manualClosedCount,
    this.initialSelected,
  });

  final List<RenamePlan> completed;
  final Future<void> Function(Set<String>)? onDelete;
  final VoidCallback? onShowManualClosed;
  final int manualClosedCount;
  final RenamePlan? initialSelected;

  @override
  State<_RenameHistoryDialog> createState() => _RenameHistoryDialogState();
}

final class _RenameHistoryDialogState extends State<_RenameHistoryDialog> {
  late RenamePlan? _selected = widget.initialSelected;
  late final List<RenamePlan> _completed = [...widget.completed];
  final Set<String> _checked = {};
  bool _selecting = false;
  bool _deleting = false;

  Future<void> _deleteChecked() async {
    if (_checked.isEmpty || _deleting || widget.onDelete == null) return;
    final ids = Set<String>.of(_checked);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除历史记录？'),
        content: Text(
          '将删除选中的 ${ids.length} 笔已完成事务记录，包括计划和事件日志。'
          '删除后将失去这些记录的撤销依据；图片文件不会改变。此操作无法撤回。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除记录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await widget.onDelete!(ids);
      if (!mounted) return;
      setState(() {
        _completed.removeWhere((plan) => ids.contains(plan.id));
        _checked.clear();
        _selecting = false;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除记录失败，请重新打开历史记录核对：$error')));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return AlertDialog(
      title: Row(
        children: [
          if (selected != null)
            IconButton(
              tooltip: '返回历史列表',
              onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.arrow_back),
            ),
          Expanded(child: Text(selected == null ? '历史操作' : '操作详情')),
          if (selected == null && widget.onDelete != null)
            TextButton(
              onPressed: _deleting
                  ? null
                  : () => setState(() {
                      _selecting = !_selecting;
                      _checked.clear();
                    }),
              child: Text(_selecting ? '取消选择' : '选择记录'),
            ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 460,
        child: selected == null ? _historyList() : _detail(selected),
      ),
      actions: [
        if (selected == null && widget.onShowManualClosed != null)
          TextButton(
            onPressed: _deleting ? null : widget.onShowManualClosed,
            child: Text('人工结案记录（${widget.manualClosedCount}）'),
          ),
        if (selected == null && _selecting && _completed.isNotEmpty)
          TextButton(
            onPressed: _deleting
                ? null
                : () => setState(() {
                    if (_checked.length == _completed.length) {
                      _checked.clear();
                    } else {
                      _checked.addAll(_completed.map((plan) => plan.id));
                    }
                  }),
            child: Text(_checked.length == _completed.length ? '取消全选' : '全选'),
          ),
        if (selected == null && _selecting)
          FilledButton(
            onPressed: _checked.isEmpty || _deleting ? null : _deleteChecked,
            child: Text('删除选中（${_checked.length}）'),
          ),
        TextButton(
          onPressed: _deleting ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (selected != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, selected),
            child: const Text('撤销这批操作'),
          ),
      ],
    );
  }

  Widget _historyList() {
    if (_completed.isEmpty) {
      return const Center(child: Text('暂无已完成的改名操作'));
    }
    final byId = {for (final plan in _completed) plan.id: plan};
    return ListView.builder(
      itemCount: _completed.length,
      itemBuilder: (context, index) {
        final plan = _completed[index];
        return ListTile(
          title: Text(
            '${renameHistoryTime(plan.id)} · ${renameHistoryDisplaySummary(plan, byId)} · ${plan.items.length} 张',
          ),
          subtitle: Text(renameHistoryDirectoryName(plan.directory)),
          leading: _selecting
              ? Checkbox(
                  value: _checked.contains(plan.id),
                  onChanged: _deleting
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _checked.add(plan.id);
                          } else {
                            _checked.remove(plan.id);
                          }
                        }),
                )
              : null,
          trailing: _selecting ? null : const Icon(Icons.chevron_right),
          onTap: _deleting
              ? null
              : () => setState(() {
                  if (_selecting) {
                    if (!_checked.add(plan.id)) _checked.remove(plan.id);
                  } else {
                    _selected = plan;
                  }
                }),
        );
      },
    );
  }

  Widget _detail(RenamePlan plan) {
    final byId = {for (final item in _completed) item.id: item};
    final sourceId = renameHistoryUndoSourceId(plan);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${renameHistoryTime(plan.id)} · ${renameHistoryDisplaySummary(plan, byId)} · ${plan.items.length} 张',
        ),
        const SizedBox(height: 6),
        if (sourceId != null) Text('实际变更：${renameHistorySummary(plan)}'),
        SelectableText('目录：${plan.directory}'),
        SelectableText('事务 ID：${plan.id}'),
        if (sourceId != null) SelectableText('来源事务 ID：$sourceId'),
        const Divider(),
        Expanded(
          child: ListView.builder(
            itemCount: plan.items.length,
            itemBuilder: (context, index) {
              final item = plan.items[index];
              return ListTile(
                dense: true,
                title: Text(item.original),
                subtitle: Text('→ ${item.target}'),
              );
            },
          ),
        ),
      ],
    );
  }
}
