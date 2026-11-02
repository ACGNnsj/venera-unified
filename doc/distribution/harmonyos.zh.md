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

这条错误无法靠改本仓绕过：TargetPlatform 枚举由 SDK 决定，3.47.8 没有 ohos 值，写 case TargetPlatform.ohos: 会让主分支编译失败，只能统一改成 default: 或给每个包打本地分支。

## 要走通 P2 还需要

1. 逐处给 switch (platform) 补 default（本仓 lib/ 可改；pub 包只能 dependency_overrides 指向本地打过补丁的副本）。
2. 换鸿蒙分支依赖：flutter_inappwebview（gitcode 6.1.5-ohos-1.0.1）、code_assets（openharmony-sig fork，需与本机 Flutter 版本对齐）、lodepng_flutter 与 flutter_7zip（venera-app fork）。
3. 原生产物：rhttp 需 aarch64-unknown-linux-ohos 交叉编译，另有 flutter_qjs、7zip、lodepng、sqlite3（本仓已升到 3.8.0，上游补丁锚定 2.7.4）的 OHOS 产物。
4. 签名：本机无华为开发者证书，未签名 HAP 只能靠 DevEco 登录账号自动签名或第三方自签工具。

## 上游自列的不可用项（移植后依然缺）

PDF 导入（PDFium）、自定义存储目录与持久化外部目录引用、系统分享、生物识别应用锁、Android 音量键 / SAF / 前台服务、已验证的 WebView 代理覆盖、部分平台专有图像编解码。

## 为什么不在 CI 里跑

上游的 harmonyos-experiment.yml 需要 Ubuntu + gitcode 的 flutter_flutter 与华为 OBS 引擎产物、RUSTUP_TOOLCHAIN=1.92.0 与 aarch64-unknown-linux-ohos 目标，单轮 100 分钟且只产出未签名 HAP。本仓把鸿蒙留在本地实验阶段，CI 不引入第二套工具链。
