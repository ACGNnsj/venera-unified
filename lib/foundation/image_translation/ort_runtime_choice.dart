import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Picks the ONNX Runtime binary this process should use.
///
/// Windows 自带一份 Windows ML 运行时：Windows App Runtime 框架包里就有微软自编的
/// ONNX Runtime 与 DirectML。直接加载它做推理，等于拿到 GPU 加速而不用在安装包里
/// 多带一份约 38 MB 的运行库，并且运行库随 Windows 更新。框架包不存在（或当前账户
/// 读不到 WindowsApps）时退回 flutter_onnxruntime 插件随包分发的那份（纯 CPU）。
///
/// 这里只回答“用哪个 DLL、要不要请求 DML”，不 import UI 或网络模块，便于单测。
class OrtRuntimeChoice {
  const OrtRuntimeChoice.bundled() : windowsMlDllPath = null;

  const OrtRuntimeChoice.windowsMl(this.windowsMlDllPath);

  /// 框架包里 `onnxruntime.dll` 的绝对路径；null 表示用随包分发的那份。
  final String? windowsMlDllPath;

  bool get isWindowsMl => windowsMlDllPath != null;

  /// 会话默认要挂的执行提供者，按尝试顺序排列；空表示不挂、走纯 CPU。
  ///
  /// Windows ML 那份运行时内置 DirectML（legacy）；Android 的 AAR 编进了
  /// XNNPACK（CPU 侧的加速内核）。候选不保证每台设备都能建起来，由
  /// [OrtFfiSession.open] 逐个尝试并在失败时退到下一个，最后落到 CPU。
  List<String> get executionProviders {
    if (isWindowsMl) {
      return const ['DML'];
    }
    return executionProvidersForPlatform(Platform.operatingSystem);
  }
}

/// 各平台随包 ONNX Runtime 里可用的执行提供者（按尝试顺序）。
///
/// 只有真正编进了该 EP 的构建才挂得上；不支持时 ORT 会明确报错，由调用方回退。
/// Android 用 XNNPACK：CPU 侧的加速内核，数值行为与默认 CPU EP 接近，是随包
/// 运行库真正可用的加速通道；其它平台目前都只有默认 CPU EP。
///
/// 不挂 NNAPI：Google 从 Android 15 起弃用 NNAPI，实测 SM-S9480 / Android 17 /
/// SDK 37 已经拿不到 `libneuralnetworks.so`，NNAPI EP 仍有导出符号、会话也能
/// 建起来，但所有节点都静默落回 CPU——没有加速，还把 XNNPACK 挡在后面。要 NPU
/// 得换 ONNX Runtime 的 QNN EP（Qualcomm），它要求随包分发 libQnnHtp/libQnnSystem
/// 并受 Qualcomm 许可约束，当前包里没有。
List<String> executionProvidersForPlatform(String platform) {
  if (platform == 'android') {
    return const ['XNNPACK'];
  }
  return const [];
}

/// 框架包的安装根目录。
const windowsAppsDirectory = r'C:\Program Files\WindowsApps';

final _windowsAppRuntimePackage = RegExp(
  r'^Microsoft\.WindowsAppRuntime\.(\d+)(?:\.(\d+))?_([0-9.]+)_(x64|arm64)__8wekyb3d8bbwe$',
);

/// 在已安装的 Windows App Runtime 框架包里挑版本最高的一个可用的。
///
/// [packageDirectories] 是 [windowsAppsDirectory] 下的目录名（不是完整路径）；
/// [hasRuntimeLibrary] 判断候选目录里是否真的有 `onnxruntime.dll`。两者都可注入，
/// 纯函数，便于单测。
String? pickWindowsMlPackage(
  Iterable<String> packageDirectories, {
  required String architecture,
  required bool Function(String packageDirectory) hasRuntimeLibrary,
}) {
  String? best;
  List<int>? bestVersion;
  for (var name in packageDirectories) {
    var match = _windowsAppRuntimePackage.firstMatch(name);
    if (match == null || match.group(4) != architecture) {
      continue;
    }
    if (!hasRuntimeLibrary(name)) {
      continue;
    }
    var version = <int>[
      int.parse(match.group(1)!),
      int.parse(match.group(2) ?? '0'),
      ...match.group(3)!.split('.').map(int.parse),
    ];
    if (bestVersion == null || _compareVersions(version, bestVersion) > 0) {
      best = name;
      bestVersion = version;
    }
  }
  return best;
}

int _compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) {
      return a[i].compareTo(b[i]);
    }
  }
  return a.length.compareTo(b.length);
}

/// 解析当前机器上该用哪份 ONNX Runtime（Windows 之外一律用随包分发的那份）。
OrtRuntimeChoice resolveOrtRuntime() {
  if (!Platform.isWindows) {
    return const OrtRuntimeChoice.bundled();
  }
  try {
    var picked = pickWindowsMlPackage(
      _installedPackageNames(),
      architecture: _currentArchitecture(),
      hasRuntimeLibrary: (name) {
        return File(_runtimeLibraryPath(name)).existsSync();
      },
    );
    if (picked == null) {
      return const OrtRuntimeChoice.bundled();
    }
    return OrtRuntimeChoice.windowsMl(_runtimeLibraryPath(picked));
  } catch (_) {
    // 受限账户既列不出 WindowsApps 也读不到包仓库；退回随包分发的那份。
    return const OrtRuntimeChoice.bundled();
  }
}

