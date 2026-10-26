import 'package:flutter/material.dart';

import '../application/tag_group_id.dart';
import '../domain/tag_groups.dart';
import 'tag_name_match_dialog.dart';

final class _CategoryEditResult {
  const _CategoryEditResult(this.category, this.createdGroups);
  final TagCategory category;
  final List<TagGroup> createdGroups;
}

final class _NameEditResult {
  const _NameEditResult.save(this.group) : delete = false;
  const _NameEditResult.delete() : group = null, delete = true;

  final TagGroup? group;
  final bool delete;
}

enum TagGroupEditorMode { names, categories }

/// Edits only the auxiliary mapping; image filenames are never changed here.
final class TagGroupEditor extends StatefulWidget {
  const TagGroupEditor({
    required this.groups,
    required this.onSave,
    required this.mode,
    super.key,
  });

  final TagGroups groups;
  final Future<void> Function(TagGroups) onSave;
  final TagGroupEditorMode mode;

  @override
  State<TagGroupEditor> createState() => _TagGroupEditorState();
}

final class _TagGroupEditorState extends State<TagGroupEditor> {
  late List<TagGroup> _groups = List.of(widget.groups.all);
  late List<TagCategory> _categories = List.of(widget.groups.categories);
  final _search = TextEditingController();
  String? _error;
  bool _saving = false;

