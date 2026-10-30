import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/diagnosis/source_diagnosis_checker.dart';
import 'package:venera_unified/features/comic_source/diagnosis/source_diagnosis_models.dart';
import 'package:venera_unified/features/comic_source/models.dart';
import 'package:venera_unified/features/comic_source/source.dart';
import 'package:venera_unified/foundation/res.dart';

Comic _comic(String id, [String? title]) =>
    Comic(title ?? 'Title $id', '', id, null, null, '', 'test', null, null);

ComicDetails _details({
  required String id,
  String title = 'Details title',
  Map<String, dynamic>? chapters,
}) => ComicDetails.fromJson({
  'title': title,
  'cover': '',
  'comicId': id,
  'sourceKey': 'test',
  'chapters': ?chapters,
});

ExplorePageData _explorePage(Future<Res<List<Comic>>> Function(int page) load) {
  return ExplorePageData(
    'Test',
    ExplorePageType.multiPageComicList,
    load,
    null,
    null,
    null,
  );
}

ComicSource _source({
  List<ExplorePageData> explorePages = const [],
  Future<Res<ComicDetails>> Function(String id)? loadInfo,
  Future<Res<List<String>>> Function(String id, String? ep)? loadPages,
}) => ComicSource(
  'Test Source',
  'test',
  null,
  null,
  null,
  null,
  explorePages,
  null,
  null,
  loadInfo,
  null,
  loadPages,
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

SourceDiagnosisChecker _checker({
  Duration stageTimeout = const Duration(seconds: 5),
  SourceDiagnosisImageBytesLoader? imageLoader,
  SourceDiagnosisImageBytesValidator? imageValidator,
}) => SourceDiagnosisChecker(
  stageTimeout: stageTimeout,
  imageLoader:
      imageLoader ??
      ({
        required imageKey,
        required sourceKey,
        required comicId,
        required episodeId,
      }) async => Uint8List.fromList([1, 2, 3]),
  imageValidator: imageValidator ?? (_) async {},
);

SourceDiagnosisStageResult _rowOf(
  SourceDiagnosisReport report,
  SourceDiagnosisStage stage,
) {
  return report.stages.singleWhere((row) => row.stage == stage);
}

void main() {
  group('A7-01 checker', () {
    test('second of three samples passing marks the source readable', () async {
      var infoCalls = 0;
      final pagesArgs = <String?>[];
      final source = _source(
        explorePages: [
          _explorePage(
            (_) async =>
                Res([_comic('bad-1'), _comic('good'), _comic('bad-2')]),
          ),
        ],
        loadInfo: (id) async {
          infoCalls++;
          if (id != 'good') return Res.error('removed');
          return Res(_details(id: id, chapters: {'c1': 'Chapter 1'}));
        },
        loadPages: (id, ep) async {
          pagesArgs.add(ep);
          return Res(['img-1']);
        },
      );
      final events = <SourceDiagnosisEvent>[];
      final report = await _checker().check(source, onEvent: events.add);

      expect(report.verdict, SourceDiagnosisVerdict.readable);
      expect(report.failedStage, isNull);
      expect(report.sampleTitle, 'Details title');
      expect(report.comicIdUserProvided, isFalse);
      expect(
        report.stages.map((row) => row.status),
        everyElement(SourceDiagnosisStatus.pass),
      );
      expect(report.stages.map((row) => row.stage), [
        SourceDiagnosisStage.catalog,
        SourceDiagnosisStage.details,
        SourceDiagnosisStage.pages,
        SourceDiagnosisStage.image,
      ]);
      // The loop stops at the first full pass: bad-2 is never attempted,
      // and the first chapter id reaches loadEp.
      expect(infoCalls, 2);
      expect(pagesArgs, ['c1']);
      // Progress fires per executed stage incl. the retried details run.
      expect(
        events.whereType<SourceDiagnosisStageSettled>().map((e) => e.stage),
        containsAllInOrder([
          SourceDiagnosisStage.catalog,
          SourceDiagnosisStage.details,
          SourceDiagnosisStage.details,
          SourceDiagnosisStage.pages,
          SourceDiagnosisStage.image,
        ]),
      );
    });

    test('details failure stops at details; pages/image are not run', () async {
      var pagesCalled = false;
      var imageCalled = false;
      final source = _source(
        explorePages: [
          _explorePage((_) async => Res([_comic('only')])),
        ],
        loadInfo: (_) async => Res.error('boom'),
        loadPages: (_, _) async {
          pagesCalled = true;
          return Res(['img-1']);
        },
      );
      final report = await _checker(
        imageLoader:
            ({
              required imageKey,
              required sourceKey,
              required comicId,
              required episodeId,
            }) async {
              imageCalled = true;
              return Uint8List.fromList([1]);
            },
      ).check(source);

      expect(report.verdict, SourceDiagnosisVerdict.failed);
      expect(report.failedStage, SourceDiagnosisStage.details);
      expect(report.stages.map((row) => row.stage), [
        SourceDiagnosisStage.catalog,
        SourceDiagnosisStage.details,
      ]);
      expect(
        _rowOf(report, SourceDiagnosisStage.catalog).status,
        SourceDiagnosisStatus.pass,
      );
      final details = _rowOf(report, SourceDiagnosisStage.details);
      expect(details.status, SourceDiagnosisStatus.fail);
      expect(details.kind, DiagnosisFailureKind.script);
      expect(pagesCalled, isFalse);
      expect(imageCalled, isFalse);
    });

    test(
      'timeout reports unknown and a late complete cannot flip it',
      () async {
        final pending = Completer<Res<ComicDetails>>();
        final source = _source(
          explorePages: [
            _explorePage((_) async => Res([_comic('slow')])),
          ],
          loadInfo: (_) => pending.future,
          loadPages: (_, _) async => Res(['img-1']),
        );
        final report = await _checker(
          stageTimeout: const Duration(milliseconds: 10),
        ).check(source);

        expect(report.verdict, SourceDiagnosisVerdict.unknown);
        expect(report.failedStage, isNull);
        final details = _rowOf(report, SourceDiagnosisStage.details);
        expect(details.status, SourceDiagnosisStatus.unknown);
        expect(details.kind, DiagnosisFailureKind.timeout);

        // The underlying work still completes late; the settled report is
        // immutable and must not flip to readable.
        pending.complete(Res(_details(id: 'slow', chapters: {'c1': 'C1'})));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(report.verdict, SourceDiagnosisVerdict.unknown);
        expect(
          _rowOf(report, SourceDiagnosisStage.details).status,
          SourceDiagnosisStatus.unknown,
        );
      },
    );

    test('timeout discards a late error without unhandled failures', () async {
      final pending = Completer<Res<List<String>>>();
      final source = _source(
        explorePages: [
          _explorePage((_) async => Res([_comic('slow')])),
        ],
        loadInfo: (id) async => Res(_details(id: id, chapters: {'c1': 'C1'})),
        loadPages: (_, _) => pending.future,
      );
      final report = await _checker(
        stageTimeout: const Duration(milliseconds: 10),
      ).check(source);

      expect(report.verdict, SourceDiagnosisVerdict.unknown);
      expect(
        _rowOf(report, SourceDiagnosisStage.pages).kind,
        DiagnosisFailureKind.timeout,
      );

      pending.completeError(StateError('late transport boom'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(report.verdict, SourceDiagnosisVerdict.unknown);
    });

    test('chapter-less works pass null into loadEp', () async {
      final pagesArgs = <String?>[];
      var episodeSeen = 'unset';
      final source = _source(
        explorePages: [
          _explorePage((_) async => Res([_comic('flat')])),
        ],
        loadInfo: (id) async => Res(_details(id: id)),
        loadPages: (id, ep) async {
          pagesArgs.add(ep);
          return Res(['img-1']);
        },
      );
      final report = await _checker(
        imageLoader:
            ({
              required imageKey,
              required sourceKey,
              required comicId,
              required episodeId,
            }) async {
              episodeSeen = episodeId;
              return Uint8List.fromList([7, 7, 7]);
            },
      ).check(source);

      expect(report.verdict, SourceDiagnosisVerdict.readable);
      expect(pagesArgs, [isNull]);
      expect(episodeSeen, SourceDiagnosisChecker.chapterlessEpisodeId);
    });

    test('user-supplied ID skips catalog without probing explore', () async {
      var exploreCalled = false;
      final infoArgs = <String>[];
      final source = _source(
        explorePages: [
          _explorePage((_) async {
            exploreCalled = true;
            return Res([_comic('never-used')]);
          }),
        ],
        loadInfo: (id) async {
          infoArgs.add(id);
          return Res(_details(id: id, chapters: {'c1': 'C1'}));
        },
        loadPages: (_, _) async => Res(['img-1']),
      );
      final report = await _checker().check(source, comicId: '  custom-id ');

      expect(report.verdict, SourceDiagnosisVerdict.readable);
      expect(report.comicIdUserProvided, isTrue);
      final catalog = _rowOf(report, SourceDiagnosisStage.catalog);
      expect(catalog.status, SourceDiagnosisStatus.skipped);
      expect(catalog.kind, isNull);
      expect(exploreCalled, isFalse);
      expect(infoArgs, ['custom-id']);
    });

    test('empty bytes and corrupt images classify as image failures', () async {
      ComicSource source() => _source(
        explorePages: [
          _explorePage((_) async => Res([_comic('pic')])),
        ],
        loadInfo: (id) async => Res(_details(id: id, chapters: {'c1': 'C1'})),
        loadPages: (_, _) async => Res(['img-1']),
      );

      final empty = await _checker(
        imageLoader:
            ({
              required imageKey,
              required sourceKey,
              required comicId,
              required episodeId,
            }) async => Uint8List(0),
      ).check(source());
      expect(empty.verdict, SourceDiagnosisVerdict.failed);
      expect(empty.failedStage, SourceDiagnosisStage.image);
      expect(
        _rowOf(empty, SourceDiagnosisStage.image).kind,
        DiagnosisFailureKind.image,
      );

      final corrupt = await _checker(
        imageValidator: (_) async => throw StateError('cannot decode'),
      ).check(source());
      expect(corrupt.verdict, SourceDiagnosisVerdict.failed);
      expect(corrupt.failedStage, SourceDiagnosisStage.image);
      expect(
        _rowOf(corrupt, SourceDiagnosisStage.image).kind,
        DiagnosisFailureKind.image,
      );
    });
  });

  group('diagnosis models', () {
    test('sample titles are truncated to the whitelist budget', () async {
      final source = _source(
        explorePages: [
          _explorePage((_) async => Res([_comic('long')])),
        ],
        loadInfo: (id) async =>
            Res(_details(id: id, title: 't' * 80, chapters: {'c1': 'C1'})),
        loadPages: (_, _) async => Res(['img-1']),
      );
      final report = await _checker().check(source);
      expect(
        report.sampleTitle,
        't' * SourceDiagnosisLimits.sampleTitleMaxChars,
      );
    });

    test('unknown rows require timeout/env kinds and vice versa', () {
      expect(
        () => SourceDiagnosisStageResult(
          stage: SourceDiagnosisStage.details,
          status: SourceDiagnosisStatus.unknown,
          kind: DiagnosisFailureKind.script,
          elapsedMs: 1,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => SourceDiagnosisStageResult(
          stage: SourceDiagnosisStage.details,
          status: SourceDiagnosisStatus.fail,
          kind: DiagnosisFailureKind.timeout,
          elapsedMs: 1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('diagnosis classifier', () {
    test('auth beats network; network beats script', () {
      expect(
        classifyDiagnosisFailure(
          StateError('401 Unauthorized'),
          stage: SourceDiagnosisStage.details,
        ),
        DiagnosisFailureKind.auth,
      );
      expect(
        classifyDiagnosisFailure(
          StateError('SocketException: failed host lookup'),
          stage: SourceDiagnosisStage.pages,
        ),
        DiagnosisFailureKind.network,
      );
      expect(
        classifyDiagnosisFailure(
          StateError('weird JS crash'),
          stage: SourceDiagnosisStage.details,
        ),
        DiagnosisFailureKind.script,
      );
    });

    test('image stage maps every error to image except timeout', () {
      expect(
        classifyDiagnosisFailure(
          StateError('401 Unauthorized'),
          stage: SourceDiagnosisStage.image,
        ),
        DiagnosisFailureKind.image,
      );
      expect(
        classifyDiagnosisFailure(
          TimeoutException('t'),
          stage: SourceDiagnosisStage.image,
        ),
        DiagnosisFailureKind.timeout,
      );
    });
  });
}
