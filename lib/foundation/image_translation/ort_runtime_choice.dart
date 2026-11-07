import 'dart:ffi';
import 'dart:io';

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

  /// Windows ML 自带 DirectML（legacy）EP；随包分发的那份是纯 CPU。
  String? get executionProvider => isWindowsMl ? 'DML' : null;
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
    var directories = Directory(windowsAppsDirectory)
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map((directory) {
          return directory.uri.pathSegments.where((s) => s.isNotEmpty).last;
        })
        .toList();
    var picked = pickWindowsMlPackage(
      directories,
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
    // 受限账户可能列不出 WindowsApps；退回随包分发的那份，功能照旧可用。
    return const OrtRuntimeChoice.bundled();
  }
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
