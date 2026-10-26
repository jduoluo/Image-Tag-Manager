import 'dart:convert';
import 'dart:io';

import '../domain/rename_plan.dart';

enum RenameRecordIssue { corruptPlan, missingPlan, missingEvents }

final class PendingRenameTransaction {
  const PendingRenameTransaction(
    this.path,
    this.plan,
    this.error, {
    this.recordIssue,
  });

  final String path;
  final RenamePlan? plan;
  final String? error;
  final RenameRecordIssue? recordIssue;
}

final class SuspectedMissingRenameRecord {
  const SuspectedMissingRenameRecord(this.id, this.filenames);

  /// Null when the visible name has the reserved prefix but no parseable ID.
  final String? id;
  final List<String> filenames;
}

final class ManuallyClosedRenameTransaction {
  const ManuallyClosedRenameTransaction(
    this.plan,
    this.abandoned,
    this.closedAt,
    this.note,
  );

  final RenamePlan plan;
  final bool abandoned;
  final DateTime closedAt;
  final String note;
}

/// Complete plans and per-step flushed events live in the configured local data directory.
final class RenameTransactionStore {
  RenameTransactionStore(this.directory);

  final Directory directory;

  File _planFile(String id) =>
      File('${directory.path}${Platform.pathSeparator}$id.json');
  File _eventsFile(String id) =>
      File('${directory.path}${Platform.pathSeparator}$id.events');

  static String _checksum(String data) {
    var value = 0xcbf29ce484222325;
    for (final byte in utf8.encode(data)) {
      value = ((value ^ byte) * 0x100000001b3) & 0xffffffffffffffff;
    }
    return value.toRadixString(16).padLeft(16, '0');
  }

