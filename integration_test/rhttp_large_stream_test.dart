// Device-side rhttp large-payload probing.
//
// The payload is served by the host machine: D:\venera\.scratch\tmp\bigsrv.dart
// listens on port 8111 and can pace its writes with ?ms=<delay per 256 KiB chunk>
// and cut the connection after ?abortAt=<bytes>. Point the probe at it with
// --dart-define=RHTTP_BASE=http://<host>:8111 (Wi-Fi or adb reverse).
//
// Every test is skipped unless RHTTP_BASE is supplied, so CI never runs this.
//
// Measured on a Galaxy S26 Ultra: at full speed the device resets the connection
// around 150 MB, but with ?ms=8 the whole 1.2 GB arrives in ~76 s (15.8 MiB/s,
// peak RSS delta 35.9 MiB), so the streaming path itself is sound. The digest is
// computed in a helper isolate: hashing 1.2 GB on the main isolate starves the
// VM service and the integration_test harness drops the connection mid-run.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

const int _totalBytes = 1200 * 1024 * 1024;
const int _stepBytes = 32 * 1024 * 1024;
const int _memoryBudgetBytes = 256 * 1024 * 1024;

/// SHA-256 of [_totalBytes] zero bytes, which is what the host server serves.
const String _expectedSha256 =
    '8213dc000104735271db2579aa28419f6b9b6f2509f97dc246a4c6ee681f4ff5';

const String _path = String.fromEnvironment(
  'RHTTP_PATH',
  defaultValue: '/download',
);

const String _base = String.fromEnvironment('RHTTP_BASE');

/// Host-side raw socket server that answers with Content-Length 1.2 GB and
/// destroys the connection after 64 MiB (D:\venera\.scratch\tmp\abortsrv.dart).
/// dart:io's HttpServer cannot cut a response once its headers are flushed.
const String _abortUrl = String.fromEnvironment(
  'RHTTP_ABORT_URL',
  defaultValue: 'http://192.168.2.94:8112/abort',
);

late RandomAccessFile _logFile;

void _openLog() {
  final dir = Directory('${Directory.systemTemp.path}/rhttp_probe');
  dir.createSync(recursive: true);
  _logFile = (File(
    '${dir.path}/probe.log',
  )..writeAsStringSync('')).openSync(mode: FileMode.append);
}

void _report(Map<String, Object?> payload) {
  final line = 'RHTTP_PROBE ${jsonEncode(payload)}';
  // ignore: avoid_print
  print(line);
  _logFile.writeStringSync('$line\n');
  _logFile.flushSync();
}

Future<void>? _rhttpReady;

/// flutter_rust_bridge refuses a second init, and all three tests share one
/// process.
Future<void> _ensureRhttp() => _rhttpReady ??= rhttp.Rhttp.init();

