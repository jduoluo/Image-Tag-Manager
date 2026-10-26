import 'dart:io';
import 'dart:convert';
import 'dart:math';

import '../domain/rename_plan.dart';
import '../domain/tag_groups.dart';
import '../infrastructure/rename_transaction_store.dart';
import '../infrastructure/windows_rename_port.dart';
import 'directory_browser.dart';

typedef RenameProgress = void Function(String stage, int done, int total);

final class RenameOutcome {
  const RenameOutcome(
    this.state,
    this.details,
    this.done,
    this.total, {
    this.issues = const [],
    this.canContinueSafe = false,
  });

  /// completed, rolledBack, notChanged, cancelled, pending, or manual.
  final String state;
  final String details;
  final int done;
  final int total;
  final List<String> issues;
  final bool canContinueSafe;
}

final class RenameItemStatus {
  const RenameItemStatus(
    this.item,
    this.location, {
    this.conflicts = const {},
    this.locationIssue,
  });

  final RenamePlanItem item;

  /// original, temporary, target, or unknown.
  final String location;

  /// Occupied planned positions keyed by original, temporary, or target.
  final Map<String, String> conflicts;
  final String? locationIssue;

  String? get problem {
    final parts = [?locationIssue, ...conflicts.values];
    return parts.isEmpty ? null : parts.join('；');
  }
}

/// Coordinates one same-directory transaction, never touching image content.
final class RenameService {
  RenameService({
    required this.port,
    required this.store,
    this.maxPathLength = 259,
    this.maxFilenameBytes,
  });

  final RenamePort port;
  final RenameTransactionStore store;
  final int? maxPathLength;
  final int? maxFilenameBytes;
  bool _tooLong(String directory, String name) =>
      (maxPathLength != null &&
          _path(directory, name).length > maxPathLength!) ||
      (maxFilenameBytes != null &&
          utf8.encode(name).length > maxFilenameBytes!);

