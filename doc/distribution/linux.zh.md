# Linux 安装与分发

[English](linux.en.md) · [返回 README](../../README.md#linux)

从 [最新稳定版](https://github.com/ACGNnsj/venera-unified/releases/latest) 下载与机器架构对应的包。`uname -m` 输出 `x86_64` 时选 x64 / amd64 / x86_64，输出 `aarch64` 时选 ARM64 / arm64 / aarch64。当前稳定版 [v1.20.0](https://github.com/ACGNnsj/venera-unified/releases/tag/v1.20.0) 提供两种架构的 DEB、RPM 和 AppImage，以及 x86_64 的 Arch 包；开发构建产物可在 GitHub Actions 的「构建」工作流里下载。

## 安装

下面用 v1.20.0 的真实文件名举例。RPM 与 Arch 包的文件名带构建号（`+246` 里的 `246`），实际下载到的可能是别的数字，其余部分不变。

```bash
# Debian / Ubuntu
sudo apt install ./venera-unified_1.20.0_amd64.deb

# Fedora 及提供对应依赖的红帽系发行版
sudo dnf install ./venera-unified-1.20.0-246.x86_64.rpm

# Arch Linux（目前仅提供 x86_64）
sudo pacman -U venera-unified-1.20.0-246-x86_64.pkg.tar.zst
```

三种包都会在 `/usr/bin/venera-unified` 放一个可执行入口，可从应用菜单或命令行启动。DEB 与 RPM 升级时重复执行上面的安装命令即可，卸载用 `sudo apt remove venera-unified` 或 `sudo dnf remove venera-unified`。这些下载包不配置自动更新仓库。

| 格式 | 实际安装位置 |
| --- | --- |
| DEB | `/usr/local/lib/venera-unified`（二进制与 `lib`/`data` 同目录） |
| RPM | `/opt/venera-unified`，入口软链到 `/usr/bin/venera-unified` |
| Arch | `/usr/bin/venera-unified_pkg`，入口软链到 `/usr/bin/venera-unified` |

## AppImage

```bash
chmod +x VeneraUnified-1.20.0+246-x86_64.AppImage
./VeneraUnified-1.20.0+246-x86_64.AppImage
```

ARM64 用文件名含 `aarch64` 的版本。AppImage 文件名带 pubspec 的完整版本号（形如 `1.20.0+246`），和解压目录 `usr/lib/venera-unified` 里的布局一起构成可重定位结构。无法挂载 FUSE 时改用解包运行：

```bash
./VeneraUnified-1.20.0+246-x86_64.AppImage --appimage-extract-and-run
```

AppImage 不需要管理员权限，也不装菜单入口；换新文件即完成升级。应用数据仍写在系统用户数据目录，不落在 AppImage 文件内。

## 系统依赖与兼容范围

Linux 构建在 Ubuntu 24.04 上完成，glibc 基线因此是 **2.39**：比这更老的发行版（含 RHEL / Rocky / AlmaLinux 9 的 2.34）不能保证运行，AppImage 也绕不过这条限制。选 24.04 而不是 22.04 是因为要直接吃系统自带的 `libavif16`：阅读器的 Linux AVIF 回退会 `dlopen` 它，AppImage 也把它打包进去；放在 22.04 上得从源码编 libavif。

DEB / RPM / Arch 包通过包管理器获取 GTK 3、WebKitGTK 4.1、libavif 等系统依赖；RPM 用 ELF 依赖检测记录所需符号版本，缺依赖时包管理器会拒绝安装。AppImage 自带 Flutter、GTK 3、WebKitGTK 4.1、WebKit 子进程、图片加载器与运行资源，但仍需宿主提供 glibc 2.39+ 和可用的 OpenGL/EGL 驱动。

已经发布的 **v1.17.0-rc.1 AppImage** 是另一套口径：文件名还带 `linux`、也不打包 GTK/WebKit，需要手动装齐运行依赖。DEB/RPM 从那时起一直走包管理器取系统依赖：

```bash
# Ubuntu 24.04 / Debian 等
sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0

# Fedora
sudo dnf install gtk3 webkit2gtk4.1
```

## GitHub Actions 与本地打包

DEB 由 `python3 debian/build.py x64` 或 `python3 debian/build.py arm64` 构建，用系统 `dpkg-deb`，不依赖 `flutter_to_debian`。先跑 `flutter pub get --enforce-lockfile`；已有对应架构的 Release bundle 时可加 `--skip-build`。输出在 `build/linux/<架构>/release/debian/`。安装路径、桌面入口与依赖都由脚本维护，固定装在 `/usr/local/lib/venera-unified`，不修改仓库里的模板文件。质量检查会用两种架构的 ELF 测试数据跑 DEB 打包与解包，这不代替真机安装与启动验证。

「构建」工作流的 Linux x64 / ARM64 开关分别控制对应架构的 DEB、RPM、AppImage；x64 还会额外生成 Arch 包。完整发布工作流收集所有产物并上传 Release，产物名分别为 `linux_extra_x64`、`linux_extra_arm64` 与 `arch_build`。

在 runner 上从已有的 Flutter bundle 出发打 RPM 与 AppImage：

```bash
sudo apt install rpm squashfs-tools desktop-file-utils file
python3 .github/scripts/build_linux_packages.py --arch x64
# ARM64 runner 用 --arch arm64
```

脚本会校验 ELF 架构与 Flutter 资源，生成并检查 RPM；AppImage 递归收集 ELF 依赖、检查 WebKit 辅助进程与可重定位资源路径，解包后再验一次依赖闭包。glibc 与显卡驱动留给宿主，其余缺库会让构建失败。依赖版本清单与版权说明打在包内 `usr/share/doc/venera-unified-runtime/`。

AppImage 构建所需的 GTK/WebKit 开发包与运行资源见 `.github/workflows/build.yml` 的 Linux 安装步骤。构建后跑 `bash .github/scripts/test_appimage.sh x64`（ARM64 用 `arm64`），需要 C 编译器、pkg-config 与 Docker：它会在不装 GTK/WebKit 的 Ubuntu 容器里验证真实应用窗口与 WebKit 子进程加载 HTML。两个架构都在 CI 上传产物前执行这一步，容器测试专用的 WebKit 沙箱关闭设置不会写进分发包。

检查还会放开外层 Docker 的 seccomp/AppArmor 与系统路径遮蔽，再显式开启 WebKit 自身沙箱复验。Ubuntu 的 WebKit 发布版不支持用 `WEBKIT_EXEC_PATH` 重定位，因此启动器会在权限 0700 的 `/tmp` 私有目录里生成库副本、替换子进程与沙箱辅助程序路径，退出时清理，不动系统或原始 AppImage。运行时需要 `/tmp` 可写可执行，并留出约 100 MB 空间；不认识的 WebKit 路径布局会明确失败。

AppImage 工具固定在 appimagetool 1.9.1 与 type2-runtime 20251108，两个架构的 SHA-256 分别校验，打包不需要 FUSE。产物在 `build/linux/<架构>/packages/`。需要回滚时恢复旧的打包脚本与工作流重新构建即可；回滚产物要用户自行安装 GTK/WebKit，应用数据格式不受影响。

## Flatpak

Flatpak 还是**验证中**的状态，不在发布门控里，也不出现在 Release 资产中给普通用户下载。当前的骨架是：

- `flatpak/manifest.template.yml` 是唯一手写的清单，`flatpak/flutter-sha256.json` 缓存各 Flutter 版本的官方 sha256。
- 发版后手动跑「Flatpak 离线依赖归档」工作流：它把 pub-cache、引擎产物、cargo vendor 三份归档算好 sha256，渲染出 `io.github.venera.unified.yml`，并挂到该标签的 Release 上。
- 再手动跑「Flatpak 离线构建验证」：联网预热一次，再用 `--disable-download` 复建一次（flatpak-builder 没有 `--offline` 开关，靠预热那次把源留在缓存里实现等价离线），最后用 xvfb 起窗口做烟测。这一条跑绿之前不要往 Flathub 提交。

清单里 Flutter 走官方 tarball（校验 sha256），pub 依赖走 `--offline` 的 `PUB_CACHE`，Rust 走 `cargo vendor` 的 source replacement 加 `org.freedesktop.Sdk.Extension.rust-stable`，全程不需要构建期联网。
