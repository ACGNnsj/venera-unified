// Manual device probe: reports AVIF decode results for the six embedded
// samples through both the raw engine codec and the app image pipeline.
//
// Build and run (Android arm64):
//   flutter build apk --debug --target-platform android-arm64 --no-pub
//     -t tool/avif_device_probe.dart
//   adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
//   adb shell am start -n io.github.venera.unified/com.github.cyrilpeng.veneranext.MainActivity
//   adb logcat -s flutter | grep AVIF_PROBE
//
// Results are printed as one AVIF_PROBE json line per sample plus a final
// AVIF_PROBE_DONE line, and are also rendered on screen for a screenshot.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../integration_test/support/avif_embedded_fixtures.dart';
import 'package:venera_unified/foundation/image_processing.dart' as processing;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final List<String> _lines = <String>[];
  final Map<String, ui.Image> _decoded = <String, ui.Image>{};
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _emit(String line) {
    debugPrint(line);
    _lines.add(line);
    if (mounted) setState(() {});
  }

  Future<void> _run() async {
    _emit(
      'AVIF_PROBE_ENV '
      '${jsonEncode({'platform': Platform.operatingSystem, 'version': Platform.operatingSystemVersion})}',
    );
    for (final sample in <AvifEmbeddedSample>[
      ...avifEmbeddedSamples,
      ..._extraSamples(),
    ]) {
      final record = <String, Object?>{
        'sample': sample.name,
        'engine': await _decodeWithEngine(sample.name, sample.bytes),
        'app': await _decodeThroughApp(sample.bytes),
      };
      _emit('AVIF_PROBE ${jsonEncode(record)}');
    }
    _done = true;
    _emit('AVIF_PROBE_DONE');
  }

  /// Extra samples pushed to the app-private directory by the operator with
  /// `adb push x.avif /data/local/tmp/ && adb shell run-as <pkg> cp ...`.
  /// The directory is optional: missing means only the embedded set runs.
  List<AvifEmbeddedSample> _extraSamples() {
    final dir = Directory(_extraDir);
    if (!dir.existsSync()) return const <AvifEmbeddedSample>[];
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.avif'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return <AvifEmbeddedSample>[
      for (final file in files)
        AvifEmbeddedSample(
          name: file.uri.pathSegments.last,
          sha256: '',
          base64: base64Encode(file.readAsBytesSync()),
        ),
    ];
  }

  static const String _extraDir =
      '/data/data/io.github.venera.unified/files/avif-probe';

  Future<Map<String, Object?>> _decodeWithEngine(
    String name,
    Uint8List bytes,
  ) async {
    final watch = Stopwatch()..start();
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      // Kept alive so the build below can prove the GPU/paint path too.
      _decoded[name] = frame.image;
      try {
        return <String, Object?>{
          'supported': true,
          'width': frame.image.width,
          'height': frame.image.height,
          'frameCount': codec.frameCount,
          'elapsedMs': watch.elapsedMilliseconds,
        };
      } finally {
        // Ownership moved to _decoded; nothing to dispose here.
      }
    } catch (error) {
      return <String, Object?>{
        'supported': false,
        'elapsedMs': watch.elapsedMilliseconds,
        'error': error.toString(),
      };
    } finally {
      codec?.dispose();
      watch.stop();
    }
  }

  Future<Map<String, Object?>> _decodeThroughApp(Uint8List bytes) async {
    final watch = Stopwatch()..start();
    try {
      final image = await processing.Image.decodeImage(bytes);
      return <String, Object?>{
        'supported': true,
        'width': image.width,
        'height': image.height,
        'elapsedMs': watch.elapsedMilliseconds,
      };
    } catch (error) {
      return <String, Object?>{
        'supported': false,
        'elapsedMs': watch.elapsedMilliseconds,
        'error': error.toString(),
      };
    } finally {
      watch.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('AVIF device probe')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text(_done ? 'DONE (${_lines.length} lines)' : 'running...'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in _decoded.entries)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RawImage(
                        image: entry.value,
                        width: 96,
                        height: 96,
                        fit: BoxFit.contain,
                      ),
                      Text(entry.key, style: const TextStyle(fontSize: 8)),
                    ],
                  ),
              ],
            ),
            const Divider(),
            ..._lines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(line, style: const TextStyle(fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
