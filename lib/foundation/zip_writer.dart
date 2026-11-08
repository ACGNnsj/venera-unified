import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' as archive_io;
import 'package:path/path.dart' as p;
import 'package:zip_flutter/zip_flutter.dart';

/// Compresses [sourceDirectory] into a zip archive at [destinationPath].
///
/// zip_flutter only ships native code for macOS, iOS, Android, Linux and
/// Windows; its Dart entry point throws `UnsupportedError` everywhere else
/// (ohos for example), so the archive is encoded by the pure Dart encoder
/// whenever the native writer is unavailable. [nativeCompressor] is a seam
/// for tests; production callers leave it unset.
Future<void> writeZipFromDirectory(
  String sourceDirectory,
  String destinationPath, {
  Future<void> Function(String source, String destination)? nativeCompressor,
}) async {
  try {
    await (nativeCompressor ??
        (String source, String destination) => ZipFile.compressFolderAsync(
          source,
          destination,
          4,
        ))(sourceDirectory, destinationPath);
    return;
  } catch (_) {
    _deletePartialArchive(destinationPath);
  }
  // The fallback reads every file synchronously, so keep it off the UI isolate.
  await Isolate.run(() => _encodeDirectory(sourceDirectory, destinationPath));
}

void _deletePartialArchive(String destinationPath) {
  final partial = File(destinationPath);
  if (!partial.existsSync()) return;
  try {
    partial.deleteSync();
  } catch (_) {
    // The rewrite reports the failure if the stale archive cannot be removed.
  }
}

void _encodeDirectory(String sourceDirectory, String destinationPath) {
  final root = Directory(sourceDirectory);
  final entries =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => MapEntry(_archivePath(file.path, root.path), file))
          .toList()
        ..sort((a, b) => _compareArchivePaths(a.key, b.key));
  final archive = archive_io.Archive();
  for (final entry in entries) {
    archive.addFile(
      archive_io.ArchiveFile.bytes(entry.key, entry.value.readAsBytesSync()),
    );
  }
  File(
    destinationPath,
  ).writeAsBytesSync(archive_io.ZipEncoder().encodeBytes(archive));
}

String _archivePath(String filePath, String rootPath) =>
    p.split(p.relative(filePath, from: rootPath)).join('/');

/// EPUB requires its `mimetype` entry to come first; every other archive does
/// not care about order, so the rule is applied unconditionally.
int _compareArchivePaths(String a, String b) {
  if (a == b) return 0;
  if (a == 'mimetype') return -1;
  if (b == 'mimetype') return 1;
  return a.compareTo(b);
}
