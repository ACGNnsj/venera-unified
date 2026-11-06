import 'package:venera_unified/foundation/operation_failure.dart';
import 'package:venera_unified/foundation/missing_download_page.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/foundation/global_preference_store.dart';
import 'package:venera_unified/foundation/application_preferences.dart';
import 'package:venera_unified/foundation/reader_preferences.dart';
import 'dart:async' show Future;
import 'dart:ui' show TargetImageSize;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_unified/foundation/file_system.dart';
import 'reader_image_processing.dart';
import 'package:venera_unified/network/images.dart';
import 'package:venera_unified/network/image_stream.dart';
import 'base_image_provider.dart';
import 'upscale/upscale_gate.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/image_translation/translation_config.dart';
import 'package:venera_unified/foundation/image_translation/translation_service.dart';
import 'package:venera_unified/foundation/reader_diagnostics.dart';
import 'package:venera_unified/foundation/tv_reader_policy.dart';

class ReaderImageProvider extends BaseImageProvider<ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.enableResize = false,
    this.decodePixelBudget,
    this.diagnostics,
    this.translationKey,
    this.legacyTranslationKey,
    this.translationConfig,
    this.translated = false,
    this.comicTitle = '',
    this.comicCover = '',
    this.chapterTitle = '',
  }) : assert(decodePixelBudget == null || decodePixelBudget > 0);

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  @override
  final bool enableResize;

  final int? decodePixelBudget;

  /// Cache key of the offline-translated variant of this page, or null when
  /// translation is off. When set, a cached or synced stored translation is
  /// shown before falling back to the original and background translation.
  final String? translationKey;

  /// The key this page's translation was stored under before [translationKey]
  /// switched to the page ordinal. Non-null only while [imageKey] is the one
  /// that wrote it.
  final String? legacyTranslationKey;

  /// This comic's own language pair + text-removal mode. Non-null exactly when
  /// [translationKey] is.
  final TranslationConfig? translationConfig;

  /// Whether the translated page is already known to exist. Only used to
  /// change the provider identity so the reader can swap the image in place
  /// once a background translation completes.
  final bool translated;

  final String comicTitle;
  final String comicCover;
  final String chapterTitle;

  /// Computes the translation constructor arguments for one page. Returns an
  /// all-empty triple when the comic's translation switch is off, so call
  /// sites can spread the result straight into the constructor without their
  /// own gating. Legacy image-key lookups are intentionally left null: the
  /// pipeline migrates those copies to the ordinal key on sync.
  static ({String? key, TranslationConfig? config, bool translated})
      translationFor({
    required String? sourceKey,
    required String cid,
    required String? eid,
    required int page,
  }) {
    final scopeKey = sourceKey ?? 'local';
    if (!ImageTranslationService.isEnabledForComic(cid, scopeKey)) {
      return (key: null, config: null, translated: false);
    }
    final config = TranslationConfig.of(cid, sourceKey);
    final key = ImageTranslationService.cacheKeyFor(
      scopeKey,
      cid,
      eid ?? '',
      page,
    );
    return (
      key: key,
      config: config,
      translated: ImageTranslationService.instance.isTranslated(
        key,
        config.mode,
      ),
    );
  }

  @override
  TargetImageSize targetSizeForImage(int width, int height) {
    final budget = decodePixelBudget;
    if (budget == null) return super.targetSizeForImage(width, height);
    final size = TvReaderPolicy.decodeSize(width, height, pixelBudget: budget);
    return TargetImageSize(width: size.width, height: size.height);
  }

  @override
  final ReaderDiagnostics? diagnostics;

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
    final readDiagnostic = diagnostics?.beginImageSpan(
      hashCode,
      imageKey.startsWith('file://')
          ? ReaderDiagnosticStage.localRead
          : ReaderDiagnosticStage.sourceRead,
    );
    try {
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
      readDiagnostic?.finish(bytes: imageBytes.length);
    } catch (_) {
      readDiagnostic?.finish(success: false);
      rethrow;
    }
    if (translationKey != null) {
      final translationConfig = this.translationConfig ??
          TranslationConfig.of(cid, sourceKey);
      final chapter = ImageTranslationService.chapterIdentity(
        cid: cid,
        sourceKey: sourceKey,
        eid: eid,
        config: translationConfig,
        comicTitle: comicTitle,
        comicCover: comicCover,
        chapterTitle: chapterTitle,
      );
      final service = ImageTranslationService.instance;
      final stored = await service.findTranslated(
        translationKey!,
        translationConfig.mode,
      );
      if (stored != null) {
        service.markTranslated(translationKey!, translationConfig.mode);
        return stored.readAsBytes();
      }
      final rendered = await service.renderStoredPage(
        translationKey!,
        imageBytes,
        translationConfig.mode,
        chapter: chapter,
        legacyCacheKey: legacyTranslationKey,
      );
      if (rendered != null) {
        return rendered;
      }
      if (ImageTranslationService.isReadyForLang(
        translationConfig.sourceLang,
      )) {
        service.schedule(
          translationKey!,
          cid,
          sourceKey,
          imageBytes,
          translationConfig,
          () => ImageTranslationService.evictImage(this),
          chapter: chapter,
          legacyCacheKey: legacyTranslationKey,
        );
      }
    }
    if (GlobalPreferenceStore(
      appdata.settings,
    ).read(ImageProcessingPreferences.enabled)) {
      var script = GlobalPreferenceStore(
        appdata.settings,
      ).read(ImageProcessingPreferences.script);
      if (!script.contains('function processImage')) {
        return imageBytes;
      }
      final processingDiagnostic = diagnostics?.beginImageSpan(
        hashCode,
        ReaderDiagnosticStage.processingWait,
      );
      try {
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
        processingDiagnostic?.finish(bytes: imageBytes.length);
      } catch (_) {
        processingDiagnostic?.finish(success: false);
        rethrow;
      }
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
  String get key =>
      "$imageKey@$sourceKey@$cid@$eid@$enableResize${decodePixelBudget == null ? '' : '@tv:$decodePixelBudget'}${translationKey == null ? '' : '@tr:$translated'}";
}