/// 已安装的框架包目录名。
///
/// 优先列 [windowsAppsDirectory]，但普通账户通常没有该目录的「列出」权限
/// （OS Error 5），这时改读 HKCU 下的 AppModel 包仓库：那里的子键名就是包全名，
/// 与 WindowsApps 下的目录名一致。仓库里可能留着已卸载的条目，
/// 所以候选仍要过 [pickWindowsMlPackage] 的 hasRuntimeLibrary 复核。
List<String> _installedPackageNames() {
  try {
    var names = Directory(windowsAppsDirectory)
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map((directory) {
          return directory.uri.pathSegments.where((s) => s.isNotEmpty).last;
        })
        .toList();
    if (names.isNotEmpty) {
      return names;
    }
  } catch (_) {
    // 列不出来就走注册表。
  }
  return _registryPackageNames();
}

const _packagesKey =
    r'Software\Classes\Local Settings\Software\Microsoft\Windows\'
    r'CurrentVersion\AppModel\Repository\Packages';

const _hkeyCurrentUser = 0x80000001;

const _keyRead = 0x20019;

const _maxKeyLength = 256;

typedef _RegOpenKeyExWNative =
    Int32 Function(
      IntPtr hKey,
      Pointer<Utf16> lpSubKey,
      Uint32 ulOptions,
      Uint32 samDesired,
      Pointer<IntPtr> phkResult,
    );

typedef _RegOpenKeyExWDart =
    int Function(
      int hKey,
      Pointer<Utf16> lpSubKey,
      int ulOptions,
      int samDesired,
      Pointer<IntPtr> phkResult,
    );

typedef _RegEnumKeyExWNative =
    Int32 Function(
      IntPtr hKey,
      Uint32 dwIndex,
      Pointer<Utf16> lpName,
      Pointer<Uint32> lpcchName,
      Pointer<Uint32> lpReserved,
      Pointer<Utf16> lpClass,
      Pointer<Uint32> lpcchClass,
      Pointer<Void> lpftLastWriteTime,
    );

typedef _RegEnumKeyExWDart =
    int Function(
      int hKey,
      int dwIndex,
      Pointer<Utf16> lpName,
      Pointer<Uint32> lpcchName,
      Pointer<Uint32> lpReserved,
      Pointer<Utf16> lpClass,
      Pointer<Uint32> lpcchClass,
      Pointer<Void> lpftLastWriteTime,
    );

typedef _RegCloseKeyNative = Int32 Function(IntPtr hKey);

typedef _RegCloseKeyDart = int Function(int hKey);

/// 读 AppModel 包仓库里当前用户的包全名（WindowsApps 列不出来时的后备）。
List<String> _registryPackageNames() {
  DynamicLibrary advapi;
  try {
    advapi = DynamicLibrary.open('advapi32.dll');
  } catch (_) {
    return const [];
  }
  var openKey = advapi.lookupFunction<_RegOpenKeyExWNative, _RegOpenKeyExWDart>(
    'RegOpenKeyExW',
  );
  var enumKey = advapi.lookupFunction<_RegEnumKeyExWNative, _RegEnumKeyExWDart>(
    'RegEnumKeyExW',
  );
  var closeKey = advapi.lookupFunction<_RegCloseKeyNative, _RegCloseKeyDart>(
    'RegCloseKey',
  );

  var subKey = _packagesKey.toNativeUtf16();
  var keyOut = calloc<IntPtr>();
  var names = <String>[];
  try {
    if (openKey(_hkeyCurrentUser, subKey, 0, _keyRead, keyOut) != 0) {
      return names;
    }
    var key = keyOut.value;
    var nameSize = calloc<Uint32>();
    var nameBuffer = calloc<Uint16>(_maxKeyLength);
    try {
      for (var index = 0; ; index++) {
        nameSize.value = _maxKeyLength;
        var status = enumKey(
          key,
          index,
          nameBuffer.cast<Utf16>(),
          nameSize,
          nullptr,
          nullptr,
          nullptr,
          nullptr,
        );
        if (status != 0) {
          break;
        }
        names.add(
          nameBuffer.cast<Utf16>().toDartString(length: nameSize.value),
        );
      }
    } finally {
      calloc.free(nameBuffer);
      calloc.free(nameSize);
      closeKey(key);
    }
  } finally {
    calloc.free(subKey);
    calloc.free(keyOut);
  }
  return names;
}

String _runtimeLibraryPath(String packageDirectory) {
  return '$windowsAppsDirectory${Platform.pathSeparator}$packageDirectory'
      '${Platform.pathSeparator}onnxruntime.dll';
}

String _currentArchitecture() {
  switch (Abi.current()) {
    case Abi.windowsX64:
      return 'x64';
    case Abi.windowsArm64:
      return 'arm64';
    default:
      return 'x64';
  }
}
