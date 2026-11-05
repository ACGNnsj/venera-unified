// Device-side AVIF codec probe. Run on a device/emulator with:
//   flutter test integration_test/avif_codec_probe_test.dart -d <deviceId>
// The host-VM probe in tool/avif_codec_probe.dart cannot exercise a device engine,
// so this file carries the samples as base64 (see support/avif_embedded_fixtures.dart).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/avif_embedded_fixtures.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('report device AVIF codec capabilities', (tester) async {
    for (final sample in avifEmbeddedSamples) {
      ui.Codec? codec;
      final stopwatch = Stopwatch()..start();
      final result = <String, Object?>{
        'sample': sample.name,
        'platform': Platform.operatingSystem,
        'operatingSystemVersion': Platform.operatingSystemVersion,
        'supported': false,
      };
      try {
        codec = await ui.instantiateImageCodec(sample.bytes);
        final frames = <String>[];
        for (var index = 0; index < codec.frameCount; index++) {
          final frame = await codec.getNextFrame();
          try {
            frames.add('${frame.image.width}x${frame.image.height}');
            if (index == 0) {
              result.addAll({
                'supported': true,
                'width': frame.image.width,
                'height': frame.image.height,
                'frameCount': codec.frameCount,
              });
            }
          } finally {
            frame.image.dispose();
          }
        }
        result['frames'] = frames;
      } catch (error) {
        result['error'] = error.toString();
      } finally {
        codec?.dispose();
        stopwatch.stop();
        result['elapsedMs'] = stopwatch.elapsedMilliseconds;
      }
      // Probe output is the deliverable; failures are recorded, not asserted.
      // ignore: avoid_print
      print('AVIF_PROBE ${jsonEncode(result)}');
    }
  });
}
