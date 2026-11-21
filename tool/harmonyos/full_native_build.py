"""Cross-compile the project's reviewed codecs, ZIP and WebView libraries for OHOS."""

import argparse
import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

from native_build import CONFIG, ROOT, digest, inspect_library, require_within, run, validate_elf
from prepare_full_app import DEPS, EXTRA_LIBRARIES, verify_dependencies
from prepare_probe import BASE, verify_native_report
from ci_sdk import check_native_sdk


EXPORTS = {
    "libvenera_native.so": ("venera_png_encode", "venera_png_error_text", "venera_native_free",
                            "venera_7z_open", "venera_7z_close", "venera_7z_count", "venera_7z_name",
                            "venera_7z_kind", "venera_7z_read"),
    "libzip_flutter.so": ("zip_open", "zip_close", "zip_entry_open", "zip_entry_fwrite", "zip_entry_read", "zip_extract"),
    "libinappwebview.so": ("RegisterEntryModule",),
    "libonnxruntime.so": ("OrtGetApiBase",),
}


def compile_libraries(native, output):
    suffix = ".exe" if os.name == "nt" else ""
    clang = native / f"llvm/bin/clang{suffix}"
    cxx = native / f"llvm/bin/clang++{suffix}"
    flags = ["--target=aarch64-linux-ohos", f"--sysroot={native / 'sysroot'}",
             "-D__MUSL__", "-D_GNU_SOURCE", "-DDART_SHARED_LIB", "-fPIC", "-O2"]
    link = ["-shared", "-Wl,--no-undefined"]
    run([cxx, *flags, "-std=c++17", *link, "-Wl,-soname,libzip_flutter.so",
         DEPS / "zip_flutter/src/zip.cc", "-o", output / "libzip_flutter.so"])
    package = ROOT / "packages/venera_native"
    c_source = package / "third_party/lzma"
    objects = require_within(output.parent / "codec-objects", BASE)
    objects.mkdir(parents=True, exist_ok=True)
    export_map = objects / "venera_native.exports"
    export_map.write_text("{\n  global:\n" + "".join(
        f"    {name};\n" for name in EXPORTS["libvenera_native.so"]) + "  local: *;\n};\n", encoding="utf-8")
    names = ("7zAlloc", "7zArcIn", "7zBuf", "7zBuf2", "7zCrc", "7zCrcOpt", "7zDec",
             "7zFile", "7zStream", "Bcj2", "Bra", "Bra86", "Delta", "LzmaDec", "Lzma2Dec", "CpuArch")
    compiled = []
    sources = [(name, c_source / f"{name}.c") for name in names]
    sources.extend((("lodepng", package / "third_party/lodepng/lodepng.c"),
                    ("venera_png", package / "src/venera_png.c")))
    for name, source in sources:
        obj = objects / f"{name}.o"
        run([clang, *flags, "-std=gnu11", "-DVENERA_LZMA_PORTABLE_ENDIAN=1",
             "-fvisibility=hidden", "-I", c_source, "-c", source, "-o", obj])
        compiled.append(obj)
    run([cxx, *flags, "-std=c++17", "-DVENERA_LZMA_PORTABLE_ENDIAN=1",
         "-fvisibility=hidden", "-fvisibility-inlines-hidden", "-I", c_source, *link,
         f"-Wl,--version-script={export_map}",
         "-Wl,-soname,libvenera_native.so", package / "src/venera_7z.cpp", *compiled,
         "-pthread", "-o", output / "libvenera_native.so"])
    run([cxx, *flags, "-std=c++17", *link, "-Wl,-soname,libinappwebview.so",
         DEPS / "webview/flutter_inappwebview_ohos/ohos/src/main/cpp/napi_init.cpp",
         "-lace_napi.z", "-luv", "-o", output / "libinappwebview.so"])