  Future<void> savePlan(RenamePlan plan) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(plan.id)) {
      throw const FormatException('无效事务 ID');
    }
    await directory.create(recursive: true);
    final file = _planFile(plan.id);
    if (await file.exists()) throw StateError('事务 ID 已存在');
    final payload = jsonEncode(plan.toJson());
    await file.writeAsString(
      jsonEncode({'payload': plan.toJson(), 'checksum': _checksum(payload)}),
      flush: true,
    );
    await loadPlan(file.path);
  }

  Future<RenamePlan> loadPlan(String path) async {
    final envelope =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final payload = envelope['payload'] as Map<String, dynamic>;
    if (envelope['checksum'] != _checksum(jsonEncode(payload))) {
      throw const FormatException('事务计划校验失败');
    }
    final plan = RenamePlan.fromJson(payload);
    if (plan.items.isEmpty ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(plan.id) ||
        !File(path).uri.pathSegments.last.startsWith('${plan.id}.')) {
      throw const FormatException('事务计划字段无效');
    }
    if (!Directory(plan.directory).isAbsolute ||
        plan.directory.split(RegExp(r'[\\/]')).contains('..') ||
        plan.directory.contains('\u0000')) {
      throw const FormatException('事务目录无效');
    }
    final sources = <String>{};
    final targets = <String>{};
    final temporaries = <String>{};
    for (final item in plan.items) {
      if ([
            item.original,
            item.temporary,
            item.target,
          ].any((name) => validateWindowsFilename(name) != null) ||
          item.fileId.isEmpty ||
          windowsNameKey(item.original) == windowsNameKey(item.temporary) ||
          windowsNameKey(item.target) == windowsNameKey(item.temporary) ||
          !sources.add(windowsNameKey(item.original)) ||
          !targets.add(windowsNameKey(item.target)) ||
          !temporaries.add(windowsNameKey(item.temporary))) {
        throw const FormatException('事务名称或身份字段无效');
      }
    }
    if (temporaries.any(
      (name) => sources.contains(name) || targets.contains(name),
    )) {
      throw const FormatException('临时名与原名或目标名冲突');
    }
    return plan;
  }

  Future<void> event(
    String id,
    String kind, [
    String? original,
    String? detail,
  ]) async {
    final data = {
      'time': DateTime.now().toUtc().toIso8601String(),
      'kind': kind,
      'original': ?original,
      'detail': ?detail,
    };
    final encoded = jsonEncode(data);
    final file = _eventsFile(id);
    await file.writeAsString(
      '${jsonEncode({'data': data, 'checksum': _checksum(encoded)})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<Map<String, dynamic>?> _lastEventData(String id) async {
    final file = _eventsFile(id);
    if (!await file.exists()) return null;
    final lines = await file.readAsLines();
    for (final line in lines.reversed) {
      try {
        final envelope = jsonDecode(line) as Map<String, dynamic>;
        final data = envelope['data'] as Map<String, dynamic>;
        if (envelope['checksum'] != _checksum(jsonEncode(data))) return null;
        return data;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<String?> lastEventKind(String id) async =>
      (await _lastEventData(id))?['kind'] as String?;

  Future<String?> lastUncertainDetail(String id) async {
    final data = await _lastEventData(id);
    if (data != null && (data['kind'] as String).startsWith('uncertain:')) {
      return data['detail'] as String?;
    }
    return null;
  }

  Future<bool> isClosed(String id) async => {
    'complete',
    'rolledBack',
    'manualResolved',
    'manualAbandoned',
  }.contains(await lastEventKind(id));

  /// Records a user's decision without claiming that the original plan ran.
  Future<void> closeManually(
    RenamePlan plan, {
    required bool abandoned,
    String note = '',
  }) async {
    final current = await loadPlan(_planFile(plan.id).path);
    if (current.directory != plan.directory || await isClosed(plan.id)) {
      throw StateError('事务已变化或已结案，请重新打开核对');
    }
    await event(
      plan.id,
      abandoned ? 'manualAbandoned' : 'manualResolved',
      null,
      note.trim(),
    );
  }

  Future<List<PendingRenameTransaction>> pending() async {
    if (!await directory.exists()) return const [];
    final result = <PendingRenameTransaction>[];
    final plans = <String, File>{};
    final journals = <String, File>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final filename = entity.uri.pathSegments.last;
      if (filename.endsWith('.json')) {
        plans[filename.substring(0, filename.length - 5)] = entity;
      } else if (filename.endsWith('.events')) {
        journals[filename.substring(0, filename.length - 7)] = entity;
      }
    }
    for (final entry in plans.entries) {
      final file = entry.value;
      try {
        final plan = await loadPlan(file.path);
        if (!journals.containsKey(entry.key)) {
          result.add(
            PendingRenameTransaction(
              file.path,
              plan,
              '事件日志缺失或尚未生成：${_eventsFile(plan.id).path}。'
              '现存计划：${file.path}。请保留现场并核对后再处理。',
              recordIssue: RenameRecordIssue.missingEvents,
            ),
          );
        } else if (!await isClosed(plan.id)) {
          result.add(PendingRenameTransaction(file.path, plan, null));
        }
      } catch (error) {
        result.add(
          PendingRenameTransaction(
            file.path,
            null,
            '计划记录无法解析：$error。请保留现存文件：${file.path}。',
            recordIssue: RenameRecordIssue.corruptPlan,
          ),
        );
      }
    }
    for (final entry in journals.entries) {
      if (plans.containsKey(entry.key)) continue;
      result.add(
        PendingRenameTransaction(
          entry.value.path,
          null,
          '计划文件缺失：${_planFile(entry.key).path}。'
          '现存事件日志：${entry.value.path}。无法从日志单独重建批次；'
          '请保留现场并核查备份。',
          recordIssue: RenameRecordIssue.missingPlan,
        ),
      );
    }
    result.sort((a, b) => b.path.compareTo(a.path));
    return result;
  }

  /// Only a visible temporary filename can hint at a batch with both files gone.
  Future<List<SuspectedMissingRenameRecord>> suspectedMissingRecords(
    Iterable<String> filenames,
  ) async {
    final pattern = RegExp(
      r'^~(itm-\d{17,20}-[0-9a-f]{8})-\d{4,}\.[^.]+$',
      caseSensitive: false,
    );
    final grouped = <String?, List<String>>{};
    for (final name in filenames) {
      if (!name.toLowerCase().startsWith('~itm-')) continue;
      final id = pattern.firstMatch(name)?.group(1);
      grouped.putIfAbsent(id, () => []).add(name);
    }
    final result = <SuspectedMissingRenameRecord>[];
    for (final entry in grouped.entries) {
      final id = entry.key;
      if (id != null &&
          (await _planFile(id).exists() || await _eventsFile(id).exists())) {
        continue;
      }
      result.add(SuspectedMissingRenameRecord(id, entry.value));
    }
    result.sort((a, b) => b.filenames.length.compareTo(a.filenames.length));
    return result;
  }

  Future<List<RenamePlan>> completed() async {
    if (!await directory.exists()) return const [];
    final result = <RenamePlan>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final plan = await loadPlan(entity.path);
        if (await lastEventKind(plan.id) == 'complete') result.add(plan);
      } catch (_) {
        // A corrupt record is surfaced in pending(), never treated as complete.
      }
    }
    result.sort((a, b) => b.id.compareTo(a.id));
    return result;
  }

  Future<List<ManuallyClosedRenameTransaction>> manuallyClosed() async {
    if (!await directory.exists()) return const [];
    final result = <ManuallyClosedRenameTransaction>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final plan = await loadPlan(entity.path);
        final event = await _lastEventData(plan.id);
        final kind = event?['kind'];
        if (kind != 'manualResolved' && kind != 'manualAbandoned') continue;
        final closedAt = DateTime.parse(event!['time'] as String).toLocal();
        result.add(
          ManuallyClosedRenameTransaction(
            plan,
            kind == 'manualAbandoned',
            closedAt,
            event['detail'] as String? ?? '',
          ),
        );
      } catch (_) {
        // Broken records remain visible through pending() for manual review.
      }
    }
    result.sort((a, b) => b.closedAt.compareTo(a.closedAt));
    return result;
  }

  /// Deletes only complete records. Rechecks every selected record before writing.
  Future<void> deleteCompleted(Iterable<String> ids) async {
    final uniqueIds = ids.toSet();
    for (final id in uniqueIds) {
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
        throw StateError('事务 ID 无效');
      }
      final plan = await loadPlan(_planFile(id).path);
      if (plan.id != id || await lastEventKind(id) != 'complete') {
        throw StateError('记录已变化或并非已完成事务：$id');
      }
    }
    for (final id in uniqueIds) {
      // Keep the plan until last so a failed journal deletion stays visible.
      await _eventsFile(id).delete();
      await _planFile(id).delete();
    }
  }
}
