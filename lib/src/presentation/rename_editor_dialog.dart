import 'package:flutter/material.dart';

import '../application/directory_browser.dart';
import '../application/tag_group_id.dart';
import '../domain/rename_plan.dart';
import '../domain/batch_stem.dart';
import '../domain/tag_groups.dart';
import 'tag_name_match_dialog.dart';

final class RenameEditorResult {
  const RenameEditorResult(
    this.edit,
    this.groups,
    this.created,
    this.draft, {
    this.batchStem,
  });
  final RenameEdit edit;
  final TagGroups groups;
  final List<TagGroup> created;
  final RenameEditorDraft draft;
  final BatchStem? batchStem;

  Map<String, RenameEdit> editsFor(List<ImageEntry> selected) =>
      batchStem?.edits({
        for (final entry in selected) entry.id: entry.filename,
      }, edit) ??
      {for (final entry in selected) entry.id: edit};
}

final class RenameEditorDraft {
  const RenameEditorDraft({
    required this.addRaw,
    required this.removeRaw,
    required this.search,
    required this.stem,
    required this.groupModes,
    this.batchEnabled = false,
    this.batchPrefix = '',
    this.batchStart = '1',
    this.batchPadding = '3',
  });

  final String addRaw;
  final Set<String> removeRaw;
  final String search;
  final String stem;
  final Map<String, int> groupModes;
  final bool batchEnabled;
  final String batchPrefix;
  final String batchStart;
  final String batchPadding;
}

/// Builds tag edits and optional, explicitly enabled numbered stems.
final class RenameEditorDialog extends StatefulWidget {
  const RenameEditorDialog({
    required this.selected,
    required this.groups,
    this.draft,
    super.key,
  });

  final List<ImageEntry> selected;
  final TagGroups groups;
  final RenameEditorDraft? draft;

  @override
  State<RenameEditorDialog> createState() => _RenameEditorDialogState();
}

final class _RenameEditorDialogState extends State<RenameEditorDialog> {
  late final _addRaw = TextEditingController(text: widget.draft?.addRaw ?? '');
  late final Set<String> _removeRaw = {...?widget.draft?.removeRaw};
  late final List<String> _availableRawTags = {
    for (final entry in widget.selected) ...entry.parsedFilename.tags,
  }.toList()..sort();
  late final _search = TextEditingController(text: widget.draft?.search ?? '');
  late final _stem = TextEditingController(
    text:
        widget.draft?.stem ??
        (widget.selected.length == 1
            ? widget.selected.single.parsedFilename.stem
            : ''),
  );
  late final Map<String, int> _groupModes = {...?widget.draft?.groupModes};
  late bool _batchEnabled = widget.draft?.batchEnabled ?? false;
  late final _batchPrefix = TextEditingController(
    text: widget.draft?.batchPrefix ?? '图片',
  );
  late final _batchStart = TextEditingController(
    text: widget.draft?.batchStart ?? '1',
  );
  late final _batchPadding = TextEditingController(
    text: widget.draft?.batchPadding ?? '3',
  );
  String? _inputError;
  bool _submitting = false;

  BatchStem _batch() {
    final start = int.tryParse(_batchStart.text);
    final padding = int.tryParse(_batchPadding.text);
    if (start == null || padding == null) {
      throw const FormatException('起始序号和序号位数须为整数');
    }
    final value = BatchStem(
      prefix: _batchPrefix.text,
      start: start,
      padding: padding,
    );
    value.stemAt(widget.selected.length - 1);
    return value;
  }

  String _batchExample() {
    try {
      final names = widget.selected.toList()
        ..sort((a, b) => a.filename.compareTo(b.filename));
      final batch = _batch();
      return '示例：${batch.example(names.first.parsedFilename, 0)} → ${batch.example(names.last.parsedFilename, names.length - 1)}';
    } on FormatException catch (error) {
      return error.message;
    }
  }

  @override
  void dispose() {
    _addRaw.dispose();
    _search.dispose();
    _stem.dispose();
    _batchPrefix.dispose();
    _batchStart.dispose();
    _batchPadding.dispose();
    super.dispose();
  }

