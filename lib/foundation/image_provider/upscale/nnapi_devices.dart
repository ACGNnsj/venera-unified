import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// NNAPI 设备类型，取值对齐 NDK `ANeuralNetworksDevice_getType`。
enum NnapiDeviceKind { unknown, cpu, gpu, accelerator, other }

/// NDK 返回的整数类型码 -> [NnapiDeviceKind]。
NnapiDeviceKind nnapiDeviceKindFromCode(int code) => switch (code) {
  1 => NnapiDeviceKind.cpu,
  2 => NnapiDeviceKind.gpu,
  3 => NnapiDeviceKind.accelerator,
  4 => NnapiDeviceKind.other,
  _ => NnapiDeviceKind.unknown,
};

/// NNAPI 能枚举到的一台设备（驱动）。
///
/// `name` 是驱动自报的名字，参考实现通常叫 `nnapi-reference`，
/// 厂商驱动形如 `qti-gpu`、`qti-default`。
class NnapiDevice {
  const NnapiDevice({required this.name, required this.kind});

  final String name;
  final NnapiDeviceKind kind;

  /// 是否为参考实现（CPU 驱动）。
  ///
  /// NDK 里参考驱动固定叫 `nnapi-reference`；部分平台会把它报成 GPU 类型，
  /// 只看类型会把「没有加速器」误判成「有 GPU」。
  bool get isReference => name.toLowerCase().contains('reference');

  /// GPU / NPU 驱动；参考实现与 CPU 驱动都不算加速。
  bool get isHardware =>
      (kind == NnapiDeviceKind.gpu || kind == NnapiDeviceKind.accelerator) &&
      !isReference;

  @override
  String toString() => '${kind.name}:${name.isEmpty ? '?' : name}';
}

/// 一次 NNAPI 探测的结果。
class NnapiInventory {
  const NnapiInventory({
    required this.loadable,
    required this.devices,
    this.error,
  });

  /// 运行时库能否加载。
  final bool loadable;

  /// 枚举到的设备；[loadable] 为 false 时为空。
  final List<NnapiDevice> devices;

  /// 加载/枚举失败的原因，便于日志排查。
  final String? error;

  /// 本机是否有真正的加速设备。
  ///
  /// Android 15 起 NNAPI 废弃、较新系统只留一个 CPU 参考实现（甚至直接删掉
  /// 运行时）：此时建 NNAPI 会话不会报错，但所有节点都会静默落回 CPU。
  bool get hasHardwareAccelerator => devices.any((device) => device.isHardware);

  String describe() =>
      'loadable=$loadable devices=[${devices.join(', ')}]'
      '${error == null ? '' : ' error=$error'}';
}

/// 通过 NNAPI 的 NDK 接口枚举本机设备，判断 NNAPI 是否值得一试。
///
/// 只看「动态库能不能加载」是不够的：Android 17 上库仍在（APEX 里），
/// 服务却没了，NNAPI 会话能建、节点全落 CPU。真正的判据是有没有
/// GPU/NPU 类型的设备。
abstract final class NnapiDevices {
  static NnapiInventory? _cached;

  static NnapiInventory get inventory => _cached ??= _probe();

  static bool get hasHardwareAccelerator => inventory.hasHardwareAccelerator;

  /// 仅测试/诊断用：丢掉缓存，下次重新枚举。
  static void resetCache() => _cached = null;

  static NnapiInventory _probe() {
    if (!Platform.isAndroid) {
      return const NnapiInventory(loadable: false, devices: []);
    }
    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open('libneuralnetworks.so');
    } catch (e) {
      return NnapiInventory(loadable: false, devices: const [], error: '$e');
    }

    final _GetDeviceCount getDeviceCount;
    final _GetDevice getDevice;
    final _DeviceGetType deviceGetType;
    final _DeviceGetName deviceGetName;
    try {
      getDeviceCount = lib.lookupFunction<_GetDeviceCountC, _GetDeviceCount>(
        'ANeuralNetworks_getDeviceCount',
      );
      getDevice = lib.lookupFunction<_GetDeviceC, _GetDevice>(
        'ANeuralNetworks_getDevice',
      );
      deviceGetType = lib.lookupFunction<_DeviceGetTypeC, _DeviceGetType>(
        'ANeuralNetworksDevice_getType',
      );
      deviceGetName = lib.lookupFunction<_DeviceGetNameC, _DeviceGetName>(
        'ANeuralNetworksDevice_getName',
      );
    } catch (e) {
      // Android 9 以下没有这些符号；按不可用处理。
      return NnapiInventory(loadable: true, devices: const [], error: '$e');
    }

    final countPtr = calloc<Uint32>();
    final devicePtr = calloc<Pointer<Void>>();
    final typePtr = calloc<Int32>();
    final namePtr = calloc<Pointer<Uint8>>();
    try {
      if (getDeviceCount(countPtr) != 0) {
        return const NnapiInventory(
          loadable: true,
          devices: [],
          error: 'getDeviceCount failed',
        );
      }
      final devices = <NnapiDevice>[];
      for (var i = 0; i < countPtr.value; i++) {
        if (getDevice(i, devicePtr) != 0 || devicePtr.value.address == 0) {
          continue;
        }
        final device = devicePtr.value;
        var kind = NnapiDeviceKind.unknown;
        if (deviceGetType(device, typePtr) == 0) {
          kind = nnapiDeviceKindFromCode(typePtr.value);
        }
        var name = '';
        if (deviceGetName(device, namePtr) == 0 && namePtr.value.address != 0) {
          name = _readCString(namePtr.value);
        }
        devices.add(NnapiDevice(name: name, kind: kind));
      }
      return NnapiInventory(loadable: true, devices: devices);
    } finally {
      calloc.free(countPtr);
      calloc.free(devicePtr);
      calloc.free(typePtr);
      calloc.free(namePtr);
    }
  }

  static String _readCString(Pointer<Uint8> pointer) {
    final bytes = <int>[];
    for (var i = 0; i < 256; i++) {
      final byte = pointer[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    return String.fromCharCodes(bytes);
  }
}

typedef _GetDeviceCountC = Int32 Function(Pointer<Uint32>);
typedef _GetDeviceCount = int Function(Pointer<Uint32>);
typedef _GetDeviceC = Int32 Function(Uint32, Pointer<Pointer<Void>>);
typedef _GetDevice = int Function(int, Pointer<Pointer<Void>>);
typedef _DeviceGetTypeC = Int32 Function(Pointer<Void>, Pointer<Int32>);
typedef _DeviceGetType = int Function(Pointer<Void>, Pointer<Int32>);
typedef _DeviceGetNameC =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Uint8>>);
typedef _DeviceGetName = int Function(Pointer<Void>, Pointer<Pointer<Uint8>>);
