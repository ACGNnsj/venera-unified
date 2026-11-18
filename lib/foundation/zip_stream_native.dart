import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'zip_stream_sink.dart';


/// Hand-written dart:ffi binding to `native/zip_stream` (venera_zip_stream).
///
/// Zero-intrusion: [ZipStreamWriter.openSink] uses [tryOpenSink] and falls
/// back to the pure-Dart writer when this library is unavailable. Every
/// method throws only when the native library cannot be loaded or reports an
/// error. No new dependencies (dart:ffi + package:ffi only, no FRB, no
/// tokio).
abstract final class ZipStreamNative {
  static DynamicLibrary? _lib;
  static bool _tried = false;

  static DynamicLibrary _load() {
    if (_lib != null) return _lib!;
    if (_tried) throw StateError('zip_stream native library unavailable');
    _tried = true;
    final override = Platform.environment['ZIP_STREAM_NATIVE_LIB'];
    final candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      if (Platform.isWindows)
        'native/zip_stream/target/release/venera_zip_stream.dll',
      if (Platform.isAndroid) 'libvenera_zip_stream.so',
      if (Platform.isLinux) 'libvenera_zip_stream.so',
      if (Platform.isMacOS) 'libvenera_zip_stream.dylib',
      if (Platform.isLinux)
        '${File(Platform.resolvedExecutable).parent.path}/lib/libvenera_zip_stream.so',
      if (Platform.isMacOS)
        '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/libvenera_zip_stream.dylib',
      if (Platform.isWindows) 'venera_zip_stream.dll',
    ];
    Object? lastError;
    if (Platform.isMacOS || Platform.isIOS) {
      try {
        final process = DynamicLibrary.process();
        if (process.providesSymbol('zip_stream_version')) {
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
    throw StateError('Failed to load venera_zip_stream: $lastError');
  }

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
      'zip_stream_version',
    );
    return _versionFn!();
  }

  static int Function(
    int,
    Pointer<Uint8>,
    int,
    Pointer<Uint8>,
    int,
    int,
    int,
  )? _addFn;
  static void _add(
    int handle,
    Uint8List name,
    Uint8List data,
    int method,
    int level,
  ) {
    _addFn ??= _load()
        .lookupFunction<
          Int32 Function(
            Int64,
            Pointer<Uint8>,
            Size,
            Pointer<Uint8>,
            Size,
            Uint32,
            Uint8,
          ),
          int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int, int, int)
        >('zip_stream_add');
    final namePtr = _copy(name);
    final dataPtr = _copy(data);
    try {
      final clamped = level < 0 ? 0 : (level > 9 ? 9 : level);
      final rc = _addFn!(
        handle,
        namePtr,
        name.length,
        dataPtr,
        data.length,
        method,
        clamped,
      );
      if (rc != 0) throw StateError('zip_stream_add failed: $rc');
    } finally {
      _free(namePtr);
      _free(dataPtr);
    }
  }

  static int Function(Pointer<Uint8>, int)? _openFn;
  static int open(String destinationPath) {
    _openFn ??= _load()
        .lookupFunction<
          Int64 Function(Pointer<Uint8>, Size),
          int Function(Pointer<Uint8>, int)
        >('zip_stream_open');
    final pathBytes = utf8.encode(destinationPath);
    final pathPtr = _copy(pathBytes);
    try {
      final handle = _openFn!(pathPtr, pathBytes.length);
      if (handle <= 0) throw StateError('zip_stream_open failed: $handle');
      return handle;
    } finally {
      _free(pathPtr);
    }
  }

  static int Function(int)? _closeFn;
  static void close(int handle) {
    _closeFn ??= _load()
        .lookupFunction<Int32 Function(Int64), int Function(int)>(
          'zip_stream_close',
        );
    final rc = _closeFn!(handle);
    if (rc != 0) throw StateError('zip_stream_close failed: $rc');
  }

  static Pointer<Uint8> _copy(List<int> bytes) {
    if (bytes.isEmpty) return nullptr;
    final ptr = malloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return ptr;
  }

  static void _free(Pointer<Uint8> ptr) {
    if (ptr != nullptr) malloc.free(ptr);
  }

  static ZipStreamSink? tryOpenSink(String destinationPath) {
    try {
      if (!available) return null;
      return _NativeZipStreamSink(open(destinationPath));
    } catch (_) {
      return null;
    }
  }
}

final class _NativeZipStreamSink implements ZipStreamSink {
  _NativeZipStreamSink(this._handle);

  final int _handle;
  bool _closed = false;

  void _add(Uint8List name, Uint8List data, int method, int level) {
    if (_closed) throw StateError('ZipStreamSink is closed');
    if (name.isEmpty || name.length > 0xffff) {
      throw ArgumentError('ZIP entry name must be 1..65535 UTF-8 bytes');
    }
    try {
      ZipStreamNative._add(_handle, name, data, method, level);
    } catch (_) {
      try {
        ZipStreamNative.close(_handle);
      } catch (_) {}
      _closed = true;
      rethrow;
    }
  }

  @override
  Future<void> addStored(String name, Uint8List data) async {
    _add(Uint8List.fromList(utf8.encode(name)), data, 0, 0);
  }

  @override
  Future<void> addDeflated(String name, Uint8List data, {int level = 6}) async {
    _add(Uint8List.fromList(utf8.encode(name)), data, 8, level);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ZipStreamNative.close(_handle);
  }
}
