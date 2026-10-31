import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Minimal libavif binding used as a Linux-only decode fallback.
///
/// The Flutter Linux engine ships no AVIF decoder (the probe reports
/// `Invalid image data` for every sample), so the reader falls back to the
/// system libavif that the .deb depends on. Every failure path returns null so
/// the caller keeps its existing placeholder/error handling: this decoder must
/// never crash the app, only decline.

/// `avifResult` values are ABI-stable; 0 means success.
const int _avifResultOk = 0;

const List<String> _libraryCandidates = [
  'libavif.so.16',
  'libavif.so.15',
  'libavif.so.14',
  'libavif.so',
];

typedef _CreateNative = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);
typedef _ReadMemoryNative =
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>, IntPtr);
typedef _ReadMemoryDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Uint8>, int);
typedef _SetDefaultsNative = Void Function(Pointer<Uint8>, Pointer<Void>);
typedef _SetDefaultsDart = void Function(Pointer<Uint8>, Pointer<Void>);
typedef _YuvToRgbNative = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _YuvToRgbDart = int Function(Pointer<Void>, Pointer<Uint8>);

/// Mirrors `avifRGBImage` (libavif 1.x). Field order and widths matter:
/// offsets verified with `offsetof` against the system header, sizeof == 64.
final class _RgbImage extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int depth;
  @Int32()
  external int format;
  @Int32()
  external int chromaUpsampling;
  @Int32()
  external int chromaDownsampling;
  // avifBool is a 32-bit int, not a byte: four bools make 16 bytes here.
  @Int32()
  external int avoidLibYuv;
  @Int32()
  external int ignoreAlpha;
  @Int32()
  external int alphaPremultiplied;
  @Int32()
  external int isFloat;
  @Int32()
  external int maxThreads;
  external Pointer<Uint8> pixels;
  @Uint32()
  external int rowBytes;
}

class _Bindings {
  _Bindings(
    this._createDecoder,
    this._destroyDecoder,
    this._createImage,
    this._destroyImage,
    this._readMemory,
    this._setDefaults,
    this._yuvToRgb,
  );

  final _CreateDart _createDecoder;
  final _DestroyDart _destroyDecoder;
  final _CreateDart _createImage;
  final _DestroyDart _destroyImage;
  final _ReadMemoryDart _readMemory;
  final _SetDefaultsDart _setDefaults;
  final _YuvToRgbDart _yuvToRgb;

  Pointer<Void> createDecoder() => _createDecoder();
  Pointer<Void> createImage() => _createImage();
  void destroyDecoder(Pointer<Void> handle) => _destroyDecoder(handle);
  void destroyImage(Pointer<Void> handle) => _destroyImage(handle);
  int readMemory(
    Pointer<Void> decoder,
    Pointer<Void> image,
    Pointer<Uint8> data,
    int length,
  ) => _readMemory(decoder, image, data, length);
  void setDefaults(Pointer<Uint8> rgb, Pointer<Void> image) =>
      _setDefaults(rgb, image);
  int yuvToRgb(Pointer<Void> image, Pointer<Uint8> rgb) =>
      _yuvToRgb(image, rgb);
}

_Bindings? _bindings;
bool _unavailable = false;

_Bindings? _load() {
  if (_bindings != null || _unavailable) return _bindings;
  if (!Platform.isLinux) {
    _unavailable = true;
    return null;
  }
  for (final name in _libraryCandidates) {
    try {
      final library = DynamicLibrary.open(name);
      _bindings = _Bindings(
        library.lookupFunction<_CreateNative, _CreateDart>('avifDecoderCreate'),
        library.lookupFunction<_DestroyNative, _DestroyDart>(
          'avifDecoderDestroy',
        ),
        library.lookupFunction<_CreateNative, _CreateDart>(
          'avifImageCreateEmpty',
        ),
        library.lookupFunction<_DestroyNative, _DestroyDart>(
          'avifImageDestroy',
        ),
        library.lookupFunction<_ReadMemoryNative, _ReadMemoryDart>(
          'avifDecoderReadMemory',
        ),
        library.lookupFunction<_SetDefaultsNative, _SetDefaultsDart>(
          'avifRGBImageSetDefaults',
        ),
        library.lookupFunction<_YuvToRgbNative, _YuvToRgbDart>(
          'avifImageYUVToRGB',
        ),
      );
      return _bindings;
    } catch (_) {
      continue;
    }
  }
  _unavailable = true;
  return null;
}

/// Decodes [bytes] with the system libavif, or returns null when the library is
/// missing, the payload is not AVIF, or any step fails.
({Uint8List rgba, int width, int height})? decodeAvifWithSystemLibrary(
  Uint8List bytes,
) {
  final bindings = _load();
  if (bindings == null) return null;

  Pointer<Void>? decoder;
  Pointer<Void>? image;
  Pointer<Uint8>? input;
  Pointer<Uint8>? output;
  try {
    decoder = bindings.createDecoder();
    image = bindings.createImage();
    if (decoder == nullptr || image == nullptr) return null;

    input = malloc<Uint8>(bytes.length);
    input.asTypedList(bytes.length).setAll(0, bytes);
    if (bindings.readMemory(decoder, image, input, bytes.length) !=
        _avifResultOk) {
      return null;
    }

    final rgb = calloc<_RgbImage>(1);
    try {
      bindings.setDefaults(rgb.cast<Uint8>(), image);
      final width = rgb.ref.width;
      final height = rgb.ref.height;
      if (width <= 0 || height <= 0) return null;
      // Force 8-bit straight RGBA so the result matches the engine path
      // (rawStraightRgba) regardless of the source bit depth.
      rgb.ref
        ..depth = 8
        ..format =
            1 // AVIF_RGB_FORMAT_RGBA
        ..alphaPremultiplied = 0
        ..maxThreads = 1;
      final byteLength = width * height * 4;
      output = malloc<Uint8>(byteLength);
      rgb.ref
        ..pixels = output
        ..rowBytes = width * 4;
      if (bindings.yuvToRgb(image, rgb.cast<Uint8>()) != _avifResultOk) {
        return null;
      }
      return (
        rgba: Uint8List.fromList(output.asTypedList(byteLength)),
        width: width,
        height: height,
      );
    } finally {
      calloc.free(rgb);
    }
  } catch (_) {
    return null;
  } finally {
    // avifDecoderDestroy on an avifImage would free the wrong object and
    // corrupt the heap, which surfaced as a segfault at process teardown.
    if (decoder != null && decoder != nullptr) {
      bindings.destroyDecoder(decoder);
    }
    if (image != null && image != nullptr) bindings.destroyImage(image);
    if (input != null) malloc.free(input);
    if (output != null) malloc.free(output);
  }
}
