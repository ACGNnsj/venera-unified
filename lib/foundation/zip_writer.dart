import 'dart:io';
import 'dart:isolate';

import 'package:zip_flutter/zip_flutter.dart';

import 'zip_stream_writer.dart';

// Compresses [sourceDirectory] into a zip archive at [destinationPath].
//
// zip_flutter only ships native code for macOS, iOS, Android, Linux and
// Windows; its Dart entry point throws UnsupportedError everywhere else
// (ohos for example), so the archive is streamed by the Rust writer (when its
// library is present) or the pure-Dart writer whenever the native writer is
// unavailable. [nativeCompressor] is a seam for tests; production callers
// leave it unset.
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
  // the worker so one slow file never blocks the isolate event loop. Entries
  // stream one at a time instead of buffering the whole archive in memory.
  try {
    await Isolate.run(
      () => ZipStreamWriter.writeDirectory(sourceDirectory, destinationPath),
    );
  } catch (_) {
    _deletePartialArchive(destinationPath);
    rethrow;
  }
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
