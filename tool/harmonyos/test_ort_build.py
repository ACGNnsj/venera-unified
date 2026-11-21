"""Offline ORT failure regression. Set ONNXRUNTIME_SOURCE to a local Git clone."""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import full_native_build as builder


class OrtBuildTests(unittest.TestCase):
    def test_cmake_failure_restores_patch_without_publishing(self):
        candidates = [builder.BASE / "onnxruntime-source", builder.ROOT.parent / ".scratch/ort-src"]
        if "ONNXRUNTIME_SOURCE" in os.environ:
            candidates = [Path(os.environ["ONNXRUNTIME_SOURCE"])]
        upstream = next((path for path in candidates if (path / ".git").exists()), None)
        if upstream is None or shutil.which("git") is None:
            self.skipTest("Requires Git and a local ONNXRUNTIME_SOURCE clone")

        revision = "da9b5e364c465de65c49d91e696cd6485270757f"
        patch_file = Path(builder.__file__).with_name("onnxruntime_ohos.patch")
        paths = re.findall(r"^--- a/(.+)$", patch_file.read_text(encoding="utf-8"), re.M)
        notices = {"LICENSE": "ONNXRUNTIME_LICENSE.txt",
                   "ThirdPartyNotices.txt": "ONNXRUNTIME_THIRD_PARTY_NOTICES.txt"}
        run = builder.run
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "onnxruntime-source"
            run(["git", "clone", "-c", "core.autocrlf=false", "-c", "core.eol=lf",
                 "--shared", "--no-checkout", upstream.resolve(), source])
            git = ["git", "-C", str(source)]
            run([*git, "sparse-checkout", "set", "--no-cone", *[f"/{name}" for name in (*paths, *notices)]])
            run([*git, "checkout", "--detach", revision])
            for name, asset in notices.items():
                blob = subprocess.check_output([*git, "show", f"{revision}:{name}"])
                self.assertEqual((builder.ROOT / "assets" / asset).read_bytes(), blob, asset)

            originals = {name: (source / name).read_bytes() for name in paths}
            output = base / "arm64-v8a"
            output.mkdir()
            for failure_stage in ("-S", "--build"):
                with self.subTest(failure_stage=failure_stage):
                    def fail_cmake(args, **kwargs):
                        if args[0] != "cmake":
                            return run(args, **kwargs)
                        run([*git, "apply", "--reverse", "--check", patch_file])
                        if args[1] == "-S":
                            self.assertFalse(any(arg.startswith("-Donnxruntime_USE_") and arg.endswith("=ON")
                                                 for arg in map(str, args)))
                        if args[1] == failure_stage:
                            raise subprocess.CalledProcessError(1, args)

                    with patch.object(builder, "BASE", base), patch.object(builder, "run", side_effect=fail_cmake):
                        with self.assertRaises(subprocess.CalledProcessError) as failure:
                            builder.build_ort(base / "sdk", output)
                    self.assertEqual(failure.exception.cmd[:2], ["cmake", failure_stage])
                    self.assertEqual({name: (source / name).read_bytes() for name in paths}, originals)
                    run([*git, "diff", "--exit-code", "HEAD"])
                    self.assertFalse((output / "libonnxruntime.so").exists())


if __name__ == "__main__":
    unittest.main()
