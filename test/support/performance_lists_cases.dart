import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_unified/features/comic_source/models.dart';
import 'package:venera_unified/features/history/history.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/comic_type.dart';

// Ported from venera-prime test/support/performance_lists_cases.dart (T4 pilot).
// Unified adaptations:
// - HistoryManager has no `cache` setter and no `batchDeleteHistories`: the
//   cases use a locally owned manager (App.dataPath pointed at a temp dir,
//   same pattern as test/features/history/history_manager_test.dart) and only
//   the individual-remove mode. The batch-vs-individual comparison is gone
//   until unified gains a batch delete API.
// - HistoryManager.remove is async (isolate-backed queue): each remove is
//   awaited and the assertions drain on waitForAsyncWrites().

/// Runs only against a newly created temporary directory. Do not initialize
/// the app or import the user's database before calling this benchmark.
void registerListPerformanceTests({bool device = false}) {
  void register(
    String name,
    Future<void> Function() body, {
    required Timeout timeout,
  }) {
    if (device) {
      testWidgets(name, (tester) async {
        await tester.runAsync(body);
      }, timeout: timeout);
    } else {
      test(name, body, timeout: timeout);
    }
  }

  register(
    'temporary SQLite: individual history deletion and All-filter lookup cost',
    () async {
      const total = 3000;
      const deleteCount = 300;
      const type = ComicType(123);
      final directory = await Directory.systemTemp.createTemp(
        'venera-list-performance-',
      );
      String? previousDataPath;
      String? previousCachePath;
      try {
        previousDataPath = App.dataPath;
        previousCachePath = App.cachePath;
      } catch (_) {
        // A standalone integration-test entrypoint has no app paths yet.
      }
      final manager = HistoryManager.create();
      Database? seedDatabase;
      void Function()? refreshListener;
      addTearDown(() async {
        if (refreshListener != null) manager.removeListener(refreshListener);
        await manager.waitForAsyncWrites();
        manager.close();
        manager.dispose();
        seedDatabase?.close();
        if (previousDataPath != null) App.dataPath = previousDataPath;
        if (previousCachePath != null) App.cachePath = previousCachePath;
        await directory.delete(recursive: true);
      });
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      await manager.init();
      final db = seedDatabase = sqlite3.open('${directory.path}/history.db');

      void seed() {
        db.execute('BEGIN');
        try {
          db.execute('DELETE FROM history');
          final statement = db.prepare('''
          INSERT INTO history
            (id,type,title,subtitle,cover,time,ep,page,readEpisode,max_page)
          VALUES (?,123,?,'Author','',0,1,1,'1',100)
        ''');
          try {
            for (var i = 0; i < total; i++) {
              statement.execute(['$i', 'Comic $i']);
            }
          } finally {
            statement.close();
          }
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
        manager.updateCache();
        expect(manager.length, total);
      }

      var refreshes = 0;
      refreshListener = () {
        refreshes++;
        // Match the HistoryPage listener's full-list read. This intentionally
        // excludes widget layout and therefore is not a frame-time measurement.
        manager.getAll();
      };
      manager.addListener(refreshListener);
      final selected = List.generate(deleteCount, (i) => ComicID(type, '$i'));
      for (var round = 0; round < 3; round++) {
        seed();
        refreshes = 0;
        final stopwatch = Stopwatch()..start();
        for (final comic in selected) {
          await manager.remove(comic.id, comic.type);
        }
        await manager.waitForAsyncWrites();
        stopwatch.stop();
        expect(refreshes, deleteCount);
        expect(manager.length, total - deleteCount);
        for (final comic in selected) {
          expect(manager.find(comic.id, comic.type), isNull);
        }
        expect(manager.find('$deleteCount', type), isNotNull);
        expect(manager.find('${total - 1}', type), isNotNull);
        print(
          'LIST_PERFORMANCE_SAMPLE ${jsonEncode({'operation': 'history_delete', 'mode': 'individual', 'round': round, 'total': total, 'deleted': deleteCount, 'elapsed_us': stopwatch.elapsedMicroseconds, 'list_refreshes': refreshes, 'remaining': manager.length})}',
        );
      }

      seed();
      for (var round = 0; round < 3; round++) {
        var found = 0;
        final stopwatch = Stopwatch()..start();
        for (var i = 0; i < total; i++) {
          if (manager.find('$i', type) != null) found++;
        }
        stopwatch.stop();
        expect(found, total);
        print(
          'LIST_PERFORMANCE_SAMPLE ${jsonEncode({'operation': 'all_favorites_removed_history_lookups', 'round': round, 'lookups': total, 'elapsed_us': stopwatch.elapsedMicroseconds})}',
        );
      }
      // Never assert wall-clock thresholds: scheduler, storage and device load
      // affect time. Exact refresh counts and persisted results are asserted.
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
