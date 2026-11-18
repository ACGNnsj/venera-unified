import 'dart:typed_data';

/// Streaming ZIP writer abstraction: one entry at a time, no staging
/// directory, no whole-archive buffering on the Dart side.
abstract interface class ZipStreamSink {
  Future<void> addStored(String name, Uint8List data);
  Future<void> addDeflated(String name, Uint8List data, {int level = 6});
  Future<void> close();
}
