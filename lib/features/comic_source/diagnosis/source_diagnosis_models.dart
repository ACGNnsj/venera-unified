import 'package:venera_unified/foundation/log_redaction.dart';

/// Fixed budgets for single-source manual readability diagnosis.
///
/// Values follow the decided unknowns U-01-U-03 (15s per stage, at most 3
/// explore probes and 3 samples). The checker exposes them as overridable
/// constructor arguments so tests can shrink the budgets.
abstract final class SourceDiagnosisLimits {
  /// Per-stage wait budget. A timeout stops waiting for the stage and ends
  /// the whole round with [SourceDiagnosisStatus.unknown]; it never cancels
  /// the underlying request (A4-04).
  static const Duration stageTimeout = Duration(seconds: 15);

  /// Maximum number of explore-page probes in the catalog stage (A4-03).
  static const int maxExploreProbes = 3;

  /// Maximum number of comic samples attempted per round (A3-05).
  static const int maxSamples = 3;

  /// Maximum sample-title length kept in a report (A5-01).
  static const int sampleTitleMaxChars = 60;

  /// Maximum redacted one-line error summary for log/UI channels (A6).
  static const int errorSummaryMaxChars = 120;
}

/// The four diagnosis stages, in execution order (A0-01).
enum SourceDiagnosisStage {
  /// Sample comics from the source explore pages.
  catalog,

  /// Load one sample's details via loadInfo.
  details,

  /// Load the first chapter's image-key list via loadEp.
  pages,

  /// Download one image through the reader path and decode its first frame.
  image,
}

/// Per-stage outcome state.
///
/// Every settled stage holds exactly one of these (A3-06). Stages that never
/// ran are absent from [SourceDiagnosisReport.stages] instead of carrying a
/// fifth state.
enum SourceDiagnosisStatus {
  /// The stage completed and its check succeeded.
  pass,

  /// The stage completed and its check failed. The coarse classification
  /// lives in [SourceDiagnosisStageResult.kind].
  fail,

  /// The stage was intentionally not executed (a user-supplied comic ID skips
  /// catalog; a source without explore capability skips catalog when an ID
  /// path is available).
  skipped,

  /// No verdict: the stage timed out, its underlying work was cancelled, or
  /// the environment could not support it. Never counts as a failed stage.
  unknown,
}

/// Coarse failure classification for diagnosis results (A6).
///
/// This enum is intentionally independent from SourceFailureCode, which
/// covers source management (import/catalog/update) rather than readability
/// (A2-02). A result object only carries the code, never the raw error.
enum DiagnosisFailureKind {
  /// The source cannot be read online or offers no usable entry: missing
  /// loadInfo/loadEp, or no explore capability and no ID path.
  unsupported,

  /// No diagnosable sample was found: all explore probes empty, no readable
  /// chapter, or an empty image list.
  empty,

  /// Login is required or has expired (heuristics, see U-06).
  auth,

  /// Transport-layer failure: DNS/connection/certificate/5xx and friends.
  network,

  /// The stage exceeded its wait budget; the round result is unknown.
  timeout,

  /// Image download or decode failed, including onImageLoad hook failures.
  image,

  /// The source script threw or returned an unusable structure.
  script,

  /// Unknown caused by the environment: cancelled underlying work, missing
  /// network, or a source replaced mid-diagnosis. Never a failure verdict.
  env,
}

/// Whole-round conclusion (A1-06).
///
/// The verdict only describes the chosen samples under the current
/// environment; one passing sample never proves the whole source (A0-03).
enum SourceDiagnosisVerdict {
  /// At least one sample completed the image stage.
  readable,

  /// Every sample failed. [SourceDiagnosisReport.failedStage] names the stage
  /// where the furthest attempt stopped.
  failed,

  /// A timeout or an environment gap stopped the round before any verdict.
  unknown,
}

/// One settled stage row: status plus elapsed time plus coarse kind (A1-06).
///
/// Whitelist-only: no URLs, headers, bodies, raw errors, or stacks (A5-01).
class SourceDiagnosisStageResult {
  const SourceDiagnosisStageResult({
    required this.stage,
    required this.status,
    required this.elapsedMs,
    this.kind,
  }) : assert(
         (status == SourceDiagnosisStatus.pass ||
                 status == SourceDiagnosisStatus.skipped)
             ? kind == null
             : kind != null,
         'kind is required for fail/unknown and forbidden otherwise',
       ),
       assert(
         status != SourceDiagnosisStatus.unknown ||
             (kind == DiagnosisFailureKind.timeout ||
                 kind == DiagnosisFailureKind.env),
         'unknown status requires the timeout or env kind',
       ),
       assert(
         (kind != DiagnosisFailureKind.timeout &&
                 kind != DiagnosisFailureKind.env) ||
             status == SourceDiagnosisStatus.unknown,
         'timeout/env kinds require the unknown status',
       ),
       assert(elapsedMs >= 0, 'elapsedMs must be non-negative'),
       assert(
         status != SourceDiagnosisStatus.skipped || elapsedMs == 0,
         'a skipped stage records no elapsed time',
       );

