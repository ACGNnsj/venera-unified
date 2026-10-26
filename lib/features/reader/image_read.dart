import 'package:venera_unified/foundation/cache_manager.dart';
import 'package:venera_unified/foundation/file_system.dart';
import 'image_position.dart';

/// Reads the original address and keeps the accepted cache/file Future. The
/// caller's ImageWork owns cancellation and waits for its actual completion.
Future<Uint8List?> readReaderImageBytes(ReaderImageAddress image) async {
  if (image.imageKey.startsWith('file://')) {
    return File(image.imageKey.substring(7)).readAsBytes();
  }
  final file = await CacheManager().findCache(image.cacheKey);
  return file?.readAsBytes();
}
