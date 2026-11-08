# HarmonyOS（鸿蒙）移植状态

本仓没有鸿蒙发行版，只有一条**实验管线**：先把宿主工具链跑通，再谈把阅读器搬过去。
上游 CyrilPeng/Venera-Next 的 HarmonyOS 分支同样只是空白包与探针 HAP，不是可安装的阅读器；
其自述的文档只覆盖探针、进程重启与合成升级数据。

## 一句话结论

- **P1（工具链）已通过**：Windows 11 + DevEco Studio 26.0（API 26）+ flutter_ohos 3.41.9+ohos-1.0.2 能生成并编译出未签名 HAP（entry-default-unsigned.hap，20,627,003 字节，19 个 zip 成员，含 libs/arm64-v8a/libflutter.so 与 libapp.so）。
- **P2（把本仓阅读器编进去）当前阻塞**：TargetPlatform.ohos 让所有未加 default 的 switch (platform) 变成非穷尽匹配，编译期一次报 168 个错误，先撞的是 pub 依赖（material_ui-1.2.0）而不是本仓代码。

## 仓内产物

| 文件 | 作用 |
| --- | --- |
| tool/harmonyos/build_blank_hap.py | 端到端复现 P1：create 空白工程 → 改 build-profile.json5 / module.json5 → pub get → build hap --release --no-codesign --target-platform ohos-arm64 → 审计 HAP |
| tool/harmonyos/toolchain.json | 钉住的 SDK/Flutter 版本与已实测证据 |

用法（需要 DevEco Studio 与 flutter_ohos checkout）：

    python tool/harmonyos/build_blank_hap.py --flutter-ohos <flutter_ohos 路径> --work <临时目录>

成功时最后一行为 {"hap": "...entry-default-unsigned.hap", "bytes": 20626990}。
脚本已在全新工作目录冷启动实测通过（`entry-default-unsigned.hap`，20,626,990 字节，19 个 zip 成员）。

## 本机 Windows 必须绕过的四处限制

脚本已内置这四处处理，手工跑时容易再次踩到：

1. **%USERPROFILE% 下写不动**（EPERM: operation not permitted, mkdir '<用户目录>/.ohpm'）。ohpm 用 os.homedir() 而不是 OHPM_HOME，hvigor 默认 ~/.hvigor。脚本把 USERPROFILE、HVIGOR_USER_HOME、PUB_CACHE、TMP 全部指到工作目录内。
2. **hvigor 进程内建目录符号链接报 EPERM**（symlink '.../tools/hvigor/hvigor' -> '.../node_modules/@ohos/hvigor'）。同一台机 cmd /c mklink /J 与 DevEco 自带 node 直接 fs.symlinkSync(..., 'junction') 都正常，只有 hvigor 进程内失败，机制未定。脚本解析报错路径后用 mklink /J 预建链接再重试（@ohos/hvigor、@ohos/hvigor-ohos-plugin 逐个出现，最多重试 4 次）。
3. **npm 缓存也写在用户目录**（EPERM: operation not permitted, open '.../AppData/Local/npm-cache/_cacache/tmp/...'）。hvigor 用 npm 装 pnpm 引导包，需把 npm_config_cache 也指到工作目录，否则 hvigor 报 00308002 Operation Error。
4. **flutter.bat 尾部的 exit 会终止整个批处理**。脚本因此每条 flutter 命令都单独起进程。

另外 PackageHap 阶段会 spawn java ENOENT，需要把 DevEco Studio 的 jbr/bin 放进 PATH（脚本已做）。

## P2 阻塞证据

用 flutter_ohos 3.47.7+ohos-0.0.1-pre（Dart 3.13.5）在本仓工程副本上跑 flutter build hap：

