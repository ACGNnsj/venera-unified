import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_unified/features/sync/app_data_archive.dart';

import '../../support/zip_fixture.dart';

void _createSource(Directory source) {
  for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
    final db = sqlite3.open('${source.path}/$name');
    try {
      db.execute('CREATE TABLE content (value TEXT);');
      db.execute('INSERT INTO content VALUES (?);', [name]);
    } finally {
      db.close();
    }
  }
  Directory('${source.path}/comic_source').createSync();
  File('${source.path}/comic_source/source.js').writeAsStringSync('// source');
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('app-data-archive-'));
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'archive service round trips explicit paths without app globals',
    () async {
      final source = Directory('${root.path}/source')..createSync();
      final cache = Directory('${root.path}/cache')..createSync();
      final output = '${root.path}/backup.venera';
      _createSource(source);
      await AppDataArchive.create(
        dataPath: source.path,
        cachePath: cache.path,
        destinationPath: output,
        settingsJson: '{"settings":{"language":"en-US"}}',
      );
      expect(cache.listSync(), isEmpty);
      final extracted = '${root.path}/extracted';
      await AppDataArchive.extract(output, extracted);
      expect(jsonDecode(File('$extracted/appdata.json').readAsStringSync()), {
        'settings': {'language': 'en-US'},
      });
      expect(
        File('$extracted/comic_source/source.js').readAsStringSync(),
        '// source',
      );
      final db = sqlite3.open('$extracted/history.db');
      try {
        expect(
          db.select('SELECT value FROM content;').single['value'],
          'history.db',
        );
      } finally {
        db.close();
      }
    },
  );

  test('zip_flutter failure falls back to ordered stream output', () async {
    final source = Directory('${root.path}/source')..createSync();
    final cache = Directory('${root.path}/cache')..createSync();
    final output = '${root.path}/backup.venera';
    _createSource(source);

    await AppDataArchive.create(
      dataPath: source.path,
      cachePath: cache.path,
      destinationPath: output,
      settingsJson: '{"settings":{"language":"en-US"}}',
      debugZipFlutterFailure: true,
    );

    final archive = ZipDecoder().decodeBytes(File(output).readAsBytesSync());
    expect(archive.map((entry) => entry.name).toList(), [
      'history.db',
      'local_favorite.db',
      'cookie.db',
      'appdata.json',
      'comic_source/source.js',
    ]);
    expect(
      utf8.decode(
        archive.firstWhere((entry) => entry.name == 'appdata.json').content,
      ),
      '{"settings":{"language":"en-US"}}',
    );
    expect(
      utf8.decode(
        archive
            .firstWhere((entry) => entry.name == 'comic_source/source.js')
            .content,
      ),
      '// source',
    );
    expect(cache.listSync(), isEmpty);
    final extracted = '${root.path}/fallback-extracted';
    await AppDataArchive.extract(output, extracted);
    for (final name in ['history.db', 'local_favorite.db', 'cookie.db']) {
      final db = sqlite3.open('$extracted/$name');
      try {
        expect(db.select('SELECT value FROM content;').single['value'], name);
      } finally {
        db.close();
      }
    }
  });

  test('stream writer failure removes archive and staging output', () async {
    final source = Directory('${root.path}/source')..createSync();
    final cache = Directory('${root.path}/cache')..createSync();
    final staging = '${root.path}/staging';
    final output = '${root.path}/backup.venera';
    _createSource(source);

    await expectLater(
      AppDataArchive.create(
        dataPath: source.path,
        cachePath: cache.path,
        destinationPath: output,
        settingsJson: '{}',
        stagingDirectoryPath: staging,
        debugZipFlutterFailure: true,
        debugFailAfterStreamWrite: true,
      ),
      throwsStateError,
    );

    expect(File(output).existsSync(), isFalse);
    expect(Directory(staging).existsSync(), isFalse);
    expect(cache.listSync(), isEmpty);
  });

  test('creation does not overwrite an existing archive', () async {
    final target = File('${root.path}/existing.venera')
      ..writeAsStringSync('keep');
    await expectLater(
      AppDataArchive.create(
        dataPath: root.path,
        cachePath: root.path,
        destinationPath: target.path,
        settingsJson: '{}',
      ),
      throwsStateError,
    );
    expect(target.readAsStringSync(), 'keep');
    expect(root.listSync(), hasLength(1));
  });

  test('all paths are validated before extraction writes any file', () async {
    final input = File('${root.path}/invalid.picadata');
    final archive = Archive()
      ..addFile(ArchiveFile.string('appdata.json', '{}'))
      ..addFile(ArchiveFile.string('../escape', 'invalid'));
    input.writeAsBytesSync(ZipEncoder().encode(archive));
    await expectLater(
      AppDataArchive.extract(input.path, '${root.path}/extracted'),
      throwsFormatException,
    );
    expect(File('${root.path}/extracted/appdata.json').existsSync(), isFalse);
    expect(File('${root.path}/escape').existsSync(), isFalse);
    input.renameSync('${input.path}.released');
  });

  for (final damage in ZipFixtureDamage.values) {
    test('rejects $damage instead of accepting partial archive data', () async {
      final input = File('${root.path}/damaged.venera')
        ..writeAsBytesSync(
          zipFixture([
            ZipFixtureEntry(utf8.encode('appdata.json'), utf8.encode('{}')),
            ZipFixtureEntry(
              utf8.encode('local_favorite.db'),
              List.filled(4096, 42),
            ),
          ], damage: damage),
        );
      await expectLater(
        AppDataArchive.extract(input.path, '${root.path}/extracted'),
        throwsFormatException,
      );
      input.renameSync('${input.path}.released');
    });
  }

  for (final compress in [false, true]) {
    test(
      'checks the CRC of stored and deflated members; compress=$compress',
      () async {
        final input = File('${root.path}/checksum.picadata')
          ..writeAsBytesSync(
            zipFixture([
              ZipFixtureEntry(
                utf8.encode('data.json'),
                utf8.encode('{}'),
                compress: compress,
              ),
            ], damage: ZipFixtureDamage.checksum),
          );
        await expectLater(
          AppDataArchive.extract(input.path, '${root.path}/extracted'),
          throwsA(isA<ArchiveChecksumException>()),
        );
      },
    );
  }
}
