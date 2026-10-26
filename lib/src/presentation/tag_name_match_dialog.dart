import 'package:flutter/material.dart';

import '../domain/tag_groups.dart';

final class TagNameMatchDecision {
  const TagNameMatchDecision.use(this.group) : createNew = false;
  const TagNameMatchDecision.create() : group = null, createNew = true;

  final TagGroup? group;
  final bool createNew;
}

/// A display name is not an alias. Ask before creating another group with it.
Future<TagNameMatchDecision?> resolveTagDisplayName(
  BuildContext context,
  String input,
  Iterable<TagGroup> groups,
) {
  final matches = groups.where((group) => group.displayName == input).toList();
  if (matches.isEmpty) {
    return Future.value(const TagNameMatchDecision.create());
  }
  return showDialog<TagNameMatchDecision>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('发现同名标签名组'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已有显示名为“$input”的标签名组，但输入值不在它的写入值或别名中：'),
              const SizedBox(height: 8),
              for (final group in matches)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('默认写入标签：${group.writeTag}'),
                        Text('可识别写法（含默认写入）：${group.aliases.join('、')}'),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.pop(
                              context,
                              TagNameMatchDecision.use(group),
                            ),
                            child: const Text('使用此组'),
                          ),
                        ),
                      ],
                    ),
                  ),
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
          onPressed: () =>
              Navigator.pop(context, const TagNameMatchDecision.create()),
          child: const Text('仍新建独立标签'),
        ),
      ],
    ),
  );
}
