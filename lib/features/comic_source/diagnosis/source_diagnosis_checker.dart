import 'dart:async';
import 'dart:io'
    show
        CertificateException,
        HandshakeException,
        HttpException,
        SocketException,
        TlsException;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:venera_unified/foundation/cache_manager.dart';
import 'package:venera_unified/foundation/image_processing.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/foundation/operation_failure.dart';
import 'package:venera_unified/network/images.dart';
import 'package:venera_unified/network/request_scope.dart';

import '../models.dart';
import '../source.dart';
import 'source_diagnosis_models.dart';

/// Downloads one comic image through the reader path (A2-03).
///
/// The production implementation resolves the source onImageLoad hook and
/// performs a real download via [ImageDownloader.loadComicImage]. The cache
/// entry is evicted before and after the download so diagnosis always
/// exercises the live path and leaves no residue (A7-06). Tests inject a
/// fake; no real network is touched then.
typedef SourceDiagnosisImageBytesLoader =
    Future<Uint8List> Function({
      required String imageKey,
      required String sourceKey,
      required String comicId,
      required String episodeId,
    });

/// Validates downloaded image bytes by decoding the first frame.
///
/// The production implementation uses the reader-equivalent decode path and
/// releases the codec afterwards (A7-06). Tests inject a fake.
typedef SourceDiagnosisImageBytesValidator =
    Future<void> Function(Uint8List bytes);

/// Production image download: reader path, cache bypassed (A2-03, A7-06).
Future<Uint8List> loadDiagnosisImageBytes({
  required String imageKey,
  required String sourceKey,
  required String comicId,
  required String episodeId,
}) async {
  final cacheKey = '$imageKey@$sourceKey@$comicId@$episodeId';
  await CacheManager().delete(cacheKey);
  try {
    Uint8List? bytes;
    await for (final event in ImageDownloader.loadComicImage(
      imageKey,
      sourceKey,
      comicId,
      episodeId,
    )) {
      if (event.imageBytes != null) bytes = event.imageBytes;
    }
    if (bytes == null) throw StateError('Empty image response');
    return bytes;
  } finally {
    await CacheManager().delete(cacheKey);
  }
}

/// Production image validation: non-empty check plus first-frame decode.
Future<void> validateDiagnosisImageBytes(Uint8List bytes) async {
  if (bytes.isEmpty) throw StateError('Empty image response');
  // Image.decodeImage instantiates a codec, reads the first frame, and
  // releases both the frame and the codec (reader-equivalent path).
  await Image.decodeImage(bytes);
}

/// Internal control-flow marker for structural empty results.
///
/// Unlike bridge/transport failures, these never reach the classifier: the
/// throw site already knows the coarse kind.
class _EmptyResult implements Exception {
  const _EmptyResult(this.kind);
  final DiagnosisFailureKind kind;
}

/// One sample's captured outcome. [_SampleAttempt] never throws.
class _SampleAttempt {
  const _SampleAttempt._({
    required this.rows,
    required this.errors,
    required this.title,
    this.failedStage,
    this.timedOut = false,
  });

  factory _SampleAttempt.passed({
    required List<SourceDiagnosisStageResult> rows,
    required Map<SourceDiagnosisStage, Object> errors,
    required String? title,
  }) => _SampleAttempt._(rows: rows, errors: errors, title: title);

  factory _SampleAttempt.failed({
    required SourceDiagnosisStage stage,
    required List<SourceDiagnosisStageResult> rows,
    required Map<SourceDiagnosisStage, Object> errors,
    required String? title,
  }) => _SampleAttempt._(
    rows: rows,
    errors: errors,
    title: title,
    failedStage: stage,
  );

  factory _SampleAttempt.timeout({
    required List<SourceDiagnosisStageResult> rows,
    required Map<SourceDiagnosisStage, Object> errors,
    required String? title,
  }) => _SampleAttempt._(
    rows: rows,
    errors: errors,
    title: title,
    timedOut: true,
  );

  /// Settled rows for this attempt, in execution order.
  final List<SourceDiagnosisStageResult> rows;

  /// Raw errors keyed by stage. Internal only: used for the redacted log
  /// line, never copied into a report (A5-01).
  final Map<SourceDiagnosisStage, Object> errors;

