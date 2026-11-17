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
  // The fallback keeps file IO off the UI isolate; reads stay async inside
  // the worker so one slow file never blocks the isolate event loop.
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

Future<void> _encodeDirectory(
  String sourceDirectory,
  String destinationPath,
) async {
  final root = Directory(sourceDirectory);
  final files = await root.list(recursive: true).where((e) => e is File).cast<File>().toList();
  final entries =
      files
          .map((file) => MapEntry(_archivePath(file.path, root.path), file))
          .toList()
        ..sort((a, b) => _compareArchivePaths(a.key, b.key));
  final archive = archive_io.Archive();
  for (final entry in entries) {
    archive.addFile(
      archive_io.ArchiveFile.bytes(entry.key, await entry.value.readAsBytes()),
    );
  }
  await File(
    destinationPath,
  ).writeAsBytes(archive_io.ZipEncoder().encodeBytes(archive));
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
