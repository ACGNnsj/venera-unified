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

  static int Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
    int,
  )?
  _upscale2xFn;

  /// Offline fast path: 2x bilinear + full Push pipeline in one FFI call.
  /// Returns null when the native library is unavailable or rejects args.
  static Uint8List? upscale2x(
    Uint8List rgbaSrc,
    int width,
    int height,
    int unblurStrength,
    int refineStrength,
  ) {
    try {
      _upscale2xFn ??= _load()
          .lookupFunction<
            Int32 Function(
              Pointer<Uint8>,
              Size,
              Int32,
              Int32,
              Uint32,
              Uint32,
              Pointer<Uint8>,
              Size,
            ),
            int Function(
              Pointer<Uint8>,
              int,
              int,
              int,
              int,
              int,
              Pointer<Uint8>,
              int,
            )
          >('venera_anime4k_upscale_2x_rgba');
      final int srcLen = rgbaSrc.length;
      final int dstLen = width * 2 * height * 2 * 4;
      final inPtr = malloc<Uint8>(srcLen);
      final outPtr = malloc<Uint8>(dstLen);
      try {
        inPtr.asTypedList(srcLen).setAll(0, rgbaSrc);
        final rc = _upscale2xFn!(
          inPtr,
          srcLen,
          width,
          height,
          unblurStrength,
          refineStrength,
          outPtr,
          dstLen,
        );
        if (rc != 0) return null;
        return Uint8List.fromList(outPtr.asTypedList(dstLen));
      } finally {
        malloc.free(inPtr);
        malloc.free(outPtr);
      }
    } catch (_) {
      return null;
    }
  }

  static int Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
  )?
  _ycrcbFn;

  /// Splits RGBA into full-range BT.601 Y/Cr/Cb planes (null on failure).
  static ({Uint8List y, Uint8List cr, Uint8List cb})? rgbToYcrcb(
    Uint8List rgba,
    int width,
    int height,
  ) {
    try {
      _ycrcbFn ??= _load()
          .lookupFunction<
            Uint8 Function(
              Pointer<Uint8>,
              Size,
              Int32,
              Int32,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint8>,
            ),
            int Function(
              Pointer<Uint8>,
              int,
              int,
              int,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint8>,
            )
          >('venera_acnet_rgb_to_ycrcb');
      final n = width * height;
      final srcPtr = malloc<Uint8>(rgba.length);
      final yPtr = malloc<Uint8>(n);
      final crPtr = malloc<Uint8>(n);
      final cbPtr = malloc<Uint8>(n);
      try {
        srcPtr.asTypedList(rgba.length).setAll(0, rgba);
        final rc = _ycrcbFn!(
          srcPtr,
          rgba.length,
          width,
          height,
          yPtr,
          crPtr,
          cbPtr,
        );
        if (rc != 0) return null;
        return (
          y: Uint8List.fromList(yPtr.asTypedList(n)),
          cr: Uint8List.fromList(crPtr.asTypedList(n)),
          cb: Uint8List.fromList(cbPtr.asTypedList(n)),
        );
      } finally {
        malloc.free(srcPtr);
        malloc.free(yPtr);
        malloc.free(crPtr);
        malloc.free(cbPtr);
      }
    } catch (_) {
      return null;
    }
  }

  static int Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    Pointer<Float>,
  )?
  _extractTileFn;

  /// Extracts one constant-size NCHW float32 tile (null on failure).
  static Float32List? extractTileF32(
    Uint8List plane,
    int strideW,
    int planeH,
    int channels,
    int x,
    int y,
    int coreW,
    int coreH,
    int tileIn,
    int pad,
  ) {
    try {
      _extractTileFn ??= _load()
          .lookupFunction<
            Uint8 Function(
              Pointer<Uint8>,
              Int32,
              Int32,
              Uint32,
              Int32,
              Int32,
              Uint32,
              Uint32,
              Uint32,
              Uint32,
              Pointer<Float>,
            ),
            int Function(
              Pointer<Uint8>,
              int,
              int,
              int,
              int,
              int,
              int,
              int,
              int,
              int,
              Pointer<Float>,
            )
          >('venera_upscale_extract_tile_f32');
      final outLen = channels * tileIn * tileIn;
      final srcPtr = malloc<Uint8>(plane.length);
      final outPtr = malloc<Float>(outLen);
      try {
        srcPtr.asTypedList(plane.length).setAll(0, plane);
        final rc = _extractTileFn!(
          srcPtr,
          strideW,
          planeH,
          channels,
          x,
          y,
          coreW,
          coreH,
          tileIn,
          pad,
          outPtr,
        );
        if (rc != 0) return null;
        return Float32List.fromList(outPtr.asTypedList(outLen));
      } finally {
        malloc.free(srcPtr);
        malloc.free(outPtr);
      }
    } catch (_) {
      return null;
    }
  }

  static int Function(
    Pointer<Float>,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    double,
    int,
    int,
    Pointer<Uint8>,
  )?
  _commitTileFn;

  /// Writes the model-output tile ROI into [out] (null on failure).
  static bool? commitTileF32(
    Float32List tile,
    int channels,
    int tileIn,
    int pad,
    int scale,
    int x,
    int y,
    int coreW,
    int coreH,
    double intensity,
    int outW,
    int outH,
    Uint8List out,
  ) {
    try {
      _commitTileFn ??= _load()
          .lookupFunction<
            Uint8 Function(
              Pointer<Float>,
              Uint32,
              Uint32,
              Uint32,
              Uint32,
              Uint32,
              Uint32,
              Uint32,
              Uint32,
              Float,
              Uint32,
              Uint32,
              Pointer<Uint8>,
            ),
            int Function(
              Pointer<Float>,
              int,
              int,
              int,
              int,
              int,
              int,
              int,
              int,
              double,
              int,
              int,
              Pointer<Uint8>,
            )
          >('venera_upscale_commit_tile_f32');
      final tilePtr = malloc<Float>(tile.length);
      final outPtr = malloc<Uint8>(out.length);
      try {
        tilePtr.asTypedList(tile.length).setAll(0, tile);
        outPtr.asTypedList(out.length).setAll(0, out);
        final rc = _commitTileFn!(
          tilePtr,
          channels,
          tileIn,
          pad,
          scale,
          x,
          y,
          coreW,
          coreH,
          intensity,
          outW,
          outH,
          outPtr,
        );
        if (rc != 0) return null;
        out.setAll(0, outPtr.asTypedList(out.length));
        return true;
      } finally {
        malloc.free(tilePtr);
        malloc.free(outPtr);
      }
    } catch (_) {
      return null;
    }
  }

  static int Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    int,
    int,
    int,
    Pointer<Uint8>,
  )?
  _mergeFn;

  /// Merges super-resolved Y with bilinear chroma into RGBA (null on fail).
  static Uint8List? mergeYcrcbToRgba(
    Uint8List yUp,
    Uint8List cr,
    Uint8List cb,
    int width,
    int height,
    int scale,
  ) {
    try {
      _mergeFn ??= _load()
          .lookupFunction<
            Uint8 Function(
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Uint32,
              Uint32,
              Uint32,
              Pointer<Uint8>,
            ),
            int Function(
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Uint8>,
              int,
              int,
              int,
              Pointer<Uint8>,
            )
          >('venera_acnet_merge_ycrcb_to_rgba');
      final outLen = yUp.length * 4;
      final yPtr = malloc<Uint8>(yUp.length);
      final crPtr = malloc<Uint8>(cr.length);
      final cbPtr = malloc<Uint8>(cb.length);
      final outPtr = malloc<Uint8>(outLen);
      try {
        yPtr.asTypedList(yUp.length).setAll(0, yUp);
        crPtr.asTypedList(cr.length).setAll(0, cr);
        cbPtr.asTypedList(cb.length).setAll(0, cb);
        final rc = _mergeFn!(yPtr, crPtr, cbPtr, width, height, scale, outPtr);
        if (rc != 0) return null;
        return Uint8List.fromList(outPtr.asTypedList(outLen));
      } finally {
        malloc.free(yPtr);
        malloc.free(crPtr);
        malloc.free(cbPtr);
        malloc.free(outPtr);
      }
    } catch (_) {
      return null;
    }
  }
}
