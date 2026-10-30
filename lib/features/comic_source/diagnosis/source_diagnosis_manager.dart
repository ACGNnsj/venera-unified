import 'dart:async';

import 'package:flutter/foundation.dart';

import '../source.dart';
import 'source_diagnosis_checker.dart';
import 'source_diagnosis_models.dart';

/// Produces the report future for one diagnosis round.
///
/// Defaults to [SourceDiagnosisChecker.check]. Tests inject a runner to drive
/// the round future directly without touching the network. A runner must be
/// fail-closed: [SourceDiagnosisChecker.check] never throws, and an injected
/// runner that does throw loses its round state and propagates the error.
typedef SourceDiagnosisRoundRunner =
    Future<SourceDiagnosisReport> Function(
      ComicSource source, {
      String? comicId,
      SourceDiagnosisEventCallback? onEvent,
    });

/// Reports when the work a timed-out round abandoned can no longer change
/// anything (A4-05).
///
/// A round that ends with a timeout stopped waiting but never cancelled the
/// underlying requests (A4-04). The manager therefore keeps that source gated
/// until this future completes. Without a probe the manager treats the round
/// as settled as soon as its report resolves; production wiring supplies a
/// probe backed by the bridge drain so A4-05 holds end to end.
typedef SourceDiagnosisLingerProbe = Future<void> Function(String sourceKey);

/// What the manager currently holds for one source (A1-07).
enum SourceDiagnosisPhase {
  /// Nothing is held: a dialog may start a round.
  idle,

  /// A round is running. [SourceDiagnosisManager.start] joins it instead of
  /// starting a second one (A4-01).
  running,

  /// The round ended, but its abandoned underlying work may still be
  /// finishing. New starts are refused until it settles or the generation is
  /// invalidated (A4-05). This is never a "cancelled" state.
  settling,
}

/// Refusal of a new start while a round is still in flight or settling
/// (A4-02, A4-05).
///
/// The caller should keep the start control disabled and show the "still
/// finishing its previous network requests" hint. It must never render this as
/// a cancelled or failed diagnosis.
class SourceDiagnosisBusyException implements Exception {
  const SourceDiagnosisBusyException(
    this.sourceKey, {
    required this.blockingSourceKey,
  });

  /// The source the start was requested for.
  final String sourceKey;

  /// The source that still owns pending diagnosis work. Usually equals
  /// [sourceKey]; a different key means the global one-round budget (A4-02).
  final String blockingSourceKey;

  @override
  String toString() =>
      'A diagnosis round for "$blockingSourceKey" is still finishing; '
      '"$sourceKey" cannot start';
}

/// Thrown by the future returned from [SourceDiagnosisManager.start] when the
/// owning source was invalidated before the round settled (A4-06).
///
/// The report is void: callers must drop it and never render or copy it.
class SourceDiagnosisStaleException implements Exception {
  const SourceDiagnosisStaleException(this.sourceKey);

  final String sourceKey;

  @override
  String toString() =>
      'The diagnosis round for "$sourceKey" was invalidated before it '
      'settled';
}

/// Live progress snapshot of one running round (A1-05).
///
/// Whitelist-only, like [SourceDiagnosisReport]: it holds settled stage rows
/// and the current stage, never raw errors (A5-01).
class SourceDiagnosisProgress {
  const SourceDiagnosisProgress({
    required this.sourceKey,
    required this.stage,
    required this.sampleIndex,
    required this.startedAt,
    required this.settled,
  });

  final String sourceKey;

  /// The stage that started most recently.
  final SourceDiagnosisStage stage;

  /// Zero-based sample attempt the current stage belongs to.
  final int sampleIndex;

  /// When the round started, for an elapsed-time readout.
  final DateTime startedAt;

  /// Stage rows settled so far, in event order. A retried sample can add a
  /// second row for the same stage.
  final List<SourceDiagnosisStageResult> settled;

  SourceDiagnosisProgress _advance({
    required SourceDiagnosisStage stage,
    required int sampleIndex,
    SourceDiagnosisStageResult? row,
  }) {
    return SourceDiagnosisProgress(
      sourceKey: sourceKey,
      stage: stage,
      sampleIndex: sampleIndex,
      startedAt: startedAt,
      settled: row == null ? settled : List.unmodifiable([...settled, row]),
    );
  }
}

/// Owner of diagnosis round lifetimes for the comic source feature.
///
/// Responsibilities (v1.20 draft section A4):
/// - A4-01: at most one round per source key; concurrent triggers share one
///   future instead of running twice.
/// - A4-02: at most [maxConcurrentRounds] rounds globally (U-01 fixes one).
/// - A4-05: a round that timed out abandoned, but never cancelled, its
///   underlying requests. The source stays in [SourceDiagnosisPhase.settling]
///   until the linger probe resolves or the generation is invalidated, so a
///   new round cannot pile up behind the old one.
/// - A4-06: when a source is replaced, updated or uninstalled, its pending
///   round is voided and later results are dropped instead of shown.
///
/// A [ChangeNotifier]: every round, progress row and phase change publishes,
/// so an open dialog never polls. Tests construct their own instance with an
/// injected runner; [instance] is the app-lifetime singleton and is never
/// disposed.
class SourceDiagnosisManager extends ChangeNotifier {
  SourceDiagnosisManager({
    this._runner,
    this._lingerProbe,
    this.maxConcurrentRounds = 1,
  }) : assert(maxConcurrentRounds >= 1, 'at least one round must be allowed');

