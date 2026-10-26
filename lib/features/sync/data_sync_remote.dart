import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera_unified/network/app_dio.dart' show RHttpAdapter;
import 'package:venera_unified/network/webdav.dart';

import 'data_sync_remote_port.dart';

class WebDavDataSyncRemote implements DataSyncRemote {
  WebDavDataSyncRemote(
    WebDavEndpoint connection, {
    Client Function(WebDavEndpoint)? createClient,
  }) : _connection = connection,
       _client = createClient == null
           ? connection.createClient(logRequests: true)
           : createClient(connection) {
    _client.c.interceptors.add(_ListingRedirectGuard());
  }

  final WebDavEndpoint _connection;
  final Client _client;
  Future<void>? _closing;

  @override
  Future<List<String>> listNames() async => [
    for (final entry in await _client.readDir('/'))
      if (entry.name != null) entry.name!,
  ];

  @override
  Future<DataSyncArchiveProbe> probeArchive(String name) => _readArchive(name);

  @override
  Future<DataSyncArchiveCreateResult> createArchiveIfAbsent(
    String name,
    File source, {
    required String sha256,
    required int length,
  }) async {
    _checkOpen();
    _uri(name);
    if (length < 0 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw ArgumentError('Invalid archive content evidence');
    }
    // Keep an immutable, verified request body for Basic/Digest challenge
    // retries. A consumed file stream cannot safely be submitted a second time.
    final bytes = await source.readAsBytes();
    if (bytes.length != length ||
        crypto.sha256.convert(bytes).toString() != sha256) {
      throw StateError('Upload archive no longer matches its durable evidence');
    }
    final response = await _request(
      'PUT',
      name,
      data: bytes,
      headers: {
        HttpHeaders.ifNoneMatchHeader: '*',
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
        HttpHeaders.contentLengthHeader: length,
      },
    );
    await _discard(response);
    return switch (response.statusCode) {
      200 || 201 || 204 => DataSyncArchiveCreateResult.created,
      412 => DataSyncArchiveCreateResult.preconditionFailed,
      _ => throw _statusError(response),
    };
  }

  @override
  Future<DataSyncArchiveRemoveResult> removeArchiveIfUnchanged(
    String name, {
    required String strongEtag,
  }) async {
    _checkOpen();
    if (!_isStrongEtag(strongEtag)) {
      throw ArgumentError.value(
        strongEtag,
        'strongEtag',
        'A strong entity tag is required',
      );
    }
    final response = await _request(
      'DELETE',
      name,
      headers: {HttpHeaders.ifMatchHeader: strongEtag},
    );
    await _discard(response);
    return switch (response.statusCode) {
      200 || 204 => DataSyncArchiveRemoveResult.removed,
      404 => DataSyncArchiveRemoveResult.missing,
      412 => DataSyncArchiveRemoveResult.preconditionFailed,
      _ => throw _statusError(response),
    };
  }

  @override
  Future<void> readToFile(String name, String path) async {
    await _readArchive(name, destination: File(path));
  }

  Future<DataSyncArchiveProbe> _readArchive(
    String name, {
    File? destination,
  }) async {
    final response = await _request('GET', name);
    if (response.statusCode != HttpStatus.ok) {
      await _discard(response);
      if (response.statusCode == HttpStatus.notFound && destination == null) {
        return const DataSyncArchiveMissing();
      }
      throw _statusError(response);
    }
    final encoding = response.headers.map[HttpHeaders.contentEncodingHeader];
    if (encoding != null &&
        (encoding.length != 1 || encoding.single.toLowerCase() != 'identity')) {
      await _discard(response);
      throw const FormatException(
        'Archive response ignored identity content encoding',
      );
    }
    final lengths = response.headers.map[HttpHeaders.contentLengthHeader];
    final expectedLength = lengths?.length == 1
        ? int.tryParse(lengths!.single)
        : null;
    if (lengths != null && (expectedLength == null || expectedLength < 0)) {
      await _discard(response);
      throw const FormatException('Invalid archive Content-Length');
    }
    final body = response.data!;
    RandomAccessFile? output;
    var length = 0;
    var subscribed = false;
    var completed = false;
    try {
      if (destination != null) {
        await destination.parent.create(recursive: true);
        output = await destination.open(mode: FileMode.write);
      }
      Stream<List<int>> chunks() async* {
        subscribed = true;
        await for (final chunk in body.stream) {
          length += chunk.length;
          if (expectedLength != null && length > expectedLength) {
            throw const FormatException('Archive body exceeds Content-Length');
          }
          await output?.writeFrom(chunk);
          yield chunk;
        }
      }

      final digest = await crypto.sha256.bind(chunks()).first;
      await _waitForNativeIdle();
      if (expectedLength != null && length != expectedLength) {
        throw const FormatException(
          'Archive body is shorter than Content-Length',
        );
      }
      await output?.flush();
      final tags = response.headers.map[HttpHeaders.etagHeader];
      final tag = tags?.length == 1 ? tags!.single : null;
      completed = true;
      return DataSyncArchivePresent(
        sha256: digest.toString(),
        length: length,
        // 下载/CDN 的 ETag 不代表原 WebDAV 文件，不能用于原文件的条件删除；
        // 只有原归档 URL 直接返回的强 ETag 才能作为删除凭据。
        strongEtag:
            response.requestOptions.uri == _uri(name) &&
                tag != null &&
                _isStrongEtag(tag)
            ? tag
            : null,
      );
    } finally {
      // Dio does not forward downstream subscription cancellation to the
      // adapter; cancel the request itself if local output cannot be opened.
      if (!completed) response.requestOptions.cancelToken?.cancel();
      if (!subscribed) await body.stream.listen(null).cancel();
      await output?.close();
    }
  }

