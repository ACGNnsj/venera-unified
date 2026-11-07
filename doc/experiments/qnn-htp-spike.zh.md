# Qualcomm QNN（HTP）可行性：取证、阻塞点与打通配方

状态：2026-11-07 取证完成，**本轮不开工**。硬前置是 Qualcomm AI Engine Direct（QAIRT）SDK，需高通账号与许可，本机没有存量。

## 一、结论

- 官方 `com.microsoft.onnxruntime:onnxruntime-android` 的 AAR **不含 QNN EP**：三版 AAR 的 arm64 运行库里 QNN 相关只剩"执行提供器名称表"的三条字符串，没有 backend 实现，也没有 `backend_path` 这个词。
- 真机上据此必然失败，实测原文：`ONNX Runtime error: QNN execution provider is not supported in this build.`
- 官方口径要求 Android 侧**自建 ORT**：QNN EP 在 Android 上只能静态链进 `libonnxruntime.so`（`--use_qnn static_lib`），共享库形态不支持 Android；预编译包只有 Windows。
- 因此"接 QNN"= 自建 ORT + 随包分发 QAIRT 运行库，不是换个依赖坐标的事。

## 二、取证（可复核）

官方 AAR 里 arm64 版 `jni/arm64-v8a/libonnxruntime.so`：

| AAR 版本 | 字节数 | sha256 前 16 | QnnHtp | libQnnHtp | QNNExecutionProvider | providers_qnn | backend_path |
|---|---|---|---|---|---|---|---|
| 1.22.0 | 18,214,224 | 999ecfdb5b5a13e4 | 1 | 0 | 1 | 1 | 0 |
| 1.23.0 | 19,242,472 | cd1285f8955f3abc | 1 | 0 | 1 | 1 | 0 |
| 1.28.0 | 28,637,280 | f826d8efb03adf0a | 1 | 0 | 1 | 1 | 0 |

本机产出的 APK（`build/app/outputs/flutter-apk/app-arm64-v8a-mobile-debug.apk`）里同一文件：28,637,280 字节、`324679b9a86f3160`，与 1.28.0 只差 347 字节、集中在 section 名表区域（打包工具重排），二进制内 `1.28.0` 出现 2 次 —— 即**实际跑的是 ORT 1.28.0**。

Gradle 解析可以解释这一点：

```
+--- project :flutter_onnxruntime
|    \--- com.microsoft.onnxruntime:onnxruntime-android:1.28.0
\--- com.microsoft.onnxruntime:onnxruntime-android:1.23.0 -> 1.28.0
```

`android/app/build.gradle` 里那句 `1.23.0` 被插件声明的 1.28.0 顶掉，是无效 pin（已改写成 1.28.0 并注明跟随插件）。

NNAPI 对照：`libneuralnetworks` 能加载（库在 APEX），但 NDK 枚举只有 `gpu:nnapi-reference` 一台参考实现，硬件加速器计数为 0，所以 NNAPI 路径已经在运行时被门控关掉，没有免费的 NPU 可用。

## 三、官方口径（onnxruntime.ai，2026-11-07 抓取）

- QNN EP 支持 Android 与 Windows 上的 Snapdragon SoC；**Pre-built Packages (Windows Only)**。
- 构建参数：`--use_qnn [shared_lib|static_lib]`，其中 `static_lib`"is required for Android builds"；`--qnn_home <QAIRT>` 指 SDK 根目录。
- 运行时用 `backend_path` 指到 `libQnnHtp.so`（与 `backend_type` 二选一）。
- `enable_htp_fp16_precision` 默认 1：fp32 模型可以直接按 fp16 跑在 HTP 上，**不必先量化成 int8**，这对现有 Anime4K / OCR 模型是关键（省掉量化链路）。
- 官方测过的组合是 QNN 2.22.x + SC8280 / SM8350 / Snapdragon X，我们的 SM-S9480 不在列表内，需自行验证。

## 四、打通配方（SDK 到手后照做）

1. 取 QAIRT：<https://qpm.qualcomm.com/#/main/tools/details/Qualcomm_AI_Runtime_SDK>（账号 + 接受许可；选与 ORT 1.28 兼容的 2.3x）。
2. 编 ORT（版本必须与本机 APK 实际版本一致，否则 Java API / JNI 对不上）：

```bash
git clone --recursive https://github.com/microsoft/onnxruntime.git
cd onnxruntime && git checkout v1.28.0
./build.sh --config Release --android --android_abi arm64-v8a --android_api 27 \
  --use_qnn static_lib --qnn_home <QAIRT 路径> --build_shared_lib --skip_tests --parallel
```

3. 换包：取 1.28.0 AAR 的 `classes.jar` 与 `jni/arm64-v8a/libonnxruntime4j_jni.so` 不动，只替换 `jni/arm64-v8a/libonnxruntime.so`；用文件依赖顶掉 Maven 坐标，并把 `flutter_onnxruntime` 的传递依赖排除或做 dependencySubstitution，避免两个 libonnxruntime.so 打架。
4. 随包放 QAIRT 的 `aarch64-android` 运行库（`libQnnHtp.so`、`libQnnSystem.so`、`libQnnHtpV*Stub.so`）进 `jniLibs`，EP 选项写 `backend_path = <applicationInfo.nativeLibraryDir>/libQnnHtp.so`。
5. 门控沿用 NNAPI 那套：先 dlopen 探 backend 能不能加载，失败就退回 XNNPACK / CPU，不要无条件挂 QNN。

## 五、验收门槛（先测再决定是否随版）

- 性能：用 Anime4K 256/512 与 OCR 预处理两处做样本，HTP 的 `accMs` 要显著优于 XNNPACK（暂按 ≤0.7× 才值得背体积）。
- 精度：XNNPACK 现在是逐位一致（MAE 0.0），HTP fp16 必然有偏差，得先定 MAD/PSNR 门槛，否则不能默认替换。
- 体积：QAIRT aarch64 运行库大小需实测；当前 debug arm64 单 ABI APK 为 125 MB 量级。
- 许可：QAIRT 二进制能否随 APK 分发，要读 Qualcomm 许可条款，不能默认可以。

## 六、待办

- [ ] 设备插上后确认 `/vendor/lib64` 有没有 `libQnnHtp.so`：有则说明设备侧运行库可能可复用，但编译仍必须有 SDK 头文件。
- [ ] 高通账号 + QAIRT SDK（需用户拍板；替代是先走 Qualcomm AI Hub 云端真机估收益，同样要账号）。
