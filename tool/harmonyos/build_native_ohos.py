"""Cross-build librhttp/libqjs for OHOS arm64 with the local DevEco native SDK."""
"""Adapted from upstream HarmonyOS tool/harmonyos/native_build.py (rust recipe + qjs recipe).
SQLite is skipped: the sqlite3 pub hook already emits a working libsqlite3.so into the HAP."""
import argparse, hashlib, json, os, re, shlex, shutil, struct, subprocess
from datetime import datetime, timezone
from pathlib import Path

REPO = Path("D:/venera/unified")
NATIVE_DEFAULT = Path("C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
OUT_DEFAULT = Path("D:/venera/.scratch/harmony/native/arm64-v8a")
QJS_DEFAULT = Path("D:/venera/.scratch/harmony/deps/flutter_qjs")
QJS_REV = "8feae95df7fb00455df129ad7a0dfec1d0e8d8e4"
TARGET = "aarch64-unknown-linux-ohos"


def run(args, env=None, capture=False):
    print("RUN", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), cwd=str(REPO), env=env, check=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None,
                          encoding="utf-8", errors="replace").stdout


def build_rust(native, output, target_dir):
    env = os.environ.copy()
    env.pop("RUSTFLAGS", None)
    sr = str(native / "sysroot")
    srx = (native / "sysroot").as_posix()
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join([
        "--cfg", "reqwest_unstable", "-C", "link-arg=--target=aarch64-linux-ohos",
        "-C", f"link-arg=--sysroot={sr}",
        "-C", "link-arg=-Wl,--no-undefined",
    ])
    tools = native / "llvm/bin"
    env["CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER"] = str(tools / "clang.exe")
    env["CC_aarch64_unknown_linux_ohos"] = str(tools / "clang.exe")
    env["CXX_aarch64_unknown_linux_ohos"] = str(tools / "clang++.exe")
    env["AR_aarch64_unknown_linux_ohos"] = str(tools / "llvm-ar.exe")
    env["CC_SHELL_ESCAPED_FLAGS"] = "1"
    flags = shlex.join(["--target=aarch64-linux-ohos", f"--sysroot={srx}", "-D__MUSL__" ])
    env["CFLAGS_aarch64_unknown_linux_ohos"] = flags
    env["CXXFLAGS_aarch64_unknown_linux_ohos"] = flags
    env["CARGO_TARGET_DIR"] = str(target_dir)
    run(["cargo", "build", "--locked", "--release", "--lib", "--jobs", "2",
         "--target", TARGET, "--manifest-path", "packages/rhttp/rust/Cargo.toml"], env=env)
    shutil.copy2(target_dir / TARGET / "release/librhttp.so", output / "librhttp.so")


def build_qjs(native, source, output):
    head = run(["git", "-C", str(source), "rev-parse", "HEAD"], capture=True).strip()
    if head != QJS_REV:
        raise ValueError(f"QuickJS rev {head} != pinned {QJS_REV}")
    cxx = source / "cxx"
    version = (cxx / "quickjs-ng" / "VERSION").read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9.+-]+", version):
        raise ValueError("Invalid QuickJS version macro")
    sr = str(native / "sysroot")
    objdir = output.parent / "qjs-objects"
    objdir.mkdir(exist_ok=True)
    common = ["--target=aarch64-linux-ohos", f"--sysroot={sr}",
              "-D__MUSL__", "-D_GNU_SOURCE", "-fPIC", "-O2"]
    vdef = "-DCONFIG_VERSION=" + chr(34) + version + chr(34)
    compiled = []
    for name in ("cutils.c", "libregexp.c", "libunicode.c", "quickjs.c", "libbf.c"):
        obj = objdir / (name + ".o")
        run([native / "llvm/bin/clang.exe", *common, "-std=gnu11",
             vdef, "-DDUMP_LEAKS", "-c", cxx / "quickjs-ng" / name, "-o", obj])
        compiled.append(obj)
    run([native / "llvm/bin/clang++.exe", *common, "-std=c++17", "-shared",
         "-Wl,--no-undefined", "-Wl,-soname,libqjs.so", cxx / "ffi.cpp",
         *compiled, "-pthread", "-lm", "-o", output / "libqjs.so"])


def inspect(native, path, required):
    data = Path(path).read_bytes()
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<HH", data, 16) != (3, 183):
        raise ValueError(f"Not an AArch64 .so: {path}")
    info = run([native / "llvm/bin/llvm-readelf.exe", "--dynamic", path], capture=True)
    needed = re.findall(r"\(NEEDED\).*?\[(.*?)\]", info)
    if any(n in needed for n in ("liblog.so", "libandroid.so")):
        raise ValueError(f"Unexpected Android linkage in {path}")
    extra = set(needed) - {"libc.so", "libc++_shared.so"}
    if extra:
        raise ValueError(f"Review unbundled deps in {path}: {extra}")
    syms = run([native / "llvm/bin/llvm-nm.exe", "-D", "--defined-only", path], capture=True)
    exported = {l.split()[-1] for l in syms.splitlines() if l.strip()}
    if not set(required).issubset(exported):
        raise ValueError(f"Missing FFI exports in {path}")
    return {"name": Path(path).name, "bytes": Path(path).stat().st_size,
            "sha256": hashlib.file_digest(open(path, "rb"), "sha256").hexdigest(),
            "needed": needed}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sdk-native", type=Path, default=NATIVE_DEFAULT)
    ap.add_argument("--qjs-source", type=Path, default=QJS_DEFAULT)
    ap.add_argument("--out", type=Path, default=OUT_DEFAULT)
    ap.add_argument("--component", choices=("all", "rust", "qjs", "inspect"), default="all")
    ap.add_argument("--cargo-target-dir", type=Path,
                    default=Path("D:/venera/.scratch/harmony/cargo"))
    a = ap.parse_args()
    native, out = a.sdk_native.resolve(), a.out
    out.mkdir(parents=True, exist_ok=True)
    if a.component in ("all", "rust"):
        build_rust(native, out, a.cargo_target_dir)
    if a.component in ("all", "qjs"):
        build_qjs(native, a.qjs_source.resolve(), out)
    if a.component in ("all", "inspect"):
        runtime = native / "llvm/lib/aarch64-linux-ohos/libc++_shared.so"
        if not runtime.is_file():
            runtime = native / "sysroot/usr/lib/aarch64-linux-ohos/libc++_shared.so"
        shutil.copy2(runtime, out / "libc++_shared.so")
        report = {"status": "cross_compile_pass", "target": TARGET,
                  "finished_at_utc": datetime.now(timezone.utc).isoformat(),
                  "libraries": [
                      inspect(native, out / "librhttp.so",
                              ("frb_get_rust_content_hash", "frb_init_frb_dart_api_dl")),
                      inspect(native, out / "libqjs.so",
                              ("jsNewRuntime", "jsEval", "jsFreeRuntime")),
                      inspect(native, out / "libc++_shared.so", ())]}
        (out.parent / "native-build.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
