# 图像翻译（实验）

阅读器内把外文漫画页翻成目标语言：先在页内检测文本行、按行抹字，再把译文按原行位绘回。整条链路默认关闭，按漫画开启，缺模型或缺服务商时不影响正常阅读。

本文记录已落地的范围、代码位置与已知边界。实验特性的意思是：数据格式与默认值仍可能随版本调整，暂不作为发布阻断项。

## 状态

- 已合并到 `main`：设置页、阅读器开关、翻译服务层、OCR 管线和原生加速层都已可用。
- 章节级后台预翻译队列已移植（`lib/features/reader/pre_translation_tasks.dart`），但**还没有任何界面入口**，目前只能按页触发。
- 未验证平台：鸿蒙（HarmonyOS）。Android、Windows、Linux 走同一套 Dart + Rust 代码路径。

## 入口

- 设置 → 阅读器 → 图片翻译（`lib/features/settings/image_translation.dart`）：语言对、文字去除方式、翻译服务商、术语表、OCR 组件下载。
- 阅读器顶栏的「文A」按钮：按当前漫画开关。开启但 OCR 组件缺失时按钮呈错误色（`colorScheme.error`），再点一次即可关闭。顶栏右侧另一个「文A」是上游的单页翻译，两者互不影响。

## 处理流程

1. 渲染某一页时，`ReaderImageProvider` 先按 `pageTranslation@2@<源>><目标>@…` 查缓存，命中直接返回译文图。
2. 未命中则回退原图，同时在后台跑该页：OCR 检测文本行 → 分组合并 → 逐行识别 → 送翻译服务 → 生成逐行擦除矩形 → 抹字 → 按行位回绘译文。
3. 译文与擦除矩形一起写进 `TranslationStore`，下次同页同语言对直接复用。

## 代码地图

| 路径 | 职责 |
|---|---|
| `lib/foundation/image_translation/translation_config.dart` | 语言对、文字去除模式、缓存前缀（当前第 2 代） |
| `lib/foundation/image_translation/translation_service.dart` | 开关状态、按漫画作用域、就绪判定、页级流水 |
| `lib/foundation/image_translation/translation_pipeline.dart` | 单页编排：检测 → 识别 → 翻译 → 回绘 |
| `lib/foundation/image_translation/ocr_worker.dart` | 文本行检测/识别 worker、行框聚类、竖排重采样、后处理 |
| `lib/foundation/image_translation/ocr_models.dart`、`translation_models.dart` | OCR 组件注册表、就绪判定、下载与体积探测 |
| `lib/foundation/image_translation/llm_translator.dart` | OpenAI 兼容服务商（含拉取模型列表） |
| `lib/foundation/image_translation/public_translator.dart`、`script_translator.dart` | 公共免费服务、图源脚本翻译 |
| `lib/foundation/image_translation/inpaint.dart` | 纯 Dart 抹字（Otsu 掩码 + 邻域平滑） |
| `lib/foundation/image_translation/page_renderer.dart` | 把译文按行位绘回页面 |
| `lib/foundation/image_translation/translation_store.dart` | 页译文与章节索引的持久化 |
| `lib/foundation/image_translation/rate_limiter.dart`、`ordered_group_committer.dart` | 服务商限速、分组结果按序提交 |
| `lib/features/reader/pre_translation_tasks.dart` | 章节级预翻译队列（未接 UI） |

## 作用域与缓存

- 全局：设置页写入的三个 key（`imageTranslationSource`、`imageTranslationTarget`、`imageTranslationInpaintMode`），未设置时按 `auto` / `zh` / `smart` 生效。设置页的三个下拉现在会直接显示这三个有效默认值。
- 设备级与按漫画覆盖：`TranslationConfig.of(cid, sourceKey)` 优先读 `cid@sourceKey` 作用域，其次设备级，最后全局。
- 缓存前缀带语言对（`pageTranslation@2@源>目标@`），换语言不会命中另一种语言的旧页；第 2 代记录逐行擦除矩形，与第 1 代的整块擦除不通用。

## OCR 组件

`text_detector`（PP-OCR 检测）加 `ocr_ja` / `ocr_zh` / `ocr_zh_v5` / `ocr_en` / `ocr_ko` 五个识别组件，全部为 ONNX。源语言选 `auto` 时只要求检测组件就绪，识别组件按实际语种按需加载；选具体语种时只要求对应识别组件。下载大小通过一字节 range 请求探测后再显示。

## 原生加速

| crate | 替代的 Dart 实现 |
|---|---|
| `native/ocr_preprocess` | 竖排行重采样、检测后处理（连通域） |
| `native/image_transpose` | `Uint32List` 图像转置 |
| `native/inpaint` | 抹字掩码与填充 |
| `native/jpg_encode` | JPEG 编码 |
| `native/anime4k` | Anime4K v1 后处理 |

Dart 侧绑定分别是 `ocr_preprocess_native.dart`、`image_transpose_native.dart`、`inpaint_native.dart`，全部按「native 优先、失败回退 Dart」实现，缺库只影响耗时不影响结果。CI 在 Android、Windows、Linux、macOS、iOS 五个平台产出这些库并执行等价比对。

本机 Windows Release 实测（CI runner 上的数字略低）：