- pubspec.yaml 的精确 flutter: 3.47.8 会拒绝预发布 SDK，需临时放宽为 '>=3.47.7-0 <3.47.8' 才能解析依赖。
- 编译期报 168 个 Error: The type 'TargetPlatform' is not exhaustively matched by the switch cases since it doesn't match 'TargetPlatform.ohos'.，分布在本仓依赖里：首例 material_ui-1.2.0/lib/src/about.dart:499:23，同包另有 action_buttons.dart:94/137、adaptive_text_selection_toolbar.dart:208/262/312、app.dart:893/914、app_bar.dart:849/1114、bottom_sheet.dart:719、calendar_date_picker.dart:260/325、checkbox.dart:497 等。

按来源统计这 168 处：material_ui-1.2.0 占 134 处，cupertino_ui-1.0.2 占 34 处，本仓 lib/ 零处（grep 不到任何 switch/case TargetPlatform）。也就是说卡住的不是本仓代码，而是这条 3.47.7 预览线自己带的 UI 包——它们还没处理 TargetPlatform.ohos。

于是形成一个版本死结：

- 稳定的鸿蒙线 3.41.9+ohos（Dart 3.11.5）框架本身能编，但低于本仓 environment.sdk >=3.12.0。
- 能配上的 3.47.7+ohos（Dart 3.13.5）自带的 UI 包过不了 ohos 枚举穷尽检查。

这条错误也无法靠改本仓绕过：TargetPlatform 枚举由 SDK 决定，3.47.8 没有 ohos 值，写 case TargetPlatform.ohos: 会让主分支编译失败；只能给这两个包做 dependency_overrides（本地打过补丁的副本）或等鸿蒙线自己更新。

## 2026-11-03 硬啃结果：完整应用 HAP 已出包

- 脚本 tool/harmonyos/patch_ohos_ui_overrides.py：把两包从 PUB_CACHE 拷到 .scratch/harmony/vendor（绝不动 cache 本体），只在 switch 块内把 ohos 并到 android 臂（or=20/fat=1/case=63），app 副本加 dependency_overrides。analyze 复查 TargetPlatform 错误归零。
- 关键发现：flutter tool 传给第三方 hook 的是 OS.linux 垫片（347 源码 targets.dart 明写），真凭据是 cCompiler 路径里的 openharmony。pdfium_dart 的 hook 按此跳过（PDF 本就是上游不可用项）；sqlite3 的 hook 在 OHOS clang 下直接编过，无需补丁。
- 产物 build/ohos/hap/entry-default-unsigned.hap 41.3MB：66 成员零重复，libs/arm64-v8a 含 libapp.so（16.7MB）/libflutter.so（18.2MB）/libsqlite3.so（1.7MB），module.json + pack.info 齐。缺 librhttp.so/libqjs（hook 静默无产物，运行时网络/JS 引擎不可用）与 libpdfium（主动跳过）。
- 结论：P2 编译关已过，版本死结解除；剩下是运行时原生库缺口（rhttp 需 aarch64-unknown-linux-ohos 交叉编译）与签名实测（P3）。

## 2026-11-03 原生库交叉编译：rhttp+qjs 全过，新 HAP 69 成员

- 脚本 tool/harmonyos/build_native_ohos.py（照上游 native_build.py 的 rust 配方：OHOS clang 当 CARGO linker/CC/CXX/AR，CARGO_ENCODED_RUSTFLAGS 带 --cfg reqwest_unstable 与 link-arg sysroot/--no-undefined，cargo build --locked --release --lib --target aarch64-unknown-linux-ohos；qjs 用 clang 直编 5 个 C 文件 + cxx/ffi.cpp；最后用 llvm-readelf/llvm-nm 验 AArch64 ELF、NEEDED 白名单与 FFI 导出符号，报告写 .scratch/harmony/native/native-build.json）：
  - librhttp.so 4163896 字节（sha256 8e2ad946…3649），NEEDED 只有 libc.so，frb_get_rust_content_hash / frb_init_frb_dart_api_dl 导出齐；
  - libqjs.so 1056056 字节（sha256 6d4e975c…2cd2），NEEDED 只有 libc++_shared.so + libc.so，无 liblog/libandroid；
  - libc++_shared.so 直接从 DevEco native 拷（1262504 字节）。
