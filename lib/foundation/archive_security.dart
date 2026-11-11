import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive_pkg;
import 'package:venera_native/venera_native.dart' show extractSevenZip;
import 'package:path/path.dart' as path_utils;

import 'zip_entry_reader.dart';

/// Bounded archive extraction used for untrusted downloads and imports.
///
/// Extraction always happens into a staging directory. Callers should only
/// publish that directory after their own validation succeeds.
///
/// Ported from venera-prime's utils/archive_security.dart. Limits and error
/// messages stay identical; [checkLimits] is public (private in prime) so the
/// preflight rules are unit-testable without invoking native extractors.
abstract final class ArchiveSecurity {
  static const maxEntries = 20000;
  static const maxSingleFileBytes = 256 * 1024 * 1024;
  static const maxTotalBytes = 1024 * 1024 * 1024;
  static const maxCompressionRatio = 1000;
  static const maxArchiveBytes = 512 * 1024 * 1024;

  static String safeTarget(String root, String archiveName) {
    final normalized = archiveName.replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.contains(String.fromCharCode(0))) {
      throw const FormatException('Archive contains an invalid entry name');
    }
    if (normalized.startsWith('/') ||
        normalized.startsWith('//') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw const FormatException('Archive contains an absolute entry path');
    }
    final segments = normalized.split('/');
    if (segments.any((segment) => segment == '..')) {
      throw const FormatException('Archive contains a parent entry path');
    }
    final canonicalRoot = path_utils.canonicalize(root);
    final target = path_utils.canonicalize(
      path_utils.join(canonicalRoot, normalized),
    );
    if (target != canonicalRoot &&
        !path_utils.isWithin(canonicalRoot, target)) {
      throw const FormatException('Archive entry escapes extraction directory');
    }
    return target;
  }

  static void checkLimits({
    required int entries,
    required int totalBytes,
    required int archiveBytes,
  }) {
    if (entries > maxEntries) {
      throw const FormatException('Archive contains too many entries');
    }
    if (totalBytes > maxTotalBytes) {
      throw const FormatException('Archive expands beyond the allowed size');
    }
    if (archiveBytes > maxArchiveBytes) {
      throw const FormatException('Archive is too large');
    }
    if (archiveBytes > 0 && totalBytes > archiveBytes * maxCompressionRatio) {
      throw const FormatException('Archive compression ratio is unsafe');
    }
  }

  static void _checkExistingPath(String root, String target) {
    var current = target;
    final canonicalRoot = path_utils.canonicalize(root);
    while (true) {
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FormatException('Archive extraction encountered a symlink');
      }
      if (current == canonicalRoot) break;
      final parent = path_utils.dirname(current);
      if (parent == current) break;
      current = parent;
    }
  }

  static Future<void> extractZip(File input, Directory output) async {
    final archiveBytes = await input.length();
    if (archiveBytes > maxArchiveBytes) {
      throw const FormatException('Archive is too large');
    }
    final bytes = await input.readAsBytes();
    final directory = archive_pkg.ZipDirectory()
      ..read(archive_pkg.InputMemoryStream(bytes));
    final root = path_utils.canonicalize(output.path);
    final seen = <String>{};
    final verifiedSizes = <String, int>{};
    final headers = <String, archive_pkg.ZipFileHeader>{};
    // Native Venera 1.6 ZIPs have correct central-directory sizes, while
    // archive's lazy entry objects can report zero on every platform.
    // Preflight the directory before decoding content (including symlinks).
    var total = 0;
    for (final entry in directory.fileHeaders) {
      final target = safeTarget(root, entry.filename);
      if (!seen.add(target)) {
        throw const FormatException('Archive contains duplicate entry names');
      }
      if (((entry.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        throw const FormatException('Archive symlinks are not supported');
      }
      final size = entry.uncompressedSize;
      if (size < 0 || size > maxSingleFileBytes) {
        throw const FormatException('Archive entry is too large');
      }
      verifiedSizes[entry.filename] = size;
      headers[entry.filename] = entry;
      total += size;
    }
    checkLimits(
      entries: directory.fileHeaders.length,
      totalBytes: total,
      archiveBytes: archiveBytes,
    );
    final archive = archive_pkg.ZipDecoder().decodeBytes(bytes);
    await output.create(recursive: true);
    for (var index = 0; index < archive.length; index++) {
      final entry = archive[index];
      if (!verifiedSizes.containsKey(entry.name)) {
        throw const FormatException(
          'Archive local and central entry names differ',
        );
      }
      final target = safeTarget(root, entry.name);
      _checkExistingPath(root, target);
      if (entry.isSymbolicLink) {
        throw const FormatException('Archive symlinks are not supported');
      }
      if (entry.isDirectory) {
        await Directory(target).create(recursive: true);
        continue;
      }
      final expectedSize = verifiedSizes[entry.name] ?? entry.size;
      Uint8List? content;
      try {
        content = entry.readBytes();
      } catch (_) {
        content = null;
      }
      // Some archives, including the ones zip_flutter writes, are valid but
      // unreadable through archive's lazy entry objects. The central directory
      // validated above carries each entry's offset and sizes, so read it from
      // there instead of reaching for a native library.
      if (content == null || content.length != expectedSize) {
        final header = headers[entry.name];
        if (header != null) {
          content = readZipEntry(
            bytes,
            localHeaderOffset: header.localHeaderOffset,
            compressedSize: header.compressedSize,
            uncompressedSize: header.uncompressedSize,
            compressionMethod: header.compressionMethod,
          );
        }
      }
      if (content == null || content.length != expectedSize) {
        throw const FormatException('Archive entry could not be read');
      }
      final targetFile = File(target);
      await targetFile.parent.create(recursive: true);
      await targetFile.writeAsBytes(content, flush: true);
    }
  }

  static Future<void> extract7z(File input, Directory output) async {
    final archiveBytes = await input.length();
    if (archiveBytes > maxArchiveBytes) {
      throw const FormatException('Archive is too large');
    }
    // venera_native only bulk-extracts, so unpack into staging first and
    // publish into [output] entry by entry after the safety walk below.
    final staging = await Directory.systemTemp.createTemp('venera-7z-');
    try {
      await extractSevenZip(input.path, staging.path);
      final root = path_utils.canonicalize(output.path);
      final entities = staging.listSync(recursive: true, followLinks: false);
      final seen = <String>{};
      var entries = 0;
      var total = 0;
      for (final entity in entities) {
        final relative = path_utils.relative(entity.path, from: staging.path);
        if (relative == '.') continue;
        entries++;
        if (entity is Link) {
          throw const FormatException('Archive symlinks are not supported');
        }
        if (entity is! File) continue;
        final target = safeTarget(root, relative);
        if (!seen.add(target)) {
          throw const FormatException('Archive contains duplicate entry names');
        }
        final size = entity.lengthSync();
        if (size > maxSingleFileBytes) {
          throw const FormatException('Archive entry is too large');
        }
        total += size;
      }
      checkLimits(
        entries: entries,
        totalBytes: total,
        archiveBytes: archiveBytes,
      );
      await output.create(recursive: true);
      for (final entity in entities) {
        final relative = path_utils.relative(entity.path, from: staging.path);
        if (relative == '.') continue;
        final target = safeTarget(root, relative);
        _checkExistingPath(root, target);
        if (entity is Directory) {
          await Directory(target).create(recursive: true);
        } else if (entity is File) {
          await Directory(path_utils.dirname(target)).create(recursive: true);
          await entity.copy(target);
          if (FileSystemEntity.typeSync(target, followLinks: false) ==
              FileSystemEntityType.link) {
            throw const FormatException('Archive symlinks are not supported');
          }
          final actualLength = await File(target).length();
          if (actualLength != entity.lengthSync()) {
            throw const FormatException('Archive entry size mismatch');
          }
        }
      }
    } finally {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  static Future<void> extract(File input, Directory output) async {
    final header = await input
        .openRead(0, 32)
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final name = input.path.toLowerCase();
    if (header.length >= 2 && header[0] == 0x50 && header[1] == 0x4b) {
      await extractZip(input, output);
    } else if (name.endsWith('.7z') ||
        (header.length >= 6 &&
            header[0] == 0x37 &&
            header[1] == 0x7a &&
            header[2] == 0xbc &&
            header[3] == 0xaf &&
            header[4] == 0x27 &&
            header[5] == 0x1c)) {
      await extract7z(input, output);
    } else {
      throw const FormatException('Unsupported archive type');
    }
  }
}
