import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_unified/app_runtime/core_bootstrap.dart';
import 'package:venera_unified/foundation/log.dart';

void main() {
  const phases = [
    'environment',
    'settings',
    'infrastructure',
    'sources',
    'stores',
    'finish',
  ];
  for (final failingPhase in phases) {
    test('reports $failingPhase before cleanup and only once', () async {
      final events = <String>[];
      final cause = StateError('failed phase');
      Future<void> step(String phase) async {
        events.add(phase);
        if (phase == failingPhase) throw cause;
      }

      final core = CoreBootstrap(
        environment: () => step('environment'),
        settings: () => step('settings'),
        infrastructure: () => step('infrastructure'),
        sources: () => step('sources'),
        stores: () => step('stores'),
        finish: () => step('finish'),
        onStartupFailure: (phase, error, stack) {
          expect(phase, failingPhase);
          expect(error, same(cause));
          events.add('reported');
        },
        failureCleanup: [(name: 'resource', close: () => events.add('closed'))],
        releaseOwnership: () => events.add('released'),
      );
      await expectLater(core.start(), throwsA(same(cause)));
      expect(events, [
        ...phases.take(phases.indexOf(failingPhase) + 1),
        'reported',
        'closed',
        'released',
      ]);
      await expectLater(core.start(), throwsA(same(cause)));
      await core.close();
      expect(events.where((event) => event == 'reported'), hasLength(1));
    });
  }

  test(
    'reporter failures cannot prevent rollback or replace the cause',
    () async {
      final cause = StateError('startup');
      var closed = false;
      final core = CoreBootstrap(
        environment: () async => throw cause,
        settings: () async {},
        infrastructure: () async {},
        sources: () async {},
        stores: () async {},
        finish: () async {},
        onStartupFailure: (_, _, _) => throw StateError('diagnostic'),
        failureCleanup: [(name: 'resource', close: () => closed = true)],
      );
      await expectLater(core.start(), throwsA(same(cause)));
      expect(closed, isTrue);
      await core.close();
    },
  );

  test(
    'SQLite startup cause reaches disk before the log session closes',
    () async {
      final root = Directory(
        'build',
      ).absolute.createTempSync('startup-diagnostic-');
      final buildRoot = Directory('build').resolveSymbolicLinksSync();
      final databasePath = '${root.path}/readonly.db';
      final seed = sqlite3.open(databasePath);
      seed.execute('CREATE TABLE existing (id INTEGER)');
      seed.close();
      final muted = Log.isMuted;
      Log.isMuted = false;
      Log.clear();
      final cleanup = <CoreStartupCleanup>[];
      final core = CoreBootstrap(
        environment: () async {},
        settings: () async {
          final close = await Log.startFileSession(
            File('${root.path}/logs.txt'),
          );
          cleanup.add((name: 'logs', close: close));
        },
        infrastructure: () async {
          final db = sqlite3.open(databasePath, mode: OpenMode.readOnly);
          try {
            db.execute('CREATE TABLE new_table (id INTEGER)');
          } finally {
            db.close();
          }
        },
        sources: () async => fail('sources must not start'),
        stores: () async => fail('stores must not start'),
        finish: () async => fail('finish must not start'),
        onStartupFailure: (phase, error, stack) =>
            Log.error('Startup', '$phase failed: $error', stack),
        failureCleanup: cleanup,
      );
      try {
        await expectLater(core.start(), throwsA(isA<SqliteException>()));
        final text = await File('${root.path}/logs.txt').readAsString();
        expect(text, contains('infrastructure failed'));
        expect(text, contains('attempt to write a readonly database'));
        expect(text, contains('core_startup_diagnostics_test.dart'));
        expect(Log.filePath, isNull);
      } finally {
        await core.close();
        Log.clear();
        Log.isMuted = muted;
        expect(
          root.resolveSymbolicLinksSync(),
          startsWith('$buildRoot${Platform.pathSeparator}'),
        );
        root.deleteSync(recursive: true);
      }
    },
  );
}