- QJS 源码钉 pubspec 同一 pin 295f774（venera-next-pinned 尖；相对 master 8feae95 只改 Dart，cxx/ 逐字节一致，故 .so 与按 8feae95 编的产物等价）。sqlite 跳过：sqlite3 hook 自编的 libsqlite3.so 已在包内。
- 三个 .so 拷进 app/ohos/entry/libs/arm64-v8a 后重跑 oh347-hap.bat（HAP_EXIT=0），新包 49739494 字节（约 47.5MB）：69 成员零重复、testzip None，libs/arm64-v8a 六个全齐（libapp/libflutter/libsqlite3/librhttp/libqjs/libc++_shared）。HAP 内 librhttp/libqjs 比 staged 小约 200B/84KB（hvigor 打包 strip）。
- 工具坑：wsl 后台 job 里写裸 Windows 路径（D:\…\oh347-hap.bat）反斜杠会被吃掉导致 exit 1，改成 cd /d + 正斜杠再调 bat。
- 结论：原生库缺口补齐；剩下 P3 签名实测与运行时验证。

## 要走通 P2 还需要

1. 逐处给 switch (platform) 补 default（本仓 lib/ 可改；pub 包只能 dependency_overrides 指向本地打过补丁的副本）。
2. 换鸿蒙分支依赖：flutter_inappwebview（gitcode 6.1.5-ohos-1.0.1）、code_assets（openharmony-sig fork，需与本机 Flutter 版本对齐）、lodepng_flutter 与 flutter_7zip（venera-app fork）。
3. 原生产物：rhttp / flutter_qjs / libc++_shared 已交叉编译进包（见上节）；还差 7zip、lodepng 的 OHOS 产物；sqlite3 由 hook 自编（本仓 3.8.0，无需上游 2.7.4 补丁）。
4. 签名：本机无华为开发者证书，未签名 HAP 只能靠 DevEco 登录账号自动签名或第三方自签工具。

## 上游自列的不可用项（移植后依然缺）

PDF 导入（PDFium）、自定义存储目录与持久化外部目录引用、系统分享、生物识别应用锁、Android 音量键 / SAF / 前台服务、已验证的 WebView 代理覆盖、部分平台专有图像编解码。

## 为什么不在 CI 里跑

上游的 harmonyos-experiment.yml 需要 Ubuntu + gitcode 的 flutter_flutter 与华为 OBS 引擎产物、RUSTUP_TOOLCHAIN=1.92.0 与 aarch64-unknown-linux-ohos 目标，单轮 100 分钟且只产出未签名 HAP。本仓把鸿蒙留在本地实验阶段，CI 不引入第二套工具链。

## 2026-11-04 x64 HAP 出包：ohpm 解析爆炸的根因是 integration_test

- 现象：arm64 能出包，加 `--target-platform ohos-x64` 后卡在 `hvigorw assembleHap` 里的 `ohpm install`，Node 堆涨到上限后 OOM。16GB 堆跑 1 小时挂，32GB 堆跑 6 小时 28 分也挂。把依赖 overrides 逐个摘掉时不是 OOM 而是立刻 404，说明不是内存不够，而是 ohpm 解 `file:` 指向 `.har` 的依赖时闭包无界增长。
- 根因：app 副本 `pubspec.yaml` 的 `dev_dependencies: integration_test: {sdk: flutter}`。flutter tool 会为它生成一个独立 ohos module 并写进 `.hvigor/dependencyMap`（连带它自己的 `@ohos/flutter_ohos: file:har/flutter.har`），于是 `ohpm i --all --target_path .../dependencyMap` 要把 entry 与 integration_test 两条链一起解。删掉这个 dev_dependency 后，同一命令约 8 分钟通过。
- 前置条件：先跑 `python tool/harmonyos/patch_ohos_ui_overrides.py`。它现在负责两件事：material_ui/cupertino_ui 的 ohos 臂补齐，以及从 app pubspec 移除 integration_test。
- 产物 `build/ohos/hap/entry-default-unsigned.hap` 58.8MB：73 个成员零重复、testzip 为 None、含 module.json；`libs/x86_64/` 有 libflutter.so(20,960,376)、libapp.so(17,154,952)、libsqlite3.so、librhttp.so、libqjs.so、libc++_shared.so。
- 收口 2026-11-04：`native-build-x64.json` 为 `cross_compile_pass`（x86_64-unknown-linux-ohos，NEEDED 仅 libc/libc++_shared），包内 `libs/x86_64/` 六个 so 齐（libapp/libflutter/libsqlite3/librhttp/libqjs/libc++_shared），包内 librhttp/libqjs 比 staged 小约 240B/80KB（hvigor strip，与 arm64 包规律一致）。`libs/arm64-v8a/` 四个预置库是双 ABI 常态残留，本次为 x64 目标构建故无 arm64 版 libapp；P2 x64 视为通过。

