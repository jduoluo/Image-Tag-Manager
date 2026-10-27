import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../infrastructure/app_information.dart';

Future<void> openAppAbout(BuildContext context) => Navigator.push<void>(
  context,
  MaterialPageRoute<void>(builder: (_) => const AppAboutPage()),
);

final class AppAboutMenuButton extends StatelessWidget {
  const AppAboutMenuButton({super.key});

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '更多',
    onSelected: (_) => openAppAbout(context),
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'about', child: Text('关于图签')),
    ],
  );
}

final class AppAboutPage extends StatefulWidget {
  const AppAboutPage({super.key});

  @override
  State<AppAboutPage> createState() => _AppAboutPageState();
}

final class _AppAboutPageState extends State<AppAboutPage> {
  late final Future<String> _version = AppInformation.version();

  void _message(String text) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open(String url) async {
    try {
      await AppInformation.openUrl(url);
    } catch (_) {
      _message('无法打开浏览器，请复制地址后手动访问。');
    }
  }

  Future<void> _copy(String url) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      _message('地址已复制');
    } catch (_) {
      _message('复制失败，可长按地址选择复制。');
    }
  }

  Widget _link(String title, String url) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        SelectableText(url),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => _open(url),
              icon: const Icon(Icons.open_in_new),
              label: Text('打开$title'),
            ),
            TextButton.icon(
              onPressed: () => _copy(url),
              icon: const Icon(Icons.copy),
              label: Text('复制$title地址'),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('关于图签')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: Image.asset('assets/app_icon.png', width: 80, height: 80),
            ),
            const SizedBox(height: 12),
            Text('图签', style: Theme.of(context).textTheme.headlineMedium),
            const Text('Image Tag Manager'),
            FutureBuilder<String>(
              future: _version,
              builder: (_, snapshot) => Text(
                snapshot.hasError
                    ? '版本信息读取失败'
                    : '版本：${snapshot.data ?? '正在读取…'}',
              ),
            ),
            const Text('开发者：多落孑（jduoluo）'),
            const Text('Copyright © 2026 jduoluo'),
            const SizedBox(height: 12),
            const Text('本地图片打标与组合筛选工具。'),
            _link('项目主页', AppInformation.repository),
            _link('问题反馈', AppInformation.issues),
            const Divider(),
            const Text('图签代码采用 GPL-3.0-only（仅第三版）。'),
            const Text(
              '允许使用、修改及商业分发；分发受 GPL 覆盖的版本时，须遵守相应的许可与源码提供要求。本程序不提供任何担保。',
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const _LicenseTextPage(),
                ),
              ),
              child: const Text('查看 GPL-3.0 完整许可'),
            ),
            FutureBuilder<String>(
              future: _version,
              builder: (_, snapshot) => OutlinedButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: '图签 · Image Tag Manager',
                  applicationVersion: snapshot.data,
                  applicationLegalese: 'Copyright © 2026 jduoluo\n第三方组件保留各自许可。',
                ),
                child: const Text('第三方开源许可'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

final class _LicenseTextPage extends StatefulWidget {
  const _LicenseTextPage();

  @override
  State<_LicenseTextPage> createState() => _LicenseTextPageState();
}

final class _LicenseTextPageState extends State<_LicenseTextPage> {
  Future<String>? _license;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _license ??= DefaultAssetBundle.of(context).loadString('LICENSE');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('GPL-3.0-only')),
    body: FutureBuilder<String>(
      future: _license,
      builder: (_, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() {
                _license = DefaultAssetBundle.of(context).loadString('LICENSE');
              }),
              child: const Text('许可加载失败，点击重试'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: SelectableText(snapshot.data!),
        );
      },
    ),
  );
}
