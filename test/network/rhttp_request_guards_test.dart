import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_unified/network/app_dio.dart';
import 'package:venera_unified/network/rhttp_stream_request.dart';

Future<RHttpStreamCall> _fakeCall(
  RequestOptions options,
  rhttp.ClientSettings settings,
  Stream<Uint8List>? upload,
) async {
  final headers =
      Completer<({int statusCode, Map<String, List<String>> headers})>();
  final body = StreamController<Uint8List>();
  final finished = Completer<void>();
  headers.complete((statusCode: 200, headers: const <String, List<String>>{}));
  body.add(Uint8List.fromList([1, 2, 3]));
  unawaited(body.close());
  finished.complete();
  return RHttpStreamCall(
    response: headers.future,
    body: body.stream,
    finished: finished.future,
    cancel: () async {},
  );
}

rhttp.ClientSettings _settings() => const rhttp.ClientSettings(
  proxySettings: rhttp.ProxySettings.noProxy(),
  throwOnStatusCode: false,
);

RequestOptions _options(String method, {Object? data}) =>
    RequestOptions(path: 'http://127.0.0.1/', method: method, data: data);

void main() {
  group('native request validation', () {
    test('rejects an invalid HTTP method', () async {
      final request = RHttpStreamRequest(
        options: _options('NOT A METHOD'),
        settings: Future.value(_settings()),
        upload: null,
        statusMessage: (code) => '$code',
      );
      await expectLater(
        request.response,
        throwsA(
          isA<DioException>().having(
            (e) => e.error.toString(),
            'error',
            contains('Invalid HTTP method'),
          ),
        ),
      );
    });

    test('rejects upload data without an upload stream', () async {
      final request = RHttpStreamRequest(
        options: _options('POST', data: 'payload'),
        settings: Future.value(_settings()),
        upload: null,
        statusMessage: (code) => '$code',
      );
      await expectLater(
        request.response,
        throwsA(
          isA<DioException>().having(
            (e) => e.error.toString(),
            'error',
            contains('no upload stream'),
          ),
        ),
      );
    });

    test('settled request ignores a late cancellation callback', () async {
      final request = RHttpStreamRequest(
        options: _options('GET'),
        settings: Future.value(_settings()),
        upload: null,
        statusMessage: (code) => '$code',
        start: _fakeCall,
      );
      final response = await request.response;
      expect(response.statusCode, 200);
      await response.stream.drain<void>();
      await request.done;
      expect(request.isDone, isTrue);
      // Must not throw or disturb the settled request.
      request.cancel();
      await request.done;
      expect(request.isDone, isTrue);
    });
  });

  group('custom DNS overrides', () {
    test('accepts valid host IP pairs', () {
      validateCustomDnsOverrides({
        'example.com': ['93.184.216.34'],
      });
    });

    test('rejects empty hosts and unparseable IPs', () {
      expect(
        () => validateCustomDnsOverrides({
          '': ['1.1.1.1'],
        }),
        throwsArgumentError,
      );
      expect(
        () => validateCustomDnsOverrides({
          'example.com': ['not-an-ip'],
        }),
        throwsArgumentError,
      );
    });
  });
}