  /// App-lifetime manager used by the diagnosis dialog.
  static final SourceDiagnosisManager instance = SourceDiagnosisManager();

  /// Global in-flight budget (A4-02, U-01).
  final int maxConcurrentRounds;

  final SourceDiagnosisRoundRunner? _runner;
  final SourceDiagnosisLingerProbe? _lingerProbe;
  final _entries = <String, _Entry>{};
  final _lastReports = <String, SourceDiagnosisReport>{};
  final _generations = <String, int>{};

  SourceDiagnosisChecker? _productionChecker;
  bool _disposed = false;

  /// Phase held for [sourceKey] (A1-07).
  SourceDiagnosisPhase phaseOf(String sourceKey) {
    final entry = _entries[sourceKey];
    if (entry == null) return SourceDiagnosisPhase.idle;
    return entry.reportDone
        ? SourceDiagnosisPhase.settling
        : SourceDiagnosisPhase.running;
  }

  /// Whether a round is still producing progress for [sourceKey] (A4-01).
  bool isRunning(String sourceKey) =>
      phaseOf(sourceKey) == SourceDiagnosisPhase.running;

  /// Whether the round ended but its underlying work is still finishing
  /// (A4-05).
  bool isSettling(String sourceKey) =>
      phaseOf(sourceKey) == SourceDiagnosisPhase.settling;

  /// Whether any source currently holds a round.
  bool get hasPendingWork => _entries.isNotEmpty;

  /// Progress of the round held for [sourceKey], or null when idle.
  SourceDiagnosisProgress? progressOf(String sourceKey) =>
      _entries[sourceKey]?.progress;

  /// The future a reopened dialog can follow instead of starting a new round
  /// (A1-07). Null when no live round is held; a voided round never resolves
  /// to a usable report.
  Future<SourceDiagnosisReport>? inFlightOf(String sourceKey) {
    final entry = _entries[sourceKey];
    if (entry == null || entry.voided) return null;
    return entry.future;
  }

  /// The last report for [sourceKey], or null when none is current.
  ///
  /// Cleared on start, invalidation and clear, so it always belongs to the
  /// current generation.
  SourceDiagnosisReport? lastReportOf(String sourceKey) =>
      _lastReports[sourceKey];

