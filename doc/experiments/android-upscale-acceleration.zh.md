# Android 超分加速：NNAPI 退场与 QNN 可行性

2026-11-07 记录。范围是 Anime4K / Real-ESRGAN 走的原生超分（Kotlin + ONNX Runtime），
不含图像翻译那条链（见 `image_translation.zh.md`）。

## 现状

- 随包 `libonnxruntime.so`（onnxruntime-android 1.28.0，28,637,280 B）编进了
  **NNAPI** 与 **XNNPACK** 两个 EP：前者含完整 `NnapiExecutionProvider` 符号，
  后者含 `XnnpackExecutionProvider` 符号。
- 真正能提效的只有 XNNPACK（CPU 侧 NEON/BF16 内核）；NNAPI 自 Android 15
  起废弃、较新系统已移除运行时，见下节。

## NNAPI 为什么不再值得挂

真机取证（SM-S9480 / Android 17 / SDK 37）：

- `/system/lib64/libneuralnetworks.so` 不存在，`dumpsys neuralnetworks` 报
  `Can't find service`，`service list` 里也没有该服务。
- ORT 仍能建出「NNAPI 会话」，但所有节点静默落回 CPU：输出与 CPU 逐位相同
  （MAE 0.0），256×256 单次 17 ms vs CPU 16 ms，没有加速。
- 因此 Android 端先看 NNAPI 到底有没有加速器再决定是否请求它：
  `NnapiDevices`（dart:ffi 调 NDK 的 `ANeuralNetworks_getDeviceCount` /
  `ANeuralNetworksDevice_getType`）枚举本机驱动，只有存在 GPU/NPU 类型的
  非参考驱动才算可用。本机实测只枚举到 `gpu:nnapi-reference`——参考实现被
  报成 GPU 类型，但名字就是 CPU 参考驱动，按不可用处理。
- Kotlin 侧另有一道兜底：`NnapiSupport` 加载 `libneuralnetworks`，连库都
  加载不到时直接按 CPU 建会话；两道判据都不写死版本号（不同 OEM 取舍不一）。

## QNN（Qualcomm NPU）可行性

结论：**当前不接入**。三条硬门槛：

1. **EP 没编进随包运行库。** 二进制里只搜到 `QNNExecutionProvider` 这个名字与
   `libonnxruntime_providers_qnn.so`（ORT 的 provider bridge 用于按需加载外部
   provider 的库名），没有 QNN 的 EP 符号，也没有 `libQnnHtp.so`/`QnnSystem`
   之类的引用。官方文档写明 **Pre-built Packages 仅限 Windows**，Android 需要
   自己从源码构建（`--use_qnn`）或自行提供 provider bridge 的 `.so`。
2. **必须随包分发 Qualcomm 运行库。** QNN EP 通过 `backend_path` 指定
   `libQnnHtp.so`，并且 HTP 后端还要 `libQnnSystem.so` 与对应 SoC 的 skel 库。
   这些都来自 Qualcomm AI Engine Direct SDK（下载需在 qpm.qualcomm.com 接受协议），
   设备 ROM 里不带（本机只有 `libSNPE.so` 系列，属另一套 SNPE，不是 QNN）。
3. **体积与许可成本。** 多 ABI 打包后是十几到几十 MB 的增量，且分发受 Qualcomm
   SDK 许可约束；对一个 21 KB 的 ACNet 小模型，换来的加速很可能抵不过加载与
   初始化的固定开销。

若之后确实要上 NPU，最小验证路径是：用 QNN SDK 出一个 `--use_qnn` 的 arm64
运行库 + 对应 skel，做成可开关的变体包，先在 Real-ESRGAN 3 通道大模型上量
端到端耗时，再决定是否进主包。

## 验证

- 单测：`test/foundation/image_provider/upscale/anime4k_v4_service_test.dart`
  覆盖「3 通道默认试 NNAPI」「NNAPI 运行时缺失时强制 CPU」。
- 真机探针：`tool/ort_ep_device_probe.dart` 会打印启动期 EP 清单、逐 EP 建会话、
  输出与 CPU 的 MAE/耗时，并额外探测方法通道的 `nnapiAvailable` 与 QNN 建会话
  的真实报错。
