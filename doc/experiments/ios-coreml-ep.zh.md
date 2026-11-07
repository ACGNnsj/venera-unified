# iOS / macOS 的 CoreML 执行提供器

2026-11-08 记录。范围是图像翻译那条链用的 ONNX Runtime（`lib/foundation/image_translation/`）。
Android 侧的两个硬件通道都已关死（NNAPI 退场、QNN 的 DSP skel 不随系统分发，
见 `qnn-htp-spike.zh.md`），所以这里给 Apple 平台补上对称的一条：用官方便携包
里已经编进去的 CoreML EP。

## 边界

- **只保证接得上、退得干净**。本仓库没有 iPhone 真机，也没有 Apple 硅的 Mac，
  无法证明在神经网络引擎（ANE）上跑得比 CPU 快，因此本文不作任何加速比承诺。
- 目标平台是 iOS 与 macOS 桌面版：两者用的是同一个 `onnxruntime-objc` pod。

## 事实

依赖链（`pubspec.yaml` 里是 `flutter_onnxruntime: 1.9.0`）：

| 层 | 版本 / 事实 |
|---|---|
| `flutter_onnxruntime` podspec | `s.dependency 'onnxruntime-objc', '1.28.0'`，`:ios => '16.0'` / `:osx => '14.0'` |
| `onnxruntime-objc` | 1.28.0，CocoaPods trunk 发布 2026-08-04；`static_framework`，platforms ios 15.1 / osx 14.0；只有 ObjC 源码（32,722 B） |
| `onnxruntime-c` | 1.28.0；`vendored_frameworks: onnxruntime.xcframework`、`static_framework: true`、**`weak_frameworks: ["CoreML"]`** |

`weak_frameworks` 里列了 CoreML，说明官方发布的那份 `onnxruntime.xcframework`
把 CoreML EP 编进去了，运行时才去弱链接系统里的 CoreML 框架。ONNX Runtime 文档
的说法一致：「Pre-built binaries of ONNX Runtime with CoreML EP for iOS are
published to CocoaPods」，前置条件是 iOS 13+ / macOS 10.15+，并建议在带 ANE 的
设备上使用。

API 侧不需要新符号：CoreML 专用的
`OrtSessionOptionsAppendExecutionProvider_CoreML` 自 1.20 起弃用，官方推荐
通用入口 `OrtSessionOptionsAppendExecutionProvider(so, "CoreML", keys, values, n)`。
`ort_ffi.dart` 本来就是从 `ORT_API` 的索引 216 取这个函数（Android 的 XNNPACK
走同一条），所以 Apple 平台只是换了个 provider 名字。

## 实现

`ort_runtime_choice.dart` 的 `executionProvidersForPlatform`：

- `android` → `['XNNPACK']`
- `ios` / `macos` → `['CoreML']`
- 其它 → `[]`（纯 CPU）

不传 provider options：CoreML 的默认 `MLComputeUnits` 是「全都要」（CPU + GPU +
ANE 由系统调度），`ModelFormat` 默认已是 `MLProgram`。等真机上发现有具体的性能
或精度问题再针对性加键值。

会话建不起来时走既有的回退链：下一个候选 → 空列表 → 纯 CPU，与 Android 一致；
`_openLibrary` 在 iOS/macOS 先试 `DynamicLibrary.process()`，所以静态链进 App 的
那份 ORT 能被找到。

数值兜底已经在 OCR 链路里：`ocr_worker` 第一次用某个模型时会跟 CPU 参考实现
双跑比对，MAE > 0.04 或相对差 > 0.02 就整页回退 CPU 并标记
`accelerationRejected`。CoreML 的 fp16 精度漂移因此不需要单独放宽容差。

## 验证现状

- 已做：`ort_runtime_choice_test.dart` 覆盖 iOS / macOS 返回 `['CoreML']`，
  以及其它平台返回空列表；`dart analyze` 与图像翻译目录下的单测通过。
- 未做：任何 Apple 设备上的运行。**没有 iPhone、没有 Apple 硅 Mac。**
- 因此以下问题都还悬着：ANE 是否真的被用上、CoreML 分区后有多少节点仍落回
  CPU、首次编译 MLProgram 模型的一次性开销有多大。

这条链在 Android 上踩过的坑值得照搬过来当验收前提：**会话建起来不等于跑在硬件
上**。QNN 那次 `ok:true`、`actual:"QNN"`，输出与 CPU 逐位一致，实际全落 CPU。
判断 CoreML 是否生效必须看设备侧证据，不能看会话是否创建成功。

## 接手时的最小验证步骤

1. 起 App，日志里过滤 `[ORT]` 的启动行，确认 `candidates` 含 `CoreML`。
2. 翻译一页，确认没有记 `accelerationRejected`（有就是数值校验没过，已回落 CPU）。
3. 证明真的在 CoreML 上：Console.app 过滤 `onnxruntime`，看 CoreML EP 的
   node assignment 日志；或用 Xcode 的 Core ML 性能报告观察该进程的预测次数。
4. 对照组：把候选列表临时改成 `[]` 跑同一页，比首次与稳态耗时。只有这一组数据
   才能支撑「有加速」的结论。

## 风险

- **fp16 漂移**：CoreML 默认走 fp16，OCR 的双跑比对会兜住，但阈值是我方经验值，
  换模型后要重新观察。
- **部分加速**：CoreML 不支持动态 shape 的算子会留在 CPU，整图被切成两段跑，
  收益取决于模型里可离线化的算子占比。
- **首次开销**：MLProgram 模型第一次加载要编译并写系统缓存，冷启动那一次会明显
  变慢，别把它当成回归。
- **系统版本**：pod 要求 iOS 15.1 / macOS 14.0，插件本身要求 iOS 16 / macOS 14，
  更严格的以插件为准；再老的系统上 CoreML EP 会用不了，但回退链保证还能跑 CPU。

## 回滚

删掉 `executionProvidersForPlatform` 里的 `ios` / `macos` 分支即可，没有任何
构建或打包层面的改动需要撤销：pod 本来就在依赖里，CoreML 是系统框架。
