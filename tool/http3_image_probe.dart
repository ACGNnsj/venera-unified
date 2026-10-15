import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/image_http3_fallback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final stateFile = Platform.environment['HTTP3_PROBE_STATE'];
  if (stateFile == null) {
    test('local HTTP/3 probe requires HTTP3_PROBE_STATE', () {}, skip: true);
    return;
  }
  final state =
      jsonDecode(File(stateFile).readAsStringSync()) as Map<String, dynamic>;
  final origin = 'https://${state['hostname']}:${state['port']}';
  final rootCertificate = File(state['ca'] as String).readAsStringSync();
  final png = base64Decode(state['png'] as String);
  final settings = rhttp.ClientSettings(
    proxySettings: const rhttp.ProxySettings.noProxy(),
    throwOnStatusCode: false,
    dnsSettings: rhttp.DnsSettings.static(
      overrides: {
        state['hostname'] as String: ['127.0.0.1'],
      },
    ),
    tlsSettings: rhttp.TlsSettings(
      trustRootCertificates: false,
      trustedRootCertificates: [rootCertificate],
      verifyCertificates: true,
    ),
  );
  setUpAll(() async {
    App.version = 'http3-local-probe';
    await rhttp.Rhttp.init();
  });

  for (final path in ['image', 'redirect']) {
    test(
      'native TLS EOF -> HTTP/3 $path keeps DNS, certificate and headers',
      () async {
        final adapter = _ProbeAdapter(settings);
        final dio = _client(adapter);
        try {
          final response = await dio.get<List<int>>('$origin/$path?key=probe');
          expect(response.statusCode, 200);
          expect(response.headers.value('x-probe-protocol'), 'h3');
          expect(response.data, png);
          final decoded = img.decodePng(png);
          expect(decoded, isNotNull);
          expect((decoded!.width, decoded.height), (1, 1));
        } finally {
          dio.close(force: true);
          await adapter.waitForIdle();
        }
      },
    );
  }

  test('native H3 still rejects an untrusted certificate', () async {
    final adapter = _ProbeAdapter(
      settings.copyWith(
        tlsSettings: const rhttp.TlsSettings(
          trustRootCertificates: false,
          verifyCertificates: true,
        ),
      ),
    );
    final dio = _client(adapter);
    try {
      await expectLater(
        dio.get<List<int>>('$origin/image?key=probe'),
        throwsA(
          isA<DioException>().having(
            (error) => error.error,
            'fallback failure',
            isA<ImageHttp3FallbackFailure>().having(
              (error) => error.fallbackError.toString().toLowerCase(),
              'certificate rejection',
              contains('certificate'),
            ),
          ),
        ),
      );
    } finally {
      dio.close(force: true);
      await adapter.waitForIdle();
    }
  });

  test('native H3 header deadline cancels and drains a waiting peer', () async {
    final adapter = _ProbeAdapter(settings);
    final dio = _client(adapter)
      ..options.connectTimeout = const Duration(milliseconds: 500);
    final elapsed = Stopwatch()..start();
    try {
      await expectLater(
        dio.get<List<int>>('$origin/slow?key=probe'),
        throwsA(
          isA<DioException>().having(
            (error) => error.error,
            'bounded fallback',
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
        ),
      );
    } finally {
      dio.close(force: true);
      await adapter.waitForIdle();
    }
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
  });
}

Dio _client(RHttpAdapter adapter) => Dio(
  BaseOptions(
    responseType: ResponseType.bytes,
    headers: {
      'Cookie': 'session=probe',
      'Authorization': 'Bearer probe',
      'Referer': 'https://source.http3.test/',
    },
  ),
)..httpClientAdapter = adapter;

class _ProbeAdapter extends RHttpAdapter {
  _ProbeAdapter(this.configured) : super(allowImageHttp3Fallback: true);
  final rhttp.ClientSettings configured;

  @override
  Future<rhttp.ClientSettings> get settings async => configured;
}
