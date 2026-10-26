import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/reader/current_image.dart';

void main() {
  const viewport = Rect.fromLTWH(0, 0, 400, 600);
  ReaderVisibleImage image(int index, double top, double bottom) =>
      (index: index, bounds: Rect.fromLTRB(0, top, 400, bottom));

  test('the dominant image is the same in either enumeration direction', () {
    for (final offset in [100.0, 250.0, 350.0, 500.0]) {
      final images = [image(1, offset - 800, offset), image(2, offset, 1400)];
      final expected = offset < 300 ? 2 : 1;
      for (final ordered in [images, images.reversed]) {
        expect(
          resolveCurrentReaderImage(images: ordered, viewport: viewport),
          expected,
        );
      }
    }
  });

  test('compares viewport area rather than each image visibility ratio', () {
    expect(
      resolveCurrentReaderImage(
        images: [image(1, -1200, 500), image(2, 500, 600)],
        viewport: viewport,
      ),
      1,
    );
  });

  test('does not force the last short image when the list reaches its end', () {
    expect(
      resolveCurrentReaderImage(
        images: [image(8, -200, 450), image(9, 450, 500), image(10, 500, 550)],
        viewport: viewport,
        currentIndex: 10,
      ),
      8,
    );
  });

  test(
    'equal areas retain the requested page before preferring the center',
    () {
      final images = [image(1, 0, 200), image(2, 200, 400), image(3, 400, 600)];
      for (final ordered in [images, images.reversed]) {
        for (final current in [null, 1, 2, 3, 4]) {
          expect(
            resolveCurrentReaderImage(
              images: ordered,
              viewport: viewport,
              currentIndex: current,
            ),
            current != null && current <= 3 ? current : 2,
          );
        }
      }
    },
  );

  test('exact ties retain the page or use a deterministic index', () {
    final images = [image(1, -400, 300), image(2, 300, 1000)];
    for (final ordered in [images, images.reversed]) {
      for (final current in [null, 1, 2, 3]) {
        expect(
          resolveCurrentReaderImage(
            images: ordered,
            viewport: viewport,
            currentIndex: current,
          ),
          current == 2 ? 2 : 1,
        );
      }
    }
  });

  test('horizontal and mirrored viewports use the same occupied area', () {
    const images = [
      (index: 1, bounds: Rect.fromLTRB(-100, 0, 80, 600)),
      (index: 2, bounds: Rect.fromLTRB(80, 0, 600, 600)),
    ];
    expect(resolveCurrentReaderImage(images: images, viewport: viewport), 2);
    expect(
      resolveCurrentReaderImage(
        images: images.map(
          (image) => (
            index: image.index,
            bounds: Rect.fromLTRB(
              400 - image.bounds.right,
              0,
              400 - image.bounds.left,
              600,
            ),
          ),
        ),
        viewport: viewport,
      ),
      2,
    );
  });

  test(
    'clips transformed images to the reader rather than the whole screen',
    () {
      expect(
        resolveCurrentReaderImage(
          images: [image(1, -800, 300), image(2, 300, 900)],
          viewport: const Rect.fromLTWH(50, 200, 300, 400),
        ),
        2,
      );
    },
  );

  test('uses both dimensions for partly offscreen zoomed images', () {
    expect(
      resolveCurrentReaderImage(
        images: const [
          (index: 1, bounds: Rect.fromLTWH(-350, 0, 400, 400)),
          (index: 2, bounds: Rect.fromLTWH(0, 400, 400, 200)),
        ],
        viewport: viewport,
      ),
      2,
    );
  });

  test('ignores empty, offscreen, invalid and non-image entries', () {
    expect(
      resolveCurrentReaderImage(
        images: [
          image(0, 0, 600),
          image(-1, 0, 600),
          image(1, -600, 0),
          image(2, 600, 1200),
          image(3, 250, 250),
          image(4, double.nan, 500),
          image(5, 0, double.infinity),
          image(6, 300, 200),
        ],
        viewport: viewport,
      ),
      isNull,
    );
    for (final invalid in [
      Rect.zero,
      const Rect.fromLTWH(0, 0, double.infinity, 600),
    ]) {
      expect(
        resolveCurrentReaderImage(
          images: [image(1, 0, 600)],
          viewport: invalid,
        ),
        isNull,
      );
    }
  });
}
