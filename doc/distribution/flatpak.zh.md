# Flatpak 打包与离线构建

本仓库用 `flatpak/manifest.template.yml` 生成 `io.github.venera.unified.yml`，由
`.github/workflows/flatpak-build.yml` 在 ubuntu-24.04 runner 上做「联网预热 → 离线复建 → 冒烟启动」三段验证。

## 组成

- `flatpak/manifest.template.yml`：唯一的真相来源。占位符 `@@FLUTTER_VERSION@@`、`@@RELEASE_BASE@@`、
  `@@SOURCE_TAG@@` 与三份归档的 `@@*_ASSET@@` / `@@*_SHA256@@` 由渲染脚本替换。
- `flatpak/shared-modules/libayatana-appindicator/`：托盘用的 libayatana-appindicator 及其依赖
  （intltool / libdbusmenu / ayatana-ido / libayatana-indicator），取自 flathub/shared-modules。
- `.github/workflows/flatpak-vendor.yml`：把**发布标签**的依赖树预先抓成三份归档并挂到 Release。
- `.github/workflows/flatpak-build.yml`：真正的构建演练。

## 为什么需要 vendor 归档

Flatpak 构建沙箱没有网络，而 Flutter 这条链在构建期会联网做四件事：

| 联网点 | 归档与处理 |
|---|---|
| Flutter SDK 下载 | `flutter-sdk` 模块直接用官方 linux tar.xz，`@@FLUTTER_SHA256@@` 锁定 |
| 引擎产物 / pub 依赖 / cargo 依赖 | `engine-artifacts`、`pub-cache`、`cargo-vendor` 三份归档，挂在 Release 上由 manifest 引用 |
| `pdfium_dart` 的 hook 下载 libpdfium | `.github/scripts/patch_pdfium_hook.py` 把 hook 改成优先读 `/app/pdfium/lib/libpdfium.so` |
| `sqlite3` 的 hook 下载 prebuilt | `.github/scripts/patch_sqlite3_hook.py` + `stage_sqlite3_asset.py`，按版本落到 `/app/sqlite3` |
| ONNX Runtime（`flutter_onnxruntime`） | 归档里带 `onnxruntime/`，manifest 摊到插件期望的 `CMAKE_CURRENT_BINARY_DIR/onnxruntime` 命中其存在性检查 |

更新依赖树（例如发新 tag 之后）：

```bash
gh workflow run flatpak-vendor.yml --ref main \
  -f tag=v1.20.0 -f ref=main -f upload_to_release=true
```

`ref` 决定**脚本与模板**用哪份提交（默认 main），依赖树永远按 `tag` 取——这样修 vendor 脚本不必回改旧标签。

只改了 manifest 时不必重跑 vendor：在 Release 上抓最新的 `io.github.venera.unified.yml`，用同版本的模板渲染覆盖即可。

## 构建演练

```bash
gh workflow run flatpak-build.yml --ref main -f tag=v1.20.0
```

三段：

1. **联网预热**：正常 `flatpak-builder --user --install`，把各模块（含应用本身）写进构建缓存。
2. **离线复建**：`--disable-download --force-clean` 重跑，靠缓存直接 checkout。这一步证明「只靠 Release 归档就能构建」。
3. **冒烟启动**：`xvfb-run -a timeout 60 flatpak run --user io.github.venera.unified`，退出码 124 表示存活 60 秒即通过；出现
   `error while loading shared libraries` 或缺库日志立即失败并打印 `smoke.log`。

## 构建期踩过的坑（都在 manifest 里固化了）

- **cargokit 会自己跑 pub**：`packages/rhttp/cargokit/run_build_tool.sh` 与缓存里第三方插件的同名脚本都要加 `--offline`；
  vendor 阶段由 `patch_cargokit_offline.py` 统一打补丁。
- **cargokit 依赖 rustup**：`org.freedesktop.Sdk.Extension.rust-stable` 只有 cargo/rustc，manifest 里放了一个 `rustup` 替身
  （`.rustup-shim/rustup`，只实现 `toolchain/target/component/run`），并写 `cargokit_options.yaml` 关闭预编译产物下载。
- **PUB_CACHE 不能落在构建目录**：pub 拒绝任何位于缓存根下的项目根（否则 `Cannot operate on packages inside the cache.`），
  所以缓存搬去 `/app/pub-cache`、构建结束再删掉。
- **每条 build-command 是独立 shell**：跨命令只能用模块级 `build-options.env` 传参，`export` 不生效。
- **插件 crate 要一起 vendor**：`super_native_extensions` 自带 git 依赖，vendor 阶段扫 `*/rust/Cargo.toml` 逐个
  `cargo vendor --no-delete --versioned-dirs`；目录必须带版本号，否则同名不同版本的 crate 会互相覆盖（`bytes` 1.6 与 1.12）。
- **GNOME SDK 不带编译器**：要 `org.freedesktop.Sdk.Extension.llvm18`；它的 libayatana-appindicator 把
  `app_indicator_new` 标了 deprecated，而 `tray_manager` 带 `-Werror`，故给模块加 `CFLAGS/CXXFLAGS=-Wno-deprecated-declarations`。
- **bundle 必须整目录落在同一处**：Flutter 按 `$ORIGIN/lib` 找插件库、按 `$ORIGIN/data` 找资源，装成
  `/app/lib/venera-unified/` 后由 `/app/bin/venera-unified` 转发；插件 `DT_NEEDED` 没有 rpath，启动脚本里补
  `LD_LIBRARY_PATH=/app/lib/venera-unified/lib`。
- **ONNX Runtime 的 soname 是 `libonnxruntime.so.1`**：flutter 的 `bundled_libraries` 只复制一个文件，构建收尾要补两条符号链接。

## 已知限制

- runtime 是 GNOME 48（`org.freedesktop.Platform` 24.08 派生），CI 会提示该 runtime 已 EOL；迁移到新 runtime 需要重新验证。
- 只验证到「能安装、能离线复建、能启动不崩」；托盘图标、读取本地漫画库、WebDAV 同步等交互未在 CI 覆盖。
- 尚未提交 Flathub：需要先补齐 appstream 元数据、截图与持续维护者，属于发布流程之外的一步。
