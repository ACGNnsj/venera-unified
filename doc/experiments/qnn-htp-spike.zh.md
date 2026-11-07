# Qualcomm QNN（HTP）可行性：取证、阻塞点与打通配方

状态：2026-11-08 已用 QAIRT 2.52 自建出带 QNN EP 的 libonnxruntime.so 并跑通装机，但设备侧 HTP 建不起来（QNN_DEVICE_ERROR_INVALID_CONFIG），QNN 对本机当前零收益。实测见第七节。

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

## 七、自建实测记录（2026-11-08 01:00-02:20，SM-S9480 / SM8850 / canoe）

能走通：
- QAIRT /mnt/d/qairt/2.52.0.261104（QNN API 2.41.0）。ORT 1.28 的 qnn_backend_manager.cc:40-42 static_assert 要求 QNN API >= 2.29，满足。
- 构建必须在 WSL：Windows cmake 取 abseil zip 报 schannel: recv returned error 56。
- 两个必踩坑：① NNAPI 与 QNN 同时编译撞 NodeAttrHelper 重复符号（providers/nnapi/utils.cc 与 providers/qnn/ort_api.cc 各一份），用 -Wl,--allow-multiple-definition 放行；② AAR 里的 libonnxruntime4j_jni.so 静态依赖 OrtSessionOptionsAppendExecutionProvider_Nnapi，只编 QNN 时 JNI 加载即 UnsatisfiedLinkError 崩溃，所以自建库必须带 --use_nnapi。
- 产物 libonnxruntime.so 23,462,976 B，替换 AAR 的 jni/arm64-v8a/libonnxruntime.so；jniLibs 放 libQnnHtp.so / libQnnSystem.so / libQnnHtpV85Stub.so。QNN EP 确认编入：会话报 {"ep":"QNN","ok":true}，不再报 not supported in this build。

卡住：
- 四种组合全失败：无选项、只 backend_path、backend_path+soc_model=87、backend_path+soc_model=87+htp_arch=85（后者需本地给 ORT 的 ParseHtpArchitecture 打补丁，它只认 68/69/73/75/81）。
- ORT 原文：W ... Unable to determine backend path from provider options. Using default. / E qnn_execution_provider.cc:1046 GetCapability QNN SetupBackend failed Failed to create device. Error: QNN_DEVICE_ERROR_INVALID_CONFIG: Invalid config values
- 设备：ro.soc.model=SM8850、ro.board.platform=canoe、soc_id=660；/vendor/lib64 与 /odm/lib64 无 libQnnHtp.so。
- SDK：QnnTypes.h 有 QNN_SOC_MODEL_SM8850=87，HTP/QnnHtpDeviceConfigShared.h 有 QNN_HTP_DEVICE_ARCH_V85=85。
- 陷阱：GetCapability 失败后 QNN EP 不报错、整图回落 CPU，输出与 CPU 逐位一致（MAE 0.0）、耗时等于 CPU（256² 13ms / 128² 3ms / 64² 0ms）。会话 ok 不等于跑在 NPU 上，必须看 logcat 的 SetupBackend 行。

结论：QAIRT 2.52 在本机建不起 HTP 设备，QNN 当前零收益；XNNPACK 与 CPU 在该模型上同速。继续的前提是先证明 SDK 能在本机建设备——最小验证是只调 QnnDevice_create 的 NDK 小程序。

## 八、最小验证程序结论（2026-11-08 02:30，NDK 直调 QNN C API）

为了排除 ORT 的因素，直接用 NDK r27c 编了一个 `qnn_device_probe`（dlopen `libQnnHtp.so` → `QnnInterface_getProviders` → `logCreate` → `backendCreate` → 四种 `deviceCreate` 变体），推到 `/data/local/tmp/qnnprobe/` 配 QAIRT 运行库跑。

- 结果：`getProviders status=0x0 count=1 providerName=HTP_QTI_AISW`、`logCreate status=0x0`、`backendCreate status=0x0`，四种 `deviceCreate` 全部 `status=0x36b1`（14001）、`dev=0x0` —— 与 ORT 里的报错同源，问题不在 ORT。
- QNN verbose 日志给出根因链：① `Detected Snapdragon SOC SM8850 with 6 SOCs`（SoC 认出来了）；② 补上 `libQnnHtpV81Stub.so` 后 → `FastRPC resolved session URI file:///libQnnHtpV81Skel.so?...&_dom=cdsp` → `openSessionForPriority failed ... status=0x80000406` → `DspTransport.openSession qnn_open failed`。
- 也就是说：SDK 把本机 DSP arch 判定为 **V81**（与厂商一致，不是头文件里的 V85），去 DSP 上按名字加载 `libQnnHtpV81Skel.so`，而该库在设备上不存在。
- 设备侧实证：`find /vendor /odm /system -name '*HtpV*Skel*'` 只命中 `/vendor/lib64/rfs/dsp/libSnpeHtpV81Skel.so`（SNPE 命名，12,533,144 B），没有 QNN 命名的 skel；`/vendor/dsp` 整个目录 Permission denied。
- 设备自带 QNN 后端存在但不可用：`/vendor/lib64/rfs/dsp/libHexlpQnnHtp.so` 12,891,316 B、`libHexlpQnnSystem.so` 726,704 B、`libVppFrcQnnHtp.so` 11,549,644 B。但 shell `head -c 8` 读到 0 字节、dlopen 报 not found、`adb pull` 报 Permission denied（user build、SELinux Enforcing、ro.secure=1）⇒ 应用侧同样加载不了。

结论（终局）：这不是参数问题，而是**DSP 镜像只有 SNPE 命名的 skel、没有 QNN 命名的 skel**，且厂商自带的 QNN 运行库被 SELinux 拦在保护区里。ORT 的 QNN EP 在本机没有可走通的路径，QNN 线到此为止。

仍可走的前提（都需要外部条件，不做）：① 向 OEM/高通要带 QNN skel 的固件；② 换一台社区固件常带 QNN skel 的高通机型再验（SM8650/SM8750 一档）；③ 放弃 HTP，等 NNAPI 侧出现真正的硬件加速器。
