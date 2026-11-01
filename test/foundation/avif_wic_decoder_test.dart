import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_provider/avif_wic_decoder.dart';

/// Exercises the Windows-only WIC fallback against the real AVIF fixtures.
///
/// The decoder is compiled on every platform but only binds on Windows, so
/// other hosts skip. It needs the HEIF/AV1 codec extensions that ship with
/// Windows 11; without them every decode declines and the suite says so.
///
/// The 1x1 sample is deliberately excluded from the success list: the AVIF
/// codec behind WIC rejects surfaces that small, which matches the Flutter
/// engine's own Windows behaviour and keeps the placeholder path in charge.

bool _canDecodeHere() {
  if (!Platform.isWindows) {
    markTestSkipped('WIC fallback only binds on Windows');
    return false;
  }
  if (isSystemAvifAvailable) return true;
  markTestSkipped('ole32 could not be bound on this host');
  return false;
}

void main() {
  const fixtures = [
    'colors-animated-8bpc.avif',
    'colors-animated-8bpc-alpha-exif-xmp.avif',
    'abc_color_irot_alpha_irot.avif',
    'e_12bit_hdr.avif',
  ];

  test('decodes every AVIF fixture through WIC', () {
    if (!_canDecodeHere()) return;
    for (final name in fixtures) {
      final bytes = File('test/fixtures/avif/$name').readAsBytesSync();
      final decoded = decodeAvifWithWic(bytes);
      expect(decoded, isNotNull, reason: name);
      expect(decoded!.width, greaterThan(0), reason: name);
      expect(decoded.height, greaterThan(0), reason: name);
      expect(
        decoded.rgba.length,
        decoded.width * decoded.height * 4,
        reason: name,
      );
    }
  });

  test('reports the 1x1 sample as undecodable', () {
    if (!_canDecodeHere()) return;
    final bytes = File('test/fixtures/avif/white_1x1.avif').readAsBytesSync();
    expect(decodeAvifWithWic(bytes), isNull);
  });

  test('declines payloads that are not ISO-BMFF AVIF', () {
    // A PNG signature padded to 12 bytes: the fallback must stay out of the
    // way so non-AVIF failures keep their original handling.
    final png = Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      0,
    ]);
    expect(isAvifContainer(png), isFalse);
    expect(decodeAvifWithWic(png), isNull);
    expect(
      isAvifContainer(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
      isFalse,
    );
  });

  test('swaps WIC BGRA bytes into RGBA', () {
    expect(bgraToRgba(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])), [
      3,
      2,
      1,
      4,
      7,
      6,
      5,
      8,
    ]);
  });
}