Future<rhttp.HttpStreamResponse> _openStream(String url) async {
  final response = await rhttp.Rhttp.request(
    method: rhttp.HttpMethod.get,
    url: url,
    expectBody: rhttp.HttpExpectBody.stream,
  );
  return response as rhttp.HttpStreamResponse;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final skipReason = _base.isEmpty
      ? 'set --dart-define=RHTTP_BASE=http://<host>:8111 to run this probe'
      : null;

  test(
    'rhttp streams a payload above 1 GB without buffering it',
    () async {
      _openLog();
      final baseline = ProcessInfo.currentRss;
      _report({
        'stage': 'start',
        'base': _base,
        'path': _path,
        'rssBytes': baseline,
      });

      await _ensureRhttp();
      final watch = Stopwatch()..start();
      final hasher = await _Hasher.start();
      final response = await _openStream('$_base$_path');
      _report({
        'stage': 'response',
        'status': response.statusCode.toInt(),
        'elapsedMs': watch.elapsedMilliseconds,
      });

      var received = 0;
      var peak = baseline;
      var next = _stepBytes;
      final ticker = Timer.periodic(const Duration(seconds: 5), (_) {
        _report({
          'stage': 'tick',
          'bytes': received,
          'elapsedMs': watch.elapsedMilliseconds,
          'rssBytes': ProcessInfo.currentRss,
        });
      });

      await for (final chunk in response.body) {
        received += chunk.length;
        hasher.add(chunk);
        final rss = ProcessInfo.currentRss;
        if (rss > peak) peak = rss;
        if (received >= next) {
          _report({
            'stage': 'progress',
            'bytes': received,
            'elapsedMs': watch.elapsedMilliseconds,
            'rssBytes': rss,
          });
          next += _stepBytes;
        }
      }
      ticker.cancel();

      final elapsedMs = watch.elapsedMilliseconds;
      final actualSha256 = await hasher.finish();
      _report({
        'stage': 'done',
        'bytes': received,
        'totalBytes': _totalBytes,
        'sha256': actualSha256,
        'sha256Matches': actualSha256 == _expectedSha256,
        'peakRssDeltaBytes': peak - baseline,
        'elapsedMs': elapsedMs,
        'mibPerSecond': received / 1024 / 1024 / (elapsedMs / 1000),
      });

      expect(received, _totalBytes);
      expect(actualSha256, _expectedSha256);
      expect(peak - baseline, lessThan(_memoryBudgetBytes));

      final upWatch = Stopwatch()..start();
      final upload =
          await rhttp.Rhttp.request(
                method: rhttp.HttpMethod.post,
                url: '$_base/upload',
                body: rhttp.HttpBody.stream(
                  _zeroStream(_totalBytes),
                  length: _totalBytes,
                ),
                expectBody: rhttp.HttpExpectBody.bytes,
              )
              as rhttp.HttpBytesResponse;
      final uploaded =
          (jsonDecode(utf8.decode(upload.body)) as Map)['received'];
      _report({
        'stage': 'upload',
        'bytes': uploaded,
        'totalBytes': _totalBytes,
        'elapsedMs': upWatch.elapsedMilliseconds,
      });
      expect(uploaded, _totalBytes);
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: skipReason,
  );

  test(
    'rhttp cancels a transfer mid-stream and stays usable',
    () async {
      _openLog();
      await _ensureRhttp();
      final response = await _openStream('$_base$_path');
      final first = Completer<void>();
      var received = 0;
      final subscription = response.body.listen(
        (chunk) {
          received += chunk.length;
          if (received >= _stepBytes && !first.isCompleted) first.complete();
        },
        onError: (Object error) {
          if (!first.isCompleted) first.completeError(error);
        },
        cancelOnError: false,
      );
      await first.future.timeout(const Duration(minutes: 2));
      await subscription.cancel();
      _report({'stage': 'cancel', 'bytesBeforeCancel': received});

      final second = await _openStream('$_base$_path');
      final resumed = Completer<void>();
      var afterCancel = 0;
      final secondSub = second.body.listen((chunk) {
        afterCancel += chunk.length;
        if (afterCancel >= 1024 * 1024 && !resumed.isCompleted)
          resumed.complete();
      });
      await resumed.future.timeout(const Duration(minutes: 2));
      await secondSub.cancel();
      _report({'stage': 'cancel-recover', 'bytesAfterRestart': afterCancel});
      expect(afterCancel, greaterThanOrEqualTo(1024 * 1024));
    },
    timeout: const Timeout(Duration(minutes: 6)),
    skip: skipReason,
  );

  test(
    'rhttp surfaces an interrupted transfer as an error',
    () async {
      _openLog();
      await _ensureRhttp();
      final watch = Stopwatch()..start();
      final response = await _openStream(_abortUrl);
      var received = 0;
      Object? failure;
      try {
        await for (final chunk in response.body) {
          received += chunk.length;
        }
      } catch (error) {
        failure = error;
      }
      _report({
        'stage': 'interrupt',
        'bytes': received,
        'elapsedMs': watch.elapsedMilliseconds,
        'failureType': failure?.runtimeType.toString(),
        'failure': failure?.toString(),
      });
      expect(received, lessThan(_totalBytes));
      expect(failure, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 6)),
    skip: skipReason,
  );
}

/// Streams received chunks into a helper isolate so the main isolate keeps
/// answering the VM service while 1.2 GB of SHA-256 is being computed.
class _Hasher {
  _Hasher._(this._fromWorker, this._toWorker, this._done);

  final ReceivePort _fromWorker;
  final SendPort _toWorker;
  final Completer<String> _done;

  static Future<_Hasher> start() async {
    final fromWorker = ReceivePort();
    final ready = Completer<SendPort>();
    final done = Completer<String>();
    fromWorker.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is List) {
        done.complete(message.first! as String);
      }
    });
    await Isolate.spawn(_hasherMain, fromWorker.sendPort);
    return _Hasher._(fromWorker, await ready.future, done);
  }

  void add(List<int> chunk) {
    _toWorker.send(Uint8List.fromList(chunk));
  }

  Future<String> finish() async {
    _toWorker.send('finish');
    final value = await _done.future;
    _fromWorker.close();
    return value;
  }
}

void _hasherMain(SendPort toMain) {
  final port = ReceivePort();
  toMain.send(port.sendPort);
  final sink = _DigestSink();
  final hasher = sha256.startChunkedConversion(sink);
  var bytes = 0;
  port.listen((message) {
    if (message is Uint8List) {
      hasher.add(message);
      bytes += message.length;
    } else if (message is String) {
      hasher.close();
      toMain.send(<Object>[sink.value.toString(), bytes]);
      port.close();
    }
  });
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

Stream<List<int>> _zeroStream(int total) async* {
  const chunkBytes = 256 * 1024;
  final chunk = List<int>.filled(chunkBytes, 0);
  var sent = 0;
  while (sent < total) {
    final n = total - sent < chunkBytes ? total - sent : chunkBytes;
    yield n == chunkBytes ? chunk : chunk.sublist(0, n);
    sent += n;
    await Future<void>.delayed(Duration.zero);
  }
}
