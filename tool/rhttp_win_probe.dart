// Windows desktop probe: stream a >=1 GB payload through rhttp and prove
// the download completes with bounded memory. Mirrors
// integration_test/rhttp_large_stream_test.dart (Android gate) but runs as a
// plain Release app entrypoint like tool/avif_device_probe.dart.
//
// Server: D:\venera\.scratch\tmp\bigsrv.dart (port 8111, ?ms= pacing).
// Env: RHTTP_BASE (default http://127.0.0.1:8111),
//      RHTTP_PATH (default /download),
//      RHTTP_PACE_MS (default 0, appended as ?ms=),
//      RHTTP_PROBE_LOG (default D:\venera\.scratch\tmp\rhttp-win-probe.log).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

const int _totalBytes = 1200 * 1024 * 1024;
const int _stepBytes = 128 * 1024 * 1024;

/// SHA-256 of [_totalBytes] zero bytes, which is what bigsrv serves.
const String _expectedSha256 =
    '8213dc000104735271db2579aa28419f6b9b6f2509f97dc246a4c6ee681f4ff5';

void main() {
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final List<String> _lines = [];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  static final RandomAccessFile _probeLog = (() {
    final path =
        Platform.environment['RHTTP_PROBE_LOG'] ??
        'D:\\venera\\.scratch\\tmp\\rhttp-win-probe.log';
    return (File(path)..writeAsStringSync('')).openSync(mode: FileMode.append);
  })();

  void _log(Map<String, Object?> payload) {
    final line = 'RHTTP_PROBE ${jsonEncode(payload)}';
    debugPrint(line);
    _probeLog.writeStringSync('$line\n');
    _probeLog.flushSync();
    setState(() => _lines.add(line));
  }

  Future<void> _run() async {
    final base = Platform.environment['RHTTP_BASE'] ?? 'http://127.0.0.1:8111';
    final path = Platform.environment['RHTTP_PATH'] ?? '/download';
    final paceMs =
        int.tryParse(Platform.environment['RHTTP_PACE_MS'] ?? '') ?? 0;
    final url = paceMs > 0 ? '$base$path?ms=$paceMs' : base + path;
    final baseline = ProcessInfo.currentRss;
    _log({'stage': 'start', 'url': url, 'rssBytes': baseline});
    try {
      await rhttp.Rhttp.init();
      final watch = Stopwatch()..start();
      final hasher = await _Hasher.start();
      final response =
          await rhttp.Rhttp.request(
                method: rhttp.HttpMethod.get,
                url: url,
                expectBody: rhttp.HttpExpectBody.stream,
              )
              as rhttp.HttpStreamResponse;
      _log({
        'stage': 'response',
        'status': response.statusCode.toInt(),
        'elapsedMs': watch.elapsedMilliseconds,
      });
      var received = 0;
      var peak = baseline;
      var next = _stepBytes;
      await for (final chunk in response.body) {
        received += chunk.length;
        hasher.add(chunk);
        final rss = ProcessInfo.currentRss;
        if (rss > peak) peak = rss;
        if (received >= next) {
          _log({
            'stage': 'progress',
            'bytes': received,
            'elapsedMs': watch.elapsedMilliseconds,
            'rssBytes': rss,
          });
          next += _stepBytes;
        }
      }
      final elapsedMs = watch.elapsedMilliseconds;
      final actualSha256 = await hasher.finish();
      _log({
        'stage': 'done',
        'bytes': received,
        'totalBytes': _totalBytes,
        'sha256Matches': actualSha256 == _expectedSha256,
        'peakRssDeltaBytes': peak - baseline,
        'elapsedMs': elapsedMs,
        'mibPerSecond': received / 1024 / 1024 / (elapsedMs / 1000),
      });
    } catch (e) {
      _log({'stage': 'failed', 'error': e.toString()});
    }
    debugPrint('RHTTP_PROBE_DONE');
    _probeLog.writeStringSync('RHTTP_PROBE_DONE\n');
    _probeLog.flushSync();
    setState(() {
      _done = true;
      _lines.add('RHTTP_PROBE_DONE');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _done ? 'DONE' : 'RUNNING...',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final line in _lines)
                SelectableText(line, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Streams received chunks into a helper isolate so SHA-256 of 1.2 GB does
/// not block the UI isolate.
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
  port.listen((message) {
    if (message is Uint8List) {
      hasher.add(message);
    } else if (message is String) {
      hasher.close();
      toMain.send(<Object>[sink.value.toString()]);
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
