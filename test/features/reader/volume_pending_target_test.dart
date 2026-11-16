import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_unified/components/message.dart';
import 'package:venera_unified/features/comic_source/models.dart';
import 'package:venera_unified/foundation/comic_type.dart';
import 'package:venera_unified/features/favorites/favorites_manager.dart';
import 'package:venera_unified/features/favorites/favorites_scope.dart';
import 'package:venera_unified/features/history/history.dart';
import 'package:venera_unified/features/history/history_scope.dart';
import 'package:venera_unified/features/local_comics/local_comics.dart';
import 'package:venera_unified/features/reader/platform_effects.dart'
    show ReaderPlatformEffectsScope;
import 'package:venera_unified/features/reader/reader_page.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/routing/app_navigation.dart';

import 'support/favorites_read_fixture.dart';

void main() {
  testWidgets('consecutive turns chain from the in-flight target', (
    tester,
  ) async {
    final previous = jsonDecode(
      jsonEncode(appdata.toJson()['settings']),
    ) as Map<String, dynamic>;
    final previousFavorites = _favoritesOwner;
    final previousHistory = _historyOwner;
    final directory = Directory.systemTemp.createTempSync('volume-pending-');
    final key = GlobalKey<_ReaderState>();
    Log.isMuted = true;
    try {
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      _favoritesOwner = ReaderFavoritesStub();
      final settings = appdata.settings;
      settings['comicSpecificSettings'] = <String, dynamic>{};
      settings['deviceSpecificSettings'] = <String, dynamic>{};
      settings['autoReaderMode'] = false;
      settings['readerMode'] = 'continuousTopToBottom';
      settings['enablePageAnimation'] = true;
      settings['enableClockAndBatteryInfoInReader'] = false;
      settings['showPageNumberInReader'] = false;
      settings['eInkMode'] = false;
      settings['limitImageWidth'] = false;
      settings['preloadImageCount'] = 1;
      settings['language'] = 'en-US';
      LocalManager.current?.dispose();
      LocalManager(initializeSources: () async {});
      await tester.runAsync(() async {
        Directory('${directory.path}/comics').createSync();
        File('${directory.path}/local_path')
            .writeAsStringSync('${directory.path}/comics');
        _historyOwner = _TestHistory();
        await _historyForView().init();
        await LocalManager().init();
        final png = img.encodePng(img.Image(width: 100, height: 200));
        final folder = Directory('${LocalManager().path}/book/one')
          ..createSync(recursive: true);
        for (var i = 1; i <= 30; i++) {
          File('${folder.path}/$i.png').writeAsBytesSync(png);
        }
        await LocalManager().add(
          LocalComic(
            id: 'book',
            title: 'Book',
            subtitle: '',
            tags: const [],
            directory: 'book',
            chapters: _chapters,
            cover: '',
            comicType: ComicType.local,
            downloadedChapters: const ['one'],
            createdAt: DateTime(2026),
          ),
        );
      });
      await tester.pumpWidget(
        _libraryView(
          MaterialApp(
            builder: (context, child) =>
                ReaderPlatformEffectsScope(child: child!),
            navigatorKey: appNavigation.rootNavigatorKey,
            home: Scaffold(body: OverlayWidget(_Reader(key: key))),
          ),
        ),
      );
      Future<void> frames(int count) async {
        for (var i = 0; i < count; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (i % 10 == 0) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
        }
      }

      final reader = key.currentState!;
      for (var i = 0; i < 30 && reader.imageViewController == null; i++) {
        await frames(5);
      }
      await frames(50);
      expect(reader.isPageAnimating, isFalse);
      expect(reader.page, 1);
      // Start an animated jump and assert before any frame can settle it.
      var started = false;
      for (var i = 0; i < 60 && !started; i++) {
        started = reader.toPage(5);
        if (!started) await frames(2);
      }
      for (var i = 0; i < 60 && reader.controller.pageCount() < 30; i++) {
        await frames(5);
      }
      expect(reader.controller.pageCount(), 30);
      expect(started, isTrue);
      expect(reader.controller.state.pendingPage, 5);
      // A consecutive turn must chain from the pending target (5),
      // not re-request from the settled page (1).
      expect(reader.toNextPage(), isTrue);
      expect(reader.controller.state.pendingPage, 6);
      expect(reader.toPrevPage(), isTrue);
      expect(reader.controller.state.pendingPage, 5);
      // Settle deterministically through the immediate path.
      expect(reader.toPage(5, animated: false), isTrue);
      expect(reader.isPageAnimating, isFalse);
      expect(reader.page, 5);
      // Idle turns still step from the settled page.
      expect(reader.toNextPage(), isTrue);
      expect(reader.controller.state.pendingPage, 6);
      reader.resetPageAnimation();
      expect(reader.isPageAnimating, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      LocalManager.current?.dispose();
      if (_historyOwner?.isInitialized == true) {
        _historyForView().close();
      }
      _historyOwner = previousHistory;
      _favoritesOwner = previousFavorites;
      Log.isMuted = false;
      previous.forEach((key, value) => appdata.settings[key] = value);
      await tester.runAsync(() async {
        await appdata.saveData(false);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await directory.delete(recursive: true);
      });
    }
  });
}

const _chapters = ComicChapters({'one': 'One'});

class _TestHistory extends HistoryManager {
  _TestHistory() : super.create();
  @override
  Future<void> addReadDuration(History history, Duration duration) async {}
}

LocalFavoritesManager? _favoritesOwner;
LocalFavoritesManager _favoritesForView() =>
    _favoritesOwner ??= LocalFavoritesManager.independent();
HistoryManager? _historyOwner;
HistoryManager _historyForView() => _historyOwner ??= HistoryManager.create();
Widget _libraryView(Widget child) {
  return FavoritesScope(
    manager: _favoritesForView(),
    child: HistoryScope(manager: _historyForView(), child: child),
  );
}

class _Reader extends Reader {
  _Reader({required super.key})
    : super(
        onClosed: () {},
        type: ComicType.local,
        cid: 'book',
        name: 'Book',
        author: '',
        tags: const [],
        chapters: _chapters,
        history: History.fromMap({
          'id': 'book',
          'type': 0,
          'time': 1000,
          'title': 'Book',
          'subtitle': '',
          'cover': '',
          'ep': 1,
          'page': 1,
          'max_page': 30,
        }),
      );
  @override
  ReaderState createState() => _ReaderState();
}

class _ReaderState extends ReaderState {
  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}
  @override
  void updateHistory() {}
}
