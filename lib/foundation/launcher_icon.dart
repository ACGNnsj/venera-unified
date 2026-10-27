import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/log.dart';

/// Launcher / app icon presets the user can switch between. This is the
/// OS-level app icon, not the in-app logo.
///
/// Ported from VeneraX (`lib/foundation/launcher_icon.dart`) with unified's
/// own brand art: five colorways of the unified "V" mark (blue default,
/// purple, green, orange, silver). Never reuse VeneraX art here — that would
/// change the app identity.
///
/// Runtime behaviour differs by platform:
/// - **iOS / Android** swap the real home-screen launcher icon.
/// - **Windows** swaps only the *live* window/taskbar-button icon (and the tray
///   icon) via `WM_SETICON`; the .exe's embedded icon — shown in Explorer, on a
///   pinned taskbar shortcut and in the Start menu — is fixed at build time and
///   cannot change at runtime. WM_SETICON does not persist across restarts, so
///   [LauncherIconService.applyForStartup] re-applies the stored choice once
///   the window is ready.
/// - Other desktops (Linux/macOS) have no runtime path, so the settings entry
///   stays hidden there (see [LauncherIconService.isSupported]).
///
/// Native contract (phase 2 wires the handlers; the channel already exists on
/// both mobile platforms): methods `setLauncherIcon` (`{'alias': String?}`)
/// and `supportsAlternateIcons` on `venera/method_channel`.
enum LauncherIconPreset {
  /// Primary blue "V" — the app's main icon (baked into the bundle).
  defaultIcon('default'),

  /// Purple colorway.
  purple('purple'),

  /// Green colorway.
  green('green'),

  /// Orange colorway.
  orange('orange'),

  /// Silver / monochrome colorway.
  silver('silver');

  const LauncherIconPreset(this.id);

  /// Stable id stored in settings (`appLauncherIcon`).
  final String id;

  static LauncherIconPreset fromId(String? id) {
    return LauncherIconPreset.values.firstWhere(
      (e) => e.id == id,
      orElse: () => LauncherIconPreset.defaultIcon,
    );
  }

  /// Android activity-alias short name this preset maps to. The native side
  /// resolves it against the application package, so the bare alias suffices.
  ///
  /// Public (unlike upstream) so the phase-2 Manifest contract is pinned by
  /// unit tests instead of living only in a comment.
  String get androidAlias => switch (this) {
    LauncherIconPreset.defaultIcon => 'IconDefault',
    LauncherIconPreset.purple => 'IconPurple',
    LauncherIconPreset.green => 'IconGreen',
    LauncherIconPreset.orange => 'IconOrange',
    LauncherIconPreset.silver => 'IconSilver',
  };

  /// iOS alternate-icon key (from `CFBundleAlternateIcons` in Info.plist).
  ///
  /// Null means the primary icon: iOS restores it via a null iconName, so the
  /// default preset carries no alternate key. Public for the same reason as
  /// [androidAlias].
  String? get iosIconName {
    return switch (this) {
      LauncherIconPreset.defaultIcon => null,
      LauncherIconPreset.purple => 'IconPurple',
      LauncherIconPreset.green => 'IconGreen',
      LauncherIconPreset.orange => 'IconOrange',
      LauncherIconPreset.silver => 'IconSilver',
    };
  }

  /// In-app logo asset matching this preset. Phase 2 wires the sidebar header
  /// and the About page to this so the in-app branding follows the chosen
  /// launcher icon; until then only the settings previews use these files.
  String get inAppLogoAsset => switch (this) {
    LauncherIconPreset.defaultIcon => 'assets/launcher_icon_default.png',
    LauncherIconPreset.purple => 'assets/launcher_icon_purple.png',
    LauncherIconPreset.green => 'assets/launcher_icon_green.png',
    LauncherIconPreset.orange => 'assets/launcher_icon_orange.png',
    LauncherIconPreset.silver => 'assets/launcher_icon_silver.png',
  };

  /// Bundled multi-resolution `.ico` this preset maps to for the Windows
  /// window/taskbar/tray icon. Paths are relative to `assets/` because both
  /// `window_manager.setIcon` and `tray_manager.setIcon` resolve against the
  /// bundle's `data/flutter_assets/` directory. Generated from the matching
  /// PNGs by `tool/gen_launcher_icos.dart`.
  String get windowsIcoAsset => switch (this) {
    LauncherIconPreset.defaultIcon => 'assets/launcher_icon_default.ico',
    LauncherIconPreset.purple => 'assets/launcher_icon_purple.ico',
    LauncherIconPreset.green => 'assets/launcher_icon_green.ico',
    LauncherIconPreset.orange => 'assets/launcher_icon_orange.ico',
    LauncherIconPreset.silver => 'assets/launcher_icon_silver.ico',
  };
}

