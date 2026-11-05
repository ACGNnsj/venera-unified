// Manual device harness for the in-app update pipeline (Android).
//
// Not part of CI. Build it as a normal APK, install it over the current build,
// launch it, then confirm the system installer on the device:
//
//   flutter build apk --debug --target-platform android-arm64 --no-pub \
//     -t tool/in_app_update_probe.dart \
//     --dart-define-from-file=<probe.json>
//
// probe.json keys: UPDATE_PROBE_NAME, UPDATE_PROBE_URL, UPDATE_PROBE_SIZE,
// UPDATE_PROBE_DIGEST, UPDATE_PROBE_VERSION, UPDATE_PROBE_CURRENT.
//
// The harness runs production code end to end: the real HTTP downloader
// (rhttp), size + sha256 verification, the native validateUpdate channel and
// the native installUpdate channel that hands the APK to the system installer.
// Only the GitHub release metadata step is skipped (asset injected), since
// that parsing is covered by unit tests.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rhttp/rhttp.dart' show Rhttp;
import 'package:venera_unified/features/update/in_app_update.dart';
import 'package:venera_unified/features/update/in_app_update_service.dart';
import 'package:venera_unified/foundation/app.dart';

const _name = String.fromEnvironment('UPDATE_PROBE_NAME');
const _url = String.fromEnvironment('UPDATE_PROBE_URL');
const _size = int.fromEnvironment('UPDATE_PROBE_SIZE');
const _digest = String.fromEnvironment('UPDATE_PROBE_DIGEST');
const _version = String.fromEnvironment('UPDATE_PROBE_VERSION');
const _currentVersion = String.fromEnvironment('UPDATE_PROBE_CURRENT');

void main() {
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  String _status = 'starting';
  String _detail = '';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final stopwatch = Stopwatch()..start();
    try {
      await App.init();
      await Rhttp.init();
      final asset = UpdateAsset(
        name: _name,
        url: _url,
        size: _size,
        digest: _digest.isEmpty ? null : _digest,
      );
      final service = InAppUpdateService(currentVersion: () => _currentVersion);
      service.state.addListener(() {
        final state = service.state.value;
        _update(
          state.status.name,
          'received=${state.received}/total=${state.total} '
          'error=${state.error}',
        );
        debugPrint(
          'UPDATE_PROBE_STATE status=${state.status.name} '
          'received=${state.received} total=${state.total} '
          'error=${state.error}',
        );
      });

      debugPrint('UPDATE_PROBE_CONFIG name=$_name size=$_size');
      await service.startDownload(version: _version, asset: asset);
      final ready = await _waitFor(service, {
        InAppUpdateStatus.ready,
        InAppUpdateStatus.failed,
      });
      if (ready.status != InAppUpdateStatus.ready) {
        throw StateError('Update failed: ${ready.error}');
      }
      debugPrint(
        'UPDATE_PROBE_READY asset=${ready.assetName} '
        'received=${ready.received} total=${ready.total} '
        'ms=${stopwatch.elapsedMilliseconds}',
      );
      final launched = await service.installReadyUpdate();
      debugPrint('UPDATE_PROBE_INSTALLER_LAUNCHED launched=$launched');
      _update('installer-launched', 'launched=$launched');
    } catch (error) {
      debugPrint('UPDATE_PROBE_ERROR $error');
      _update('error', '$error');
    }
  }

  Future<InAppUpdateState> _waitFor(
    InAppUpdateService service,
    Set<InAppUpdateStatus> wanted,
  ) async {
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(deadline)) {
      final state = service.state.value;
      if (wanted.contains(state.status)) return state;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('Timed out waiting for $wanted');
  }

  void _update(String status, String detail) {
    debugPrint('UPDATE_PROBE $status $detail');
    if (!mounted) return;
    setState(() {
      _status = status;
      _detail = detail;
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_status, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 12),
              Text(_detail, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}