  Set<String> _tags(String value) => value
      .split(RegExp(r'[,，]'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toSet();

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final batch = _batchEnabled ? _batch() : null;
      final created = <TagGroup>[];
      final addGroups = <String>{
        ..._groupModes.entries
            .where((entry) => entry.value == 1)
            .map((entry) => entry.key),
      };
      for (final raw in _tags(_addRaw.text)) {
        final existing = widget.groups.findAlias(raw);
        if (existing != null) {
          addGroups.add(existing.id);
        } else {
          final decision = await resolveTagDisplayName(context, raw, [
            ...widget.groups.all,
            ...created,
          ]);
          if (!mounted || decision == null) return;
          if (!decision.createNew) {
            addGroups.add(decision.group!.id);
            continue;
          }
          created.add(
            TagGroup(
              id: TagGroupId.name([
                ...widget.groups.all.map((group) => group.id),
                ...created.map((group) => group.id),
              ]),
              displayName: raw,
              writeTag: raw,
              aliases: [raw],
            ),
          );
          addGroups.add(created.last.id);
        }
      }
      final proposed = TagGroups([
        ...widget.groups.all,
        ...created,
      ], categories: widget.groups.categories);
      final edit = RenameEdit(
        removeRaw: Set.of(_removeRaw),
        addGroups: addGroups,
        removeGroups: _groupModes.entries
            .where((entry) => entry.value == 2)
            .map((entry) => entry.key)
            .toSet(),
        stem:
            widget.selected.length == 1 &&
                _stem.text != widget.selected.single.parsedFilename.stem
            ? _stem.text
            : null,
      );
      Navigator.pop(
        context,
        RenameEditorResult(
          edit,
          proposed,
          created,
          RenameEditorDraft(
            addRaw: _addRaw.text,
            removeRaw: Set.of(_removeRaw),
            search: _search.text,
            stem: _stem.text,
            groupModes: Map.of(_groupModes),
            batchEnabled: _batchEnabled,
            batchPrefix: _batchPrefix.text,
            batchStart: _batchStart.text,
            batchPadding: _batchPadding.text,
          ),
          batchStem: batch,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _inputError = '编辑无效：$error');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _groupButton(TagGroup group, {bool isDefault = false}) {
    final mode = _groupModes[group.id] ?? 0;
    return PopupMenuButton<int>(
      tooltip: '编辑 ${group.displayName}',
      onSelected: (value) => setState(() => _groupModes[group.id] = value),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 0, child: Text('不变')),
        PopupMenuItem(value: 1, child: Text('添加')),
        PopupMenuItem(value: 2, child: Text('删除本组全部写法')),
      ],
      child: Chip(
        label: Text(
          '${isDefault ? '默认标签：' : ''}${group.displayName}${mode == 1
              ? ' · 添加'
              : mode == 2
              ? ' · 删除整组'
              : ''}',
        ),
      ),
    );
  }

  bool _matches(TagGroup group) =>
      group.displayName.contains(_search.text) ||
      group.id.contains(_search.text) ||
      group.writeTag.contains(_search.text) ||
      group.aliases.any((alias) => alias.contains(_search.text));