  Uri _uri(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[/\\\x00-\x1f\x7f]'))) {
      throw ArgumentError.value(name, 'name', 'Expected one archive filename');
    }
    final base = Uri.parse(_connection.url);
    final directory = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base
        .replace(path: '$directory${Uri.encodeComponent(name)}')
        .removeFragment();
  }

  void _checkOpen() {
    if (_closing != null) {
      throw DioException(
        requestOptions: RequestOptions(path: _connection.url),
        error: StateError('WebDAV remote is closed'),
      );
    }
  }

  Future<Response<ResponseBody>> _request(
    String method,
    String name, {
    Uint8List? data,
    Map<String, Object> headers = const {},
  }) async {
    _checkOpen();
    var uri = _uri(name);
    final visited = <Uri>{uri};
    var redirects = 0;
    var challenges = 0;
    var credentialsAllowed = true;
    // 兼容性回归：123 云盘目录 PROPFIND 返回 207，归档 GET 却会以 302
    // 跳到 HTTPS 下载/CDN 域名。rc.1 一刀切拒绝跳转导致 Android、Windows 同步失败。
    // WdDio.req 即使关闭 followRedirects 也会自行重试 301/302，不能改回该入口；
    // 这里复用 SDK 认证并自行限制重试。修改策略须保留 data_sync_download_redirect_test.dart 的断言。
    for (;;) {
      _checkOpen();
      final target = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
      final auth = _client.auth;
      // 同源跳转也必须按新路径和查询重新签名。SDK DigestAuth 会再次编码参数，
      // 此处保留实际发送的转义路径及查询，并复用 SDK 算法和已缓存的认证挑战。
      final signer = auth is DigestAuth
          ? DigestAuth(
              user: auth.user,
              pwd: auth.pwd,
              dParts: _WireDigestParts(auth.dParts, target),
            )
          : auth;
      final authorization = credentialsAllowed
          ? signer.authorize(method, target)
          : null;
      // 关闭的是传输层自动跳转，不是禁止下载跳转。validateStatus 必须放行 3xx，
      // 再由下方 GET 分支检查 Location；收紧为仅 2xx 会重现 rc.1 的 302 错误。
      final options =
          Options(
            method: method,
            followRedirects: false,
            maxRedirects: 0,
            responseType: ResponseType.stream,
            validateStatus: (_) => true,
            headers: {
              HttpHeaders.acceptEncodingHeader: 'identity',
              ...headers,
              HttpHeaders.authorizationHeader: ?authorization,
            },
          ).compose(
            _client.c.options,
            uri.toString(),
            data: data,
            cancelToken: CancelToken(),
          );
      if (!credentialsAllowed) {
        // 跨源下载不能继承 WebDAV 认证、Cookie、自定义私有头或默认查询参数。
        // 仅清除客户端默认查询，必须保留 Location 自带的签名查询，否则 CDN 会拒绝下载。
        // 一旦跨源，整条跳转链都不再携带原凭据，即使后来跳回原 WebDAV 域名。
        options.headers.removeWhere(
          (name, _) => !{
            HttpHeaders.acceptHeader,
            HttpHeaders.acceptEncodingHeader,
            HttpHeaders.userAgentHeader,
          }.contains(name.toLowerCase()),
        );
        options.queryParameters.clear();
      }
      final response = await _client.c.fetch<ResponseBody>(options);
      if (response.statusCode == HttpStatus.unauthorized) {
        await _discard(response);
        if (!credentialsAllowed ||
            challenges++ >= 2 ||
            !_authenticate(response)) {
          throw _statusError(response);
        }
        continue;
      }
      // 仅 GET 可受控跳转；不能为了修复下载而放开 PUT、DELETE 或 PROPFIND，
      // 否则会破坏原端点的认证及条件写入/删除边界。次数上限和循环检测必须保留。
      final redirect = method == 'GET' ? _downloadRedirect(response) : null;
      if (redirect != null && redirects < 5 && visited.add(redirect)) {
        await _discard(response);
        credentialsAllowed = credentialsAllowed && _sameOrigin(uri, redirect);
        uri = redirect;
        redirects++;
        continue;
      }
      // CDN 链接失效返回 404 不代表原 WebDAV 归档不存在，必须报错；
      // 不能按“远端无备份”处理，否则同步可能误判并继续上传。
      if (redirects > 0 && response.statusCode == HttpStatus.notFound) {
        await _discard(response);
        throw _statusError(response);
      }
      return response;
    }
  }

  Uri? _downloadRedirect(Response<ResponseBody> response) {
    if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) return null;
    final locations = response.headers.map[HttpHeaders.locationHeader];
    if (locations == null || locations.length != 1) return null;
    final location = locations.single.trim();
    if (location.isEmpty || location.contains(RegExp(r'[\\\x00-\x1f\x7f]'))) {
      return null;
    }
    final current = response.requestOptions.uri;
    Uri next;
    try {
      // 允许相对 Location，并保留其转义路径和签名查询；不能重新拼接或解码下载 URL。
      next = current.resolve(location).removeFragment();
      // 下载跳转不等于信任任意目标：必须拒绝 URL 内嵌凭据和 HTTPS 降级。
      if (!{'http', 'https'}.contains(next.scheme) ||
          next.host.isEmpty ||
          next.userInfo.isNotEmpty ||
          current.scheme == 'https' && next.scheme != 'https') {
        return null;
      }
    } on FormatException {
      return null;
    }
    return next;
  }

  bool _authenticate(Response<ResponseBody> response) {
    final challenges =
        response.headers.map[HttpHeaders.wwwAuthenticateHeader] ?? const [];
    String? challenge(String scheme) {
      for (final value in challenges) {
        if (value.toLowerCase().startsWith('$scheme ')) return value;
      }
      return null;
    }

    final auth = _client.auth;
    final digest = challenge('digest');
    if (digest != null &&
        (auth.type == AuthType.NoAuth ||
            auth.type == AuthType.DigestAuth &&
                RegExp(
                  r'stale\s*=\s*true',
                  caseSensitive: false,
                ).hasMatch(digest))) {
      _client.auth = DigestAuth(
        user: auth.user,
        pwd: auth.pwd,
        dParts: DigestParts(digest),
      );
      return true;
    }
    if (auth.type == AuthType.NoAuth && challenge('basic') != null) {
      _client.auth = BasicAuth(user: auth.user, pwd: auth.pwd);
      return true;
    }
    return false;
  }

  Future<void> _discard(Response<ResponseBody> response) async {
    // 认证重试及下一跳请求前，必须读完本次响应并等待原生请求真正收尾；
    // 不能只收到响应头就重发，也不能用固定延时替代 waitForIdle。
    var length = 0;
    await for (final chunk in response.data!.stream) {
      length += chunk.length;
    }
    await _waitForNativeIdle();
    final lengths = response.headers.map[HttpHeaders.contentLengthHeader];
    if (lengths != null &&
        (lengths.length != 1 || int.tryParse(lengths.single) != length)) {
      throw const FormatException('Incomplete WebDAV response body');
    }
  }

  Future<void> _waitForNativeIdle() async {
    final adapter = _client.c.httpClientAdapter;
    if (adapter is RHttpAdapter) await adapter.waitForIdle();
  }

  DioException _statusError(Response<ResponseBody> response) =>
      DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );

  @override
  Future<void> dispose() => _closing ??= closeWebDavClient(_client);
}

bool _isStrongEtag(String value) =>
    RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value);

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme == second.scheme &&
    first.host == second.host &&
    first.port == second.port;

class _WireDigestParts extends DigestParts {
  _WireDigestParts(DigestParts source, this.target) : super(null) {
    parts.addAll(source.parts);
  }

  final String target;

  @override
  String get uri => target;
  @override
  set uri(String value) {}
}

/// 目录读取保留 SDK 的 XML 解析及认证，但不能随下载 GET 一起放开重定向。
/// SDK 会自行重试 301/302，仅设置 followRedirects=false 不够；还须拒绝目录 3xx，
/// 防止 PROPFIND 改变原端点或把认证发送到下载/CDN 域名。
class _ListingRedirectGuard extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.method == 'PROPFIND') {
      options.followRedirects = false;
      options.maxRedirects = 0;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final status = response.statusCode;
    if (response.requestOptions.method == 'PROPFIND' &&
        status != null &&
        status >= 300 &&
        status < 400) {
      handler.reject(
        DioException.badResponse(
          statusCode: status,
          requestOptions: response.requestOptions,
          response: response,
        ),
      );
      return;
    }
    handler.next(response);
  }
}