  String _path(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';

  Future<Map<String, String>> _names(String directory) async {
    final names = <String, String>{};
    final adapter = port;
    final entries = adapter is RenameDirectoryListing
        ? await (adapter as RenameDirectoryListing).directoryNames(directory)
        : await Directory(directory)
              .list(followLinks: false)
              .map((entry) => entry.path.split(Platform.pathSeparator).last)
              .toList();
    for (final name in entries) {
      final key = windowsNameKey(name);
      if (names.containsKey(key)) throw StateError('目录含有大小写等价的重复名称：$name');
      names[key] = name;
    }
    return names;
  }

  static String _batchId() {
    final time = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    final random = Random.secure()
        .nextInt(0x100000000)
        .toRadixString(16)
        .padLeft(8, '0');
    return 'itm-$time-$random';
  }

  Future<RenamePlan> preview({
    required String directory,
    required List<ImageEntry> selected,
    required Map<String, RenameEdit> edits,
    required TagGroups groups,
    String? batchId,
  }) async {
    final root = Directory(directory).absolute.path;
    final id = batchId ?? _batchId();
    final issues = <String>[];
    final unchanged = <String>[];
    final items = <RenamePlanItem>[];
    if (selected.isEmpty) issues.add('未选择图片');
    late Map<String, String> occupied;
    try {
      occupied = await _names(root);
    } catch (error) {
      return RenamePlan(
        id: id,
        directory: root,
        items: const [],
        unchanged: const [],
        issues: ['无法读取目录：$error'],
      );
    }
    final seenSources = <String>{};
    for (final entry in selected) {
      final sourceName = entry.filename;
      final sourceKey = windowsNameKey(sourceName);
      if (!seenSources.add(sourceKey)) {
        issues.add('重复选择：$sourceName');
        continue;
      }
      if (File(entry.id).absolute.path.toUpperCase() !=
          _path(root, sourceName).toUpperCase()) {
        issues.add('选择项不属于当前目录：$sourceName');
        continue;
      }
      if (occupied[sourceKey] != sourceName) {
        final actual = occupied[sourceKey];
        issues.add(
          actual == null
              ? '目录中未找到所选源文件：$sourceName（系统记录可能未同步）'
              : '源文件名与目录不一致：$sourceName；目录中的实际名称：$actual',
        );
        continue;
      }
      final edit = edits[entry.id] ?? RenameEdit();
      String target;
      try {
        target = edit.apply(entry.parsedFilename, groups).serialize();
      } catch (error) {
        issues.add('$sourceName：编辑无效：$error');
        continue;
      }
      if (target == sourceName) {
        unchanged.add(sourceName);
        continue;
      }
      if (validateWindowsFilename(sourceName) != null) {
        issues.add('原名不符合当前可写命名规则：$sourceName');
        continue;
      }
      final targetProblem = validateWindowsFilename(target);
      if (targetProblem != null || _tooLong(root, target)) {
        issues.add(
          '$sourceName → $target：${targetProblem ?? '文件名或完整路径超过平台长度限制'}',
        );
        continue;
      }
      String fileId;
      try {
        if (entry.fileId == null || entry.fileId!.isEmpty) {
          issues.add('$sourceName：扫描时无法获取可靠文件身份');
          continue;
        }
        fileId = await port.identity(
          _path(root, sourceName),
          requireDelete: true,
        );
        if (fileId != entry.fileId) {
          issues.add('$sourceName：文件身份在扫描后发生变化');
          continue;
        }
      } catch (error) {
        issues.add('$sourceName：无法核对文件身份：$error');
        continue;
      }
      final extension = entry.parsedFilename.extension;
      final temp = '~$id-${items.length.toString().padLeft(4, '0')}$extension';
      if (validateWindowsFilename(temp) != null || _tooLong(root, temp)) {
        issues.add('$sourceName：临时名过长或无效');
        continue;
      }
      items.add(
        RenamePlanItem(
          original: sourceName,
          temporary: temp,
          target: target,
          fileId: fileId,
          reason: '标签或主体名修改',
        ),
      );
    }
    final moving = items.map((item) => windowsNameKey(item.original)).toSet();
    final targets = <String>{};
    final temporary = <String>{};
    for (final item in items) {
      final targetKey = windowsNameKey(item.target);
      final tempKey = windowsNameKey(item.temporary);
      if (!targets.add(targetKey)) issues.add('批次内目标重名：${item.target}');
      if (!temporary.add(tempKey) || occupied.containsKey(tempKey)) {
        issues.add('临时名已占用：${item.temporary}');
      }
      if (occupied.containsKey(targetKey) && !moving.contains(targetKey)) {
        issues.add('目标被批次外项目占用：${item.target}');
      }
    }
    for (final item in items) {
      final tempKey = windowsNameKey(item.temporary);
      if (targets.contains(tempKey) || seenSources.contains(tempKey)) {
        issues.add('临时名与原名或目标名冲突：${item.temporary}');
      }
    }
    return RenamePlan(
      id: id,
      directory: root,
      items: items,
      unchanged: unchanged,
      issues: issues,
    );
  }

  Future<List<String>> _revalidate(RenamePlan plan) async {
    final issues = <String>[];
    final occupied = await _names(plan.directory);
    final moving = plan.items
        .map((item) => windowsNameKey(item.original))
        .toSet();
    for (final item in plan.items) {
      final source = _path(plan.directory, item.original);
      if (occupied[windowsNameKey(item.original)] != item.original) {
        issues.add('源名已变化：${item.original}');
      } else {
        try {
          if (await port.identity(source, requireDelete: true) != item.fileId) {
            issues.add('源文件身份已变化：${item.original}');
          }
        } catch (error) {
          issues.add('源文件无法核对：${item.original}：$error');
        }
      }
      if (occupied.containsKey(windowsNameKey(item.temporary))) {
        issues.add('临时名被占用：${item.temporary}');
      }
      final targetKey = windowsNameKey(item.target);
      if (occupied.containsKey(targetKey) && !moving.contains(targetKey)) {
        issues.add('目标被占用：${item.target}');
      }
    }
    return issues;
  }

  Future<String?> _identityIfPresent(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    return port.identity(path);
  }

  Future<void> _step(
    RenamePlan plan,
    RenamePlanItem item,
    String from,
    String to,
    String stage,
  ) async {
    final source = _path(plan.directory, from);
    final target = _path(plan.directory, to);
    await store.event(plan.id, 'intent:$stage', item.original, '$from -> $to');
    for (var attempt = 0; attempt < 3; attempt++) {
      final currentId = await _identityIfPresent(source);
      if (currentId != item.fileId) throw StateError('源文件身份或位置变化：$from');
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('目标已被占用：$to');
      }
      try {
        await port.renameNoReplace(source, target, item.fileId);
        if (await _identityIfPresent(target) != item.fileId) {
          throw StateError('重命名后无法核对文件身份：$to');
        }
        await store.event(plan.id, 'done:$stage', item.original);
        return;
      } on RenamePortException catch (error) {
        if (error.requiresInspection) {
          await store.event(
            plan.id,
            'uncertain:$stage',
            item.original,
            error.message,
          );
          rethrow;
        }
        // A call can fail after the rename actually happened; verify first.
        if (await _identityIfPresent(target) == item.fileId &&
            await _identityIfPresent(source) == null) {
          await store.event(
            plan.id,
            'done:$stage',
            item.original,
            'verified after error',
          );
          return;
        }
        if (!error.isTransient || attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<RenameOutcome> execute(
    RenamePlan plan, {
    RenameProgress? progress,
    bool Function()? cancelled,
    Set<String> acknowledgedPendingPaths = const {},
  }) async {
    if (!plan.canExecute) {
      return RenameOutcome('manual', '计划存在冲突或没有实际改名项', 0, plan.items.length);
    }
    final pending = await store.pending();
    if (pending.any(
      (transaction) => !acknowledgedPendingPaths.contains(transaction.path),
    )) {
      return RenameOutcome('manual', '存在未解决事务，请先确认继续新批次', 0, plan.items.length);
    }
    final issues = await _revalidate(plan);
    if (issues.isNotEmpty) {
      return RenameOutcome('manual', issues.join('\n'), 0, plan.items.length);
    }
    await store.savePlan(plan);
    final confirmed = await _revalidate(plan);
    if (confirmed.isNotEmpty) {
      await store.event(plan.id, 'rolledBack', null, confirmed.join('; '));
      return RenameOutcome(
        'manual',
        confirmed.join('\n'),
        0,
        plan.items.length,
      );
    }
    var done = 0;
    try {
      await store.event(plan.id, 'stage1');
      for (final item in plan.items) {
        if (cancelled?.call() == true) throw StateError('用户取消第一阶段');
        progress?.call('第一阶段：转入临时名', done, plan.items.length);
        await _step(plan, item, item.original, item.temporary, 'stage1');
        done++;
      }
    } catch (error) {
      if (error is RenamePortException && error.requiresInspection) {
        return RenameOutcome(
          'manual',
          '系统返回非预期结果，已停止，未自动回滚：$error',
          done,
          plan.items.length,
          issues: [error.message],
        );
      }
      progress?.call('正在核对并回滚第一阶段', done, plan.items.length);
      return _rollback(plan, '$error');
    }
    return _finishStage2(plan, progress: progress, cancelled: cancelled);
  }

  Future<RenameOutcome> _finishStage2(
    RenamePlan plan, {
    RenameProgress? progress,
    bool Function()? cancelled,
    Map<String, String> skipped = const {},
  }) async {
    var done = 0;
    try {
      final names = await _names(plan.directory);
      for (final item in plan.items) {
        if (skipped.containsKey(item.original)) continue;
        final location = await _location(plan, item, names);
        if (location != 'temporary' && location != 'target') {
          throw StateError('文件位置不明：${item.original}');
        }
        if (location == 'temporary' &&
            names.containsKey(windowsNameKey(item.target))) {
          throw StateError('续做前发现目标被占用：${item.target}');
        }
      }
      await store.event(plan.id, 'stage2');
      for (final item in plan.items) {
        if (skipped.containsKey(item.original)) continue;
        if (cancelled?.call() == true) throw StateError('用户取消第二阶段');
        progress?.call('第二阶段：写入目标名', done, plan.items.length);
        final location = await _location(plan, item, names);
        if (location == 'target') {
          done++;
          continue;
        }
        if (location != 'temporary') {
          throw StateError('文件位置不明：${item.original}');
        }
        await _step(plan, item, item.temporary, item.target, 'stage2');
        names.remove(windowsNameKey(item.temporary));
        names[windowsNameKey(item.target)] = item.target;
        done++;
      }
      final finalNames = await _names(plan.directory);
      for (final item in plan.items) {
        if (skipped.containsKey(item.original)) continue;
        if (await _location(plan, item, finalNames) != 'target') {
          throw StateError('最终核对未通过：${item.original}');
        }
      }
      if (skipped.isNotEmpty) {
        final issues = <String>[];
        for (final item in plan.items) {
          final reason = skipped[item.original];
          if (reason == null) continue;
          issues.add(
            _formatIssue(await _inspectItem(plan, item, finalNames), reason),
          );
        }
        return RenameOutcome(
          'manual',
          '已处理可确认安全的项目；仍有 ${skipped.length} 项待人工核对，事务保持未解决。',
          done,
          plan.items.length,
          issues: issues,
        );
      }
      await store.event(plan.id, 'complete');
      progress?.call('已完成', done, plan.items.length);
      return RenameOutcome('completed', '全部目标文件已核对', done, plan.items.length);
    } catch (error) {
      return RenameOutcome(
        'pending',
        '第二阶段停止，已完成项保持目标名：$error',
        done,
        plan.items.length,
      );
    }
  }

  Future<String> _location(
    RenamePlan plan,
    RenamePlanItem item, [
    Map<String, String>? knownNames,
  ]) async => (await _inspectItem(plan, item, knownNames)).location;

  Future<RenameItemStatus> _inspectItem(
    RenamePlan plan,
    RenamePlanItem item, [
    Map<String, String>? knownNames,
  ]) async {
    final names = knownNames ?? await _names(plan.directory);
    final planned = {
      'original': item.original,
      'temporary': item.temporary,
      'target': item.target,
    };
    final matches = <String, String>{};
    final conflicts = <String, String>{};
    for (final entry in planned.entries) {
      final name = entry.value;
      final actual = names[windowsNameKey(name)];
      if (actual == null) continue;
      final path = _path(plan.directory, actual);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        final kind = switch (type) {
          FileSystemEntityType.directory => '目录',
          FileSystemEntityType.link => '链接',
          _ => '已变化的项目',
        };
        conflicts[entry.key] = '${_positionLabel(entry.key)}被$kind占用：$actual';
        continue;
      }
      try {
        if (await port.identity(path) == item.fileId) {
          matches[entry.key] = actual;
        } else {
          conflicts[entry.key] =
              '${_positionLabel(entry.key)}被其他文件占用（身份不符）：$actual';
        }
      } catch (error) {
        conflicts[entry.key] =
            '${_positionLabel(entry.key)}无法核对文件身份：$actual：$error';
      }
    }
    if (matches.length == 1) {
      final match = matches.entries.single;
      if (match.value == planned[match.key]) {
        return RenameItemStatus(item, match.key, conflicts: conflicts);
      }
      return RenameItemStatus(
        item,
        'unknown',
        conflicts: conflicts,
        locationIssue: '文件名大小写与计划不一致：${match.value}',
      );
    }
    return RenameItemStatus(
      item,
      'unknown',
      conflicts: conflicts,
      locationIssue: matches.isEmpty
          ? '计划中的原名、临时名和目标名均未找到原文件身份'
          : '同一文件身份出现在多个计划位置：${matches.values.join('、')}',
    );
  }

  static String _positionLabel(String position) => switch (position) {
    'original' => '原名',
    'temporary' => '临时名',
    _ => '目标名',
  };

  static String _formatIssue(RenameItemStatus status, String reason) {
    final item = status.item;
    final location = status.location == 'unknown'
        ? '无法确认'
        : _positionLabel(status.location);
    return '原名：${item.original}；计划临时名：${item.temporary}；'
        '目标名：${item.target}；当前：$location；原因：$reason';
  }

  Future<List<RenameItemStatus>> inspect(RenamePlan plan) async {
    final names = await _names(plan.directory);
    final statuses = <RenameItemStatus>[];
    for (final item in plan.items) {
      statuses.add(await _inspectItem(plan, item, names));
    }
    return statuses;
  }

  Future<RenamePlan> previewReverse(RenamePlan completed) async {
    final id = _batchId();
    final items = <RenamePlanItem>[];
    for (var index = 0; index < completed.items.length; index++) {
      final old = completed.items[index];
      final extension = old.target.contains('.')
          ? old.target.substring(old.target.lastIndexOf('.'))
          : '';
      items.add(
        RenamePlanItem(
          original: old.target,
          temporary: '~$id-${index.toString().padLeft(4, '0')}$extension',
          target: old.original,
          fileId: old.fileId,
          reason: '撤销事务 ${completed.id}',
        ),
      );
    }
    final candidate = RenamePlan(
      id: id,
      directory: completed.directory,
      items: items,
      unchanged: const [],
      issues: const [],
    );
    final issues = <String>[];
    try {
      issues.addAll(await _revalidate(candidate));
    } catch (error) {
      issues.add('无法核对撤销计划：$error');
    }
    return RenamePlan(
      id: id,
      directory: completed.directory,
      items: items,
      unchanged: const [],
      issues: issues,
    );
  }

  Future<RenameOutcome> _rollback(
    RenamePlan plan,
    String reason, {
    Map<String, String> skipped = const {},
  }) async {
    final errors = <String>[];
    var restored = 0;
    var alreadyOriginal = 0;
    late Map<String, String> names;
    try {
      names = await _names(plan.directory);
    } catch (error) {
      return RenameOutcome(
        'manual',
        '$reason\n无法读取目录以安全回滚：$error',
        0,
        plan.items.length,
      );
    }
    for (final item in plan.items.reversed) {
      if (skipped.containsKey(item.original)) {
        errors.add('${item.original}：已跳过，${skipped[item.original]}');
        continue;
      }
      final location = await _location(plan, item, names);
      if (location == 'original') {
        alreadyOriginal++;
        continue;
      }
      if (location != 'temporary') {
        errors.add('${item.original}：状态 $location，无法安全回滚');
        continue;
      }
      try {
        await _step(plan, item, item.temporary, item.original, 'rollback');
        names.remove(windowsNameKey(item.temporary));
        names[windowsNameKey(item.original)] = item.original;
        restored++;
      } catch (error) {
        errors.add('${item.original}：$error');
      }
    }
    if (errors.isEmpty) {
      try {
        await store.event(plan.id, 'rolledBack', null, reason);
        return RenameOutcome(
          restored == 0 ? 'notChanged' : 'rolledBack',
          restored == 0
              ? '核对后 ${plan.items.length} 张图片仍在原名，本次没有需要恢复的文件。\n原因：$reason'
              : '已恢复 $restored 张，另有 $alreadyOriginal 张原本就在原名。\n原因：$reason',
          restored,
          plan.items.length,
        );
      } catch (error) {
        errors.add('记录回滚结果失败：$error');
      }
    }
    return RenameOutcome(
      'manual',
      '$reason\n${errors.join('\n')}',
      restored,
      plan.items.length,
      issues: errors,
    );
  }

  Future<RenameOutcome> resume(
    RenamePlan plan, {
    RenameProgress? progress,
    bool Function()? cancelled,
    bool continueSafe = false,
  }) async {
    if (await store.isClosed(plan.id)) {
      return RenameOutcome(
        'manual',
        '事务已结案；保留原计划供查阅，不再按旧计划自动续做。',
        0,
        plan.items.length,
      );
    }
    late Map<String, String> names;
    try {
      names = await _names(plan.directory);
    } catch (error) {
      return RenameOutcome(
        'manual',
        '无法读取事务目录：${plan.directory}。请先恢复目录并重新核对。技术详情：$error',
        0,
        plan.items.length,
      );
    }
    final statuses = <RenameItemStatus>[];
    for (final item in plan.items) {
      statuses.add(await _inspectItem(plan, item, names));
    }
    if (statuses.every((status) => status.location == 'target')) {
      await store.event(plan.id, 'complete');
      return RenameOutcome(
        'completed',
        '核对后确认全部已完成',
        plan.items.length,
        plan.items.length,
      );
    }
    final hasOriginal = statuses.any((status) => status.location == 'original');
    final hasTarget = statuses.any((status) => status.location == 'target');
    if (hasOriginal && hasTarget) {
      final issues = <String>[
        for (final status in statuses)
          if (status.location == 'unknown')
            _formatIssue(status, status.problem ?? '文件位置不明'),
      ];
      return RenameOutcome(
        'manual',
        '同时存在原名与目标名，无法确定安全续做方向；请人工核对。'
            '${issues.isEmpty ? '' : '另发现 ${issues.length} 项位置异常。'}',
        0,
        plan.items.length,
        issues: issues,
      );
    }
    final lastKind = await store.lastEventKind(plan.id);
    final finishStage2 =
        hasTarget ||
        (lastKind != null &&
            (lastKind == 'stage2' || lastKind.endsWith(':stage2')));
    final problems = <String, String>{};
    var safeToChange = 0;
    for (final status in statuses) {
      String? problem;
      if (status.location == 'unknown') {
        problem = status.problem ?? '文件位置不明';
      } else if (status.location == 'temporary') {
        problem = status.conflicts[finishStage2 ? 'target' : 'original'];
        if (problem == null) safeToChange++;
      }
      if (problem != null) problems[status.item.original] = problem;
    }
    if (problems.isNotEmpty && !continueSafe) {
      return RenameOutcome(
        'manual',
        '发现 ${problems.length} 项异常；请逐项核对。可显式跳过异常项，仅处理其余安全项目。',
        0,
        plan.items.length,
        issues: [
          for (final status in statuses)
            if (problems.containsKey(status.item.original))
              _formatIssue(status, problems[status.item.original]!),
        ],
        canContinueSafe: safeToChange > 0,
      );
    }
    if (problems.isNotEmpty && safeToChange == 0) {
      return RenameOutcome(
        'manual',
        '仍有 ${problems.length} 项异常，没有可继续处理的项目。',
        0,
        plan.items.length,
        issues: [
          for (final status in statuses)
            if (problems.containsKey(status.item.original))
              _formatIssue(status, problems[status.item.original]!),
        ],
      );
    }
    if (!finishStage2) {
      return _rollback(plan, '第一阶段中断，尝试恢复原名', skipped: problems);
    }
    return _finishStage2(
      plan,
      progress: progress,
      cancelled: cancelled,
      skipped: problems,
    );
  }
}