## 2026-11-04 x64 模拟器首跑：四连 crash 全是「Dart 层不认 ohos」

- 通法：git/版本依赖改不了上游，用 `patch_ohos_ui_overrides.py` vendor 到 `.scratch/harmony/vendor/` 后打补丁 + `dependency_overrides` 切 path；原生缺失的 .so 用 `build_native_ohos.py` 以 OHOS clang 直编进 `entry/libs/x86_64/`（flags 与 qjs 同款：`--target=x86_64-linux-ohos --sysroot -D__MUSL__ -D_GNU_SOURCE`）。
- 第一关 path_provider：加 `path_provider_ohos ^2.2.1`（OpenHarmony federated 实现）即过。
- 第二关 libsqlite3.so `fcntl64: symbol not found`：hook 传 OS.linux 垫片会下 glibc 预编译版；改 `--component sqlite` 从 amalgamation 直编（NEEDED 仅 libc.so）+ hook `source: system` 即过。
- 第三关 flutter_rust_bridge `Unknown platform: ohos`：vendor 后把 `Platform.isAndroid` 改为含 ohos（按 soname dlopen 包内 librhttp.so）即过。
- 第四关 flutter_7zip `_dylib` + flutter_qjs `_qjsLib` 同构 throw：同样 vendor 并 ohos 分支；另 7zip 原生库包内缺失，用 `--component 7zip` 编 `src/`（16 个 7zip C + flutter_7zip.cpp，C++20，DART_SHARED_LIB，NEEDED 仅 libc++/libc）出 libflutter_7zip.so。重出 HAP 59.2MB，模拟器 `aa start` 直达主页，无启动失败。

## 2026-11-06 运行期兜底：ohos 不再直接抛 MissingPluginException

进主页只说明启动链通了；真正的阅读闭环还会撞上四个「插件没有 ohos 实现」的坑。本次全部改成显式分支，不再靠异常冒泡：

| 位置 | 现象 | 处理 |
| --- | --- | --- |
| `lib/foundation/app.dart:24` | Dart 层没有任何 ohos 判断 | 新增 `App.isOhos`（`Platform.operatingSystem == 'ohos'`；flutter_ohos 只经 operatingSystem 上报，`Platform.is*` 全不匹配） |
| `lib/network/proxy.dart:30` | `getProxy` 直调 `venera/method_channel`，ohos 上抛 MissingPluginException，等于断网 | ohos 直接返回 `No Proxy`，走直连 |
| `lib/foundation/image_processing.dart` | `encodePng` 走 lodepng 原生库，本仓无 ohos .so | ohos 走纯 Dart 的 `package:image` 编码（`image ^4.12.0` 已在依赖里，不必补编原生库） |
| `lib/foundation/file_interaction.dart` | `file_selector` 无 ohos 实现，选目录/选文件/另存为全部不可用 | 四个入口改为弹输入框要绝对路径（默认 `/data/storage/el2/base/haps/entry/files`） |
| `lib/routing/webview.dart` | `flutter_inappwebview` 无 ohos 实现 | `AppWebview` 渲染占位页 + 「用系统浏览器打开」 |
| `lib/routing/cloudflare.dart:65` | 过验证依赖内置网页的 UA/Cookie | ohos 直接跳过并提示，不静默假成功 |

