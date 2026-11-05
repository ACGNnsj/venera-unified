import 'package:dio/dio.dart';

/// Minimum per-host request interval ("host pacing").
///
/// Slot reservation: each request claims `max(now, nextAllowed[host])` as its
/// start and moves the host's next slot forward by [interval]. The actual
/// wait happens outside any lock (Dart's event loop makes the map update
/// itself atomic), so paced hosts never block each other.
///
/// The default table only carries the known-strict pixiv hosts; other
/// sources declare their intervals from the source side via [intervals].
// ponytail: static table, per-source runtime tuning when a source needs it.
class HostPacingInterceptor extends Interceptor {
  HostPacingInterceptor({Map<String, Duration>? intervals})
    : _intervals = {..._defaultIntervals, ...?intervals};

  static const _defaultIntervals = <String, Duration>{
    'app-api.pixiv.net': Duration(milliseconds: 300),
    'www.pixiv.net': Duration(milliseconds: 300),
    'i.pximg.net': Duration(milliseconds: 50),
    's.pximg.net': Duration(milliseconds: 50),
  };

  final Map<String, Duration> _intervals;
  final Map<String, DateTime> _nextAllowed = {};

  /// Configured interval for [host] (zero when unlisted).
  Duration intervalFor(String host) =>
      _intervals[host.toLowerCase()] ?? Duration.zero;

  /// Reserves this request's start slot and waits until it arrives.
  Future<void> pace(Uri uri) async {
    final interval = intervalFor(uri.host);
    if (interval <= Duration.zero) return;
    final now = DateTime.now();
    final slot = _nextAllowed[uri.host.toLowerCase()];
    final start = slot != null && slot.isAfter(now) ? slot : now;
    _nextAllowed[uri.host.toLowerCase()] = start.add(interval);
    final delay = start.difference(now);
    if (delay > Duration.zero) await Future.delayed(delay);
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    await pace(options.uri);
    handler.next(options);
  }
}