  final SourceDiagnosisStage stage;
  final SourceDiagnosisStatus status;

  /// Null for pass/skipped rows.
  final DiagnosisFailureKind? kind;

  /// Wall-clock milliseconds spent executing this stage, 0 when skipped.
  final int elapsedMs;
}

/// Whole-round diagnosis report (A5-01 whitelist).
///
/// Only the fields below may reach the UI, clipboard, or logs: source key and
/// name, per-stage rows, a truncated sample title, whether the comic ID came
/// from the user, and the diagnosis time. Raw URLs, headers, bodies, full
/// identities, raw errors, stacks, and credentials are forbidden here (A5-01).
class SourceDiagnosisReport {
  SourceDiagnosisReport({
    required this.sourceKey,
    required this.sourceName,
    required this.verdict,
    required List<SourceDiagnosisStageResult> stages,
    required String? title,
    required this.comicIdUserProvided,
    required this.diagnosedAt,
    this.failedStage,
  }) : stages = List<SourceDiagnosisStageResult>.unmodifiable(stages),
       sampleTitle = sanitizeDiagnosisSampleTitle(title) {
    assert(
      (verdict == SourceDiagnosisVerdict.failed) == (failedStage != null),
      'failedStage is required if and only if the verdict is failed',
    );
    assert(
      verdict != SourceDiagnosisVerdict.failed ||
          stages.any(
            (row) =>
                row.stage == failedStage &&
                row.status == SourceDiagnosisStatus.fail,
          ),
      'the failed stage must have a matching fail row',
    );
  }

  final String sourceKey;
  final String sourceName;
  final SourceDiagnosisVerdict verdict;

  /// Settled stage rows in execution order. Absence means 'not run': a round
  /// that stops at details carries no pages/image rows.
  final List<SourceDiagnosisStageResult> stages;

  /// Non-null if and only if [verdict] is [SourceDiagnosisVerdict.failed].
  /// Unknown stages never appear here (A3-06).
  final SourceDiagnosisStage? failedStage;

  /// Desensitized sample title of the decisive attempt, truncated to
  /// [SourceDiagnosisLimits.sampleTitleMaxChars]; null when unknown.
  final String? sampleTitle;

  /// Whether the diagnosed comic ID was typed in by the user (A1-06).
  final bool comicIdUserProvided;

  final DateTime diagnosedAt;

  bool get readable => verdict == SourceDiagnosisVerdict.readable;
}

/// Progress event emitted while a round runs (A1-05).
abstract class SourceDiagnosisEvent {
  const SourceDiagnosisEvent({required this.stage, required this.sampleIndex});

  /// The stage this event belongs to.
  final SourceDiagnosisStage stage;

  /// Zero-based sample attempt. The catalog stage always reports 0.
  final int sampleIndex;
}

/// A stage run started. Details/pages/image fire once per sample attempt.
class SourceDiagnosisStageStarted extends SourceDiagnosisEvent {
  const SourceDiagnosisStageStarted({
    required super.stage,
    required super.sampleIndex,
  });
}

/// A stage run settled with its final row for this attempt.
class SourceDiagnosisStageSettled extends SourceDiagnosisEvent {
  const SourceDiagnosisStageSettled({
    required super.stage,
    required super.sampleIndex,
    required this.result,
  });

  final SourceDiagnosisStageResult result;
}

typedef SourceDiagnosisEventCallback =
    void Function(SourceDiagnosisEvent event);

String _truncateByRunes(String value, int maxChars) {
  if (value.runes.length <= maxChars) return value;
  return String.fromCharCodes(value.runes.take(maxChars));
}

/// Desensitize and truncate a sample title for [SourceDiagnosisReport] (A5-01).
///
/// Returns null when no usable title is known. Never returns the raw comic
/// ID: the report only records whether the ID was user-supplied (A1-06).
String? sanitizeDiagnosisSampleTitle(String? title) {
  if (title == null) return null;
  final cleaned = redactLogText(title).trim();
  if (cleaned.isEmpty) return null;
  return _truncateByRunes(cleaned, SourceDiagnosisLimits.sampleTitleMaxChars);
}

/// Build the single redacted error line for log/UI channels (A6).
///
/// First line only, desensitized, truncated to
/// [SourceDiagnosisLimits.errorSummaryMaxChars]. Stacks and structured causes
/// never pass through here.
String summarizeDiagnosisError(Object error) {
  final firstLine = error.toString().split('\n').first.trim();
  final cleaned = redactLogText(
    firstLine.isEmpty ? 'Unknown error' : firstLine,
  );
  final trimmed = cleaned.trim();
  return _truncateByRunes(
    trimmed.isEmpty ? 'Unknown error' : trimmed,
    SourceDiagnosisLimits.errorSummaryMaxChars,
  );
}
