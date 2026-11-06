import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/image_translation/translation_store.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.close();
    return true;
  } catch (_) {
    return false;
  }
}

TranslatedRegion _region(String text, {int left = 10}) {
  return TranslatedRegion(
    rect: IntRect(left, 20, left + 100, 60),
    text: text,
    backgroundColor: 0xffffffff,
    textColor: 0xff000000,
  );
}

TranslationChapterIdentity _chapter({
  String comicId = 'comic1',
  String chapterId = 'ch1',
}) {
  return TranslationChapterIdentity(
    scopePrefix: 'pageTranslation@2@ja>zh@local@$comicId@$chapterId@',
    sourceKey: 'local',
    comicId: comicId,
    chapterId: chapterId,
    sourceLang: 'ja',
    targetLang: 'zh',
  );
}

TranslationStore _openStore(Directory directory) {
  final store = TranslationStore.create();
  addTearDown(() {
    store.close();
    store.dispose();
  });
  return store;
}

void main() {
  group('TranslationStore put/get', skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable', () {
    late Directory directory;
    late TranslationStore store;

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('translation-store-');
      App.dataPath = directory.path;
      store = _openStore(directory);
      await store.init();
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    test('round-trips regions for a page', () {
      const key = 'pageTranslation@2@ja>zh@local@comic1@ch1@0001';
      store.put(key, [_region('hello'), _region('world', left: 200)]);
      final got = store.get(key);
      expect(got, isNotNull);
      expect(got!.map((r) => r.text), ['hello', 'world']);
      expect(got.first.rect.left, 10);
      expect(got.first.backgroundColor, 0xffffffff);
    });

    test('empty regions mean translated-without-text, unknown key is null', () {
      const key = 'pageTranslation@2@ja>zh@local@comic1@ch1@0002';
      store.put(key, const []);
      expect(store.get(key), isEmpty);
      expect(store.get('pageTranslation@2@ja>zh@local@comic1@ch1@nope'), isNull);
    });

    test('second put overwrites the first', () {
      const key = 'pageTranslation@2@ja>zh@local@comic1@ch1@0003';
      store.put(key, [_region('old')]);
      store.put(key, [_region('new')]);
      expect(store.get(key)!.single.text, 'new');
      expect(store.count, 1);
    });

    test('count and countByPrefix', () {
      store.put('pageTranslation@2@ja>zh@local@comic1@ch1@0001', [_region('a')]);
      store.put('pageTranslation@2@ja>zh@local@comic1@ch1@0002', [_region('b')]);
      store.put('pageTranslation@2@ja>zh@local@comic1@ch2@0001', [_region('c')]);
      expect(store.count, 3);
      expect(
        store.countByPrefix('pageTranslation@2@ja>zh@local@comic1@ch1@'),
        2,
      );
      expect(
        store.countByPrefix('pageTranslation@2@ja>zh@local@comic1@'),
        3,
      );
    });

    test('deleteByPrefix removes scoped rows and reports the count', () {
      const chapter = 'pageTranslation@2@ja>zh@local@comic1@ch1@';
      store.put('${chapter}0001', [_region('a')]);
      store.put('${chapter}0002', [_region('b')]);
      store.put('pageTranslation@2@ja>zh@local@comic1@ch2@0001', [_region('c')]);
      expect(store.deleteByPrefix(chapter), 2);
      expect(store.get('${chapter}0001'), isNull);
      expect(
        store.get('pageTranslation@2@ja>zh@local@comic1@ch2@0001'),
        isNotNull,
      );
    });

    test('deleteByPrefix escapes LIKE wildcards in the prefix', () {
      const withUnderscore = 'pageTranslation@2@ja>zh@local@comic1@ch_1@0001';
      const lookalike = 'pageTranslation@2@ja>zh@local@comic1@chx1@0001';
      store.put(withUnderscore, [_region('a')]);
      store.put(lookalike, [_region('b')]);
      expect(
        store.deleteByPrefix('pageTranslation@2@ja>zh@local@comic1@ch_1@'),
        1,
      );
      expect(store.get(lookalike), isNotNull);
    });

    test('clearAll wipes every row', () {
      store.put('pageTranslation@2@ja>zh@local@comic1@ch1@0001', [_region('a')]);
      store.put('pageTranslation@2@ja>zh@local@comic2@ch1@0001', [_region('b')]);
      expect(store.clearAll(), 2);
      expect(store.count, 0);
    });
  });

  group('TranslationStore chapter index', skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable', () {
    late Directory directory;
    late TranslationStore store;

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('translation-chapters-');
      App.dataPath = directory.path;
      store = _openStore(directory);
      await store.init();
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    test('put with a chapter builds chapters and comics', () {
      final ch1 = _chapter();
      store.put('pageTranslation@2@ja>zh@local@comic1@ch1@0001', [_region('a')], chapter: ch1);
      store.put('pageTranslation@2@ja>zh@local@comic1@ch1@0002', [_region('b')], chapter: ch1);
      store.put(
        'pageTranslation@2@ja>zh@local@comic1@ch2@0001',
        [_region('c')],
        chapter: _chapter(chapterId: 'ch2'),
      );

      final chapters = store.chapters;
      expect(chapters.map((c) => c.identity.chapterId).toSet(), {'ch1', 'ch2'});
      expect(
        chapters.firstWhere((c) => c.identity.chapterId == 'ch1').pageCount,
        2,
      );
      final comics = store.comics;
      expect(comics, hasLength(1));
      expect(comics.single.chapterCount, 2);
      expect(comics.single.pageCount, 3);
      expect(
        store.chaptersFor('local', 'comic1'),
        hasLength(2),
      );
      expect(store.chaptersFor('local', 'comic1', targetLang: 'en'), isEmpty);
    });

    test('updateComicMetadata fills titles and covers', () {
      final ch1 = _chapter();
      store.put('pageTranslation@2@ja>zh@local@comic1@ch1@0001', [_region('a')], chapter: ch1);
      store.updateComicMetadata(
        'local',
        'comic1',
        comicTitle: 'Title',
        comicCover: 'cover.jpg',
        chapterTitles: {'ch1': 'Chapter 1'},
      );
      final chapters = store.chapters;
      expect(chapters.single.identity.comicTitle, 'Title');
      expect(chapters.single.identity.comicCover, 'cover.jpg');
      expect(chapters.single.identity.chapterTitle, 'Chapter 1');
      expect(store.comics.single.title, 'Title');
    });

    test('recordExistingChapter indexes rows written without a chapter', () {
      store.put('pageTranslation@2@ja>zh@local@comic9@ch9@0001', [_region('a')]);
      store.put('pageTranslation@2@ja>zh@local@comic9@ch9@0002', const []);
      final chapter = TranslationChapterIdentity(
        scopePrefix: 'pageTranslation@2@ja>zh@local@comic9@ch9@',
        sourceKey: 'local',
        comicId: 'comic9',
        chapterId: 'ch9',
        sourceLang: 'ja',
        targetLang: 'zh',
      );
      expect(store.recordExistingChapter(chapter), 2);
      expect(store.chapters.map((c) => c.identity.comicId), contains('comic9'));
    });

    test('backfill indexes rows that predate the index', () async {
      // Write rows with a fresh handle that never went through put-with-chapter.
      store.put('pageTranslation@2@ja>zh@local@comic7@ch7@0001', [_region('a')]);
      store.close();
      final reopened = _openStore(directory);
      await reopened.init();
      expect(
        reopened.chapters.map((c) => c.identity.comicId),
        contains('comic7'),
      );
    });
  });

  group('TranslationStore legacy keys', skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable', () {
    late Directory directory;
    late TranslationStore store;

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('translation-legacy-');
      App.dataPath = directory.path;
      store = _openStore(directory);
      await store.init();
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    test('adoptLegacyKey moves a row to the stable key once', () {
      const legacy = 'transport-derived-key-1';
      const stable = 'pageTranslation@2@ja>zh@local@comic1@ch1@0001';
      store.put(legacy, [_region('moved')]);
      final regions = store.adoptLegacyKey(legacy, stable);
      expect(regions!.single.text, 'moved');
      expect(store.get(stable)!.single.text, 'moved');
      expect(store.get(legacy), isNull);
      // Second adoption finds nothing.
      expect(store.adoptLegacyKey(legacy, stable), isNull);
    });

    test('migrateLegacyKeys rewrites generation-1 keys', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute(
        'create table translated_page(cache_key text primary key, regions text, time int);',
      );
      db.execute(
        "insert into translated_page values('pageTranslation@ja>zh@local@c@ch@img', '[]', 1);",
      );
      db.execute(
        "insert into translated_page values('pageTranslation@2@ja>zh@local@c@ch@img2', '[]', 2);",
      );
      TranslationStore.migrateLegacyKeys(db);
      final keys = db
          .select('select cache_key from translated_page;')
          .map((r) => r['cache_key'] as String)
          .toSet();
      expect(keys, {
        'pageTranslation@2@ja>zh@local@c@ch@img',
        'pageTranslation@2@ja>zh@local@c@ch@img2',
      });
    });

    test('migrateSchema rebuilds on extra columns, backfills missing ones', () {
      final extra = sqlite3.openInMemory();
      addTearDown(extra.close);
      extra.execute(
        'create table translated_page(cache_key text primary key, regions text, time int, junk text);',
      );
      extra.execute("insert into translated_page values('k', '[]', 3, 'x');");
      TranslationStore.migrateSchema(extra);
      final cols = extra
          .select('PRAGMA table_info(translated_page);')
          .map((r) => r['name'] as String)
          .toSet();
      expect(cols, {'cache_key', 'regions', 'time'});
      expect(
        extra.select('select regions from translated_page;').first['regions'],
        '[]',
      );

      final missing = sqlite3.openInMemory();
      addTearDown(missing.close);
      missing.execute(
        'create table translated_page(cache_key text primary key, regions text);',
      );
      TranslationStore.migrateSchema(missing);
      final cols2 = missing
          .select('PRAGMA table_info(translated_page);')
          .map((r) => r['name'] as String)
          .toSet();
      expect(cols2, contains('time'));
    });
  });

  group('TranslationStore mergeFrom', skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable', () {
    late Directory directory;
    late TranslationStore store;

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('translation-merge-');
      App.dataPath = directory.path;
      store = _openStore(directory);
      await store.init();
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    String writeForeign({
      required List<(String, String, int)> pages,
      List<Map<String, Object?>> index = const [],
    }) {
      final foreignPath = '${directory.path}/foreign.db';
      final foreign = sqlite3.open(foreignPath);
      foreign.execute(
        'create table translated_page(cache_key text primary key, regions text, time int);',
      );
      foreign.execute(
        'create table translated_chapter_index(scope_prefix text primary key, source_key text not null, comic_id text not null, chapter_id text not null, source_lang text not null, target_lang text not null, comic_title text not null default \'\', comic_cover text not null default \'\', chapter_title text not null default \'\', page_count int not null default 0, updated_at int not null default 0);',
      );
      for (final (key, regions, time) in pages) {
        foreign.execute(
          'insert into translated_page values(?, ?, ?);',
          [key, regions, time],
        );
      }
      for (final row in index) {
        foreign.execute(
          'insert into translated_chapter_index values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
          [
            row['scope_prefix'],
            row['source_key'],
            row['comic_id'],
            row['chapter_id'],
            row['source_lang'],
            row['target_lang'],
            row['comic_title'],
            row['comic_cover'],
            row['chapter_title'],
            row['page_count'],
            row['updated_at'],
          ],
        );
      }
      foreign.close();
      return foreignPath;
    }

    test('merges foreign rows and keeps local rows on conflict', () async {
      const shared = 'pageTranslation@2@ja>zh@local@comic1@ch1@0001';
      store.put(shared, [_region('local')]);
      final foreignPath = writeForeign(
        pages: [
          (shared, '[{"l":1,"t":1,"r":2,"b":2,"text":"foreign","bg":1,"fg":2}]', 5),
          ('pageTranslation@2@ja>zh@local@comic1@ch1@0002', '[]', 6),
        ],
      );
      expect(await store.mergeFrom(foreignPath), 2);
      // Local row wins the conflict.
      expect(store.get(shared)!.single.text, 'local');
      expect(store.get('pageTranslation@2@ja>zh@local@comic1@ch1@0002'), isEmpty);
    });

    test('foreign database without the table merges nothing', () async {
      final foreignPath = '${directory.path}/other.db';
      final foreign = sqlite3.open(foreignPath);
      foreign.execute('create table other(x);');
      foreign.close();
      expect(await store.mergeFrom(foreignPath), 0);
    });

    test('merge without init throws', () async {
      final fresh = TranslationStore.create();
      addTearDown(fresh.dispose);
      await expectLater(fresh.mergeFrom('nowhere.db'), throwsStateError);
    });
  });
}
