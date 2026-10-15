import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/image_http3_fallback.dart';
import 'package:venera_next/network/rhttp_stream_request.dart';

const _url = 'https://images.example.test/page.webp?token=private';
final _nativeRequest = rhttp.HttpRequest(
  method: rhttp.HttpMethod.get,
  url: _url,
);
final _tlsEof = rhttp.RhttpConnectionException(
  _nativeRequest,
  'hyper_util::client::legacy::Error(Connect, Custom { kind: UnexpectedEof, '
  'error: "tls handshake eof" })',
);
const _settings = rhttp.ClientSettings(
  proxySettings: rhttp.ProxySettings.noProxy(),
  tlsSettings: rhttp.TlsSettings(),
  throwOnStatusCode: false,
  redirectSettings: rhttp.RedirectSettings.limited(3),
  dnsSettings: rhttp.DnsSettings.static(
    overrides: {
      'images.example.test': ['127.0.0.1'],
    },
  ),
  cookieSettings: rhttp.CookieSettings.none(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => App.version = 'http3-test');

  test('only explicitly opted-in image clients enable fallback', () {
    for (final images in [false, true]) {
      final dio = images ? AppDio.forImages() : AppDio();
      expect(
        (dio.httpClientAdapter as RHttpAdapter).allowImageHttp3Fallback,
        images,
      );
      dio.close(force: true);
    }
  });

  group('interruption classification', () {
    for (final message in [
      'tls handshake eof',
      'Connection reset by peer (os error 104)',
      'Custom { kind: ConnectionReset, error: "connection failed" }',
      'An existing connection was forcibly closed by the remote host',
      'Connection terminated during handshake',
      'TLS handshake: unexpected end of file',
    ]) {
      test(message, () {
        expect(
          isImageTlsConnectionInterruption(
            rhttp.RhttpConnectionException(_nativeRequest, message),
          ),
          isTrue,
        );
      });
    }
    for (final error in <Object>[
      StateError('tls handshake eof'),
      rhttp.RhttpUnknownException(_nativeRequest, 'connection reset'),
      rhttp.RhttpConnectionException(_nativeRequest, 'connection refused'),
      rhttp.RhttpConnectionException(_nativeRequest, 'dns lookup failed'),
      rhttp.RhttpConnectionException(
        _nativeRequest,
        'dns error: connection reset by peer',
      ),
      rhttp.RhttpConnectionException(_nativeRequest, 'unexpected eof'),
      rhttp.RhttpConnectionException(
        _nativeRequest,
        'certificate failure during handshake: unexpected eof',
      ),
      rhttp.RhttpInvalidCertificateException(
        request: _nativeRequest,
        message: 'certificate invalid',
      ),
      rhttp.RhttpTimeoutException(_nativeRequest),
      rhttp.RhttpCancelException(_nativeRequest),
    ]) {
      test('rejects $error', () {
        expect(isImageTlsConnectionInterruption(error), isFalse);
      });
    }
  });

  test('header deadline is bounded and respects a shorter caller timeout', () {
    expect(
      imageHttp3HeaderTimeout(RequestOptions(), _settings),
      const Duration(seconds: 5),
    );
    expect(
      imageHttp3HeaderTimeout(
        RequestOptions(connectTimeout: const Duration(seconds: 2)),
        _settings,
      ),
      const Duration(seconds: 2),
    );
    expect(
      imageHttp3HeaderTimeout(
        RequestOptions(receiveTimeout: const Duration(milliseconds: 100)),
        _settings,
      ),
      const Duration(milliseconds: 100),
    );
    expect(
      imageHttp3HeaderTimeout(
        RequestOptions(connectTimeout: Duration.zero),
        _settings.copyWith(
          timeoutSettings: const rhttp.TimeoutSettings(
            connectTimeout: Duration(seconds: 3),
          ),
        ),
      ),
      const Duration(seconds: 3),
    );
  });

  test(
    'waits for failed attempt cleanup, then keeps request and security settings',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final options = RequestOptions(
        path: _url,
        headers: {
          'Cookie': 'private-cookie',
          'Authorization': 'private-auth',
          'Referer': 'https://source.example.test/',
        },
      );
      final result = fixture.fetch(options);
      await fixture.first.started.future;
      fixture.first.headers.completeError(_tlsEof);
      await fixture.first.cancelled.future;
      await pumpEventQueue();
      expect(fixture.configurations, hasLength(1));
      var idle = false;
      final draining = fixture.adapter.waitForIdle().then((_) => idle = true);
      await fixture.first.release();
      await fixture.second.started.future;
      expect(idle, isFalse);
      final fallback = fixture.configurations.last;
      expect(fixture.requests.last, same(options));
      expect(fallback.httpVersionPref, rhttp.HttpVersionPref.http3);
      expect(fallback.tlsSettings, same(_settings.tlsSettings));
      expect(fallback.proxySettings, same(_settings.proxySettings));
      expect(fallback.dnsSettings, same(_settings.dnsSettings));
      expect(fallback.cookieSettings, same(_settings.cookieSettings));
      expect(fallback.redirectSettings, isNotNull);
      expect(fallback.throwOnStatusCode, isFalse);
      fixture.second.respond();
      final bytes = (await result).stream.expand((chunk) => chunk).toList();
      fixture.second.body.add(Uint8List.fromList([3, 2, 1]));
      await fixture.second.release();
      expect(await bytes, [3, 2, 1]);
      await draining;
      expect(idle, isTrue);
      expect(fixture.configurations, hasLength(2));
      final diagnostics = Log.logs
          .where((log) => log.title == 'Image HTTP')
          .map((log) => log.content)
          .join('\n');
      expect(diagnostics, contains('https://images.example.test'));
      expect(diagnostics, isNot(contains('token=private')));
      expect(diagnostics, isNot(contains('private-cookie')));
      expect(diagnostics, isNot(contains('private-auth')));
    },
  );

  for (final reason in [
    'not-image',
    'http',
    'post',
    'body',
    'upload',
    'proxy',
    'system-proxy',
    'forced-version',
  ]) {
    test('no fallback for $reason', () async {
      final fixture = _Fixture(
        enabled: reason != 'not-image',
        configured: switch (reason) {
          'proxy' => _settings.copyWith(
            proxySettings: const rhttp.ProxySettings.proxy(
              'http://127.0.0.1:7897',
            ),
          ),
          'system-proxy' => _settings.copyWith(proxySettings: null),
          'forced-version' => _settings.copyWith(
            httpVersionPref: rhttp.HttpVersionPref.http2,
          ),
          _ => _settings,
        },
      );
      addTearDown(fixture.dispose);
      final result = fixture.fetch(
        RequestOptions(
          path: reason == 'http' ? 'http://images.example.test/page.jpg' : _url,
          method: reason == 'post' ? 'POST' : 'GET',
          data: reason == 'body' ? 'body' : null,
        ),
        upload: reason == 'upload' ? const Stream<Uint8List>.empty() : null,
      );
      final failed = expectLater(result, throwsA(same(_tlsEof)));
      await fixture.first.started.future;
      fixture.first.headers.completeError(_tlsEof);
      await fixture.first.release();
      await failed;
      await fixture.adapter.waitForIdle();
      expect(fixture.configurations, hasLength(1));
    });
  }

  test('an HTTP status response is not a connection failure', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final result = fixture.fetch(null);
    await fixture.first.started.future;
    fixture.first.respond(status: 503);
    final response = await result;
    expect(response.statusCode, 503);
    final body = response.stream.drain<void>();
    await fixture.first.release();
    await body;
    await fixture.adapter.waitForIdle();
    expect(fixture.configurations, hasLength(1));
  });

  test('a partial body is never replayed over another protocol', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final result = fixture.fetch(null);
    await fixture.first.started.future;
    fixture.first.respond();
    final body = (await result).stream.toList();
    final failed = expectLater(body, throwsA(same(_tlsEof)));
    fixture.first.body.add(Uint8List.fromList([1]));
    fixture.first.body.addError(_tlsEof);
    await fixture.first.release();
    await failed;
    await fixture.adapter.waitForIdle();
    expect(fixture.configurations, hasLength(1));
  });

  test('H3 failure preserves both causes and cannot retry again', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final fallbackFailure = rhttp.RhttpConnectionException(
      _nativeRequest,
      'connection reset by peer',
    );
    final result = fixture.fetch(null);
    final failed = expectLater(
      result,
      throwsA(
        isA<ImageHttp3FallbackFailure>()
            .having((error) => error.originalError, 'TCP error', same(_tlsEof))
            .having(
              (error) => error.fallbackError,
              'H3 error',
              same(fallbackFailure),
            ),
      ),
    );
    await fixture.first.started.future;
    fixture.first.headers.completeError(_tlsEof);
    await fixture.first.release();
    await fixture.second.started.future;
    fixture.second.headers.completeError(fallbackFailure);
    await fixture.second.release();
    await failed;
    await fixture.adapter.waitForIdle();
    expect(fixture.configurations, hasLength(2));
  });

  for (final phase in ['first-cleanup', 'second-headers']) {
    test(
      'cancellation at $phase stops fallback and still joins cleanup',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        final cancel = Completer<void>();
        final result = fixture.fetch(null, cancellation: cancel.future);
        final failed = expectLater(
          result,
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'cancelled',
              DioExceptionType.cancel,
            ),
          ),
        );
        await fixture.first.started.future;
        fixture.first.headers.completeError(_tlsEof);
        await fixture.first.cancelled.future;
        var idle = false;
        final draining = fixture.adapter.waitForIdle().then((_) => idle = true);
        if (phase == 'second-headers') {
          await fixture.first.release();
          await fixture.second.started.future;
        }
        cancel.complete();
        await pumpEventQueue();
        expect(idle, isFalse);
        if (phase == 'first-cleanup') {
          await fixture.first.release();
        } else {
          await fixture.second.cancelled.future;
          fixture.second.headers.completeError(
            rhttp.RhttpCancelException(_nativeRequest),
          );
          await fixture.second.release();
        }
        await failed;
        await draining;
        expect(
          fixture.configurations,
          hasLength(phase == 'first-cleanup' ? 1 : 2),
        );
      },
    );
  }

  test(
    'H3 header timeout cancels native work but idle waits for its release',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final result = fixture.fetch(
        RequestOptions(
          path: _url,
          connectTimeout: const Duration(milliseconds: 25),
        ),
      );
      final failed = expectLater(
        result,
        throwsA(
          isA<ImageHttp3FallbackFailure>().having(
            (error) => error.fallbackError,
            'header timeout',
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.connectionTimeout,
            ),
          ),
        ),
      );
      await fixture.first.started.future;
      fixture.first.headers.completeError(_tlsEof);
      await fixture.first.release();
      await fixture.second.started.future;
      await failed;
      await fixture.second.cancelled.future;
      var idle = false;
      final draining = fixture.adapter.waitForIdle().then((_) => idle = true);
      await pumpEventQueue();
      expect(idle, isFalse);
      fixture.second.headers.completeError(
        rhttp.RhttpCancelException(_nativeRequest),
      );
      await fixture.second.release();
      await draining;
      expect(fixture.second.cancels, 1);
    },
  );

  for (final phase in ['cancel', 'native', 'subscription']) {
    test(
      '$phase cleanup failure blocks H3 and remains visible on idle',
      () async {
        final cleanup = StateError('$phase release failed');
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        if (phase == 'cancel') fixture.first.cancelError = cleanup;
        if (phase == 'subscription') {
          fixture.first.body.onCancel = () => throw cleanup;
        }
        final result = fixture.fetch(null);
        final failed = expectLater(result, throwsA(same(_tlsEof)));
        await fixture.first.started.future;
        fixture.first.headers.completeError(_tlsEof);
        await fixture.first.release(
          error: phase == 'native'
              ? cleanup
              : phase == 'subscription'
              ? StateError('Bridge exited without closing its body stream')
              : null,
          closeBody: phase != 'subscription',
        );
        await failed;
        final matcher = isA<RHttpCleanupFailure>().having(
          (error) => error.failures.map((item) => item.error),
          'cleanup',
          contains(same(cleanup)),
        );
        await expectLater(fixture.adapter.waitForIdle(), throwsA(matcher));
        await expectLater(fixture.adapter.waitForIdle(), throwsA(matcher));
        expect(fixture.configurations, hasLength(1));
      },
    );
  }

  test(
    'force closing in the retry gap cannot admit a second native call',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final result = fixture.fetch(null);
      final failed = expectLater(result, throwsA(isA<DioException>()));
      await fixture.first.started.future;
      fixture.first.headers.completeError(_tlsEof);
      await fixture.first.cancelled.future;
      fixture.adapter.close(force: true);
      await fixture.first.release();
      await failed;
      await fixture.adapter.waitForIdle();
      expect(fixture.configurations, hasLength(1));
    },
  );
}

