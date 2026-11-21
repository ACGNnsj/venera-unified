import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_details/chapters.dart';
import 'package:venera_unified/features/comic_source/models.dart';
import 'package:venera_unified/features/history/history_model.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/comic_type.dart';

void main() {
  testWidgets('detail catalog shows downloaded status by chapter ID', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ComicChaptersView(
                chapters: const ComicChapters({
                  'remote-id': 'Downloaded chapter',
                  'other': 'Other chapter',
                }),
                downloaded: const ['remote-id'],
                readChapter: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Find chapter'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(Icons.download_done_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog selection is rejected after its host changes books', (
    tester,
  ) async {
    final selections = <int>[];
    var chapters = ComicChapters({'one': 'First'});
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return CustomScrollView(
                slivers: [
                  ComicChaptersView(
                    chapters: chapters,
                    readChapter: selections.add,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Find chapter'));
    await tester.pumpAndSettle();
    update(() => chapters = ComicChapters({'one': 'First'}));
    await tester.pump();
    await tester.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text('First')),
    );
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });

  testWidgets('full catalog searches across groups and filters read chapters', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ComicChaptersView(
                chapters: ComicChapters.grouped({
                  'Volume A': {
                    for (var i = 1; i <= 500; i++) '$i': 'Chapter $i',
                  },
                  'Volume B': {
                    for (var i = 501; i <= 1000; i++) '$i': 'Chapter $i',
                  },
                }),
                history: History(
                  type: const ComicType(17),
                  time: DateTime(2026),
                  title: 'Book',
                  subtitle: '',
                  cover: '',
                  ep: 400,
                  group: 2,
                  page: 1,
                  id: 'book',
                  readEpisode: {'2-400', '2-500'},
                  maxPage: null,
                  readDurationMs: 0,
                ),
                readChapter: selected.add,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Find chapter'));
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    expect(
      find
          .descendant(of: dialog, matching: find.text('Chapter 900'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(
      find
          .descendant(of: dialog, matching: find.byType(InkWell))
          .evaluate()
          .length,
      lessThan(80),
    );
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      'chapter 1000',
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: dialog, matching: find.text('Chapter 1000')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('Unread')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: dialog, matching: find.text('Chapter 1000')),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('No data')),
      findsOneWidget,
    );
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      'Chapter 499',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('Chapter 499')).last,
    );
    await tester.pumpAndSettle();
    expect(selected, [499]);
    expect(dialog, findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final order in ['source', 'reverse']) {
    testWidgets(
      'normal chapter read marks follow original indices; order=$order',
      (tester) async {
        final previousOrder = appdata.settings['chapterOrder'];
        final previousLegacy = appdata.settings['reverseChapterOrder'];
        appdata.settings['chapterOrder'] = order;
        appdata.settings['reverseChapterOrder'] = false;
        addTearDown(() {
          appdata.settings['chapterOrder'] = previousOrder;
          appdata.settings['reverseChapterOrder'] = previousLegacy;
        });
        final history = History(
          type: const ComicType(17),
          time: DateTime(2026),
          title: 'Book',
          subtitle: '',
          cover: '',
          ep: 2,
          page: 1,
          id: 'book',
          readEpisode: {'2'},
          maxPage: null,
          readDurationMs: 0,
        );
        final selected = <int>[];
        final theme = ThemeData();
        Future<void> show(History? value) => tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  ComicChaptersView(
                    chapters: const ComicChapters({
                      'first-id': 'First chapter',
                      'other-id': 'Second chapter',
                    }),
                    history: value,
                    readChapter: selected.add,
                  ),
                ],
              ),
            ),
          ),
        );
        Color? color(String label) =>
            tester.widget<Text>(find.text(label)).style?.color;
        await show(history);
        expect(color('First chapter'), isNull);
        expect(color('Second chapter'), theme.colorScheme.outline);
        await tester.tap(find.text('Second chapter'));
        expect(selected, [2]);
        await show(null);
        expect(color('Second chapter'), isNull);
        await show(history.copy()..readEpisode = {'1'});
        expect(color('First chapter'), theme.colorScheme.outline);
        expect(color('Second chapter'), isNull);
      },
    );
  }
}
