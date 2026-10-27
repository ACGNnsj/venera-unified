import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:venera_unified/foundation/app.dart';

/// Native side of in-app updates (Android only).
///
/// Ported from venera-prime's `AndroidAppUpdater`. The MethodChannel name is
/// shared with the existing unified channel; the native methods
/// (`getSupportedAbis`/`validateUpdate`/`installUpdate`) are added to
/// unified's `MainActivity`.
class AndroidAppInstaller {
  static const _channel = MethodChannel('venera/method_channel');

  static Future<List<String>> supportedAbis() async =>
      await _channel.invokeListMethod<String>('getSupportedAbis') ?? const [];

  static Future<void> validate(File apk) =>
      _channel.invokeMethod<void>('validateUpdate', {'path': apk.path});

  /// Native code validates package identity, version and signing certificate,
  /// requests install permission if needed, then launches the system
  /// installer. Returns false when the user declines the install permission.
  static Future<bool> install(File apk) async =>
      await _channel.invokeMethod<bool>('installUpdate', {'path': apk.path}) ??
      false;

  /// Private updater cache. The native side resolves the same location as
  /// `<cacheDir>/updates` and refuses to install anything outside it.
  static Directory get downloadDirectory =>
      Directory(p.join(App.cachePath, 'updates'));
}
