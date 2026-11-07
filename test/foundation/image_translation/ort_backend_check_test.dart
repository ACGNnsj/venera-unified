import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:venera_unified/foundation/image_translation/ort_backend_check.dart';
import 'package:venera_unified/foundation/image_translation/ort_ffi.dart';

OrtOutput _out(List<double> values, {List<int>? shape}) =>
    OrtOutput(Float32List.fromList(values), shape ?? [values.length]);

void main() {
  group('meanAbsoluteDifference', () {
    test('identical tensors have zero error', () {
      expect(
        meanAbsoluteDifference(
          Float32List.fromList([1, 2, 3]),
          Float32List.fromList([1, 2, 3]),
        ),
        0,
      );
    });

    test('averages per-element absolute error', () {
      expect(
        meanAbsoluteDifference(
          Float32List.fromList([1, 2, 3]),
          Float32List.fromList([1, 4, 3]),
        ),
        closeTo(2 / 3, 1e-9),
      );
    });

    test('length mismatch is untrusted', () {
      expect(
        meanAbsoluteDifference(Float32List(2), Float32List(3)),
        double.infinity,
      );
    });

    test('empty tensors match', () {
      expect(meanAbsoluteDifference(Float32List(0), Float32List(0)), 0);
    });
  });

  group('meanMagnitude', () {
    test('averages absolute values', () {
      expect(
        meanMagnitude(Float32List.fromList([-1, 2, -3])),
        closeTo(2, 1e-9),
      );
    });

    test('empty tensor has zero magnitude', () {
      expect(meanMagnitude(Float32List(0)), 0);
    });
  });

  group('sameTensorShape', () {
    test('identical shapes match', () {
      expect(sameTensorShape([1, 3, 960, 960], [1, 3, 960, 960]), isTrue);
    });

    test('different rank or extents do not match', () {
      expect(sameTensorShape([1, 2], [1, 2, 1]), isFalse);
      expect(sameTensorShape([1, 2], [1, 3]), isFalse);
    });
  });

  group('evaluateAcceleratedOutput', () {
    test('accepts small absolute error', () {
      var check = evaluateAcceleratedOutput(
        provider: 'XNNPACK',
        cpu: _out([0.1, 0.2]),
        accelerated: _out([0.11, 0.21]),
      );
      expect(check.accepted, isTrue);
      expect(check.provider, 'XNNPACK');
      expect(check.mae, closeTo(0.01, 1e-6));
    });

    test('rejects large absolute and relative error', () {
      var check = evaluateAcceleratedOutput(
        provider: 'XNNPACK',
        cpu: _out([1, 1]),
        accelerated: _out([1.1, 1.1]),
      );
      expect(check.accepted, isFalse);
      expect(check.mae, closeTo(0.1, 1e-6));
      expect(check.relativeMae, closeTo(0.1, 1e-6));
      expect(check.describe(), contains('整页回退 CPU'));
    });

    test('accepts magnitude-scaled logits error within relative tolerance', () {
      var check = evaluateAcceleratedOutput(
        provider: 'XNNPACK',
        cpu: _out([10, 10]),
        accelerated: _out([10.1, 10.1]),
      );
      expect(check.accepted, isTrue);
      expect(check.relativeMae, closeTo(0.01, 1e-6));
    });

    test('shape mismatch is untrusted regardless of values', () {
      var check = evaluateAcceleratedOutput(
        provider: 'XNNPACK',
        cpu: _out([0, 0]),
        accelerated: _out([0, 0], shape: [2, 1]),
      );
      expect(check.accepted, isFalse);
      expect(check.mae, double.infinity);
      expect(check.detail, contains('shape'));
    });

    test('zero reference accepts error within absolute tolerance', () {
      var check = evaluateAcceleratedOutput(
        provider: 'XNNPACK',
        cpu: _out([0, 0]),
        accelerated: _out([0.01, 0.01]),
      );
      expect(check.accepted, isTrue);
      expect(check.relativeMae, 0);
    });

    test('zero reference rejects error beyond absolute tolerance', () {
      var check = evaluateAcceleratedOutput(
        provider: 'XNNPACK',
        cpu: _out([0, 0]),
        accelerated: _out([0.5, 0.5]),
      );
      expect(check.accepted, isFalse);
      expect(check.relativeMae, 1);
    });

    test('describe reports provider and per-output detail', () {
      var check = evaluateAcceleratedOutput(
        provider: 'XNNPACK',
        cpu: _out([0.1]),
        accelerated: _out([0.1]),
        outputName: 'logits',
      );
      expect(check.describe(), contains('XNNPACK'));
      expect(check.describe(), contains('logits'));
      expect(check.describe(), contains('与 CPU 参考一致'));
    });
  });
}
