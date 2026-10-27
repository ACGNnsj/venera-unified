#!/usr/bin/env python3
"""校验各平台的发布身份彼此一致。

fork 一份上游项目后，最容易漏掉的不是代码，而是散在四个平台里的标识：
Android 的 applicationId、macOS/iOS 的 PRODUCT_BUNDLE_IDENTIFIER、
Linux 的 APPLICATION_ID、Windows 安装包的 MyAppName。任何一处没跟着改，
产物就会自称是另一个应用（或与用户数据目录对不上）。

这个脚本只做一件事：把这些值读出来，断言它们指向同一个身份，
并断言 Dart 包名是包标识最后一段的下划线写法。它不改任何东西。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

BUNDLE_ID_RE = re.compile(r'^\s*applicationId\s*=?\s*"?([\w.\-]+)"?', re.MULTILINE)
NS_BUNDLE_RE = re.compile(
    r"^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([\w.\-]+);?", re.MULTILINE
)
LINUX_ID_RE = re.compile(r'set\(APPLICATION_ID\s+"([\w.\-]+)"\)')
ISS_NAME_RE = re.compile(r'^#define\s+MyAppName\s+"([^"]+)"', re.MULTILINE)
ISS_EXE_RE = re.compile(r'^#define\s+MyAppExeName\s+"([^"]+)"', re.MULTILINE)
ISS_APPID_RE = re.compile(r"^AppId=\{\{?([0-9A-Fa-f\-]{36})", re.MULTILINE)
PUBSPEC_NAME_RE = re.compile(r"^name:\s*(\S+)", re.MULTILINE)


class IdentityError(Exception):
    pass


def _read(root: Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        raise IdentityError(f"缺少文件：{relative}")
    return path.read_text(encoding="utf-8")


def _single(pattern: re.Pattern[str], text: str, what: str) -> str:
    found = pattern.findall(text)
    if not found:
        raise IdentityError(f"没找到 {what}")
    values = {value for value in found}
    if len(values) > 1:
        raise IdentityError(f"{what} 有多个不一致的取值：{sorted(values)}")
    return values.pop()


def collect(root: Path) -> dict[str, str]:
    android = _single(BUNDLE_ID_RE, _read(root, "android/app/build.gradle"), "Android applicationId")

    macos_ids = NS_BUNDLE_RE.findall(_read(root, "macos/Runner/Configs/AppInfo.xcconfig"))
    if not macos_ids:
        raise IdentityError("没找到 macOS PRODUCT_BUNDLE_IDENTIFIER")
    macos = macos_ids[0]

    # RunnerTests 之类带后缀的标识是测试宿主，不参与身份校验。
    ios_all = NS_BUNDLE_RE.findall(_read(root, "ios/Runner.xcodeproj/project.pbxproj"))
    ios_ids = {value for value in ios_all if not value.endswith(".RunnerTests")}
    if not ios_ids:
        raise IdentityError("没找到 iOS PRODUCT_BUNDLE_IDENTIFIER")
    if len(ios_ids) > 1:
        raise IdentityError(f"iOS PRODUCT_BUNDLE_IDENTIFIER 有多个不一致的取值：{sorted(ios_ids)}")

    linux = _single(LINUX_ID_RE, _read(root, "linux/CMakeLists.txt"), "Linux APPLICATION_ID")

    iss = _read(root, "windows/build.iss")
    windows_name = _single(ISS_NAME_RE, iss, "Windows MyAppName")
    windows_exe = _single(ISS_EXE_RE, iss, "Windows MyAppExeName")
    windows_app_id = _single(ISS_APPID_RE, iss, "Windows AppId GUID")

    dart_name = _single(PUBSPEC_NAME_RE, _read(root, "pubspec.yaml"), "pubspec 的 name")

    return {
        "android": android,
        "macos": macos,
        "ios": next(iter(ios_ids)),
        "linux": linux,
        "windows_name": windows_name,
        "windows_exe": windows_exe,
        "windows_app_id": windows_app_id,
        "dart_name": dart_name,
    }


def check(identity: dict[str, str]) -> list[str]:
    problems: list[str] = []

    bundle_ids = {
        "android": identity["android"],
        "macos": identity["macos"],
        "ios": identity["ios"],
        "linux": identity["linux"],
    }
    if len(set(bundle_ids.values())) != 1:
        formatted = ", ".join(f"{key}={value}" for key, value in bundle_ids.items())
        problems.append(f"各平台包标识不一致：{formatted}")
    else:
        bundle = bundle_ids["android"]
        tokens = [token for token in identity["dart_name"].split("_") if token]
        missing = [token for token in tokens if token not in bundle]
        if not tokens or missing:
            problems.append(
                f"Dart 包名 {identity['dart_name']!r} 与包标识 {bundle!r} 不同源，"
                f"缺少片段：{missing or tokens}"
            )

    # Windows 的可执行文件名与产品名必须来自同一个词：Venera Unified -> VeneraUnified.exe。
    expected_exe = identity["windows_name"].replace(" ", "") + ".exe"
    if identity["windows_exe"] != expected_exe:
        problems.append(
            f"Windows 可执行名 {identity['windows_exe']!r} 与产品名 "
            f"{identity['windows_name']!r} 不同源，应为 {expected_exe!r}"
        )

    if not re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", identity["windows_app_id"]):
        problems.append(f"Windows AppId 不是合法 GUID：{identity['windows_app_id']!r}")

    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="仓库根目录，默认当前目录")
    args = parser.parse_args(argv)

    root = Path(args.root)
    try:
        identity = collect(root)
    except IdentityError as error:
        print(f"::error::发布身份校验失败：{error}")
        return 1

    problems = check(identity)
    if problems:
        for problem in problems:
            print(f"::error::发布身份校验失败：{problem}")
        return 1

    print(
        "发布身份一致：{bundle}（Dart 包 {dart}，Windows {name} / {exe}）".format(
            bundle=identity["android"],
            dart=identity["dart_name"],
            name=identity["windows_name"],
            exe=identity["windows_exe"],
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
