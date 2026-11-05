import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart'; // ponytail: malloc not calloc below; buffers fully overwritten pre-read

/// Hand-written dart:ffi binding to `native/jpg_encode` (venera_jpg_encode).
///
/// Zero-intrusion: [_encodePdfPage] in pdf_import.dart keeps its package:image
/// body as the fallback. Every method here throws only when the native
/// library cannot be loaded or reports an error; callers should catch and use
/// the Dart path instead. No new dependencies (dart:ffi + package:ffi only,
/// no FRB, no tokio).
abstract final class JpgEncodeNative {
  static DynamicLibrary? _lib;
  static bool _tried = false;

  static DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (_tried) throw StateError('jpg_encode native library unavailable');
    _tried = true;
    final override = Platform.environment['JPG_ENCODE_NATIVE_LIB'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      if (Platform.isWindows)
        'native/jpg_encode/target/release/venera_jpg_encode.dll',
      if (Platform.isAndroid) 'libvenera_jpg_encode.so',
      if (Platform.isLinux) 'libvenera_jpg_encode.so',
      if (Platform.isMacOS) 'libvenera_jpg_encode.dylib',
      // Release bundles: Linux ships the .so in bundle/lib, macOS in
      // Frameworks; a bare soname won't resolve there, so add the
      // exe-relative absolute path (missing files just fail this candidate).
      if (Platform.isLinux)
        '${File(Platform.resolvedExecutable).parent.path}/lib/libvenera_jpg_encode.so',
      if (Platform.isMacOS)
        '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/libvenera_jpg_encode.dylib',
      if (Platform.isWindows) 'venera_jpg_encode.dll',
    ];
    Object? lastError;
    // iOS/macOS may statically link the crate into the process.
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        if (process.providesSymbol('jpg_encode_version')) {
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
    throw StateError('Failed to load venera_jpg_encode: $lastError');
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
      'jpg_encode_version',
    );
    return _versionFn!();
  }

  static int Function(
    Pointer<Uint8>,
    int,
    int,
    int,
    int,
    Pointer<Pointer<Uint8>>,
    Pointer<Size>,
  )?
  _encodeFn;
  static void Function(Pointer<Uint8>, int)? _freeFn;

  /// Encode straight BGRA pixels to a JPEG blob (quality 1-100, clamped
  /// natively). Throws on load/encode failure so callers fall back to Dart.
  static Uint8List encodeBgra(
    Uint8List bgra,
    int width,
    int height, {
    int quality = 92,
  }) {
    _encodeFn ??= _load()
        .lookupFunction<
          Int64 Function(
            Pointer<Uint8>,
            Size,
            Uint32,
            Uint32,
            Uint8,
            Pointer<Pointer<Uint8>>,
            Pointer<Size>,
          ),
          int Function(
            Pointer<Uint8>,
            int,
            int,
            int,
            int,
            Pointer<Pointer<Uint8>>,
            Pointer<Size>,
          )
        >('jpg_encode_bgra');
    _freeFn ??= _load()
        .lookupFunction<
          Void Function(Pointer<Uint8>, Size),
          void Function(Pointer<Uint8>, int)
        >('jpg_encode_free');
    final inPtr = malloc<Uint8>(bgra.length);
    final outDataPtr = malloc<Pointer<Uint8>>();
    final outLenPtr = malloc<Size>();
    try {
      inPtr.asTypedList(bgra.length).setAll(0, bgra);
      final rc = _encodeFn!(
        inPtr,
        bgra.length,
        width,
        height,
        quality,
        outDataPtr,
        outLenPtr,
      );
      if (rc < 0) throw StateError('jpg_encode_bgra failed: $rc');
      final len = outLenPtr.value;
      final outPtr = outDataPtr.value;
      if (len <= 0 || len != rc || outPtr == nullptr) {
        throw StateError('jpg_encode_bgra bad output (rc=$rc, len=$len)');
      }
      try {
        return Uint8List.fromList(outPtr.asTypedList(len));
      } finally {
        _freeFn!(outPtr, len);
      }
    } finally {
      malloc.free(inPtr);
      malloc.free(outDataPtr);
      malloc.free(outLenPtr);
    }
  }
}
