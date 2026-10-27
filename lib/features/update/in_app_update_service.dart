import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/release_version.dart';
import 'package:venera_unified/network/app_dio.dart'
    show Dio, CancelToken, Options, ProgressCallback, RHttpAdapter;

import 'android_app_installer.dart';
import 'in_app_update.dart';

/// Downloads a release [asset] into [directory] as `<name>.part`, verifies
/// size and digest, then renames it to the final name.
///
/// Ported from venera-prime's `AppUpdateDownloader.download`.
typedef UpdateDownloader =
    Future<File> Function({
      required UpdateAsset asset,
      required Directory directory,
      required CancelToken cancelToken,
      ProgressCallback? onProgress,
    });

Future<File> downloadUpdateAsset({
  required Dio dio,
  required UpdateAsset asset,
  required Directory directory,
  required CancelToken cancelToken,
  ProgressCallback? onProgress,
}) async {
  await directory.create(recursive: true);
  if (asset.size <= 0) {
    throw const FormatException('Invalid update filesize');
  }
  // Only a basename from a release may be used inside the updater cache.
  final target = updateTargetFile(directory, asset.name);
  final partial = File('${target.path}.part');
  try {
    await dio.download(
      asset.url,
      partial.path,
      cancelToken: cancelToken,
      onReceiveProgress: onProgress,
      options: Options(receiveTimeout: const Duration(minutes: 2)),
    );
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final actualSize = await partial.length();
    if (actualSize != asset.size) {
      throw FormatException(
        'Update download is incomplete '
        '(expected ${asset.size} bytes, received $actualSize bytes)',
      );
    }
    if (asset.digest != null && asset.digest!.isNotEmpty) {
      final expected = asset.digest!;
      if (!RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(expected)) {
        throw const FormatException('Unsupported update checksum');
      }
      final actual = await verifyDownloadedUpdate(
        partial,
        size: asset.size,
        digest: expected,
      );
      if (actual != expected.substring(7).toLowerCase()) {
        throw const FormatException('Update checksum mismatch');
      }
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    if (await target.exists()) await target.delete();
    return await partial.rename(target.path);
  } finally {
    if (await partial.exists()) await partial.delete();
  }
}

/// Creates a download client equivalent to the update metadata client
/// ([createApplicationUpdates]): plain Dio over the rhttp adapter.
Dio newUpdateDownloadClient() => Dio()..httpClientAdapter = RHttpAdapter();

enum InAppUpdateStatus {
  idle,
  downloading,
  verifying,
  ready,
  installing,
  failed,
  cancelled,
}

@immutable
class InAppUpdateState {
  const InAppUpdateState({
    this.status = InAppUpdateStatus.idle,
    this.version,
    this.assetName,
    this.received = 0,
    this.total = 0,
    this.error,
  });

  final InAppUpdateStatus status;
  final String? version;
  final String? assetName;
  final int received;
  final int total;
  final Object? error;

  double get progress => total > 0 ? (received / total).clamp(0, 1) : 0;

  InAppUpdateState copyWith({
    InAppUpdateStatus? status,
    String? version,
    String? assetName,
    int? received,
    int? total,
    Object? error,
  }) => InAppUpdateState(
    status: status ?? this.status,
    version: version ?? this.version,
    assetName: assetName ?? this.assetName,
    received: received ?? this.received,
    total: total ?? this.total,
    error: error,
  );
}

/// Owns one in-app update download independently of any dialog.
///
/// Ported from venera-prime's `AppUpdateService`, minus the background-task
/// center (unified has none): progress is reported through [state] for the
/// dialog to render, and cancelling/disposing the dialog cancels the
/// download. A verified APK is still cached in `ready.json`, so reopening
/// the update dialog offers Install without re-downloading.
class InAppUpdateService {
  InAppUpdateService({
    UpdateDownloader? downloader,
    Future<void> Function(File)? validate,
    Future<bool> Function(File)? installer,
    String Function()? currentVersion,
    Directory Function()? downloadDirectory,
    DateTime Function()? now,
  }) : _downloader =
           downloader ??
           (({
             required asset,
             required directory,
             required cancelToken,
             onProgress,
           }) => downloadUpdateAsset(
             dio: newUpdateDownloadClient(),
             asset: asset,
             directory: directory,
             cancelToken: cancelToken,
             onProgress: onProgress,
           )),
       _validate = validate ?? AndroidAppInstaller.validate,
       _installer = installer ?? AndroidAppInstaller.install,
       _currentVersion = currentVersion ?? (() => App.version),
       _directory =
           downloadDirectory ?? (() => AndroidAppInstaller.downloadDirectory),
       _now = now ?? DateTime.now;

  final UpdateDownloader _downloader;
  final Future<void> Function(File) _validate;
  final Future<bool> Function(File) _installer;
  final String Function() _currentVersion;
  final Directory Function() _directory;
  final DateTime Function() _now;

  final ValueNotifier<InAppUpdateState> state = ValueNotifier(
    const InAppUpdateState(),
  );

  Future<void> _preparation = Future<void>.value();
  bool _restored = false;
  bool _busy = false;
  bool _disposed = false;
  CancelToken? _token;
  _ReadyUpdate? _ready;

  void _emit(InAppUpdateState next) {
    if (!_disposed) state.value = next;
  }

  // Serialize restoration and starts, but never hold this queue for a download.
  Future<T> _prepare<T>(Future<T> Function() action) {
    final result = _preparation.then((_) => action());
    _preparation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> restore() => _prepare(_restore);

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    File? metadata;
    Directory? directory;
    try {
      directory = _directory();
      metadata = File(p.join(directory.path, 'ready.json'));
      if (!await metadata.exists()) return;
      final data = jsonDecode(await metadata.readAsString()) as Map;
      final asset = UpdateAsset.fromJson(data['asset'] as Map);
      final version = data['version'];
      final digest = data['sha256'];
      if (asset == null ||
          version is! String ||
          digest is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
          !shouldNotifyRelease(version, _currentVersion())) {
        throw const FormatException('Invalid or obsolete cached update');
      }
      final file = updateTargetFile(directory, asset.name);
      await verifyDownloadedUpdate(
        file,
        size: asset.size,
        expectedSha256: digest,
      );
      await _validate(file);
      _ready = _ReadyUpdate(version, asset, file, digest);
      _emit(
        InAppUpdateState(
          status: InAppUpdateStatus.ready,
          version: version,
          assetName: asset.name,
          received: asset.size,
          total: asset.size,
        ),
      );
    } catch (_) {
      // Cache restoration must never offer an invalid APK.
      await _delete(metadata);
    } finally {
      if (directory != null) await _cleanCache(directory, keep: _ready?.file);
    }
  }

  /// Starts downloading [asset] for [version]. A verified cached APK for the
  /// same release is reused without re-downloading.
  Future<void> startDownload({
    required String version,
    required UpdateAsset asset,
  }) => _prepare(() async {
    await _restore();
    if (_busy || _disposed) return;
    final ready = _ready;
    if (ready != null &&
        ready.version == version &&
        ready.asset.name == asset.name &&
        ready.asset.url == asset.url &&
        ready.asset.size == asset.size &&
        ready.asset.digest == asset.digest) {
      try {
        // The OS may evict cache files at any time. Never offer a remembered
        // installation action for a missing/corrupt APK.
        await verifyDownloadedUpdate(
          ready.file,
          size: ready.asset.size,
          expectedSha256: ready.digest,
        );
        _emit(
          InAppUpdateState(
            status: InAppUpdateStatus.ready,
            version: ready.version,
            assetName: ready.asset.name,
            received: ready.asset.size,
            total: ready.asset.size,
          ),
        );
        return;
      } catch (_) {
        // A new explicit download request repairs unusable cached content.
      }
    }
    if (ready != null) await _discardReady(ready);
    _ready = null;
    if (!shouldNotifyRelease(version, _currentVersion())) {
      throw const FormatException('Update version is not newer');
    }
    final token = CancelToken();
    _token = token;
    _busy = true;
    _emit(
      InAppUpdateState(
        status: InAppUpdateStatus.downloading,
        version: version,
        assetName: asset.name,
        total: asset.size,
      ),
    );
    unawaited(_download(version, asset, token));
  });

  Future<void> _download(
    String version,
    UpdateAsset asset,
    CancelToken token,
  ) async {
    File? target;
    File? metadata;
    var lastProgress = _now();
    try {
      final directory = _directory();
      target = updateTargetFile(directory, asset.name);
      metadata = File(p.join(directory.path, 'ready.json'));
      await _delete(metadata);
      if (!shouldNotifyRelease(version, _currentVersion())) {
        throw const FormatException('Update version is not newer');
      }
      if (token.isCancelled) throw token.cancelError!;
      final file = await _downloader(
        asset: asset,
        directory: directory,
        cancelToken: token,
        onProgress: (received, _) {
          if (token.isCancelled || _disposed) return;
          final now = _now();
          if (now.difference(lastProgress) <
              const Duration(milliseconds: 100)) {
            return;
          }
          lastProgress = now;
          final completed = received.clamp(0, asset.size);
          _emit(
            state.value.copyWith(
              status: InAppUpdateStatus.downloading,
              received: completed,
              total: asset.size,
            ),
          );
        },
      );
      if (token.isCancelled) throw token.cancelError!;
      if (p.normalize(file.absolute.path) !=
          p.normalize(target.absolute.path)) {
        throw const FormatException('Unexpected update file');
      }
      _emit(
        state.value.copyWith(
          status: InAppUpdateStatus.verifying,
          received: asset.size,
          total: asset.size,
        ),
      );
      final digest = await verifyDownloadedUpdate(
        file,
        size: asset.size,
        digest: asset.digest,
      );
      if (token.isCancelled) throw token.cancelError!;
      await _validate(file);
      if (token.isCancelled) throw token.cancelError!;
      final ready = _ReadyUpdate(version, asset, file, digest);
      await directory.create(recursive: true);
      final temporary = File('${metadata.path}.tmp');
      await temporary.writeAsString(jsonEncode(ready.toJson()), flush: true);
      if (token.isCancelled) throw token.cancelError!;
      await temporary.rename(metadata.path);
      if (token.isCancelled) throw token.cancelError!;
      _ready = ready;
      _emit(
        InAppUpdateState(
          status: InAppUpdateStatus.ready,
          version: version,
          assetName: asset.name,
          received: asset.size,
          total: asset.size,
        ),
      );
    } catch (error) {
      await _delete(metadata);
      await _delete(target);
      if (token.isCancelled) {
        _emit(state.value.copyWith(status: InAppUpdateStatus.cancelled));
      } else {
        _emit(
          state.value.copyWith(status: InAppUpdateStatus.failed, error: error),
        );
      }
    } finally {
      _busy = false;
      if (identical(_token, token)) _token = null;
    }
  }

  /// Launches the system installer for the verified APK. Only call after an
  /// explicit user action. Returns false when the install permission was
  /// declined (the cached APK stays reusable) or no ready APK exists.
  Future<bool> installReadyUpdate() async {
    final ready = _ready;
    if (ready == null || _disposed) return false;
    _emit(state.value.copyWith(status: InAppUpdateStatus.installing));
    try {
      if (!shouldNotifyRelease(ready.version, _currentVersion())) {
        throw const FormatException('Update version is not newer');
      }
      try {
        await verifyDownloadedUpdate(
          ready.file,
          size: ready.asset.size,
          expectedSha256: ready.digest,
        );
      } catch (error) {
        await _discardReady(ready);
        _emit(
          state.value.copyWith(status: InAppUpdateStatus.failed, error: error),
        );
        return false;
      }
      await _validate(ready.file);
      final launched = await _installer(ready.file);
      _emit(
        state.value.copyWith(
          status: launched ? InAppUpdateStatus.ready : InAppUpdateStatus.failed,
          error: launched ? null : const _InstallPermissionDenied(),
        ),
      );
      return launched;
    } catch (error) {
      _emit(
        state.value.copyWith(status: InAppUpdateStatus.failed, error: error),
      );
      return false;
    }
  }

  void cancel() => _token?.cancel('Cancelled');

  Future<void> _discardReady(_ReadyUpdate ready) async {
    if (identical(_ready, ready)) _ready = null;
    await _delete(File(p.join(ready.file.parent.path, 'ready.json')));
    await _delete(ready.file);
  }

  // The updater owns these files. Leave unrelated files and directories
  // alone, and never follow links while cleaning interrupted downloads.
  static Future<void> _cleanCache(Directory directory, {File? keep}) async {
    try {
      if (!await directory.exists()) return;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File && entry is! Link) continue;
        if (keep != null && p.equals(entry.absolute.path, keep.absolute.path)) {
          continue;
        }
        final name = p.basename(entry.path).toLowerCase();
        if (name.endsWith('.apk') ||
            name.endsWith('.apk.part') ||
            name == 'ready.json.tmp') {
          await _delete(File(entry.path));
        }
      }
    } catch (_) {
      // Cache housekeeping must not prevent a fresh download.
    }
  }

  static Future<void> _delete(File? file) async {
    try {
      if (file == null) return;
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await file.delete();
      }
    } catch (_) {}
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _token?.cancel('Disposed');
    _token = null;
    state.dispose();
  }
}

/// Marker for a declined system install permission (distinct from failures:
/// the cached APK stays valid and Install can be retried).
class _InstallPermissionDenied {
  const _InstallPermissionDenied();

  @override
  String toString() => 'Install permission was not granted';
}

/// Whether [error] is a declined install permission rather than a failure.
bool isInstallPermissionDenied(Object? error) =>
    error is _InstallPermissionDenied;

class _ReadyUpdate {
  const _ReadyUpdate(this.version, this.asset, this.file, this.digest);
  final String version;
  final UpdateAsset asset;
  final File file;
  final String digest;
  Map<String, dynamic> toJson() => {
    'version': version,
    'sha256': digest,
    'asset': asset.toJson(),
  };
}
