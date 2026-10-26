import 'package:flutter/material.dart';

import '../infrastructure/guide_preferences.dart';
import 'usage_guide_page.dart';

/// Opens the guide before creating the browser (and before requesting media access).
final class GuideStartup extends StatefulWidget {
  const GuideStartup({
    required this.preferences,
    required this.assetPath,
    required this.browserBuilder,
    super.key,
  });
  final GuidePreferences preferences;
  final String assetPath;
  final WidgetBuilder browserBuilder;
  @override
  State<GuideStartup> createState() => _GuideStartupState();
}

final class _GuideStartupState extends State<GuideStartup> {
  bool? _showGuide;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var suppressed = false;
    try {
      suppressed = await widget.preferences.loadSuppressed();
    } catch (_) {
      /* Failed reads must not silently suppress onboarding. */
    }
    if (mounted) setState(() => _showGuide = !suppressed);
  }

  @override
  Widget build(BuildContext context) {
    if (_showGuide == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_showGuide!) return widget.browserBuilder(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _showGuide = false);
      },
      child: UsageGuidePage(
        assetPath: widget.assetPath,
        preferences: widget.preferences,
        onClose: () => setState(() => _showGuide = false),
      ),
    );
  }
}
