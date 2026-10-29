import 'package:flutter_test/flutter_test.dart';

import 'package:venera_unified/features/reader/gallery_view.dart';

void main() {
  test('lays images out left to right with ascending numbers', () {
    expect(galleryPageOrder(['a', 'b'], 4, rightToLeft: false), [
      ('a', 5),
      ('b', 6),
    ]);
  });

  test('lays images out right to left but keeps each image number', () {
    expect(galleryPageOrder(['a', 'b'], 4, rightToLeft: true), [
      ('b', 6),
      ('a', 5),
    ]);
  });

  test('numbers three images from the page start', () {
    expect(galleryPageOrder(['a', 'b', 'c'], 0, rightToLeft: true), [
      ('c', 3),
      ('b', 2),
      ('a', 1),
    ]);
  });
}
