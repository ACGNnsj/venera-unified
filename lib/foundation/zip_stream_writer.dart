import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'zip_stream_native.dart';
import 'zip_stream_sink.dart';

/// Ordering shared with [ZipStreamWriter.writeDirectory]: EPUB requires its
/// `mimetype` entry to come first; every other archive does not care about
/// order, so the rule is applied unconditionally.
int compareArchivePaths(String a, String b) {
  if (a == b) return 0;
  if (a == 'mimetype') return -1;
  if (b == 'mimetype') return 1;
  return a.compareTo(b);
}

/// Streaming ZIP writer used by exports.
///
/// [openSink] prefers the Rust writer (`native/zip_stream`, same
/// hand-written `dart:ffi` pattern as `pdf_jpg_native.dart`) and falls back
/// to [DartZipStreamSink] when its library is unavailable, so output is
/// identical on every platform. Entries flush one at a time: at most one
/// file's bytes sit in memory, never the whole archive. `mimetype` is stored
/// uncompressed to satisfy the EPUB container spec.
abstract final class ZipStreamWriter {
  /// Opens [destinationPath] for streaming writes (native when available).
  static Future<ZipStreamSink> openSink(String destinationPath) async {
    final native = ZipStreamNative.tryOpenSink(destinationPath);
    if (native != null) return native;
    return DartZipStreamSink.open(destinationPath);
  }

  /// Streams [sourceDirectory] into [destinationPath] entry by entry.
  ///
  /// [storeEntry] selects stored (uncompressed) entries; it defaults to
  /// storing only `mimetype`. A failure deletes the partial archive.
  static Future<void> writeDirectory(
    String sourceDirectory,
    String destinationPath, {
    bool Function(String archivePath)? storeEntry,
  }) async {
    final store = storeEntry ?? (name) => name == 'mimetype';
    final root = Directory(sourceDirectory);
    final files = await root
        .list(recursive: true)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    final entries =
        files
            .map((file) => MapEntry(_archivePath(file.path, root.path), file))
            .toList()
          ..sort((a, b) => compareArchivePaths(a.key, b.key));
    final sink = await openSink(destinationPath);
    try {
      for (final entry in entries) {
        final bytes = await entry.value.readAsBytes();
        if (store(entry.key)) {
          await sink.addStored(entry.key, bytes);
        } else {
          await sink.addDeflated(entry.key, bytes);
        }
      }
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await File(destinationPath).delete();
      } catch (_) {}
      rethrow;
    }
  }

  static String _archivePath(String filePath, String rootPath) =>
      p.split(p.relative(filePath, from: rootPath)).join('/');
}

/// One open archive; entries append in call order, the central directory and
/// end record land on [close].
/// Pure-Dart [ZipStreamSink]: local headers stream per entry, central
/// directory + end record land on [close]. Deterministic output (fixed DOS
/// timestamp); no zip64 in this PoC (entries are capped below 4 GiB).
final class DartZipStreamSink implements ZipStreamSink {
  DartZipStreamSink._(this._out);

  static Future<DartZipStreamSink> open(String destinationPath) async {
    return DartZipStreamSink._(File(destinationPath).openWrite());
  }

  final IOSink _out;
  int _offset = 0;
  final List<_CentralEntry> _central = [];
  bool _closed = false;

  void _addBytes(List<int> bytes) {
    _out.add(bytes);
    _offset += bytes.length;
  }

