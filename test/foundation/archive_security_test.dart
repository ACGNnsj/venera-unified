import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive_pkg;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_utils;
import 'package:venera_unified/foundation/archive_security.dart';

String _withNul(String name) => name.replaceFirst('/', String.fromCharCode(0));

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

  group('extractZip streaming', () {
    test('writes byte-identical entries for mixed content', () async {
      final sources = <String, List<int>>{
        'page/0001.jpg': List<int>.generate(4096, (i) => i % 251),
        'page/0002.jpg': List<int>.generate(512, (i) => i % 97),
        '猫之眼/第01卷/001.jpg': List<int>.generate(1024, (i) => i % 13),
        'empty.txt': <int>[],
      };
      final archive = archive_pkg.Archive();
      for (final source in sources.entries) {
        archive.addFile(
          archive_pkg.ArchiveFile.bytes(source.key, source.value),
        );
      }
      archive.addFile(archive_pkg.ArchiveFile.directory('docs/'));
      final root = Directory.systemTemp.createTempSync('archive-parity-');
      addTearDown(() => root.deleteSync(recursive: true));
      final input = File('${root.path}/book.cbz')
        ..writeAsBytesSync(archive_pkg.ZipEncoder().encodeBytes(archive));
      final out = Directory('${root.path}/out')..createSync();

      await ArchiveSecurity.extractZip(input, out);

      for (final source in sources.entries) {
        expect(
          File('${out.path}/${source.key}').readAsBytesSync(),
          source.value,
          reason: source.key,
        );
      }
      expect(Directory('${out.path}/docs').existsSync(), isTrue);
      expect(
        out
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) => path_utils.relative(file.path, from: out.path))
            .toSet(),
        sources.keys.map((name) => path_utils.joinAll(name.split('/'))).toSet(),
      );
    });

    test(
      'holds far less than full retention for long packages',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        // 16 x 20MB entries at ~10:1 deflate (2MB LCG-random head, zeros
        // after): the decoded total (320MB) dwarfs any single entry, so the
        // gap between "retain every decoded entry" and "stream one entry at
        // a time" is structural, not codec-dependent. LCG output is
        // incompressible (unlike arithmetic progressions, which deflate to
        // almost nothing and would fake a long package).
        const entries = 16;
        const entryBytes = 20 * 1024 * 1024;
        const headBytes = 2 * 1024 * 1024;
        final archive = archive_pkg.Archive();
        for (var i = 0; i < entries; i++) {
          final payload = Uint8List(entryBytes);
          var state = 0x12345678 + i;
          for (var j = 0; j < headBytes; j++) {
            state = (state * 1103515245 + 12345) & 0x7fffffff;
            payload[j] = (state >> 16) & 0xff;
          }
          archive.addFile(
            archive_pkg.ArchiveFile.bytes(
              'page/${i.toString().padLeft(4, '0')}.jpg',
              payload,
            ),
          );
        }
        final root = Directory.systemTemp.createTempSync('archive-memory-');
        addTearDown(() => root.deleteSync(recursive: true));
        final input = File('${root.path}/long.cbz')
          ..writeAsBytesSync(archive_pkg.ZipEncoder().encodeBytes(archive));

        Future<int> growthDuring(Future<void> Function() work) async {
          final before = ProcessInfo.currentRss;
          var peak = before;
          final sampler = Timer.periodic(const Duration(milliseconds: 10), (_) {
            final rss = ProcessInfo.currentRss;
            if (rss > peak) peak = rss;
          });
          try {
            await work();
          } finally {
            sampler.cancel();
          }
          return peak - before;
        }

        // Pin the heap with far more than the encoder's transient garbage so
        // the extraction cannot hide inside reusable free pages: it must grow
        // fresh pages for whatever it actually retains.
        final ballastBytes =
            await input.length() + entries * entryBytes + 128 * 1024 * 1024;
        final ballast = Uint8List(ballastBytes)..fillRange(0, ballastBytes, 1);
        final streamOut = Directory('${root.path}/streamed')..createSync();
        final streamGrowth = await growthDuring(() async {
          await ArchiveSecurity.extractZip(input, streamOut);
        });

        // Structural need is ~34MB compressed + one 20MB entry at a time; a
        // retaining loop would need ~354MB (compressed + decoded total). The
        // 150MB bound catches that with wide margins: normal heap headroom
        // can only hide tens of MB, never hundreds.
        expect(
          streamGrowth,
          lessThan(150 * 1024 * 1024),
          reason: 'stream=$streamGrowth ballast=${ballast.length}',
        );
        final streamFiles = streamOut
            .listSync(recursive: true)
            .whereType<File>()
            .toList();
        expect(streamFiles, hasLength(entries));
        var streamTotal = 0;
        for (final file in streamFiles) {
          streamTotal += file.lengthSync();
        }
        expect(streamTotal, entries * entryBytes);
      },
    );
  });
}
