import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/sync/data_sync_upload_journal.dart';

import '../../support/directory_alias.dart';

const _id = '4a112222-3333-4444-8555-666666666666';
const _journalName = '.data-sync-upload.sqlite';

void main() {
  late Directory root;
  late String physicalRoot;
  late List<Link> aliases;
  setUp(() {
    root = Directory.systemTemp.createTempSync('upload-journal-path-');
    physicalRoot = root.resolveSymbolicLinksSync();
    aliases = [];
  });
  tearDown(() async {
    // Remove aliases themselves before recursively cleaning the owned fixture.
    for (final alias in aliases.reversed) {
      if (await FileSystemEntity.type(alias.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await alias.delete();
      }
    }
    expect(root.resolveSymbolicLinksSync(), physicalRoot);
    expect(
      p.isWithin(Directory.systemTemp.resolveSymbolicLinksSync(), physicalRoot),
      isTrue,
    );
    await root.delete(recursive: true);
  });

  Future<Link> alias(String path, Directory target) async {
    final link = await createDirectoryAlias(path, target.path);
    aliases.add(link);
    return link;
  }

  DataSyncUploadJournal open(String path) {
    final journal = DataSyncUploadJournal.open(path);
    addTearDown(journal.close);
    return journal;
  }

  DataSyncUploadRecord record({bool sourceOwned = false}) =>
      DataSyncUploadRecord(
        operationId: _id,
        endpointFingerprint: dataSyncEndpointFingerprint([
          'https://example.invalid',
          'user',
          'password',
        ]),
        sourceOwned: sourceOwned,
      );

  test('ancestor alias opens the same physical journal and receipts', () async {
    final target = Directory(p.join(root.path, 'private'))..createSync();
    final link = await alias(p.join(root.path, 'data-data'), target);
    final requested = Directory(p.join(link.path, 'package', 'files'))
      ..createSync(recursive: true);
    final physical = p.normalize(requested.resolveSymbolicLinksSync());
    expect(
      FileSystemEntity.typeSync(requested.path, followLinks: false),
      FileSystemEntityType.directory,
    );
    expect(p.equals(requested.path, physical), isFalse);

    final original = record();
    final journal = open(requested.path)..save(original);
    expect(journal.dataPath, physical);
    journal.close();

    final reopened = open(physical);
    expect(reopened.lookup(_id)!.toJson(), original.toJson());
    expect(reopened.operationDirectory(_id).parent.path, physical);
    expect(File(p.join(requested.path, _journalName)).existsSync(), isTrue);
    expect(File(p.join(physical, _journalName)).existsSync(), isTrue);
  });

  test('a trusted data-root alias is resolved before child checks', () async {
    final target = Directory(p.join(root.path, 'private'))..createSync();
    final link = await alias(p.join(root.path, 'app-files'), target);
    final journal = open(link.path);
    expect(journal.dataPath, p.normalize(target.resolveSymbolicLinksSync()));
    expect(journal.records, isEmpty);
  });

  test(
    'an open journal stays pinned if its root alias is retargeted',
    () async {
      final first = Directory(p.join(root.path, 'first'))..createSync();
      final second = Directory(p.join(root.path, 'second'))..createSync();
      final link = await alias(p.join(root.path, 'app-files'), first);
      final journal = open(link.path)..save(record(sourceOwned: true));
      journal.operationDirectory(_id).createSync();
      journal.snapshotFile(_id).writeAsStringSync('retained snapshot');

      await link.delete();
      aliases.remove(link);
      await alias(link.path, second);

      expect(journal.dataPath, p.normalize(first.resolveSymbolicLinksSync()));
      expect(journal.snapshotFile(_id).readAsStringSync(), 'retained snapshot');
      await journal.cleanup(_id);
      expect(second.listSync(), isEmpty);
      expect(journal.lookup(_id)!.sourceOwned, isTrue);
    },
  );

  for (final suffix in ['', '-journal', '-wal', '-shm']) {
    test(
      'journal child alias is rejected before SQLite opens: $suffix',
      () async {
        final data = Directory(p.join(root.path, 'data'))..createSync();
        final outside = Directory(p.join(root.path, 'outside'))..createSync();
        final sentinel = File(p.join(outside.path, 'preserve'))
          ..writeAsStringSync('foreign evidence');
        await alias(p.join(data.path, '$_journalName$suffix'), outside);

        expect(
          () => DataSyncUploadJournal.open(data.path),
          throwsFormatException,
        );
        expect(sentinel.readAsStringSync(), 'foreign evidence');
        expect(outside.listSync(), hasLength(1));
        if (suffix.isNotEmpty) {
          expect(File(p.join(data.path, _journalName)).existsSync(), isFalse);
        }
      },
    );
  }

  for (final entry in ['operation', 'snapshot', 'staging', 'nested staging']) {
    test(
      'owned upload rejects internal aliases during cleanup: $entry',
      () async {
        final journal = open(p.join(root.path, 'data'));
        journal.save(record(sourceOwned: true));
        final outside = Directory(p.join(root.path, 'outside'))..createSync();
        final sentinel = File(p.join(outside.path, 'snapshot.venera'))
          ..writeAsStringSync('foreign snapshot');
        final directory = journal.operationDirectory(_id);
        if (entry == 'operation') {
          await alias(directory.path, outside);
        } else {
          directory.createSync();
          if (entry == 'snapshot') {
            await alias(journal.snapshotFile(_id).path, outside);
          } else {
            journal.snapshotFile(_id).writeAsStringSync('owned snapshot');
            final staging = Directory(p.join(directory.path, 'export-staging'));
            if (entry == 'staging') {
              await alias(staging.path, outside);
            } else {
              staging.createSync();
              await alias(p.join(staging.path, 'sources'), outside);
            }
          }
        }

        if (entry == 'operation' || entry == 'snapshot') {
          expect(() => journal.snapshotFile(_id), throwsFormatException);
        }
        await expectLater(journal.cleanup(_id), throwsFormatException);
        expect(sentinel.readAsStringSync(), 'foreign snapshot');
        expect(
          journal.lookup(_id)!.toJson(),
          record(sourceOwned: true).toJson(),
        );
        if (entry == 'staging' || entry == 'nested staging') {
          expect(
            journal.snapshotFile(_id).readAsStringSync(),
            'owned snapshot',
          );
        }
      },
    );
  }
}
