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
    // Decode twice: a bad ownership transfer (freeing an avifImage with
    // avifDecoderDestroy) only surfaces as heap corruption on a later pass or
    // at process teardown.
    for (var pass = 0; pass < 2; pass++) {
      for (final name in fixtures) {
        final bytes = File('test/fixtures/avif/$name').readAsBytesSync();
        final decoded = decodeAvifWithSystemLibrary(bytes);
        expect(decoded, isNotNull, reason: '$name pass $pass');
        final rgba = decoded!.rgba;
        expect(decoded.width, greaterThan(0), reason: '$name pass $pass');
        expect(decoded.height, greaterThan(0), reason: '$name pass $pass');
        expect(
          rgba.length,
          decoded.width * decoded.height * 4,
          reason: '$name pass $pass',
        );
      }
    }
  });

  test('decodes the 1x1 sample to near-white pixels', () {
    if (!Platform.isLinux) {
      markTestSkipped('libavif fallback only binds on Linux');
      return;
    }
    final bytes = File('test/fixtures/avif/white_1x1.avif').readAsBytesSync();
    final decoded = decodeAvifWithSystemLibrary(bytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, 1);
    expect(decoded.height, 1);
    expect(decoded.rgba[0], greaterThan(200));
    expect(decoded.rgba[1], greaterThan(200));
    expect(decoded.rgba[2], greaterThan(200));
    expect(decoded.rgba[3], 255);
  });
}