  /// Best-known sample title: details title when loaded, else catalog title.
  final String? title;
  final SourceDiagnosisStage? failedStage;
  final bool timedOut;
}

/// Furthest failed attempt kept across samples (A3-05).
class _FurthestFailure {
  _FurthestFailure({
    required this.stage,
    required this.rows,
    required this.title,
  });

  final SourceDiagnosisStage stage;
  final List<SourceDiagnosisStageResult> rows;
  final String? title;
}

SourceDiagnosisStatus _statusForKind(DiagnosisFailureKind kind) {
  switch (kind) {
    case DiagnosisFailureKind.timeout:
    case DiagnosisFailureKind.env:
      return SourceDiagnosisStatus.unknown;
    default:
      return SourceDiagnosisStatus.fail;
  }
}

/// Runs one manual four-stage readability round for a single source.
///
/// Semantics follow the v1.20 draft section A: catalog -> details -> pages
/// -> image, at most 3 samples, per-stage timeout, no diagnosis-layer retry
/// (A4-07). Every stage reports exactly one of pass/fail/skipped/unknown
/// (A3-06); timeouts and environment gaps end the round as unknown and their
/// late results are discarded (A4-04). Result objects are whitelist-only and
/// never carry raw errors or stacks (A5-01); failures are only logged as a
/// coarse kind plus one redacted line (A2-05, A6).
class SourceDiagnosisChecker {
  SourceDiagnosisChecker({
    this.stageTimeout = SourceDiagnosisLimits.stageTimeout,
    this.maxExploreProbes = SourceDiagnosisLimits.maxExploreProbes,
    this.maxSamples = SourceDiagnosisLimits.maxSamples,
    SourceDiagnosisImageBytesLoader? imageLoader,
    SourceDiagnosisImageBytesValidator? imageValidator,
  }) : _imageLoader = imageLoader ?? loadDiagnosisImageBytes,
       _imageValidator = imageValidator ?? validateDiagnosisImageBytes;

  final Duration stageTimeout;
  final int maxExploreProbes;
  final int maxSamples;
  final SourceDiagnosisImageBytesLoader _imageLoader;
  final SourceDiagnosisImageBytesValidator _imageValidator;

  /// Placeholder episode id for chapter-less works (loadEp received null).
  ///
  /// The reader image path still needs a string episode segment for its
  /// request identity; reader flows use '0' for the same case.
  static const String chapterlessEpisodeId = '0';

