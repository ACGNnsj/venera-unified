// A15 Anime4K v1 pure-Dart upscale: tiny-fixture unit tests.
// No render-chain wiring is asserted here (API-only landing).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_unified/foundation/image_provider/upscale/anime4k_service.dart';
import 'package:venera_unified/foundation/image_provider/upscale/anime4k_upscaler.dart';

/// Left half black, right half white: a single hard vertical edge.
img.Image _halfSplitImage({int size = 8}) {
  final image = img.Image(width: size, height: size, numChannels: 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final v = x < size ~/ 2 ? 0 : 255;
      image.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  return image;
}

img.Image _uniformImage({int size = 8, int v = 128}) {
  final image = img.Image(width: size, height: size, numChannels: 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      image.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  return image;
}

int _minRed(img.Image image) {
  var min = 255;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final r = image.getPixel(x, y).r.toInt();
      if (r < min) min = r;
    }
  }
  return min;
}

int _maxRed(img.Image image) {
  var max = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final r = image.getPixel(x, y).r.toInt();
      if (r > max) max = r;
    }
  }
  return max;
}

double _meanRed(img.Image image) {
  var sum = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      sum += image.getPixel(x, y).r.toInt();
    }
  }
  return sum / (image.width * image.height);
}

void main() {
  group('Anime4KUpscaler.upscale', () {
    test('doubles dimensions with default scaleFactor', () {
      final result = Anime4KUpscaler().upscale(_halfSplitImage(size: 8));
      expect(result.width, 16);
      expect(result.height, 16);
    });

    test('honors custom scaleFactor', () {
      final result = Anime4KUpscaler(
        scaleFactor: 1.5,
      ).upscale(_halfSplitImage(size: 8));
      expect(result.width, 12);
      expect(result.height, 12);
    });

    test('handles 1x1 input without crashing', () {
      final result = Anime4KUpscaler().upscale(_uniformImage(size: 1, v: 200));
      expect(result.width, 2);
      expect(result.height, 2);
      expect(_meanRed(result), closeTo(200, 8));
    });

    test('uniform gray keeps mean luminance and stays opaque', () {
      final result = Anime4KUpscaler().upscale(_uniformImage(size: 8, v: 128));
      expect(_meanRed(result), closeTo(128, 8));
      expect(_minRed(result), greaterThanOrEqualTo(100));
      expect(_maxRed(result), lessThanOrEqualTo(156));
      expect(result.getPixel(7, 7).a.toInt(), 255);
    });

    test('hard black/white edge is not washed out', () {
      final result = Anime4KUpscaler().upscale(_halfSplitImage(size: 8));
      expect(_minRed(result), lessThanOrEqualTo(64));
      expect(_maxRed(result), greaterThanOrEqualTo(192));
    });
  });

  group('Anime4KUpscaler.processDirect', () {
    test('returns decodable PNG with expected dimensions', () {
      final bytes = Uint8List.fromList(img.encodePng(_halfSplitImage()));
      final out = Anime4KUpscaler.processDirect(
        Anime4KParams(imageBytes: bytes),
      );
      expect(out, isNotNull);
      final decoded = img.decodeImage(out!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 16);
      expect(decoded.height, 16);
    });

    test('garbage bytes return null instead of throwing', () {
      final out = Anime4KUpscaler.processDirect(
        Anime4KParams(imageBytes: Uint8List.fromList([0, 1, 2, 3, 4])),
      );
      expect(out, isNull);
    });
  });

  group('Anime4KUpscaler.processInIsolate', () {
    test('compute path returns correctly sized PNG', () async {
      final bytes = Uint8List.fromList(
        img.encodePng(_halfSplitImage(size: 4)),
      );
      final out = await Anime4KUpscaler.processInIsolate(
        Anime4KParams(imageBytes: bytes),
      );
      expect(out, isNotNull);
      final decoded = img.decodeImage(out!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 8);
      expect(decoded.height, 8);
    });
  });

  group('Anime4KService', () {
    test('processImage works with cache disabled (no init)', () async {
      final bytes = Uint8List.fromList(
        img.encodePng(_halfSplitImage(size: 4)),
      );
      final out = await Anime4KService.instance.processImage(
        imageBytes: bytes,
        cacheKey: 'a15-test-no-cache',
      );
      expect(out, isNotNull);
      final decoded = img.decodeImage(out!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 8);
      expect(decoded.height, 8);
    });

    test('processImage with invalid bytes returns null', () async {
      final out = await Anime4KService.instance.processImage(
        imageBytes: Uint8List.fromList([9, 9, 9]),
        cacheKey: 'a15-test-invalid',
      );
      expect(out, isNull);
    });

    test('processFile on missing file returns null', () async {
      final out = await Anime4KService.instance.processFile(
        filePath: r'D:\venera\definitely-not-here-a15.png',
      );
      expect(out, isNull);
    });

    test('cache helpers are safe with cache disabled', () async {
      expect(await Anime4KService.instance.getCacheSize(), 0);
      await Anime4KService.instance.clearCache();
    });
  });
}
