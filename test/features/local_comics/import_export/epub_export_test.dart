import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/local_comics/import_export/epub.dart';
import 'package:venera_unified/features/local_comics/local_comics.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/comic_type.dart';
import 'package:xml/xml.dart';

import '../../../support/sqlite_test_environment.dart';

void main() {
  test(
    'concurrent EPUB exports retain every image and resolve manifest paths',
    () async {
      final root = await Directory.systemTemp.createTemp('epub-export-');
      try {
        final bytes = Uint8List.fromList(
          List.generate(512 * 1024, (i) => i % 251),
        );
        final image = File('${root.path}/image.jpg')..writeAsBytesSync(bytes);
        final data = EpubData(
          title: 'A & B',
          author: 'C < D',
          cover: image,
          chapters: {
            'Chapter 1 & 2': [image, image],
          },
        );
        final outputs = await Future.wait([
          for (var i = 0; i < 2; i++)
            createEpubComic(data, root.path, '${root.path}/book$i.epub'),
        ]);
        for (final output in outputs) {
          final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
          for (final name in ['cover.jpg', 'img0.jpg', 'img1.jpg']) {
            expect(archive.find('OEBPS/images/$name')!.readBytes(), bytes);
          }
          final document = XmlDocument.parse(
            String.fromCharCodes(archive.find('content.opf')!.readBytes()!),
          );
          for (final item in document.findAllElements('item')) {
            expect(archive.find(item.getAttribute('href')!), isNotNull);
          }
          expect(
            document.findAllElements('dc:title').single.innerText,
            'A & B',
          );
        }
        // Private staging dirs must not survive their export.
        final leftovers = root
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('epub-'))
            .toList();
        expect(leftovers, isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('directory size sums every file for export stats', () async {
    if (!sqliteTestAvailable()) return;
    final root = Directory.systemTemp.createTempSync('epub-size-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalManager.current?.dispose();
    LocalManager(initializeSources: () async {});
    final manager = LocalManager();
    await manager.init();
    try {
      final book = Directory('${manager.path}/book')..createSync();
      File('${book.path}/cover.jpg').writeAsBytesSync(const [1, 2, 3]);
      File('${book.path}/p1.jpg').writeAsBytesSync(const [4, 5]);
      final comic = LocalComic(
        id: 'sized',
        title: 'Sized',
        subtitle: '',
        tags: const [],
        directory: 'book',
        chapters: null,
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime(2026, 1, 1),
      );
      expect(await localComicDirectorySize(comic), 5);
    } finally {
      manager.dispose();
      root.deleteSync(recursive: true);
    }
  });
}
