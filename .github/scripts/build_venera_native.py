"""Build the hand-rolled venera Rust crates and stage them per platform.

Zero new dependencies (stdlib only). Each subcommand builds the three
cdylib crates (inpaint, ocr_preprocess, jpg_encode) with the locked
toolchain and copies the artifacts where the packager picks them up:

  android  -> android/app/src/main/jniLibs/<abi>/libvenera_*.so
  windows  -> --out dir/venera_*.dll (build.py passes Release/)
  linux    -> --out dir/libvenera_*.so (debian/build.py passes bundle/lib/)
  macos    -> --out dir/libvenera_*.dylib (lipo universal)
  ios      -> --out dir/libvenera_*.a (staticlib, via podspec)

cargo build is per-crate so one crate failure cannot hide another.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CRATES = ("native/inpaint", "native/ocr_preprocess", "native/jpg_encode", "native/image_transpose", "native/anime4k")

ANDROID_TARGETS = {
    "aarch64-linux-android": "arm64-v8a",
    "armv7-linux-androideabi": "armeabi-v7a",
    "x86_64-linux-android": "x86_64",
}


def run(cmd):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run(cmd, check=True, cwd=ROOT)


def cargo_build(crate, target=None):
    cmd = ["cargo", "build", "--locked", "--release",
           "--manifest-path", str(ROOT / crate / "Cargo.toml")]
    if target:
        cmd += ["--target", target]
    run(cmd)


def lib_name(crate):
    # Source of truth is the crate's own [package] name (always the first
    # `name =` in Cargo.toml); it may differ from the directory name
    # (e.g. native/image_transpose builds venera_transpose).
    for line in (ROOT / crate / "Cargo.toml").read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("name") and "=" in s:
            return s.split("=", 1)[1].strip().strip("\"'")
    return "venera_" + Path(crate).name


def artifact(crate, target, ext):
    name = lib_name(crate)
    stem = name if ext == ".dll" else "lib" + name
    if ext == ".a":
        stem = "lib" + name
    path = ROOT / crate / "target" / (target or "release") / (stem + ext)
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError("missing native artifact: " + str(path))
    return path


def find_ndk():
    for var in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        hit = os.environ.get(var)
        if hit and Path(hit).is_dir():
            return Path(hit)
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    candidates = []
    if sdk:
        candidates.append(Path(sdk) / "ndk")
    candidates.append(Path("/usr/local/lib/android/sdk/ndk"))
    candidates.append(Path("/opt/android-sdk/ndk"))
    for ndk_root in candidates:
        if not ndk_root.is_dir():
            continue
        versions = sorted(p for p in ndk_root.iterdir() if p.is_dir())
        if versions:
            return versions[-1]
    raise RuntimeError("Android NDK not found; set ANDROID_NDK_HOME")


def cmd_android(_args):
    ndk = find_ndk()
    toolchain = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
    linkers = {
        "aarch64-linux-android": toolchain / "aarch64-linux-android21-clang",
        "armv7-linux-androideabi": toolchain / "arm-linux-androideabi21-clang",
        "x86_64-linux-android": toolchain / "x86_64-linux-android21-clang",
    }
    saved = os.environ.copy()
    try:
        for triple, clang in linkers.items():
            if not clang.is_file():
                raise RuntimeError("missing NDK linker: " + str(clang))
            key = "CARGO_TARGET_" + triple.upper().replace("-", "_") + "_LINKER"
            os.environ[key] = str(clang)
        for triple, abi in ANDROID_TARGETS.items():
            for crate in CRATES:
                cargo_build(crate, triple)
                src = artifact(crate, triple, ".so")
                dest = ROOT / "android/app/src/main/jniLibs" / abi / src.name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dest)
                print("staged: " + str(dest), flush=True)
    finally:
        os.environ.clear()
        os.environ.update(saved)


def cmd_host(args, ext):
    for crate in CRATES:
        cargo_build(crate)
        src = artifact(crate, None, ext)
        dest = Path(args.out) / src.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)
        print("staged: " + str(dest), flush=True)


def cmd_macos(args):
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for crate in CRATES:
        parts = []
        for target in ("aarch64-apple-darwin", "x86_64-apple-darwin"):
            cargo_build(crate, target)
            parts.append(str(artifact(crate, target, ".dylib")))
        name = "libvenera_" + Path(crate).name + ".dylib"
        run(["lipo", "-create"] + parts + ["-output", str(out / name)])
        print("staged: " + str(out / name), flush=True)


def cmd_ios(args):
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for crate in CRATES:
        cargo_build(crate, "aarch64-apple-ios")
        src = artifact(crate, "aarch64-apple-ios", ".a")
        dest = out / src.name
        shutil.copyfile(src, dest)
        print("staged: " + str(out / dest.name), flush=True)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("android").set_defaults(func=cmd_android)
    p = sub.add_parser("windows")
    p.add_argument("--out", required=True)
    p.set_defaults(func=lambda a: cmd_host(a, ".dll"))
    p = sub.add_parser("linux")
    p.add_argument("--out", required=True)
    p.set_defaults(func=lambda a: cmd_host(a, ".so"))
    p = sub.add_parser("macos")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_macos)
    p = sub.add_parser("ios")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_ios)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
