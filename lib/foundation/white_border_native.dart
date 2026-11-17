import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Hand-written dart:ffi binding to `native/white_border`
/// (venera_white_border).
///
/// Zero-intrusion: [ReaderWhiteBorderCrop] keeps its `compute` fallback; this
/// method returns null whenever the native library cannot be loaded or
/// rejects the buffer, and callers fall back to the Dart pixel loop.
/// No new dependencies (dart:ffi + package:ffi only).
abstract final class WhiteBorderNative {
  static DynamicLibrary? _lib;
  static bool _tried = false;

  static DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (_tried) throw StateError('white border native library unavailable');
    _tried = true;
    final override = Platform.environment['WHITE_BORDER_NATIVE_LIB'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      if (Platform.isWindows)
        'native/white_border/target/release/venera_white_border.dll',
      if (Platform.isAndroid) 'libvenera_white_border.so',
      if (Platform.isLinux) 'libvenera_white_border.so',
      if (Platform.isMacOS) 'libvenera_white_border.dylib',
      // Release bundles: Linux ships the .so in bundle/lib, macOS in
      // Frameworks; a bare soname won't resolve there, so add the
      // exe-relative absolute path (missing files just fail this candidate).
      if (Platform.isLinux)
        '${File(Platform.resolvedExecutable).parent.path}/lib/libvenera_white_border.so',
      if (Platform.isMacOS)
        '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/libvenera_white_border.dylib',
      if (Platform.isWindows) 'venera_white_border.dll',
    ];
    Object? lastError;
    // iOS/macOS may statically link the crate into the process.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        if (process.providesSymbol('white_border_version')) {
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
    throw StateError('Failed to load venera_white_border: $lastError');
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
      'white_border_version',
    );
    return _versionFn!();
  }

  static int Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    Pointer<Int32>,
    Pointer<Int32>,
  )? _insetsFn;

  /// Mirrors [horizontalWhiteBorderInsets]: scans a w*h RGBA buffer and
  /// returns the kept (left, right) insets, or null when the native library
  /// is unavailable or rejects the buffer; callers fall back to Dart.
  static (int, int)? insetsOrNull(Uint8List rgba, int width, int height) {
    try {
      _insetsFn ??= _load()
          .lookupFunction<
            Int32 Function(
              Pointer<Uint8>,
              IntPtr,
              Int32,
              Int32,
              Pointer<Int32>,
              Pointer<Int32>,
            ),
            int Function(
              Pointer<Uint8>,
              int,
              int,
              int,
              Pointer<Int32>,
              Pointer<Int32>,
            )
          >('white_border_insets');
      final inPtr = malloc<Uint8>(rgba.length);
      final outLeft = malloc<Int32>(1);
      final outRight = malloc<Int32>(1);
      try {
        inPtr.asTypedList(rgba.length).setAll(0, rgba);
        final rc = _insetsFn!(
          inPtr,
          rgba.length,
          width,
          height,
          outLeft,
          outRight,
        );
        if (rc != 0) return null;
        return (outLeft.value, outRight.value);
      } finally {
        malloc.free(inPtr);
        malloc.free(outLeft);
        malloc.free(outRight);
      }
    } catch (_) {
      return null;
    }
  }
}
