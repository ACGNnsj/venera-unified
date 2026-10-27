import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/application_update_service.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/foundation/translations.dart';

import 'android_app_installer.dart';
import 'in_app_update.dart';
import 'in_app_update_service.dart';

const _releasePageUrl = 'https://github.com/CyrilPeng/venera-next/releases';

/// Opens the in-app update flow for an available release.
///
/// Android only: fetches the installable release, picks the APK matching the
/// device ABI, and downloads → verifies → installs without leaving the app.
/// Any failure (fetch error, no matching APK, non-Android platform) falls
/// back to opening the release page, preserving the previous behavior.
Future<void> showInAppUpdate({
  required BuildContext context,
  required ApplicationUpdateService service,
  required String version,
}) async {
  if (!App.isAndroid || !context.mounted) {
    await _openReleasePage(_releasePageUrl);
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _InAppUpdateDialog(service: service),
  );
}

Future<void> _openReleasePage(String url) async {
  try {
    await launchUrlString(url);
  } catch (error, stack) {
    Log.error('Open application release', error, stack);
  }
}

enum _DialogPhase { preparing, confirm }

class _InAppUpdateDialog extends StatefulWidget {
  const _InAppUpdateDialog({required this.service});

  final ApplicationUpdateService service;

  @override
  State<_InAppUpdateDialog> createState() => _InAppUpdateDialogState();
}

class _InAppUpdateDialogState extends State<_InAppUpdateDialog> {
  final _service = InAppUpdateService();
  _DialogPhase _phase = _DialogPhase.preparing;
  UpdateRelease? _release;
  UpdateAsset? _asset;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    InstallableApplicationRelease? fetched;
    try {
      fetched = await widget.service.checkInstallableRelease();
    } catch (error, stack) {
      Log.error('Fetch installable release', error, stack);
    }
    if (!mounted) return;
    if (fetched == null) {
      await _fallback(_releasePageUrl);
      return;
    }
    final release = UpdateRelease.fromAssets(
      version: fetched.version,
      title: fetched.title,
      body: fetched.body,
      url: fetched.url,
      assets: fetched.assets,
    );
    List<String> abis;
    try {
      abis = await AndroidAppInstaller.supportedAbis();
    } catch (error, stack) {
      Log.error('Query update ABIs', error, stack);
      await _fallback(release.url);
      return;
    }
    final asset = release.androidAsset(abis);
    if (!mounted) return;
    if (asset == null) {
      await _fallback(release.url);
      return;
    }
    setState(() {
      _release = release;
      _asset = asset;
      _phase = _DialogPhase.confirm;
    });
    // Surface a previously verified APK (if the user dismissed the dialog
    // after downloading) without starting a new download.
    unawaited(_service.restore());
  }

  Future<void> _fallback(String url) async {
    if (!mounted) return;
    Navigator.of(context).pop();
    await _openReleasePage(url);
  }

  Future<void> _startDownload() async {
    final release = _release;
    final asset = _asset;
    if (release == null || asset == null) return;
    try {
      await _service.startDownload(version: release.version, asset: asset);
    } catch (error, stack) {
      Log.error('Start update download', error, stack);
    }
  }

  Future<void> _install() async {
    final navigator = Navigator.of(context);
    final launched = await _service.installReadyUpdate();
    if (!mounted) return;
    if (launched) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    return ValueListenableBuilder<InAppUpdateState>(
      valueListenable: _service.state,
      builder: (context, update, _) {
        if (_phase == _DialogPhase.preparing) {
          return AlertDialog(
            title: Text('App update'.tl),
            content: const SizedBox(
              height: 64,
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        return AlertDialog(
          title: Text('${release!.title} (${release.version})'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A new version @v is available. Do you want to update now?'
                      .tlParams({'v': release.version}),
                ),
                if (release.body.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: SingleChildScrollView(child: Text(release.body)),
                  ),
                ],
                ..._statusBody(update),
              ],
            ),
          ),
          actions: _actions(update),
        );
      },
    );
  }

  List<Widget> _statusBody(InAppUpdateState update) {
    switch (update.status) {
      case InAppUpdateStatus.idle:
      case InAppUpdateStatus.cancelled:
        return const [];
      case InAppUpdateStatus.downloading:
        return [
          const SizedBox(height: 12),
          LinearProgressIndicator(value: update.progress),
          const SizedBox(height: 4),
          Text(
            '${'Downloading'.tl} '
            '${(update.progress * 100).toStringAsFixed(0)}% · '
            '${_bytes(update.received)} / ${_bytes(update.total)}',
            style: const TextStyle(fontSize: 12),
          ),
        ];
      case InAppUpdateStatus.verifying:
        return [
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 4),
          Text('Verifying update'.tl, style: const TextStyle(fontSize: 12)),
        ];
      case InAppUpdateStatus.ready:
        return [
          const SizedBox(height: 12),
          Text('Ready to install'.tl, style: const TextStyle(fontSize: 12)),
        ];
      case InAppUpdateStatus.installing:
        return [
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 4),
          Text('Opening installer…'.tl, style: const TextStyle(fontSize: 12)),
        ];
      case InAppUpdateStatus.failed:
        final error = update.error;
        final message = isInstallPermissionDenied(error)
            ? 'Allow app installs in system settings, then tap Install again.'
                  .tl
            : '${'Update failed'.tl}\n$error';
        return [
          const SizedBox(height: 12),
          SelectableText(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ];
    }
  }

  List<Widget> _actions(InAppUpdateState update) {
    final release = _release;
    final cancel = TextButton(
      onPressed:
          update.status == InAppUpdateStatus.downloading ||
              update.status == InAppUpdateStatus.verifying
          ? _service.cancel
          : () => Navigator.of(context).pop(),
      child: Text('Cancel'.tl),
    );
    switch (update.status) {
      case InAppUpdateStatus.idle:
      case InAppUpdateStatus.cancelled:
        return [
          cancel,
          TextButton(onPressed: _startDownload, child: Text('Update'.tl)),
        ];
      case InAppUpdateStatus.downloading:
      case InAppUpdateStatus.verifying:
      case InAppUpdateStatus.installing:
        return [cancel];
      case InAppUpdateStatus.ready:
        return [
          cancel,
          TextButton(onPressed: _install, child: Text('Install'.tl)),
        ];
      case InAppUpdateStatus.failed:
        if (isInstallPermissionDenied(update.error)) {
          return [
            cancel,
            TextButton(onPressed: _install, child: Text('Install'.tl)),
          ];
        }
        return [
          cancel,
          if (release != null)
            TextButton(
              onPressed: () => _openReleasePage(release.url),
              child: Text('Open release page'.tl),
            ),
          TextButton(onPressed: _startDownload, child: Text('Retry'.tl)),
        ];
    }
  }

  static String _bytes(int count) => count < 1024
      ? '$count B'
      : count < 1024 * 1024
      ? '${(count / 1024).toStringAsFixed(1)} KiB'
      : '${(count / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
