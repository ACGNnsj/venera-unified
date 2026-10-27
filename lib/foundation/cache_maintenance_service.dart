import 'dart:async';

import 'appdata.dart';
import 'cache_manager.dart';
import 'log.dart';

/// Fixed retention options in days, mirroring venera-prime. Zero keeps
/// entries until the size limit evicts them.
const allowedCacheRetentionDays = [0, 1, 3, 7, 30];
const defaultCacheRetentionDays = 7;

/// Prime's `_applySettings` allowlist: only offered values are honored.
int normalizeCacheRetentionDays(Object? value) =>
    value is int && allowedCacheRetentionDays.contains(value)
    ? value
    : defaultCacheRetentionDays;

/// Applies the retention setting and runs age-based cleanup on startup, on
/// settings changes, and hourly. Cleanup itself is owned by [CacheManager],
/// which only touches its own cache directory and tracking database.
///
/// Deviations from prime's CacheMaintenanceService: the size limit stays with
/// the existing [CacheSettingsBinding], lifecycle-resume triggers are skipped
/// (no widget binding in unit tests), and the countdown progress hook is
/// dropped because [CacheManager.checkCache] reports no progress.
class CacheMaintenanceService {
  CacheMaintenanceService({
    required this.settings,
    required this.applyRetention,
    required this.runCleanup,
    Map<String, dynamic>? implicitData,
    void Function()? persist,
    DateTime Function()? now,
    this.interval = const Duration(hours: 1),
  }) : _implicitData = implicitData ?? appdata.implicitData,
       _persist = persist ?? (() => unawaited(appdata.writeImplicitData())),
       _now = now ?? DateTime.now;

  factory CacheMaintenanceService.forCache({
    required Settings settings,
    required CacheManager cache,
    Map<String, dynamic>? implicitData,
    void Function()? persist,
    DateTime Function()? now,
    Duration interval = const Duration(hours: 1),
  }) => CacheMaintenanceService(
    settings: settings,
    applyRetention: cache.setRetentionDays,
    runCleanup: cache.checkCache,
    implicitData: implicitData,
    persist: persist,
    now: now,
    interval: interval,
  );

  final Settings settings;
  final void Function(int days) applyRetention;
  final Future<void> Function() runCleanup;
  final Map<String, dynamic> _implicitData;
  final void Function() _persist;
  final DateTime Function() _now;
  final Duration interval;

  bool _started = false;
  Timer? _timer;
  int _retention = defaultCacheRetentionDays;
  Future<void>? _running;
  bool _rerun = false;

  void start() {
    if (_started) return;
    _started = true;
    _applySettings();
    settings.addListener(_onSettingsChanged);
    _timer = Timer.periodic(interval, (_) => _schedule('periodic'));
    _schedule('startup');
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    settings.removeListener(_onSettingsChanged);
  }

  bool _applySettings() {
    final retention = normalizeCacheRetentionDays(
      settings['cacheRetentionDays'],
    );
    final changed = retention != _retention;
    _retention = retention;
    applyRetention(retention);
    return changed;
  }

  void _onSettingsChanged() {
    if (_applySettings()) {
      _rerun = _running != null;
      _schedule('settings');
    }
  }

  void _schedule(String reason) {
    unawaited(
      clean(reason: reason).catchError((Object error, StackTrace stack) {
        Log.error('Automatic cache cleanup', error, stack);
      }),
    );
  }

  Future<void> clean({String reason = 'manual'}) {
    if (_running != null) return _running!;
    _applySettings();
    if ((reason == 'startup' || reason == 'periodic') && !_dailyCheckDue()) {
      return Future<void>.value();
    }
    return _running = _run(reason).whenComplete(() => _running = null);
  }

  bool _dailyCheckDue() {
    final record = _implicitData['cacheMaintenance'];
    if (record is! Map ||
        record['finishedAt'] is! int ||
        record['retentionDays'] != _retention) {
      return true;
    }
    final DateTime last;
    try {
      last = DateTime.fromMillisecondsSinceEpoch(record['finishedAt']);
    } on ArgumentError {
      return true;
    }
    final now = _now().toLocal();
    return last.year != now.year ||
        last.month != now.month ||
        last.day != now.day;
  }

  Future<void> _run(String reason) async {
    do {
      _rerun = false;
      _applySettings();
      final retention = _retention;
      await runCleanup();
      // Persist only successful maintenance; failures remain retryable.
      _implicitData['cacheMaintenance'] = {
        'finishedAt': _now().millisecondsSinceEpoch,
        'retentionDays': retention,
      };
      _persist();
      reason = 'settings';
    } while (_rerun);
  }
}
