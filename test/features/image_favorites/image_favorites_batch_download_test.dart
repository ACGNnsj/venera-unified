import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/history/image_favorites_models.dart';
import 'package:venera_unified/features/image_favorites/image_favorites_batch_download.dart';

final _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x00,
]);

ImageFavorite _image({int page = 0}) => ImageFavorite(
  page,
  'image-$page',
  null,
  'ep-1',
  'comic-1',
  1,
  'source',
  'Chapter 1',
);

ImageFavoritesComic _comic(
  List<ImageFavorite> images, {
  String title = 'Comic',
}) => ImageFavoritesComic(
  'comic-1',
  [ImageFavoritesEp('ep-1', 1, images, 'Chapter 1', 10)],
  title,
  'source',
  const [],
  const [],
  DateTime(2026),
  'author',
  const {},
  '',
  10,
);

void main() {
  test('plan keeps only selected images with their comic and chapter', () {
    final first = _image(page: 0);
    final second = _image(page: 1);
    final entries = planImageFavoritesDownload(
      comics: [
        _comic([first, second], title: 'My Comic'),
      ],
      selected: {second: true},
    );

    expect(entries, hasLength(1));
    expect(entries.single.image, same(second));
    expect(entries.single.comicTitle, 'My Comic');
    expect(entries.single.chapterName, 'Chapter 1');
    expect(entries.single.fileName('.png'), 'My Comic - Chapter 1 - 2.png');
  });

  test('plan drops selections that are no longer in the list', () {
    final entries = planImageFavoritesDownload(
      comics: [
        _comic([_image()]),
      ],
      selected: {_image(page: 7): true},
    );

    expect(entries, isEmpty);
  });

  test('file name replaces path separators and keeps the extension', () {
    expect(
      imageFavoritesDownloadFileName(
        comicTitle: 'A/B:C',
        chapterName: 'D',
        page: 0,
        extension: '.jpg',
      ),
      'A B C - D - 1.jpg',
    );
  });

  test(
    'write saves new files, skips existing ones and counts failures',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gallery-download-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final entries = [
        for (final image in [_image(page: 0), _image(page: 1), _image(page: 2)])
          ImageFavoritesDownloadEntry(
            image: image,
            comicTitle: 'Comic',
            chapterName: 'Chapter 1',
          ),
      ];
      File(
        '${directory.path}/Comic - Chapter 1 - 2.png',
      ).writeAsBytesSync(Uint8List(0));

      final progress = <String>[];
      final result = await writeImageFavorites(
        directory: directory,
        entries: entries,
        checkStop: () {},
        cancelSignal: Completer<void>().future,
        onProgress: (done, total) => progress.add('$done/$total'),
        read: (image, checkStop, cancelSignal) async {
          if (image.page == 2) throw const SocketException('offline');
          return _png;
        },
      );

      expect(result.saved, 1);
      expect(result.skipped, 1);
      expect(result.failed, 1);
      expect(result.cancelled, isFalse);
      expect(progress, ['1/3', '2/3', '3/3']);
      expect(
        File('${directory.path}/Comic - Chapter 1 - 1.png').lengthSync(),
        _png.length,
      );
    },
  );

  test('write stops when the user cancels', () async {
    final directory = await Directory.systemTemp.createTemp('gallery-cancel-');
    addTearDown(() => directory.delete(recursive: true));
    var cancelled = false;
    final result = await writeImageFavorites(
      directory: directory,
      entries: [
        for (final image in [_image(page: 0), _image(page: 1)])
          ImageFavoritesDownloadEntry(
            image: image,
            comicTitle: 'Comic',
            chapterName: 'Chapter 1',
          ),
      ],
      checkStop: () {
        if (cancelled) throw const ImageFavoritesDownloadCancelled();
      },
      cancelSignal: Completer<void>().future,
      isCancelled: () => cancelled,
      onProgress: (done, total) => cancelled = true,
      read: (image, checkStop, cancelSignal) async => _png,
    );

    expect(result.saved, 1);
    expect(result.cancelled, isTrue);
    expect(directory.listSync(), hasLength(1));
  });
}
