"""Cross-build librhttp/libqjs for OHOS arm64 with the local DevEco native SDK."""
"""Adapted from upstream HarmonyOS tool/harmonyos/native_build.py (rust recipe + qjs recipe).
SQLite is compiled from the vendored amalgamation: the sqlite3 pub hook sees an
OS.linux shim on OHOS and would otherwise download a glibc prebuilt (fcntl64
missing on device) or miscompile with --target=x86_64-linux-gnu. The hook is
set to source: system and dlopens the .so staged into entry/libs."""
import argparse, hashlib, json, os, re, shlex, shutil, struct, subprocess
from datetime import datetime, timezone
from pathlib import Path

REPO = Path("D:/venera/unified")
NATIVE_DEFAULT = Path("C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
OUT_DEFAULT = Path("D:/venera/.scratch/harmony/native/arm64-v8a")
QJS_DEFAULT = Path("D:/venera/.scratch/harmony/deps/flutter_qjs")
# == pubspec.yaml flutter_qjs pin == venera-next-pinned tip (fix is Dart-only; cxx/ identical to master 8feae95).
QJS_REV = "295f77421eedff356a02e92987181b525970c780"
ARCHES = {
    "arm64": {"target": "aarch64-unknown-linux-ohos", "gnu": "aarch64-linux-ohos",
                "machine": 183, "out": "arm64-v8a"},
    "x64": {"target": "x86_64-unknown-linux-ohos", "gnu": "x86_64-linux-ohos",
              "machine": 62, "out": "x86_64"},
}
TARGET = ARCHES["arm64"]["target"]


def run(args, env=None, capture=False):
    print("RUN", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), cwd=str(REPO), env=env, check=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None,
                          encoding="utf-8", errors="replace").stdout


def build_rust(native, output, target_dir, arch):
    target, gnu = arch["target"], arch["gnu"]
    tu, tl = target.replace("-", "_").upper(), target.replace("-", "_")
    gu = tl
    env = os.environ.copy()
    env.pop("RUSTFLAGS", None)
    sr = str(native / "sysroot")
    srx = (native / "sysroot").as_posix()
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join([
        "--cfg", "reqwest_unstable", "-C", f"link-arg=--target={gnu}",
        "-C", f"link-arg=--sysroot={sr}",
        "-C", "link-arg=-Wl,--no-undefined",
    ])
    tools = native / "llvm/bin"
    env[f"CARGO_TARGET_{tu}_LINKER"] = str(tools / "clang.exe")
    env[f"CC_{gu}"] = str(tools / "clang.exe")
    env[f"CXX_{gu}"] = str(tools / "clang++.exe")
    env[f"AR_{gu}"] = str(tools / "llvm-ar.exe")
    env["CC_SHELL_ESCAPED_FLAGS"] = "1"
    flags = shlex.join([f"--target={gnu}", f"--sysroot={srx}", "-D__MUSL__" ])
    env[f"CFLAGS_{gu}"] = flags
    env[f"CXXFLAGS_{gu}"] = flags
    env["CARGO_TARGET_DIR"] = str(target_dir)
    run(["cargo", "build", "--locked", "--release", "--lib", "--jobs", "2",
         "--target", target, "--manifest-path", "packages/rhttp/rust/Cargo.toml"], env=env)
    shutil.copy2(target_dir / target / "release/librhttp.so", output / "librhttp.so")


