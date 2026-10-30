import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/diagnosis/source_diagnosis_dialog.dart';
import 'package:venera_unified/features/comic_source/diagnosis/source_diagnosis_manager.dart';
import 'package:venera_unified/features/comic_source/diagnosis/source_diagnosis_models.dart';
import 'package:venera_unified/features/comic_source/source.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/translations.dart';

ComicSource _source({String name = 'Test Source', String key = 'test'}) =>
    ComicSource(
      name,
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

SourceDiagnosisReport _readableReport({
  String sourceKey = 'test',
  String? title = 'Sample title',
  bool catalogSkipped = false,
}) {
  return SourceDiagnosisReport(
    sourceKey: sourceKey,
    sourceName: 'Test Source',
    verdict: SourceDiagnosisVerdict.readable,
    stages: [
      SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.catalog,
        status: catalogSkipped
            ? SourceDiagnosisStatus.skipped
            : SourceDiagnosisStatus.pass,
        elapsedMs: catalogSkipped ? 0 : 12,
      ),
      const SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.details,
        status: SourceDiagnosisStatus.pass,
        elapsedMs: 34,
      ),
      const SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.pages,
        status: SourceDiagnosisStatus.pass,
        elapsedMs: 56,
      ),
      const SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.image,
        status: SourceDiagnosisStatus.pass,
        elapsedMs: 78,
      ),
    ],
    title: title,
    comicIdUserProvided: catalogSkipped,
    diagnosedAt: DateTime(2026, 10, 30, 12, 34),
  );
}

SourceDiagnosisReport _timeoutReport({String? title}) {
  return SourceDiagnosisReport(
    sourceKey: 'test',
    sourceName: 'Test Source',
    verdict: SourceDiagnosisVerdict.unknown,
    stages: const [
      SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.details,
        status: SourceDiagnosisStatus.pass,
        elapsedMs: 20,
      ),
      SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.pages,
        status: SourceDiagnosisStatus.unknown,
        elapsedMs: 15000,
        kind: DiagnosisFailureKind.timeout,
      ),
    ],
    title: title ?? 'Sample title',
    comicIdUserProvided: false,
    diagnosedAt: DateTime(2026, 10, 30, 12, 35),
  );
}

SourceDiagnosisReport _failedReport() {
  return SourceDiagnosisReport(
    sourceKey: 'test',
    sourceName: 'Test Source',
    verdict: SourceDiagnosisVerdict.failed,
    failedStage: SourceDiagnosisStage.pages,
    stages: const [
      SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.catalog,
        status: SourceDiagnosisStatus.pass,
        elapsedMs: 10,
      ),
      SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.details,
        status: SourceDiagnosisStatus.pass,
        elapsedMs: 20,
      ),
      SourceDiagnosisStageResult(
        stage: SourceDiagnosisStage.pages,
        status: SourceDiagnosisStatus.fail,
        elapsedMs: 30,
        kind: DiagnosisFailureKind.network,
      ),
    ],
    title: 'Sample title',
    comicIdUserProvided: false,
    diagnosedAt: DateTime(2026, 10, 30, 12, 36),
  );
}

class _Runner {
  final calls = <String?>[];
  final completer = Completer<SourceDiagnosisReport>();

  Future<SourceDiagnosisReport> run(
    ComicSource source, {
    String? comicId,
    SourceDiagnosisEventCallback? onEvent,
  }) {
    calls.add(comicId);
    return completer.future;
  }
}

Widget _dialogApp(SourceDiagnosisDialog dialog) {
  return MaterialApp(home: Scaffold(body: dialog));
}

String _allText(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data ?? '')
      .join('\n');
}

