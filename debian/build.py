"""Build and package Venera Unified with the system dpkg-deb tool."""

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".github/scripts"))
from build_linux_packages import desktop_file, stage_bundle, validate_bundle, versions

DEBIAN_ARCHES = {"x64": "amd64", "arm64": "arm64"}
# Preserve the existing DEB installation directory across upgrades.
INSTALL_PATH = "usr/local/lib/venera-unified"


def stage_package(bundle, stage, arch, version):
    validate_bundle(bundle, arch)
    deb_version, _ = versions(version)
    stage_bundle(bundle, stage / INSTALL_PATH)
    control = stage / "DEBIAN"
    control.mkdir()
    (control / "control").write_text(
        "Package: venera-unified\n"
        f"Version: {deb_version}\n"
        f"Architecture: {DEBIAN_ARCHES[arch]}\n"
        "Section: graphics\nPriority: optional\n"
        # libavif backs the reader's AVIF fallback: the Linux engine cannot
        # decode AVIF itself, so the package must pull in the system decoder.
        "Depends: libwebkit2gtk-4.1-0, libgtk-3-0, libavif16\n"
        "Maintainer: CyrilPeng <https://github.com/ACGNnsj/venera-unified>\n"
        "Description: Venera Unified comic reader\n",
        encoding="utf-8",
    )
    applications = stage / "usr/share/applications"
    applications.mkdir(parents=True)
    (applications / "venera-unified.desktop").write_text(
        desktop_file(f"/{INSTALL_PATH}/venera-unified"), encoding="utf-8"
    )
    icons = stage / "usr/share/icons/hicolor/256x256/apps"
    icons.mkdir(parents=True)
    shutil.copyfile(ROOT / "debian/gui/venera-unified.png", icons / "venera-unified.png")


def package_bundle(bundle, output, arch, version):
    deb_version, _ = versions(version)
    output.mkdir(parents=True, exist_ok=True)
    package = output / f"venera-unified_{deb_version}_{DEBIAN_ARCHES[arch]}.deb"
    with tempfile.TemporaryDirectory(prefix="venera-deb-") as temp:
        stage = Path(temp) / "package"
        stage_package(bundle, stage, arch, version)
        temporary_package = Path(temp) / package.name
        subprocess.run(
            ["dpkg-deb", "--root-owner-group", "--build", str(stage), str(temporary_package)],
            check=True,
        )
        # Do not replace an existing artifact until dpkg-deb succeeds.
        shutil.copyfile(temporary_package, package)
    return package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arch", choices=DEBIAN_ARCHES)
    parser.add_argument("--skip-build", action="store_true", help="Package an existing release bundle")
    args = parser.parse_args()
    match = re.search(r"^version:\s*(\S+)", (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
    if match is None:
        raise ValueError("Missing pubspec version")
    if not args.skip_build:
        subprocess.run(["flutter", "build", "linux", "--release", "--no-pub"], cwd=ROOT, check=True)
    release = ROOT / "build/linux" / args.arch / "release"
    print(package_bundle(release / "bundle", release / "debian", args.arch, match[1]))


if __name__ == "__main__":
    main()
