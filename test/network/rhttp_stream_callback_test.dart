// Exercises the locked native bridge directly, including its callback ack.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
// ignore: invalid_use_of_internal_member
import 'package:rhttp/src/model/settings.dart' show ClientSettingsExt;
import 'package:rhttp/src/rust/api/error.dart';
import 'package:rhttp/src/rust/api/http.dart' as rust;
import 'package:rhttp/src/rust/frb_generated.dart';
import 'package:rhttp/src/rust/lib.dart' show CancellationToken;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native cancellation finishes only after Dart callbacks acknowledge',
    () async {
      await rhttp.Rhttp.init();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        // Send headers but keep the body open so EOF cannot win cancellation.
        request.response.contentLength = 2;
        request.response.write('x');
        await request.response.flush();
      });
      const timeout = Duration(seconds: 10);
      final responseEntered = Completer<void>();
      final releaseResponse = Completer<void>();
      final errorEntered = Completer<RhttpError>();
      final releaseError = Completer<void>();
      final token = Completer<CancellationToken>();
      // ignore: invalid_use_of_internal_member
      final original = RustLib.instance.api as RustLibApiImpl;
      // ignore: invalid_use_of_protected_member
      final handler = _ObserveNativeReturn(original.handler);
      final api = RustLibApiImpl(
        handler: handler,
        // ignore: invalid_use_of_protected_member
        wire: original.wire,
        generalizedFrbRustBinding: original.generalizedFrbRustBinding,
        portManager: original.portManager,
      );
      final body = api.crateApiHttpMakeHttpRequestReceiveStream(
        settings: const rhttp.ClientSettings(
          proxySettings: rhttp.ProxySettings.noProxy(),
          throwOnStatusCode: false,
          // ignore: invalid_use_of_internal_member
        ).toRustType(),
        method: const rust.HttpMethod(method: 'GET'),
        url: 'http://127.0.0.1:${server.port}',
        cancelable: true,
        onCancelToken: token.complete,
        onResponse: (_) async {
          responseEntered.complete();
          await releaseResponse.future;
        },
        onError: (error) async {
          errorEntered.complete(error);
          await releaseError.future;
        },
      );
      final bodyDone = Completer<void>();
      final subscription = body.listen(
        (_) {},
        onError: (Object _) {},
        onDone: bodyDone.complete,
      );
      addTearDown(() async {
        if (!releaseResponse.isCompleted) releaseResponse.complete();
        if (!releaseError.isCompleted) releaseError.complete();
        try {
          if (token.isCompleted) {
            final nativeToken = await token.future;
            await rust.cancelRequest(token: nativeToken).timeout(timeout);
            await handler.finished.timeout(timeout);
            if (!nativeToken.isDisposed) nativeToken.dispose();
          }
        } finally {
          await subscription.cancel();
        }
      });
      await responseEntered.future.timeout(timeout);
      await rust.cancelRequest(token: await token.future).timeout(timeout);
      var returned = false;
      final finished = handler.finished.then((_) => returned = true);
      await pumpEventQueue();
      expect(returned, isFalse);

      // The bridge first awaits the response ack, then polls body cancellation.
      releaseResponse.complete();
      expect(
        await errorEntered.future.timeout(timeout),
        isA<RhttpError_RhttpCancelError>(),
      );
      await bodyDone.future.timeout(timeout);
      expect(returned, isFalse);
      releaseError.complete();
      await finished.timeout(timeout);
      expect(returned, isTrue);
    },
    skip: !Platform.isWindows,
  );
}

class _ObserveNativeReturn extends BaseHandler {
  _ObserveNativeReturn(this.delegate);
  final BaseHandler delegate;
  late Future<void> finished;

  @override
  Future<S> executeNormal<S, E extends Object>(NormalTask<S, E> task) {
    final result = delegate.executeNormal<S, E>(task);
    finished = result.then<void>((_) {});
    return result;
  }
}
