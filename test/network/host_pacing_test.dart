import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/network/host_pacing.dart';

void main() {
  test('intervalFor covers pixiv hosts, unknown zero, case-insensitive', () {
    final pacing = HostPacingInterceptor();
    expect(
      pacing.intervalFor('app-api.pixiv.net'),
      const Duration(milliseconds: 300),
    );
    expect(
      pacing.intervalFor('www.pixiv.net'),
      const Duration(milliseconds: 300),
    );
    expect(pacing.intervalFor('i.pximg.net'), const Duration(milliseconds: 50));
    expect(pacing.intervalFor('s.pximg.net'), const Duration(milliseconds: 50));
    expect(pacing.intervalFor('example.com'), Duration.zero);
    expect(
      pacing.intervalFor('APP-API.PIXIV.NET'),
      const Duration(milliseconds: 300),
    );
    expect(pacing.intervalFor('I.PxImg.Net'), const Duration(milliseconds: 50));
  });

  test('pace() same host back-to-back respects the interval', () async {
    final pacing = HostPacingInterceptor(
      intervals: const {'example.com': Duration(milliseconds: 120)},
    );
    final uri = Uri.parse('https://example.com/a');
    await pacing.pace(uri);
    final stopwatch = Stopwatch()..start();
    await pacing.pace(uri);
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(90));
  });

  test('pace() cross hosts do not block each other', () async {
    final pacing = HostPacingInterceptor(
      intervals: const {
        'a.example.com': Duration(milliseconds: 200),
        'b.example.com': Duration(milliseconds: 200),
      },
    );
    final stopwatch = Stopwatch()..start();
    await Future.wait([
      pacing.pace(Uri.parse('https://a.example.com/1')),
      pacing.pace(Uri.parse('https://b.example.com/1')),
    ]);
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, lessThan(150));
  });

  test('onRequest paces full Dio chain via stub adapter', () async {
    const interval = Duration(milliseconds: 100);
    final adapter = _StubAdapter();
    final dio = Dio()
      ..options.baseUrl = 'https://example.com'
      ..interceptors.add(
        HostPacingInterceptor(intervals: const {'example.com': interval}),
      )
      ..httpClientAdapter = adapter;

    final first = await dio.get<String>('/a');
    final second = await dio.get<String>('/b');

    expect(first.statusCode, 200);
    expect(second.statusCode, 200);
    expect(adapter.paths, ['/a', '/b']);
    expect(adapter.starts, hasLength(2));
    final gap = adapter.starts[1].difference(adapter.starts[0]).inMilliseconds;
    expect(gap, greaterThanOrEqualTo(80));
  });
}

class _StubAdapter implements HttpClientAdapter {
  final paths = <String>[];
  final starts = <DateTime>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    starts.add(DateTime.now());
    paths.add(options.uri.path);
    return ResponseBody.fromString(
      'ok',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
