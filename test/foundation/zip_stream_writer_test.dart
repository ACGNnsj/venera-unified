import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' as archive_io;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/zip_stream_writer.dart';

void main() {
  test('streams a directory with mimetype stored first', () async {
    final work = await Directory.systemTemp.createTemp('zip_stream_writer_');
    try {
      final src = Directory('${work.path}/src')..createSync(recursive: true);
      File('${src.path}/mimetype').writeAsStringSync('application/epub+zip');
      final page = File('${src.path}/OEBPS/page.html')
        ..createSync(recursive: true)
        ..writeAsStringSync('<p>page</p>');
      expect(page.existsSync(), isTrue);
      File('${src.path}/cover.png').writeAsBytesSync(const [1, 2, 3]);
      final out = '${work.path}/out.zip';
      await ZipStreamWriter.writeDirectory(src.path, out);
      final bytes = await File(out).readAsBytes();
      expect(bytes[8] | (bytes[9] << 8), 0);
      final archive = archive_io.ZipDecoder().decodeBytes(bytes);
      expect(archive.files.map((file) => file.name).toList(), [
        'mimetype',
        'OEBPS/page.html',
        'cover.png',
      ]);
      expect(
        archive.findFile('mimetype')!.content as List<int>,
        'application/epub+zip'.codeUnits,
      );
      expect(
        archive.findFile('OEBPS/page.html')!.content as List<int>,
        '<p>page</p>'.codeUnits,
      );
      expect(archive.findFile('cover.png')!.content as List<int>, [1, 2, 3]);
    } finally {
      await work.delete(recursive: true);
    }
  });

  test('stored and deflated sink entries round-trip', () async {
    final work = await Directory.systemTemp.createTemp('zip_stream_sink_');
    try {
      final out = '${work.path}/sink.zip';
      final sink = await ZipStreamWriter.openSink(out);
      final payload = Uint8List.fromList(
        List<int>.generate(4096, (i) => i % 251),
      );
      await sink.addStored(
        'mimetype',
        Uint8List.fromList('application/epub+zip'.codeUnits),
      );
      await sink.addDeflated('OEBPS/images/img0.jpg', payload);
      await sink.close();
      final bytes = await File(out).readAsBytes();
      expect(bytes[8] | (bytes[9] << 8), 0);
      final archive = archive_io.ZipDecoder().decodeBytes(bytes);
      expect(
        archive.findFile('OEBPS/images/img0.jpg')!.content as List<int>,
        payload,
      );
    } finally {
      await work.delete(recursive: true);
    }
  });
}
