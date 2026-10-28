// task-23 upscale wiring: gate helper unit tests.
//
// Host-safe by design: on non-Android, processImage returns null before any
// platform channel is touched, so `enabled: true` must fall back to the input
// bytes without throwing (this also pins the Android-check-before-init order).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_provider/upscale/upscale_gate.dart';

void main() {
  group('upscaleIfEnabled', () {
    test('disabled gate returns the identical input', () async {
      final input = Uint8List.fromList([1, 2, 3, 4]);
      final output = await upscaleIfEnabled(
        input,
        cacheKey: 'gate-off',
        enabled: false,
      );
      expect(identical(output, input), isTrue);
    });

    test('enabled gate on host falls back to input bytes', () async {
      final input = Uint8List.fromList([5, 6, 7, 8]);
      final output = await upscaleIfEnabled(
        input,
        cacheKey: 'gate-on-host',
        enabled: true,
      );
      expect(output, orderedEquals(input));
    });

    test('fallback preserves each input independently', () async {
      final first = Uint8List.fromList([9, 9, 9]);
      final second = Uint8List.fromList([7, 7, 7, 7, 7]);
      final outFirst = await upscaleIfEnabled(
        first,
        cacheKey: 'a',
        enabled: true,
      );
      final outSecond = await upscaleIfEnabled(
        second,
        cacheKey: 'b',
        enabled: true,
      );
      expect(outFirst, orderedEquals(first));
      expect(outSecond, orderedEquals(second));
    });
  });
}
