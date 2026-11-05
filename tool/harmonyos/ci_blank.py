"""Build and audit an unsigned blank HarmonyOS HAP on a Linux CI runner.

Blank stage only: proves flutter_ohos + hvigor + ohpm work before any
application code is ported. Mirrors the blank stage of upstream
tool/harmonos/ci_build.py without its probe/full-app dependencies.

Usage:
  python3 tool/harmonyos/ci_blank.py --flutter-sdk <flutter_ohos> --work <dir>
"""

import argparse
import hashlib
import json
import os
import subprocess
import re
import sys
import zipfile
from pathlib import Path

DEVICE_TYPES = '["phone", "tablet"]'


def run(cmd, cwd, name, logdir):
    logdir.mkdir(parents=True, exist_ok=True)
    print("RUN", " ".join(map(str, cmd)), flush=True)
    with (logdir / f"{name}.txt").open("w", encoding="utf-8") as log:
        with subprocess.Popen(list(map(str, cmd)), cwd=cwd, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True,
                              encoding="utf-8", errors="replace") as process:
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
            if process.wait():
                raise subprocess.CalledProcessError(process.returncode, cmd)


def configure_profile(text, target_sdk):
    updated = text.replace('"targetSdkVersion": "26.0.0"',
                           f'"targetSdkVersion": "{target_sdk}"')
    return updated.replace('"compatibleSdkVersion": "5.0.5(17)"',
                           f'"compatibleSdkVersion": "{target_sdk}"')


def configure_device_types(text):
    matches = re.findall(r'("deviceTypes"\s*:\s*)(\[[^\]]*\])', text)
    if len(matches) != 1:
        raise ValueError("module.json5 must declare deviceTypes exactly once")
    if re.sub(r"\s", "", matches[0][1]) != '["phone"]':
        raise ValueError("module.json5 deviceTypes must start as [phone]")
    return re.sub(r'("deviceTypes"\s*:\s*)(\[[^\]]*\])',
                  r"\1" + DEVICE_TYPES, text, count=1)


def audit_hap(hap):
    if not hap.name.endswith("-unsigned.hap"):
        raise ValueError("Only an explicitly unsigned HAP may be exported")
    with zipfile.ZipFile(hap) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names) or archive.testzip() is not None:
            raise ValueError("Duplicated or corrupt HAP members")
        for lib in ("libflutter.so", "libapp.so"):
            if f"libs/arm64-v8a/{lib}" not in names:
                raise ValueError(f"Missing ARM64 HAP library: {lib}")
    return {"bytes": hap.stat().st_size,
            "sha256": hashlib.file_digest(hap.open("rb"), "sha256").hexdigest(),
            "members": len(names)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    project = work / "blank"
    logs = work / "logs"
    report_path = work / "blank-build.json"
    report = {"stage": "blank", "status": "building",
              "commit": os.getenv("GITHUB_SHA"), "signed": False}
    try:
        if project.exists():
            raise ValueError("The CI blank app must be created in a fresh directory")
        tc = json.loads(Path(__file__).with_name("toolchain.json").read_text())
        target_sdk = tc["harmonyCiSdk"]["targetSdk"]
        flutter = args.flutter_sdk / "bin/flutter"
        run([flutter, "create", "--platforms", "ohos", "--no-pub", "--org",
             "com.github.cyrilpeng", "--project-name", "harmonyos_blank", project],
            Path.cwd(), "blank-create", logs)
        profile = project / "ohos/build-profile.json5"
        profile.write_text(configure_profile(profile.read_text(), target_sdk),
                           encoding="utf-8")
        module = project / "ohos/entry/src/main/module.json5"
        module.write_text(configure_device_types(module.read_text(encoding="utf-8")),
                          encoding="utf-8")
        run([flutter, "pub", "get"], project, "blank-pub", logs)
        run([flutter, "build", "hap", "--release", "--no-codesign",
             "--target-platform", "ohos-arm64", "--no-pub"], project, "blank-hap", logs)
        haps = sorted((project / "build/ohos/hap").glob("*-unsigned.hap"))
        if not haps:
            raise ValueError("No unsigned HAP was produced")
        report.update(audit_hap(haps[0]), status="verified", hap=str(haps[0]))
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__, error=str(error))
        raise
    finally:
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
