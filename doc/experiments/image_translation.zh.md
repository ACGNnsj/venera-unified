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

## 验证

- `test/foundation/image_translation/` 覆盖类型、抹字、渲染、服务层、worker、缓存、模型注册表，以及各原生 crate 的像素等价与加速比门禁。
- `test/features/reader/pre_translation_tasks_test.dart`（10 个用例）覆盖队列的续跑、逐页失败重试与单章取消。
- `test/features/settings/` 覆盖设置页取值、保存时序与继承规则。
- 真机（Windows Release）已走通：主页/详情/阅读器正常，顶栏开关开→关颜色切换正常，设置页四节与模型下载行正常渲染。

## 已知边界

- 章节级预翻译队列没有入口，用户目前只能翻当前页。
- 术语表按 `cid@sourceKey` 分组，跨漫画不共享。
- 译文只影响阅读器里显示的图像，不改动已下载的原图文件。
- 竖排文本、气泡内多行合并与手写体仍是识别质量的主要风险点，行框聚类参数改动需要在真实页面上回归。
- 鸿蒙未验证。
