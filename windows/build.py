import argparse
from pathlib import Path
import hashlib
import os
import sys
import platform
import re
import shutil
import subprocess
import zipfile
from urllib.request import Request, urlopen
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_BUILD_DIR = ROOT / "build" / "windows"
WINDOWS_ICON_PATH = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
CHINESE_TRANSLATION_PATH = ROOT / "windows" / "ChineseSimplified.isl"
CHINESE_TRANSLATION_URL = (
    "https://cdn.jsdelivr.net/gh/kira-96/"
    "Inno-Setup-Chinese-Simplified-Translation@"
    "1ace6a485174288c7416d0979cc2db1f0990f95a/ChineseSimplified.isl"
)
CHINESE_TRANSLATION_SHA256 = (
    "bc76580176cba3303fb4b0edfd4c65557cc57dad09d1efc3f8d16557c0f2d694"
)
# MSIX 身份默认值只够侧载试用。提交微软商店时必须换成 Partner Center 在
# 「应用名保留」里分配的 Identity Name 与 Publisher：二者与账号绑定，错一个
# 字符上传就会被拒。用环境变量覆盖即可，不必改代码。
MSIX_IDENTITY_NAME = os.environ.get("MSIX_IDENTITY_NAME") or "ACGNnsj.VeneraUnified"
MSIX_PUBLISHER = os.environ.get("MSIX_PUBLISHER") or "CN=ACGNnsj"
MSIX_PUBLISHER_DISPLAY_NAME = (
    os.environ.get("MSIX_PUBLISHER_DISPLAY_NAME") or "ACGNnsj"
)
# 清单里的 Package/Properties/DisplayName 与 VisualElements 的 DisplayName 两处都必须
# 是 Partner Center 里已保留的应用名，否则商店报「使用了你未保留的显示名称」。
# 保留名就是 Identity Name 里点号后面那一段（形如 <发行方>.<应用名>），所以默认从
# MSIX_IDENTITY_NAME 推导，不写死，也不必再多配一条仓库变量。
def _default_msix_display_name():
    _, dot, app_name = MSIX_IDENTITY_NAME.partition(".")
    return app_name if dot else MSIX_IDENTITY_NAME


MSIX_DISPLAY_NAME = os.environ.get("MSIX_DISPLAY_NAME") or _default_msix_display_name()
APPX_MANIFEST_TEMPLATE = ROOT / "windows" / "appx" / "AppxManifest.xml"
APPX_LOGO_SOURCE = ROOT / "assets" / "app_icon.png"
APPX_LOGO_NAMES = ("Square44x44Logo.png", "Square150x150Logo.png", "StoreLogo.png")


def run(command):
    executable = shutil.which(command[0])
    if executable is None:
        raise FileNotFoundError(command[0])
    subprocess.run([executable, *command[1:]], check=True, cwd=ROOT)


def read_version():
    content = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^\s]+)", content, re.MULTILINE)
    if match is None:
        raise RuntimeError("pubspec.yaml does not contain a version field")
    version = match.group(1).split("+", 1)[0]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError(f"Unsafe package version: {version}")
    return version


def read_msix_version():
    """MSIX 版本号：pubspec 的 1.19.0+245 映射成 1.19.0.0。

    第四段是「修订号」，微软商店硬性要求为 0（否则上传报「不允许指定版本号
    不为零的版本」），侧载也一样用这个值。代价是同版本号重装需要先卸载，
    跨补丁版本（1.19.0 → 1.19.1）仍能正常升级。
    """
    content = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([^\s]+)", content, re.MULTILINE)
    if match is None:
        raise RuntimeError("pubspec.yaml does not contain a version field")
    base, _, _build = match.group(1).partition("+")
    base = base.split("-", 1)[0]  # 预发布后缀（-rc.1）不进 MSIX：它只要纯数字四段
    parts = [part for part in base.split(".") if part]
    if not parts or any(not part.isdigit() for part in parts):
        raise ValueError(f"MSIX 需要纯数字版本号，pubspec 是 {base!r}")
    if len(parts) > 3:
        raise ValueError(f"MSIX 版本最多四段，pubspec 是 {base!r}")
    fields = (parts + ["0", "0", "0"])[:3] + ["0"]
    for field in fields:
        if int(field) > 65535:
            raise ValueError(f"MSIX 版本段超出 65535：{match.group(1)!r}")
    return ".".join(fields)


def require_non_empty_file(path):
    if not path.is_file():
        raise FileNotFoundError(path)
    if path.stat().st_size <= 0:
        raise RuntimeError(f"{path} is empty")


def architecture_paths(arch):
    if arch not in ("x64", "arm64"):
        raise ValueError(f"Unsupported Windows architecture: {arch}")
    runner = WINDOWS_BUILD_DIR / arch / "runner"
    suffix = "windows" if arch == "x64" else "windows-arm64"
    template = ROOT / "windows" / ("build.iss" if arch == "x64" else "build_arm64.iss")
    return runner, suffix, template


