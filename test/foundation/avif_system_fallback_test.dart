import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_processing.dart';

void main() {
  tearDown(() {
    Image.systemAvifDecoderForTesting = null;
  });

  test(
    'falls back to the system AVIF decoder when the engine cannot decode',
    () async {
      // A 2x2 opaque white surface delivered by the injected decoder.
      const width = 2;
      const height = 2;
      final rgba = Uint8List(width * height * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 0xff;
        rgba[i + 1] = 0xff;
        rgba[i + 2] = 0xff;
        rgba[i + 3] = 0xff;
      }

      var calls = 0;
      Image.systemAvifDecoderForTesting = (bytes) {
        calls++;
        return (rgba: rgba, width: width, height: height);
      };

      final image = await Image.decodeImage(Uint8List.fromList([1, 2, 3, 4]));

      expect(calls, 1);
      expect(image.width, width);
      expect(image.height, height);
    },
  );

  test('keeps the original failure when the system decoder declines', () async {
    var calls = 0;
    Image.systemAvifDecoderForTesting = (bytes) {
      calls++;
      return null;
    };

    await expectLater(
      Image.decodeImage(Uint8List.fromList([0, 0, 0])),
      throwsA(isA<Exception>()),
    );
    expect(calls, 1);
  });

  test('does not consult the system decoder for a decodable PNG', () async {
    var calls = 0;
    Image.systemAvifDecoderForTesting = (bytes) {
      calls++;
      return null;
    };

    // 1x1 transparent PNG.
    final png = Uint8List.fromList([
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
      0x00,
      0x00,
      0x00,
      0x0d,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1f,
      0x15,
      0xc4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0a,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9c,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0d,
      0x0a,
      0x2d,
      0xb4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4e,
      0x44,
      0xae,
      0x42,
      0x60,
      0x82,
    ]);

    final image = await Image.decodeImage(png);

    expect(calls, 0);
    expect(image.width, 1);
    expect(image.height, 1);
  });
}
