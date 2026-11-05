// Anime4K v1 native equivalence: full post-resize pipeline byte equality
// plus a pipeline speedup gate. Mirrors the B2 native-test pattern.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_unified/foundation/image_provider/upscale/anime4k_native.dart';
import 'package:venera_unified/foundation/image_provider/upscale/anime4k_upscaler.dart';

img.Image _halfSplit({int size = 16}) {
  final image = img.Image(width: size, height: size, numChannels: 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final v = x < size ~/ 2 ? 0 : 255;
      image.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  return image;
}

img.Image _noise({int w = 24, int h = 18, int seed = 0xa4e4}) {
  final rand = Random(seed);
  final image = img.Image(width: w, height: h, numChannels: 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgba(
        x,
        y,
        rand.nextInt(256),
        rand.nextInt(256),
        rand.nextInt(256),
        255,
      );
    }
  }
  return image;
}

Uint8List _rgba(img.Image image) =>
    image.getBytes(order: img.ChannelOrder.rgba);

void main() {
  test('native matches Dart pipeline byte for byte', () {
    if (!Anime4KNative.available) {
      markTestSkipped('venera_anime4k not built for this platform');
    }
    expect(Anime4KNative.version(), 1);
    final unblur = (0.31 * 255).round().clamp(0, 0xFFFF);
    final refine = (1.0 * 255).round().clamp(0, 0xFFFF);
    final upscaler = Anime4KUpscaler();
    for (final base in [_halfSplit(size: 16), _halfSplit(size: 5), _noise()]) {
      final up = img.copyResize(
        base,
        width: base.width * 2,
        height: base.height * 2,
        interpolation: img.Interpolation.linear,
      );
      final d = upscaler.upscalePixels(up);
      final n = Anime4KNative.process(up, unblur, refine);
      expect(n, orderedEquals(_rgba(d)));
    }
  });

  test('native wins the pipeline race', () {
    if (!Anime4KNative.available) {
      markTestSkipped('venera_anime4k not built for this platform');
    }
    final unblur = (0.31 * 255).round().clamp(0, 0xFFFF);
    final refine = (1.0 * 255).round().clamp(0, 0xFFFF);
    final up = img.copyResize(
      _noise(w: 240, h: 180, seed: 0xbeef),
      width: 480,
      height: 360,
      interpolation: img.Interpolation.linear,
    );
    final upscaler = Anime4KUpscaler();
    const iters = 5;
    final dartMs = <double>[];
    final nativeMs = <double>[];
    for (var it = 0; it < iters; it++) {
      var c = Stopwatch()..start();
      upscaler.upscalePixels(up);
      c.stop();
      dartMs.add(c.elapsedMicroseconds / 1000.0);
      c = Stopwatch()..start();
      Anime4KNative.process(up, unblur, refine);
      c.stop();
      nativeMs.add(c.elapsedMicroseconds / 1000.0);
    }
    double med(List<double> v) {
      final s = [...v]..sort();
      return s[s.length ~/ 2];
    }

    final speedup = med(dartMs) / med(nativeMs);
    // ignore: avoid_print
    print(
      'anime4k pipe: dart=${med(dartMs).toStringAsFixed(1)}ms native=${med(nativeMs).toStringAsFixed(1)}ms speedup=${speedup.toStringAsFixed(2)}',
    );
    expect(
      [for (var i = 0; i < iters; i++) nativeMs[i] < dartMs[i]].every((e) => e),
      isTrue,
      reason: 'native must win all $iters pipeline runs',
    );
    expect(speedup, greaterThanOrEqualTo(2.0), reason: 'pipe <2.0x');
  });
}
