import 'package:venera_unified/features/local_comics/local_comic_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_unified/features/local_comics/local_repository.dart';
import 'package:venera_unified/features/local_comics/local_sort_type.dart';
import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/foundation/comic_type.dart';

void main() {
  test('legacy schema upgrades without changing complete records', () {
    final db = sqlite3.openInMemory();
    try {
      db.execute(
        'CREATE TABLE comics (id TEXT, title TEXT, subtitle TEXT, tags TEXT, directory TEXT, chapters TEXT, cover TEXT, comic_type INT, downloadedChapters TEXT, created_at INT, PRIMARY KEY(id, comic_type))',
      );
      db.execute(
        "INSERT INTO comics VALUES ('1', 'Old', '', '[]', 'book', 'null', '', 17, '[]', 0)",
      );
      final repository = LocalRepository(db)..initialize();
      repository.initialize();
      expect(repository.find('1', const ComicType(17))!.isIncomplete, isFalse);
      expect(
        db
            .select('PRAGMA table_info(comics)')
            .where((row) => row['name'] == 'incomplete_pages'),
        hasLength(1),
      );
    } finally {
      db.close();
    }
  });

  test(
    'chapter updates preserve other missing pages and clear only repaired chapters',
    () {
      final db = sqlite3.openInMemory();
      final repository = LocalRepository(db)..initialize();
      LocalComic comic(
        List<String> chapters,
        Map<String, IncompleteChapter> missing,
      ) => LocalComic(
        id: '1',
        title: 'Book',
        subtitle: '',
        tags: [],
        directory: 'book',
        chapters: const ComicChapters({'a': 'A', 'b': 'B'}),
        cover: 'cover.jpg',
        comicType: const ComicType(17),
        downloadedChapters: chapters,
        createdAt: DateTime(2026),
        incompleteChapters: missing,
      );
      try {
        repository.add(
          comic(
            ['a'],
            {
              'a': IncompleteChapter(pageCount: 3, missing: [2, 0, 2]),
            },
          ),
        );
        repository.add(
          comic(
            ['b'],
            {
              'b': IncompleteChapter(pageCount: 2, missing: [1]),
            },
          ),
        );
        var saved = repository.find('1', const ComicType(17))!;
        expect(saved.missingImageCount, 3);
        expect(saved.incompleteChapters['a']!.missing, [0, 2]);
        repository.add(comic(['a'], {}));
        saved = repository.find('1', const ComicType(17))!;
        expect(saved.incompleteChapters.keys, ['b']);
        repository.removeChapters('1', const ComicType(17), ['b']);
        expect(
          repository.find('1', const ComicType(17))!.isIncomplete,
          isFalse,
        );
        expect(
          () => IncompleteChapter(pageCount: 2, missing: [2]),
          throwsFormatException,
        );
      } finally {
        db.close();
      }
    },
  );

  test(
    'directory references exclude exact identity without decoding other metadata',
    () {
      final db = sqlite3.openInMemory();
      final repository = LocalRepository(db)..initialize();
      try {
        for (final type in [1, 2]) {
          db.execute(
            '''INSERT INTO comics
          (id,title,subtitle,tags,directory,chapters,cover,comic_type,downloadedChapters,created_at)
          VALUES (?,?,?,?,?,?,?,?,?,?)''',
            [
              'same',
              '',
              '',
              'invalid json',
              'directory-$type',
              'invalid json',
              '',
              type,
              'invalid json',
              0,
            ],
          );
        }
        expect(
          repository.directoryReferences(),
          unorderedEquals(['directory-1', 'directory-2']),
        );
        expect(
          repository.directoryReferences(
            excluding: ('same', const ComicType(1)),
          ),
          ['directory-2'],
        );
        expect(
          repository.directoryReferences(
            excluding: ("' OR 1=1 --", const ComicType(1)),
          ),
          hasLength(2),
        );
        expect(
          repository.directoryReferences(
            excludingMany: [
              ('same', const ComicType(1)),
              ('same', const ComicType(1)),
              ('missing', const ComicType(2)),
            ],
          ),
          ['directory-2'],
        );
        expect(
          repository.directoryReferences(
            excluding: ('same', const ComicType(1)),
            excludingMany: [('same', const ComicType(2))],
          ),
          isEmpty,
        );
      } finally {
        db.close();
      }
    },
  );
  test(
    'page mappings preserve first writer, null markers and source identity',
    () {
      final db = sqlite3.openInMemory();
      final repository = LocalRepository(db)..initialize();
      try {
        expect(repository.findPageMigration('1', ComicType.local), isNull);
        repository.recordPageMigration(
          '1',
          ComicType.local,
          const LocalPageMigration(10, 2, 3),
        );
        final kept = repository.recordPageMigration(
          '1',
          ComicType.local,
          const LocalPageMigration(20, 3, 2),
        );
        expect([kept.historyTime, kept.oldPage, kept.newPage], [10, 2, 3]);
        repository.recordPageMigration(
          '1',
          const ComicType(17),
          const LocalPageMigration(null, null, null),
        );
        final marker = repository.recordPageMigration(
          '1',
          const ComicType(17),
          const LocalPageMigration(10, 2, 3),
        );
        expect(marker.historyTime, isNull);
        expect(marker.newPage, isNull);
        db.execute(
          "CREATE TRIGGER reject_mapping BEFORE INSERT ON natural_sort_migration BEGIN SELECT RAISE(ABORT, 'injected'); END;",
        );
        expect(
          () => repository.recordPageMigration(
            '2',
            ComicType.local,
            const LocalPageMigration(10, 2, 3),
          ),
          throwsA(isA<SqliteException>()),
        );
        expect(repository.findPageMigration('2', ComicType.local), isNull);
        db.execute('DROP TRIGGER reject_mapping;');
        expect(
          repository
              .recordPageMigration(
                '2',
                ComicType.local,
                const LocalPageMigration(10, 2, 3),
              )
              .newPage,
          3,
        );
      } finally {
        db.close();
      }
    },
  );

  test('writes and migration markers commit together without mutating chapters', () {
    final db = sqlite3.openInMemory();
    final repository = LocalRepository(db)..initialize();
    LocalComic comic(String id, List<String> chapters) => LocalComic(
      id: id,
      title: 'Title',
      subtitle: '',
      tags: [],
      directory: 'folder',
      chapters: null,
      cover: '',
      comicType: const ComicType(17),
      downloadedChapters: chapters,
      createdAt: DateTime(2026),
    );
    try {
      repository.initialize();
      db.execute(
        "CREATE TRIGGER reject_insert BEFORE INSERT ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(
        () => repository.add(comic('1', const ['new'])),
        throwsA(isA<SqliteException>()),
      );
      expect(db.select('SELECT * FROM natural_sort_migration;'), isEmpty);
      expect(repository.count, 0);
      db.execute('DROP TRIGGER reject_insert;');
      repository.add(comic('ignored', const ['old']), '1');
      // Ids are never reused: a fresh id is a timestamp above every stored id.
      final nextId = int.parse(repository.findValidId(const ComicType(17)));
      expect(nextId, greaterThan(1));
      expect(nextId, greaterThanOrEqualTo(1700000000000));
      // A type holding no comics never gets a bare, reusable id either.
      final emptyTypeId = int.parse(
        repository.findValidId(const ComicType(18)),
      );
      expect(emptyTypeId, greaterThanOrEqualTo(1700000000000));
      final updated = comic('1', const ['new', 'old']);
      repository.add(updated);
      expect(updated.downloadedChapters, ['new', 'old']);
      expect(repository.find('1', const ComicType(17))!.downloadedChapters, [
        'new',
        'old',
        'old',
      ]);
      db.execute(
        "UPDATE natural_sort_migration SET history_time = 99, old_page = 4, new_page = 2;",
      );
      repository.add(comic('1', const []));
      expect(
        db
            .select('SELECT history_time FROM natural_sort_migration;')
            .single['history_time'],
        99,
      );
      db.execute(
        "CREATE TRIGGER reject_delete BEFORE DELETE ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(
        () => repository.remove('1', const ComicType(17)),
        throwsA(isA<SqliteException>()),
      );
      expect(repository.count, 1);
      expect(
        db
            .select('SELECT history_time FROM natural_sort_migration;')
            .single['history_time'],
        99,
      );
      db.execute('DROP TRIGGER reject_delete;');
      repository.remove('1', const ComicType(17));
      expect(repository.count, 0);
      expect(db.select('SELECT * FROM natural_sort_migration;'), isEmpty);
    } finally {
      db.close();
    }
  });

  test(
    'local queries retain source identity, sort rules, limits and bound search',
    () {
      final db = sqlite3.openInMemory();
      final repository = LocalRepository(db);
      try {
        db.execute(
          'CREATE TABLE comics (id TEXT, title TEXT, subtitle TEXT, tags TEXT, directory TEXT, chapters TEXT, cover TEXT, comic_type INT, downloadedChapters TEXT, created_at INT, PRIMARY KEY(id, comic_type));',
        );
        for (var i = 0; i < 25; i++) {
          db.execute(
            'INSERT INTO comics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
            [
              'shared',
              'Title ${i.toString().padLeft(2, '0')}',
              'Author',
              '["Tag"]',
              'directory-$i',
              'null',
              '',
              i,
              '[]',
              i,
            ],
          );
        }
        expect(repository.count, 25);
        expect(
          repository.find('shared', const ComicType(12))!.directory,
          'directory-12',
        );
        expect(repository.find('missing', const ComicType(12)), isNull);
        expect(repository.findByName('directory-12')!.comicType.value, 12);
        expect(repository.findByName('Title 12')!.comicType.value, 12);
        expect(repository.findByName("' OR 1=1 --"), isNull);
        expect(
          repository.getComics(LocalSortType.timeAsc).first.comicType.value,
          0,
        );
        expect(
          repository.getComics(LocalSortType.timeDesc).first.comicType.value,
          24,
        );
        // Existing name sorting is descending, even though the UI name is neutral.
        expect(
          repository.getComics(LocalSortType.name).first.title,
          'Title 24',
        );
        expect(repository.getRecent(), hasLength(20));
        expect(repository.getRecent().last.comicType.value, 5);
        for (final query in ['Author', 'tag', '%', '']) {
          expect(repository.search(query), hasLength(25));
          expect(repository.search(query).first.comicType.value, 24);
        }
        expect(repository.search("' OR 1=1 --"), isEmpty);
        expect(LocalSortType.fromString('unknown'), LocalSortType.name);
      } finally {
        db.close();
      }
    },
  );

  test('a deleted id is never handed out again', () {
    final db = sqlite3.openInMemory();
    final repository = LocalRepository(db)..initialize();
    LocalComic comic(String id, String title) => LocalComic(
      id: id,
      title: title,
      subtitle: '',
      tags: const [],
      directory: 'folder',
      chapters: null,
      cover: '',
      comicType: ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime(2026),
    );
    try {
      final first = repository.findValidId(ComicType.local);
      repository.add(comic(first, 'First'));
      repository.remove(first, ComicType.local);
      // History and favorites are keyed by id and may outlive the comic
      // (restored archives, other devices), so the freed id stays retired.
      final second = repository.findValidId(ComicType.local);
      expect(second, isNot(first));
      expect(int.parse(second), greaterThanOrEqualTo(1700000000000));
      repository.add(comic(second, 'Second'));
      expect(repository.find(second, ComicType.local)!.title, 'Second');
    } finally {
      db.close();
    }
  });

  // Importers such as document_import allocate an id when the model is built
  // and insert later, so two allocations may land in the same millisecond.
  // Upstream VeneraX 47f3b7dd still returns that one timestamp twice and the
  // second INSERT OR REPLACE then silently swallows the first comic; the local
  // high-water mark deliberately deviates from upstream to keep them apart.
  test('consecutive allocations without an insert stay distinct', () {
    final db = sqlite3.openInMemory();
    final repository = LocalRepository(db)..initialize();
    try {
      final first = repository.findValidId(ComicType.local);
      final second = repository.findValidId(ComicType.local);
      final third = repository.findValidId(const ComicType(17));
      expect(second, isNot(first));
      expect(third, isNot(anyOf(first, second)));
      expect(int.parse(second), greaterThan(int.parse(first)));
      expect(int.parse(third), greaterThan(int.parse(second)));
    } finally {
      db.close();
    }
  });
}
