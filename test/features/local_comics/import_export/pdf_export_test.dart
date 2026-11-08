import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/local_comics/import_export/pdf.dart';
import 'package:venera_unified/foundation/image_processing.dart';

int _indexOfBytes(Uint8List haystack, String needle, [int from = 0]) =>
    latin1.decode(haystack).indexOf(needle, from);

/// Pulls the bytes of the first /Filter /FlateDecode image stream.
Uint8List _firstFlateStream(Uint8List pdf) {
  final filterAt = _indexOfBytes(pdf, '/Filter /FlateDecode');
  expect(filterAt, isNonNegative, reason: 'image stream should be deflated');
  final text = latin1.decode(pdf);
  final lengthAt = text.indexOf('/Length ', filterAt) + '/Length '.length;
  var end = lengthAt;
  while (end < text.length &&
      text.codeUnitAt(end) >= 0x30 &&
      text.codeUnitAt(end) <= 0x39) {
    end++;
  }
  final length = int.parse(text.substring(lengthAt, end));
  final streamAt = text.indexOf('stream\n', lengthAt) + 'stream\n'.length;
  return pdf.sublist(streamAt, streamAt + length);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pdf-export-');
  });

  tearDown(() async {
    if (!tempDir.existsSync()) return;
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // A failed run may leave the output stream open; the OS temp dir
      // reclaims it later.
    }
  });

  test('packs every page image as a zlib stream of raw RGB bytes', () async {
    // Image packs pixels as 0xAABBGGRR, so these are blue, green, red, white.
    final pixels = Uint32List.fromList([
      0xFFFF0000,
      0xFF00FF00,
      0xFF0000FF,
      0xFFFFFFFF,
    ]);
    final pages = <String>[];
    for (final name in ['p1.jpg', 'p2.jpg']) {
      final file = File('${tempDir.path}/$name')
        ..writeAsBytesSync(const [1, 2, 3]);
      pages.add(file.path);
    }
    final outputPath = '${tempDir.path}/out.pdf';
    final generator = PdfGenerator(
      title: 'Fixture',
      author: 'tests',
      imagePaths: pages,
      outputPath: outputPath,
      decodeImage: (bytes) async => Image(pixels, 2, 2),
    );

    await generator.generate();

    final pdf = File(outputPath).readAsBytesSync();
    expect(latin1.decode(pdf.sublist(0, 8)), '%PDF-1.7');
    expect(latin1.decode(pdf), contains('/Count 2'));

    // dart:io zlib (RFC 1950) is what /FlateDecode expects; the native miniz
    // helper this used to call is missing on platforms such as ohos.
    final stream = _firstFlateStream(pdf);
    expect(ZLibDecoder().convert(stream), [
      0, 0, 255, //
      0, 255, 0,
      255, 0, 0,
      255, 255, 255,
    ]);
  });
}