def remove_build_directory(path):
    # Resolve before recursive deletion, including junctions and symlinks.
    resolved = path.resolve()
    build_root = WINDOWS_BUILD_DIR.resolve()
    if resolved == build_root or not resolved.is_relative_to(build_root):
        raise ValueError(f"Build cleanup escapes its root: {path}")
    if path.exists():
        shutil.rmtree(path)


def clean_windows_runner_build(arch="x64"):
    runner, _, _ = architecture_paths(arch)
    remove_build_directory(runner)


def create_portable_zip(version, arch="x64"):
    runner, suffix, _ = architecture_paths(arch)
    release_dir = runner / "Release"
    if not release_dir.is_dir():
        raise FileNotFoundError(release_dir)

    zip_path = WINDOWS_BUILD_DIR / f"VeneraUnified-{version}-{suffix}.zip"
    package_dir = WINDOWS_BUILD_DIR / f"VeneraUnified-{version}-{suffix}"
    if zip_path.exists():
        zip_path.unlink()
    if package_dir.exists():
        remove_build_directory(package_dir)

    try:
        shutil.copytree(release_dir, package_dir)
        shutil.make_archive(
            str(zip_path.with_suffix("")),
            "zip",
            WINDOWS_BUILD_DIR,
            package_dir.name,
        )
        require_non_empty_file(zip_path)
        return zip_path
    finally:
        if package_dir.exists():
            remove_build_directory(package_dir)


def validate_icon_resources():
    require_non_empty_file(WINDOWS_ICON_PATH)


def ensure_chinese_translation():
    if CHINESE_TRANSLATION_PATH.exists():
        return

    request = Request(
        CHINESE_TRANSLATION_URL,
        headers={"User-Agent": "VeneraUnified-Windows-Build"},
    )
    with urlopen(request, timeout=30) as response:
        content = response.read()
    if not content:
        raise RuntimeError("Downloaded ChineseSimplified.isl is empty")
    digest = hashlib.sha256(content).hexdigest()
    if digest != CHINESE_TRANSLATION_SHA256:
        raise RuntimeError(
            "Downloaded ChineseSimplified.isl failed SHA256 verification: "
            f"{digest}"
        )

    temporary_path = CHINESE_TRANSLATION_PATH.with_suffix(".isl.tmp")
    temporary_path.write_bytes(content)
    temporary_path.replace(CHINESE_TRANSLATION_PATH)


def build_installer(version, arch="x64"):
    _, suffix, iss_path = architecture_paths(arch)
    iss_content = iss_path.read_bytes()
    rendered = iss_content.decode("utf-8").replace("{{version}}", version)
    rendered = rendered.replace("{{root_path}}", str(ROOT))
    installer_path = WINDOWS_BUILD_DIR / f"VeneraUnified-{version}-{suffix}-installer.exe"

    if installer_path.exists():
        installer_path.unlink()

    try:
        iss_path.write_text(rendered, encoding="utf-8")
        ensure_chinese_translation()
        run(["iscc", str(iss_path)])
    finally:
        iss_path.write_bytes(iss_content)

    require_non_empty_file(installer_path)
    return installer_path


def find_makeappx():
    """MakeAppx.exe 随 Windows SDK 安装，CI 上不在 PATH 里，需要自己找。"""
    executable = shutil.which("MakeAppx.exe") or shutil.which("makeappx")
    if executable is not None:
        return executable
    kits_root = Path(
        os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    ) / "Windows Kits" / "10" / "bin"
    if kits_root.is_dir():
        versions = sorted(path.name for path in kits_root.iterdir() if path.is_dir())
        for version in reversed(versions):
            candidate = kits_root / version / "x64" / "MakeAppx.exe"
            if candidate.is_file():
                return str(candidate)
    raise FileNotFoundError("MakeAppx.exe (Windows SDK) 未找到")


def create_msix(version, arch="x64"):
    """把 Release 目录打成 MSIX；不签名，微软商店会替我们签。"""
    runner, suffix, _ = architecture_paths(arch)
    release_dir = runner / "Release"
    if not release_dir.is_dir():
        raise FileNotFoundError(release_dir)
    require_non_empty_file(APPX_MANIFEST_TEMPLATE)
    require_non_empty_file(APPX_LOGO_SOURCE)

    package_name = f"VeneraUnified-{version}-{suffix}"
    msix_path = WINDOWS_BUILD_DIR / f"{package_name}.msix"
    layout_dir = WINDOWS_BUILD_DIR / f"{package_name}-appx"
    if msix_path.exists():
        msix_path.unlink()
    if layout_dir.exists():
        remove_build_directory(layout_dir)

    try:
        shutil.copytree(release_dir, layout_dir)
        assets_dir = layout_dir / "Assets"
        assets_dir.mkdir()
        # 一张 512x512 源图顶三个槽位：MSIX 只要文件存在，商店页素材另行提交。
        for name in APPX_LOGO_NAMES:
            shutil.copyfile(APPX_LOGO_SOURCE, assets_dir / name)
        rendered = APPX_MANIFEST_TEMPLATE.read_text(encoding="utf-8")
        substitutions = {
            "{{version}}": read_msix_version(),
            "{{identity_name}}": MSIX_IDENTITY_NAME,
            "{{publisher}}": MSIX_PUBLISHER,
            "{{publisher_display_name}}": MSIX_PUBLISHER_DISPLAY_NAME,
            "{{display_name}}": MSIX_DISPLAY_NAME,
            "{{processor_architecture}}": arch,
        }
        for placeholder, value in substitutions.items():
            rendered = rendered.replace(placeholder, escape(value, {'"': "&quot;"}))
        (layout_dir / "AppxManifest.xml").write_text(rendered, encoding="utf-8")
        subprocess.run(
            [
                find_makeappx(),
                "pack",
                "/o",
                "/d",
                str(layout_dir),
                "/p",
                str(msix_path),
            ],
            check=True,
            cwd=ROOT,
        )
    finally:
        if layout_dir.exists():
            remove_build_directory(layout_dir)

    require_non_empty_file(msix_path)
    return msix_path


