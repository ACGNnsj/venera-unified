import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_translation/ocr_types.dart';
import 'package:venera_unified/foundation/image_translation/ocr_worker.dart';

// Host diagnostic, not a benchmark for marketing: establishes the Dart
// baseline for the ocr_preprocess Rust migration (resize/normalize/ctc/dedup,
// fixed seed, synthetic manga-ish pixels). ORT inference is not on this path,
// so there is no ORT time to exclude.
int _seed = 0x51ab3d77;
int _nextRand(int bound) {
  _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
  return _seed % bound;
}

double _ms(Stopwatch c) => c.elapsedMicroseconds / 1000;

RgbaImage _mangaTile(int w, int h) {
  final pixels = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      var v = 190 + ((x + y) % 60);
      if ((x % 6 == 0) && (y % 6 == 0)) v -= 70;
      pixels[i] = v;
      pixels[i + 1] = v;
      pixels[i + 2] = v - 8;
      pixels[i + 3] = 255;
    }
  }
  // White bubble with dark glyph bars so the tile is not uniform.
  final bl = w ~/ 8, bt = h ~/ 10, br = bl + 420, bb = bt + 180;
  for (var y = bt; y < bb; y++) {
    for (var x = bl; x < br; x++) {
      final i = (y * w + x) * 4;
      pixels[i] = 255;
      pixels[i + 1] = 255;
      pixels[i + 2] = 255;
    }
  }
  for (var line = 0; line < 4; line++) {
    final gy = bt + 18 + line * 36;
    var gx = bl + 14 + _nextRand(24);
    while (gx < br - 36) {
      final gw = 16 + _nextRand(40);
      for (var y = gy; y < gy + 14 && y < bb - 8; y++) {
        for (var x = gx; x < gx + gw && x < br - 8; x++) {
          final i = (y * w + x) * 4;
          pixels[i] = 18;
          pixels[i + 1] = 18;
          pixels[i + 2] = 18;
        }
      }
      gx += gw + 8 + _nextRand(20);
    }
  }
  return RgbaImage(w, h, pixels);
}

void main() {
  test('ocr Dart baseline probe', () {
    const w = 800, h = 1200;
    const classes = 97, steps = 160;
    final charset = [
      for (var i = 0; i < classes; i++) String.fromCharCode(0x4E00 + i),
    ];
    const runs = 5;
    for (var run = -1; run < runs; run++) {
      _seed = 0x51ab3d77;
      final tile = _mangaTile(w, h);

      final detClock = Stopwatch()..start();
      final det = detPreprocessForTest(tile);
      detClock.stop();

      final lineClock = Stopwatch()..start();
      final resized = resizeRegionForTest(
        tile,
        IntRect(w ~/ 8, h ~/ 10, w ~/ 8 + 420, h ~/ 10 + 180),
        384,
        48,
      );
      final norm = normalizeForTest(resized, 384, 48);
      lineClock.stop();

      final probs = Float32List(steps * classes);
      for (var t = 0; t < steps; t++) {
        final peak = 1 + _nextRand(classes - 1);
        for (var cc = 0; cc < classes; cc++) {
          probs[t * classes + cc] = cc == peak ? 0.9 : 0.001 * _nextRand(100);
        }
      }
      final ctcClock = Stopwatch()..start();
      final text = ctcDecodeForTest(probs, classes, charset);
      ctcClock.stop();

      final boxes = [
        for (var i = 0; i < 240; i++)
          IntRect(
            _nextRand(w - 60),
            _nextRand(h - 40),
            _nextRand(w - 60) + 40,
            _nextRand(h - 40) + 24,
          ),
      ];
      for (final b in boxes) {
        if (b.right <= b.left) b.right = b.left + 40;
        if (b.bottom <= b.top) b.top = (b.top - 24).clamp(0, h - 25);
        if (b.bottom <= b.top) b.bottom = b.top + 24;
      }
      final dedupClock = Stopwatch()..start();
      final kept = dedupBoxesForTest(boxes);
      dedupClock.stop();

      expect(det.tensor.length, det.width * det.height * 3);
      expect(norm.length, 3 * 48 * 384);
      expect(text, isNotEmpty);
      expect(kept, isNotEmpty);
      if (run < 0) continue; // warm-up
      // ignore: avoid_print
      print(
        jsonEncode({
          'probe': 'ocr_baseline',
          'detMs': _ms(detClock),
          'lineMs': _ms(lineClock),
          'ctcMs': _ms(ctcClock),
          'dedupMs': _ms(dedupClock),
          'totalMs':
              _ms(detClock) + _ms(lineClock) + _ms(ctcClock) + _ms(dedupClock),
          'detW': det.width,
          'detH': det.height,
          'kept': kept.length,
          'run': run,
        }),
      );
    }
  });
}
