import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart'; // ponytail: malloc not calloc below; buffers fully overwritten pre-read

/// Hand-written dart:ffi binding to `native/image_transpose`
/// (venera_transpose).
///
/// Zero-intrusion: [Image.copyAndRotate90] in image_processing.dart is
/// untouched and remains the fallback. This method throws only when the
/// native library cannot be loaded; callers should catch and use the Dart
/// pixel loop instead. No new dependencies (dart:ffi + package:ffi only).
abstract final class ImageTransposeNative {
  static DynamicLibrary? _lib;
  static bool _tried = false;

  static DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (_tried) throw StateError('transpose native library unavailable');
    _tried = true;
    final override = Platform.environment['TRANSPOSE_NATIVE_LIB'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      if (Platform.isWindows)
        'native/image_transpose/target/release/venera_transpose.dll',
      if (Platform.isAndroid) 'libvenera_transpose.so',
      if (Platform.isLinux) 'libvenera_transpose.so',
      if (Platform.isMacOS) 'libvenera_transpose.dylib',
      // Release bundles: Linux ships the .so in bundle/lib, macOS in
      // Frameworks; a bare soname won't resolve there, so add the
      // exe-relative absolute path (missing files just fail this candidate).
      if (Platform.isLinux)
        '${File(Platform.resolvedExecutable).parent.path}/lib/libvenera_transpose.so',
      if (Platform.isMacOS)
        '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/libvenera_transpose.dylib',
      if (Platform.isWindows) 'venera_transpose.dll',
    ];
    Object? lastError;
    // iOS/macOS may statically link the crate into the process.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        if (process.providesSymbol('image_transpose_version')) {
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
    throw StateError('Failed to load venera_transpose: $lastError');
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
      'image_transpose_version',
    );
    return _versionFn!();
  }

  static int Function(Pointer<Uint32>, int, int, Pointer<Uint32>)? _transposeFn;

  /// Mirrors [Image.copyAndRotate90]: whole-image 90-degree transpose of a
  /// w*h u32 pixel buffer, returning the new (h*w) buffer. Throws on load
  /// failure or a negative return code; callers fall back to Dart.
  static Uint32List transpose(Uint32List pixels, int width, int height) {
    _transposeFn ??= _load()
        .lookupFunction<
          Int32 Function(Pointer<Uint32>, Int32, Int32, Pointer<Uint32>),
          int Function(Pointer<Uint32>, int, int, Pointer<Uint32>)
        >('image_transpose_u32');
    final inPtr = malloc<Uint32>(pixels.length);
    final outPtr = malloc<Uint32>(pixels.length);
    try {
      inPtr.asTypedList(pixels.length).setAll(0, pixels);
      final rc = _transposeFn!(inPtr, width, height, outPtr);
      if (rc != 0) throw StateError('image_transpose_u32 failed ($rc)');
      return Uint32List.fromList(outPtr.asTypedList(pixels.length));
    } finally {
      malloc.free(inPtr);
      malloc.free(outPtr);
    }
  }
}