  /// Diagnose [source] once and return its whitelist report.
  ///
  /// When [comicId] is non-blank, catalog is recorded as skipped and the
  /// given ID is diagnosed directly (A3-01); this is the mandatory path for
  /// sources without explore capability. [onEvent] receives started/settled
  /// progress events (A1-05). This method never throws: unexpected errors
  /// fail the current stage as [DiagnosisFailureKind.script].
  Future<SourceDiagnosisReport> check(
    ComicSource source, {
    String? comicId,
    SourceDiagnosisEventCallback? onEvent,
  }) async {
    final settled = <SourceDiagnosisStageResult>[];
    final trimmedId = comicId?.trim() ?? '';
    final useIdPath = trimmedId.isNotEmpty;
    var currentStage = SourceDiagnosisStage.catalog;
    var sampleIndex = 0;

    void emitStarted(SourceDiagnosisStage stage) {
      currentStage = stage;
      onEvent?.call(
        SourceDiagnosisStageStarted(stage: stage, sampleIndex: sampleIndex),
      );
    }

    void emitSettled(SourceDiagnosisStageResult row, {Object? error}) {
      onEvent?.call(
        SourceDiagnosisStageSettled(
          stage: row.stage,
          sampleIndex: sampleIndex,
          result: row,
        ),
      );
      _logRow(source, row, error: error);
    }

    SourceDiagnosisReport buildReport({
      required SourceDiagnosisVerdict verdict,
      SourceDiagnosisStage? failedStage,
      String? title,
    }) {
      return SourceDiagnosisReport(
        sourceKey: source.key,
        sourceName: source.name,
        verdict: verdict,
        stages: settled,
        title: title,
        comicIdUserProvided: useIdPath,
        diagnosedAt: DateTime.now(),
        failedStage: failedStage,
      );
    }

    try {
      // ---- catalog (A3-01) ----
      final List<Comic> samples;
      emitStarted(SourceDiagnosisStage.catalog);
      if (useIdPath) {
        const row = SourceDiagnosisStageResult(
          stage: SourceDiagnosisStage.catalog,
          status: SourceDiagnosisStatus.skipped,
          elapsedMs: 0,
        );
        settled.add(row);
        emitSettled(row);
        samples = [
          Comic('', '', trimmedId, null, null, '', source.key, null, null),
        ];
      } else if (!_hasUsableExplore(source)) {
        const row = SourceDiagnosisStageResult(
          stage: SourceDiagnosisStage.catalog,
          status: SourceDiagnosisStatus.fail,
          kind: DiagnosisFailureKind.unsupported,
          elapsedMs: 0,
        );
        settled.add(row);
        emitSettled(row);
        return buildReport(
          verdict: SourceDiagnosisVerdict.failed,
          failedStage: SourceDiagnosisStage.catalog,
        );
      } else {
        final stopwatch = Stopwatch()..start();
        try {
          samples = await _probeCatalog(source);
          stopwatch.stop();
          final row = SourceDiagnosisStageResult(
            stage: SourceDiagnosisStage.catalog,
            status: SourceDiagnosisStatus.pass,
            elapsedMs: stopwatch.elapsedMilliseconds,
          );
          settled.add(row);
          emitSettled(row);
        } on TimeoutException catch (error) {
          stopwatch.stop();
          final row = SourceDiagnosisStageResult(
            stage: SourceDiagnosisStage.catalog,
            status: SourceDiagnosisStatus.unknown,
            kind: DiagnosisFailureKind.timeout,
            elapsedMs: stopwatch.elapsedMilliseconds,
          );
          settled.add(row);
          emitSettled(row, error: error);
          return buildReport(verdict: SourceDiagnosisVerdict.unknown);
        } on _EmptyResult catch (error) {
          stopwatch.stop();
          final row = SourceDiagnosisStageResult(
            stage: SourceDiagnosisStage.catalog,
            status: SourceDiagnosisStatus.fail,
            kind: error.kind,
            elapsedMs: stopwatch.elapsedMilliseconds,
          );
          settled.add(row);
          emitSettled(row, error: error);
          return buildReport(
            verdict: SourceDiagnosisVerdict.failed,
            failedStage: SourceDiagnosisStage.catalog,
          );
        } catch (error) {
          stopwatch.stop();
          final kind = classifyDiagnosisFailure(
            error,
            stage: SourceDiagnosisStage.catalog,
          );
          if (kind == DiagnosisFailureKind.env) {
            final row = SourceDiagnosisStageResult(
              stage: SourceDiagnosisStage.catalog,
              status: SourceDiagnosisStatus.unknown,
              kind: kind,
              elapsedMs: stopwatch.elapsedMilliseconds,
            );
            settled.add(row);
            emitSettled(row, error: error);
            return buildReport(verdict: SourceDiagnosisVerdict.unknown);
          }
          final row = SourceDiagnosisStageResult(
            stage: SourceDiagnosisStage.catalog,
            status: SourceDiagnosisStatus.fail,
            kind: kind,
            elapsedMs: stopwatch.elapsedMilliseconds,
          );
          settled.add(row);
          emitSettled(row, error: error);
          return buildReport(
            verdict: SourceDiagnosisVerdict.failed,
            failedStage: SourceDiagnosisStage.catalog,
          );
        }
      }

      // ---- capability gate (A3-02): missing loadInfo/loadEp fails the
      // whole round at details without trying any sample.
      if (source.loadComicInfo == null || source.loadComicPages == null) {
        sampleIndex = 0;
        emitStarted(SourceDiagnosisStage.details);
        const row = SourceDiagnosisStageResult(
          stage: SourceDiagnosisStage.details,
          status: SourceDiagnosisStatus.fail,
          kind: DiagnosisFailureKind.unsupported,
          elapsedMs: 0,
        );
        settled.add(row);
        emitSettled(row);
        return buildReport(
          verdict: SourceDiagnosisVerdict.failed,
          failedStage: SourceDiagnosisStage.details,
        );
      }

      // ---- samples (A3-02..A3-05): first full pass wins; otherwise the
      // furthest failure is reported.
      _FurthestFailure? furthest;
      final candidates = samples.take(maxSamples).toList();
      for (var i = 0; i < candidates.length; i++) {
        sampleIndex = i;
        final attempt = await _runSample(source, candidates[i], emitStarted);
        for (final row in attempt.rows) {
          onEvent?.call(
            SourceDiagnosisStageSettled(
              stage: row.stage,
              sampleIndex: sampleIndex,
              result: row,
            ),
          );
          _logRow(source, row, error: attempt.errors[row.stage]);
        }
        if (attempt.timedOut) {
          settled.addAll(attempt.rows);
          return buildReport(
            verdict: SourceDiagnosisVerdict.unknown,
            title: attempt.title,
          );
        }
        if (attempt.failedStage == null) {
          settled.addAll(attempt.rows);
          return buildReport(
            verdict: SourceDiagnosisVerdict.readable,
            title: attempt.title,
          );
        }
        final failed = _FurthestFailure(
          stage: attempt.failedStage!,
          rows: attempt.rows,
          title: attempt.title,
        );
        if (furthest == null || failed.stage.index >= furthest.stage.index) {
          furthest = failed;
        }
      }
      final decisive = furthest!;
      settled.addAll(decisive.rows);
      return buildReport(
        verdict: SourceDiagnosisVerdict.failed,
        failedStage: decisive.stage,
        title: decisive.title,
      );
    } catch (error) {
      // Fail-closed: an unexpected error (including a stray timeout) ends
      // the round at the current stage instead of throwing to the caller.
      final kind = classifyDiagnosisFailure(error, stage: currentStage);
      final status = _statusForKind(kind);
      final row = SourceDiagnosisStageResult(
        stage: currentStage,
        status: status,
        kind: kind,
        elapsedMs: 0,
      );
      onEvent?.call(
        SourceDiagnosisStageSettled(
          stage: currentStage,
          sampleIndex: sampleIndex,
          result: row,
        ),
      );
      _logRow(source, row, error: error);
      settled.add(row);
      if (status == SourceDiagnosisStatus.unknown) {
        return buildReport(verdict: SourceDiagnosisVerdict.unknown);
      }
      return buildReport(
        verdict: SourceDiagnosisVerdict.failed,
        failedStage: currentStage,
      );
    }
  }

