import 'package:flutter_test/flutter_test.dart';

import 'package:venera_unified/foundation/image_translation/ort_runtime_choice.dart';

void main() {
  bool allPresent(String _) => true;

  test('picks the highest Windows App Runtime version that ships ORT', () {
    var picked = pickWindowsMlPackage(
      const [
        'Microsoft.WindowsAppRuntime.1.3_3000.934.1904.0_x64__8wekyb3d8bbwe',
        'Microsoft.WindowsAppRuntime.1.8_8000.836.2153.0_x64__8wekyb3d8bbwe',
        'Microsoft.WindowsAppRuntime.1.8_8000.994.2142.0_x64__8wekyb3d8bbwe',
        'Microsoft.WindowsAppRuntime.1.1_1005.616.1651.0_x64__8wekyb3d8bbwe',
      ],
      architecture: 'x64',
      hasRuntimeLibrary: allPresent,
    );
    expect(
      picked,
      'Microsoft.WindowsAppRuntime.1.8_8000.994.2142.0_x64__8wekyb3d8bbwe',
    );
  });

  test('accepts the single-number family name used by Windows App SDK 2.x', () {
    var picked = pickWindowsMlPackage(
      const [
        'Microsoft.WindowsAppRuntime.1.8_8000.994.2142.0_x64__8wekyb3d8bbwe',
        'Microsoft.WindowsAppRuntime.2_2.5.1.0_x64__8wekyb3d8bbwe',
      ],
      architecture: 'x64',
      hasRuntimeLibrary: allPresent,
    );
    expect(picked, 'Microsoft.WindowsAppRuntime.2_2.5.1.0_x64__8wekyb3d8bbwe');
  });

  test('ignores packages for another architecture', () {
    var picked = pickWindowsMlPackage(
      const [
        'Microsoft.WindowsAppRuntime.1.8_8000.994.2142.0_x86__8wekyb3d8bbwe',
      ],
      architecture: 'x64',
      hasRuntimeLibrary: allPresent,
    );
    expect(picked, isNull);
  });

  test('ignores packages that do not carry onnxruntime.dll', () {
    var picked = pickWindowsMlPackage(
      const [
        'Microsoft.WindowsAppRuntime.1.8_8000.994.2142.0_x64__8wekyb3d8bbwe',
      ],
      architecture: 'x64',
      hasRuntimeLibrary: (_) => false,
    );
    expect(picked, isNull);
  });

  test('ignores unrelated directories', () {
    var picked = pickWindowsMlPackage(
      const [
        'Microsoft.WindowsAppRuntime.1.8_8000.994.2142.0_x64__8wekyb3d8bbwe.bak',
        'Microsoft.Windows.Photos_2026.11090.22001.0_x64__8wekyb3d8bbwe',
        'WindowsApps',
      ],
      architecture: 'x64',
      hasRuntimeLibrary: allPresent,
    );
    expect(picked, isNull);
  });

  test('only the Windows ML runtime asks for the DML provider', () {
    // 单测跑在 Windows 上，随包分发的运行库是纯 CPU，没有候选 EP。
    expect(const OrtRuntimeChoice.bundled().executionProviders, isEmpty);
    var windowsMl = const OrtRuntimeChoice.windowsMl(
      r'C:\Program Files\WindowsApps\pkg\onnxruntime.dll',
    );
    expect(windowsMl.isWindowsMl, isTrue);
    expect(windowsMl.executionProviders, ['DML']);
  });

  test('Android tries NNAPI before XNNPACK', () {
    expect(executionProvidersForPlatform('android'), ['NNAPI', 'XNNPACK']);
  });

  test('other platforms stay on the default CPU provider', () {
    for (var platform in ['windows', 'linux', 'macos', 'ios', 'ohos']) {
      expect(executionProvidersForPlatform(platform), isEmpty);
    }
  });
}