两个实现细节值得留档：

1. 路径输入框放在 `lib/routing/ohos_path_prompt.dart`（UI 文件），`foundation/file_interaction.dart` 只调用 `lib/foundation/path_prompt.dart` 里可注入的 handler，handler 在 `lib/main.dart` 启动时注册。原因：`foundation/` 一旦 import `components/` 或 `routing/`，`.github/scripts/check_architecture_dependencies.py` 会报 `Business file reaches UI`（`file_interaction.dart` 是 business 文件，bootstrap 会经它摸到整张 UI 图），而 `.github/scripts/check_structure_imports.py` 也禁止 foundation→components。新增文件必须同时登记进 `doc/architecture/dependency_baseline.json` 的 `business_files`/`ui_files`，否则报 `Unclassified library file`。
2. Cloudflare 的跳过是「诚实失败」而不是降级：没有内置网页就拿不到 `cf_clearance`，假装验证通过只会让后续请求 403。

## 2026-11-08 第二轮运行期兜底：缺原生实现的入口改为明确降级

上一节处理的是启动链上的六处；本次补的是导入、分享、生物识别与图像翻译这些非主链入口，规则统一成「没有原生实现就显式降级并说清原因」：

| 位置 | 现象 | 处理 |
| --- | --- | --- |
| `lib/features/local_comics/local_comics_summary.dart` | 导入对话框的 PDF 选项会走到 pdfrx→PDFium，HAP 没编这个库 | ohos 隐藏该项（`importMethodIndices`），其余项索引不变 |
| `lib/foundation/file_interaction.dart` | `share_plus` 无 ohos 实现 | 文件分享抛 `UnsupportedError`（与 Linux 同口径，调用方提示）；文本分享改走剪贴板（`usesClipboard`） |
| `lib/features/settings/app_controls.dart` | `local_auth` 无 ohos 实现，`canCheckBiometrics` 抛 MissingPluginException 会打断设置页 | `supportsAuthorization()` 在 ohos 直接读作不支持，其他平台异常也归为不支持，退回 PIN／密码 |
| `lib/features/reader/scaffold.dart`、`lib/features/settings/image_translation.dart` | 图像翻译依赖 ONNX Runtime，HAP 不随包 | 阅读器顶栏两个翻译入口隐藏；设置页顶部说明该构建暂不支持，同步来的配置保留但不假装能跑 |
| `lib/foundation/image_translation/ocr_engine.dart` | 缺库时报「重装应用再试」 | ohos 上改为说明该构建不含 ONNX Runtime |

门禁：`dart format`／`dart analyze` 干净；新增 3 个测试（导入选项索引、分享平台闸、生物识别探测），`test/features/settings` + `test/features/local_comics` + `test/foundation/image_translation` 共 889 项、`test/features/reader` 972 项全通过；两个架构脚本 clean。

仍未接的还有：图像翻译的 ONNX 推理本体（要把 onnxruntime 交叉编译进 HAP）、PDF 导入（PDFium）、系统分享、内置 WebView（验证码与站点登录）。

## 2026-11-08 x64 模拟器三链路实机验收

环境与口径：

