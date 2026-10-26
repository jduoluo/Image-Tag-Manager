import 'package:flutter/material.dart';

import '../infrastructure/android_media_probe.dart';
import '../infrastructure/android_rename_probe.dart';

final class AndroidRenameProbePage extends StatefulWidget {
  const AndroidRenameProbePage({super.key});
  @override
  State<AndroidRenameProbePage> createState() => _AndroidRenameProbePageState();
}

final class _AndroidRenameProbePageState extends State<AndroidRenameProbePage> {
  static const _probe = AndroidRenameProbe();
  final _target = TextEditingController();
  List<MediaImage> _images = const [];
  int? _id;
  String? _token;
  bool _accepted = false;
  bool _authorized = false;
  bool _busy = false;
  String _details = '请通过系统文件管理器把少量可丢弃图片副本放入专用测试相册。';

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _details = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _invalidate() {
    _token = null;
    _authorized = false;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('M4.3 测试副本改名验证')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '仅限 Android 11+ Debug 包；相册：${AndroidRenameProbe.album}\n'
            '每次只改一张、不递归，副本不超过 32 MiB。使用其他应用创建的副本，才能验证修改授权。'
            '该实验调用尚未证明具备不覆盖保证，可能出现系统自动换名；仅使用可丢弃副本。'
            '记录保存在应用私有空间，重启后可核对；卸载或清除应用数据会丢失记录。',
          ),
          CheckboxListTile(
            title: const Text('确认专用相册中的图片均为可丢弃测试副本'),
            value: _accepted,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _accepted = value ?? false;
                    _invalidate();
                  }),
          ),
          OutlinedButton(
            onPressed: _busy || !_accepted
                ? null
                : () => _run(() async {
                    final images = await const AndroidMediaProbe().listImages(
                      AndroidRenameProbe.album,
                    );
                    if (!mounted) return;
                    setState(() {
                      _images = images;
                      _id = null;
                      _invalidate();
                      _details = '读取 ${images.length} 张测试副本；请选择一张。';
                    });
                  }),
            child: const Text('读取测试相册'),
          ),
          for (final image in _images)
            ListTile(
              title: Text(image.name),
              leading: Icon(
                _id == image.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _id = image.id;
                      _target.text = '[m43]${image.name}';
                      _invalidate();
                    }),
            ),
          TextField(
            controller: _target,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: '本次测试目标文件名（含扩展名）'),
            onChanged: (_) => setState(_invalidate),
          ),
          OutlinedButton(
            onPressed: _busy || !_accepted || _id == null
                ? null
                : () => _run(() async {
                    _invalidate();
                    final plan = await _probe.prepare(_id!, _target.text);
                    if (mounted) {
                      setState(() {
                        _token = plan.token;
                        _details = plan.details;
                      });
                    }
                  }),
            child: const Text('预演并保存验证计划'),
          ),
          OutlinedButton(
            onPressed: _busy || _token == null
                ? null
                : () => _run(() async {
                    _authorized = false;
                    final authorized = await _probe.authorize(_token!);
                    if (mounted) {
                      setState(() {
                        _authorized = authorized;
                        _details = authorized
                            ? '系统已同意修改；仍需确认执行。'
                            : '系统授权已取消或拒绝，未执行改名。';
                      });
                    }
                  }),
            child: const Text('请求本张副本的系统修改授权'),
          ),
          FilledButton(
            onPressed: _busy || !_accepted || !_authorized || _token == null
                ? null
                : () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('确认实验改名'),
                        content: Text(
                          '仅修改专用测试相册中的一张副本，目标：${_target.text}。此调用的不覆盖与恢复能力尚未验证，结果需核对；不自动回滚。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('执行测试'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !mounted) return;
                    await _run(() async {
                      final token = _token!;
                      _invalidate();
                      final details = await _probe.execute(token);
                      if (mounted) setState(() => _details = details);
                    });
                  },
            child: const Text('确认后执行单张实验改名'),
          ),
          OutlinedButton(
            onPressed: _busy || !_accepted
                ? null
                : () => _run(() async {
                    final details = await _probe.inspect();
                    if (mounted) setState(() => _details = details);
                  }),
            child: const Text('核对验证记录（含重启后状态）'),
          ),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          SelectableText(_details),
        ],
      ),
    ),
  );
}
