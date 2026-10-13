import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/features/sync/data_sync_remote.dart';
import 'package:venera_next/features/sync/data_sync_remote_port.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    App.version = 'redirect-test';
    if (Platform.isWindows) await rhttp.Rhttp.init();
  });

  group('native request redirect policy', () {
    late HttpServer origin;
    late HttpServer destination;
    late RHttpAdapter adapter;
    late Dio dio;
    late Uri originUrl;
    late Uri destinationUrl;
    final destinationMethods = <String>[];

    setUp(() async {
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      originUrl = Uri.parse('http://127.0.0.1:${origin.port}/archive');
      destinationUrl = Uri.parse(
        'http://127.0.0.1:${destination.port}/archive',
      );
      destinationMethods.clear();
      adapter = _DirectAdapter();
      dio = Dio()..httpClientAdapter = adapter;
      destination.listen((request) async {
        destinationMethods.add(request.method);
        await request.drain<void>();
        request.response.write('destination');
        await request.response.close();
      });
    });

    tearDown(() async {
      dio.close(force: true);
      await adapter.waitForIdle();
      await origin.close(force: true);
      await destination.close(force: true);
    });

    for (final method in ['GET', 'PUT', 'DELETE']) {
      for (final status in [302, 307]) {
        test(
          '$method returns $status without contacting redirect target',
          () async {
            origin.listen((request) async {
              await request.drain<void>();
              request.response
                ..statusCode = status
                ..headers.set(HttpHeaders.locationHeader, destinationUrl)
                ..write('original endpoint');
              await request.response.close();
            });

            final response = await dio.requestUri<String>(
              originUrl,
              data: method == 'PUT' ? 'snapshot bytes' : null,
              options: Options(
                method: method,
                followRedirects: false,
                responseType: ResponseType.plain,
                validateStatus: (_) => true,
              ),
            );
            await adapter.waitForIdle();

            expect(response.statusCode, status);
            expect(response.data, 'original endpoint');
            expect(destinationMethods, isEmpty);
          },
        );
      }
    }

    test('default GET policy follows a redirect', () async {
      origin.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, destinationUrl);
        await request.response.close();
      });
      final response = await dio.getUri<String>(
        originUrl,
        options: Options(responseType: ResponseType.plain),
      );
      expect(response.statusCode, 200);
      expect(response.data, 'destination');
      expect(destinationMethods, ['GET']);
    });

    test(
      'WebDAV sync follows native CDN redirects without forwarding authentication',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'native-dav-redirect-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        var originRequests = 0;
        final failures = <Object>[];
        origin.listen((request) async {
          try {
            await request.drain<void>();
            originRequests++;
            expect(request.method, 'GET');
            final authorization = request.headers.value(
              HttpHeaders.authorizationHeader,
            );
            if (authorization == null) {
              request.response.statusCode = 401;
              request.response.headers.set(
                HttpHeaders.wwwAuthenticateHeader,
                'Basic realm="DAV"',
              );
            } else {
              expect(authorization, 'Basic dXNlcjpwYXNzd29yZA==');
              request.response.statusCode = 302;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                destinationUrl.replace(query: 'sign=download-token'),
              );
              request.response.write('redirect body');
            }
          } catch (error) {
            failures.add(error);
            request.response.statusCode = 500;
          } finally {
            await request.response.close();
          }
        });
        // Use a separate CDN handler to inspect the actual native request headers.
        final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => cdn.close(force: true));
        destinationUrl = Uri.parse('http://127.0.0.1:${cdn.port}/Download');
        var downloads = 0;
        cdn.listen((request) async {
          try {
            await request.drain<void>();
            downloads++;
            expect(request.method, 'GET');
            expect(request.uri.query, 'sign=download-token');
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              isNull,
            );
            expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
            expect(
              request.headers.value(HttpHeaders.acceptEncodingHeader),
              'identity',
            );
            request.response.headers.set(HttpHeaders.etagHeader, '"cdn-only"');
            request.response.contentLength = 3;
            request.response.add([1, 2, 3]);
          } catch (error) {
            failures.add(error);
            request.response.statusCode = 500;
          } finally {
            await request.response.close();
          }
        });
        final remote = WebDavDataSyncRemote(
          WebDavEndpoint(
            url: originUrl.toString(),
            user: 'user',
            password: 'password',
          ),
          createClient: (endpoint) => endpoint.createClient(adapter: adapter),
        );
        addTearDown(remote.dispose);
        final output = File('${directory.path}/snapshot.venera');
        await remote.readToFile('Snapshot.venera', output.path);
        expect(output.readAsBytesSync(), [1, 2, 3]);
        final evidence =
            await remote.probeArchive('Snapshot.venera')
                as DataSyncArchivePresent;
        expect(evidence.length, 3);
        expect(evidence.strongEtag, isNull);
        expect(originRequests, 3);
        expect(downloads, 2);
        expect(destinationMethods, isEmpty);
        expect(failures, isEmpty);
      },
    );

    test(
      'request maxRedirects zero does not contact the destination',
      () async {
        origin.listen((request) async {
          await request.drain<void>();
          request.response
            ..statusCode = 302
            ..headers.set(HttpHeaders.locationHeader, destinationUrl);
          await request.response.close();
        });
        await expectLater(
          dio.getUri<String>(
            originUrl,
            options: Options(maxRedirects: 0, responseType: ResponseType.plain),
          ),
          throwsA(isA<DioException>()),
        );
        await adapter.waitForIdle();
        expect(destinationMethods, isEmpty);
      },
    );
  }, skip: !Platform.isWindows);
}

class _DirectAdapter extends RHttpAdapter {
  @override
  Future<rhttp.ClientSettings> get settings async => const rhttp.ClientSettings(
    proxySettings: rhttp.ProxySettings.noProxy(),
    redirectSettings: rhttp.RedirectSettings.limited(5),
    throwOnStatusCode: false,
  );
}
