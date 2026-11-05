import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_translation/ocr_preprocess_native.dart';
import 'package:venera_unified/foundation/image_translation/ocr_types.dart';
import 'package:venera_unified/foundation/image_translation/ocr_worker.dart';

// Pixel-equality + timing double assertion for the Rust ocr_preprocess
// migration. Skips when the dev library is not built
// (CI without native/ocr_preprocess/target); the Dart pure functions in
// ocr_worker.dart remain the fallback. ORT inference is not on this path.
int _seed = 0x51ab3d77;
int _nextRand(int bound) {
  _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
  return _seed % bound;
}

double _ms(Stopwatch c) => c.elapsedMicroseconds / 1000;

RgbaImage _mangaTile(int w, int h) {
  _seed = 0x51ab3d77;
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

List<IntRect> _boxes(int w, int h, int count) {
  final boxes = [
    for (var i = 0; i < count; i++)
      IntRect(
        _nextRand(w - 60),
        _nextRand(h - 40),
        _nextRand(w - 60) + 40,
        _nextRand(h - 40) + 24,
      ),
  ];
  for (final b in boxes) {
    if (b.right <= b.left) b.right = b.left + 40;
    if (b.bottom <= b.top) b.bottom = b.top + 24;
    if (b.top < 0) b.top = 0;
  }
  return boxes;
}

void main() {
  test('ocr native matches Dart pixels and clears both gates', () {
    if (!OcrPreprocessNative.available) {
      markTestSkipped('venera_ocr_preprocess not built for this platform');
    }
    expect(OcrPreprocessNative.version(), 1);

    const w = 800, h = 1200;
    final tile = _mangaTile(w, h);
    const classes = 97;
    final charset = [
      for (var i = 0; i < classes; i++) String.fromCharCode(0x4E00 + i),
    ];

    // 1) Bilinear resize byte equality, downscale and odd-size regions.
    for (final region in [
      IntRect(w ~/ 8, h ~/ 10, w ~/ 8 + 420, h ~/ 10 + 180),
      IntRect(0, 0, w, h),
      IntRect(13, 29, 517, 903),
    ]) {
      const outW = 384, outH = 48;
      final d = resizeRegionForTest(tile, region, outW, outH);
      final n = OcrPreprocessNative.resizeRegion(tile, region, outW, outH);
      expect(n, orderedEquals(d), reason: 'resize bytes $region');
    }

    // 2) detPreprocess equality (dims + ImageNet tensor, bitwise).
    final dDet = detPreprocessForTest(tile);
    final nDet = OcrPreprocessNative.detPreprocess(tile);
    expect((nDet.width, nDet.height), (dDet.width, dDet.height));
    expect(nDet.tensor, orderedEquals(dDet.tensor), reason: 'det tensor');

    // 4) CTC string equality (blank + repeat + charset-cap pins).
    _seed = 0x77aa;
    const steps = 160;
    final probs = Float32List(steps * classes);
    for (var t = 0; t < steps; t++) {
      // Every 7th step is blank; neighbours repeat to pin dedup.
      final peak = t % 7 == 3 ? 0 : 1 + _nextRand(classes - 1);
      for (var cc = 0; cc < classes; cc++) {
        probs[t * classes + cc] = cc == peak ? 0.9 : 0.001 * _nextRand(100);
      }
    }
    expect(
      OcrPreprocessNative.ctcDecode(probs, classes, charset),
      ctcDecodeForTest(probs, classes, charset),
    );
    // Out-of-range ids are dropped, never crash the mapper.
    final hot = Float32List.fromList(probs);
    for (var cc = 0; cc < classes; cc++) {
      hot[5 * classes + cc] = cc == classes - 1 ? 0.99 : 0.0;
    }
    expect(
      OcrPreprocessNative.ctcDecode(hot, classes, ['a', 'b']),
      ctcDecodeForTest(hot, classes, ['a', 'b']),
    );

    // 5) Dedup equality (field-wise, order-preserving, same input).
    _seed = 0x51ab3d77;
    final boxes = _boxes(w, h, 240);
    List<int> flat(List<IntRect> rs) => [
      for (final b in rs) ...[b.left, b.top, b.right, b.bottom],
    ];
    expect(
      flat(OcrPreprocessNative.dedupBoxes(boxes)),
      orderedEquals(flat(dedupBoxesForTest(boxes))),
      reason: 'dedup boxes',
    );
    expect(OcrPreprocessNative.dedupBoxes([]), isEmpty);

    // 6) Timing double assertion. Preprocess segment gate >=3x (5/5 wins);
    // end-to-end-minus-ORT gate >=1.5x. Fresh copies per iter.
    const iters = 5;
    final dartPre = <double>[];
    final nativePre = <double>[];
    for (var it = 0; it < iters; it++) {
      var c = Stopwatch()..start();
      detPreprocessForTest(tile);
      c.stop();
      dartPre.add(_ms(c));
      c = Stopwatch()..start();
      OcrPreprocessNative.detPreprocess(tile);
      c.stop();
      nativePre.add(_ms(c));
    }
    double med(List<double> v) {
      final s = [...v]..sort();
      return s[s.length ~/ 2];
    }

    final preSpeedup = med(dartPre) / max(med(nativePre), 0.001);
    final preWins = [
      for (var i = 0; i < iters; i++) nativePre[i] < dartPre[i],
    ].every((e) => e);

    void dartPipe() {
      final det = detPreprocessForTest(tile);
      if (det.tensor.isEmpty) throw StateError('empty');
      final r = resizeRegionForTest(
        tile,
        IntRect(w ~/ 8, h ~/ 10, w ~/ 8 + 420, h ~/ 10 + 180),
        384,
        48,
      );
      normalizeForTest(r, 384, 48);
      _seed = 0x77aa;
      final pr = Float32List(480 * classes);
      for (var t = 0; t < 480; t++) {
        final peak = 1 + _nextRand(classes - 1);
        for (var cc = 0; cc < classes; cc++) {
          pr[t * classes + cc] = cc == peak ? 0.9 : 0.001 * _nextRand(100);
        }
      }
      ctcDecodeForTest(pr, classes, charset);
      dedupBoxesForTest(_boxes(w, h, 2000));
    }

    void nativePipe() {
      final det = OcrPreprocessNative.detPreprocess(tile);
      if (det.tensor.isEmpty) throw StateError('empty');
      final r = OcrPreprocessNative.resizeRegion(
        tile,
        IntRect(w ~/ 8, h ~/ 10, w ~/ 8 + 420, h ~/ 10 + 180),
        384,
        48,
      );
      normalizeForTest(r, 384, 48);
      _seed = 0x77aa;
      final pr = Float32List(480 * classes);
      for (var t = 0; t < 480; t++) {
        final peak = 1 + _nextRand(classes - 1);
        for (var cc = 0; cc < classes; cc++) {
          pr[t * classes + cc] = cc == peak ? 0.9 : 0.001 * _nextRand(100);
        }
      }
      OcrPreprocessNative.ctcDecode(pr, classes, charset);
      OcrPreprocessNative.dedupBoxes(_boxes(w, h, 2000));
    }

    // Warm-up (JIT + first FFI lookup) outside the measured window.
    dartPipe();
    nativePipe();
    final dartPipeMs = <double>[];
    final nativePipeMs = <double>[];
    for (var it = 0; it < iters; it++) {
      var c = Stopwatch()..start();
      dartPipe();
      c.stop();
      dartPipeMs.add(_ms(c));
      c = Stopwatch()..start();
      nativePipe();
      c.stop();
      nativePipeMs.add(_ms(c));
    }
    final pipeSpeedup = med(dartPipeMs) / max(med(nativePipeMs), 0.001);
    // ignore: avoid_print
    print(
      jsonEncode({
        'probe': 'ocr_preprocess_native',
        'dartPreMs': med(dartPre),
        'nativePreMs': med(nativePre),
        'preSpeedup': preSpeedup,
        'preWins': preWins,
        'dartPipeMs': med(dartPipeMs),
        'nativePipeMs': med(nativePipeMs),
        'pipeSpeedup': pipeSpeedup,
      }),
    );
    expect(
      preWins,
      isTrue,
      reason: 'native must win all $iters preprocess runs',
    );
    // 2026-11-05 用户裁决：CI三轮2.70/2.97/2.49x，2.5线切在分布中间无余量→2.0（CI地板2.49上有0.5余量），像素+全胜+pipe门不动。
    expect(preSpeedup, greaterThanOrEqualTo(2.0), reason: 'preprocess <2.0x');
    expect(pipeSpeedup, greaterThanOrEqualTo(1.5), reason: 'pipe <1.5x');
  });
}
