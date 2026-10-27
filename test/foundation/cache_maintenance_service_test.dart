import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/cache_maintenance_service.dart';

void main() {
  test('retention honors the fixed allowlist with a 7-day fallback', () {
    for (final days in [0, 1, 3, 7, 30]) {
      expect(normalizeCacheRetentionDays(days), days);
    }
    expect(normalizeCacheRetentionDays(5), 7);
    expect(normalizeCacheRetentionDays(-1), 7);
    expect(normalizeCacheRetentionDays('7'), 7);
    expect(normalizeCacheRetentionDays(null), 7);
    expect(normalizeCacheRetentionDays(double.nan), 7);
  });

  test('startup clean runs once per calendar day, manual always runs',
      () async {
    final settings = appdata.settings;
    final previous = settings['cacheRetentionDays'];
    addTearDown(() => settings['cacheRetentionDays'] = previous);
    settings['cacheRetentionDays'] = 7;
    final implicit = <String, dynamic>{};
    var runs = 0;
    var persists = 0;
    final applied = <int>[];
    final service = CacheMaintenanceService(
      settings: settings,
      applyRetention: applied.add,
      runCleanup: () async => runs++,
      implicitData: implicit,
      persist: () => persists++,
    );
    addTearDown(service.stop);

    await service.clean(reason: 'startup');
    expect(runs, 1);
    expect(persists, 1);
    // clean() and _run() each apply retention, like prime; idempotent.
    expect(applied, [7, 7]);
    final record = implicit['cacheMaintenance'] as Map;
    expect(record['retentionDays'], 7);
    expect(record['finishedAt'], isA<int>());

    await service.clean(reason: 'startup');
    await service.clean(reason: 'periodic');
    expect(runs, 1);
    expect(persists, 1);
    // Gated cleans still re-apply retention without running cleanup.
    expect(applied, [7, 7, 7, 7]);

    await service.clean();
    expect(runs, 2);
    expect(persists, 2);
    expect(applied, [7, 7, 7, 7, 7, 7]);
  });

  test('retention change re-arms the daily gate', () async {
    final settings = appdata.settings;
    final previous = settings['cacheRetentionDays'];
    addTearDown(() => settings['cacheRetentionDays'] = previous);
    settings['cacheRetentionDays'] = 7;
    final implicit = <String, dynamic>{};
    var runs = 0;
    final service = CacheMaintenanceService(
      settings: settings,
      applyRetention: (_) {},
      runCleanup: () async => runs++,
      implicitData: implicit,
      persist: () {},
    );
    addTearDown(service.stop);

    await service.clean(reason: 'startup');
    expect(runs, 1);
    settings['cacheRetentionDays'] = 3;
    await service.clean(reason: 'startup');
    expect(runs, 2);
    expect(
      (implicit['cacheMaintenance'] as Map)['retentionDays'],
      3,
    );
  });

  test('yesterday record is due again today', () async {
    final settings = appdata.settings;
    final previous = settings['cacheRetentionDays'];
    addTearDown(() => settings['cacheRetentionDays'] = previous);
    settings['cacheRetentionDays'] = 7;
    final now = DateTime(2026, 10, 27, 12);
    final implicit = <String, dynamic>{
      'cacheMaintenance': {
        'finishedAt': DateTime(2026, 10, 26, 23).millisecondsSinceEpoch,
        'retentionDays': 7,
      },
    };
    var runs = 0;
    final service = CacheMaintenanceService(
      settings: settings,
      applyRetention: (_) {},
      runCleanup: () async => runs++,
      implicitData: implicit,
      persist: () {},
      now: () => now,
    );
    addTearDown(service.stop);

    await service.clean(reason: 'periodic');
    expect(runs, 1);
  });

  test('start applies retention and stop detaches the listener', () async {
    final settings = appdata.settings;
    final previous = settings['cacheRetentionDays'];
    addTearDown(() => settings['cacheRetentionDays'] = previous);
    settings['cacheRetentionDays'] = 7;
    final applied = <int>[];
    final service = CacheMaintenanceService(
      settings: settings,
      applyRetention: applied.add,
      runCleanup: () async {},
      implicitData: <String, dynamic>{
        'cacheMaintenance': {
          'finishedAt': DateTime.now().millisecondsSinceEpoch,
          'retentionDays': 7,
        },
      },
      persist: () {},
    );

    service.start();
    service.start();
    // start() applies once; the scheduled startup gate applies again.
    expect(applied, [7, 7]);
    settings['cacheRetentionDays'] = 30;
    await Future<void>.delayed(Duration.zero);
    // Listener, scheduled clean, and its run each apply retention.
    expect(applied, [7, 7, 30, 30, 30]);
    service.stop();
    service.stop();
    settings['cacheRetentionDays'] = 1;
    await Future<void>.delayed(Duration.zero);
    expect(applied, [7, 7, 30, 30, 30]);
  });

  test('concurrent cleans share one run and settings rerun it', () async {
    final settings = appdata.settings;
    final previous = settings['cacheRetentionDays'];
    addTearDown(() => settings['cacheRetentionDays'] = previous);
    settings['cacheRetentionDays'] = 7;
    var runs = 0;
    final gate = Completer<void>();
    final service = CacheMaintenanceService(
      settings: settings,
      applyRetention: (_) {},
      runCleanup: () async {
        runs++;
        await gate.future;
      },
      implicitData: <String, dynamic>{},
      persist: () {},
    );
    addTearDown(service.stop);

    service.start();
    final first = service.clean();
    final second = service.clean();
    // The listener path is covered separately; rerun directly here.
    settings['cacheRetentionDays'] = 3;
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([first, second]);
    // Single flight plus one rerun triggered by the settings change.
    expect(runs, 2);
  });
}
