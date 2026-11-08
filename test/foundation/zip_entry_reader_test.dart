import 'dart:typed_data';

import 'package:archive/archive.dart' as archive_pkg;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/zip_entry_reader.dart';

Uint8List _buildZip(Map<String, List<int>> files, {bool store = false}) {
  final archive = archive_pkg.Archive();
  files.forEach((name, bytes) {
    final file = archive_pkg.ArchiveFile(name, bytes.length, bytes);
    if (store) {
      file.compression = archive_pkg.CompressionType.none;
    }
    archive.addFile(file);
  });
  return archive_pkg.ZipEncoder().encodeBytes(archive);
}

archive_pkg.ZipFileHeader _header(Uint8List zip, String name) {
  final directory = archive_pkg.ZipDirectory()
    ..read(archive_pkg.InputMemoryStream(zip));
  return directory.fileHeaders.firstWhere((header) => header.filename == name);
}

Uint8List _readEntry(Uint8List zip, String name) {
  final header = _header(zip, name);
  return readZipEntry(
    zip,
    localHeaderOffset: header.localHeaderOffset,
    compressedSize: header.compressedSize,
    uncompressedSize: header.uncompressedSize,
    compressionMethod: header.compressionMethod,
  );
}

void main() {
  test('reads a deflated entry from its central directory offsets', () {
    final source = Uint8List.fromList(List.generate(4096, (i) => i % 251));
    final zip = _buildZip({'page/0001.jpg': source});

    expect(_readEntry(zip, 'page/0001.jpg'), source);
  });

  test('reads a stored entry without inflating it', () {
    final source = Uint8List.fromList(List.generate(512, (i) => i % 97));
    final zip = _buildZip({'mimetype': source}, store: true);
    expect(_header(zip, 'mimetype').compressionMethod, 0);

    expect(_readEntry(zip, 'mimetype'), source);
  });

  test('rejects a local header that is not a zip entry', () {
    final zip = _buildZip({
      'page.jpg': Uint8List.fromList([1, 2, 3, 4]),
    });
    final header = _header(zip, 'page.jpg');
    zip[header.localHeaderOffset] = 0;

    expect(() => _readEntry(zip, 'page.jpg'), throwsFormatException);
  });

  test('rejects an entry whose inflated size does not match', () {
    final source = Uint8List.fromList(List.generate(1024, (i) => i % 13));
    final zip = _buildZip({'page.jpg': source});
    final header = _header(zip, 'page.jpg');

    expect(
      () => readZipEntry(
        zip,
        localHeaderOffset: header.localHeaderOffset,
        compressedSize: header.compressedSize,
        uncompressedSize: 1,
        compressionMethod: header.compressionMethod,
      ),
      throwsFormatException,
    );
  });

  test('rejects encrypted entries before reading their data', () {
    final zip = _buildZip({
      'page.jpg': Uint8List.fromList([9, 8, 7]),
    });
    final header = _header(zip, 'page.jpg');
    zip[header.localHeaderOffset + 6] = 0x01;

    expect(
      () => _readEntry(zip, 'page.jpg'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Encrypted'),
        ),
      ),
    );
  });

  test('rejects compression methods it cannot decode', () {
    final zip = _buildZip({
      'page.jpg': Uint8List.fromList([1, 2, 3]),
    });
    final header = _header(zip, 'page.jpg');

    expect(
      () => readZipEntry(
        zip,
        localHeaderOffset: header.localHeaderOffset,
        compressedSize: header.compressedSize,
        uncompressedSize: header.uncompressedSize,
        compressionMethod: 12,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Unsupported'),
        ),
      ),
    );
  });
}
