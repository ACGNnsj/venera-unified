import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/reader/white_border_crop.dart';
import 'package:venera_unified/foundation/white_border_native.dart';

Uint8List _rgba(int width, int height, {int left = 0, int right = 0}) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      if (x < left || x >= width - right) {
        pixels[o] = 255;
        pixels[o + 1] = 255;
        pixels[o + 2] = 255;
        pixels[o + 3] = 255;
      } else {
        pixels[o] = 32;
        pixels[o + 1] = 64;
        pixels[o + 2] = 96;
        pixels[o + 3] = 255;
      }
    }
  }
  return pixels;
}

bool _requireNative() {
  if (!WhiteBorderNative.available) {
    markTestSkipped('venera_white_border not built for this platform');
    return false;
  }
  return true;
}

void main() {
  group('WhiteBorderNative parity with horizontalWhiteBorderInsets', () {
    test('bordered, dark, over-wide and wide pages', () {
      if (!_requireNative()) return;
      final cases = <(Uint8List, int, int)>[
        (_rgba(100, 160, left: 10, right: 12), 100, 160),
        (_rgba(100, 160), 100, 160),
        (_rgba(100, 160, left: 30, right: 30), 100, 160),
        (_rgba(320, 200, left: 20, right: 8), 320, 200),
        (_rgba(32, 32, left: 2, right: 2), 32, 32),
      ];
      for (final (pixels, w, h) in cases) {
        expect(
          WhiteBorderNative.insetsOrNull(pixels, w, h),
          horizontalWhiteBorderInsets(pixels, w, h),
          reason: 'parity ${w}x$h',
        );
      }
    });

    test('length mismatch mirrors the Dart (0, 0) guard', () {
      if (!_requireNative()) return;
      final pixels = _rgba(100, 160, left: 10, right: 12);
      final short = pixels.sublist(0, 100);
      expect(WhiteBorderNative.insetsOrNull(short, 100, 160), (0, 0));
      expect(horizontalWhiteBorderInsets(short, 100, 160), (0, 0));
    });
  });
}
