import 'package:venera_unified/foundation/operation_failure.dart';
import 'package:venera_unified/foundation/missing_download_page.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/reader_preferences.dart';
import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_unified/foundation/file_system.dart';
import 'reader_image_processing.dart';
import 'package:venera_unified/network/images.dart';
import 'package:venera_unified/network/image_stream.dart';
import 'base_image_provider.dart';
import 'upscale/upscale_gate.dart';
import 'package:venera_unified/foundation/appdata.dart';

class ReaderImageProvider extends BaseImageProvider<ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.enableResize = false,
  });

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  @override
  final bool enableResize;

  @protected
  File createLocalFile(String path) => File(path);

  @override
  bool get retryFileSystemErrors =>
      !imageKey.startsWith('file://') &&
      !imageKey.startsWith(missingDownloadPagePrefix);

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    if (imageKey.startsWith(missingDownloadPagePrefix)) {
      throw FileSystemException(
        'This page is missing. Retry missing pages in Downloads.'.tl,
      );
    }
    Uint8List? imageBytes;
    if (imageKey.startsWith('file://')) {
      final file = createLocalFile(imageKey.substring(7));
      final exists = await file.exists();
      checkStop();
      if (exists) {
        imageBytes = await readFileBytesChecked(
          file,
          requireNonEmpty: true,
          checkStop: checkStop,
          cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
          canRetry: () => BaseImageProvider.canRetryAfterFailure(checkStop),
        );
      } else {
        throw FileSystemException('File not found', file.path);
      }
    } else {
      imageBytes = await readImageStream(
        ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid),
        cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
        checkStop: checkStop,
        onProgress: (event) => chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        ),
      );
    }
    if (imageBytes == null) {
      throw OperationFailure.message("Error: Empty response body.");
    }
    checkStop();
    if (GlobalPreferenceStore(
      appdata.settings,
    ).read(ImageProcessingPreferences.enabled)) {
      var script = GlobalPreferenceStore(
        appdata.settings,
      ).read(ImageProcessingPreferences.script);
      if (!script.contains('function processImage')) {
        return imageBytes;
      }
      imageBytes = await processReaderImageBytes(
        imageBytes,
        script: script,
        comicId: cid,
        episodeId: eid,
        page: page,
        sourceKey: sourceKey,
        checkStop: checkStop,
        cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
      );
    }
    // 超分（upscaleEnabled 门控，默认关；失败回退原图）。
    imageBytes = await upscaleIfEnabled(
      imageBytes,
      cacheKey: 'reader:$cid:$eid:$page:${imageKey.hashCode}',
      enabled: GlobalPreferenceStore(
        appdata.settings,
      ).read(ReaderPreferences.upscaleEnabled),
    );
    return imageBytes;
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "$imageKey@$sourceKey@$cid@$eid@$enableResize";
}