- DevEco Studio 26.0（API 26／HarmonyOS 7.0.0）+ 模拟器 Mate 90 Pro（x86_64）。快照启动会 sysfreeze（`crash_report-2026-11-08T221337.zip` 的 detail 写 "Emulator found sysfreeze. Freeze type: Guest No Response"，sceneboard 连续 appfreeze），必须 `Emulator.exe -start "Mate 90 Pro" -bootMode coldboot` 冷启，约 4–5 分钟。
- 出包：`D:/venera/.scratch/harmony/app`（与 main 同步到 d5c6d55）跑 oh347-build-hap-x64.bat，assembleHap 151.6s，HAP 64,154,703 字节。
- 装机：`hdc install -r` 可装未签名包；`aa start` 报 10106102（锁屏）时先 `uitest uiInput swipe` 解锁再启。
- 自动化口径：`uitest uiInput click/text`、`uitest dumpLayout`、`snapshot_display` + `hdc file recv`；设备身份 uid=2000(shell)、无 root，读不到 app 私有目录，也没有 curl/wget。

三条链路结果（模拟器实测，非推断）：

1. **在线书源 ✔**：本地探针 JS 源（`source.js`，含 search/explore/comic/chapter 与 archive 段）导入后，搜索 → 详情 → 章节 → p1/p2/p3 三页上屏（页码 3/3），取图 UA 为 `VeneraUnified/v1.20.0-rc.1`，JS 内部 Network.get 走 Chrome/119 UA。
2. **本地归档 ✔**：探针源的 `comic.archive.getArchives/getDownloadUrl` 提供 cbz／zip／7z 三种归档；详情页 下载 → 归档 → 选中 → 确认后落本地库，阅读器直接读归档内图片——读 ZIP／CBZ 时服务端没有 p1/p2/p3 请求，证明读的是本地解压产物。
3. **WebDAV ✔（上传方向）**：自建 WebDAV 探针，测试连接得到 `PROPFIND /dav/ 207`；保存配置后 `OPTIONS` + `PUT /dav/<id>.venera 201`，服务端收到的 5,875 字节归档解出 6 项（history.db／local_favorite.db／cookie.db／appdata.json／comic_source/source.js 等）。下载方向本次未触发（实时同步判定远端无变更）。

为此必须改的两处代码（同一根因：只走 zip_flutter 原生库）：

| 位置 | 现象 | 处理 |
| --- | --- | --- |
| `lib/features/local_comics/archive_download_task.dart`（默认提取器） | 归档下载走 `ZipFile.openAndExtract`，绕过 CBZ 三级梯子；ohos 上 zip_flutter 的 Dart 入口在 `zip_flutter-0.0.13/lib/src/zip_dart_base.dart:23` 直接抛 `Unsupported operation: Unknown platform: ohos`（`_dylib` 只认 macOS／iOS／Android／Linux／Windows），HAP 里也没有 `libzip_flutter.so` | 非 Android 分支改调 `CBZ.extractArchive`（zip_flutter → flutter_7zip → 纯 Dart archive 的三级降级）；Android SAF 分支原样保留 |
| `lib/features/sync/app_data_archive.dart` | 数据同步与「导出应用数据」的备份 zip 用 `ZipFile.open` 原生写，ohos 上同样抛 Unknown platform，保存配置报「保存失败」 | 抽出 `_writeZip`：先试原生写，异常则删半成品并改用 `archive_io.ZipEncoder` 纯 Dart 编码；解压侧 `_extractZip` 本就是纯 Dart，未动 |

仍缺（未修／未验）：

- 「导出为 cbz／zip」仍走 `lib/features/local_comics/local_comics_page.dart:697` 的 `ZipFile.compressFolderAsync`，ohos 上会报 Unknown platform，本地库导出这条没通。
- 导入本地文件只能靠路径输入框（file_selector 无 ohos 实现），且模拟器 shell 读不到 app 目录，本轮无法从设备外塞文件验证「导入」入口本身；改由归档下载覆盖同一套解压梯子。
- WebDAV 下载方向、真机（未签名 HAP 需 DevEco 自动签名）仍未验。

门禁：`dart format`（两个文件 0 changed）、`dart analyze lib/features/local_comics lib/features/sync` No issues、`flutter test test/features/local_comics test/features/sync` 1172 通过（1 项 crash 测试在并行负载下因 Windows 文件占用 flaky，单独重跑 6/6 通过）、两个架构脚本 clean。