class _Adapter extends RHttpAdapter {
  _Adapter({
    required RHttpStreamCallFactory start,
    required bool enabled,
    required this.configured,
  }) : super(startStreamCall: start, allowImageHttp3Fallback: enabled);

  final rhttp.ClientSettings configured;

  @override
  Future<rhttp.ClientSettings> get settings async => configured;
}

class _Fixture {
  _Fixture({bool enabled = true, rhttp.ClientSettings configured = _settings}) {
    adapter = _Adapter(
      enabled: enabled,
      configured: configured,
      start: (options, settings, upload) async {
        requests.add(options);
        configurations.add(settings);
        final call = configurations.length == 1 ? first : second;
        if (configurations.length > 2) {
          throw StateError('Unexpected third attempt');
        }
        call.started.complete();
        return RHttpStreamCall(
          response: call.headers.future,
          body: call.body.stream,
          finished: call.finished.future,
          cancel: call.cancel,
        );
      },
    );
  }

  late final _Adapter adapter;
  final first = _Call();
  final second = _Call();
  final configurations = <rhttp.ClientSettings>[];
  final requests = <RequestOptions>[];

  Future<ResponseBody> fetch(
    RequestOptions? options, {
    Stream<Uint8List>? upload,
    Future<void>? cancellation,
  }) => adapter.fetch(
    options ?? RequestOptions(path: _url),
    upload,
    cancellation,
  );

  Future<void> dispose() async {
    adapter.close(force: true);
    for (final call in [first, second]) {
      if (!call.started.isCompleted) continue;
      if (!call.headers.isCompleted) {
        call.headers.completeError(rhttp.RhttpCancelException(_nativeRequest));
      }
      await call.release();
    }
    try {
      await adapter.waitForIdle();
    } catch (_) {}
  }
}

class _Call {
  final started = Completer<void>();
  final cancelled = Completer<void>();
  final finished = Completer<void>();
  final headers =
      Completer<({int statusCode, Map<String, List<String>> headers})>();
  final body = StreamController<Uint8List>();
  Object? cancelError;
  int cancels = 0;

  void respond({int status = 200}) =>
      headers.complete((statusCode: status, headers: <String, List<String>>{}));

  Future<void> cancel() async {
    cancels++;
    if (!cancelled.isCompleted) cancelled.complete();
    if (cancelError != null) throw cancelError!;
  }

  Future<void> release({Object? error, bool closeBody = true}) async {
    if (closeBody) unawaited(body.close());
    if (!finished.isCompleted) {
      if (error == null) {
        finished.complete();
      } else {
        finished.completeError(error);
      }
    }
  }
}