  /// Probe up to [maxExploreProbes] explore pages; first non-empty wins.
  ///
  /// Throws [_EmptyResult] when every probe is empty, rethrows the last
  /// probe error when nothing usable was found, and rethrows
  /// [TimeoutException] immediately: a timeout stops the whole round (A4-04).
  Future<List<Comic>> _probeCatalog(ComicSource source) async {
    Object? lastError;
    StackTrace? lastStack;
    for (final page in source.explorePages.take(maxExploreProbes)) {
      if (!_hasLoader(page)) continue;
      try {
        final comics = await _awaitStage(_loadExploreProbe(page));
        if (comics.isNotEmpty) return comics;
      } on TimeoutException {
        rethrow;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack!);
    }
    throw const _EmptyResult(DiagnosisFailureKind.empty);
  }

  /// Load one explore probe through whichever loader the page offers.
  Future<List<Comic>> _loadExploreProbe(ExplorePageData page) async {
    final loadPage = page.loadPage;
    if (loadPage != null) return (await loadPage(1)).data;
    final loadNext = page.loadNext;
    if (loadNext != null) return (await loadNext(null)).data;
    final loadMultiPart = page.loadMultiPart;
    if (loadMultiPart != null) {
      final parts = (await loadMultiPart()).data;
      return parts.expand((part) => part.comics).toList();
    }
    final loadMixed = page.loadMixed;
    if (loadMixed != null) {
      final parts = (await loadMixed(1)).data;
      return parts.expand<Comic>((part) {
        if (part is ExplorePagePart) return part.comics;
        if (part is List<Comic>) return part;
        return const <Comic>[];
      }).toList();
    }
    return const <Comic>[];
  }

  bool _hasUsableExplore(ComicSource source) =>
      source.explorePages.take(maxExploreProbes).any(_hasLoader);

