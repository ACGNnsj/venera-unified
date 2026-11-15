import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/settings/upscale_preview.dart';

void main() {
  test('band fills a 4:3 page exactly', () {
    expect(previewBandRect(480, 360), const Rect.fromLTWH(0, 0, 480, 360));
  });

  test('long strip centers a 4:3 band', () {
    // 800-wide strip: band is 800x600, vertically centred.
    expect(previewBandRect(800, 12000), const Rect.fromLTWH(0, 5700, 800, 600));
  });

  test('wide page centers a 4:3 band', () {
    // 800-tall page: band is ~1066x800, horizontally centred.
    final band = previewBandRect(12000, 800);
    expect(band.height, 800);
    expect(band.width, moreOrLessEquals(800 * 4 / 3, epsilon: 1));
    expect(band.left, moreOrLessEquals((12000 - band.width) / 2, epsilon: 1));
    expect(band.top, 0);
  });
}