  void _appendEntry(String name, Uint8List raw, Uint8List payload, int method) {
    if (_closed) throw StateError('ZipStreamSink is closed');
    final nameBytes = utf8.encode(name);
    if (nameBytes.isEmpty || nameBytes.length > 0xffff) {
      throw ArgumentError('ZIP entry name must be 1..65535 UTF-8 bytes');
    }
    if (raw.length > 0xffffffff || payload.length > 0xffffffff) {
      throw ArgumentError('ZIP entry exceeds 4 GiB; zip64 is out of scope');
    }
    final crc = _crc32(raw);
    final headerOffset = _offset;
    final header = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x0800, Endian.little) // UTF-8 names
      ..setUint16(8, method, Endian.little)
      ..setUint16(10, 0, Endian.little) // DOS time
      ..setUint16(12, 0x5021, Endian.little) // DOS date: 2020-01-01
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, payload.length, Endian.little)
      ..setUint32(22, raw.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 0, Endian.little); // extra length
    _addBytes(header.buffer.asUint8List());
    _addBytes(nameBytes);
    _addBytes(payload);
    _central.add(
      _CentralEntry(
        nameBytes,
        crc,
        payload.length,
        raw.length,
        headerOffset,
        method,
      ),
    );
  }

  @override
  Future<void> addStored(String name, Uint8List data) async {
    _appendEntry(name, data, data, 0);
  }

  @override
  Future<void> addDeflated(String name, Uint8List data, {int level = 6}) async {
    _appendEntry(name, data, _rawDeflate(data, level), 8);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_central.length > 0xffff) {
      throw StateError('ZIP entry count exceeds 64k; zip64 is out of scope');
    }
    final centralOffset = _offset;
    for (final entry in _central) {
      final header = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little) // version made by
        ..setUint16(6, 20, Endian.little) // version needed
        ..setUint16(8, 0x0800, Endian.little)
        ..setUint16(10, entry.method, Endian.little)
        ..setUint16(12, 0, Endian.little)
        ..setUint16(14, 0x5021, Endian.little)
        ..setUint32(16, entry.crc, Endian.little)
        ..setUint32(20, entry.compressedSize, Endian.little)
        ..setUint32(24, entry.size, Endian.little)
        ..setUint16(28, entry.name.length, Endian.little)
        ..setUint16(30, 0, Endian.little) // extra
        ..setUint16(32, 0, Endian.little) // comment
        ..setUint16(34, 0, Endian.little) // disk
        ..setUint16(36, 0, Endian.little) // internal attrs
        ..setUint32(38, 0, Endian.little) // external attrs
        ..setUint32(42, entry.headerOffset, Endian.little);
      _addBytes(header.buffer.asUint8List());
      _addBytes(entry.name);
    }
    final centralSize = _offset - centralOffset;
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(4, 0, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, _central.length, Endian.little)
      ..setUint16(10, _central.length, Endian.little)
      ..setUint32(12, centralSize, Endian.little)
      ..setUint32(16, centralOffset, Endian.little)
      ..setUint16(20, 0, Endian.little);
    _addBytes(end.buffer.asUint8List());
    await _out.close();
  }
}

final class _CentralEntry {
  _CentralEntry(
    this.name,
    this.crc,
    this.compressedSize,
    this.size,
    this.headerOffset,
    this.method,
  );

  final Uint8List name;
  final int crc;
  final int compressedSize;
  final int size;
  final int headerOffset;
  final int method;
}

List<int>? _crcTable;

int _crc32(Uint8List data) {
  _crcTable ??= List<int>.generate(256, (i) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  var crc = 0xffffffff;
  for (final byte in data) {
    crc = (_crcTable![(crc ^ byte) & 0xff] ^ (crc >> 8)) & 0xffffffff;
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

/// Raw deflate stream for a ZIP entry: dart:io emits RFC 1950
/// (2-byte header + deflate + 4-byte Adler-32); the wrapper is stripped.
Uint8List _rawDeflate(Uint8List data, int level) {
  final clamped = level < 0 ? 0 : (level > 9 ? 9 : level);
  final wrapped = Uint8List.fromList(ZLibCodec(level: clamped).encode(data));
  if (wrapped.length < 6 || wrapped[0] != 0x78) {
    throw StateError('Unexpected zlib framing from ZLibCodec');
  }
  return Uint8List.sublistView(wrapped, 2, wrapped.length - 4);
}