  bool _hasLoader(ExplorePageData page) =>
      page.loadPage != null ||
      page.loadNext != null ||
      page.loadMultiPart != null ||
      page.loadMixed != null;

  /// Run details -> pages -> image for one sample.
  ///
  /// Never throws: every outcome is captured in the returned attempt.
  /// [emitStarted] fires once per executed stage for live progress (A1-05).
  Future<_SampleAttempt> _runSample(
    ComicSource source,
    Comic sample,
    void Function(SourceDiagnosisStage stage) emitStarted,
  ) async {
    final rows = <SourceDiagnosisStageResult>[];
    final errors = <SourceDiagnosisStage, Object>{};
    String? title = sample.title.isEmpty ? null : sample.title;

    SourceDiagnosisStageResult settle({
      required SourceDiagnosisStage stage,
      required SourceDiagnosisStatus status,
      required int elapsedMs,
      DiagnosisFailureKind? kind,
      Object? error,
    }) {
      final row = SourceDiagnosisStageResult(
        stage: stage,
        status: status,
        kind: kind,
        elapsedMs: elapsedMs,
      );
      rows.add(row);
      if (error != null) errors[stage] = error;
      return row;
    }

    _SampleAttempt settleUnknown(
      SourceDiagnosisStage stage,
      Object error,
      int elapsedMs,
    ) {
      final kind = classifyDiagnosisFailure(error, stage: stage);
      assert(
        kind == DiagnosisFailureKind.timeout ||
            kind == DiagnosisFailureKind.env,
        'unknown rows only carry timeout/env kinds',
      );
      settle(
        stage: stage,
        status: SourceDiagnosisStatus.unknown,
        elapsedMs: elapsedMs,
        kind: kind,
        error: error,
      );
      return _SampleAttempt.timeout(rows: rows, errors: errors, title: title);
    }

    _SampleAttempt settleFailed(
      SourceDiagnosisStage stage,
      DiagnosisFailureKind kind,
      int elapsedMs,
      Object error,
    ) {
      settle(
        stage: stage,
        status: SourceDiagnosisStatus.fail,
        elapsedMs: elapsedMs,
        kind: kind,
        error: error,
      );
      return _SampleAttempt.failed(
        stage: stage,
        rows: rows,
        errors: errors,
        title: title,
      );
    }

    // ---- details (A3-02) ----
    emitStarted(SourceDiagnosisStage.details);
    final detailsStopwatch = Stopwatch()..start();
    ComicDetails info;
    try {
      final details = await _awaitStage(source.loadComicInfo!(sample.id));
      info = details.data;
    } on TimeoutException catch (error) {
      detailsStopwatch.stop();
      return settleUnknown(
        SourceDiagnosisStage.details,
        error,
        detailsStopwatch.elapsedMilliseconds,
      );
    } catch (error) {
      detailsStopwatch.stop();
      final kind = classifyDiagnosisFailure(
        error,
        stage: SourceDiagnosisStage.details,
      );
      if (kind == DiagnosisFailureKind.env) {
        return settleUnknown(
          SourceDiagnosisStage.details,
          error,
          detailsStopwatch.elapsedMilliseconds,
        );
      }
      return settleFailed(
        SourceDiagnosisStage.details,
        kind,
        detailsStopwatch.elapsedMilliseconds,
        error,
      );
    }
    detailsStopwatch.stop();
    if (info.title.isNotEmpty) title = info.title;
    settle(
      stage: SourceDiagnosisStage.details,
      status: SourceDiagnosisStatus.pass,
      elapsedMs: detailsStopwatch.elapsedMilliseconds,
    );

    // ---- pages (A3-03): first chapter; chapter-less works pass null into
    // loadEp instead of failing.
    emitStarted(SourceDiagnosisStage.pages);
    final pagesStopwatch = Stopwatch()..start();
    String? episode;
    List<String> imageKeys;
    try {
      final chapters = info.chapters;
      if (chapters != null) {
        if (chapters.length == 0) {
          throw const _EmptyResult(DiagnosisFailureKind.empty);
        }
        episode = chapters.ids.first;
      }
      final pages = await _awaitStage(
        source.loadComicPages!(sample.id, episode),
      );
      imageKeys = pages.data;
      if (imageKeys.isEmpty) {
        throw const _EmptyResult(DiagnosisFailureKind.empty);
      }
    } on TimeoutException catch (error) {
      pagesStopwatch.stop();
      return settleUnknown(
        SourceDiagnosisStage.pages,
        error,
        pagesStopwatch.elapsedMilliseconds,
      );
    } on _EmptyResult catch (error) {
      pagesStopwatch.stop();
      return settleFailed(
        SourceDiagnosisStage.pages,
        error.kind,
        pagesStopwatch.elapsedMilliseconds,
        error,
      );
    } catch (error) {
      pagesStopwatch.stop();
      final kind = classifyDiagnosisFailure(
        error,
        stage: SourceDiagnosisStage.pages,
      );
      if (kind == DiagnosisFailureKind.env) {
        return settleUnknown(
          SourceDiagnosisStage.pages,
          error,
          pagesStopwatch.elapsedMilliseconds,
        );
      }
      return settleFailed(
        SourceDiagnosisStage.pages,
        kind,
        pagesStopwatch.elapsedMilliseconds,
        error,
      );
    }
    pagesStopwatch.stop();
    settle(
      stage: SourceDiagnosisStage.pages,
      status: SourceDiagnosisStatus.pass,
      elapsedMs: pagesStopwatch.elapsedMilliseconds,
    );

    // ---- image (A3-04): first key through the reader download+decode path.
    emitStarted(SourceDiagnosisStage.image);
    final imageStopwatch = Stopwatch()..start();
    try {
      await _awaitStage(
        _runImageStep(
          imageKey: imageKeys.first,
          sourceKey: source.key,
          comicId: sample.id,
          episodeId: episode ?? chapterlessEpisodeId,
        ),
      );
    } on TimeoutException catch (error) {
      imageStopwatch.stop();
      return settleUnknown(
        SourceDiagnosisStage.image,
        error,
        imageStopwatch.elapsedMilliseconds,
      );
    } on _EmptyResult catch (error) {
      imageStopwatch.stop();
      return settleFailed(
        SourceDiagnosisStage.image,
        error.kind,
        imageStopwatch.elapsedMilliseconds,
        error,
      );
    } catch (error) {
      imageStopwatch.stop();
      final kind = classifyDiagnosisFailure(
        error,
        stage: SourceDiagnosisStage.image,
      );
      if (kind == DiagnosisFailureKind.env) {
        return settleUnknown(
          SourceDiagnosisStage.image,
          error,
          imageStopwatch.elapsedMilliseconds,
        );
      }
      return settleFailed(
        SourceDiagnosisStage.image,
        kind,
        imageStopwatch.elapsedMilliseconds,
        error,
      );
    }
    imageStopwatch.stop();
    settle(
      stage: SourceDiagnosisStage.image,
      status: SourceDiagnosisStatus.pass,
      elapsedMs: imageStopwatch.elapsedMilliseconds,
    );
    return _SampleAttempt.passed(rows: rows, errors: errors, title: title);
  }

