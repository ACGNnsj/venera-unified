import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/diagnosis/source_diagnosis_manager.dart';
import 'package:venera_unified/features/comic_source/diagnosis/source_diagnosis_models.dart';
import 'package:venera_unified/features/comic_source/source.dart';

ComicSource _source({String key = 'test'}) => ComicSource(
  'Test Source',
  key,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'test.js',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

SourceDiagnosisStageResult _passRow(SourceDiagnosisStage stage) =>
    SourceDiagnosisStageResult(
      stage: stage,
      status: SourceDiagnosisStatus.pass,
      elapsedMs: 3,
    );

SourceDiagnosisStageResult _timeoutRow(SourceDiagnosisStage stage) =>
    SourceDiagnosisStageResult(
      stage: stage,
      status: SourceDiagnosisStatus.unknown,
      kind: DiagnosisFailureKind.timeout,
      elapsedMs: 15,
    );

SourceDiagnosisReport _readableReport() => SourceDiagnosisReport(
  sourceKey: 'test',
  sourceName: 'Test Source',
  verdict: SourceDiagnosisVerdict.readable,
  stages: [for (final stage in SourceDiagnosisStage.values) _passRow(stage)],
  title: 'Sample title',
  comicIdUserProvided: false,
  diagnosedAt: DateTime(2026, 10, 30),
);

SourceDiagnosisReport _timeoutReport() => SourceDiagnosisReport(
  sourceKey: 'test',
  sourceName: 'Test Source',
  verdict: SourceDiagnosisVerdict.unknown,
  stages: [
    _passRow(SourceDiagnosisStage.catalog),
    _timeoutRow(SourceDiagnosisStage.details),
  ],
  title: null,
  comicIdUserProvided: false,
  diagnosedAt: DateTime(2026, 10, 30),
);

void main() {
  group('A7-02 manager', () {
    test('concurrent triggers for one source share a single future', () async {
      final gate = Completer<SourceDiagnosisReport>();
      final rounds = <String?>[];
      final manager = SourceDiagnosisManager(
        runner: (source, {comicId, onEvent}) {
          rounds.add(comicId);
          return gate.future;
        },
      );
      addTearDown(manager.dispose);

      final source = _source();
      final first = manager.start(source);
      final second = manager.start(source);
      // A1-07: re-entering with another ID must not start a second round.
      final third = manager.start(source, comicId: ' other-id ');

      expect(second, same(first));
      expect(third, same(first));
      expect(rounds, [null]);
      expect(manager.phaseOf('test'), SourceDiagnosisPhase.running);
      expect(manager.isRunning('test'), isTrue);
      expect(manager.hasPendingWork, isTrue);
      expect(manager.inFlightOf('test'), same(first));
      expect(manager.lastReportOf('test'), isNull);

      final report = _readableReport();
      gate.complete(report);

      expect(await first, same(report));
      expect(await second, same(report));
      expect(manager.phaseOf('test'), SourceDiagnosisPhase.idle);
      expect(manager.hasPendingWork, isFalse);
      expect(manager.lastReportOf('test'), same(report));
      expect(manager.inFlightOf('test'), isNull);
    });

    test('invalidation drops the late result of a running round', () async {
      final gate = Completer<SourceDiagnosisReport>();
      final manager = SourceDiagnosisManager(
        runner: (source, {comicId, onEvent}) => gate.future,
      );
      addTearDown(manager.dispose);

      final future = manager.start(_source());
      manager.invalidateSource('test');

      // The round keeps its in-flight gate while the underlying work runs
      // (A4-05), but its result is already void (A4-06).
      expect(manager.phaseOf('test'), SourceDiagnosisPhase.running);
      expect(manager.inFlightOf('test'), isNull);
      expect(manager.lastReportOf('test'), isNull);

      gate.complete(_readableReport());

      await expectLater(future, throwsA(isA<SourceDiagnosisStaleException>()));
      await Future<void>.delayed(Duration.zero);
      expect(manager.lastReportOf('test'), isNull);
      expect(manager.phaseOf('test'), SourceDiagnosisPhase.idle);
      expect(manager.hasPendingWork, isFalse);
    });

    test('clear drops in-flight results and releases every gate', () async {
      final gate = Completer<SourceDiagnosisReport>();
      final manager = SourceDiagnosisManager(
        runner: (source, {comicId, onEvent}) => gate.future,
      );
      addTearDown(manager.dispose);

      final future = manager.start(_source());
      manager.clear();
      expect(manager.hasPendingWork, isFalse);

      gate.complete(_readableReport());
      await expectLater(future, throwsA(isA<SourceDiagnosisStaleException>()));
      await Future<void>.delayed(Duration.zero);
      expect(manager.lastReportOf('test'), isNull);
      expect(manager.phaseOf('test'), SourceDiagnosisPhase.idle);
    });

    test(
      'a timed-out round refuses starts until the underlying work settles',
      () async {
        final lingers = <Completer<void>>[];
        final manager = SourceDiagnosisManager(
          runner: (source, {comicId, onEvent}) async => _timeoutReport(),
          lingerProbe: (sourceKey) {
            final linger = Completer<void>();
            lingers.add(linger);
            return linger.future;
          },
        );
        addTearDown(manager.dispose);

        final source = _source();
        final report = await manager.start(source);
        expect(report.verdict, SourceDiagnosisVerdict.unknown);
        expect(manager.phaseOf('test'), SourceDiagnosisPhase.settling);
        expect(manager.isSettling('test'), isTrue);
        expect(manager.lastReportOf('test'), same(report));

        expect(
          () => manager.start(source),
          throwsA(isA<SourceDiagnosisBusyException>()),
        );
        // U-01: the global one-round budget also refuses another source.
        expect(
          () => manager.start(_source(key: 'other')),
          throwsA(isA<SourceDiagnosisBusyException>()),
        );

        expect(lingers, hasLength(1));
        lingers.single.complete();
        await Future<void>.delayed(Duration.zero);

        expect(manager.phaseOf('test'), SourceDiagnosisPhase.idle);
        expect(manager.hasPendingWork, isFalse);
        await manager.start(source);
        expect(lingers, hasLength(2));
        expect(manager.phaseOf('test'), SourceDiagnosisPhase.settling);
      },
    );

    test(
      'a replaced source is admitted while the old round is settling',
      () async {
        final linger = Completer<void>();
        var rounds = 0;
        final manager = SourceDiagnosisManager(
          runner: (source, {comicId, onEvent}) async {
            rounds++;
            return _timeoutReport();
          },
          lingerProbe: (sourceKey) => linger.future,
        );
        addTearDown(manager.dispose);

        final first = _source();
        await manager.start(first);
        expect(manager.isSettling('test'), isTrue);

        // A different source object with the same key means the installed
        // script was replaced: the old generation is void, so its gate is
        // released too (A4-05, A4-06).
        final replacement = _source();
        final report = await manager.start(replacement);

        expect(rounds, 2);
        expect(report.verdict, SourceDiagnosisVerdict.unknown);
        expect(manager.isSettling('test'), isTrue);
      },
    );
  });

  group('manager progress', () {
    test('settled rows follow the runner events', () async {
      final gate = Completer<SourceDiagnosisReport>();
      final manager = SourceDiagnosisManager(
        runner: (source, {comicId, onEvent}) {
          onEvent?.call(
            const SourceDiagnosisStageStarted(
              stage: SourceDiagnosisStage.details,
              sampleIndex: 0,
            ),
          );
          onEvent?.call(
            SourceDiagnosisStageSettled(
              stage: SourceDiagnosisStage.details,
              sampleIndex: 0,
              result: _passRow(SourceDiagnosisStage.details),
            ),
          );
          return gate.future;
        },
      );
      addTearDown(manager.dispose);

      var notifications = 0;
      manager.addListener(() => notifications++);

      final future = manager.start(_source());
      final progress = manager.progressOf('test');
      expect(progress, isNotNull);
      expect(progress!.sourceKey, 'test');
      expect(progress.stage, SourceDiagnosisStage.details);
      expect(progress.sampleIndex, 0);
      expect(progress.settled, hasLength(1));
      expect(progress.settled.single.stage, SourceDiagnosisStage.details);
      expect(progress.settled.single.status, SourceDiagnosisStatus.pass);
      expect(notifications, greaterThan(0));

      gate.complete(_readableReport());
      await future;
      expect(manager.progressOf('test'), isNull);
    });
  });
}
