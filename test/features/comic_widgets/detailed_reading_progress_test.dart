import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/app_runtime/init.dart' as runtime;
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_widgets/comic_tile.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/features/history/history_page.dart';
import 'package:venera_next/foundation/appdata.dart';

class _Source extends Fake implements ComicSource {
  int requests = 0;
  @override
  String get key => 'progress-source';
  @override
  int get intKey => key.hashCode;
  @override
  String get name => 'Source';
  @override
  bool get enableTagsTranslate => false;
  @override
  LoadComicFunc get loadComicInfo => (_) async {
    requests++;
    throw StateError('Progress display must not load comic metadata');
  };
  @override
  LoadComicPagesFunc get loadComicPages => (_, _) async {
    requests++;
    throw StateError('Progress display must not load chapter pages');
  };
}

class _HistoryManager extends HistoryManager {
  _HistoryManager(this.items) : super.create();
  final List<History> items;
  @override
  List<History> getAll() => items;
}

History _history(_Source source) => History.fromMap({
  'type': source.intKey,
  'time': 1000,
  'title': 'Book',
  'subtitle': '',
  'cover': '',
  'id': 'book',
  'ep': 21,
  'page': 162,
  'max_chapter': 55,
  'max_page': 233,
});

void main() {
  late _Source source;
  setUp(() async {
    final oldSettings = {
      for (final key in [
        'language',
        'comicDisplayMode',
        'showFavoriteStatusOnTile',
        'showUpdateStatusOnTile',
        'showHistoryStatusOnTile',
        'showDetailedReadingProgress',
      ])
        key: appdata.settings[key],
    };
    appdata.settings['language'] = 'en-US';
    appdata.settings['comicDisplayMode'] = 'brief';
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showUpdateStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['showDetailedReadingProgress'] = true;
    source = _Source();
    configureComicSourceRegistry(
      all: () => [source],
      find: (key) => key == source.key ? source : null,
      fromIntKey: (key) => key == source.intKey ? source : null,
      isEmpty: () => false,
    );
    Future<void> ready() async {}
    final core = CoreBootstrap(
      environment: ready,
      settings: ready,
      infrastructure: ready,
      sources: ready,
      stores: ready,
      finish: ready,
    );
    final errorHandler = FlutterError.onError;
    try {
      await runtime.init(core);
    } finally {
      FlutterError.onError = errorHandler;
    }
    addTearDown(() async {
      expect(source.requests, 0);
      configureComicWidgets();
      configureComicSourceRegistry(
        all: () => [],
        find: (_) => null,
        fromIntKey: (_) => null,
        isEmpty: () => true,
      );
      oldSettings.forEach((key, value) => appdata.settings[key] = value);
      await core.close();
    });
  });

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    for (final mode in ['detailed', 'brief']) {
      testWidgets('history page shows local totals in $mode at $size', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        appdata.settings['comicDisplayMode'] = mode;
        final manager = _HistoryManager([_history(source)]);
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MaterialApp(home: HistoryPage(manager: manager)),
        );
        if (mode == 'detailed') {
          expect(find.text('Chapter 21 / 55 - Page 162 / 233'), findsOneWidget);
        } else {
          expect(find.text('Ch. 21/55'), findsOneWidget);
          expect(find.text('P. 162/233'), findsOneWidget);
        }
        expect(
          find.byTooltip('Chapter 21 / 55 - Page 162 / 233'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('history totals do not require enabling thumbnail badges', (
    tester,
  ) async {
    final item = _history(source);
    Widget view() => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(
              width: 375,
              height: 180,
              child: ComicTile(
                comic: item,
                displayMode: ComicTileDisplayMode.detailed,
              ),
            ),
            SimpleComicTile(comic: item),
          ],
        ),
      ),
    );
    await tester.pumpWidget(view());
    expect(find.text('Chapter 21 / 55 - Page 162 / 233'), findsOneWidget);
    expect(find.text('Ch. 21/55'), findsNothing);
    appdata.settings['showHistoryStatusOnTile'] = true;
    await tester.pumpWidget(view());
    expect(find.text('Chapter 21 / 55 - Page 162 / 233'), findsOneWidget);
    expect(find.text('Ch. 21/55'), findsOneWidget);
    expect(find.text('P. 162/233'), findsOneWidget);
    appdata.settings['showDetailedReadingProgress'] = false;
    await tester.pumpWidget(view());
    expect(find.text('Chapter 21 - Page 162'), findsNWidgets(3));
    expect(find.text('Ch. 21/55'), findsNothing);
    expect(item.maxChapter, 55);
    expect(item.maxPage, 233);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('legacy histories retain known page totals in compact tiles', (
    tester,
  ) async {
    appdata.settings['showHistoryStatusOnTile'] = true;
    final item = _history(source)..maxChapter = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SimpleComicTile(comic: item)),
      ),
    );
    expect(find.text('Ch. 21'), findsOneWidget);
    expect(find.text('P. 162/233'), findsOneWidget);
    expect(find.byTooltip('Chapter 21 - Page 162 / 233'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('long chapter names do not displace totals or lose semantics', (
    tester,
  ) async {
    const title = 'A very long chapter title with a subtitle and punctuation';
    const progress = 'Chapter 21 / 55 - Page 162 / 233';
    const tooltip = '$title - Page 162\n$progress';
    final item = _history(source)..chapterTitle = title;
    appdata.settings['showHistoryStatusOnTile'] = true;
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 375,
                  height: 200,
                  child: ComicTile(
                    comic: item,
                    displayMode: ComicTileDisplayMode.detailed,
                  ),
                ),
                SimpleComicTile(comic: item),
              ],
            ),
          ),
        ),
      );
      expect(find.text(progress), findsOneWidget);
      expect(find.text('Ch. 21/55'), findsOneWidget);
      expect(find.text('P. 162/233'), findsOneWidget);
      expect(find.byTooltip(tooltip), findsNWidgets(2));
      expect(
        find.bySemanticsLabel(RegExp(RegExp.escape(tooltip))),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 3.0]) {
      testWidgets(
        'compact progress stays accessible at dark=$dark scale=$scale',
        (tester) async {
          const description =
              'Volume Two - A long chapter title (Chapter 21 / 55) - Page 162 / 233';
          configureComicWidgets(
            tileStateResolver: (_) => const ComicTileState(
              isFavorite: true,
              hasNewUpdate: true,
              historyPage: 162,
              historyMaxPage: 233,
              historyDescription: description,
              historyCompactDescription: 'Ch. 21/55\nP. 162/233',
            ),
          );
          final semantics = tester.ensureSemantics();
          try {
            final item = _history(source);
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                home: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: Scaffold(
                    body: Wrap(
                      children: [
                        SizedBox(
                          width: 72,
                          height: 180,
                          child: ComicTile(
                            comic: item,
                            displayMode: ComicTileDisplayMode.gallery,
                          ),
                        ),
                        SizedBox(
                          width: 160,
                          height: 240,
                          child: ComicTile(comic: item),
                        ),
                        SimpleComicTile(comic: item),
                      ],
                    ),
                  ),
                ),
              ),
            );
            expect(find.text('Ch. 21/55'), findsNWidgets(3));
            expect(find.text('P. 162/233'), findsNWidgets(3));
            expect(find.byTooltip(description), findsNWidgets(3));
            expect(find.bySemanticsLabel(description), findsNWidgets(3));
            for (var i = 0; i < 3; i++) {
              final chapter = tester.getRect(find.text('Ch. 21/55').at(i));
              final page = tester.getRect(find.text('P. 162/233').at(i));
              expect(page.top, greaterThanOrEqualTo(chapter.bottom));
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
