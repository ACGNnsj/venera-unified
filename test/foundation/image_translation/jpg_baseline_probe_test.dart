import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

// Baseline probe for P2 JPG migration: mirrors _encodePdfPage in
// lib/features/local_comics/import_export/pdf_import.dart
// (Image.fromBytes BGRA + encodeJpg q92). Synthetic gradient page at PDF
// render scale. Prints JSON, asserts only sanity (non-empty, decodable).
Uint8List _encodePdfPage(({Uint8List pixels, int width, int height}) page) {
  final decoded = image.Image.fromBytes(
    width: page.width,
    height: page.height,
    bytes: page.pixels.buffer,
    bytesOffset: page.pixels.offsetInBytes,
    order: image.ChannelOrder.bgra,
  );
  return image.encodeJpg(decoded, quality: 92);
}

({Uint8List pixels, int w, int h}) _page(int w, int h) {
  final pixels = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final v = (x * 255 ~/ w + y * 255 ~/ h) ~/ 2;
      pixels[i] = v; // B
      pixels[i + 1] = 255 - v; // G
      pixels[i + 2] = (v + 128) % 256; // R
      pixels[i + 3] = 255; // A
    }
  }
  return (pixels: pixels, w: w, h: h);
}

double _ms(Stopwatch c) => c.elapsedMicroseconds / 1000;

void main() {
  test('jpg Dart baseline probe', () {
    for (final (w, h) in [(800, 1200), (2142, 3000)]) {
      final page = _page(w, h);
      // warm-up + sanity
      final first = _encodePdfPage((pixels: page.pixels, width: w, height: h));
      expect(first, isNotEmpty);
      expect(first[0], 0xFF);
      expect(first[1], 0xD8); // SOI
      final times = <double>[];
      Uint8List? last;
      for (var run = 0; run < 5; run++) {
        final c = Stopwatch()..start();
        last = _encodePdfPage((pixels: page.pixels, width: w, height: h));
        c.stop();
        times.add(_ms(c));
      }
      times.sort();
      // ignore: avoid_print
      print(
        jsonEncode({
          'probe': 'jpg_baseline',
          'width': w,
          'height': h,
          'mp': w * h / 1e6,
          'bytes': last!.length,
          'runsMs': times,
          'medianMs': times[times.length ~/ 2],
          'maxMs': times.last,
        }),
      );
    }
  });
}