def build_qjs(native, source, output, arch):
    gnu = arch["gnu"]
    head = run(["git", "-C", str(source), "rev-parse", "HEAD"], capture=True).strip()
    if head != QJS_REV:
        raise ValueError(f"QuickJS rev {head} != pinned {QJS_REV}")
    cxx = source / "cxx"
    version = (cxx / "quickjs-ng" / "VERSION").read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9.+-]+", version):
        raise ValueError("Invalid QuickJS version macro")
    sr = str(native / "sysroot")
    objdir = output.parent / f"qjs-objects-{arch['out']}"
    objdir.mkdir(exist_ok=True)
    common = [f"--target={gnu}", f"--sysroot={sr}",
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


SQLITE_DEFINES = ("SQLITE_ENABLE_DBSTAT_VTAB", "SQLITE_ENABLE_FTS5", "SQLITE_ENABLE_RTREE",
    "SQLITE_ENABLE_MATH_FUNCTIONS", "SQLITE_DQS=0", "SQLITE_DEFAULT_MEMSTATUS=0", "SQLITE_TEMP_STORE=2",
    "SQLITE_MAX_EXPR_DEPTH=0", "SQLITE_STRICT_SUBTYPE=1", "SQLITE_OMIT_AUTHORIZATION",
    "SQLITE_OMIT_DECLTYPE", "SQLITE_OMIT_DEPRECATED", "SQLITE_OMIT_PROGRESS_CALLBACK",
    "SQLITE_OMIT_SHARED_CACHE", "SQLITE_OMIT_TCL_VARIABLE", "SQLITE_OMIT_TRACE", "SQLITE_USE_ALLOCA",
    "SQLITE_ENABLE_SESSION", "SQLITE_ENABLE_PREUPDATE_HOOK", "SQLITE_UNTESTABLE", "SQLITE_HAVE_ISNAN",
    "SQLITE_HAVE_LOCALTIME_R", "SQLITE_HAVE_LOCALTIME_S", "SQLITE_HAVE_MALLOC_USABLE_SIZE",
    "SQLITE_HAVE_STRCHRNUL", "SQLITE_ENABLE_BATCH_ATOMIC_WRITE")


def build_sqlite(native, amalgamation, output, arch):
    gnu = arch["gnu"]
    sr = str(native / "sysroot")
    common = [f"--target={gnu}", f"--sysroot={sr}",
              "-D__MUSL__", "-D_GNU_SOURCE", "-fPIC", "-O2"]
    run([native / "llvm/bin/clang.exe", *common,
         *[f"-D{d}" for d in SQLITE_DEFINES],
         "-shared", "-Wl,--no-undefined", "-Wl,-soname,libsqlite3.so",
         str(amalgamation), "-lm", "-o", output / "libsqlite3.so"])


SEVEN_ZIP_C = ("7zAlloc.c", "7zArcIn.c", "7zBuf.c", "7zBuf2.c", "7zCrc.c",
    "7zCrcOpt.c", "7zDec.c", "7zFile.c", "7zStream.c", "Bcj2.c", "Bra.c",
    "Bra86.c", "Delta.c", "LzmaDec.c", "Lzma2Dec.c", "CpuArch.c")


def build_7zip(native, source, output, arch):
    gnu = arch["gnu"]
    sr = str(native / "sysroot")
    common = [f"--target={gnu}", f"--sysroot={sr}",
              "-D__MUSL__", "-D_GNU_SOURCE", "-fPIC", "-O2"]
    cdir = source / "7zip" / "C"
    objdir = output.parent / f"7zip-objects-{arch['out']}"
    objdir.mkdir(exist_ok=True)
    compiled = []
    for name in SEVEN_ZIP_C:
        obj = objdir / (name + ".o")
        run([native / "llvm/bin/clang.exe", *common,
             "-I", cdir, "-c", cdir / name, "-o", obj])
        compiled.append(obj)
    run([native / "llvm/bin/clang++.exe", *common, "-std=c++20",
         "-DDART_SHARED_LIB", "-I", source, "-I", cdir,
         "-shared", "-Wl,--no-undefined", "-Wl,-soname,libflutter_7zip.so",
         source / "flutter_7zip.cpp", *compiled,
         "-o", output / "libflutter_7zip.so"])


def inspect(native, path, required, machine=183):
    data = Path(path).read_bytes()
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<HH", data, 16) != (3, machine):
        raise ValueError(f"Not an e_machine={machine} .so: {path}")
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
    ap.add_argument("--arch", choices=tuple(ARCHES), default="arm64")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--component", choices=("all", "rust", "qjs", "sqlite", "7zip", "inspect"), default="all")
    ap.add_argument("--sqlite-amalgamation", type=Path,
                    default=Path("D:/venera/.scratch/harmony/vendor/sqlite-amalgamation/sqlite3.c"))
    ap.add_argument("--cargo-target-dir", type=Path,
                    default=Path("D:/venera/.scratch/harmony/cargo"))
    a = ap.parse_args()
    arch = ARCHES[a.arch]
    native = a.sdk_native.resolve()
    out = a.out or Path(f"D:/venera/.scratch/harmony/native/{arch['out']}")
    out.mkdir(parents=True, exist_ok=True)
    if a.component in ("all", "rust"):
        build_rust(native, out, a.cargo_target_dir, arch)
    if a.component in ("all", "qjs"):
        build_qjs(native, a.qjs_source.resolve(), out, arch)
    if a.component in ("all", "7zip"):
        build_7zip(native, Path("D:/venera/.scratch/harmony/vendor/flutter_7zip-b333447/src").resolve(), out, arch)
    if a.component in ("all", "sqlite"):
        build_sqlite(native, a.sqlite_amalgamation.resolve(), out, arch)
    if a.component in ("all", "inspect"):
        runtime = native / f"llvm/lib/{arch['gnu']}/libc++_shared.so"
        if not runtime.is_file():
            runtime = native / f"sysroot/usr/lib/{arch['gnu']}/libc++_shared.so"
        shutil.copy2(runtime, out / "libc++_shared.so")
        report = {"status": "cross_compile_pass", "target": arch["target"],
                  "finished_at_utc": datetime.now(timezone.utc).isoformat(),
                  "libraries": [
                      inspect(native, out / "librhttp.so",
                              ("frb_get_rust_content_hash", "frb_init_frb_dart_api_dl"),
                              arch["machine"]),
                      inspect(native, out / "libqjs.so",
                              ("jsNewRuntime", "jsEval", "jsFreeRuntime"),
                              arch["machine"]),
                      inspect(native, out / "libsqlite3.so",
                              ("sqlite3_libversion", "sqlite3_open", "sqlite3_close"),
                              arch["machine"]),
                      inspect(native, out / "libflutter_7zip.so",
                              ("openArchive", "closeArchive", "freeReadData"),
                              arch["machine"]),
                      inspect(native, out / "libc++_shared.so", (),
                              arch["machine"])]}
        (out.parent / f"native-build-{a.arch}.json").write_text(json.dumps(report, indent=2) + "\n")
        if a.arch == "arm64":
            (out.parent / "native-build.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
