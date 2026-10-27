import 'app_about_page.dart';
import '../infrastructure/guide_preferences.dart';

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../application/directory_browser.dart';
import '../application/rename_service.dart';
import '../domain/tag_filter.dart';
import '../domain/tag_group_config.dart';
import '../domain/tag_group_profiles.dart';
import '../domain/tag_groups.dart';
import '../domain/rename_plan.dart';
import '../infrastructure/local_tag_group_store.dart';
import '../infrastructure/tag_group_import.dart';
import '../infrastructure/windows_image_copy.dart';
import '../infrastructure/rename_transaction_store.dart';
import 'image_thumbnail.dart';
import 'image_viewer_dialog.dart';
import 'manual_closed_history_dialog.dart';
import 'rename_editor_dialog.dart';
import 'rename_history_dialog.dart';
import 'tag_group_editor.dart';
import 'usage_guide_page.dart';

enum _FilterRole { ignored, required, any, excluded }

extension _FilterRoleLabel on _FilterRole {
  String get label => switch (this) {
    _FilterRole.ignored => '不参与',
    _FilterRole.required => '必须有',
    _FilterRole.any => '任一有',
    _FilterRole.excluded => '必须无',
  };

  String get shortLabel => switch (this) {
    _FilterRole.ignored => '',
    _FilterRole.required => 'AND',
    _FilterRole.any => 'OR',
    _FilterRole.excluded => 'NOT',
  };

  Color? get backgroundColor => switch (this) {
    _FilterRole.ignored => null,
    _FilterRole.required => const Color(0xFFDDF3DE),
    _FilterRole.any => const Color(0xFFDDEEFF),
    _FilterRole.excluded => const Color(0xFFF9DFE1),
  };
}

final class _FilterOption {
  const _FilterOption(this.identity, this.label);

  final String identity;
  final String label;
}

