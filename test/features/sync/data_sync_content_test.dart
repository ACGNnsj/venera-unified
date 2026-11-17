import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_unified/features/sync/app_data_snapshot.dart';
import 'package:venera_unified/features/sync/data_sync_content.dart';
import 'package:venera_unified/features/sync/data_sync_content_fingerprint.dart';
import 'package:venera_unified/features/sync/data_sync_content_journal.dart';

void main() {
  late Directory root;
  const first = '11111111-1111-4111-8111-111111111111';
  const second = '22222222-2222-4222-8222-222222222222';
  final scope = DataSyncContentScope(
    endpoint: 'a' * 64,
    excludedFields: 'language, language',
    archiveSyncEnabled: false,
  );
  String metadata({
    int version = 4,
    String language = 'en-US',
    String theme = 'dark',
  }) => jsonEncode({
    'settings': {
      'dataVersion': version,
      'lastSyncTime': version * 1000,
      'deviceId': '$version',
      'language': language,
      'theme': theme,
    },
    'searchHistory': ['one', 'two'],
  });
  setUp(() {
    root = Directory.systemTemp.createTempSync('sync-content-');
    File('${root.path}/appdata.json').writeAsStringSync(metadata());
    Directory('${root.path}/comic_source').createSync();
    File('${root.path}/comic_source/one.js').writeAsStringSync('source script');
    File(
      '${root.path}/comic_source/one.data',
    ).writeAsStringSync('{"token":"old"}');
    for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
      final db = sqlite3.open('${root.path}/$name');
      db.execute(
        'CREATE TABLE records (id INTEGER PRIMARY KEY, value, payload BLOB)',
      );
      db.execute('INSERT INTO records VALUES (?, ?, ?)', [
        1,
        'first',
        Uint8List.fromList([0, 1, 255]),
      ]);
      db.close();
    }
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<String> capture({String? memory}) =>
      DataSyncContentFingerprint.capture(
        root.path,
        excludedFields: scope.excludedFields,
        memorySettingsJson: memory,
        archiveSyncEnabled: false,
      );

  test(
    'comparison ignores transport fields and filtered values but retains business edits',
    () async {
      final before = await capture();
      File(
        '${root.path}/appdata.json',
      ).writeAsStringSync(metadata(version: 99, language: 'zh-CN'));
      expect(await capture(), before);
      File(
        '${root.path}/appdata.json',
      ).writeAsStringSync(metadata(theme: 'light'));
      expect(await capture(), isNot(before));
    },
  );

  test(
    'object ordering is stable while history order remains significant',
    () async {
      final before = await capture();
      final doc = jsonDecode(metadata()) as Map<String, dynamic>;
      final settings = doc['settings'] as Map<String, dynamic>;
      doc['settings'] = {
        for (final entry in settings.entries.toList().reversed)
          entry.key: entry.value,
      };
      File('${root.path}/appdata.json').writeAsStringSync(jsonEncode(doc));
      expect(await capture(), before);
      doc['searchHistory'] = ['two', 'one'];
      File('${root.path}/appdata.json').writeAsStringSync(jsonEncode(doc));
      expect(await capture(), isNot(before));
    },
  );

  for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
    test(
      'unannounced committed $name writes change content including WAL',
      () async {
        final before = await capture();
        final db = sqlite3.open('${root.path}/$name');
        try {
          db.execute('PRAGMA journal_mode = WAL');
          expect(await capture(), before);
          db.execute("UPDATE records SET value = 'later' WHERE id = 1");
          expect(await capture(), isNot(before));
          final changed = await capture();
          db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
          db.execute('VACUUM');
          expect(await capture(), changed);
        } finally {
          db.close();
        }
      },
    );
  }

  test('source files and unsaved memory are independently visible', () async {
    final before = await capture();
    expect(await capture(memory: metadata()), before);
    expect(await capture(memory: metadata(theme: 'unsaved')), isNot(before));
    File(
      '${root.path}/comic_source/one.data',
    ).writeAsStringSync('{"token":"new"}');
    expect(await capture(), isNot(before));
    File(
      '${root.path}/comic_source/one.data',
    ).writeAsStringSync('{"token":"old"}');
    expect(await capture(), before);
    File('${root.path}/comic_source/one.js').deleteSync();
    expect(await capture(), isNot(before));
  });

  test('staged database backups match live logical content', () async {
    final staging = Directory('${root.path}/staged')..createSync();
    await createAppDataSnapshot(
      root.path,
      staging.path,
      settingsJson: metadata(),
    );
    expect(
      await DataSyncContentFingerprint.capture(
        staging.path,
        excludedFields: scope.excludedFields,
      ),
      await capture(),
    );
  });

  test(
    'user tables with sqlite prefixes and shadowed rowids are included',
    () async {
      final db = sqlite3.open('${root.path}/history.db');
      try {
        db.execute('CREATE TABLE sqliteXuser (ROWID TEXT, value BLOB)');
        db.execute("INSERT INTO sqliteXuser VALUES ('key', X'0102')");
        final before = await capture();
        db.execute("UPDATE sqliteXuser SET value = X'0103'");
        expect(await capture(), isNot(before));
        db.execute(
          'CREATE TABLE keyed (k TEXT PRIMARY KEY, value) WITHOUT ROWID',
        );
        db.execute("INSERT INTO keyed VALUES ('key', 1)");
        final number = await capture();
        db.execute("UPDATE keyed SET value = '1'");
        expect(await capture(), isNot(number));
      } finally {
        db.close();
      }
    },
  );

  test(
    'invalid scope and mismatched snapshot directions never become evidence',
    () async {
      final journal = DataSyncContentJournal.open(root.path);
      try {
        expect(
          () async => journal.begin(
            id: first,
            direction: 'download',
            scope: DataSyncContentScope(
              endpoint: 'invalid',
              excludedFields: '',
              archiveSyncEnabled: false,
            ),
            before: await capture(),
          ),
          throwsFormatException,
        );
        expect(journal.lookup(first), isNull);
        journal.begin(
          id: first,
          direction: 'download',
          scope: scope,
          before: await capture(),
        );
        expect(
          () => journal.recordSnapshot(first, 'a' * 64, archiveHash: 'b' * 64),
          throwsFormatException,
        );
        expect(journal.lookup(first)!.after, isNull);
      } finally {
        journal.close();
      }
    },
  );

  test(
    'invalid metadata or database does not become a clean comparison',
    () async {
      File('${root.path}/appdata.json').writeAsStringSync('{bad');
      await expectLater(capture(), throwsFormatException);
      File('${root.path}/appdata.json').writeAsStringSync(metadata());
      File('${root.path}/cookie.db').writeAsBytesSync(List.filled(4096, 33));
      await expectLater(capture(), throwsA(isA<SqliteException>()));
    },
  );

  test('captured optional archive policy survives filtering its flag', () {
    final enabled = jsonEncode({
      'settings': {
        'backupWebdavSyncEnabled': true,
        'backupWebdav': ['url', 'user', 'password'],
      },
    });
    final filtered = jsonEncode({
      'settings': {
        'backupWebdav': ['url', 'user', 'password'],
      },
    });
    expect(
      DataSyncContentFingerprint.settings(
        enabled,
        'backupWebdavSyncEnabled',
        archiveSyncEnabled: true,
      ),
      DataSyncContentFingerprint.settings(
        filtered,
        'backupWebdavSyncEnabled',
        archiveSyncEnabled: true,
      ),
    );
  });

  test(
    'confirmed baseline survives reopen and candidate acknowledgement',
    () async {
      var journal = DataSyncContentJournal.open(root.path);
      final before = await capture();
      expect(journal.baseline(scope), isNull);
      journal.begin(
        id: first,
        direction: 'upload',
        scope: scope,
        before: before,
      );
      expect(() => journal.confirm(first), throwsStateError);
      journal.recordSnapshot(first, before, archiveHash: 'b' * 64);
      journal.close();
      journal = DataSyncContentJournal.open(root.path);
      expect(journal.baseline(scope), isNull);
      journal.confirm(first);
      journal.acknowledge(first);
      journal.close();
      journal = DataSyncContentJournal.open(root.path);
      expect(journal.baseline(scope), before);
      expect(journal.lookup(first), isNull);
      journal.close();
    },
  );

  test('older receipt cannot regress a later confirmed baseline', () {
    final journal = DataSyncContentJournal.open(root.path);
    try {
      journal.begin(
        id: first,
        direction: 'download',
        scope: scope,
        before: 'a' * 64,
      );
      journal.recordSnapshot(first, 'b' * 64);
      journal.begin(
        id: second,
        direction: 'download',
        scope: scope,
        before: 'a' * 64,
      );
      journal.recordSnapshot(second, 'c' * 64);
      journal.confirm(second);
      journal.confirm(first);
      expect(journal.baseline(scope), 'c' * 64);
      expect(() => journal.recordSnapshot(first, 'd' * 64), throwsStateError);
      expect(
        journal.baseline(
          DataSyncContentScope(
            endpoint: 'd' * 64,
            excludedFields: '',
            archiveSyncEnabled: false,
          ),
        ),
        isNull,
      );
    } finally {
      journal.close();
    }
  });

  test('download guard rejects changes before any replacement', () async {
    final journal = DataSyncContentJournal.open(root.path);
    try {
      final before = await capture();
      journal.begin(
        id: first,
        direction: 'download',
        scope: scope,
        before: before,
      );
      journal.verifyBeforeImport(first, before);
      File('${root.path}/comic_source/one.data').writeAsStringSync('later');
      await expectLater(
        () async => journal.verifyBeforeImport(first, await capture()),
        throwsA(isA<DataSyncContentConflict>()),
      );
      expect(journal.lookup(first)!.after, isNull);
    } finally {
      journal.close();
    }
  });

  test('corrupted candidates are retained rather than acknowledged', () async {
    final journal = DataSyncContentJournal.open(root.path);
    journal.begin(
      id: first,
      direction: 'download',
      scope: scope,
      before: await capture(),
    );
    final db = sqlite3.open('${root.path}/${DataSyncContentJournal.fileName}');
    db.execute("UPDATE content_operations SET digest = 'bad'");
    db.close();
    expect(() => journal.acknowledge(first), throwsFormatException);
    journal.close();
    final reopened = sqlite3.open(
      '${root.path}/${DataSyncContentJournal.fileName}',
    );
    expect(
      reopened.select('SELECT id FROM content_operations').single['id'],
      first,
    );
    reopened.close();
  });
}