def create_msixbundle(version, arch="x64"):
    """把 MSIX 打成一个 .msixbundle。"""
    _, suffix, _ = architecture_paths(arch)
    msix_path = WINDOWS_BUILD_DIR / f"VeneraUnified-{version}-{suffix}.msix"
    require_non_empty_file(msix_path)
    bundle_path = WINDOWS_BUILD_DIR / f"VeneraUnified-{version}-{suffix}.msixbundle"
    layout_dir = WINDOWS_BUILD_DIR / f"VeneraUnified-{version}-{suffix}-bundle"
    if bundle_path.exists():
        bundle_path.unlink()
    if layout_dir.exists():
        remove_build_directory(layout_dir)

    try:
        layout_dir.mkdir(parents=True)
        shutil.copyfile(msix_path, layout_dir / msix_path.name)
        subprocess.run(
            [
                find_makeappx(),
                "bundle",
                "/o",
                "/d",
                str(layout_dir),
                "/p",
                str(bundle_path),
                "/bv",
                read_msix_version(),
            ],
            check=True,
            cwd=ROOT,
        )
    finally:
        if layout_dir.exists():
            remove_build_directory(layout_dir)

    require_non_empty_file(bundle_path)
    return bundle_path


def create_msixupload(version, arch="x64"):
    """商店上传文件 .msixupload：一个 zip，里面装 .msixbundle（可再加符号包）。

    注意它不是一个 bundle。MakeAppx 只能产出 bundle；上传文件必须自己 zip，
    把 bundle 的杂项文件（AppxBundleManifest.xml 等）留在最外层会被商店判成
    「不受支持的文件」而拒收。
    """
    _, suffix, _ = architecture_paths(arch)
    bundle_path = WINDOWS_BUILD_DIR / f"VeneraUnified-{version}-{suffix}.msixbundle"
    require_non_empty_file(bundle_path)
    upload_path = WINDOWS_BUILD_DIR / f"VeneraUnified-{version}-{suffix}.msixupload"
    if upload_path.exists():
        upload_path.unlink()
    with zipfile.ZipFile(upload_path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(bundle_path, bundle_path.name)
    require_non_empty_file(upload_path)
    return upload_path


def _is_arm64_host():
    if platform.machine().lower() in ("arm64", "aarch64"):
        return True
    # Native CPU id under emulation (x64 Python on ARM64 Windows).
    return os.environ.get("PROCESSOR_ARCHITECTURE", "").upper() == "ARM64" or os.environ.get(
        "PROCESSOR_ARCHITEW6432", ""
    ).upper() == "ARM64"


def build_venera_native(arch="x64"):
    # Hand-rolled venera_* Rust crates: stage the DLLs next to the exe so
    # the zip/installer/MSIX pick them up and the dart:ffi binding resolves
    # them via the exe directory. Runs after `flutter build windows` because
    # clean_windows_runner_build wipes runner/ before the build.
    runner, _, _ = architecture_paths(arch)
    script = ROOT / ".github" / "scripts" / "build_venera_native.py"
    subprocess.run(
        [sys.executable, str(script), "windows",
         "--out", str(runner / "Release")],
        check=True, cwd=ROOT,
    )


def main(arch="x64"):
    architecture_paths(arch)
    version = read_version()
    validate_icon_resources()
    clean_windows_runner_build(arch)
    # `flutter build windows` has no --target-platform flag: it always builds
    # for the host architecture. ARM64 therefore requires an ARM64 runner
    # (windows-11-arm); refuse to run on x64 so x64 bits are never mislabeled
    # as windows-arm64 artifacts. PROCESSOR_* env vars report the native CPU
    # even when this interpreter itself runs emulated (x64 Python on ARM64).
    if arch == "arm64" and not _is_arm64_host():
        raise RuntimeError(
            "Windows ARM64 builds require an ARM64 host "
            f"(this host reports {platform.machine()!r})"
        )
    run(["flutter", "build", "windows"])
    build_venera_native(arch)
    create_portable_zip(version, arch)
    build_installer(version, arch)
    create_msix(version, arch)
    create_msixbundle(version, arch)
    create_msixupload(version, arch)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build Windows release packages")
    parser.add_argument("--arch", choices=("x64", "arm64"), default="x64")
    main(parser.parse_args().arch)