  /// Start one diagnosis round for [source], or join the running one.
  ///
  /// While a round for the same source runs, every call returns the exact
  /// future of that round (A4-01), so concurrent triggers cannot run two
  /// rounds. A different comic ID does not start a second round either: the
  /// dialog disables re-entry while running (A1-07).
  ///
  /// Throws [SourceDiagnosisBusyException] when a previous round is still
  /// settling (A4-05) or the global budget is exhausted (A4-02). The returned
  /// future throws [SourceDiagnosisStaleException] when the source is
  /// invalidated before the round settles (A4-06).
  Future<SourceDiagnosisReport> start(ComicSource source, {String? comicId}) {
    if (_disposed) {
      throw StateError('The diagnosis manager was disposed');
    }
    final key = source.key;
    final trimmedId = comicId?.trim();
    final requestedId = (trimmedId == null || trimmedId.isEmpty)
        ? null
        : trimmedId;

    final existing = _entries[key];
    if (existing != null) {
      // A settled round whose source object was replaced: the old generation
      // is void, which also releases the A4-05 gate (A4-06). Any other case
      // is a join or a refusal.
      final replaced =
          existing.reportDone &&
          !existing.voided &&
          !identical(existing.source, source);
      if (!replaced) {
        if (!existing.voided && !existing.reportDone) return existing.future;
        throw SourceDiagnosisBusyException(key, blockingSourceKey: key);
      }
      _releaseEntry(key, existing);
      _generations[key] = (_generations[key] ?? 0) + 1;
      _lastReports.remove(key);
    }

    if (_entries.length >= maxConcurrentRounds) {
      throw SourceDiagnosisBusyException(
        key,
        blockingSourceKey: _entries.keys.first,
      );
    }

    final generation = (_generations[key] ?? 0) + 1;
    _generations[key] = generation;
    _lastReports.remove(key);
    final entry = _Entry(
      source: source,
      comicId: requestedId,
      generation: generation,
      startedAt: DateTime.now(),
    );
    _entries[key] = entry;
    entry.future = _run(source, requestedId, entry);
    // A dialog that closed while the round ran has no listener left; a voided
    // round must not surface as an unhandled async error.
    unawaited(
      entry.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    _publish();
    return entry.future;
  }

  /// Void the pending round of [sourceKey] (A4-06).
  ///
  /// Called when the source is updated, uninstalled or replaced. A running
  /// round keeps its A4-05 gate until its underlying work settles, but its
  /// eventual report is dropped: the future returned by [start] fails with
  /// [SourceDiagnosisStaleException] instead of resolving. The new source
  /// needs another manual [start].
  void invalidateSource(String sourceKey) {
    _generations[sourceKey] = (_generations[sourceKey] ?? 0) + 1;
    _lastReports.remove(sourceKey);
    final entry = _entries[sourceKey];
    if (entry != null) {
      entry.voided = true;
      if (entry.reportDone) {
        // Invalidation releases the settling gate as well (A4-05).
        entry.lingers = null;
        _entries.remove(sourceKey);
      }
    }
    _publish();
  }

  /// Void every pending round (A4-06) while keeping the gates of rounds that
  /// are still running.
  void invalidateAll() {
    final keys = <String>{..._entries.keys, ..._lastReports.keys};
    for (final key in keys) {
      invalidateSource(key);
    }
  }

  /// Hard reset: drop every result and every gate.
  ///
  /// Only for app-level teardown (logout, data reset) where the source bridge
  /// is torn down too; it does not keep running rounds gated.
  void clear() {
    for (final entry in _entries.values) {
      entry.voided = true;
      entry.lingers = null;
    }
    _entries.clear();
    _lastReports.clear();
    _generations.clear();
    _publish();
  }

  @override
  void dispose() {
    _disposed = true;
    _entries.clear();
    _lastReports.clear();
    _generations.clear();
    super.dispose();
  }

  Future<SourceDiagnosisReport> _run(
    ComicSource source,
    String? comicId,
    _Entry entry,
  ) async {
    final key = source.key;
    SourceDiagnosisReport report;
    try {
      report = await (_runner ?? _productionRun)(
        source,
        comicId: comicId,
        onEvent: (event) => _onEvent(key, entry, event),
      );
    } catch (error, stack) {
      _dropEntry(key, entry);
      Error.throwWithStackTrace(error, stack);
    }
    return _settleRound(key, entry, report);
  }

  Future<SourceDiagnosisReport> _productionRun(
    ComicSource source, {
    String? comicId,
    SourceDiagnosisEventCallback? onEvent,
  }) {
    final checker = _productionChecker ??= SourceDiagnosisChecker();
    return checker.check(source, comicId: comicId, onEvent: onEvent);
  }

  Future<SourceDiagnosisReport> _settleRound(
    String key,
    _Entry entry,
    SourceDiagnosisReport report,
  ) async {
    entry.reportDone = true;
    if (entry.voided || _generations[key] != entry.generation) {
      _dropEntry(key, entry);
      throw SourceDiagnosisStaleException(key);
    }
    _lastReports[key] = report;
    final abandoned = report.stages.any(
      (row) => row.kind == DiagnosisFailureKind.timeout,
    );
    final linger = abandoned ? _lingerProbe?.call(key) : null;
    if (linger == null) {
      _dropEntry(key, entry);
      return report;
    }
    entry.lingers = linger;
    _publish();
    unawaited(
      linger.then<void>(
        (_) => _releaseLinger(key, entry),
        onError: (Object _, StackTrace _) => _releaseLinger(key, entry),
      ),
    );
    return report;
  }

  void _releaseLinger(String key, _Entry entry) {
    if (!identical(_entries[key], entry)) return;
    entry.lingers = null;
    entry.reportDone = true;
    _entries.remove(key);
    _publish();
  }

  void _onEvent(String key, _Entry entry, SourceDiagnosisEvent event) {
    if (entry.voided || !identical(_entries[key], entry)) return;
    entry.progress = entry.progress._advance(
      stage: event.stage,
      sampleIndex: event.sampleIndex,
      row: event is SourceDiagnosisStageSettled ? event.result : null,
    );
    _publish();
  }

  void _dropEntry(String key, _Entry entry) => _releaseEntry(key, entry);

  void _releaseEntry(String key, _Entry entry) {
    if (!identical(_entries[key], entry)) return;
    entry.lingers = null;
    _entries.remove(key);
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    notifyListeners();
  }
}

/// State of one round held by [SourceDiagnosisManager].
class _Entry {
  _Entry({
    required this.source,
    required this.comicId,
    required this.generation,
    required this.startedAt,
  }) : progress = SourceDiagnosisProgress(
         sourceKey: source.key,
         stage: SourceDiagnosisStage.catalog,
         sampleIndex: 0,
         startedAt: startedAt,
         settled: const <SourceDiagnosisStageResult>[],
       );

  final ComicSource source;
  final String? comicId;
  final int generation;
  final DateTime startedAt;

  late final Future<SourceDiagnosisReport> future;
  SourceDiagnosisProgress progress;

  /// The report future resolved; the round no longer reports progress.
  bool reportDone = false;

  /// The generation was invalidated; the eventual report must be dropped
  /// (A4-06).
  bool voided = false;

  /// Non-null while a timed-out round's abandoned work is still finishing
  /// (A4-05).
  Future<void>? lingers;
}
