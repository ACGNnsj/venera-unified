# 依赖审计

本文记录 Venera Unified 当前的依赖审查。精确解析结果以
[pubspec.lock](../../pubspec.lock) 为准，Git 与本地源码的不可变来源记录在
[git_dependencies.json](git_dependencies.json)；本文只说明维护策略，不另建一套版本固定值。

## 当前清单

当前 lockfile 从 3 个 Git 仓库解析出 8 个 Git 包，并包含 6 个本地包：

| 依赖 | 当前来源与修订 | 维护原因 |
| --- | --- | --- |
| flutter_qjs | [flutter_qjs](https://github.com/CyrilPeng/flutter_qjs)，`295f77421eedff356a02e92987181b525970c780` | Venera 引擎修复与已审查的平台源码 |
| flutter_inappwebview 系列 | [flutter_inappwebview](https://github.com/venera-app/flutter_inappwebview)，`0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676` | 六个包共享的 Venera WebView 兼容修复 |
| webdav_client | [webdav_client](https://github.com/venera-app/webdav_client)，`2f669c98fb81cff1c64fee93466a1475c77e4273` | Venera WebDAV 行为与 Android 网络兼容修复 |

QuickJS 源码审计同时记录 quickjs-ng 核心
`d07f6b59c76e5b5c4c784c96e888ae85f779d512`，并保留 Venera 专用补丁。不能只更新
Dart 包装层固定值，却让已审查的原生核心停留在旧状态。

## 本地包

| 包 | 当前版本 | 维护边界 |
| --- | --- | --- |
| photo_view | 0.14.0 | 本地空安全、定位与缩放修复 |
| share_plus | 12.0.2 | 本地 Windows ARM64 与 Venera 分享行为 |
| rhttp | 0.15.1 | 本地 Rust HTTP 后端、profile 可移植性与 HTTP/3 策略 |
| desktop_webview_window | 0.2.4 | 本地 Linux/WebKit 兼容与生命周期修复 |
| venera_native | 1.0.0 | Venera 原生集成与 Linux 兼容 |
| venera_saf | 1.0.0 | Venera 分区存储行为与取消修复 |

源码变化必须同步维护对应补丁与许可证文档。尤其当 rhttp 的 Rust lockfile 改变时，
应审查 [rhttp 本地补丁](../../packages/rhttp/LOCAL_PATCHES.md)；url `2.5.9` 与
form_urlencoded `1.2.3` 属于这套已审查源码状态。

## 有意保留的托管依赖

当前 lockfile 保留 dynamic_color `2.1.0`、pdfrx `2.11.0` 与
pdfrx_engine `0.9.0`、flutter_reorderable_grid_view `5.7.0`，以及
scrollable_positioned_list `0.3.8`。上游发布说明或更新的候选版本不构成修改这些
固定值的授权。升级必须有独立 diff、兼容性证据以及相关阅读器/平台测试。

## 必需审查流程

1. 修改 `pubspec.yaml` 后，用本仓库 Flutter/Dart 工具链重新生成 `pubspec.lock`；
   不能为迁就上游 lockfile 而丢掉本地包解析。
2. 每个 Git 或 path 来源都要在 [git_dependencies.json](git_dependencies.json) 中记录
   不可变提交/内容来源、审查目录、随包资源、许可证文本与校验和；格式见
   [依赖维护策略](dependencies.zh.md)。
3. 除 Dart 外还要审查原生与随包源码。QuickJS、pdfium、rhttp、WebView 与平台补丁记录
   必须和实际发布内容一致。
4. 运行：

   ```sh
   fvm dart tool/check_git_dependencies.dart
   python .github/scripts/check_structure_imports.py
   python .github/scripts/check_architecture_dependencies.py
   fvm flutter test test/tool/ci_workflow_contract_test.dart
   ```

5. 为行为变化添加定向测试，再运行相关完整平台或阅读器套件，并记录工具链和未实测的
   运行环境。

共享 pub cache 中已有改动的包会让已解析来源检查按失败关闭。应使用干净解析缓存或 CI；
不能通过修改缓存让审计变绿，也不能把网络 clone 失败当作清单比对成功。
