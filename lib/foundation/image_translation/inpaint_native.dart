import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart'; // ponytail: malloc not calloc below; buffers fully overwritten pre-read

import 'inpaint.dart';
import 'translation_types.dart';

/// Hand-written dart:ffi binding to `native/inpaint` (venera_inpaint).
///
/// Zero-intrusion: [TextInpainter] in inpaint.dart is untouched and remains
/// the fallback. Every method here throws only when the native library cannot
/// be loaded; callers should catch and use the Dart pure functions instead.
/// No new dependencies (dart:ffi + package:ffi only, no FRB, no tokio).
abstract final class InpaintNative {
  static DynamicLibrary? _lib;
  static bool _tried = false;

  static DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (_tried) throw StateError('inpaint native library unavailable');
    _tried = true;
    final override = Platform.environment['INPAINT_NATIVE_LIB'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      if (Platform.isWindows)
        'native/inpaint/target/release/venera_inpaint.dll',
      if (Platform.isAndroid) 'libvenera_inpaint.so',
      if (Platform.isLinux) 'libvenera_inpaint.so',
      if (Platform.isMacOS) 'libvenera_inpaint.dylib',
      if (Platform.isWindows) 'venera_inpaint.dll',
    ];
    Object? lastError;
    // iOS/macOS may statically link the crate into the process.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        if (process.providesSymbol('inpaint_version')) {
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
    throw StateError('Failed to load venera_inpaint: $lastError');
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
      'inpaint_version',
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
    int,
    Pointer<Uint8>,
    Pointer<Int32>,
  )?
  _maskFn;
  static TextMask? computeMask(RgbaImage image, IntRect region) {
    _maskFn ??= _load()
        .lookupFunction<
          Int32 Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Uint8>,
            Pointer<Int32>,
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
            Pointer<Uint8>,
            Pointer<Int32>,
          )
        >('inpaint_compute_mask');
    final w = image.width;
    final h = image.height;
    final pixPtr = malloc<Uint8>(image.pixels.length);
    final maskPtr = malloc<Uint8>(w * h);
    final outPtr = malloc<Int32>(4);
    try {
      pixPtr.asTypedList(image.pixels.length).setAll(0, image.pixels);
      final count = _maskFn!(
        pixPtr,
        image.pixels.length,
        w,
        h,
        region.left,
        region.top,
        region.right,
        region.bottom,
        maskPtr,
        outPtr,
      );
      if (count < 0) return null;
      final left = outPtr[0], top = outPtr[1];
      final rw = outPtr[2], rh = outPtr[3];
      final mask = Uint8List.fromList(maskPtr.asTypedList(rw * rh));
      return TextMask(left, top, rw, rh, mask);
    } finally {
      malloc.free(pixPtr);
      malloc.free(maskPtr);
      malloc.free(outPtr);
    }
  }

  /// Mirrors [TextInpainter.erase]: sequential compute+erase per region over
  /// one native pixel transfer (later masks see earlier erases, exactly like
  /// the Dart loop). One copy in/out per page instead of per region.
  static RgbaImage erase(RgbaImage image, List<IntRect> regions) {
    _maskFn ??= _load()
        .lookupFunction<
          Int32 Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Uint8>,
            Pointer<Int32>,
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
            Pointer<Uint8>,
            Pointer<Int32>,
          )
        >('inpaint_compute_mask');
    _eraseFn ??= _load()
        .lookupFunction<
          Void Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Uint8>,
          ),
          void Function(
            Pointer<Uint8>,
            int,
            int,
            int,
            int,
            int,
            int,
            Pointer<Uint8>,
          )
        >('inpaint_erase');
    final w = image.width;
    final h = image.height;
    final pixPtr = malloc<Uint8>(image.pixels.length);
    final maskPtr = malloc<Uint8>(w * h);
    final outPtr = malloc<Int32>(4);
    try {
      pixPtr.asTypedList(image.pixels.length).setAll(0, image.pixels);
      for (final region in regions) {
        final count = _maskFn!(
          pixPtr,
          image.pixels.length,
          w,
          h,
          region.left,
          region.top,
          region.right,
          region.bottom,
          maskPtr,
          outPtr,
        );
        if (count < 0) continue;
        _eraseFn!(
          pixPtr,
          image.pixels.length,
          w,
          outPtr[0],
          outPtr[1],
          outPtr[2],
          outPtr[3],
          maskPtr,
        );
      }
      image.pixels.setAll(0, pixPtr.asTypedList(image.pixels.length));
    } finally {
      malloc.free(pixPtr);
      malloc.free(maskPtr);
      malloc.free(outPtr);
    }
    return image;
  }

  static void Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
  )?
  _eraseFn;
  static void eraseWithMask(RgbaImage image, TextMask m) {
    _eraseFn ??= _load()
        .lookupFunction<
          Void Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Uint8>,
          ),
          void Function(
            Pointer<Uint8>,
            int,
            int,
            int,
            int,
            int,
            int,
            Pointer<Uint8>,
          )
        >('inpaint_erase');
    _runWindow(_eraseFn!, image, m, null);
  }

  static void Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
  )?
  _fillFn;
  static void fill(RgbaImage image, TextMask m) {
    _fillFn ??= _load()
        .lookupFunction<
          Void Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Uint8>,
          ),
          void Function(
            Pointer<Uint8>,
            int,
            int,
            int,
            int,
            int,
            int,
            Pointer<Uint8>,
          )
        >('inpaint_fill');
    _runWindow(_fillFn!, image, m, null);
  }

  static void Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
    int,
  )?
  _relaxFn;
  static void relax(RgbaImage image, TextMask m, int passes) {
    _relaxFn ??= _load()
        .lookupFunction<
          Void Function(
            Pointer<Uint8>,
            Size,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Pointer<Uint8>,
            Int32,
          ),
          void Function(
            Pointer<Uint8>,
            int,
            int,
            int,
            int,
            int,
            int,
            Pointer<Uint8>,
            int,
          )
        >('inpaint_relax');
    _runWindow(_relaxFn!, image, m, passes);
  }

  static void _runWindow(
    Function fn,
    RgbaImage image,
    TextMask m,
    int? passes,
  ) {
    final pixPtr = malloc<Uint8>(image.pixels.length);
    final maskPtr = malloc<Uint8>(m.mask.length);
    try {
      pixPtr.asTypedList(image.pixels.length).setAll(0, image.pixels);
      maskPtr.asTypedList(m.mask.length).setAll(0, m.mask);
      if (passes == null) {
        (fn
            as void Function(
              Pointer<Uint8>,
              int,
              int,
              int,
              int,
              int,
              int,
              Pointer<Uint8>,
            ))(
          pixPtr,
          image.pixels.length,
          image.width,
          m.left,
          m.top,
          m.rw,
          m.rh,
          maskPtr,
        );
      } else {
        (fn
            as void Function(
              Pointer<Uint8>,
              int,
              int,
              int,
              int,
              int,
              int,
              Pointer<Uint8>,
              int,
            ))(
          pixPtr,
          image.pixels.length,
          image.width,
          m.left,
          m.top,
          m.rw,
          m.rh,
          maskPtr,
          passes,
        );
      }
      image.pixels.setAll(0, pixPtr.asTypedList(image.pixels.length));
    } finally {
      malloc.free(pixPtr);
      malloc.free(maskPtr);
    }
  }
}
