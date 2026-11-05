import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart'; // ponytail: malloc not calloc below; buffers fully overwritten pre-read
import 'package:image/image.dart' as img;

/// Hand-written dart:ffi binding to `native/anime4k` (venera_anime4k).
///
/// Owns the whole post-resize Anime4K v1 pipeline (luminance, Sobel edge
/// mask, multi-pass unblur, Sobel gradient, multi-pass refine, ARGB
/// write-back) behind one FFI call. Bilinear resize, strength math, PNG
/// and isolate/cache stay in Dart. Throws only when the native library
/// cannot be loaded or rejects its arguments; callers fall back to
/// [Anime4KUpscaler.upscalePixels]. No new dependencies.
abstract final class Anime4KNative {
  static DynamicLibrary? _lib;
  static bool _tried = false;

  static DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (_tried) throw StateError('anime4k native library unavailable');
    _tried = true;
    final override = Platform.environment['ANIME4K_NATIVE_LIB'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      if (Platform.isWindows)
        'native/anime4k/target/release/venera_anime4k.dll',
      if (Platform.isAndroid) 'libvenera_anime4k.so',
      if (Platform.isLinux) 'libvenera_anime4k.so',
      if (Platform.isMacOS) 'libvenera_anime4k.dylib',
      // Release bundles: Linux ships the .so in bundle/lib, macOS in
      // Frameworks; a bare soname won't resolve there, so add the
      // exe-relative absolute path (missing files just fail this candidate).
      if (Platform.isLinux)
        '${File(Platform.resolvedExecutable).parent.path}/lib/libvenera_anime4k.so',
      if (Platform.isMacOS)
        '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/libvenera_anime4k.dylib',
      if (Platform.isWindows) 'venera_anime4k.dll',
    ];
    Object? lastError;
    // iOS/macOS may statically link the crate into the process.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        if (process.providesSymbol('anime4k_version')) {
          return _lib = process;
        }
      } catch (e) {
        lastError = e;
      }
    }
    for (final name in candidates) {
      try {
        return _lib = DynamicLibrary.open(name);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('Failed to load venera_anime4k: $lastError');
  }

  /// True when the Rust library loaded (version check included).
  static bool get available {
    try {
      return version() == 1;
    } catch (_) {
      return false;
    }
  }

  static int Function()? _versionFn;
  static int version() {
    _versionFn ??= _load().lookupFunction<Uint32 Function(), int Function()>(
      'anime4k_version',
    );
    return _versionFn!();
  }

  static int Function(Pointer<Uint8>, int, int, int, int, int, Pointer<Uint8>)?
  _upscaleFn;

  /// Runs the native pipeline over [upscaled] (already bilinear-resized).
  /// Strengths are the same rounded/clamped ints the Dart path derives from
  /// pushStrength/pushGradStrength. Returns fresh RGBA bytes.
  static Uint8List process(
    img.Image upscaled,
    int unblurStrength,
    int refineStrength,
  ) {
    _upscaleFn ??= _load()
        .lookupFunction<
          Int32 Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Uint32,
            Uint32,
            Pointer<Uint8>,
          ),
          int Function(Pointer<Uint8>, int, int, int, int, int, Pointer<Uint8>)
        >('anime4k_upscale_v1');
    final Uint8List rgba = upscaled.getBytes(order: img.ChannelOrder.rgba);
    final int len = rgba.length;
    final inPtr = malloc<Uint8>(len);
    final outPtr = malloc<Uint8>(len);
    try {
      inPtr.asTypedList(len).setAll(0, rgba);
      final rc = _upscaleFn!(
        inPtr,
        len,
        upscaled.width,
        upscaled.height,
        unblurStrength,
        refineStrength,
        outPtr,
      );
      if (rc != 0) {
        throw StateError('anime4k_upscale_v1 failed ($rc)');
      }
      return Uint8List.fromList(outPtr.asTypedList(len));
    } finally {
      malloc.free(inPtr);
      malloc.free(outPtr);
    }
  }
}
