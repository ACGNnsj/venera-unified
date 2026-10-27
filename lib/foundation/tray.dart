import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:window_manager/window_manager.dart';

/// System tray controller (Windows only).
///
/// When "minimize to tray" is on: keeps a resident tray icon, and close
/// requests (title-bar button, Alt+F4, taskbar) hide the window into the tray
/// instead of exiting. Restore from the tray menu or a left click; quit
/// explicitly from the menu. Turning the setting off removes the tray and
/// restores normal closing. Every method is a no-op on other platforms.
///
/// Close interception deliberately does NOT add a second `WindowListener`.
/// unified already runs with `preventClose` and funnels every close path
/// through `WindowFrame._onClose` (guards, exit tasks, finalize, then exit).
/// A parallel `onWindowClose => hide` listener would race that pipeline and
/// the app would still exit. Instead the shell registers a close guard via
/// `WindowFrameController.addCloseListener` that hides to the tray and vetoes
/// the close; quitting unregisters the guard first and goes through the same
/// full pipeline, so no exit task is ever skipped.
class TrayController with TrayListener {
  TrayController._();

  static final TrayController instance = TrayController._();

  static const _menuShow = 'show';
  static const _menuQuit = 'quit';

  static const _iconAsset = 'assets/tray_icon.ico';

  bool get isSupported => App.isWindows;

  /// Set by the shell binding. Must unregister the close guard, then request
  /// a normal close so exit tasks and finalization still run.
  Future<void> Function()? onQuitRequest;

  bool _enabled = false;
  bool _wired = false;

  bool get isEnabled => _enabled;

  /// Call once from the shell binding. Safe to call repeatedly.
  Future<void> init() async {
    if (!isSupported) return;
    _wire();
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    trayManager.addListener(this);
  }

  /// Applies the setting. Enabling builds tray icon/menu; the caller
  /// registers the close guard only after this completes, so the window can
  /// never hide before its tray icon exists.
  Future<void> setEnabled(bool enabled) async {
    if (!isSupported || enabled == _enabled) return;
    _wire();
    if (enabled) {
      await trayManager.setIcon(_iconAsset);
      await trayManager.setToolTip('Venera Unified');
      await trayManager.setContextMenu(_buildMenu());
      _enabled = true;
    } else {
      _enabled = false;
      await trayManager.destroy();
      await windowManager.show();
    }
  }

  /// Hides the window into the tray. Only called through the close guard,
  /// which only exists while the tray is enabled and ready.
  Future<void> hideToTray() async {
    if (!isSupported || !_enabled) return;
    await windowManager.hide();
  }

  Future<void> restoreWindow() async {
    if (!isSupported) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Menu _buildMenu() => Menu(
    items: [
      MenuItem(key: _menuShow, label: 'Show'.tl),
      MenuItem.separator(),
      MenuItem(key: _menuQuit, label: 'Exit'.tl),
    ],
  );

  @override
  void onTrayIconMouseDown() {
    unawaited(restoreWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _menuShow:
        unawaited(restoreWindow());
      case _menuQuit:
        final quit = onQuitRequest;
        if (quit != null) unawaited(quit());
    }
  }

  @visibleForTesting
  void debugReset() {
    _enabled = false;
    _wired = false;
    onQuitRequest = null;
  }
}