def build_ort(native, output):
    # CPU only; acceleration remains a separate, deferred platform project.
    source = BASE / "onnxruntime-source"
    revision = "da9b5e364c465de65c49d91e696cd6485270757f"
    if not source.exists():
        run(["git", "clone", "-c", "core.autocrlf=false", "-c", "core.eol=lf",
             "--depth", "1", "--branch", "v1.28.0",
             "https://gitcode.com/gh_mirrors/on/onnxruntime.git", source])
    if run(["git", "-C", source, "rev-parse", "HEAD"], capture=True).strip() != revision:
        raise ValueError("Unexpected ONNX Runtime source revision")
    run(["git", "-C", source, "diff", "--exit-code", "HEAD"])
    for upstream, asset in (("LICENSE", "ONNXRUNTIME_LICENSE.txt"),
                            ("ThirdPartyNotices.txt", "ONNXRUNTIME_THIRD_PARTY_NOTICES.txt")):
        if digest(source / upstream) != digest(ROOT / "assets" / asset):
            raise ValueError("ONNX Runtime distribution notices differ from pinned source")
    patch = Path(__file__).with_name("onnxruntime_ohos.patch")
    build = output.parent / "onnxruntime-build"
    run(["git", "-C", source, "apply", "--check", patch])
    run(["git", "-C", source, "apply", patch])
    try:
        run(["cmake", "-S", source / "cmake", "-B", build, "-G", "Ninja",
             f"-DCMAKE_TOOLCHAIN_FILE={native / 'build/cmake/ohos.toolchain.cmake'}",
             "-DOHOS_ARCH=arm64-v8a", "-DCMAKE_BUILD_TYPE=Release",
             *[f"-DCMAKE_{language}_FLAGS=-Wno-unused-command-line-argument" for language in ("C", "CXX", "ASM")],
             "-Donnxruntime_BUILD_SHARED_LIB=ON", "-Donnxruntime_BUILD_UNIT_TESTS=OFF",
             "-Donnxruntime_ENABLE_CPUINFO=OFF", "-Donnxruntime_DISABLE_RTTI=ON"])
        run(["cmake", "--build", build, "--target", "onnxruntime", "--parallel", "2"])
        shutil.copy2(build / "libonnxruntime.so.1.28.0", output / "libonnxruntime.so")
    finally:
        run(["git", "-C", source, "apply", "--reverse", patch])
    return {"revision": revision, "patch_sha256": digest(patch), "execution_providers": ["CPUExecutionProvider"]}


def inspect_reader_library(native, path):
    suffix = ".exe" if os.name == "nt" else ""
    if path.name == "libinappwebview.so":
        validate_elf(path.read_bytes())
        info = run([native / f"llvm/bin/llvm-readelf{suffix}", "--dynamic", path], capture=True)
        needed = re.findall(r"\(NEEDED\).*?\[(.*?)\]", info)
        if set(needed) - {"libc.so", "libc++_shared.so", "libace_napi.z.so", "libuv.so"}:
            raise ValueError("Unreviewed WebView helper linkage")
        record = {"name": path.name, "bytes": path.stat().st_size,
                  "sha256": digest(path), "needed": needed}
    else:
        record = inspect_library(native, path)
    symbols = run([native / f"llvm/bin/llvm-nm{suffix}", "-D", "--defined-only", path], capture=True)
    defined = {line.split()[-1].split("@")[0] for line in symbols.splitlines() if line.strip()}
    if not set(EXPORTS[path.name]).issubset(defined):
        raise ValueError(f"Missing reader FFI exports: {path.name}")
    if path.name == "libvenera_native.so" and defined != set(EXPORTS[path.name]):
        raise ValueError("Unexpected project codec exports")
    record["checked_exports"] = list(EXPORTS[path.name])
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-native", type=Path, required=True)
    parser.add_argument("--core-native-dir", type=Path, default=BASE / "native")
    parser.add_argument("--output", type=Path, default=BASE / "full-native")
    args = parser.parse_args()
    native = args.sdk_native.resolve()
    core = verify_native_report(args.core_native_dir / "native-build.json", args.core_native_dir / "arm64-v8a")
    sdk = json.loads((native / "oh-uni-package.json").read_text(encoding="utf-8-sig"))
    check_native_sdk(sdk, core["sdk_profile"], CONFIG, core.get("sdk_receipt"))
    if sdk["version"] != core["sdk_version"] or int(sdk["apiVersion"]) != core["sdk_api"]:
        raise ValueError("Reader libraries must match the core Native SDK")
    output = require_within(args.output.resolve(), BASE)
    libraries = output / "arm64-v8a"
    libraries.mkdir(parents=True, exist_ok=True)
    report = {"status": "building", "sdk_profile": core["sdk_profile"], "sdk_version": core["sdk_version"],
              "sdk_api": core["sdk_api"], "runtime_verified": False, "dependencies": verify_dependencies(),
              "build_script_sha256": digest(Path(__file__))}
    try:
        compile_libraries(native, libraries)
        report["onnxruntime"] = build_ort(native, libraries)
        report["libraries"] = [inspect_reader_library(native, libraries / name) for name in EXTRA_LIBRARIES]
        report["status"] = "cross_compile_pass"
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        (output / "extra-native-build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("Audited real reader FFI libraries; device runtime remains unverified.")


if __name__ == "__main__":
    main()
