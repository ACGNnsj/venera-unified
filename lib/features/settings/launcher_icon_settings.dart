import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/launcher_icon.dart';
import 'package:venera_unified/foundation/translations.dart';

/// Lets the user switch the OS-level launcher icon between built-in presets.
///
/// Ported from VeneraX's `LauncherIconSettings`. Until phase 2 wires the
/// native handlers, applying a preset fails gracefully (toast + no persist).
class LauncherIconSettings extends StatefulWidget {
  const LauncherIconSettings({super.key});

  @override
  State<LauncherIconSettings> createState() => _LauncherIconSettingsState();
}

class _LauncherIconSettingsState extends State<LauncherIconSettings> {
  late LauncherIconPreset selected = LauncherIconService.current;
  bool applying = false;

  String _label(LauncherIconPreset preset) => switch (preset) {
    LauncherIconPreset.defaultIcon => "Default".tl,
    LauncherIconPreset.purple => "Purple".tl,
    LauncherIconPreset.green => "Green".tl,
    LauncherIconPreset.orange => "Orange".tl,
    LauncherIconPreset.silver => "Silver".tl,
  };

  /// Placeholder chip color while the preview asset is missing (phase 1 ships
  /// before the assets are registered in pubspec, so Image.asset falls back
  /// here via errorBuilder instead of painting red).
  Color _placeholderColor(LauncherIconPreset preset) => switch (preset) {
    LauncherIconPreset.defaultIcon => Colors.blue,
    LauncherIconPreset.purple => Colors.purple,
    LauncherIconPreset.green => Colors.green,
    LauncherIconPreset.orange => Colors.orange,
    LauncherIconPreset.silver => Colors.grey,
  };

  Future<void> _select(LauncherIconPreset preset) async {
    if (applying || preset == selected) return;
    setState(() => applying = true);
    var ok = await LauncherIconService.apply(preset);
    if (!mounted) return;
    setState(() {
      applying = false;
      if (ok) selected = preset;
    });
    if (!ok) {
      context.showMessage(message: "This device does not support this".tl);
      return;
    }
    // Phase 2 wires the in-app logo (sidebar / About) to the chosen preset;
    // then this needs an appNavigation.forceRebuild() like upstream.
    context.showMessage(
      message: App.isIOS ? "Icon changed".tl : "Icon updated".tl,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("App Icon".tl)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              LauncherIconService.isWindowIconOnly
                  ? "Changes the window and taskbar icon while the app is running. The pinned and Start menu icon stays the same."
                        .tl
                  : "Change the icon shown on your home screen.".tl,
              style: TextStyle(
                fontSize: 12,
                color: context.colorScheme.outline,
              ),
            ),
          ),
          ...LauncherIconPreset.values.map(_buildTile),
        ],
      ),
    );
  }

  Widget _buildTile(LauncherIconPreset preset) {
    var isSelected = preset == selected;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(
          color: isSelected
              ? context.colorScheme.primary
              : context.colorScheme.outlineVariant,
          width: isSelected ? 1.6 : 0.6,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: applying ? null : () => _select(preset),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  preset.inAppLogoAsset,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    width: 56,
                    height: 56,
                    color: _placeholderColor(preset),
                    child: const Icon(Icons.apps, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  _label(preset),
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: context.colorScheme.primary)
              else
                Icon(
                  Icons.circle_outlined,
                  color: context.colorScheme.outlineVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
