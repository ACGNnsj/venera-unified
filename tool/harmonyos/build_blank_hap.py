"""Build an unsigned HarmonyOS HAP from a generated blank Flutter project.

This reproduces stage P1 of doc/distribution/harmonyos.zh.md: it proves the
host toolchain (flutter_ohos + hvigor + ohpm) works before any application code
is ported. Verified on Windows 11 with DevEco Studio 26.0 (API 26) and
flutter_ohos 3.41.9+ohos-1.0.2.

Usage:
  python tool/harmonyos/build_blank_hap.py --flutter-ohos <flutter_ohos> --work <scratch>

Every flutter command runs as its own process on purpose: invoking
flutter.bat inside a .bat chain ends that chain at its trailing exit.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

DEVICE_TYPES = '["phone", "tablet"]'
DEFAULT_DEV_ECO = r"C:\Program Files\Huawei\DevEco Studio"


def build_env(work: Path, dev_eco: Path) -> dict:
    env = dict(os.environ)
    tmp = work / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    sdk = dev_eco / "sdk"
    prepend = [
        dev_eco / "jbr" / "bin",
        sdk / "default" / "openharmony" / "toolchains",
        dev_eco / "tools" / "node",
        dev_eco / "tools" / "ohpm" / "bin",
        dev_eco / "tools" / "hvigor" / "bin",
    ]
    env["PATH"] = os.pathsep.join([str(p) for p in prepend] + [env.get("PATH", "")])
    env["DEVECO_SDK_HOME"] = str(sdk)
    # hvigor and ohpm resolve their user homes from these variables; both
    # default under %USERPROFILE%, which some machines deny writes to.
    env["HVIGOR_USER_HOME"] = str(work / "hvigor-home")
    env["USERPROFILE"] = str(work / "home")
    env["PUB_CACHE"] = str(work / "pubcache")
    # hvigor bootstraps pnpm through npm; npm's own cache under %LOCALAPPDATA%
    # hits the same write denial as the user homes above.
    env["npm_config_cache"] = env["NPM_CONFIG_CACHE"] = str(work / "npm-cache")
    env["TMP"] = env["TEMP"] = env["TMPDIR"] = str(tmp)
    env.setdefault(
        "FLUTTER_OHOS_STORAGE_BASE_URL",
        "https://flutter-ohos.obs.cn-south-1.myhuaweicloud.com",
    )
    env.setdefault("FLUTTER_STORAGE_BASE_URL", "https://storage.flutter-io.cn")
    (work / "home").mkdir(parents=True, exist_ok=True)
    return env


def run(cmd, env, cwd=None, check=True):
    print("+ " + " ".join(str(c) for c in cmd), flush=True)
    proc = subprocess.run(
        [str(c) for c in cmd],
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    tail = "\n".join(proc.stdout.strip().splitlines()[-8:])
    print(tail, flush=True)
    if check and proc.returncode != 0:
        raise SystemExit("command failed (%d): %s\n%s" % (proc.returncode, cmd[0], tail))
    return proc


def patch_profile(project: Path):
    profile = project / "ohos" / "build-profile.json5"
    text = profile.read_text(encoding="utf-8")
    new_text, count = re.subn(
        r'("compatibleSdkVersion"\s*:\s*)"[^"]*"', r'\g<1>"26.0.0"', text
    )
    if count != 1:
        raise SystemExit("unexpected build-profile.json5 template (%d matches)" % count)
    profile.write_text(new_text, encoding="utf-8")
    print("patched compatibleSdkVersion (1 site)", flush=True)


def patch_device_types(project: Path):
    module = project / "ohos" / "entry" / "src" / "main" / "module.json5"
    text = module.read_text(encoding="utf-8")
    new_text, count = re.subn(
        r'("deviceTypes"\s*:\s*)\[[^\]]*\]', r"\g<1>" + DEVICE_TYPES.replace("\\", "\\\\"), text
    )
    if count != 1:
        raise SystemExit("unexpected module.json5 template (%d matches)" % count)
    module.write_text(new_text, encoding="utf-8")
    print("patched deviceTypes (1 site)", flush=True)


JUNCTION_RE = re.compile(
    r"symlink '[^']*' -> '([^']*project_caches[^']*node_modules[\\/]@ohos[\\/][^']*)'"
)


def link_ohos_packages(output: str, dev_eco: Path) -> bool:
    """hvigor creates @ohos junctions with fs.symlinkSync, which fails with EPERM
    on machines that deny it. Pre-create the junction with mklink /J instead;
    hvigor then sees the link and skips creating it."""
    created = False
    for target in JUNCTION_RE.findall(output):
        dest = Path(target)
        package = dest.name
        source = dev_eco / "tools" / "hvigor" / package
        if not source.exists() or dest.exists():
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        run(["cmd", "/c", "mklink", "/J", str(dest), str(source)], os.environ, check=False)
        created = True
    return created


def build_to_log(cmd, env, cwd: Path, log: Path) -> str:
    """Run the build with shell redirection so hvigor's console output is kept."""
    if os.name != "nt":
        proc = run(cmd, env, cwd=cwd, check=False)
        return proc.stdout
    line = subprocess.list2cmdline([str(c) for c in cmd])
    proc = subprocess.run(
        'cmd /c "%s > "%s" 2>&1"' % (line, log),
        cwd=str(cwd),
        env=env,
        shell=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    output = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
    print("\n".join(output.strip().splitlines()[-8:]), flush=True)
    if proc.returncode != 0:
        print("build exited with %d (full log: %s)" % (proc.returncode, log), flush=True)
    return output


def audit(project: Path) -> Path:
    hap_dir = project / "build" / "ohos" / "hap"
    haps = sorted(hap_dir.glob("*-unsigned.hap"))
    if len(haps) != 1:
        raise SystemExit("expected exactly one -unsigned.hap in %s" % hap_dir)
    hap = haps[0]
    with zipfile.ZipFile(hap) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise SystemExit("duplicate zip members in %s" % hap.name)
        if archive.testzip() is not None:
            raise SystemExit("corrupt zip member in %s" % hap.name)
        for required in ("libs/arm64-v8a/libflutter.so", "libs/arm64-v8a/libapp.so"):
            if required not in names:
                raise SystemExit("%s missing %s" % (hap.name, required))
        print("hap %s %d bytes, %d members" % (hap.name, hap.stat().st_size, len(names)), flush=True)
    return hap


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-ohos", required=True, help="flutter_ohos SDK checkout")
    parser.add_argument("--work", required=True, help="scratch directory for the project")
    parser.add_argument("--dev-eco", default=os.environ.get("DEVECO_HOME", DEFAULT_DEV_ECO))
    parser.add_argument("--org", default="io.github.venera")
    parser.add_argument("--project-name", default="harmonyos_blank")
    args = parser.parse_args()

    flutter_bat = Path(args.flutter_ohos) / "bin" / ("flutter.bat" if os.name == "nt" else "flutter")
    if not flutter_bat.exists():
        raise SystemExit("flutter_ohos not found: %s" % flutter_bat)
    dev_eco = Path(args.dev_eco)
    if not (dev_eco / "sdk").exists():
        raise SystemExit("DevEco SDK not found under %s" % dev_eco)

    work = Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    env = build_env(work, dev_eco)
    project = work / "project"

    if not (project / "ohos").exists():
        run([flutter_bat, "create", "--platforms", "ohos", "--no-pub", "--org", args.org,
             "--project-name", args.project_name, project], env, cwd=work)
        patch_profile(project)
        patch_device_types(project)

    run([flutter_bat, "pub", "get"], env, cwd=project)

    build_cmd = [flutter_bat, "build", "hap", "--release", "--no-codesign",
                 "--target-platform", "ohos-arm64"]
    if (project / "pubspec.lock").exists():
        build_cmd.append("--no-pub")
    log = work / "build.log"
    # A fresh hvigor cache surfaces @ohos links one package at a time. hvigor
    # writes that error straight to the console, so the build runs through a
    # shell redirection to a log file and the junction is pre-created from it.
    for attempt in range(4):
        output = build_to_log(build_cmd, env, project, log)
        if os.name != "nt":
            break
        if link_ohos_packages(output, dev_eco):
            print("pre-created @ohos junction, retrying (attempt %d)" % (attempt + 2), flush=True)
            continue
        break
    if not list((project / "build" / "ohos" / "hap").glob("*-unsigned.hap")):
        raise SystemExit("flutter build hap produced no HAP; see %s" % log)

    hap = audit(project)
    print(json.dumps({"hap": str(hap), "bytes": hap.stat().st_size}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