  String _rawLabel(String raw) {
    final group = widget.groups.findAlias(raw);
    return group == null ? raw : '$raw（${group.displayName} 组）';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('编辑 ${widget.selected.length} 张图片的文件名'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('标签增删会应用到全部已选图片；默认保留主体名，扩展名始终保持不变。'),
            const SizedBox(height: 12),
            TextField(
              controller: _addRaw,
              decoration: const InputDecoration(
                labelText: '添加标签（不存在时新建标签名组；中英文逗号分隔）',
              ),
            ),
            const SizedBox(height: 12),
            const Text('按原始写法删除（只删除点选的写法）'),
            if (_availableRawTags.isEmpty) const Text('已选图片没有文件名前缀标签'),
            if (_availableRawTags.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final raw in _availableRawTags)
                    FilterChip(
                      key: ValueKey('remove-raw:$raw'),
                      label: Text(_rawLabel(raw)),
                      selected: _removeRaw.contains(raw),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _removeRaw.add(raw);
                        } else {
                          _removeRaw.remove(raw);
                        }
                      }),
                    ),
                ],
              ),
            if (widget.selected.length == 1 && !_batchEnabled)
              TextField(
                controller: _stem,
                decoration: InputDecoration(
                  labelText: '主体文件名',
                  helperText:
                      '扩展名 ${widget.selected.single.parsedFilename.extension} 保持不变',
                ),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('批量生成简短主体名'),
              subtitle: const Text('统一主体名＋序号；按原文件名排序编号，与点选顺序无关'),
              value: _batchEnabled,
              onChanged: (value) => setState(() {
                _batchEnabled = value!;
                _inputError = null;
              }),
            ),
            if (_batchEnabled) ...[
              TextField(
                key: const ValueKey('batch-prefix'),
                controller: _batchPrefix,
                onChanged: (_) => setState(() => _inputError = null),
                decoration: const InputDecoration(
                  labelText: '统一主体名',
                  helperText: '例如“表情_”，生成表情_001；不含标签与扩展名',
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('batch-start'),
                      controller: _batchStart,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() => _inputError = null),
                      decoration: const InputDecoration(labelText: '起始序号'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('batch-padding'),
                      controller: _batchPadding,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() => _inputError = null),
                      decoration: const InputDecoration(labelText: '序号位数（补零）'),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_batchExample()),
              ),
              const Text('现有占名会在完整预演中提示，不自动跳号或覆盖。关闭此选项即保留原主体名。'),
            ],
            if (_inputError != null)
              Text(
                _inputError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '搜索标签名称、写入值或别名'),
            ),
            if (_groupModes.values.any((mode) => mode != 0))
              Text(
                '已选择：${_groupModes.entries.where((item) => item.value != 0).map((item) => '${widget.groups.group(item.key).displayName} ${item.value == 1 ? '添加' : '删除'}').join(' · ')}',
              ),
            const SizedBox(height: 8),
            for (final category in widget.groups.categories.where(
              (category) =>
                  category.displayName.contains(_search.text) ||
                  category.memberGroupIds.any(
                    (id) => _matches(widget.groups.group(id)),
                  ),
            ))
              ExpansionTile(
                title: Text('${category.displayName} · 类'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final id in category.memberGroupIds)
                          if (_search.text.isEmpty ||
                              _matches(widget.groups.group(id)))
                            _groupButton(
                              widget.groups.group(id),
                              isDefault: id == category.defaultGroupId,
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            Wrap(
              spacing: 8,
              children: [
                for (final group in widget.groups.all)
                  if (widget.groups.categories.every(
                        (category) =>
                            !category.memberGroupIds.contains(group.id),
                      ) &&
                      _matches(group))
                    _groupButton(group),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _submitting ? null : _submit,
        child: const Text('生成预演'),
      ),
    ],
  );
}

Future<bool> showRenamePreview(
  BuildContext context,
  RenamePlan plan, {
  List<TagGroup> created = const [],
  String? platformNotice,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('文件名变更预演'),
        content: SizedBox(
          width: 720,
          height: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (platformNotice != null) Text(platformNotice),
              SelectableText('目录：${plan.directory}'),
              Text(
                '需要改名 ${plan.items.length} 张 · 无变化 ${plan.unchanged.length} 张 · 问题 ${plan.issues.length} 项',
              ),
              if (created.isNotEmpty)
                Text(
                  '确认后将先保存新标签名组：${created.map((group) => group.displayName).join('、')}。改名失败时这些组仍保留。',
                ),
              const SizedBox(height: 8),
              if (plan.issues.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 130),
                  child: ListView(
                    children: [
                      for (final issue in plan.issues)
                        Text(
                          issue,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: plan.items.length,
                  itemBuilder: (context, index) {
                    final item = plan.items[index];
                    return ListTile(
                      dense: true,
                      title: Text(item.original),
                      subtitle: Text('→ ${item.target}\n临时名：${item.temporary}'),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: plan.canExecute
                ? () => Navigator.pop(context, true)
                : null,
            child: const Text('确认执行'),
          ),
        ],
      ),
    ) ??
    false;
