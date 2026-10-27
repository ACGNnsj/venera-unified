import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera_unified/foundation/app.dart';

/// Builds the body text of a foreground task notification. Pure, unit tested.
///
/// When a detail (e.g. `3/10`, an in-progress title) is present it is appended
/// to the title so the user can tell the background work is actually running.
String formatTaskStatus({required String title, String? detail}) {
  final d = detail?.trim() ?? '';
  return d.isEmpty ? title : '$title · $d';
}

/// Whether the shared sync keep-alive notification must stay up.
///
/// Sync operations can overlap — upload, download, image sync, and a queued
/// follow-up waiting on the current transfer — while sharing one
/// [BackgroundKeepAlive.tagSync] notification. Releasing on the first
/// completion would also drop the foreground service the others still rely on
/// to keep the process from being frozen. Only release once every flag is
/// clear (reference-count semantics). Pure, unit tested.
bool syncKeepAliveActive({
  required bool uploading,
  required bool downloading,
  required bool syncingImages,
  required bool waiting,
}) => uploading || downloading || syncingImages || waiting;

/// Generic background-task keep-alive: while follow-up checks, imports,
/// syncs or source updates run on Android, holds a native foreground service
/// with one independent progress notification per tag; removing the last tag
/// stops the service. No-ops on other platforms.
///
/// Task bodies keep running on the main isolate; this class only keeps the OS
/// from freezing the process, so it stays decoupled from task logic and
/// evolves independently. Coexists with the download-specific keep-alive
/// (`AndroidDownloads` + `DownloadService`); the two never touch each other.
class BackgroundKeepAlive {
  BackgroundKeepAlive._();

  static final BackgroundKeepAlive instance = BackgroundKeepAlive._();

  static const _channel = MethodChannel('venera/background_keepalive');

  /// Must match the tag constants in `BackgroundKeepAliveService`.
  static const tagFollowUpdate = 'follow_update';
  static const tagImport = 'import';
  static const tagSync = 'sync';
  static const tagSourceUpdate = 'source_update';

  bool get _supported => _debugSupported ?? App.isAndroid;

  /// Forces [_supported] in tests; the test VM is never Android.
  static bool? _debugSupported;

  /// Sets [_debugSupported]; call with null to restore platform behavior.
  @visibleForTesting
  static set debugSupported(bool? value) => _debugSupported = value;

  /// Clears cached statuses and the permission flag between tests.
  @visibleForTesting
  void debugReset() {
    _statuses.clear();
    _permissionAsked = false;
  }

  /// tag -> last status pushed to native. Dedupes repeats so identical
  /// updates don't round-trip the channel or refresh the notification.
  final _statuses = <String, String>{};
  bool _permissionAsked = false;

  /// Reports the latest status of a task kind. A no-op when the text is
  /// unchanged. Silently degrades when removed or unauthorized: the task runs
  /// on, only background protection is lost.
  void update(String tag, String status) {
    if (!_supported) return;
    if (_statuses[tag] == status) return;
    _statuses[tag] = status;
    unawaited(_pushUpdate(tag, status));
  }

  /// Drops a task kind's keep-alive notification. Call when the task ends,
  /// is cancelled or pauses.
  void remove(String tag) {
    if (!_supported) return;
    if (!_statuses.containsKey(tag)) return;
    _statuses.remove(tag);
    unawaited(_invoke('remove', {'tag': tag}));
  }

  Future<void> _pushUpdate(String tag, String status) async {
    if (!await _ensurePermission()) {
      // A foreground service needs its notification; without permission don't
      // spin — drop this keep-alive attempt.
      _statuses.remove(tag);
      return;
    }
    // The tag may have been removed while the permission dialog was up (the
    // task finished meanwhile). Recheck before pushing to avoid leaving a
    // resident notification with no task behind it.
    if (_statuses[tag] != status) return;
    final ok = await _invoke('update', {'tag': tag, 'status': status});
    if (ok != true) {
      // The system refused (e.g. background-start limits); clear the cached
      // text so the next update retries.
      _statuses.remove(tag);
    }
  }

  /// Ensures notification permission. Asks the system at most once per
  /// session; stays silent afterwards. Shares the native notification
  /// permission implementation with the download keep-alive (same permission,
  /// no conflict).
  Future<bool> _ensurePermission() async {
    if (await _invoke('notificationGranted') == true) return true;
    if (_permissionAsked) return false;
    _permissionAsked = true;
    return await _invoke('requestNotification') == true;
  }

  Future<Object?> _invoke(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
