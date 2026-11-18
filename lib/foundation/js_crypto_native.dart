import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Hand-written dart:ffi binding to `native/js_crypto` (venera_js_crypto).
///
/// Zero-intrusion: `JsEngine._convert` tries these first and falls back to
/// the pure-Dart implementation (package:crypto / pointycastle) whenever the
/// library is unavailable or reports an error, so per-source API parity holds
/// on every platform. No new dependencies (dart:ffi + package:ffi only).
///
/// V1 scope: hashes, HMAC, AES-ECB/CBC.
/// # ponytail: AES-CFB/OFB + RSA stay in Dart until latency data shows they
/// matter; each is one Rust fn + one try-method here.
abstract final class JsCryptoNative {
  static DynamicLibrary? _lib;
  static bool _tried = false;

  static DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (_tried) throw StateError('js_crypto native library unavailable');
    _tried = true;
    final override = Platform.environment['JS_CRYPTO_NATIVE_LIB'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      if (Platform.isWindows)
        'native/js_crypto/target/release/venera_js_crypto.dll',
      if (Platform.isAndroid) 'libvenera_js_crypto.so',
      if (Platform.isLinux) 'libvenera_js_crypto.so',
      if (Platform.isMacOS) 'libvenera_js_crypto.dylib',
      if (Platform.isLinux)
        '${File(Platform.resolvedExecutable).parent.path}/lib/libvenera_js_crypto.so',
      if (Platform.isMacOS)
        '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/libvenera_js_crypto.dylib',
      if (Platform.isWindows) 'venera_js_crypto.dll',
    ];
    Object? lastError;
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        if (process.providesSymbol('js_crypto_version')) {
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
    throw StateError('Failed to load venera_js_crypto: $lastError');
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
      'js_crypto_version',
    );
    return _versionFn!();
  }

  /// Hash ids: 1 md5, 2 sha1, 3 sha256, 4 sha512. Null = use Dart fallback.
  static Uint8List? tryHash(int algo, List<int> data) {
    try {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      final inPtr = malloc<Uint8>((bytes.isEmpty ? 1 : bytes.length));
      final outPtr = malloc<Uint8>(64);
      try {
        if (bytes.isNotEmpty) {
          inPtr.asTypedList(bytes.length).setAll(0, bytes);
        }
        final fn = _load()
            .lookupFunction<
              Int32 Function(
                Uint32,
                Pointer<Uint8>,
                Size,
                Pointer<Uint8>,
                Size,
              ),
              int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int)
            >('js_crypto_hash');
        final rc = fn(algo, inPtr, bytes.length, outPtr, 64);
        if (rc <= 0) return null;
        return Uint8List.fromList(outPtr.asTypedList(rc));
      } finally {
        malloc.free(inPtr);
        malloc.free(outPtr);
      }
    } catch (_) {
      return null;
    }
  }

  /// HMAC over [data] with [key]. Same hash ids as [tryHash].
  static Uint8List? tryHmac(int hash, List<int> key, List<int> data) {
    try {
      if (hash < 1 || hash > 4) return null;
      final keyBytes = key is Uint8List ? key : Uint8List.fromList(key);
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      final keyPtr = malloc<Uint8>((keyBytes.isEmpty ? 1 : keyBytes.length));
      final inPtr = malloc<Uint8>((bytes.isEmpty ? 1 : bytes.length));
      final outPtr = malloc<Uint8>(64);
      try {
        if (keyBytes.isNotEmpty) {
          keyPtr.asTypedList(keyBytes.length).setAll(0, keyBytes);
        }
        if (bytes.isNotEmpty) {
          inPtr.asTypedList(bytes.length).setAll(0, bytes);
        }
        final fn = _load()
            .lookupFunction<
              Int32 Function(
                Uint32,
                Pointer<Uint8>,
                Size,
                Pointer<Uint8>,
                Size,
                Pointer<Uint8>,
                Size,
              ),
              int Function(
                int,
                Pointer<Uint8>,
                int,
                Pointer<Uint8>,
                int,
                Pointer<Uint8>,
                int,
              )
            >('js_crypto_hmac');
        final rc = fn(
          hash,
          keyPtr,
          keyBytes.length,
          inPtr,
          bytes.length,
          outPtr,
          64,
        );
        if (rc <= 0) return null;
        return Uint8List.fromList(outPtr.asTypedList(rc));
      } finally {
        malloc.free(keyPtr);
        malloc.free(inPtr);
        malloc.free(outPtr);
      }
    } catch (_) {
      return null;
    }
  }

  /// Raw-block AES (no padding, like the pointycastle processBlock loops).
  /// mode: 1 ECB, 2 CBC. Null = use Dart fallback (incl. short/empty input,
  /// which Dart answers itself).
  static Uint8List? tryAes(
    int mode,
    bool encrypt,
    List<int> key,
    List<int>? iv,
    List<int> data,
  ) {
    try {
      if (data.isEmpty || data.length % 16 != 0) return null;
      if (mode != 1 && mode != 2) return null;
      final keyBytes = key is Uint8List ? key : Uint8List.fromList(key);
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      final ivBytes = iv == null
          ? null
          : (iv is Uint8List ? iv : Uint8List.fromList(iv));
      final keyPtr = malloc<Uint8>((keyBytes.isEmpty ? 1 : keyBytes.length));
      final inPtr = malloc<Uint8>(bytes.length);
      final outPtr = malloc<Uint8>(bytes.length);
      final ivPtr = malloc<Uint8>(
        ivBytes == null || ivBytes.isEmpty ? 1 : ivBytes.length,
      );
      try {
        if (keyBytes.isNotEmpty) {
          keyPtr.asTypedList(keyBytes.length).setAll(0, keyBytes);
        }
        inPtr.asTypedList(bytes.length).setAll(0, bytes);
        if (ivBytes != null && ivBytes.isNotEmpty) {
          ivPtr.asTypedList(ivBytes.length).setAll(0, ivBytes);
        }
        final fn = _load()
            .lookupFunction<
              Int32 Function(
                Uint32,
                Uint32,
                Pointer<Uint8>,
                Size,
                Pointer<Uint8>,
                Size,
                Pointer<Uint8>,
                Size,
                Pointer<Uint8>,
                Size,
              ),
              int Function(
                int,
                int,
                Pointer<Uint8>,
                int,
                Pointer<Uint8>,
                int,
                Pointer<Uint8>,
                int,
                Pointer<Uint8>,
                int,
              )
            >('js_crypto_aes');
        final rc = fn(
          mode,
          encrypt ? 1 : 0,
          keyPtr,
          keyBytes.length,
          ivPtr,
          ivBytes?.length ?? 0,
          inPtr,
          bytes.length,
          outPtr,
          bytes.length,
        );
        if (rc != bytes.length) return null;
        return Uint8List.fromList(outPtr.asTypedList(bytes.length));
      } finally {
        malloc.free(keyPtr);
        malloc.free(inPtr);
        malloc.free(outPtr);
        malloc.free(ivPtr);
      }
    } catch (_) {
      return null;
    }
  }
}
