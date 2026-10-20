import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';

void main() {
  late bool muted;
  setUp(() {
    muted = Log.isMuted;
    Log.isMuted = false;
    Log.clear();
  });
  tearDown(() {
    Log.clear();
    Log.isMuted = muted;
  });

  test('request masks credentials by default without altering traffic', () {
    final options = RequestOptions(
      path: 'https://example.com/api?token=private-query&page=2',
      method: 'POST',
      headers: {
        'Cookie': 'login=private-cookie',
        'aUtHoRiZaTiOn': 'Bearer private-auth',
        'X-Custom': 'private-custom',
        'Content-Type': 'application/json',
      },
      data: {'password': 'private-password', 'title': 'public title'},
      extra: {
        'maskHeadersInLog': ['x-custom'],
      },
    );
    MyLogInterceptor().onRequest(options, RequestInterceptorHandler());
    final text = Log.logs.single.content;
    expect(text, isNot(contains('private-')));
    expect(text, contains('application/json'));
    expect(text, contains('public title'));
    expect(text, contains('page=2'));
    expect(options.headers['Cookie'], 'login=private-cookie');
    expect(options.headers['aUtHoRiZaTiOn'], 'Bearer private-auth');
    expect(options.data['password'], 'private-password');
    expect(options.uri.queryParameters['token'], 'private-query');
  });

  test('response and error diagnostics redact cookies and body fields', () {
    final response = Response<dynamic>(
      requestOptions: RequestOptions(path: 'https://example.com/api'),
      statusCode: 401,
      headers: Headers.fromMap({
        'Set-Cookie': ['login=private-cookie', 'other=private-other'],
        'Content-Type': ['application/json'],
      }),
      data: {'refresh_token': 'private-refresh', 'message': 'public failure'},
    );
    MyLogInterceptor().onResponse(response, ResponseInterceptorHandler());
    MyLogInterceptor().onError(
      DioException(
        requestOptions: response.requestOptions,
        response: response,
        message: 'Authorization: Bearer private-auth',
      ),
      _CapturedErrorHandler(),
    );
    final text = Log().toString();
    expect(text, isNot(contains('private-')));
    expect(text, contains('public failure'));
    expect(text, contains('401'));
    expect(response.headers['set-cookie'], [
      'login=private-cookie',
      'other=private-other',
    ]);
    expect(response.data['refresh_token'], 'private-refresh');
  });

  test(
    'legacy comma-separated custom header masks remain case insensitive',
    () {
      MyLogInterceptor().onRequest(
        RequestOptions(
          path: 'https://example.com/api',
          headers: {'X-Custom': 'private-one', 'X-Other': 'private-two'},
          extra: {'maskHeadersInLog': 'x-custom, x-other'},
        ),
        RequestInterceptorHandler(),
      );
      expect(Log().toString(), isNot(contains('private-')));
    },
  );

  test('legacy full-body masking is retained', () {
    MyLogInterceptor().onRequest(
      RequestOptions(
        path: 'https://example.com/api',
        data: 'private-entire-body',
        extra: {'maskDataInLog': true, 'maskHeadersInLog': null},
      ),
      RequestInterceptorHandler(),
    );
    expect(Log().toString(), contains('DATA_PROTECTED'));
    expect(Log().toString(), isNot(contains('private-')));
  });
}

class _CapturedErrorHandler extends ErrorInterceptorHandler {
  @override
  void next(DioException err) {}
}
