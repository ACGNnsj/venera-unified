import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_provider/avif_system_decoder.dart';

/// Exercises the Linux-only libavif fallback against the real AVIF fixtures.
///
/// The decoder is compiled on every platform but only binds on Linux; other
/// hosts skip. `avif-probe.yml` installs the shared library before running this
/// on ubuntu-24.04, so a skipped run there means the binding or install broke.
void main() {
  const fixtures = [
    'white_1x1.avif',
    'abc_color_irot_alpha_irot.avif',
    'colors-animated-8bpc.avif',
    'colors-animated-8bpc-alpha-exif-xmp.avif',
  ];

  test('decodes every AVIF fixture through the system libavif', () {
    if (!Platform.isLinux) {
      markTestSkipped('libavif fallback only binds on Linux');
      return;
    }
    for (final name in fixtures) {
      final bytes = File('test/fixtures/avif/$name').readAsBytesSync();
      final decoded = decodeAvifWithSystemLibrary(bytes);
      expect(decoded, isNotNull, reason: '$name');
      final rgba = decoded!.rgba;
      expect(decoded.width, greaterThan(0), reason: '$name');
      expect(decoded.height, greaterThan(0), reason: '$name');
      expect(rgba.length, decoded.width * decoded.height * 4, reason: '$name');
    }
  });
}
