import importlib.util
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


class ReleaseIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write_defaults(self, *, android='io.github.venera.unified', exe='VeneraUnified.exe'):
        write(self.root, 'android/app/build.gradle', f'android {{\n    applicationId = "{android}"\n}}\n')
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
        self.assertEqual(identity.main(['--root', str(self.root)]), 0)

    def test_rejects_mismatched_bundle_identifier(self):
        self.write_defaults()
        write(self.root, 'linux/CMakeLists.txt', 'set(APPLICATION_ID "io.github.other.unified")\n')
        problems = identity.check(identity.collect(self.root))
        self.assertTrue(any('包标识不一致' in problem for problem in problems), problems)
        self.assertEqual(identity.main(['--root', str(self.root)]), 1)

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
