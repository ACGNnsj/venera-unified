import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_utils;
import 'package:venera_unified/foundation/archive_security.dart';

String _withNul(String name) =>
    name.replaceFirst('/', String.fromCharCode(0));

void main() {
  test('limits match prime values', () {
    expect(ArchiveSecurity.maxEntries, 20000);
    expect(ArchiveSecurity.maxSingleFileBytes, 256 * 1024 * 1024);
    expect(ArchiveSecurity.maxTotalBytes, 1024 * 1024 * 1024);
    expect(ArchiveSecurity.maxCompressionRatio, 1000);
    expect(ArchiveSecurity.maxArchiveBytes, 512 * 1024 * 1024);
  });

  test('safeTarget keeps nested entries inside the root', () {
    final root = Directory.systemTemp.createTempSync('archive-root-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final target = ArchiveSecurity.safeTarget(root, 'a/b/c.txt');
    expect(path_utils.isWithin(path_utils.canonicalize(root), target), isTrue);
    expect(target.endsWith(path_utils.join('a', 'b', 'c.txt')), isTrue);
  });

  test('safeTarget normalizes backslashes like prime', () {
    final root = Directory.systemTemp.createTempSync('archive-root-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final forward = ArchiveSecurity.safeTarget(root, 'a/b.txt');
    final backward = ArchiveSecurity.safeTarget(root, 'a\\b.txt');
    expect(backward, forward);
  });

  test('safeTarget rejects invalid absolute and parent entries', () {
    final root = Directory.systemTemp.createTempSync('archive-root-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    expect(
      () => ArchiveSecurity.safeTarget(root, ''),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive contains an invalid entry name',
        ),
      ),
    );
    expect(
      () => ArchiveSecurity.safeTarget(root, _withNul('a/b.txt')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive contains an invalid entry name',
        ),
      ),
    );
    expect(
      () => ArchiveSecurity.safeTarget(root, '/abs/path.txt'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive contains an absolute entry path',
        ),
      ),
    );
    expect(
      () => ArchiveSecurity.safeTarget(root, 'C:/win/path.txt'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive contains an absolute entry path',
        ),
      ),
    );
    expect(
      () => ArchiveSecurity.safeTarget(root, 'a/../../escape.txt'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive contains a parent entry path',
        ),
      ),
    );
  });

  test('checkLimits enforces the preflight rules with prime messages', () {
    expect(
      () => ArchiveSecurity.checkLimits(
        entries: 20001,
        totalBytes: 1,
        archiveBytes: 1,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive contains too many entries',
        ),
      ),
    );
    expect(
      () => ArchiveSecurity.checkLimits(
        entries: 1,
        totalBytes: ArchiveSecurity.maxTotalBytes + 1,
        archiveBytes: 1,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive expands beyond the allowed size',
        ),
      ),
    );
    expect(
      () => ArchiveSecurity.checkLimits(
        entries: 1,
        totalBytes: 1,
        archiveBytes: ArchiveSecurity.maxArchiveBytes + 1,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive is too large',
        ),
      ),
    );
    expect(
      () => ArchiveSecurity.checkLimits(
        entries: 1,
        totalBytes: 1001,
        archiveBytes: 1,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Archive compression ratio is unsafe',
        ),
      ),
    );
    expect(
      () => ArchiveSecurity.checkLimits(
        entries: 20000,
        totalBytes: 1000,
        archiveBytes: 1,
      ),
      returnsNormally,
    );
  });
}
