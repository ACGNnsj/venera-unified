# AVIF 解码评估（#94）

2026-10-11：本轮完成 AVIF 文件识别修复和可复现的解码评估。通用内置 AVIF 解码器尚未接入；当前固定 SDK 下，候选库的错误处理仍有阻塞。#94 的解码器需求继续保持开放。

## 已完成的格式识别

文件类型检测读取 ISO-BMFF 顶层 `ftyp` 盒中的主品牌和兼容品牌，支持 `avif`／`avis`、不同盒长度、64 位盒长度及前置空白盒。截断、非法盒长度、minor version 和媒体载荷中的同名字符串不会被当成 AVIF 品牌。该识别用于保存正确的 `.avif` 扩展名；实际解码能力由运行环境决定。

## 当前宿主的实际结果

环境：Windows x64、Flutter 3.41.4、Dart 3.11.4。执行：

```powershell
flutter test --no-pub tool/avif_codec_probe.dart
```

| libavif 测试样本 | Flutter 宿主解码结果 |
|---|---|
| `white_1x1.avif` | 失败：Codec failed to produce an image |
| `abc_color_irot_alpha_irot.avif` | 成功，256×512，返回 1 帧 |
| `colors-animated-8bpc.avif` | 成功，150×150，返回 1 帧 |
| `colors-animated-8bpc-alpha-exif-xmp.avif` | 成功，150×150，返回 1 帧 |

以探测输出中的 `supported`、尺寸和 `frameCount` 逐项评估。此结果只覆盖当前 Windows 测试宿主；Android、iOS、macOS、Linux 以及其他 Windows 安装环境仍需分别验证。动画样本的首帧显示成功，完整动画能力仍需支持多个帧。

样本来源、固定提交、SHA-256 和许可证见 [AVIF 测试夹具](../../test/fixtures/avif/README.md)。

## 候选依赖

| 候选 | 来源、版本及许可证 | 当前结果 |
|---|---|---|
| flutter_avif | [pub.dev 3.1.0](https://pub.dev/packages/flutter_avif/versions/3.1.0)，[yekeskin/flutter_avif](https://github.com/yekeskin/flutter_avif)，MIT | SDK 可兼容；Windows 原生 DLL 对损坏输入发生 panic，未返回错误。上游未归档，最近代码更新为 2025-09 |
| flutter_libavif | [pub.dev 0.1.1](https://pub.dev/packages/flutter_libavif/versions/0.1.1)，[dartgfx/libavif](https://github.com/dartgfx/libavif)，MIT | 要求 Dart ^3.12.0，与当前 3.11.4 不兼容；0.1.0 也要求 ^3.12.0 |
| imcodec_native | [pub.dev 0.2.5](https://pub.dev/packages/imcodec_native/versions/0.2.5) | 所有已发布版本均要求 Dart >=3.13.0，不适配当前 SDK；未进入原生与许可证审查 |
| native_animated_image | [pub.dev 0.3.4](https://pub.dev/packages/native_animated_image/versions/0.3.4)，[Lingyan000/native_animated_image](https://github.com/Lingyan000/native_animated_image)，MIT | 平台包 0.3.2 的源码明确说明 0.3.0 已撤掉 AVIF 后端，当前支持 GIF／APNG／WebP |

对 `flutter_avif_windows 3.1.0` 的独立进程探测：1×1 白色样本获得 19 字节回包；将有效 AVIF 截断到 64 字节后，原生线程报告 `Couldn't decode the image. Code: 20`，3 秒内没有结果或错误回包。源码中 `_init_memory_decoder`／`_get_next_frame` 的失败分支会 panic，Dart 桥接的 `RawReceivePort` 只等待成功回包。该路径会遗留等待和原生资源，单纯增加 Dart 超时无法补齐原生释放。

原生候选探测使用单独的程序和从对应 pub.dev 归档解压出的 DLL，未添加应用依赖或捆绑该二进制：

```powershell
dart compile exe tool/avif_native_candidate_probe.dart -o build/avif-candidate-probe.exe
build/avif-candidate-probe.exe <flutter_avif.dll 的绝对路径> test/fixtures/avif/white_1x1.avif
build/avif-candidate-probe.exe <flutter_avif.dll 的绝对路径> test/fixtures/avif/abc_color_irot_alpha_irot.avif 64
```

## 接入条件

优先评估兼容 SDK 的 libavif 方案，或在单独的 SDK 升级中重新评估 `flutter_libavif`。接入前须验证损坏数据能返回有界错误并释放解码器、输入和帧缓冲区；与阅读器退出／取消、缓存和动画帧的所有权兼容。

功能验证需覆盖普通静态图、透明度、旋转／镜像、网格、不同位深及动画帧。原生 RGBA 的预乘 alpha 语义必须与 Flutter 接口匹配，并验证色彩和尺寸。新增依赖按[依赖治理](../development/dependencies.zh.md)记录固定来源、许可证、上游状态和替代方案，完成目标平台构建与真机测试后再合入。