  /// Download plus first-frame decode for one image key (A3-04).
  Future<void> _runImageStep({
    required String imageKey,
    required String sourceKey,
    required String comicId,
    required String episodeId,
  }) async {
    final bytes = await _imageLoader(
      imageKey: imageKey,
      sourceKey: sourceKey,
      comicId: comicId,
      episodeId: episodeId,
    );
    if (bytes.isEmpty) {
      throw const _EmptyResult(DiagnosisFailureKind.image);
    }
    await _imageValidator(bytes);
  }

  /// Await one stage call with the stage timeout (A4-04).
  ///
  /// A timeout throws [TimeoutException] without cancelling the underlying
  /// work, whose late result or error is discarded: the discard handler
  /// below keeps a late error from surfacing as an unhandled async error
  /// after the round has already moved on.
  Future<T> _awaitStage<T>(Future<T> task) {
    unawaited(task.then<void>((_) {}, onError: (_, _) {}));
    return task.timeout(stageTimeout);
  }

  void _logRow(
    ComicSource source,
    SourceDiagnosisStageResult row, {
    Object? error,
  }) {
    Log.info(
      'SourceDiagnosis',
      '${source.key} ${row.stage.name} ${row.status.name} '
          '${row.kind?.name ?? '-'} ${row.elapsedMs}ms',
    );
    if (error != null) {
      Log.error(
        'SourceDiagnosis',
        '${row.kind?.name}: ${summarizeDiagnosisError(error)}',
      );
    }
  }
}

