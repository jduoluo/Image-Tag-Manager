import 'dart:io';

import 'package:flutter/material.dart';

import '../infrastructure/rename_transaction_store.dart';

String _localTime(DateTime value) {
  String two(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

final class ManualClosedHistoryDialog extends StatelessWidget {
  const ManualClosedHistoryDialog({required this.records, super.key});

  final List<ManuallyClosedRenameTransaction> records;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('人工结案记录'),
    content: SizedBox(
      width: 720,
      height: 460,
      child: ListView.builder(
        itemCount: records.length,
        itemBuilder: (context, index) {
          final record = records[index];
          final folder = Directory(record.plan.directory).uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last;
          return ListTile(
            title: Text(
              '${_localTime(record.closedAt)} · '
              '${record.abandoned ? '放弃处理' : '人工已处理'} · '
              '$folder · ${record.plan.items.length} 项',
            ),
            subtitle: Text(record.note.isEmpty ? record.plan.id : record.note),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => _ManualClosedDetailDialog(record: record),
            ),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

final class _ManualClosedDetailDialog extends StatelessWidget {
  const _ManualClosedDetailDialog({required this.record});

  final ManuallyClosedRenameTransaction record;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(record.abandoned ? '放弃处理的事务' : '人工已处理的事务'),
    content: SizedBox(
      width: 720,
      height: 460,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('时间：${_localTime(record.closedAt)}'),
          SelectableText('事务 ID：${record.plan.id}'),
          SelectableText('目录：${record.plan.directory}'),
          SelectableText('说明：${record.note.isEmpty ? '未填写' : record.note}'),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: record.plan.items.length,
              itemBuilder: (context, index) {
                final item = record.plan.items[index];
                return ListTile(
                  dense: true,
                  title: Text('${item.original} → ${item.target}'),
                  subtitle: Text('计划临时名：${item.temporary}'),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
