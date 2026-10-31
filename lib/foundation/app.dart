import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

class _App {
  String version = "0.0.0";

  bool get isAndroid => Platform.isAndroid;

  bool get isIOS => Platform.isIOS;

  bool get isWindows => Platform.isWindows;

  bool get isLinux => Platform.isLinux;

  bool get isMacOS => Platform.isMacOS;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  static const _windowsCompanyDirectory = 'com.github.cyrilpeng';
  static const _windowsProductDirectory = 'VeneraNext';
  static const _legacyWindowsDirectories = [
    ('CyrilPeng_venera-next', 'VeneraNext'),
    ('CyrilPeng_venera-next', 'venera'),
    ('com.github.wgh136', 'venera'),
  ];

  Future<void> init() async {
    await _initVersion();
    cachePath = await _writablePath(
      (await getApplicationCacheDirectory()).path,
    );
    dataPath = await _writablePath(
      (await getApplicationSupportDirectory()).path,
    );
    if (isWindows) {
      await _migrateLegacyWindowsPath(cachePath);
      await _migrateLegacyWindowsPath(dataPath);
    }
    if (isAndroid) {
      externalStoragePath = (await getExternalStorageDirectory())!.path;
    }
    isInitialized = true;
  }

  /// Returns [preferred] when the process can write there, otherwise a
  /// userdata directory next to the executable.
  ///
  /// Some Windows hosts deny writes to the roaming/local app data trees even
  /// though the ACLs look fine (restricted token, machine policy, or endpoint
  /// protection). Without this probe every cache write fails with
  /// PathAccessException and images never render, so fall back to a location
  /// the user can always write next to the app.
  Future<String> _writablePath(String preferred) async {
    if (!isDesktop) return preferred;
    if (await _isWritable(preferred)) return preferred;
    final fallback = p.join(
      p.dirname(Platform.resolvedExecutable),
      'userdata',
      p.basename(preferred),
    );
    if (await _isWritable(fallback)) {
      _reportPathFallback(
        'App data path $preferred is not writable; using $fallback',
      );
      return fallback;
    }
    _reportPathFallback('No writable app data path found; keeping $preferred');
    return preferred;
  }

  @visibleForTesting
  Future<String> writablePathForTesting(String preferred) =>
      _writablePath(preferred);

  /// Logging must never break startup: packaged builds have no console, and
  /// writing to the closed stdio handle throws.
  void _reportPathFallback(String message) {
    try {
      debugPrint(message);
    } catch (_) {
      // Ignored on purpose.
    }
  }

  Future<bool> _isWritable(String directory) async {
    try {
      await Directory(directory).create(recursive: true);
      final probe = File(p.join(directory, '.write-probe'));
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @visibleForTesting
  Future<void> migrateLegacyWindowsPathForTesting(String currentPath) {
    return _migrateLegacyWindowsPath(currentPath);
  }

  Future<void> _migrateLegacyWindowsPath(String currentPath) async {
    final normalizedCurrentPath = p.normalize(currentPath);
    final appDirectoryName = p.basename(normalizedCurrentPath);
    final companyDirectory = p.basename(p.dirname(normalizedCurrentPath));
    if (companyDirectory != _windowsCompanyDirectory ||
        appDirectoryName != _windowsProductDirectory) {
      return;
    }

    final baseDirectory = p.dirname(p.dirname(normalizedCurrentPath));
    final currentDirectory = Directory(normalizedCurrentPath);
    if (!await currentDirectory.exists()) {
      await currentDirectory.create(recursive: true);
    }

    for (final (company, product) in _legacyWindowsDirectories) {
      final legacyDirectory = Directory(
        p.join(baseDirectory, company, product),
      );
      if (!await legacyDirectory.exists()) {
        continue;
      }
      await _copyMissingDirectoryContents(legacyDirectory, currentDirectory);
    }
  }

  Future<void> _copyMissingDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }

    await for (final entity in source.list(followLinks: false)) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyMissingDirectoryContents(entity, Directory(targetPath));
      } else if (entity is File) {
        final target = File(targetPath);
        if (!await target.exists()) {
          await target.parent.create(recursive: true);
          await entity.copy(targetPath);
        }
      }
    }
  }

  Future<void> _initVersion() async {
    final pubspec = await rootBundle.loadString("pubspec.yaml");
    final data = loadYaml(pubspec);
    version = data["version"].toString().split('+').first;
  }
}

// ignore: non_constant_identifier_names
final App = _App();