void _mockClipboard(WidgetTester tester, List<String> copies) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copies.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  Object? language;
  setUp(() {
    language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
  });
  tearDown(() => appdata.settings['language'] = language);

  testWidgets('opening the dialog never starts a diagnosis', (tester) async {
    final runner = _Runner();
    final manager = SourceDiagnosisManager(runner: runner.run);
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      _dialogApp(SourceDiagnosisDialog(source: _source(), manager: manager)),
    );
    await tester.pumpAndSettle();

    expect(runner.calls, isEmpty);
    expect(find.text('Diagnose readability'), findsOneWidget);
    expect(find.text('Start diagnosis'), findsOneWidget);
    expect(find.textContaining('real network requests'), findsOneWidget);
    expect(find.textContaining('Comic ID (optional)'), findsOneWidget);
    expect(find.text('Readable'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a running diagnosis disables start and the comic ID field', (
    tester,
  ) async {
    final runner = _Runner();
    final manager = SourceDiagnosisManager(runner: runner.run);
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      _dialogApp(SourceDiagnosisDialog(source: _source(), manager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start diagnosis'));
    await tester.pump();

    expect(runner.calls, [null]);
    expect(find.text('Diagnosis in progress…'), findsOneWidget);
    final startButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Diagnosis in progress…'),
    );
    expect(startButton.onPressed, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    runner.completer.complete(_readableReport());
    await tester.pumpAndSettle();

    expect(find.text('Readable'), findsOneWidget);
    expect(find.text('Recheck'), findsOneWidget);
    expect(find.text('Passed · 12 ms'), findsOneWidget);
    expect(find.text('Start diagnosis'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a timeout is shown as unknown without invalid wording', (
    tester,
  ) async {
    final runner = _Runner();
    final manager = SourceDiagnosisManager(runner: runner.run);
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      _dialogApp(SourceDiagnosisDialog(source: _source(), manager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start diagnosis'));
    await tester.pump();
    runner.completer.complete(_timeoutReport());
    await tester.pumpAndSettle();

    expect(find.text('Unknown'), findsWidgets);
    expect(find.textContaining('Timed out'), findsOneWidget);
    expect(find.textContaining('timed out'), findsOneWidget);
    final text = _allText(tester).toLowerCase();
    expect(text, isNot(contains('invalid')));
    expect(text, isNot(contains('fails')));
    expect(_allText(tester), isNot(contains('失效')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed diagnosis always names its failing stage', (
    tester,
  ) async {
    final runner = _Runner();
    final manager = SourceDiagnosisManager(runner: runner.run);
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      _dialogApp(SourceDiagnosisDialog(source: _source(), manager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start diagnosis'));
    await tester.pump();
    runner.completer.complete(_failedReport());
    await tester.pumpAndSettle();

    expect(find.text('Failed'), findsWidgets);
    expect(find.text('Failed at: Chapter pages'), findsOneWidget);
    expect(find.text('Failed · Network error · 30 ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copying the summary never copies URLs or exception text', (
    tester,
  ) async {
    final copies = <String>[];
    _mockClipboard(tester, copies);
    // The report body is taller than the default 800x600 surface; give this
    // test room so the copy button is hit-testable.
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final runner = _Runner();
    final manager = SourceDiagnosisManager(runner: runner.run);
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      _dialogApp(SourceDiagnosisDialog(source: _source(), manager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start diagnosis'));
    await tester.pump();
    runner.completer.complete(
      _readableReport(
        title:
            'Leak https://example.test/private/comic?token=abc TimeoutException',
        catalogSkipped: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Skipped · 0 ms'), findsOneWidget);
    await tester.tap(find.text('Copy diagnosis summary'));
    await tester.pumpAndSettle();

    expect(copies, hasLength(1));
    final copied = copies.single;
    expect(copied, contains('Diagnosis summary'));
    expect(copied, contains('Readable'));
    expect(copied, contains('Catalog'));
    expect(copied, contains('Skipped'));
    expect(copied, isNot(contains('http')));
    expect(copied, isNot(contains('example.test')));
    expect(copied, isNot(contains('token')));
    expect(copied, isNot(contains('TimeoutException')));
    expect(copied, isNot(contains('失效')));
    expect(find.text('Diagnosis summary copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening follows the in-flight round instead of starting one', (
    tester,
  ) async {
    final runner = _Runner();
    final manager = SourceDiagnosisManager(runner: runner.run);
    addTearDown(manager.dispose);
    final source = _source();

    unawaited(manager.start(source));
    await tester.pumpWidget(
      _dialogApp(SourceDiagnosisDialog(source: source, manager: manager)),
    );
    await tester.pump();

    expect(runner.calls, hasLength(1));
    expect(find.text('Diagnosis in progress…'), findsOneWidget);

    runner.completer.complete(_readableReport());
    await tester.pumpAndSettle();

    expect(find.text('Readable'), findsOneWidget);
    expect(runner.calls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a settling round waits without offering a new start', (
    tester,
  ) async {
    final linger = Completer<void>();
    final runner = _Runner();
    final manager = SourceDiagnosisManager(
      runner: runner.run,
      lingerProbe: (_) => linger.future,
    );
    addTearDown(manager.dispose);

    await tester.pumpWidget(
      _dialogApp(SourceDiagnosisDialog(source: _source(), manager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start diagnosis'));
    await tester.pump();
    runner.completer.complete(_timeoutReport());
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Waiting for the previous diagnosis request to finish…'),
      findsOneWidget,
    );
    final waitButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Please wait…'),
    );
    expect(waitButton.onPressed, isNull);
    expect(find.textContaining('cancel'), findsNothing);

    linger.complete();
    await tester.pumpAndSettle();

    expect(find.text('Recheck'), findsOneWidget);
    expect(find.text('Please wait…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalidated round drops its report and shows a notice', (
    tester,
  ) async {
    final runner = _Runner();
    final manager = SourceDiagnosisManager(runner: runner.run);
    addTearDown(manager.dispose);
    final source = _source();

    await tester.pumpWidget(
      _dialogApp(SourceDiagnosisDialog(source: source, manager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start diagnosis'));
    await tester.pump();

    manager.invalidateSource('test');
    await tester.pump();
    runner.completer.complete(_readableReport());
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('The source changed during diagnosis'),
      findsOneWidget,
    );
    expect(find.text('Readable'), findsNothing);
    expect(find.text('Start diagnosis'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the clipboard guard rejects private fields', () {
    final summary = buildSourceDiagnosisSummary(
      _readableReport(title: 'See https://example.test/private'),
    );
    expect(summary, isNot(contains('http')));
    expect(
      () => assertSourceDiagnosisSummaryIsPrivate(summary),
      returnsNormally,
    );
    expect(
      () => assertSourceDiagnosisSummaryIsPrivate('Cookie: session=secret'),
      throwsStateError,
    );
    expect(
      () => assertSourceDiagnosisSummaryIsPrivate('https://example.test/a'),
      throwsStateError,
    );
    expect(
      () => assertSourceDiagnosisSummaryIsPrivate('TimeoutException: boom'),
      throwsStateError,
    );
  });
}
