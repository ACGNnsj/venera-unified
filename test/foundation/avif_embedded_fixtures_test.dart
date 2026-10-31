import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../integration_test/support/avif_embedded_fixtures.dart';

void main() {
  test('embedded AVIF samples match test/fixtures/avif byte for byte', () {
    for (final sample in avifEmbeddedSamples) {
      final file = File('test/fixtures/avif/${sample.name}');
      expect(file.existsSync(), isTrue, reason: '${sample.name} missing');
      final bytes = file.readAsBytesSync();
      expect(bytes, sample.bytes, reason: '${sample.name} bytes drifted');
      expect(
        base64Encode(bytes),
        sample.base64,
        reason: '${sample.name} base64 drifted',
      );
    }
  });
}
