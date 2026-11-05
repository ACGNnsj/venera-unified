// Anime4K v1 Dart baseline probe (batch 3, P1 gate >=5x).
//
// Host diagnostic, not a marketing benchmark: establishes the Dart baseline
// for the Anime4K Rust migration. Times Anime4KUpscaler.upscale() on a
// deterministic synthetic manga page, split into copyResize (package:image,
// stays in Dart) vs the 5 kernel passes (luminance/edgeMask/unblur/gradient/
// refine, the port candidates). PNG decode/encode are excluded (codec, not
// ours to port); ORT/v4 MethodChannel inference is not on this path.
// Env overrides: ANIME4K_W (default 240), ANIME4K_H (default 360),
// ANIME4K_RUNS (default 5). Sizes are source dims; kernels run at 2x.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_unified/foundation/image_provider/upscale/anime4k_upscaler.dart';

int _seed = 0x4b4b5151;
int _nextRand(int bound) {
  _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
  return _seed % bound;
}

double _ms(Stopwatch c) => c.elapsedMicroseconds / 1000;

// Synthetic manga-ish page: gradient + screentone dots + glyph bars.
img.Image _mangaPage(int w, int h) {
  _seed = 0x4b4b5151;
  final image = img.Image(width: w, height: h, numChannels: 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 200 + ((x + y) % 56);
      if ((x % 7 == 0) && (y % 7 == 0)) v -= 60;
      image.setPixelRgba(x, y, v, v, v - 10, 255);
    }
  }
  final bubbles = [
    (w ~/ 8, h ~/ 12, w ~/ 8 + w ~/ 3, h ~/ 12 + h ~/ 8),
    (w ~/ 2, h ~/ 2, w ~/ 2 + w ~/ 4, h ~/ 2 + h ~/ 6),
  ];
  for (final (bl, bt, br, bb) in bubbles) {
    for (var y = bt; y < bb && y < h; y++) {
      for (var x = bl; x < br && x < w; x++) {
        image.setPixelRgba(x, y, 255, 255, 255, 255);
      }
    }
    for (var line = 0; line < 4; line++) {
      final gy = bt + 8 + line * ((bb - bt - 16) ~/ 4);
      var gx = bl + 6 + _nextRand(12);
      while (gx < br - 14) {
        final gw = 8 + _nextRand(18);
        for (var y = gy; y < gy + 8 && y < bb - 4; y++) {
          for (var x = gx; x < gx + gw && x < br - 4; x++) {
            image.setPixelRgba(x, y, 20, 20, 20, 255);
          }
        }
        gx += gw + 4 + _nextRand(10);
      }
    }
  }
  return image;
}

void main() {
  test('anime4k Dart baseline probe', () {
    final srcW = int.tryParse(const String.fromEnvironment('ANIME4K_W')) ?? 240;
    final srcH = int.tryParse(const String.fromEnvironment('ANIME4K_H')) ?? 360;
    final runs =
        int.tryParse(const String.fromEnvironment('ANIME4K_RUNS')) ?? 5;
    final upscaler = Anime4KUpscaler();
    final src = _mangaPage(srcW, srcH);

    // Sanity: 2x dims, non-uniform output.
    final once = upscaler.upscale(src);
    expect(once.width, srcW * 2);
    expect(once.height, srcH * 2);
    var sum = 0;
    for (var y = 0; y < once.height; y += 7) {
      for (var x = 0; x < once.width; x += 7) {
        sum += once.getPixel(x, y).r.toInt();
      }
    }
    expect(sum, greaterThan(0));

    for (var run = -1; run < runs; run++) {
      final resizeClock = Stopwatch()..start();
      final up = img.copyResize(
        src,
        width: srcW * 2,
        height: srcH * 2,
        interpolation: img.Interpolation.linear,
      );
      resizeClock.stop();
      final fullClock = Stopwatch()..start();
      upscaler.upscale(src);
      fullClock.stop();
      if (run < 0) continue; // warm-up (JIT + package:image init)
      // ignore: avoid_print
      print(
        jsonEncode({
          'probe': 'anime4k_baseline',
          'srcW': srcW,
          'srcH': srcH,
          'outW': up.width,
          'outH': up.height,
          'resizeMs': _ms(resizeClock),
          'fullMs': _ms(fullClock),
          'kernelsMs': _ms(fullClock) - _ms(resizeClock),
          'run': run,
        }),
      );
    }
  });
}
