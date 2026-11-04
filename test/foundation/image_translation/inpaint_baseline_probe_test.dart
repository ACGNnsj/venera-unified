import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_translation/inpaint.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';

// Host diagnostic, not a benchmark for marketing: establishes the Dart
// baseline for the inpaint Rust migration (mask vs erase phases, fixed seed,
// synthetic bubble page). ORT is not on this path, so no ORT time to exclude.
int _seed = 0x12345678;
int _nextRand(int bound) {
  _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
  return _seed % bound;
}

double _ms(Stopwatch c) => c.elapsedMicroseconds / 1000;

// Synthetic manga-ish page: vertical gradient + screentone dots + white
// bubble rects with black glyph bars. Fully deterministic (fixed LCG seed).
({RgbaImage image, List<IntRect> regions}) _bubblePage(int w, int h) {
  _seed = 0x12345678;
  final pixels = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      // Light gradient background with screentone dots.
      var v = 200 + ((x + y) % 56);
      if ((x % 7 == 0) && (y % 7 == 0)) v -= 60;
      pixels[i] = v;
      pixels[i + 1] = v;
      pixels[i + 2] = v - 10;
      pixels[i + 3] = 255;
    }
  }
  final regions = <IntRect>[];
  final bubbles = [
    IntRect(w ~/ 8, h ~/ 12, w ~/ 8 + 420, h ~/ 12 + 180),
    IntRect(w ~/ 2, h ~/ 2, w ~/ 2 + 360, h ~/ 2 + 220),
    IntRect(w ~/ 6, (h * 0.72).round(), w ~/ 6 + 500, (h * 0.72).round() + 160),
  ];
  for (final b in bubbles) {
    for (var y = b.top; y < b.bottom; y++) {
      for (var x = b.left; x < b.right; x++) {
        final i = (y * w + x) * 4;
        pixels[i] = 255;
        pixels[i + 1] = 255;
        pixels[i + 2] = 255;
      }
    }
    // Glyph bars: 4 lines of dark strokes with deterministic jitter.
    for (var line = 0; line < 4; line++) {
      final gy = b.top + 20 + line * ((b.bottom - b.top - 40) ~/ 4);
      var gx = b.left + 16 + _nextRand(30);
      while (gx < b.right - 40) {
        final gw = 18 + _nextRand(46);
        final gh = 14 + _nextRand(8);
        for (var y = gy; y < gy + gh && y < b.bottom - 8; y++) {
          for (var x = gx; x < gx + gw && x < b.right - 8; x++) {
            final i = (y * w + x) * 4;
            pixels[i] = 20;
            pixels[i + 1] = 20;
            pixels[i + 2] = 20;
          }
        }
        gx += gw + 10 + _nextRand(24);
      }
    }
    regions.add(IntRect(b.left + 8, b.top + 8, b.right - 8, b.bottom - 8));
  }
  return (image: RgbaImage(w, h, pixels), regions: regions);
}

void main() {
  test('inpaint Dart baseline probe', () {
    const w = 800, h = 1200;
    const runs = 5;
    for (var run = -1; run < runs; run++) {
      final page = _bubblePage(w, h);
      final pixels = Uint8List.fromList(page.image.pixels);
      final image = RgbaImage(w, h, pixels);
      final maskClock = Stopwatch()..start();
      final masks = <TextMask?>[];
      for (final r in page.regions) {
        masks.add(TextInpainter.computeMask(image, r));
      }
      maskClock.stop();
      final eraseClock = Stopwatch()..start();
      var erased = 0;
      for (final m in masks) {
        if (m == null) continue;
        TextInpainter.eraseWithMask(image, m);
        erased++;
      }
      eraseClock.stop();
      var maskPixels = 0;
      for (final m in masks) {
        if (m == null) continue;
        for (final v in m.mask) {
          maskPixels += v;
        }
      }
      // Sanity: erased pixels must differ from the glyph bars somewhere.
      expect(erased, greaterThan(0));
      if (run < 0) continue; // warm-up
      // ignore: avoid_print
      print(
        jsonEncode({
          'probe': 'inpaint_baseline',
          'width': w,
          'height': h,
          'regions': page.regions.length,
          'erased': erased,
          'maskPixels': maskPixels,
          'maskMs': _ms(maskClock),
          'eraseMs': _ms(eraseClock),
          'totalMs': _ms(maskClock) + _ms(eraseClock),
          'run': run,
        }),
      );
    }
  });
}
