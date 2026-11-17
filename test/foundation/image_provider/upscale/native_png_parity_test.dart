import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_native/venera_native.dart';
import 'package:venera_unified/foundation/image_processing.dart' as processing;
import 'package:venera_unified/foundation/image_provider/upscale/native_png.dart';

import '../../../support/native_test_environment.dart';

// PoC-C parity first: the upscale path encodes through the existing
// venera_native PNG encoder instead of package:image, while decodes stay
// on full-resolution RGBA readback. These tests pin pixel behavior so the
// swap cannot change a page by a single channel value.

({int w, int h, Uint8List rgba}) _fixture(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      rgba[i] = (x * 255 ~/ w + y * 37) & 255;
      rgba[i + 1] = (y * 255 ~/ h + x * 11) & 255;
      rgba[i + 2] = ((x + y) * 255 ~/ (w + h)) & 255;
      rgba[i + 3] = 255;
    }
  }
  return (w: w, h: h, rgba: rgba);
}

img.Image _toPkgImage(({int w, int h, Uint8List rgba}) f) {
  return img.Image.fromBytes(
    width: f.w,
    height: f.h,
    bytes: f.rgba.buffer,
    bytesOffset: f.rgba.offsetInBytes,
    order: img.ChannelOrder.rgba,
  );
}

/// Per-pixel RGBA of package:image decode, row-major.
Uint8List _pkgRgba(Uint8List bytes) {
  final decoded = img.decodeImage(bytes)!;
  return decoded.getBytes(order: img.ChannelOrder.rgba);
}

/// Per-pixel RGBA of engine full-res decode, row-major.
Future<Uint8List> _engineRgba(Uint8List bytes, int w, int h) async {
  final decoded = await processing.Image.decodeImage(bytes);
  expect((decoded.width, decoded.height), (w, h));
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    final v = decoded.getPixelAtIndex(i).value;
    out[i * 4] = v & 0xFF;
    out[i * 4 + 1] = (v >> 8) & 0xFF;
    out[i * 4 + 2] = (v >> 16) & 0xFF;
    out[i * 4 + 3] = (v >> 24) & 0xFF;
  }
  return out;
}

double _meanAbsDiff(Uint8List a, Uint8List b) {
  expect(b.length, a.length);
  var sum = 0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decode parity (engine full-res vs package:image)', () {
    test('png is pixel-identical, odd stride included', () async {
      for (final (w, h) in [(64, 48), (63, 47)]) {
        final bytes = Uint8List.fromList(
          img.encodePng(_toPkgImage(_fixture(w, h))),
        );
        expect(_pkgRgba(bytes), await _engineRgba(bytes, w, h));
      }
    });

    test('jpeg decoders agree within 1 LSB on average', () async {
      for (final (w, h) in [(64, 48), (63, 47)]) {
        final bytes = Uint8List.fromList(
          img.encodeJpg(_toPkgImage(_fixture(w, h)), quality: 92),
        );
        final mad = _meanAbsDiff(
          _pkgRgba(bytes),
          await _engineRgba(bytes, w, h),
        );
        expect(mad, lessThan(1.0));
      }
    });
  });

  group('encode parity (rust venera_native vs package:image)', () {
    test('rust output re-decodes pixel-identical', () {
      final f = _fixture(64, 48);
      Uint8List nativeBytes;
      try {
        nativeBytes = encodePngRgba(f.rgba, f.w, f.h);
      } catch (e) {
        if (requireNativeTestLibraries) rethrow;
        markTestSkipped('venera_native not built for this platform');
        return;
      }
      // PNG signature, then pixel-identical re-decode.
      expect(nativeBytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      expect(_pkgRgba(nativeBytes), f.rgba);
    });

    test(
      'helper matches fixture through either path, views included',
      () async {
        for (final (w, h) in [(64, 48), (63, 47)]) {
          final f = _fixture(w, h);
          // Typed view with a nonzero offset exercises the offset path.
          final backing = Uint8List(f.rgba.length + 8)..setAll(8, f.rgba);
          final view = Uint8List.sublistView(backing, 8, 8 + f.rgba.length);
          final out = encodeUpscalePng(view, w, h);
          expect(_pkgRgba(out), f.rgba);
          expect(await _engineRgba(out, w, h), f.rgba);
        }
      },
    );
  });
}
