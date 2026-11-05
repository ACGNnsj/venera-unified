import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart'; // ponytail: malloc not calloc below; buffers fully overwritten pre-read

import 'ocr_types.dart';

/// Hand-written dart:ffi binding to `native/ocr_preprocess`
/// (venera_ocr_preprocess).
///
/// Zero-intrusion: the pure functions in ocr_worker.dart are untouched and
/// remain the fallback. Every method here throws only when the native library
/// cannot be loaded; callers should catch and use the Dart pure functions
/// instead. No new dependencies (dart:ffi + package:ffi only, no FRB).
/// ORT inference stays in Dart (ort_ffi); this crate only does
/// resize/normalize/argmax/dedup math.
abstract final class OcrPreprocessNative {
  static DynamicLibrary? _lib;
  static bool _tried = false;

  static DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (_tried) throw StateError('ocr_preprocess native library unavailable');
    _tried = true;
    final override = Platform.environment['OCR_PREPROCESS_NATIVE_LIB'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      if (Platform.isWindows)
        'native/ocr_preprocess/target/release/venera_ocr_preprocess.dll',
      if (Platform.isAndroid) 'libvenera_ocr_preprocess.so',
      if (Platform.isLinux) 'libvenera_ocr_preprocess.so',
      if (Platform.isMacOS) 'libvenera_ocr_preprocess.dylib',
      // Release bundles: Linux ships the .so in bundle/lib, macOS in
      // Frameworks; a bare soname won't resolve there, so add the
      // exe-relative absolute path (missing files just fail this candidate).
      if (Platform.isLinux)
        '${File(Platform.resolvedExecutable).parent.path}/lib/libvenera_ocr_preprocess.so',
      if (Platform.isMacOS)
        '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/libvenera_ocr_preprocess.dylib',
      if (Platform.isWindows) 'venera_ocr_preprocess.dll',
    ];
    Object? lastError;
    // iOS/macOS may statically link the crate into the process.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        if (process.providesSymbol('ocr_preprocess_version')) {
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
    throw StateError('Failed to load venera_ocr_preprocess: $lastError');
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
      'ocr_preprocess_version',
    );
    return _versionFn!();
  }

  static int Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
    int,
    int,
  )?
  _resizeFn;
  static Uint8List resizeRegion(
    RgbaImage src,
    IntRect region,
    int outW,
    int outH,
  ) {
    _resizeFn ??= _load()
        .lookupFunction<
          Int32 Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Uint8>,
            Int32,
            Int32,
          ),
          int Function(
            Pointer<Uint8>,
            int,
            int,
            int,
            int,
            int,
            int,
            Pointer<Uint8>,
            int,
            int,
          )
        >('ocr_resize_region');
    final pixPtr = malloc<Uint8>(src.pixels.length);
    final outPtr = malloc<Uint8>(outW * outH * 4);
    try {
      pixPtr.asTypedList(src.pixels.length).setAll(0, src.pixels);
      final rc = _resizeFn!(
        pixPtr,
        src.pixels.length,
        src.width,
        region.left,
        region.top,
        region.right,
        region.bottom,
        outPtr,
        outW,
        outH,
      );
      if (rc != 0) throw StateError('ocr_resize_region failed ($rc)');
      return Uint8List.fromList(outPtr.asTypedList(outW * outH * 4));
    } finally {
      malloc.free(pixPtr);
      malloc.free(outPtr);
    }
  }

  static int Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    Pointer<Float>,
    int,
    Pointer<Int32>,
  )?
  _detFn;

  /// Mirrors `_detPreprocess` in one native pass (scale + round32 run
  /// inside the crate): long side <= 1280, multiple of 32, ImageNet norm.
  static ({Float32List tensor, int width, int height}) detPreprocess(
    RgbaImage tile,
  ) {
    _detFn ??= _load()
        .lookupFunction<
          Int32 Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Pointer<Float>,
            Size,
            Pointer<Int32>,
          ),
          int Function(
            Pointer<Uint8>,
            int,
            int,
            int,
            Pointer<Float>,
            int,
            Pointer<Int32>,
          )
        >('ocr_det_preprocess');
    int round32(double v) => math.max(32, (v / 32).round() * 32);
    final capW = round32(tile.width.toDouble());
    final capH = round32(tile.height.toDouble());
    final pixPtr = malloc<Uint8>(tile.pixels.length);
    final outPtr = malloc<Float>(capW * capH * 3);
    final dimsPtr = malloc<Int32>(2);
    try {
      pixPtr.asTypedList(tile.pixels.length).setAll(0, tile.pixels);
      final n = _detFn!(
        pixPtr,
        tile.pixels.length,
        tile.width,
        tile.height,
        outPtr,
        capW * capH * 3,
        dimsPtr,
      );
      if (n < 0) throw StateError('ocr_det_preprocess failed ($n)');
      final inW = dimsPtr[0], inH = dimsPtr[1];
      return (
        tensor: Float32List.fromList(outPtr.asTypedList(inW * inH * 3)),
        width: inW,
        height: inH,
      );
    } finally {
      malloc.free(pixPtr);
      malloc.free(outPtr);
      malloc.free(dimsPtr);
    }
  }

  static int Function(Pointer<Float>, int, int, int, Pointer<Int32>)? _ctcFn;
  static List<int> ctcDecodeIds(
    Float32List probs,
    int steps,
    int classes,
    int charsetLen,
  ) {
    _ctcFn ??= _load()
        .lookupFunction<
          Int32 Function(Pointer<Float>, Int32, Int32, Int32, Pointer<Int32>),
          int Function(Pointer<Float>, int, int, int, Pointer<Int32>)
        >('ocr_ctc_decode_ids');
    final probsPtr = malloc<Float>(probs.length);
    final outPtr = malloc<Int32>(steps);
    try {
      probsPtr.asTypedList(probs.length).setAll(0, probs);
      final n = _ctcFn!(probsPtr, steps, classes, charsetLen, outPtr);
      if (n < 0) throw StateError('ocr_ctc_decode_ids failed ($n)');
      return List<int>.generate(n, (i) => outPtr[i]);
    } finally {
      malloc.free(probsPtr);
      malloc.free(outPtr);
    }
  }

  /// Mirrors `_ctcDecode` end to end (charset mapping stays in Dart).
  static String ctcDecode(
    Float32List probs,
    int classes,
    List<String> charset,
  ) {
    final steps = probs.length ~/ classes;
    final ids = ctcDecodeIds(probs, steps, classes, charset.length);
    final buffer = StringBuffer();
    for (final id in ids) {
      buffer.write(charset[id]);
    }
    return buffer.toString().trim();
  }

  static int Function(Pointer<Int32>, int, Pointer<Int32>)? _dedupFn;
  static List<IntRect> dedupBoxes(List<IntRect> boxes) {
    if (boxes.isEmpty) return [];
    _dedupFn ??= _load()
        .lookupFunction<
          Int32 Function(Pointer<Int32>, Int32, Pointer<Int32>),
          int Function(Pointer<Int32>, int, Pointer<Int32>)
        >('ocr_dedup_boxes');
    final inPtr = malloc<Int32>(boxes.length * 4);
    final outPtr = malloc<Int32>(boxes.length * 4);
    try {
      final flat = inPtr.asTypedList(boxes.length * 4);
      for (var i = 0; i < boxes.length; i++) {
        flat[i * 4] = boxes[i].left;
        flat[i * 4 + 1] = boxes[i].top;
        flat[i * 4 + 2] = boxes[i].right;
        flat[i * 4 + 3] = boxes[i].bottom;
      }
      final kept = _dedupFn!(inPtr, boxes.length, outPtr);
      if (kept < 0) throw StateError('ocr_dedup_boxes failed ($kept)');
      final out = outPtr.asTypedList(kept * 4);
      return [
        for (var k = 0; k < kept; k++)
          IntRect(out[k * 4], out[k * 4 + 1], out[k * 4 + 2], out[k * 4 + 3]),
      ];
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
    int,
    Pointer<Uint8>,
    int,
    int,
  )?
  _rotateFn;

  /// Mirrors resizeTextLine(..., rotate: true): rotated bilinear resample
  /// for vertical columns. Throws on load failure; callers fall back to Dart.
  static Uint8List resizeTextLineRotated(
    RgbaImage image,
    IntRect region,
    int outW,
    int outH,
  ) {
    _rotateFn ??= _load()
        .lookupFunction<
          Int32 Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Uint8>,
            Int32,
            Int32,
          ),
          int Function(
            Pointer<Uint8>,
            int,
            int,
            int,
            int,
            int,
            int,
            Pointer<Uint8>,
            int,
            int,
          )
        >('ocr_resize_text_line_rotated');
    final pixPtr = malloc<Uint8>(image.pixels.length);
    final outPtr = malloc<Uint8>(outW * outH * 4);
    try {
      pixPtr.asTypedList(image.pixels.length).setAll(0, image.pixels);
      final rc = _rotateFn!(
        pixPtr,
        image.pixels.length,
        image.width,
        region.left,
        region.top,
        region.right,
        region.bottom,
        outPtr,
        outW,
        outH,
      );
      if (rc != 0) {
        throw StateError('ocr_resize_text_line_rotated failed');
      }
      return Uint8List.fromList(outPtr.asTypedList(outW * outH * 4));
    } finally {
      malloc.free(pixPtr);
      malloc.free(outPtr);
    }
  }

  static int Function(Pointer<Float>, int, int, int, int, Pointer<Int32>, int)?
  _postFn;

  /// Mirrors detPostprocess end to end. Throws on load failure or native
  /// overflow (-2, more boxes than the w*h/12 cap); both fall back to Dart.
  static List<IntRect> detPostprocess(
    Float32List probs,
    int w,
    int h,
    int tileWidth,
    int tileHeight,
  ) {
    _postFn ??= _load()
        .lookupFunction<
          Int32 Function(
            Pointer<Float>,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Int32>,
            Size,
          ),
          int Function(Pointer<Float>, int, int, int, int, Pointer<Int32>, int)
        >('ocr_det_postprocess');
    final probsPtr = malloc<Float>(probs.length);
    // Every kept component owns >= 12 px, so w*h/12 quads always suffice;
    // overflow still falls back to Dart instead of truncating.
    final cap = probs.length ~/ 12 + 1;
    final outPtr = malloc<Int32>(cap * 4);
    try {
      probsPtr.asTypedList(probs.length).setAll(0, probs);
      final n = _postFn!(probsPtr, w, h, tileWidth, tileHeight, outPtr, cap);
      if (n < 0) throw StateError('ocr_det_postprocess failed');
      final out = outPtr.asTypedList(n * 4);
      return [
        for (var k = 0; k < n; k++)
          IntRect(out[k * 4], out[k * 4 + 1], out[k * 4 + 2], out[k * 4 + 3]),
      ];
    } finally {
      malloc.free(probsPtr);
      malloc.free(outPtr);
    }
  }
}
