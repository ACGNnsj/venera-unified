// Throughput probe for the Flutter Rust Bridge path, mirroring
// `../kotlin/src/main/kotlin/Main.kt` so the uniffi and FRB bindings can be
// put side by side on the same machine.
//
// The generated bindings are imported by relative path from the vendored
// package instead of being copied here: they are generated files, and a copy
// would drift the moment `flutter_rust_bridge_codegen` runs again.
//
//   dart pub get --offline
//   dart run bin/bench.dart
//
// Environment:
//   RHTTP_DLL        native library (default: rust/target/debug/rhttp.dll
//                    relative to the packages/rhttp directory)
//   BENCH_BODY_MIB   payload size in MiB (default 64)
//   BENCH_WARMUP     warmup rounds per path (default 2)
//   BENCH_ROUNDS     measured rounds (default 9)
//
// Two paths read the same loopback body: the generated FRB call
// (`makeHttpRequestReceiveStream`, the layer `Rhttp.requestStream` wraps) and
// `dart:io` with no FFI at all. Rounds interleave so a slow moment on the
// machine hits both, and both are warmed first — the first pass through a cold
// JIT and a cold TCP window is not a throughput measurement.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import '../../../../../lib/src/rust/api/client.dart';
import '../../../../../lib/src/rust/api/http.dart';
import '../../../../../lib/src/rust/frb_generated.dart';

const int _chunkBytes = 64 * 1024;

int _envInt(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

Future<void> main() async {
  final bodyBytes = _envInt('BENCH_BODY_MIB', 64) * 1024 * 1024;
  final warmupRounds = _envInt('BENCH_WARMUP', 2);
  final rounds = _envInt('BENCH_ROUNDS', 9);

  final dllPath =
      Platform.environment['RHTTP_DLL'] ?? 'rust/target/debug/rhttp.dll';
  if (!File(dllPath).existsSync()) {
    _fail(
      'native library not found at $dllPath '
      '(build it with `cargo build -p rhttp --lib` in packages/rhttp/rust)',
    );
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dllPath));

  final server = await _startServer(bodyBytes);
  final url = 'http://127.0.0.1:${server.port}/payload';
  final client = await registerClient(
    settings: await ClientSettings.default_(),
  );

  Future<double> throughFrb() async {
    final watch = Stopwatch()..start();
    var total = 0;
    final response = Completer<HttpResponse>();
    final stream = makeHttpRequestReceiveStream(
      client: client,
      method: const HttpMethod(method: 'GET'),
      url: url,
      onResponse: (value) {
        if (!response.isCompleted) response.complete(value);
      },
      onError: (error) {
        if (!response.isCompleted) response.completeError(error);
      },
      onCancelToken: (_) {},
      cancelable: true,
    );
    await for (final part in stream) {
      total += part.length;
    }
    final head = await response.future;
    watch.stop();
    if (total != bodyBytes) {
      _fail('FRB path read $total bytes, expected $bodyBytes');
    }
    if (head.statusCode != 200) {
      _fail('FRB path got status ${head.statusCode}');
    }
    return _mibPerSecond(bodyBytes, watch.elapsedMicroseconds);
  }

  Future<double> throughDartIo() async {
    final httpClient = HttpClient();
    final watch = Stopwatch()..start();
    var total = 0;
    try {
      final request = await httpClient.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        _fail('dart:io path got status ${response.statusCode}');
      }
      await for (final part in response) {
        total += part.length;
      }
    } finally {
      httpClient.close(force: true);
    }
    watch.stop();
    if (total != bodyBytes) {
      _fail('dart:io path read $total bytes, expected $bodyBytes');
    }
    return _mibPerSecond(bodyBytes, watch.elapsedMicroseconds);
  }

  _log(
    'Payload: ${bodyBytes ~/ (1024 * 1024)} MiB in '
    '${bodyBytes ~/ _chunkBytes} chunks over 127.0.0.1',
  );
  _log('Warmup: $warmupRounds rounds each, then $rounds interleaved rounds');

  for (var i = 0; i < warmupRounds; i++) {
    await throughFrb();
    await throughDartIo();
    _log('warmup ${i + 1}/$warmupRounds done');
  }

  final frb = <double>[];
  final dartIo = <double>[];
  for (var i = 0; i < rounds; i++) {
    final viaFrb = await throughFrb();
    final viaIo = await throughDartIo();
    frb.add(viaFrb);
    dartIo.add(viaIo);
    _log(
      'round ${i + 1}/$rounds   '
      'frb ${viaFrb.toStringAsFixed(1)}   '
      'dart:io ${viaIo.toStringAsFixed(1)}',
    );
  }

  _report('frb (Dart host)', frb);
  _report('dart:io HttpClient', dartIo);

  await server.close(force: true);

  // The FRB runtime keeps native threads alive after `main` returns, so the
  // process would sit there instead of exiting and the caller would wait on it
  // forever. Flush first: without a terminal, stdout is buffered.
  await stdout.flush();
  exit(0);
}

Future<HttpServer> _startServer(int bodyBytes) async {
  final block = Uint8List(_chunkBytes);
  for (var i = 0; i < _chunkBytes; i++) {
    block[i] = i % 251;
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    // The length is known, same as the Kotlin host, so the body goes out with
    // `Content-Length` rather than chunked framing.
    response.contentLength = bodyBytes;
    response.bufferOutput = false;
    var remaining = bodyBytes;
    while (remaining > 0) {
      final write = math.min(_chunkBytes, remaining);
      response.add(
        write == _chunkBytes ? block : Uint8List.sublistView(block, 0, write),
      );
      remaining -= write;
    }
    await response.close();
  });
  return server;
}

double _mibPerSecond(int bytes, int microseconds) =>
    (bytes / (1024 * 1024)) / (microseconds / 1000000);

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

void _report(String label, List<double> values) {
  final median = _median(values);
  final low = values.reduce(math.min);
  final high = values.reduce(math.max);
  _log(
    '${label.padRight(22)} median ${median.toStringAsFixed(1)} MiB/s   '
    'range ${low.toStringAsFixed(1)} .. ${high.toStringAsFixed(1)}',
  );
}

void _log(String message) => stdout.writeln(message);

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
