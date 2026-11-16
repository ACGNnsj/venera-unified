import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_unified/features/reader/continuous_data.dart';
import 'package:venera_unified/features/reader/continuous_view.dart';
import 'package:venera_unified/features/reader/reader_controller.dart';
import 'package:venera_unified/features/reader/reader_viewport.dart';
import 'package:venera_unified/foundation/cache_manager.dart';
import 'package:venera_unified/foundation/image_work.dart';
import 'package:venera_unified/foundation/reader_diagnostics.dart';
import 'package:venera_unified/network/images.dart';

/// Widget-level regression for the decoded-image lookahead in
/// [ContinuousModeState.cacheImages] (`_decodedAhead`): regular devices
/// precache two decoded neighbours per side, the TV low-memory decode budget
/// precaches one, and a zero preload count disables decoded prefetch.
///
/// The decoded path is observed through the diagnostics `cacheLookup` events
/// it records (two per precached neighbour, before and after resolve); the
/// encoded path records none. Display-path lookups are baselined after the
/// mount settles, so the delta only counts [cacheImages] neighbours.
class _Fixture {
  _Fixture({this.preloadCount = 2, this.decodePixelBudget})
    : keys = [for (var i = 0; i < 9; i++) 'decoded-ahead-$i'];

  final int preloadCount;
  final int? decodePixelBudget;
  final List<String> keys;

  static const sourceKey = 'decoded-ahead-source';
  static const comicId = 'decoded-ahead-book';

  late final Directory directory = Directory.systemTemp.createTempSync(
    'decoded-ahead-',
  );
  late final CacheManager cache = CacheManager.open(
    dataPath: directory.path,
    cacheRoot: directory.path,
  );
  CacheManager? previous;
  late final Uint8List png = img.encodePng(img.Image(width: 40, height: 80));

  final viewport = ReaderViewportBinding();
  final diagnostics = ReaderDiagnostics(
    nowMicros: () => 0,
    attachTimings: (_) {},
    detachTimings: (_) {},
  );
  late final ImageWork imageWork = ImageWork(diagnostics: diagnostics);
  late final ReaderController navigation =
      ReaderController(
          pageCount: () => keys.length,
          chapterCount: () => 1,
          animationEnabled: () => false,
          viewport: () => viewport.current,
          onChanged: () {},
          onPageChanged: () {},
          onError: (error, _) => fail('$error'),
        )
        ..restoreChapter(1)
        ..replaceChapterImages(keys);

  // Cache writes use real async file/sqlite IO, which never completes
  // inside the testWidgets FakeAsync zone unless driven via runAsync.
  Future<void> seed(WidgetTester tester) async {
    previous = CacheManager.instance;
    CacheManager.instance = cache;
    await tester.runAsync(() async {
      for (final key in keys) {
        await cache.writeCache('$key@$sourceKey@$comicId@id-1', png);
      }
    });
  }

  Widget build() => MaterialApp(
    home: Material(
      child: ReaderContinuousView(
        imageWork: imageWork,
        data: ReaderContinuousData(
          vertical: true,
          reverse: false,
          crossChapter: false,
          firstChapter: true,
          lastChapter: true,
          maxChapter: 1,
          preloadCount: preloadCount,
          splitWideImages: false,
          invertSplit: false,
          scrollSpeed: 1,
          limitImageWidth: false,
          sideMargin: 0,
          doubleTapCollect: false,
          centerLongPressZoom: false,
          sourceKey: sourceKey,
          comicId: comicId,
          decodePixelBudget: decodePixelBudget,
        ),
        navigation: navigation,
        loadChapter: (chapter, scope) async => keys,
        chapterId: (chapter) => 'id-$chapter',
        chapterTitle: (chapter) => 'Title $chapter',
        onViewportChanged: viewport.update,
        onUpdate: () {},
        onFloatingButton: (_) {},
        onCollectImage: () {},
        onActiveChapterChanged: () {},
        onContentLoading: (_) {},
        onPreviousError: (error, _) => fail('$error'),
        onNavigationError: (_, error, _) => fail('$error'),
        readerSize: () => const Size(800, 600),
        readImage: (_) => Future.value(png),
      ),
    ),
  );

  ContinuousModeState state(WidgetTester tester) =>
      tester.state<ContinuousModeState>(find.byType(ReaderContinuousView));

  int cacheLookups() {
    final report = jsonDecode(diagnostics.exportJson()) as Map;
    return (report['imageEvents'] as List)
        .where((event) => (event as Map)['stage'] == 'cacheLookup')
        .length;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => pumpEventQueue());
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final closing = imageWork.dispose();
    unawaited(closing.then((_) => closed = true));
    while (!closed) {
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
    }
    await closing;
    navigation.dispose();
    ImageDownloader.cancelAllLoadingImages();
    CacheManager.instance = previous;
    await tester.runAsync(() => cache.dispose());
    directory.deleteSync(recursive: true);
    diagnostics.dispose();
  }
}

Future<void> _expectAhead(
  WidgetTester tester,
  _Fixture fixture,
  int expected,
) async {
  await fixture.seed(tester);
  try {
    fixture.diagnostics.start(
      mode: ReaderDiagnosticMode.continuous,
      processingEnabled: false,
      appVersion: 'test',
      refreshRate: 60,
    );
    await tester.pumpWidget(fixture.build());
    await fixture.settle(tester);
    final before = fixture.cacheLookups();
    fixture.state(tester).cacheImages(3, 5);
    await fixture.settle(tester);
    expect(fixture.cacheLookups() - before, expected);
    expect(tester.takeException(), isNull);
  } finally {
    await fixture.dispose(tester);
  }
}

void main() {
  testWidgets('regular devices precache two decoded neighbours per side', (
    tester,
  ) async {
    // Neighbours of 3..5 at indices 1, 2 and 6, 7: four precaches,
    // each recording a lookup before and after resolve.
    await _expectAhead(tester, _Fixture(), 8);
  });

  testWidgets('tv low-memory budget precaches one decoded neighbour per side', (
    tester,
  ) async {
    await _expectAhead(tester, _Fixture(decodePixelBudget: 1), 4);
  });

  testWidgets('zero preload disables decoded prefetch', (tester) async {
    await _expectAhead(tester, _Fixture(preloadCount: 0), 0);
  });
}