/// Unwrap a failure chain for classification (at most 5 links).
///
/// Bridge failures nest: [FailureDetails.cause] may hold a [DioException]
/// whose own payload holds the transport error, and vice versa.
List<Object> _errorChain(Object error) {
  final chain = <Object>[];
  Object? current = error;
  for (var i = 0; i < 5 && current != null; i++) {
    chain.add(current);
    current = switch (current) {
      FailureDetails details => details.cause,
      DioException dio => dio.error,
      _ => null,
    };
  }
  return chain;
}

bool _isCancellation(Object error) {
  return _errorChain(error).any(
    (link) =>
        link is RequestCancelled ||
        (link is FailureDetails && link.kind == FailureKind.cancelled) ||
        (link is DioException && link.type == DioExceptionType.cancel),
  );
}

/// Auth signals (U-06 implementation threshold).
///
/// A 401/403 status on any [DioException] in the chain wins structurally.
/// String-only failures (legacy Res.error text, script messages) fall back
/// to case-insensitive keyword matching. This is a heuristic: servers that
/// report auth failures any other way classify as network/script instead,
/// which T4/T5 real-source sampling may refine.
bool _isAuthFailure(Object error) {
  final chain = _errorChain(error);
  for (final link in chain) {
    if (link is DioException &&
        (link.response?.statusCode == 401 ||
            link.response?.statusCode == 403)) {
      return true;
    }
  }
  const markers = [
    '401',
    '403',
    'unauthorized',
    'unauthenticated',
    'no permission',
    'login expired',
    'login required',
    'need login',
    'not logged',
    'please login',
    '需要登录',
    '登录过期',
    '登录已过期',
    '登录失效',
    '未登录',
    '请登录',
  ];
  final text = chain.map((link) => link.toString()).join('\n').toLowerCase();
  return markers.any(text.contains);
}

/// Transport signals: typed I/O failures first, message fallback second.
bool _isNetworkFailure(Object error) {
  final chain = _errorChain(error);
  for (final link in chain) {
    if (link is DioException) return true;
    if (link is SocketException ||
        link is HandshakeException ||
        link is CertificateException ||
        link is TlsException ||
        link is HttpException) {
      return true;
    }
  }
  const markers = [
    'dioexception',
    'failed host lookup',
    'no address associated',
    'network is unreachable',
    'connection refused',
    'connection reset',
    'connection closed',
    'connection timed out',
    'socketexception',
    'handshake',
    'certificate',
    'connection abort',
  ];
  final text = chain.map((link) => link.toString()).join('\n').toLowerCase();
  if (markers.any(text.contains)) return true;
  // Bare 5xx mentions in string-only errors (typed responses arrive as
  // DioException and are caught above).
  return RegExp(r'\b5\d\d\b').hasMatch(text);
}

/// Map a caught stage error to its coarse kind (A6).
///
/// [TimeoutException] (our own stage budget, never the bridge) maps to
/// [DiagnosisFailureKind.timeout]; cancelled underlying work maps to
/// [DiagnosisFailureKind.env]. Image-stage failures always map to
/// [DiagnosisFailureKind.image]. Elsewhere auth beats network, and anything
/// unrecognized (JS throws, malformed structures) maps to
/// [DiagnosisFailureKind.script]. Structural kinds (unsupported/empty) are
/// decided by the checker, never by this function.
DiagnosisFailureKind classifyDiagnosisFailure(
  Object error, {
  required SourceDiagnosisStage stage,
}) {
  if (error is TimeoutException) return DiagnosisFailureKind.timeout;
  if (_isCancellation(error)) return DiagnosisFailureKind.env;
  if (stage == SourceDiagnosisStage.image) return DiagnosisFailureKind.image;
  if (_isAuthFailure(error)) return DiagnosisFailureKind.auth;
  if (_isNetworkFailure(error)) return DiagnosisFailureKind.network;
  return DiagnosisFailureKind.script;
}
