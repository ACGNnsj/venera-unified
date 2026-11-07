import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/image_provider/upscale/nnapi_devices.dart';

void main() {
  group('nnapiDeviceKindFromCode', () {
    test('maps the NDK type codes', () {
      expect(nnapiDeviceKindFromCode(0), NnapiDeviceKind.unknown);
      expect(nnapiDeviceKindFromCode(1), NnapiDeviceKind.cpu);
      expect(nnapiDeviceKindFromCode(2), NnapiDeviceKind.gpu);
      expect(nnapiDeviceKindFromCode(3), NnapiDeviceKind.accelerator);
      expect(nnapiDeviceKindFromCode(4), NnapiDeviceKind.other);
    });

    test('unknown codes stay unknown', () {
      expect(nnapiDeviceKindFromCode(-1), NnapiDeviceKind.unknown);
      expect(nnapiDeviceKindFromCode(99), NnapiDeviceKind.unknown);
    });
  });

  group('NnapiInventory.hasHardwareAccelerator', () {
    test('cpu reference implementation does not count', () {
      const inventory = NnapiInventory(
        loadable: true,
        devices: [
          NnapiDevice(name: 'nnapi-reference', kind: NnapiDeviceKind.cpu),
        ],
      );
      expect(inventory.hasHardwareAccelerator, isFalse);
    });

    test('reference driver reported as gpu still does not count', () {
      const inventory = NnapiInventory(
        loadable: true,
        devices: [
          NnapiDevice(name: 'nnapi-reference', kind: NnapiDeviceKind.gpu),
        ],
      );
      expect(inventory.hasHardwareAccelerator, isFalse);
    });

    test('gpu or npu devices count', () {
      const gpu = NnapiInventory(
        loadable: true,
        devices: [NnapiDevice(name: 'qti-gpu', kind: NnapiDeviceKind.gpu)],
      );
      const npu = NnapiInventory(
        loadable: true,
        devices: [
          NnapiDevice(name: 'qti-default', kind: NnapiDeviceKind.accelerator),
        ],
      );
      expect(gpu.hasHardwareAccelerator, isTrue);
      expect(npu.hasHardwareAccelerator, isTrue);
    });

    test('unloadable runtime has no devices', () {
      const inventory = NnapiInventory(loadable: false, devices: []);
      expect(inventory.hasHardwareAccelerator, isFalse);
      expect(inventory.describe(), 'loadable=false devices=[]');
    });
  });

  group('NnapiInventory.describe', () {
    test('lists devices and keeps the error', () {
      const inventory = NnapiInventory(
        loadable: true,
        devices: [
          NnapiDevice(name: 'nnapi-reference', kind: NnapiDeviceKind.cpu),
          NnapiDevice(name: '', kind: NnapiDeviceKind.unknown),
        ],
        error: 'boom',
      );
      final text = inventory.describe();
      expect(text, contains('cpu:nnapi-reference'));
      expect(text, contains('unknown:?'));
      expect(text, contains('error=boom'));
      expect(
        const NnapiDevice(name: '', kind: NnapiDeviceKind.gpu).toString(),
        'gpu:?',
      );
    });
  });
}
