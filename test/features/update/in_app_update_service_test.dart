import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_unified/features/update/in_app_update.dart';
import 'package:venera_unified/features/update/in_app_update_service.dart';
import 'package:venera_unified/network/app_dio.dart' show CancelToken;

const _apkName = 'VeneraUnified-1.19.0-android-arm64-v8a.apk';
const _apkUrl =
    'https://github.com/CyrilPeng/venera-next/releases/download/v1.19.0/$_apkName';

UpdateAsset testAsset({required int size, String? digest}) =>
    UpdateAsset(name: _apkName, url: _apkUrl, size: size, digest: digest);

Future<void> waitForStatus(
  InAppUpdateService service,
  InAppUpdateStatus status,
) async {
  for (var i = 0; i < 500; i++) {
    if (service.state.value.status == status) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'timed out waiting for $status '
    '(was ${service.state.value.status}: ${service.state.value.error})',
  );
}

void main() {
  late Directory temp;
  late List<int> payload;
  late String payloadSha256;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('in-app-update-service-test');
    payload = List<int>.generate(4096, (i) => i % 251);
    payloadSha256 = sha256.convert(payload).toString();
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<File> writingDownloader({
    required UpdateAsset asset,
    required Directory directory,
    required CancelToken cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, asset.name));
    await file.writeAsBytes(payload, flush: true);
    onProgress?.call(payload.length, asset.size);
    return file;
  }

  group('download → verify → ready', () {
    test('verified download is cached in ready.json', () async {
      var validations = 0;
      final service = InAppUpdateService(
        downloader: writingDownloader,
        validate: (_) async => validations++,
        installer: (_) async => true,
        currentVersion: () => '1.18.2',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);
      final asset = testAsset(
        size: payload.length,
        digest: 'sha256:$payloadSha256',
      );

      await service.startDownload(version: '1.19.0', asset: asset);
      await waitForStatus(service, InAppUpdateStatus.ready);

      expect(validations, 1);
      final metadata = File(p.join(temp.path, 'ready.json'));
      expect(metadata.existsSync(), isTrue);
      final data = jsonDecode(metadata.readAsStringSync()) as Map;
      expect(data['version'], '1.19.0');
      expect(data['sha256'], payloadSha256);
      expect(File(p.join(temp.path, _apkName)).existsSync(), isTrue);
    });

    test('size mismatch fails and cleans the APK', () async {
      final service = InAppUpdateService(
        downloader: writingDownloader,
        validate: (_) async {},
        installer: (_) async => true,
        currentVersion: () => '1.18.2',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);

      await service.startDownload(
        version: '1.19.0',
        asset: testAsset(size: payload.length + 1),
      );
      await waitForStatus(service, InAppUpdateStatus.failed);

      expect(service.state.value.error, isFormatException);
      expect(File(p.join(temp.path, _apkName)).existsSync(), isFalse);
      expect(File(p.join(temp.path, 'ready.json')).existsSync(), isFalse);
    });

    test('digest mismatch fails', () async {
      final service = InAppUpdateService(
        downloader: writingDownloader,
        validate: (_) async {},
        installer: (_) async => true,
        currentVersion: () => '1.18.2',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);

      await service.startDownload(
        version: '1.19.0',
        asset: testAsset(size: payload.length, digest: 'sha256:${'0' * 64}'),
      );
      await waitForStatus(service, InAppUpdateStatus.failed);

      expect(
        service.state.value.error.toString(),
        contains('checksum mismatch'),
      );
    });

    test('stale versions are rejected before downloading', () async {
      var downloads = 0;
      final service = InAppUpdateService(
        downloader:
            ({
              required asset,
              required directory,
              required cancelToken,
              onProgress,
            }) async {
              downloads++;
              return writingDownloader(
                asset: asset,
                directory: directory,
                cancelToken: cancelToken,
                onProgress: onProgress,
              );
            },
        validate: (_) async {},
        installer: (_) async => true,
        currentVersion: () => '1.19.0',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);

      await expectLater(
        service.startDownload(
          version: '1.18.2',
          asset: testAsset(size: payload.length),
        ),
        throwsFormatException,
      );
      expect(downloads, 0);
    });

    test(
      'prerelease is rejected for stable installs (channel joint)',
      () async {
        var downloads = 0;
        final service = InAppUpdateService(
          downloader:
              ({
                required asset,
                required directory,
                required cancelToken,
                onProgress,
              }) async {
                downloads++;
                return writingDownloader(
                  asset: asset,
                  directory: directory,
                  cancelToken: cancelToken,
                  onProgress: onProgress,
                );
              },
          validate: (_) async {},
          installer: (_) async => true,
          currentVersion: () => '1.18.2',
          downloadDirectory: () => temp,
        );
        addTearDown(service.dispose);

        await expectLater(
          service.startDownload(
            version: '2.0.0-rc.1',
            asset: testAsset(size: payload.length),
          ),
          throwsFormatException,
        );
        expect(downloads, 0);
      },
    );

    test('cancellation reports cancelled', () async {
      final service = InAppUpdateService(
        downloader:
            ({
              required asset,
              required directory,
              required cancelToken,
              onProgress,
            }) async {
              await cancelToken.whenCancel;
              throw cancelToken.cancelError!;
            },
        validate: (_) async {},
        installer: (_) async => true,
        currentVersion: () => '1.18.2',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);

      await service.startDownload(
        version: '1.19.0',
        asset: testAsset(size: payload.length),
      );
      await waitForStatus(service, InAppUpdateStatus.downloading);
      service.cancel();
      await waitForStatus(service, InAppUpdateStatus.cancelled);
    });
  });

  group('ready.json restoration', () {
    Future<void> seedReadyCache() async {
      await File(p.join(temp.path, _apkName)).writeAsBytes(payload);
      await File(p.join(temp.path, 'ready.json')).writeAsString(
        jsonEncode({
          'version': '1.19.0',
          'sha256': payloadSha256,
          'asset': testAsset(
            size: payload.length,
            digest: 'sha256:$payloadSha256',
          ).toJson(),
        }),
      );
    }

    test('valid cache is reused without downloading', () async {
      await seedReadyCache();
      var downloads = 0;
      var validations = 0;
      final service = InAppUpdateService(
        downloader:
            ({
              required asset,
              required directory,
              required cancelToken,
              onProgress,
            }) async {
              downloads++;
              return writingDownloader(
                asset: asset,
                directory: directory,
                cancelToken: cancelToken,
                onProgress: onProgress,
              );
            },
        validate: (_) async => validations++,
        installer: (_) async => true,
        currentVersion: () => '1.18.2',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);

      await service.restore();
      expect(service.state.value.status, InAppUpdateStatus.ready);
      expect(downloads, 0);
      expect(validations, 1);
    });

    test('corrupt cache is discarded', () async {
      await seedReadyCache();
      await File(p.join(temp.path, _apkName)).writeAsBytes([9, 9, 9]);
      final service = InAppUpdateService(
        downloader: writingDownloader,
        validate: (_) async {},
        installer: (_) async => true,
        currentVersion: () => '1.18.2',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);

      await service.restore();
      expect(service.state.value.status, InAppUpdateStatus.idle);
      expect(File(p.join(temp.path, 'ready.json')).existsSync(), isFalse);
    });
  });

  group('install', () {
    Future<InAppUpdateService> readyService({
      Future<bool> Function(File)? installer,
      void Function()? onValidate,
    }) async {
      final service = InAppUpdateService(
        downloader: writingDownloader,
        validate: (_) async => onValidate?.call(),
        installer: installer ?? (_) async => true,
        currentVersion: () => '1.18.2',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);
      await service.startDownload(
        version: '1.19.0',
        asset: testAsset(size: payload.length, digest: 'sha256:$payloadSha256'),
      );
      await waitForStatus(service, InAppUpdateStatus.ready);
      return service;
    }

    test('launched installer keeps the ready state', () async {
      final service = await readyService();
      expect(await service.installReadyUpdate(), isTrue);
      expect(service.state.value.status, InAppUpdateStatus.ready);
      expect(service.state.value.error, isNull);
    });

    test('declined permission is retryable and keeps the APK', () async {
      final service = await readyService(installer: (_) async => false);
      expect(await service.installReadyUpdate(), isFalse);
      expect(service.state.value.status, InAppUpdateStatus.failed);
      expect(isInstallPermissionDenied(service.state.value.error), isTrue);
      expect(File(p.join(temp.path, _apkName)).existsSync(), isTrue);
    });

    test('missing APK at install time fails cleanly', () async {
      final service = await readyService();
      File(p.join(temp.path, _apkName)).deleteSync();
      expect(await service.installReadyUpdate(), isFalse);
      expect(service.state.value.status, InAppUpdateStatus.failed);
      expect(isInstallPermissionDenied(service.state.value.error), isFalse);
    });

    test('nothing ready returns false', () async {
      final service = InAppUpdateService(
        downloader: writingDownloader,
        validate: (_) async {},
        installer: (_) async => true,
        currentVersion: () => '1.18.2',
        downloadDirectory: () => temp,
      );
      addTearDown(service.dispose);
      expect(await service.installReadyUpdate(), isFalse);
    });
  });
}
