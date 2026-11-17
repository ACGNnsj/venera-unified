import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:venera_native/venera_native.dart';

/// Encode straight RGBA bytes to PNG for the reader/upscale path.
///
/// Prefers the existing `venera_native` encoder (same one behind
/// `Image.encodePng`) and falls back to package:image when the native
/// library is not built for this platform (mirrors the `jpg_encode`
/// wiring in pdf_import.dart). Either way the output decodes to
/// pixel-identical RGBA; see native_png_parity_test.dart.
Uint8List encodeUpscalePng(Uint8List rgba, int width, int height) {
  try {
    return encodePngRgba(rgba, width, height);
  } catch (_) {
    // Native library not built for this platform; Dart fallback below.
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodePng(image));
}
