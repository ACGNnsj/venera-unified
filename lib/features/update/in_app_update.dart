import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A downloadable GitHub release asset for in-app updates.
///
/// Ported from venera-prime's `app_update.dart` ([ReleaseAsset]); the download
/// URL allowlist points at this repository's releases instead of prime's.
class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    required this.size,
    this.digest,
  });

  final String name;
  final String url;
  final int size;

  /// The `digest` field reported by the GitHub releases API, if any
  /// (expected shape: `sha256:<64 hex chars>`).
  final String? digest;

  static const _downloadPrefix = '/CyrilPeng/venera-next/releases/download/';

  static UpdateAsset? fromJson(Map data) {
    final name = data['name'];
    final url = data['browser_download_url'];
    final size = data['size'];
    if (name is! String || url is! String || size is! int || size <= 0) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith(_downloadPrefix)) {
      return null;
    }
    return UpdateAsset(
      name: name,
      url: url,
      size: size,
      digest: data['digest']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'browser_download_url': url,
    'size': size,
    'digest': digest,
  };
}

/// A GitHub release carrying installable update assets.
///
/// Ported from venera-prime's `app_update.dart` ([LatestRelease]).
class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.title,
    required this.body,
    required this.url,
    this.assets = const [],
  });

  final String version;
  final String title;
  final String body;
  final String url;
  final List<UpdateAsset> assets;

  static UpdateRelease fromAssets({
    required String version,
    required String title,
    required String body,
    required String url,
    required List<Map<String, dynamic>> assets,
  }) {
    return UpdateRelease(
      version: version,
      title: title,
      body: body,
      url: url,
      assets: [for (final entry in assets) ?UpdateAsset.fromJson(entry)],
    );
  }

  /// Picks the APK matching one of [supportedAbis], preferring an exact
  /// `-<abi>.apk` suffix match. Falls back to a universal (ABI-less) APK.
  /// Returns null when no installable APK exists.
  UpdateAsset? androidAsset(List<String> supportedAbis) {
    const knownAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];
    final apks = assets
        .where(
          (a) =>
              a.name.toLowerCase().endsWith('.apk') &&
              !a.name.toLowerCase().contains('debug'),
        )
        .toList();
    for (final abi in supportedAbis) {
      for (final asset in apks) {
        if (asset.name.toLowerCase().endsWith('-${abi.toLowerCase()}.apk')) {
          return asset;
        }
      }
    }
    for (final asset in apks) {
      if (!knownAbis.any(
        (abi) => asset.name.toLowerCase().endsWith('-$abi.apk'),
      )) {
        return asset;
      }
    }
    return null;
  }
}

/// Resolves the updater-cache file for [assetName], rejecting anything that
/// is not a plain `.apk` basename (no directories, separators, or links).
///
/// Throws [FormatException] on invalid names. Ported from prime's
/// `AppUpdateService._assetFile` guard.
File updateTargetFile(Directory directory, String assetName) {
  if (p.basename(assetName) != assetName ||
      assetName.contains('\\') ||
      !assetName.toLowerCase().endsWith('.apk')) {
    throw const FormatException('Invalid update filename');
  }
  return File(p.join(directory.path, assetName));
}

/// Verifies a downloaded APK: regular file (never following a cache symlink),
/// exact published size, and sha256 digest when the release (or a cached
/// `ready.json`) pins one. Returns the lowercase hex digest.
///
/// Ported from prime's `AppUpdateService._verifyFile`.
Future<String> verifyDownloadedUpdate(
  File file, {
  required int size,
  String? digest,
  String? expectedSha256,
}) async {
  // Do not follow a cache symlink outside the private updater directory.
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw FormatException('Update file is not a regular file ($type)');
  }
  final actualSize = await file.length();
  if (size <= 0 || actualSize != size) {
    throw FormatException(
      'Update download is incomplete '
      '(expected $size bytes, received $actualSize bytes)',
    );
  }
  final sha256Hex = (await sha256.bind(file.openRead()).first).toString();
  if (expectedSha256 != null && sha256Hex != expectedSha256.toLowerCase() ||
      digest != null &&
          digest.isNotEmpty &&
          digest.toLowerCase() != 'sha256:$sha256Hex') {
    throw const FormatException('Update checksum mismatch');
  }
  return sha256Hex;
}
