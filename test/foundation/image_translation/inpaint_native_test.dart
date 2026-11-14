import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_translation/inpaint.dart';
import 'package:venera_unified/foundation/image_translation/inpaint_native.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';

// Pixel-equality + timing double assertion for the Rust inpaint migration.
// Skips when the dev library is not built (CI without native/inpaint/target);
// the Dart pure functions in inpaint.dart remain the fallback.
int _seed = 0x9e3779b9;
int _nextRand(int bound) {
  _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
  return _seed % bound;
}

double _ms(Stopwatch c) => c.elapsedMicroseconds / 1000;

({RgbaImage image, List<IntRect> regions}) _bubblePage(int w, int h) {
  _seed = 0x9e3779b9;
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
  final regions = <IntRect>[];
  final bubbles = [
    IntRect(w ~/ 10, h ~/ 14, w ~/ 10 + 380, h ~/ 14 + 170),
    IntRect(w ~/ 2, h ~/ 2, w ~/ 2 + 340, h ~/ 2 + 200),
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
    for (var line = 0; line < 4; line++) {
      final gy = b.top + 18 + line * ((b.bottom - b.top - 36) ~/ 4);
      var gx = b.left + 14 + _nextRand(24);
      while (gx < b.right - 36) {
        final gw = 16 + _nextRand(40);
        final gh = 12 + _nextRand(8);
        for (var y = gy; y < gy + gh && y < b.bottom - 8; y++) {
          for (var x = gx; x < gx + gw && x < b.right - 8; x++) {
            final i = (y * w + x) * 4;
            pixels[i] = 18;
            pixels[i + 1] = 18;
            pixels[i + 2] = 18;
          }
        }
        gx += gw + 8 + _nextRand(20);
      }
    }
    regions.add(IntRect(b.left + 8, b.top + 8, b.right - 8, b.bottom - 8));
  }
  // Degenerate cases: both implementations must agree on null.
  regions.add(IntRect(4, 4, 8, 8)); // too small
  regions.add(IntRect(0, 0, w, h)); // near-uniform full page
  return (image: RgbaImage(w, h, pixels), regions: regions);
}

void main() {
  test('inpaint native matches Dart pixels and is >=2x faster', () {
    if (!InpaintNative.available) {
      markTestSkipped('venera_inpaint not built for this platform');
      return;
    }
    expect(InpaintNative.version(), 1);

    const w = 800, h = 1200;
    final page = _bubblePage(w, h);

    // 1) Mask equality (null-ness, window, bytes).
    final dartMasks = <TextMask?>[];
    final nativeMasks = <TextMask?>[];
    for (final r in page.regions) {
      dartMasks.add(TextInpainter.computeMask(page.image, r));
      nativeMasks.add(InpaintNative.computeMask(page.image, r));
    }
    for (var k = 0; k < page.regions.length; k++) {
      final d = dartMasks[k], n = nativeMasks[k];
      expect(n == null, d == null, reason: 'null mismatch region $k');
      if (d == null) continue;
      expect((n!.left, n.top, n.rw, n.rh), (d.left, d.top, d.rw, d.rh));
      expect(n.mask, orderedEquals(d.mask), reason: 'mask bytes $k');
    }
    final pairs = [
      for (var k = 0; k < dartMasks.length; k++)
        if (dartMasks[k] != null) (dartMasks[k]!, nativeMasks[k]!),
    ];
    expect(pairs, isNotEmpty);

    // 2) Per-mask erase pixel equality.
    for (final (d, _) in pairs) {
      final a = Uint8List.fromList(page.image.pixels);
      final b = Uint8List.fromList(page.image.pixels);
      TextInpainter.eraseWithMask(RgbaImage(w, h, a), d);
      InpaintNative.eraseWithMask(RgbaImage(w, h, b), d);
      expect(b, orderedEquals(a), reason: 'erase bytes differ');
    }

    // 3) Full-pipeline equality: sequential compute+erase over all regions,
    // proving the batched native path preserves interleaved semantics.
    {
      final a = TextInpainter.erase(
        RgbaImage(w, h, Uint8List.fromList(page.image.pixels)),
        page.regions,
      );
      final b = InpaintNative.erase(
        RgbaImage(w, h, Uint8List.fromList(page.image.pixels)),
        page.regions,
      );
      expect(b.pixels, orderedEquals(a.pixels), reason: 'erase() differs');
    }

    // 4) Timing double assertion on the full pipeline, fresh copies per iter.
    const iters = 7;
    final dartClock = Stopwatch()..start();
    for (var it = 0; it < iters; it++) {
      TextInpainter.erase(
        RgbaImage(w, h, Uint8List.fromList(page.image.pixels)),
        page.regions,
      );
    }
    dartClock.stop();
    final nativeClock = Stopwatch()..start();
    for (var it = 0; it < iters; it++) {
      InpaintNative.erase(
        RgbaImage(w, h, Uint8List.fromList(page.image.pixels)),
        page.regions,
      );
    }
    nativeClock.stop();
    final dartMs = _ms(dartClock) / iters;
    final nativeMs = _ms(nativeClock) / iters;
    final speedup = dartMs / max(nativeMs, 0.001);
    // ignore: avoid_print
    print(
      jsonEncode({
        'probe': 'inpaint_native',
        'width': w,
        'height': h,
        'masks': pairs.length,
        'iters': iters,
        'dartEraseMs': dartMs,
        'nativeEraseMs': nativeMs,
        'speedup': speedup,
      }),
    );
    // 2026-11-05 用户裁决（同OCR原则）：CI 2.43x vs 本机3.28x，门槛3.0→2.0，像素一致断言不动。
    expect(speedup, greaterThanOrEqualTo(2.0), reason: 'native <2x Dart');
  });
}
