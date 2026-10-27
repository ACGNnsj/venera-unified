import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_unified/features/update/in_app_update.dart';
import 'package:venera_unified/foundation/release_version.dart';

Map<String, dynamic> assetJson({
  String name = 'VeneraUnified-1.19.0-android-arm64-v8a.apk',
  String url =
      'https://github.com/CyrilPeng/venera-next/releases/download/v1.19.0/VeneraUnified-1.19.0-android-arm64-v8a.apk',
  int size = 42,
  String? digest,
}) => {
  'name': name,
  'browser_download_url': url,
  'size': size,
  'digest': ?digest,
};

UpdateRelease releaseWith(List<String> names) => UpdateRelease(
  version: '1.19.0',
  title: 'v1.19.0',
  body: '',
  url: 'https://github.com/CyrilPeng/venera-next/releases',
  assets: [
    for (final name in names)
      UpdateAsset(
        name: name,
        url:
            'https://github.com/CyrilPeng/venera-next/releases/download/v1.19.0/$name',
        size: 42,
      ),
  ],
);

void main() {
  group('UpdateAsset.fromJson', () {
    test('accepts unified release download URLs', () {
      final asset = UpdateAsset.fromJson(assetJson(digest: 'sha256:abc'));
      expect(asset, isNotNull);
      expect(asset!.digest, 'sha256:abc');
      expect(asset.size, 42);
    });

    test('rejects other repositories', () {
      expect(
        UpdateAsset.fromJson(
          assetJson(
            url:
                'https://github.com/venera-app/venera-prime/releases/download/v2.6.3/app.apk',
          ),
        ),
        isNull,
      );
    });

    test('rejects non-github hosts and non-https URLs', () {
      expect(
        UpdateAsset.fromJson(
          assetJson(
            url:
                'https://objects.githubusercontent.com/CyrilPeng/venera-next/releases/download/v1.19.0/app.apk',
          ),
        ),
        isNull,
      );
      expect(
        UpdateAsset.fromJson(
          assetJson(
            url:
                'http://github.com/CyrilPeng/venera-next/releases/download/v1.19.0/app.apk',
          ),
        ),
        isNull,
      );
    });

    test('rejects missing names and non-positive sizes', () {
      expect(UpdateAsset.fromJson(assetJson(size: 0)), isNull);
      expect(UpdateAsset.fromJson(assetJson(size: -1)), isNull);
      final missingName = assetJson()..remove('name');
      expect(UpdateAsset.fromJson(missingName), isNull);
    });
  });

  group('UpdateRelease.androidAsset', () {
    test('prefers the first supported ABI in device order', () {
      final release = releaseWith([
        'VeneraUnified-1.19.0-android-armeabi-v7a.apk',
        'VeneraUnified-1.19.0-android-arm64-v8a.apk',
        'VeneraUnified-1.19.0-android.apk',
      ]);
      final asset = release.androidAsset(['arm64-v8a', 'armeabi-v7a']);
      expect(asset!.name, 'VeneraUnified-1.19.0-android-arm64-v8a.apk');
    });

    test('falls back to the universal APK', () {
      final release = releaseWith([
        'VeneraUnified-1.19.0-android.apk',
        'VeneraUnified-1.19.0-windows-x64.zip',
      ]);
      final asset = release.androidAsset(['arm64-v8a']);
      expect(asset!.name, 'VeneraUnified-1.19.0-android.apk');
    });

    test('skips debug builds and returns null without an APK', () {
      final release = releaseWith([
        'VeneraUnified-1.19.0-android-arm64-v8a-debug.apk',
        'notes.txt',
      ]);
      expect(release.androidAsset(['arm64-v8a']), isNull);
    });
  });

  group('UpdateRelease.fromAssets', () {
    test('drops assets outside the allowlist', () {
      final release = UpdateRelease.fromAssets(
        version: '1.19.0',
        title: 'v1.19.0',
        body: '',
        url: 'https://github.com/CyrilPeng/venera-next/releases',
        assets: [
          assetJson(),
          assetJson(name: 'evil.apk', url: 'https://example.com/evil.apk'),
        ],
      );
      expect(release.assets.map((a) => a.name), [
        'VeneraUnified-1.19.0-android-arm64-v8a.apk',
      ]);
    });
  });

  group('updateTargetFile', () {
    test('resolves basenames inside the updater cache', () {
      final file = updateTargetFile(
        Directory('/cache/updates'),
        'app-arm64-v8a.apk',
      );
      expect(file.path, p.join('/cache/updates', 'app-arm64-v8a.apk'));
    });

    test('rejects paths, separators, and non-APK names', () {
      final dir = Directory('/cache/updates');
      expect(() => updateTargetFile(dir, '../evil.apk'), throwsFormatException);
      expect(
        () => updateTargetFile(dir, 'sub/evil.apk'),
        throwsFormatException,
      );
      expect(() => updateTargetFile(dir, 'evil.apk\\x'), throwsFormatException);
      expect(() => updateTargetFile(dir, 'evil.zip'), throwsFormatException);
    });
  });

  group('verifyDownloadedUpdate', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('in-app-update-test');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('returns the sha256 hex digest for valid files', () async {
      final file = File(p.join(temp.path, 'a.apk'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      final expected = sha256.convert([1, 2, 3, 4]).toString();
      expect(await verifyDownloadedUpdate(file, size: 4), expected);
      expect(
        await verifyDownloadedUpdate(file, size: 4, digest: 'sha256:$expected'),
        expected,
      );
      expect(
        await verifyDownloadedUpdate(file, size: 4, expectedSha256: expected),
        expected,
      );
    });

    test('rejects size and digest mismatches', () async {
      final file = File(p.join(temp.path, 'a.apk'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      expect(verifyDownloadedUpdate(file, size: 5), throwsFormatException);
      expect(
        verifyDownloadedUpdate(file, size: 4, digest: 'sha256:${'0' * 64}'),
        throwsFormatException,
      );
      expect(
        verifyDownloadedUpdate(file, size: 4, expectedSha256: '0' * 64),
        throwsFormatException,
      );
    });

    test('rejects non-regular files', () async {
      expect(
        verifyDownloadedUpdate(File(temp.path), size: 4),
        throwsFormatException,
      );
    });
  });

  group('unified version comparison joint', () {
    Map<String, dynamic> release(
      String tag, {
      bool prerelease = false,
      bool draft = false,
    }) => {'tag_name': tag, 'prerelease': prerelease, 'draft': draft};

    test('stable current only takes newer stable releases', () {
      const current = '1.18.2';
      final data = [
        release('v2.0.0-rc.1', prerelease: true),
        release('v1.19.0'),
      ];
      expect(allowsPrereleaseUpdates(current), isFalse);
      final latest = selectPublishedReleaseVersion(
        data,
        includePrerelease: false,
      );
      expect(latest, '1.19.0');
      expect(shouldNotifyRelease(latest!, current), isTrue);
      expect(shouldNotifyRelease('2.0.0-rc.1', current), isFalse);
    });

    test('prerelease current takes newer prereleases and stable', () {
      const current = '1.18.2-rc.3';
      expect(allowsPrereleaseUpdates(current), isTrue);
      final data = [
        release('v1.18.2-rc.4', prerelease: true),
        release('v1.18.2'),
      ];
      final latest = selectPublishedReleaseVersion(
        data,
        includePrerelease: true,
      );
      expect(latest, '1.18.2');
      expect(shouldNotifyRelease(latest!, current), isTrue);
      expect(shouldNotifyRelease('1.18.2-rc.4', current), isTrue);
      expect(shouldNotifyRelease('1.18.2-rc.2', current), isFalse);
    });

    test('drafts are never selected', () {
      final latest = selectPublishedReleaseVersion([
        release('v9.9.9', draft: true),
        release('v1.19.0'),
      ], includePrerelease: false);
      expect(latest, '1.19.0');
    });

    test('equal versions do not notify', () {
      expect(shouldNotifyRelease('1.18.2', '1.18.2'), isFalse);
      expect(shouldNotifyRelease('v1.18.2', '1.18.2'), isFalse);
    });
  });
}
