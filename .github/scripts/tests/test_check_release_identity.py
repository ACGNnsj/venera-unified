import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location(
    'check_release_identity', ROOT / '.github/scripts/check_release_identity.py'
)
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


def write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def run_main(args: list[str]) -> tuple[int, str]:
    """Run identity.main() with stdout captured.

    Negative cases intentionally feed bad fixtures, and main() reports
    them with ::error:: lines for CI. Capturing keeps those lines out of
    the test log so GitHub doesn't pin misleading error annotations on
    green runs; the returned output is still asserted below.
    """
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = identity.main(args)
    return code, buf.getvalue()


class ReleaseIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write_defaults(self, *, android='io.github.venera.unified', exe='VeneraUnified.exe'):
        write(self.root, 'android/app/build.gradle', f'android {{\n    namespace = "{android}"\n    applicationId = "{android}"\n}}\n')
        write(self.root, 'macos/Runner/Configs/AppInfo.xcconfig', 'PRODUCT_BUNDLE_IDENTIFIER = io.github.venera.unified\n')
        write(
            self.root,
            'ios/Runner.xcodeproj/project.pbxproj',
            'PRODUCT_BUNDLE_IDENTIFIER = io.github.venera.unified;\n'
            'PRODUCT_BUNDLE_IDENTIFIER = io.github.venera.unified.RunnerTests;\n',
        )
        write(self.root, 'linux/CMakeLists.txt', 'set(APPLICATION_ID "io.github.venera.unified")\n')
        write(
            self.root,
            'windows/build.iss',
            '#define MyAppName "Venera Unified"\n'
            f'#define MyAppExeName "{exe}"\n'
            'AppId={{C6B7E69A-0FD6-4F2A-AC64-7D1AE8A40FB8}\n',
        )
        write(self.root, 'pubspec.yaml', 'name: venera_unified\nversion: 1.0.0+1\n')

    def test_accepts_consistent_identity(self):
        self.write_defaults()
        found = identity.collect(self.root)
        self.assertEqual(identity.check(found), [])
        code, out = run_main(['--root', str(self.root)])
        self.assertEqual(code, 0)
        self.assertNotIn('::error::', out)

    def test_rejects_mismatched_bundle_identifier(self):
        self.write_defaults()
        write(self.root, 'linux/CMakeLists.txt', 'set(APPLICATION_ID "io.github.other.unified")\n')
        problems = identity.check(identity.collect(self.root))
        self.assertTrue(any('包标识不一致' in problem for problem in problems), problems)
        code, out = run_main(['--root', str(self.root)])
        self.assertEqual(code, 1)
        self.assertIn('::error::', out)

    def test_rejects_namespace_drift(self):
        self.write_defaults()
        write(
            self.root,
            'android/app/build.gradle',
            'android {\n    namespace = "com.github.cyrilpeng.veneranext"\n    applicationId = "io.github.venera.unified"\n}\n',
        )
        problems = identity.check(identity.collect(self.root))
        self.assertTrue(any('namespace' in problem for problem in problems), problems)

    def test_rejects_executable_name_drift(self):
        self.write_defaults(exe='VeneraNext.exe')
        problems = identity.check(identity.collect(self.root))
        self.assertTrue(any('可执行名' in problem for problem in problems), problems)

    def test_rejects_dart_package_out_of_sync(self):
        self.write_defaults()
        write(self.root, 'pubspec.yaml', 'name: venera_next\nversion: 1.0.0+1\n')
        problems = identity.check(identity.collect(self.root))
        self.assertTrue(any('Dart 包名' in problem for problem in problems), problems)

    def test_rejects_detached_ios_identifier(self):
        self.write_defaults()
        write(
            self.root,
            'ios/Runner.xcodeproj/project.pbxproj',
            'PRODUCT_BUNDLE_IDENTIFIER = io.github.venera.unified;\n'
            'PRODUCT_BUNDLE_IDENTIFIER = io.github.other.unified;\n',
        )
        with self.assertRaises(identity.IdentityError):
            identity.collect(self.root)

    def test_reports_missing_file(self):
        self.write_defaults()
        (self.root / 'linux/CMakeLists.txt').unlink()
        with self.assertRaises(identity.IdentityError):
            identity.collect(self.root)


if __name__ == '__main__':
    unittest.main()
