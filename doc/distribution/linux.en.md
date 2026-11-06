# Linux installation and distribution

[简体中文](linux.zh.md) · [README](../../README.en.md#linux)

Pick the asset matching `uname -m` from the [latest stable release](https://github.com/ACGNnsj/venera-unified/releases/latest): `x86_64` maps to x64 / amd64 / x86_64, `aarch64` maps to ARM64 / arm64 / aarch64. The current stable release, [v1.20.0](https://github.com/ACGNnsj/venera-unified/releases/tag/v1.20.0), ships DEB, RPM and AppImage for both architectures plus an x86_64 Arch package. Development builds are artifacts of the **构建** (Build) workflow.

## Installation

The filenames below are the real v1.20.0 assets. RPM and Arch filenames carry the build number (the `246` in `1.20.0-246`); yours may differ, the rest is stable.

```bash
# Debian / Ubuntu
sudo apt install ./venera-unified_1.20.0_amd64.deb

# Fedora and compatible RPM distributions
sudo dnf install ./venera-unified-1.20.0-246.x86_64.rpm

# Arch Linux (x86_64 only)
sudo pacman -U venera-unified-1.20.0-246-x86_64.pkg.tar.zst
```

All three place a `/usr/bin/venera-unified` entry point, usable from the application menu or a terminal. Re-run the same install command to upgrade; remove with `sudo apt remove venera-unified` or `sudo dnf remove venera-unified`. These packages do not configure an update repository.

| Format | Installed under |
| --- | --- |
| DEB | `/usr/local/lib/venera-unified` (binary plus `lib`/`data`) |
| RPM | `/opt/venera-unified`, symlinked to `/usr/bin/venera-unified` |
| Arch | `/usr/bin/venera-unified_pkg`, symlinked to `/usr/bin/venera-unified` |

## AppImage

```bash
chmod +x VeneraUnified-1.20.0+246-x86_64.AppImage
./VeneraUnified-1.20.0+246-x86_64.AppImage
# Run without FUSE when mounting is unavailable:
./VeneraUnified-1.20.0+246-x86_64.AppImage --appimage-extract-and-run
```

Use the `aarch64` asset for ARM64. The filename carries the full pubspec version (`1.20.0+246`), and together with the `usr/lib/venera-unified` layout inside it forms the relocatable structure. No administrator rights or menu entries are involved; replace the file to upgrade, and application data stays in your user data directory.

## Compatibility and dependencies

Linux binaries are built on Ubuntu 24.04, so the glibc baseline is **2.39**. Older distributions (including RHEL / Rocky / AlmaLinux 9 at glibc 2.34) are not supported, and AppImage cannot bypass that. 24.04 rather than 22.04 is used because the reader's Linux AVIF fallback `dlopen`s the system `libavif16` and the AppImage bundles it; on 22.04 libavif would have to be built from source.

DEB / RPM / Arch get GTK 3, WebKitGTK 4.1, libavif and friends from the package manager; RPM records ELF symbol requirements, so missing dependencies reject the install. The AppImage bundles Flutter, GTK 3, WebKitGTK 4.1, its helper processes, image loaders and runtime resources, but still needs host glibc 2.39+ and a working OpenGL/EGL driver.

The already published **v1.17.0-rc.1 AppImage** is a different story: its filename still contains `linux` and it does not bundle GTK/WebKit, so that release needs the host packages; DEB/RPM have always used system dependencies:

```bash
sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0  # Ubuntu / Debian
sudo dnf install gtk3 webkit2gtk4.1             # Fedora
```

## GitHub Actions and packaging

DEB builds use `python3 debian/build.py x64` or `python3 debian/build.py arm64` and the system `dpkg-deb`, without installing `flutter_to_debian`. Run `flutter pub get --enforce-lockfile` first; add `--skip-build` to package an existing bundle. Output goes to `build/linux/<arch>/release/debian/`. The script owns dependencies, desktop entries and the `/usr/local/lib/venera-unified` install path; it never rewrites repository templates. Quality checks build and extract DEBs from ELF fixtures for both architectures, which does not replace a real install and launch test.

The Linux x64 / ARM64 switches in **构建** build DEB, RPM and AppImage for that architecture, and x64 additionally builds the Arch package. The release workflow collects every asset; the extra workflow artifacts are named `linux_extra_x64`, `linux_extra_arm64` and `arch_build`.

Packaging from an existing Flutter bundle on a runner:

```bash
sudo apt install rpm squashfs-tools desktop-file-utils file
python3 .github/scripts/build_linux_packages.py --arch x64
# Use --arch arm64 on an ARM64 runner.
```

The script validates ELF architecture and Flutter resources, builds and inspects the RPM, then recursively collects AppImage ELF dependencies and re-verifies the closure after extraction, including WebKit helpers and relocatable resource paths. Only glibc and graphics drivers stay host interfaces; any other missing library fails packaging. Dependency versions and copyright notices land in `usr/share/doc/venera-unified-runtime/`.

See the Linux install steps in `.github/workflows/build.yml` for the GTK/WebKit build packages. Afterwards run `bash .github/scripts/test_appimage.sh x64` (or `arm64`) with a C compiler, pkg-config and Docker: it boots an Ubuntu 24.04 container without GTK/WebKit, and the real application window plus a WebKit helper loading HTML must come up. CI runs it for both architectures before uploading; the container-only WebKit sandbox override is never shipped in the launcher.

A second pass relaxes Docker's outer seccomp/AppArmor policies and masked system paths, then explicitly enables WebKit's own sandbox. Ubuntu release builds ignore `WEBKIT_EXEC_PATH`, so the launcher relocates compiled-in helper paths in a private library copy under a mode-0700 `/tmp` directory, cleaned up on exit, never touching the system or the original AppImage. `/tmp` must be writable and executable with roughly 100 MB free; unsupported WebKit path layouts fail explicitly.

Packaging pins appimagetool 1.9.1 and type2-runtime 20251108 with per-architecture SHA-256 checks and needs no FUSE. Outputs are in `build/linux/<architecture>/packages/`. To roll back, restore the previous packaging scripts and workflow and rebuild; those images require host GTK/WebKit again. Application data formats are unchanged.

## Flatpak

Flatpak is **still being verified**. It is not release-gated and no Flatpak asset is offered to end users yet. The current skeleton:

- `flatpak/manifest.template.yml` is the single hand-written manifest; `flatpak/flutter-sha256.json` caches the official Flutter tarball hashes.
- After a release, run the **Flatpak 离线依赖归档** workflow by hand: it hashes the pub-cache, engine-artifact and cargo-vendor archives, renders `io.github.venera.unified.yml` from the template, and uploads all of it to that tag's release.
- Then run **Flatpak 离线构建验证**: one networked prewarm build, one `--offline` rebuild, and an xvfb launch smoke. Do not submit to Flathub before that job is green.

The manifest takes Flutter from the official tarball (sha256-pinned), pub dependencies from an `--offline` `PUB_CACHE`, and Rust from `cargo vendor` source replacement plus `org.freedesktop.Sdk.Extension.rust-stable`, so the build needs no network.