String _pendingTransactionLabel(PendingRenameTransaction pending, bool latest) {
  final filename = File(pending.path).uri.pathSegments.last;
  final id =
      pending.plan?.id ??
      filename.replaceFirst(RegExp(r'\.(json|events)$'), '');
  final match = RegExp(r'^itm-(\d{17,20})-').firstMatch(id);
  String time = '时间未知';
  if (match != null) {
    final digits = match.group(1)!;
    final local = DateTime.utc(
      int.parse(digits.substring(0, 4)),
      int.parse(digits.substring(4, 6)),
      int.parse(digits.substring(6, 8)),
      int.parse(digits.substring(8, 10)),
      int.parse(digits.substring(10, 12)),
    ).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    time =
        '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
  final directory = pending.plan?.directory;
  final folder = directory == null
      ? pending.recordIssue == RenameRecordIssue.missingPlan
            ? '计划缺失'
            : '记录损坏'
      : Directory(directory).uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
  final shortId = id.length > 8 ? id.substring(id.length - 8) : id;
  final issue = switch (pending.recordIssue) {
    RenameRecordIssue.missingPlan => ' · 计划缺失',
    RenameRecordIssue.missingEvents => ' · 日志缺失或未生成',
    RenameRecordIssue.corruptPlan => ' · 记录损坏',
    null => '',
  };
  return '${latest ? '最新 · ' : ''}$time · $folder · '
      '${pending.plan?.items.length ?? '?'} 项 · …$shortId$issue';
}

final class _FolderTab {
  _FolderTab(this.path, this.root);

  final String path;
  final String root;
  final List<ImageEntry> entries = [];
  String? error;
  bool complete = false;
  bool checkedSuspected = false;
  List<SuspectedMissingRenameRecord> suspected = const [];
}

/// M1 的只读入口：显式选目录，仅列出当前目录中的图片文件。
final class DirectoryBrowserPage extends StatefulWidget {
  DirectoryBrowserPage({
    required this.browser,
    this.groupStore,
    this.renameService,
    this.copyService = const ImageCopyService(WindowsImageCopyPort()),
    this.chooseCopyDestination,
    TagGroups? groups,
    super.key,
  }) : groups = groups ?? TagGroups(const []);

  final DirectoryBrowser browser;
  final TagGroups groups;
  final TagGroupStore? groupStore;
  final RenameService? renameService;
  final ImageCopyService copyService;
  final Future<String?> Function()? chooseCopyDestination;

  @override
  State<DirectoryBrowserPage> createState() => _DirectoryBrowserPageState();
}

final class _DirectoryBrowserPageState extends State<DirectoryBrowserPage> {
  StreamSubscription<FolderScanEvent>? _subscription;
  Timer? _scanRefreshTimer;
  final List<ScanRoot> _roots = [];
  final List<_FolderTab> _tabs = [];
  final List<String> _scanIssues = [];
  int _activeTabIndex = 0;
  List<ImageEntry> _visible = const [];
  final Map<String, _FilterRole> _filterRoles = {};
  bool _onlyUntagged = false;
  final Set<String> _selectedIds = {};
  late TagGroups _groups = widget.groups;
  TagGroupProfiles? _profiles;
  bool _loadingGroups = false;
  bool _renaming = false;
  bool _copying = false;
  bool _cancelRename = false;
  String? _renameStage;
  int _renameDone = 0;
  int _renameTotal = 0;
  List<PendingRenameTransaction> _pendingTransactions = const [];
  List<RenamePlan> _completedTransactions = const [];
  List<ManuallyClosedRenameTransaction> _manualClosedTransactions = const [];
  List<SuspectedMissingRenameRecord> _suspectedMissingRecords = const [];
  String? _groupsError;
  String? _filterNotice;
  String? _directory;
  String? _error;
  bool _choosing = false;
  bool _scanning = false;
  bool _cancelled = false;
  int _scanId = 0;

  @override
  void initState() {
    super.initState();
    if (widget.groupStore != null) _loadGroups();
    if (widget.renameService != null) _loadPendingTransactions();
  }

  Future<void> _loadPendingTransactions() async {
    try {
      final pending = await widget.renameService!.store.pending();
      final completed = await widget.renameService!.store.completed();
      final manualClosed = await widget.renameService!.store.manuallyClosed();
      if (mounted) {
        setState(() {
          _pendingTransactions = pending;
          _completedTransactions = completed;
          _manualClosedTransactions = manualClosed;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _renameStage = '读取事务记录失败：$error');
    }
  }

  Future<void> _showCompletedTransactions() async {
    RenamePlan? returnToDetail;
    while (true) {
      if (!mounted) return;
      final selected = await showRenameHistory(
        context,
        _completedTransactions,
        onDelete: (ids) async {
          try {
            await widget.renameService!.store.deleteCompleted(ids);
          } finally {
            await _loadPendingTransactions();
          }
        },
        onShowManualClosed: _manualClosedTransactions.isEmpty
            ? null
            : _showManualClosedTransactions,
        manualClosedCount: _manualClosedTransactions.length,
        initialSelected: returnToDetail,
      );
      if (selected == null || !mounted) return;
      try {
        final reverse = await widget.renameService!.previewReverse(selected);
        if (!mounted) return;
        final confirmed = await showRenamePreview(context, reverse);
        if (!mounted) return;
        if (!confirmed) {
          returnToDetail = selected;
          continue;
        }
        final acknowledged = await _confirmPendingForNewBatch(
          reverse.directory,
        );
        if (acknowledged != null && mounted) {
          await _runRename(reverse, acknowledgedPendingPaths: acknowledged);
        }
        return;
      } catch (error) {
        if (mounted) {
          _showRenameResult(
            RenameOutcome(
              'manual',
              '无法生成撤销预演：$error',
              0,
              selected.items.length,
            ),
          );
        }
        return;
      }
    }
  }

  Future<void> _showManualClosedTransactions() => showDialog<void>(
    context: context,
    builder: (context) =>
        ManualClosedHistoryDialog(records: _manualClosedTransactions),
  );

  Future<void> _copySelected() async {
    if (_copying || _renaming || _selectedIds.isEmpty) return;
    final selected = _selectedEntries;
    setState(() => _copying = true);
    try {
      final destination =
          await (widget.chooseCopyDestination?.call() ??
              getDirectoryPath(confirmButtonText: '选择复制目标'));
      if (!mounted || destination == null) return;
      final report = await widget.copyService.copySelected(
        selected,
        destination,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('复制结果'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '已复制 ${report.copied} 张 · 同名跳过 ${report.skipped} 张 · 其他失败 ${report.issues.length - report.skipped} 张',
                  ),
                  for (final issue in report.issues)
                    SelectableText(
                      '${issue.filename} · ${issue.source}：${issue.reason}',
                    ),
                ],
              ),
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
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法复制选中图片：$error')));
      }
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _editSelected() async {
    if (_selectedIds.isEmpty || _renaming || _selectedDirectories.length != 1) {
      return;
    }
    final selected = _selectedEntries;
    final selectedDirectory = File(selected.first.id).parent.path;
    RenameEditorDraft? draft;
    while (true) {
      if (!mounted) return;
      final result = await showDialog<RenameEditorResult>(
        context: context,
        builder: (_) => RenameEditorDialog(
          selected: selected,
          groups: _groups,
          draft: draft,
        ),
      );
      if (result == null || !mounted) return;
      try {
        final plan = await widget.renameService!.preview(
          directory: selectedDirectory,
          selected: selected,
          edits: result.editsFor(selected),
          groups: result.groups,
        );
        if (!mounted) return;
        final confirmed = await showRenamePreview(
          context,
          plan,
          created: result.created,
        );
        if (!mounted) return;
        if (!confirmed) {
          draft = result.draft;
          continue;
        }
        final acknowledged = await _confirmPendingForNewBatch(plan.directory);
        if (acknowledged == null || !mounted) return;
        if (result.created.isNotEmpty) {
          try {
            await _saveGroups(result.groups);
          } catch (error) {
            if (mounted) {
              _showRenameResult(
                RenameOutcome(
                  'manual',
                  '新标签名组保存失败，未执行图片改名：$error',
                  0,
                  selected.length,
                ),
              );
            }
            return;
          }
          if (!mounted) return;
        }
        await _runRename(plan, acknowledgedPendingPaths: acknowledged);
        return;
      } catch (error) {
        if (mounted) {
          _showRenameResult(
            RenameOutcome('manual', '生成预演失败：$error', 0, selected.length),
          );
        }
        return;
      }
    }
  }

  Future<Set<String>?> _confirmPendingForNewBatch(String directory) async {
    final pending = await widget.renameService!.store.pending();
    if (pending.isEmpty) return <String>{};
    if (!mounted) return null;
    final sameDirectory = pending
        .where(
          (transaction) =>
              transaction.plan?.directory.toUpperCase() ==
              directory.toUpperCase(),
        )
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('仍有未解决事务'),
        content: SelectableText(
          '目前有 ${pending.length} 笔未解决事务，其中 $sameDirectory 笔属于当前目录。'
          '继续改名可能使旧计划无法再按原样恢复。旧记录会保留；需要时可在事务详情中人工结案。\n\n'
          '确认仍开始这笔新改名吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('仍继续改名'),
          ),
        ],
      ),
    );
    return confirmed == true
        ? pending.map((transaction) => transaction.path).toSet()
        : null;
  }

  Future<void> _runRename(
    RenamePlan plan, {
    bool resume = false,
    bool continueSafe = false,
    Set<String> acknowledgedPendingPaths = const {},
  }) async {
    setState(() {
      _renaming = true;
      _cancelRename = false;
      _renameStage = '准备中';
      _renameDone = 0;
      _renameTotal = plan.items.length;
    });
    late RenameOutcome outcome;
    try {
      outcome = resume
          ? await widget.renameService!.resume(
              plan,
              progress: _onRenameProgress,
              cancelled: () => _cancelRename,
              continueSafe: continueSafe,
            )
          : await widget.renameService!.execute(
              plan,
              progress: _onRenameProgress,
              cancelled: () => _cancelRename,
              acknowledgedPendingPaths: acknowledgedPendingPaths,
            );
    } catch (error) {
      outcome = RenameOutcome(
        'manual',
        '执行中断：$error。请检查事务记录和现场。',
        0,
        plan.items.length,
      );
    }
    if (!mounted) return;
    setState(() {
      _renaming = false;
      _renameStage = null;
    });
    await _loadPendingTransactions();
    List<RenameItemStatus> statuses = const [];
    try {
      statuses = await widget.renameService!.inspect(plan);
    } catch (error) {
      outcome = RenameOutcome(
        'manual',
        '${outcome.details}\n逐项核对失败：$error',
        outcome.done,
        outcome.total,
      );
    }
    final wantsSafeContinuation = mounted
        ? await _showRenameResult(
            outcome,
            statuses: statuses,
            offerSafeContinuation: resume && !continueSafe,
          )
        : false;
    if (mounted &&
        _tabs.any(
          (tab) =>
              Directory(tab.path).absolute.path.toLowerCase() ==
              Directory(plan.directory).absolute.path.toLowerCase(),
        )) {
      await _rescanAll();
    }
    if (wantsSafeContinuation && mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('只继续安全项目？'),
          content: Text(
            '程序会在执行前重新核对整个批次，只处理仍可确认安全的项目。'
            '其余 ${outcome.issues.length} 项保持未解决，整批不会显示为完成。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认继续'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await _runRename(plan, resume: true, continueSafe: true);
      }
    }
  }

  void _onRenameProgress(String stage, int done, int total) {
    if (mounted) {
      setState(() {
        _renameStage = stage;
        _renameDone = done;
        _renameTotal = total;
      });
    }
  }

  Future<bool> _showRenameResult(
    RenameOutcome outcome, {
    List<RenameItemStatus> statuses = const [],
    bool offerSafeContinuation = false,
  }) async {
    final continueSafe = await showDialog<bool>(
      context: context,
      builder: (context) => RenameResultDialog(
        outcome: outcome,
        statuses: statuses,
        offerSafeContinuation: offerSafeContinuation,
      ),
    );
    return continueSafe == true;
  }

  Future<void> _showPendingTransaction(PendingRenameTransaction pending) async {
    final plan = pending.plan;
    List<RenameItemStatus> statuses = const [];
    if (plan != null) {
      try {
        statuses = await widget.renameService!.inspect(plan);
      } catch (_) {
        // Preserve the plan for manual inspection; resume rechecks before writes.
      }
    }
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未解决的文件名事务'),
        content: SizedBox(
          width: 700,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(pending.path),
              if (pending.error != null) SelectableText(pending.error!),
              if (plan != null) ...[
                SelectableText('目录：${plan.directory} · ${plan.items.length} 项'),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: plan.items.length,
                    itemBuilder: (context, index) {
                      final item = plan.items[index];
                      return ListTile(
                        dense: true,
                        title: Text(item.original),
                        subtitle: Text(
                          '临时：${item.temporary}\n目标：${item.target}\n当前：${statuses.length == plan.items.length ? statuses[index].location : '未知'}'
                          '${statuses.length == plan.items.length && statuses[index].problem != null ? '\n${statuses[index].problem}' : ''}'
                          '\n身份：${item.fileId}',
                        ),
                      );
                    },
                  ),
                ),
              ],
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
              child: const Text('标记为人工已处理'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'abandoned'),
              child: const Text('放弃处理此事务'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'resume'),
              child: const Text('核对并继续处理'),
            ),
          ],
        ],
      ),
    );
    if (action == 'resume' && plan != null && mounted) {
      await _runRename(plan, resume: true);
    } else if (plan != null &&
        mounted &&
        (action == 'resolved' || action == 'abandoned')) {
      await _closePendingManually(plan, abandoned: action == 'abandoned');
    }
  }

  Future<void> _closePendingManually(
    RenamePlan plan, {
    required bool abandoned,
  }) async {
    final noteController = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(abandoned ? '放弃处理此事务？' : '标记为人工已处理？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              '事务 ${plan.id} · ${plan.items.length} 项。此操作只记录你的决定，'
              '不会改动图片，也不会把批次记作按计划完成；原计划和事件记录仍保留。',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              maxLength: 500,
              decoration: const InputDecoration(labelText: '处理说明（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, noteController.text),
            child: const Text('确认结案'),
          ),
        ],
      ),
    );
    noteController.dispose();
    if (note == null || !mounted) return;
    try {
      await widget.renameService!.store.closeManually(
        plan,
        abandoned: abandoned,
        note: note,
      );
      await _loadPendingTransactions();
    } catch (error) {
      if (mounted) {
        await _showRenameResult(
          RenameOutcome('manual', '人工结案失败：$error', 0, plan.items.length),
        );
      }
    }
  }

  Future<void> _loadGroups() async {
    setState(() {
      _loadingGroups = true;
      _groupsError = null;
    });
    try {
      final loaded = await widget.groupStore!.loadProfiles();
      if (mounted) {
        setState(() => _profiles = loaded);
        _applyGroups(loaded.active.groups);
      }
    } catch (error) {
      if (mounted) setState(() => _groupsError = '标签组配置读取失败：$error');
    } finally {
      if (mounted) setState(() => _loadingGroups = false);
    }
  }

  void _applyGroups(TagGroups groups) {
    final oldGroupsById = {for (final group in _groups.all) group.id: group};
    final newGroupIds = groups.all.map((group) => group.id).toSet();
    final migrated = <String, _FilterRole>{};
    final conflicts = <String>{};
    var removed = 0;
    for (final entry in _filterRoles.entries) {
      final identity = entry.key;
      String? target;
      if (identity.startsWith('raw:')) {
        target = groups.identity(identity.substring(4));
      } else if (identity.startsWith('group:')) {
        final id = identity.substring(6);
        if (newGroupIds.contains(id)) {
          target = identity;
        } else {
          final oldGroup = oldGroupsById[id];
          if (oldGroup != null) {
            final targets = oldGroup.aliases.map(groups.identity).toSet();
            if (targets.length == 1) target = targets.single;
          }
        }
      }
      if (target == null) {
        removed++;
      } else if (conflicts.contains(target)) {
        removed++;
      } else if (migrated.containsKey(target) &&
          migrated[target] != entry.value) {
        migrated.remove(target);
        conflicts.add(target);
        removed += 2;
      } else {
        migrated[target] = entry.value;
      }
    }
    setState(() {
      _groups = groups;
      _groupsError = null;
      _filterRoles.clear();
      _filterRoles.addAll(migrated);
      _selectedIds.clear();
      _filterNotice = removed > 0
          ? '标签组配置改变了筛选身份或产生模式冲突，已清除 $removed 项条件，请重新设置。'
          : null;
    });
  }

  Future<void> _saveGroups(TagGroups groups) async {
    final profiles = _profiles!;
    final updated = TagGroupProfiles(
      profiles: [
        for (final profile in profiles.profiles)
          profile.id == profiles.activeId
              ? TagGroupProfile(
                  id: profile.id,
                  name: profile.name,
                  groups: groups,
                )
              : profile,
      ],
      activeId: profiles.activeId,
    );
    await widget.groupStore!.saveProfiles(updated);
    if (mounted) setState(() => _profiles = updated);
    if (mounted) _applyGroups(groups);
  }

  Future<void> _saveProfileList(TagGroupProfiles profiles) async {
    await widget.groupStore!.saveProfiles(profiles);
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _groups = profiles.active.groups;
      _filterRoles.clear();
      _onlyUntagged = false;
      _selectedIds.clear();
      _filterNotice = null;
      _groupsError = null;
    });
  }

  Future<String?> _askProfileName(
    String title, {
    String initial = '',
    String? excludeProfileId,
  }) async {
    var name = initial;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: '配置名称'),
          onChanged: (value) => name = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value.trim()),
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
    if (result == null || result.isEmpty || !mounted) return null;
    if (_profiles!.profiles.any(
      (profile) => profile.id != excludeProfileId && profile.name == result,
    )) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('配置名称已存在')));
      return null;
    }
    return result;
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('新建配置失败：$error')));
      }
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
      activeId: previous.activeId,
    );
    try {
      await widget.groupStore!.saveProfiles(updated);
      if (mounted) setState(() => _profiles = updated);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重命名配置失败：$error')));
      }
    }
  }

  Future<void> _switchProfile(String id) async {
    final previous = _profiles!;
    if (id == previous.activeId) return;
    try {
      await _saveProfileList(
        TagGroupProfiles(profiles: previous.profiles, activeId: id),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换配置失败：$error')));
      }
    }
  }

  Future<void> _deleteProfile() async {
    final previous = _profiles!;
    final active = previous.active;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除配置失败：$error')));
      }
    }
  }

  Future<void> _importGroups() async {
    try {
      final selected = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (selected == null || !mounted) return;
      final imported = await TagGroupImport.read(selected);
      if (!mounted) return;
      final filename = selected.name.replaceFirst(
        RegExp(r'\.json$', caseSensitive: false),
        '',
      );
      final name = await _askProfileName(
        '导入新配置（${imported.all.length} 个名组、${imported.categories.length} 个类组）',
        initial: filename,
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
            TagGroupProfile(id: id, name: name, groups: imported),
          ],
          activeId: id,
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$error')));
      }
    }
  }

  Future<void> _exportGroups() async {
    try {
      final location = await getSaveLocation(
        suggestedName: 'tag_groups.json',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (location == null) return;
      await File(location.path)
          .writeAsString('${TagGroupConfig.encode(_groups)}\n', flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('标签组配置已导出')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$error')));
      }
    }
  }

  @override
  void dispose() {
    _scanId++;
    _scanRefreshTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  _FolderTab? get _activeTab => _tabs.isEmpty ? null : _tabs[_activeTabIndex];

  void _activateTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    setState(() {
      _activeTabIndex = index;
      final tab = _tabs[index];
      _directory = tab.path;
      _visible = List.of(tab.entries);
      _error = tab.error;
      _suspectedMissingRecords = tab.suspected;
    });
    final tab = _tabs[index];
    if (tab.complete && !tab.checkedSuspected && widget.renameService != null) {
      _checkSuspectedMissingRecords(_scanId, tab);
    }
  }

  Future<void> _chooseDirectory() async {
    if (_choosing || _renaming || _copying || _scanning) return;
    setState(() => _choosing = true);
    try {
      final selected = await widget.browser.chooseDirectory();
      if (!mounted || selected == null) return;
      await _startScan(selected);
    } catch (error) {
      if (mounted) setState(() => _scanIssues.add('无法选择目录：$error'));
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  String _pathKey(String path) =>
      Directory(path).absolute.path
          .replaceAll('/', '\\')
          .replaceFirst(RegExp(r'[\\]+$'), '')
          .toLowerCase();

  bool _isBelow(String path, String parent) =>
      _pathKey(path).startsWith('${_pathKey(parent)}\\');

  void _showSourceNotice(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _startScan(String path) async {
    final key = _pathKey(path);
    final existingTab = _tabs.indexWhere((tab) => _pathKey(tab.path) == key);
    if (existingTab >= 0) {
      _activateTab(existingTab);
      _showSourceNotice('该文件夹已在标签页中');
      return;
    }
    for (final root in _roots) {
      if (_pathKey(root.path) == key) return;
      if (root.recursive && _isBelow(path, root.path)) {
        _showSourceNotice('该文件夹已包含在现有来源的递归扫描中');
        return;
      }
    }
    final root = ScanRoot(path);
    _roots.add(root);
    await _scanRoots([root], clearExisting: false, activateRoot: true);
  }

  Future<void> _rescanAll() =>
      _scanRoots(List.of(_roots), clearExisting: true, activateRoot: true);

  Future<void> _scanRoots(
    List<ScanRoot> roots, {
    required bool clearExisting,
    required bool activateRoot,
  }) async {
    final scanId = ++_scanId;
    _scanRefreshTimer?.cancel();
    await _subscription?.cancel();
    if (!mounted || scanId != _scanId) return;
    setState(() {
      if (clearExisting) {
        _tabs.clear();
        _activeTabIndex = 0;
        _directory = null;
        _visible = const [];
        _error = null;
        _suspectedMissingRecords = const [];
      }
      _selectedIds.clear();
      _scanIssues.clear();
      _cancelled = false;
      _scanning = roots.isNotEmpty;
    });
    if (roots.isEmpty) return;
    _scanRefreshTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || scanId != _scanId) return;
      final active = _activeTab;
      if (active != null && _visible.length != active.entries.length) {
        setState(() => _visible = List.of(active.entries));
      }
    });
    _subscription = widget.browser
        .scanRoots(roots)
        .listen(
          (event) {
            if (!mounted || scanId != _scanId) return;
            var index = _tabs.indexWhere((tab) => tab.path == event.path);
            if (index < 0 &&
                (event.path == event.root || event.entry != null)) {
              final tab = _FolderTab(event.path, event.root);
              setState(() {
                _tabs.add(tab);
                index = _tabs.length - 1;
                if (_tabs.length == 1 ||
                    (activateRoot && event.path == roots.first.path)) {
                  _activeTabIndex = index;
                  _directory = tab.path;
                  _visible = const [];
                  _error = null;
                  _suspectedMissingRecords = const [];
                }
              });
            }
            final tab = index < 0 ? null : _tabs[index];
            if (event.entry != null && tab != null) {
              tab.entries.add(event.entry!);
            }
            if (event.error != null) {
              if (tab != null) {
                tab.error = '读取目录失败：${event.error}';
                if (index == _activeTabIndex) {
                  setState(() => _error = tab.error);
                }
              } else {
                setState(() => _scanIssues.add('${event.path}：${event.error}'));
              }
            }
            if (event.done && tab != null) {
              tab.complete = true;
              tab.entries.sort(
                (a, b) => a.filename.toLowerCase().compareTo(
                  b.filename.toLowerCase(),
                ),
              );
              if (index == _activeTabIndex) {
                setState(() => _visible = List.of(tab.entries));
                if (widget.renameService != null && tab.error == null) {
                  _checkSuspectedMissingRecords(scanId, tab);
                }
              } else {
                setState(() {});
              }
            }
          },
          onError: (Object error) {
            if (!mounted || scanId != _scanId) return;
            _scanRefreshTimer?.cancel();
            setState(() {
              _scanning = false;
              _scanIssues.add('扫描中断：$error');
            });
          },
          onDone: () {
            if (!mounted || scanId != _scanId) return;
            _scanRefreshTimer?.cancel();
            setState(() {
              _scanning = false;
              final active = _activeTab;
              if (active != null) _visible = List.of(active.entries);
            });
          },
        );
  }

  Future<void> _checkSuspectedMissingRecords(int scanId, _FolderTab tab) async {
    if (tab.checkedSuspected) return;
    tab.checkedSuspected = true;
    try {
      final suspected = await widget.renameService!.store
          .suspectedMissingRecords(tab.entries.map((entry) => entry.filename));
      if (mounted && scanId == _scanId) {
        tab.suspected = suspected;
        if (_activeTab == tab) {
          setState(() => _suspectedMissingRecords = suspected);
        }
      }
    } catch (error) {
      if (mounted && scanId == _scanId) {
        tab.error = '检查临时名对应的事务记录失败：$error';
        if (_activeTab == tab) setState(() => _error = tab.error);
      }
    }
  }

  void _cancelScan() {
    if (!_scanning) return;
    _scanId++;
    _scanRefreshTimer?.cancel();
    final subscription = _subscription;
    _subscription = null;
    setState(() {
      _scanning = false;
      _cancelled = true;
    });
    if (subscription != null) unawaited(subscription.cancel());
  }

  List<ImageEntry> get _allEntries {
    final unique = <String, ImageEntry>{};
    for (final tab in _tabs) {
      for (final entry in tab.entries) {
        unique.putIfAbsent(entry.id.toLowerCase(), () => entry);
      }
    }
    return unique.values.toList();
  }

  List<ImageEntry> get _selectedEntries =>
      _allEntries.where((entry) => _selectedIds.contains(entry.id)).toList();

  Set<String> get _selectedDirectories => _selectedEntries
      .map((entry) => File(entry.id).parent.absolute.path.toLowerCase())
      .toSet();

  ScanRoot? get _activeRoot {
    final active = _activeTab;
    if (active == null) return null;
    for (final root in _roots) {
      if (root.path == active.root) return root;
    }
    return null;
  }

  String _tabLabel(_FolderTab tab) {
    String basename(String path) {
      final segments = Directory(path).uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      return segments.isEmpty ? path : segments.last;
    }

    final name = basename(tab.path);
    final duplicateName =
        _tabs.where((other) => basename(other.path) == name).length > 1;
    final display = duplicateName ? tab.path : name;
    if (tab.path == tab.root) return display;
    final relative = tab.path
        .substring(tab.root.length)
        .split(RegExp(r'[\\/]'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    return '${List.filled(relative.length.clamp(1, 3), '↳ ').join()}$display';
  }

  void _setRecursive(bool recursive) {
    final root = _activeRoot;
    if (root == null || _scanning || _renaming) return;
    if (recursive &&
        _roots.any(
          (other) => other != root && _isBelow(other.path, root.path),
        )) {
      _showSourceNotice('另一个已添加来源位于此目录内，请先移除它再开启递归');
      return;
    }
    final index = _roots.indexOf(root);
    _roots[index] = ScanRoot(root.path, recursive: recursive);
    _rescanAll();
  }

  void _removeActiveRoot() {
    final root = _activeRoot;
    if (root == null || _scanning || _renaming) return;
    _roots.remove(root);
    _rescanAll();
  }

  TagFilter get _activeFilter => TagFilter(
    onlyUntagged: _onlyUntagged,
    allOf: _filterRoles.entries
        .where((entry) => entry.value == _FilterRole.required)
        .map((entry) => entry.key),
    anyOf: _filterRoles.entries
        .where((entry) => entry.value == _FilterRole.any)
        .map((entry) => entry.key),
    noneOf: _filterRoles.entries
        .where((entry) => entry.value == _FilterRole.excluded)
        .map((entry) => entry.key),
  );

  List<_FilterOption> _filterOptionsFor(List<ImageEntry> entries) {
    final options = <String, String>{};
    for (final image in entries) {
      for (final rawTag in image.parsedFilename.tags) {
        final identity = _groups.identity(rawTag);
        options.putIfAbsent(
          identity,
          () => identity.startsWith('group:')
              ? _groups.group(identity.substring(6)).displayName
              : rawTag,
        );
      }
    }
    for (final identity in _filterRoles.keys) {
      options.putIfAbsent(identity, () {
        if (identity.startsWith('raw:')) return identity.substring(4);
        if (identity.startsWith('group:')) {
          final id = identity.substring(6);
          for (final group in _groups.all) {
            if (group.id == id) return group.displayName;
          }
        }
        return identity;
      });
    }
    final sorted = options.entries
        .map((entry) => _FilterOption(entry.key, entry.value))
        .toList();
    sorted.sort((a, b) => a.label.compareTo(b.label));
    return sorted;
  }

  void _setFilterRole(String identity, _FilterRole role) {
    setState(() {
      if (role == _FilterRole.ignored) {
        _filterRoles.remove(identity);
      } else {
        _onlyUntagged = false;
        _filterRoles[identity] = role;
      }
      _selectedIds.clear();
    });
  }

  void _toggleSelected(String id) {
    if (_renaming) return;
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  String _filterButtonText(_FilterOption option, _FilterRole role) =>
      role == _FilterRole.ignored
      ? option.label
      : '${option.label}  ${role.shortLabel}';

  Future<void> _showFilterHelp(BuildContext context) => showDialog<void>(
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
          Text('不参与：默认状态，该标签不影响筛选结果。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> _showRoleMenu(
    BuildContext context,
    _FilterOption option, {
    required VoidCallback refreshDialog,
  }) async {
    final button = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final group = option.identity.startsWith('group:')
        ? _groups.group(option.identity.substring(6))
        : null;
    final role = await showMenu<_FilterRole>(
      context: context,
      position: RelativeRect.fromRect(
        topLeft & button.size,
        Offset.zero & overlay.size,
      ),
      items: [
        if (group != null) ...[
          PopupMenuItem<_FilterRole>(
            enabled: false,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('同组别名（${group.aliases.length}）'),
                  const SizedBox(height: 4),
                  Text(group.aliases.join(' · '), softWrap: true),
                ],
              ),
            ),
          ),
          const PopupMenuDivider(),
        ],
        ..._FilterRole.values.map(
          (value) => PopupMenuItem<_FilterRole>(
            value: value,
            child: Text(
              value == _FilterRole.ignored
                  ? value.label
                  : '${value.shortLabel}  ${value.label}',
            ),
          ),
        ),
      ],
    );
    if (role == null || !mounted) return;
    _setFilterRole(option.identity, role);
    refreshDialog();
  }

  Future<void> _showFilterDialog(List<_FilterOption> options) async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refreshDialog) => AlertDialog(
          title: Row(
            children: [
              const Text('组合筛选'),
              IconButton(
                key: const ValueKey('filter-help'),
                tooltip: '筛选模式说明',
                onPressed: () => _showFilterHelp(context),
                icon: const Icon(Icons.info_outline),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            height: 400,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in options)
                    Builder(
                      builder: (buttonContext) => OutlinedButton(
                        key: ValueKey('filter:${option.identity}'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor:
                              (_filterRoles[option.identity] ??
                                      _FilterRole.ignored)
                                  .backgroundColor,
                        ),
                        onPressed: () => _showRoleMenu(
                          buttonContext,
                          option,
                          refreshDialog: () => refreshDialog(() {}),
                        ),
                        child: Text(
                          _filterButtonText(
                            option,
                            _filterRoles[option.identity] ??
                                _FilterRole.ignored,
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
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allEntries = _allEntries;
    final options = _filterOptionsFor(allEntries);
    final filter = _activeFilter;
    final filtered = _visible
        .where((image) => filter.matches(image.parsedFilename, _groups))
        .toList();
    final allSelected =
        filtered.isNotEmpty &&
        filtered.every((image) => _selectedIds.contains(image.id));
    final someSelected = filtered.any(
      (image) => _selectedIds.contains(image.id),
    );
    final allFiltered = <ImageEntry>[];
    final matchingByTab = <_FolderTab, int>{};
    final matchedIds = <String>{};
    for (final tab in _tabs) {
      var count = 0;
      for (final image in tab.entries) {
        if (!filter.matches(image.parsedFilename, _groups)) continue;
        count++;
        if (matchedIds.add(image.id.toLowerCase())) allFiltered.add(image);
      }
      matchingByTab[tab] = count;
    }
    final selectedDirectories = allEntries
        .where((entry) => _selectedIds.contains(entry.id))
        .map((entry) => File(entry.id).parent.absolute.path.toLowerCase())
        .toSet();
    final selectedInCurrent = _visible
        .where((entry) => _selectedIds.contains(entry.id))
        .length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('图签'),
        actions: [
          const AppAboutMenuButton(),
          IconButton(
            tooltip: '使用指南',
            icon: const Icon(Icons.error_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => UsageGuidePage(
                  preferences: LocalGuidePreferences(),
                  assetPath: UsageGuidePage.windowsAssetPath,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _choosing || _renaming || _scanning
                      ? null
                      : _chooseDirectory,
                  icon: const Icon(Icons.folder_open),
                  label: Text(_roots.isEmpty ? '选择图片文件夹' : '添加图片文件夹'),
                ),
                if (widget.groupStore != null) ...[
                  for (final mode in TagGroupEditorMode.values)
                    OutlinedButton(
                      onPressed:
                          _loadingGroups || _groupsError != null || _renaming
                          ? null
                          : () => showDialog<void>(
                              context: context,
                              builder: (_) => TagGroupEditor(
                                groups: _groups,
                                onSave: _saveGroups,
                                mode: mode,
                              ),
                            ),
                      child: Text(
                        mode == TagGroupEditorMode.names ? '标签名组' : '标签类组',
                      ),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '标签组配置',
                    enabled:
                        !_loadingGroups &&
                        !_renaming &&
                        _groupsError == null &&
                        _profiles != null,
                    onSelected: (value) {
                      if (value.startsWith('switch:')) {
                        _switchProfile(value.substring(7));
                      } else if (value == 'new') {
                        _newProfile();
                      } else if (value == 'rename') {
                        _renameProfile();
                      } else if (value == 'import') {
                        _importGroups();
                      } else if (value == 'export') {
                        _exportGroups();
                      } else if (value == 'delete') {
                        _deleteProfile();
                      }
                    },
                    itemBuilder: (_) => [
                      for (final profile
                          in _profiles?.profiles ?? <TagGroupProfile>[])
                        PopupMenuItem(
                          value: 'switch:${profile.id}',
                          child: Text(
                            '${profile.id == _profiles?.activeId ? '✓ ' : ''}${profile.name}',
                          ),
                        ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: 'new', child: Text('新建空配置')),
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('重命名当前配置'),
                      ),
                      const PopupMenuItem(
                        value: 'import',
                        child: Text('导入为新配置'),
                      ),
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('导出当前配置'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除当前配置'),
                      ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('配置 ▾'),
                    ),
                  ),
                  if (_profiles != null) Text('当前：${_profiles!.active.name}'),
                ],
                if (widget.renameService != null &&
                    (_completedTransactions.isNotEmpty ||
                        _manualClosedTransactions.isNotEmpty))
                  if (Platform.isWindows)
                    OutlinedButton(
                      onPressed: _renaming ? null : _showCompletedTransactions,
                      child: const Text('历史操作'),
                    ),
                if (_scanning)
                  TextButton(onPressed: _cancelScan, child: const Text('取消扫描')),
                Text(
                  _activeRoot?.recursive == true
                      ? '包含子文件夹，每个子目录独立成页'
                      : '仅当前文件夹，不包含子文件夹',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_tabs.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: DefaultTabController(
                      key: ValueKey(
                        'folder-tabs-${_tabs.length}-$_activeTabIndex',
                      ),
                      length: _tabs.length,
                      initialIndex: _activeTabIndex,
                      child: TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        onTap: _activateTab,
                        tabs: [
                          for (final tab in _tabs)
                            Tooltip(
                              message: tab.path,
                              child: Tab(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_tabLabel(tab)),
                                    const SizedBox(width: 6),
                                    Text(
                                      '${matchingByTab[tab] ?? 0}',
                                      key: ValueKey('tab-match:${tab.path}'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_tabs.length > 1)
                    PopupMenuButton<int>(
                      key: const ValueKey('jump-to-folder'),
                      tooltip: '跳转文件夹',
                      onSelected: _activateTab,
                      itemBuilder: (context) => [
                        for (var index = 0; index < _tabs.length; index++)
                          PopupMenuItem<int>(
                            value: index,
                            child: Text(
                              '${index == _activeTabIndex ? '✓ ' : ''}${_tabLabel(_tabs[index])}（${matchingByTab[_tabs[index]] ?? 0}）',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      icon: const Icon(Icons.unfold_more),
                    ),
                  IconButton(
                    key: const ValueKey('recursive-source'),
                    tooltip: _activeRoot?.recursive == true
                        ? '关闭当前来源的递归扫描'
                        : '包含当前来源的子文件夹',
                    onPressed: _scanning || _renaming || _copying
                        ? null
                        : () =>
                              _setRecursive(!(_activeRoot?.recursive ?? false)),
                    icon: Icon(
                      _activeRoot?.recursive == true
                          ? Icons.account_tree
                          : Icons.account_tree_outlined,
                    ),
                  ),
                  IconButton(
                    tooltip: '移除当前来源',
                    onPressed:
                        _activeTab?.path != _activeTab?.root ||
                            _scanning ||
                            _renaming ||
                            _copying
                        ? null
                        : _removeActiveRoot,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            for (final issue in _scanIssues)
              Text(
                issue,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_loadingGroups) const LinearProgressIndicator(),
            if (_pendingTransactions.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('有 ${_pendingTransactions.length} 个未解决的文件名事务'),
                      for (final (index, pending)
                          in _pendingTransactions.indexed)
                        Tooltip(
                          message: pending.plan?.id ?? pending.path,
                          child: TextButton(
                            onPressed: _renaming
                                ? null
                                : () => _showPendingTransaction(pending),
                            child: Text(
                              _pendingTransactionLabel(pending, index == 0),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (_suspectedMissingRecords.isNotEmpty)
              Card(
                color: const Color(0xFFFFF3D6),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '疑似批次记录缺失：当前目录发现 ~itm- 临时名图片，'
                        '但找不到对应的计划和事件日志。请保留文件并核查备份；程序无法据此重建原批次。',
                      ),
                      for (final record in _suspectedMissingRecords.take(3))
                        SelectableText(
                          '${record.id ?? '无法辨认批次 ID'} · '
                          '${record.filenames.length} 张 · 例如 ${record.filenames.first}',
                        ),
                      if (_suspectedMissingRecords.length > 3)
                        Text('另有 ${_suspectedMissingRecords.length - 3} 组线索。'),
                    ],
                  ),
                ),
              ),
            if (_renaming) ...[
              LinearProgressIndicator(
                value: _renameTotal == 0 ? null : _renameDone / _renameTotal,
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_renameStage ?? '处理中'} · $_renameDone / $_renameTotal。取消后第一阶段尝试恢复原名，第二阶段保存现场。',
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _cancelRename = true),
                    child: const Text('请求取消'),
                  ),
                ],
              ),
            ] else if (_renameStage != null)
              Text(_renameStage!),
            if (_groupsError != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _groupsError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  TextButton(onPressed: _loadGroups, child: const Text('重试读取')),
                ],
              ),
            if (_filterNotice != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(child: Text(_filterNotice!)),
                      TextButton(
                        onPressed: () => setState(() => _filterNotice = null),
                        child: const Text('知道了'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_scanning) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_directory != null)
              Text(
                _cancelled
                    ? '扫描已取消，已读取 ${_visible.length} 张'
                    : _error != null
                    ? '扫描中断，已读取 ${_visible.length} 张'
                    : _scanning
                    ? '正在读取：${_visible.length} 张'
                    : '找到 ${_visible.length} 张图片',
              ),
            if (_directory != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: options.isEmpty || _scanning || _renaming
                        ? null
                        : () => _showFilterDialog(options),
                    icon: const Icon(Icons.filter_alt_outlined),
                    label: const Text('筛选标签'),
                  ),
                  FilterChip(
                    key: const ValueKey('untagged-filter'),
                    label: const Text('仅显示无标签'),
                    selected: _onlyUntagged,
                    onSelected:
                        _scanning || _renaming || _cancelled || _error != null
                        ? null
                        : (selected) => setState(() {
                            _onlyUntagged = selected;
                            _filterRoles.clear();
                            _selectedIds.clear();
                          }),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        key: const ValueKey('select-all-filtered'),
                        tristate: true,
                        value: allSelected
                            ? true
                            : someSelected
                            ? null
                            : false,
                        onChanged:
                            _scanning ||
                                _renaming ||
                                _cancelled ||
                                _error != null ||
                                filtered.isEmpty
                            ? null
                            : (_) => setState(() {
                                if (allSelected) {
                                  _selectedIds.removeAll(
                                    filtered.map((image) => image.id),
                                  );
                                } else {
                                  _selectedIds.addAll(
                                    filtered.map((image) => image.id),
                                  );
                                }
                              }),
                      ),
                      Text('全选当前页筛选结果（${filtered.length} 张）'),
                    ],
                  ),
                  if (_tabs.length > 1)
                    OutlinedButton(
                      key: const ValueKey('select-all-folders'),
                      onPressed:
                          _scanning ||
                              _renaming ||
                              _cancelled ||
                              allFiltered.isEmpty
                          ? null
                          : () => setState(
                              () => _selectedIds.addAll(
                                allFiltered.map((entry) => entry.id),
                              ),
                            ),
                      child: Text('全选全部文件夹结果（${allFiltered.length} 张）'),
                    ),
                  if (_filterRoles.isNotEmpty || _onlyUntagged)
                    TextButton(
                      onPressed: _renaming
                          ? null
                          : () => setState(() {
                              _filterRoles.clear();
                              _onlyUntagged = false;
                              _selectedIds.clear();
                            }),
                      child: const Text('清空筛选'),
                    ),
                  if (_selectedIds.isNotEmpty) ...[
                    TextButton(
                      onPressed: _renaming || selectedInCurrent == 0
                          ? null
                          : () => setState(
                              () => _selectedIds.removeAll(
                                _visible.map((entry) => entry.id),
                              ),
                            ),
                      child: const Text('清空当前页选择'),
                    ),
                    if (_tabs.length > 1)
                      TextButton(
                        onPressed: _renaming
                            ? null
                            : () => setState(_selectedIds.clear),
                        child: const Text('清空全部选择'),
                      ),
                  ],
                  if (widget.renameService != null)
                    Tooltip(
                      message: selectedDirectories.length > 1
                          ? '已选图片分属不同文件夹，请只选择同一文件夹的图片改名'
                          : '修改同一文件夹内的已选图片',
                      child: FilledButton(
                        onPressed:
                            _selectedIds.isEmpty ||
                                selectedDirectories.length != 1 ||
                                _scanning ||
                                _cancelled ||
                                _groupsError != null ||
                                _loadingGroups ||
                                _renaming
                            ? null
                            : _editSelected,
                        child: Text('修改已选文件名（${_selectedIds.length}）'),
                      ),
                    ),
                  if (Platform.isWindows)
                    OutlinedButton(
                      onPressed:
                          _selectedIds.isEmpty ||
                              _scanning ||
                              _cancelled ||
                              _renaming ||
                              _copying
                          ? null
                          : _copySelected,
                      child: Text('复制已选图片（${_selectedIds.length}）'),
                    ),
                  Text(
                    '显示 ${filtered.length} / ${_visible.length} 张 · 已选 ${_selectedIds.length} 张 · 全部匹配 ${allFiltered.length} 张',
                  ),
                ],
              ),
              if (_filterRoles.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in options)
                      if (_filterRoles.containsKey(option.identity))
                        Builder(
                          builder: (buttonContext) => OutlinedButton(
                            key: ValueKey('active-filter:${option.identity}'),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: _filterRoles[option.identity]!
                                  .backgroundColor,
                            ),
                            onPressed: () => _showRoleMenu(
                              buttonContext,
                              option,
                              refreshDialog: () {},
                            ),
                            child: Text(
                              _filterButtonText(
                                option,
                                _filterRoles[option.identity]!,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: 8),
            Expanded(
              child: _directory == null
                  ? const Center(child: Text('请选择一个文件夹开始浏览'))
                  : _visible.isEmpty && !_scanning && _error == null
                  ? const Center(child: Text('当前文件夹没有找到支持格式的图片'))
                  : filtered.isEmpty && !_scanning && _error == null
                  ? const Center(child: Text('没有符合筛选条件的图片'))
                  : GridView.builder(
                      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 220,
                            mainAxisExtent: 230,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final entry = filtered[index];
                        final tags = entry.parsedFilename.tags;
                        final selected = _selectedIds.contains(entry.id);
                        return Card(
                          key: ValueKey(entry.id),
                          clipBehavior: Clip.antiAlias,
                          color: selected
                              ? Theme.of(context).colorScheme.primaryContainer
                              : null,
                          child: InkWell(
                            onTap: () => _toggleSelected(entry.id),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ImageThumbnail(path: entry.id),
                                      Positioned(
                                        top: 4,
                                        left: 4,
                                        child: Checkbox(
                                          value: selected,
                                          onChanged: (_) =>
                                              _toggleSelected(entry.id),
                                        ),
                                      ),
                                      Positioned(
                                        top: 4,
                                        right: 4,
                                        child: IconButton(
                                          tooltip: '查看原图',
                                          style: IconButton.styleFrom(
                                            backgroundColor: Colors.black54,
                                            foregroundColor: Colors.white,
                                          ),
                                          onPressed: () => showImageViewer(
                                            context,
                                            path: entry.id,
                                            filename: entry.filename,
                                          ),
                                          icon: const Icon(Icons.open_in_full),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    4,
                                    8,
                                    2,
                                  ),
                                  child: Tooltip(
                                    message: entry.filename,
                                    child: Text(
                                      entry.filename,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    0,
                                    8,
                                    6,
                                  ),
                                  child: Text(
                                    tags.isEmpty
                                        ? '无标签'
                                        : tags
                                              .map((tag) {
                                                final identity = _groups
                                                    .identity(tag);
                                                return identity.startsWith(
                                                      'group:',
                                                    )
                                                    ? '[${_groups.group(identity.substring(6)).displayName}]'
                                                    : '[$tag]';
                                              })
                                              .toSet()
                                              .join(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows a verified batch result without reading or modifying files.
final class RenameResultDialog extends StatelessWidget {
  const RenameResultDialog({
    required this.outcome,
    this.statuses = const [],
    this.offerSafeContinuation = false,
    super.key,
  });

  final RenameOutcome outcome;
  final List<RenameItemStatus> statuses;
  final bool offerSafeContinuation;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(switch (outcome.state) {
      'completed' => '文件名修改完成',
      'cancelled' => '操作已取消',
      'rolledBack' => '已恢复原名',
      'notChanged' => '未改名，文件保持原名',
      'pending' => '事务待处理',
      _ => '需要人工核对',
    }),
    content: SizedBox(
      width: 650,
      height: statuses.isEmpty && outcome.issues.isEmpty ? 130 : 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            '${outcome.details}\n已处理 ${outcome.done} / ${outcome.total} 项。',
          ),
          if (statuses.isNotEmpty || outcome.issues.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: outcome.issues.length + statuses.length,
                itemBuilder: (context, index) {
                  if (index < outcome.issues.length) {
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.warning_amber_rounded),
                      title: SelectableText(outcome.issues[index]),
                    );
                  }
                  final status = statuses[index - outcome.issues.length];
                  final location = switch (status.location) {
                    'original' => '原名',
                    'temporary' => '临时名',
                    'target' => '目标名',
                    _ => '状态不明',
                  };
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${status.item.original} → ${status.item.target}',
                    ),
                    subtitle: Text(
                      '当前：$location · 计划临时名：${status.item.temporary}'
                      '${status.problem == null ? '' : '\n${status.problem}'}',
                    ),
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
        child: const Text('关闭'),
      ),
      if (offerSafeContinuation && outcome.canContinueSafe)
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('跳过异常项，继续安全项'),
        ),
    ],
  );
}