- JPEG 编码 4.9–7.3 倍
- OCR 前后处理 2.5–3.9 倍，整页管线 3.3–3.5 倍
- 单页抹字 2.6–3.3 倍

## 执行后端

推理走 ONNX Runtime，按平台挑能用的加速，拿不到就退回默认 CPU：

| 平台 | 后端 | 选择方式 |
|---|---|---|
| Android | 图片翻译：XNNPACK → CPU；动漫超分：按通道数判断 | 前者由 `ort_runtime_choice.dart` 给出候选、会话逐个尝试；后者单通道强制 CPU，带偏色/全黑自检，异常整图重跑 |
| Windows 11 24H2+ | 系统 Windows ML（ORT + DirectML）优先，缺失则回退随包 CPU | `ort_runtime_choice.dart` 在 `C:\Program Files\WindowsApps` 里挑版本最高的 `Microsoft.WindowsAppRuntime.*` 框架包 |
| 其它桌面/移动 | 随包 CPU | — |

Windows 上不再自带 DirectML：Windows 11 的 Windows App Runtime 框架包已经带了 ONNX Runtime 与 DirectML.dll，直接加载那份并把 `DML` 作为 execution provider 挂上，比随包分发省 38 MB，运行时还跟着 Windows 更新。普通账户列不出 `C:\Program Files\WindowsApps`（OS Error 5），因此候选包名改从注册表 `HKCU\Software\Classes\Local Settings\...\AppModel\Repository\Packages` 读，再用文件是否存在复核。任何一步失败（DLL 载入失败、GPU 会话建不起来）都静默回退到随包 CPU，功能不受影响。

RTX 4080 Laptop 实测（单线程、warmup 2 次取中位数）：

- OCR 检测 960×960：201.7 ms → 18.7 ms（约 10.8 倍）
- OCR 识别 48×320：17.3 ms → 4.0 ms（约 4.4 倍）
- Anime4K 降噪 acnet 256×256：247.4 ms → 2.0 ms（约 121 倍）

Windows ML 的厂商 EP（TensorRT RTX、OpenVINO、QNN 等）走 EP catalog 按需下载，未打包进程里枚举为空，需要 MSIX 或 WinAppSdk bootstrapper 才有包依赖图，暂未接入。

Android 随包的 `libonnxruntime.so`（onnxruntime-android 1.28.0）编进了 XNNPACK：CPU 侧的加速内核（Arm NEON/BF16 优化），数值行为与默认 CPU EP 接近，走 ORT 的通用 `SessionOptionsAppendExecutionProvider` 按名挂载。候选链只有 XNNPACK → CPU，单个候选建会话失败只记一次日志并继续下一个。

不再挂 NNAPI：Google 从 Android 15 起弃用 NNAPI；实测 SM-S9480 / Android 17 / SDK 37 上已经没有 `libneuralnetworks.so`，`dumpsys neuralnetworks` 也报 `Can't find service`。ORT 的 NNAPI EP 仍能建会话（导出符号还在），但所有节点都静默落回 CPU——输出与 CPU 逐位相同（MAE 0.0，256×256 单次 17 ms vs 16 ms），既没有加速，还把 XNNPACK 挡在后面。要真正用上 NPU 得换 ONNX Runtime 的 QNN EP（Qualcomm），它要求随包分发 `libQnnHtp.so`/`libQnnSystem.so` 并受 Qualcomm 许可约束，当前安装包里没有，暂不接入。

设备上首次用到某个非 CPU 会话时，会把同一组输入再跑一遍 CPU：逐元素 MAE ≤ 0.04（或相对 MAE ≤ 0.02）才采用加速输出；超阈值、输出形状不一致或空输出都判该 EP 不可信，整页剩余推理切回 CPU，并把结论打进日志。启动时 `OrtRuntime.logStartupDiagnostics()` 会列出本机实际可挂载的 EP（`[ORT]` 前缀），排障不用再猜运行库有没有编进去。iOS/macOS 的 pod 里带了 CoreML EP，Linux/鸿蒙的随包运行库只有 CPU，均暂未接。

## 验证

- `test/foundation/image_translation/` 覆盖类型、抹字、渲染、服务层、worker、缓存、模型注册表、运行时与执行提供者选择（含 `ort_backend_check_test.dart` 的 MAE／相对误差判定与形状不一致回退），以及各原生 crate 的像素等价与加速比门禁。
- `test/features/reader/pre_translation_tasks_test.dart`（10 个用例）覆盖队列的续跑、逐页失败重试与单章取消。
- `test/features/settings/` 覆盖设置页取值、保存时序与继承规则。
- 真机（Windows Release）已走通：主页/详情/阅读器正常，顶栏开关开→关颜色切换正常，设置页四节与模型下载行正常渲染。

## 已知边界

- 章节级预翻译队列没有入口，用户目前只能翻当前页。
- 术语表按 `cid@sourceKey` 分组，跨漫画不共享。
- 译文只影响阅读器里显示的图像，不改动已下载的原图文件。
- 竖排文本、气泡内多行合并与手写体仍是识别质量的主要风险点，行框聚类参数改动需要在真实页面上回归。
- 鸿蒙未验证。
