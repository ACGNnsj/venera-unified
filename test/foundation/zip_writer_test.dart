import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart' as archive_io;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/zip_writer.dart';

void main() {
  late Directory work;

  setUp(() {
    work = Directory.systemTemp.createTempSync('zip_writer_test_');
  });

  tearDown(() {
    if (work.existsSync()) {
      work.deleteSync(recursive: true);
    }
  });

  File writeFile(String directory, String name, String content) {
    final file = File('$directory/$name');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  String readEntry(String archivePath, String name) {
    final archive = archive_io.ZipDecoder().decodeBytes(
      File(archivePath).readAsBytesSync(),
    );
    final file = archive.findFile(name);
    expect(file, isNotNull, reason: 'missing entry $name');
    return utf8.decode(file!.content as List<int>);
  }

  test('uses the native writer when it succeeds', () async {
    final source = Directory('${work.path}/source')..createSync();
    writeFile(source.path, 'page.jpg', 'native input');
    final destination = '${work.path}/native.zip';
    var calls = 0;

    await writeZipFromDirectory(
      source.path,
      destination,
      nativeCompressor: (source, target) async {
        calls++;
        File(target).writeAsStringSync('native writer output');
      },
    );

    expect(calls, 1);
    expect(File(destination).readAsStringSync(), 'native writer output');
  });

  test(
    'falls back to the Dart encoder when the native writer throws',
    () async {
      final source = Directory('${work.path}/source')..createSync();
      writeFile(source.path, 'cover.png', 'cover bytes');
      writeFile(source.path, 'mimetype', 'application/epub+zip');
      writeFile(source.path, 'OEBPS/page.html', '<p>page</p>');
      final destination = '${work.path}/fallback.zip';

      await writeZipFromDirectory(
        source.path,
        destination,
        nativeCompressor: (source, target) async {
          File(target).writeAsStringSync('partial archive');
          throw UnsupportedError('Unknown platform: ohos');
        },
      );

      final archive = archive_io.ZipDecoder().decodeBytes(
        File(destination).readAsBytesSync(),
      );
      expect(archive.files.map((file) => file.name), [
        'mimetype',
        'OEBPS/page.html',
        'cover.png',
      ]);
      expect(readEntry(destination, 'mimetype'), 'application/epub+zip');
      expect(readEntry(destination, 'OEBPS/page.html'), '<p>page</p>');
      expect(readEntry(destination, 'cover.png'), 'cover bytes');
    },
  );

  test('keeps nested entries with forward slashes', () async {
    final source = Directory('${work.path}/source')..createSync();
    writeFile(source.path, 'a/b/c/deep.txt', 'deep');
    final destination = '${work.path}/nested.zip';

    await writeZipFromDirectory(
      source.path,
      destination,
      nativeCompressor: (source, target) async {
        throw UnsupportedError('Unknown platform: ohos');
      },
    );

    expect(readEntry(destination, 'a/b/c/deep.txt'), 'deep');
  });
}