  Future<void> _persist(
    List<TagGroup> next, [
    List<TagCategory>? categories,
  ]) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final validated = TagGroups(next, categories: categories ?? _categories);
      await widget.onSave(validated);
      if (mounted) {
        setState(() {
          _groups = next;
          _categories = categories ?? _categories;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([TagGroup? existing]) async {
    final result = await showDialog<_NameEditResult>(
      context: context,
      builder: (context) => _TagGroupForm(
        existing: existing,
        otherGroups: _groups
            .where((group) => group.id != existing?.id)
            .toList(),
      ),
    );
    if (result == null || !mounted) return;
    if (result.delete) {
      await _removeGroup(existing!);
      return;
    }
    final next = List<TagGroup>.of(_groups);
    if (existing == null) {
      next.add(result.group!);
    } else {
      next[next.indexWhere((group) => group.id == existing.id)] = result.group!;
    }
    await _persist(next);
  }

  Future<void> _removeGroup(TagGroup group) async {
    final remaining = _groups.where((item) => item.id != group.id).toList();
    final categories = [
      for (final category in _categories)
        TagCategory(
          id: category.id,
          displayName: category.displayName,
          defaultGroupId: category.defaultGroupId == group.id
              ? category.memberGroupIds
                    .where((id) => id != group.id)
                    .firstOrNull
              : category.defaultGroupId,
          memberGroupIds: category.memberGroupIds.where((id) => id != group.id),
        ),
    ];
    await _persist(remaining, categories);
  }

  Future<void> _editCategory([TagCategory? existing]) async {
    final result = await showDialog<_CategoryEditResult>(
      context: context,
      builder: (_) => _CategoryForm(
        existing: existing,
        groups: _groups,
        otherCategoryIds: _categories
            .where((category) => category.id != existing?.id)
            .map((category) => category.id),
      ),
    );
    if (result == null || !mounted) return;
    final next = List<TagCategory>.of(_categories);
    if (existing == null) {
      next.add(result.category);
    } else {
      next[next.indexWhere((item) => item.id == existing.id)] = result.category;
    }
    await _persist([..._groups, ...result.createdGroups], next);
  }

  Future<void> _deleteCategory(TagCategory category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除标签类组“${category.displayName}”？'),
        content: const Text('只删除分类；成员标签名组和图片文件名保持不变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _persist(
        _groups,
        _categories.where((item) => item.id != category.id).toList(),
      );
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.mode == TagGroupEditorMode.names ? '标签名组' : '标签类组'),
    content: SizedBox(
      width: widget.mode == TagGroupEditorMode.names ? 620 : 520,
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.mode == TagGroupEditorMode.names
                ? '点击标签编辑；删除入口在编辑页。别名影响显示与筛选，不自动改写图片。'
                : '类组只用于分类；★ 是默认标签，成员标签仍分别操作。',
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_saving) const LinearProgressIndicator(),
          TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: widget.mode == TagGroupEditorMode.names
                  ? '查找名称、ID、写入值或别名'
                  : '查找标签类组',
            ),
            onChanged: (_) => setState(() {}),
          ),
          Expanded(
            child: widget.mode == TagGroupEditorMode.categories
                ? ListView(
                    children: [
                      for (final category in _categories.where(
                        (category) =>
                            category.displayName.contains(_search.text) ||
                            category.id.contains(_search.text),
                      ))
                        ListTile(
                          title: Text('${category.displayName} · 类'),
                          subtitle: Text(
                            [
                              if (category.defaultGroupId != null)
                                '★ ${_groups.firstWhere((group) => group.id == category.defaultGroupId).displayName}',
                              ...category.memberGroupIds
                                  .where((id) => id != category.defaultGroupId)
                                  .map(
                                    (id) => _groups
                                        .firstWhere((group) => group.id == id)
                                        .displayName,
                                  ),
                            ].join(' · '),
                          ),
                          trailing: Wrap(
                            children: [
                              IconButton(
                                tooltip: '编辑类组 ${category.displayName}',
                                onPressed: _saving
                                    ? null
                                    : () => _editCategory(category),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: '删除类组 ${category.displayName}',
                                onPressed: _saving
                                    ? null
                                    : () => _deleteCategory(category),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                    ],
                  )
                : SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final group in _groups.where(
                          (group) =>
                              group.displayName.contains(_search.text) ||
                              group.id.contains(_search.text) ||
                              group.writeTag.contains(_search.text) ||
                              group.aliases.any(
                                (alias) => alias.contains(_search.text),
                              ),
                        ))
                          InputChip(
                            label: Text(group.displayName),
                            onPressed: _saving ? null : () => _edit(group),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    ),
    actions: [
      if (widget.mode == TagGroupEditorMode.categories)
        TextButton(
          onPressed: _saving ? null : () => _editCategory(),
          child: const Text('新建标签类组'),
        ),
      if (widget.mode == TagGroupEditorMode.names)
        TextButton(
          onPressed: _saving ? null : () => _edit(),
          child: const Text('新建标签名组'),
        ),
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  );
}

final class _TagGroupForm extends StatefulWidget {
  const _TagGroupForm({this.existing, required this.otherGroups});

  final TagGroup? existing;
  final List<TagGroup> otherGroups;

  @override
  State<_TagGroupForm> createState() => _TagGroupFormState();
}

final class _TagGroupFormState extends State<_TagGroupForm> {
  late final _name = TextEditingController(
    text: widget.existing?.displayName ?? '',
  );
  late final _write = TextEditingController(
    text: widget.existing?.writeTag ?? '',
  );
  late final _aliases = TextEditingController(
    text:
        widget.existing?.aliases
            .where((alias) => alias != widget.existing!.writeTag)
            .join(', ') ??
        '',
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _write.dispose();
    _aliases.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final writeTag = _write.text.trim();
      final aliases = _aliases.text
          .split(RegExp(r'[,，]'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet();
      if (widget.existing != null && widget.existing!.writeTag != writeTag) {
        aliases.add(widget.existing!.writeTag);
      }
      aliases.add(writeTag);
      final result = TagGroup(
        id:
            widget.existing?.id ??
            TagGroupId.name(widget.otherGroups.map((group) => group.id)),
        displayName: _name.text.trim(),
        writeTag: writeTag,
        aliases: aliases,
      );
      TagGroups([...widget.otherGroups, result]);
      Navigator.pop(context, _NameEditResult.save(result));
    } catch (error) {
      setState(() => _error = '请检查标签组：$error');
    }
  }

  Future<void> _confirmDelete() async {
    final existing = widget.existing!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除标签名组“${existing.displayName}”？'),
        content: const Text('只删除映射配置，不修改图片文件名。历史标签会作为普通标签显示；当前未保存的编辑内容不会生效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(context, const _NameEditResult.delete());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? '新建标签名组' : '编辑标签名组'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '显示名称'),
            ),
            TextField(
              controller: _write,
              decoration: const InputDecoration(labelText: '默认写入标签'),
            ),
            TextField(
              controller: _aliases,
              decoration: const InputDecoration(
                labelText: '其他兼容写法（不含默认写入标签；中英文逗号分隔）',
              ),
            ),
            if (widget.existing != null)
              SelectableText('内部 ID：${widget.existing!.id}'),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.existing != null)
        TextButton(
          onPressed: _confirmDelete,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('删除'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('保存')),
    ],
  );
}

final class _CategoryForm extends StatefulWidget {
  const _CategoryForm({
    this.existing,
    required this.groups,
    required this.otherCategoryIds,
  });

  final TagCategory? existing;
  final List<TagGroup> groups;
  final Iterable<String> otherCategoryIds;

  @override
  State<_CategoryForm> createState() => _CategoryFormState();
}

final class _CategoryFormState extends State<_CategoryForm> {
  late final _name = TextEditingController(
    text: widget.existing?.displayName ?? '',
  );
  final _search = TextEditingController();
  final _newMembers = TextEditingController();
  late final Set<String> _members = {...?widget.existing?.memberGroupIds};
  late String? _defaultId = widget.existing?.defaultGroupId;
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    _newMembers.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final created = <TagGroup>[];
      final memberIds = Set<String>.of(_members);
      final known = TagGroups(widget.groups);
      for (final raw
          in _newMembers.text
              .split(RegExp(r'[,，]'))
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toSet()) {
        final existing =
            known.findAlias(raw) ??
            created.where((group) => group.aliases.contains(raw)).firstOrNull;
        if (existing != null) {
          memberIds.add(existing.id);
        } else {
          final decision = await resolveTagDisplayName(context, raw, [
            ...widget.groups,
            ...created,
          ]);
          if (!mounted || decision == null) return;
          if (!decision.createNew) {
            memberIds.add(decision.group!.id);
            continue;
          }
          final group = TagGroup(
            id: TagGroupId.name([
              ...widget.groups.map((group) => group.id),
              ...created.map((group) => group.id),
            ]),
            displayName: raw,
            writeTag: raw,
            aliases: [raw],
          );
          created.add(group);
          memberIds.add(group.id);
        }
      }
      final defaultId = _defaultId ?? memberIds.firstOrNull;
      final ordered = [?defaultId, ...memberIds.where((id) => id != defaultId)];
      Navigator.pop(
        context,
        _CategoryEditResult(
          TagCategory(
            id:
                widget.existing?.id ??
                TagGroupId.category(widget.otherCategoryIds),
            displayName: _name.text.trim(),
            defaultGroupId: defaultId,
            memberGroupIds: ordered,
          ),
          created,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '请检查类组：$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? '新建标签类组' : '编辑标签类组'),
    content: SizedBox(
      width: 480,
      height: 440,
      child: Column(
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '显示名称'),
          ),
          if (widget.existing != null)
            SelectableText('内部 ID：${widget.existing!.id}'),
          TextField(
            controller: _newMembers,
            decoration: const InputDecoration(labelText: '添加新成员标签（中英文逗号分隔）'),
          ),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: '搜索成员标签名组'),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final group in widget.groups.where(
                    (group) =>
                        group.displayName.contains(_search.text) ||
                        group.id.contains(_search.text) ||
                        group.writeTag.contains(_search.text) ||
                        group.aliases.any(
                          (alias) => alias.contains(_search.text),
                        ),
                  ))
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Tooltip(
                          message: '写入 ${group.writeTag}',
                          child: FilterChip(
                            label: Text(group.displayName),
                            selected: _members.contains(group.id),
                            onSelected: (selected) => setState(() {
                              if (selected) {
                                _members.add(group.id);
                                _defaultId ??= group.id;
                              } else {
                                _members.remove(group.id);
                                if (_defaultId == group.id) {
                                  _defaultId = _members.firstOrNull;
                                }
                              }
                            }),
                          ),
                        ),
                        if (_members.contains(group.id))
                          IconButton(
                            tooltip: '设 ${group.displayName} 为默认标签',
                            icon: Icon(
                              _defaultId == group.id
                                  ? Icons.star
                                  : Icons.star_border,
                            ),
                            onPressed: () =>
                                setState(() => _defaultId = group.id),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _submitting ? null : _submit,
        child: const Text('保存'),
      ),
    ],
  );
}
