import 'dart:io';
import 'dart:typed_data';

const _localHeaderSignature = 0x04034b50;

/// Reads one ZIP entry straight from the central-directory offsets.
///
/// archive's lazy entry objects hold a stream position that some archives
/// written by other tools do not match, and the native zip library is not
/// available on every platform we ship. The central directory already reports
/// where each local header and its data live, so this reader goes there
/// directly instead of relying on either.
///
/// Returns the uncompressed bytes of the entry. Throws a [FormatException] for
/// malformed, encrypted, truncated or unsupported entries so callers keep
/// reporting the same "Archive entry could not be read" class of failure.
Uint8List readZipEntry(
  Uint8List bytes, {
  required int localHeaderOffset,
  required int compressedSize,
  required int uncompressedSize,
  required int compressionMethod,
}) {
  if (localHeaderOffset < 0 || localHeaderOffset + 30 > bytes.length) {
    throw const FormatException('Archive entry header is out of bounds');
  }
  if (_readUint32(bytes, localHeaderOffset) != _localHeaderSignature) {
    throw const FormatException('Archive entry header is invalid');
  }
  final flags = _readUint16(bytes, localHeaderOffset + 6);
  if (flags & 0x1 != 0) {
    throw const FormatException('Encrypted archives are not supported');
  }
  final nameLength = _readUint16(bytes, localHeaderOffset + 26);
  final extraLength = _readUint16(bytes, localHeaderOffset + 28);
  final dataStart = localHeaderOffset + 30 + nameLength + extraLength;
  if (compressedSize < 0 ||
      uncompressedSize < 0 ||
      dataStart + compressedSize > bytes.length) {
    throw const FormatException('Archive entry data is out of bounds');
  }
  final raw = Uint8List.sublistView(
    bytes,
    dataStart,
    dataStart + compressedSize,
  );
  final content = switch (compressionMethod) {
    0 => Uint8List.fromList(raw),
    8 => _inflate(raw),
    _ => throw const FormatException('Unsupported archive compression'),
  };
  if (content.length != uncompressedSize) {
    throw const FormatException('Archive entry size mismatch');
  }
  return content;
}

Uint8List _inflate(Uint8List raw) {
  try {
    final decoded = ZLibDecoder(raw: true).convert(raw);
    return decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
  } catch (_) {
    throw const FormatException('Archive entry could not be inflated');
  }
}

int _readUint16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _readUint32(Uint8List bytes, int offset) =>
    _readUint16(bytes, offset) | (_readUint16(bytes, offset + 2) << 16);