abstract final class LauncherIconService {
  static const _channel = MethodChannel('venera/method_channel');

  /// Whether this platform can switch app icons at runtime. Windows swaps only
  /// the live window/taskbar/tray icon (not the .exe's embedded icon); iOS and
  /// Android swap the real home-screen launcher icon.
  static bool get isSupported => App.isAndroid || App.isIOS || App.isWindows;

  /// Whether this platform can only swap the *live* window icon, leaving the
  /// installed/pinned icon unchanged. Drives the extra caveat in the settings
  /// copy so Windows users know the Explorer/Start-menu icon won't follow.
  static bool get isWindowIconOnly => App.isWindows;

  /// The preset currently stored in settings.
  static LauncherIconPreset get current =>
      LauncherIconPreset.fromId(appdata.settings['appLauncherIcon'] as String?);

  /// Hook the tray controller registers so its icon follows the chosen preset.
  /// Left null on non-Windows / before the tray is wired.
  static Future<void> Function(String icoAsset)? onWindowsIconChanged;

  /// Apply [preset] as the app icon and persist the choice.
  ///
  /// Returns true on success. Each platform takes a different path:
  ///
  /// - **Android** switches the enabled `activity-alias` immediately via the
  ///   shared native channel (`DONT_KILL_APP`). All aliases target the same
  ///   MainActivity, so an in-place switch is safe and effective at once.
  /// - **iOS** calls `setAlternateIconName` over the same native channel,
  ///   matching an Info.plist `CFBundleAlternateIcons` key (null = primary);
  ///   the system shows its own "icon changed" alert.
  /// - **Windows** pushes the preset's bundled `.ico` to the live window via
  ///   `window_manager.setIcon` (WM_SETICON) and to the tray, if wired. This
  ///   does not touch the .exe's embedded icon and does not persist across
  ///   restarts — [applyForStartup] re-applies the stored choice on launch.
  ///
  /// Until phase 2 wires the native handlers, the mobile paths fail gracefully
  /// (caught below → false) and the settings page reports "not supported".
  static Future<bool> apply(LauncherIconPreset preset) async {
    if (!isSupported) return false;

    try {
      if (App.isAndroid) {
        final ok = await _channel.invokeMethod<bool>('setLauncherIcon', {
          'alias': preset.androidAlias,
        });
        if (ok != true) {
          Log.warning('LauncherIcon', 'Native icon switch returned $ok');
          return false;
        }
      } else if (App.isWindows) {
        await windowManager.setIcon(preset.windowsIcoAsset);
        // Keep the tray icon (if the tray is active) in step with the window.
        await onWindowsIconChanged?.call(preset.windowsIcoAsset);
      } else {
        if (await _channel.invokeMethod<bool>('supportsAlternateIcons') !=
            true) {
          Log.warning(
            'LauncherIcon',
            'Alternate icons not supported on device',
          );
          return false;
        }
        final ok = await _channel.invokeMethod<bool>(
          'setLauncherIcon',
          // Null alias restores the primary icon.
          {'alias': preset.iosIconName},
        );
        if (ok != true) {
          Log.warning('LauncherIcon', 'Native icon switch returned $ok');
          return false;
        }
      }

      await appdata.updateSettings(
        (settings) => settings['appLauncherIcon'] = preset.id,
      );
      return true;
    } catch (e, s) {
      Log.error('LauncherIcon', 'Failed to set launcher icon: $e', s);
      return false;
    }
  }

  /// Re-apply the stored preset's icon to the live Windows window on startup.
  ///
  /// WM_SETICON is per-process and lost on exit, so without this the window
  /// would revert to the built-in icon each launch. No-op unless the stored
  /// preset actually differs from the built-in default, and only on Windows.
  static Future<void> applyForStartup() async {
    if (!App.isWindows) return;
    final preset = current;
    if (preset == LauncherIconPreset.defaultIcon) return;
    try {
      await windowManager.setIcon(preset.windowsIcoAsset);
    } catch (e, s) {
      Log.error('LauncherIcon', 'Failed to apply startup icon: $e', s);
    }
  }
}
