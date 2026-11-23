import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_unified/foundation/image_translation/ocr_engine.dart';

void main() {
  test('decoded OCR input carries RGBA and dimensions from one decode', () {
    final image = img.Image(width: 2, height: 3, numChannels: 4)
      ..setPixelRgba(0, 0, 1, 2, 3, 4);
    final decoded = decodeOcrPage(Uint8List.fromList(img.encodePng(image)));

    expect(decoded.width, 2);
    expect(decoded.height, 3);
    expect(decoded.rgba, hasLength(2 * 3 * 4));
    expect(decoded.rgba.sublist(0, 4), [1, 2, 3, 4]);
  });

  test('decoded OCR input rejects an undecodable page', () {
    expect(
      () => decodeOcrPage(Uint8List.fromList([0, 1, 2, 3])),
      throwsA(isA<Exception>()),
    );
  });
}
