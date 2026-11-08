import 'dart:async';

import 'package:venera_unified/features/history/history_api.dart';
import 'package:venera_unified/foundation/file_interaction.dart';
import 'package:venera_unified/foundation/file_type.dart';

/// Thrown by the caller's stop check when the user cancels a batch download.
class ImageFavoritesDownloadCancelled implements Exception {
  const ImageFavoritesDownloadCancelled();
}

/// One selected gallery image together with the comic it was liked in.
class ImageFavoritesDownloadEntry {
  const ImageFavoritesDownloadEntry({
    required this.image,
    required this.comicTitle,
    required this.chapterName,
  });

  final ImageFavorite image;
  final String comicTitle;
  final String chapterName;

  /// File name of this entry once [extension] (including the dot) is known.
  String fileName(String extension) => imageFavoritesDownloadFileName(
    comicTitle: comicTitle,
    chapterName: chapterName,
    page: image.page,
    extension: extension,
  );
}

/// File name of one saved gallery image. The comic title stays in the name so
/// a flat directory keeps its images distinguishable.
String imageFavoritesDownloadFileName({
  required String comicTitle,
  required String chapterName,
  required int page,
  required String extension,
}) => sanitizeFileNameWithSuffix(
  comicTitle,
  middle: ' - $chapterName - ${page + 1}',
  extension: extension,
);

/// Collects the selected images with their comic and chapter. Selections that
/// are no longer present in [comics] are dropped instead of guessed.
List<ImageFavoritesDownloadEntry> planImageFavoritesDownload({
  required List<ImageFavoritesComic> comics,
  required Map<ImageFavorite, bool> selected,
}) {
  final entries = <ImageFavoritesDownloadEntry>[];
  final seen = <String>{};
  for (final comic in comics) {
    for (final ep in comic.imageFavoritesEp) {
      for (final image in ep.imageFavorites) {
        if (selected[image] != true) continue;
        final key = '${image.sourceKey}/${image.id}/${image.eid}/${image.page}';
        if (!seen.add(key)) continue;
        entries.add(
          ImageFavoritesDownloadEntry(
            image: image,
            comicTitle: comic.title,
            chapterName: ep.epName,
          ),
        );
      }
    }
  }
  return entries;
}

/// Outcome of one batch download. [skipped] counts files that already existed.
class ImageFavoritesDownloadResult {
  const ImageFavoritesDownloadResult({
    this.saved = 0,
    this.skipped = 0,
    this.failed = 0,
    this.cancelled = false,
    this.savedDirectories = const [],
  });

  final int saved;
  final int skipped;
  final int failed;
  final bool cancelled;

  /// Canonical paths of the directories this download wrote into. Kept for
  /// diagnostics; nothing is cleaned up after a partial download.
  final List<String> savedDirectories;

  int get total => saved + skipped + failed;
}

typedef ImageFavoritesBytesReader =
    Future<Uint8List> Function(
      ImageFavorite image,
      void Function() checkStop,
      Future<void> cancelSignal,
    );

/// Writes [entries] into [directory]. Existing files are skipped, so repeating
/// the same download never duplicates or overwrites earlier saves.
///
/// [read] is the byte source, so this module owns no source-specific network
/// knowledge. Cancellation is observed through [checkStop] and [isCancelled],
/// and joined through [cancelSignal].
Future<ImageFavoritesDownloadResult> writeImageFavorites({
  required Directory directory,
  required List<ImageFavoritesDownloadEntry> entries,
  required ImageFavoritesBytesReader read,
  required void Function() checkStop,
  required Future<void> cancelSignal,
  bool Function()? isCancelled,
  void Function(int done, int total)? onProgress,
}) => overrideIO(() async {
  var saved = 0;
  var skipped = 0;
  var failed = 0;
  var cancelled = false;
  var done = 0;
  for (final entry in entries) {
    try {
      checkStop();
      final bytes = await read(entry.image, checkStop, cancelSignal);
      checkStop();
      final type = detectFileType(bytes);
      final extension = type.ext.length > 1 ? type.ext : '.jpg';
      final file = File(
        FilePath.join(directory.path, entry.fileName(extension)),
      );
      if (file.existsSync()) {
        skipped++;
      } else {
        file.writeAsBytesSync(bytes, flush: true);
        saved++;
      }
    } on ImageFavoritesDownloadCancelled {
      cancelled = true;
      break;
    } catch (_) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      failed++;
    }
    done++;
    onProgress?.call(done, entries.length);
  }
  return ImageFavoritesDownloadResult(
    saved: saved,
    skipped: skipped,
    failed: failed,
    cancelled: cancelled,
    savedDirectories: saved > 0 ? [directory.path] : const [],
  );
});
