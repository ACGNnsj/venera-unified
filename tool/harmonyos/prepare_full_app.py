"""Prepare the real application in an isolated, locked OHOS build directory."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

from native_build import CONFIG, ROOT, digest, require_within
from prepare_probe import (BASE, command, configure_device_types, configure_profile,
                           export_qjs, verify_native_report)
from release_context import build_inputs


FULL_CONFIG_PATH = Path(__file__).with_name("full_app_config.json")
FULL_CONFIG = json.loads(FULL_CONFIG_PATH.read_text(encoding="utf-8"))
DEPS = BASE / "full-deps"
PROJECT = BASE / "full-app"
WEBVIEW_PACKAGES = tuple("flutter_inappwebview" + suffix for suffix in (
    "", "_platform_interface", "_ohos", "_android", "_ios", "_macos", "_web", "_windows"))
EXTRA_LIBRARIES = ("libvenera_native.so", "libzip_flutter.so", "libinappwebview.so")
GIT_DEPENDENCIES = ("webview", "webview_api", "code_assets")
PROJECT_PACKAGES = tuple(FULL_CONFIG["project_packages"])
NATIVE_NOTICE_ASSET = "assets/notices/VENERA_NATIVE_THIRD_PARTY_NOTICES.txt"
NATIVE_NOTICE_SOURCE = ROOT / "packages/venera_native/notices/VENERA_NATIVE_THIRD_PARTY_NOTICES.txt"
WEBVIEW_API_TYPES = ("browser_process_exit_kind.dart", "browser_process_exit_kind.g.dart",
                     "browser_process_exited_detail.dart", "browser_process_exited_detail.g.dart", "enum_method.dart")
WEBVIEW_TYPES = Path("flutter_inappwebview_platform_interface/lib/src/types")
# Host-only tests that override an interface member added by a newer pdfrx
# release than the pinned HAP dependency set provides (PdfPageRenderPriority).
# They are never packaged into the application, so the HAP analyze gate and
# the HAP unit-test subset leave them out; the repository analyzes and runs
# them on the main SDK.
HAP_PDFRX_208_TESTS = (
    "test/features/local_comics/import_export/pdf_import_test.dart",
    "test/features/local_comics/import_export/import_registration_failure_test.dart",
)


def tree_digest(root):
    result = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if (set(relative.parts) & {".git", ".dart_tool", "oh_modules", ".hvigor", "build"} or
                path.name in ("pubspec.lock", "oh-package-lock.json5", "flutter.har")):
            continue
        if path.is_symlink():
            raise ValueError("Unexpected dependency symlink")
        if path.is_file():
            result.update(path.relative_to(root).as_posix().encode() + b"\0")
            result.update(path.read_bytes())
    return result.hexdigest()


def require_committed_inputs(*paths):
    changed = subprocess.check_output(["git", "-C", str(ROOT), "diff", "--name-only", "HEAD", "--",
                                       *paths], timeout=120)
    if changed:
        raise ValueError("Uncommitted reader source inputs: " + changed.decode("utf-8").strip())


def git_input_bytes(name):
    """Use canonical Git bytes, independent of checkout EOL attributes."""
    try:
        return subprocess.check_output(["git", "-C", str(ROOT), "show", f"HEAD:{name}"], timeout=120)
    except subprocess.CalledProcessError as error:
        raise ValueError("Missing committed reader input: " + name) from error


def project_tree_digest(root):
    """Hash committed package blobs, independently of EOL rules and build caches."""
    prefix = root.relative_to(ROOT).as_posix()
    names = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "--",
                                     prefix], timeout=120).split(b"\0")
    if not any(names):
        raise ValueError("Missing committed project package")
    inputs = sorted(value.decode("utf-8") for value in names if value)
    for name in inputs:
        path = require_within(ROOT / name, root)
        if not path.is_file():
            raise ValueError("Missing project package input: " + name)
    require_committed_inputs(prefix)
    result = hashlib.sha256()
    for name in inputs:
        result.update(Path(name).relative_to(root.relative_to(ROOT)).as_posix().encode("utf-8") + b"\0")
        result.update(git_input_bytes(name))
    return result.hexdigest()


def project_packages():
    inventory = json.loads((ROOT / "doc/development/git_dependencies.json").read_text(encoding="utf-8"))
    records = {item["dependency"]: item for item in inventory["local_packages"]}
    if set(records) != set(PROJECT_PACKAGES):
        raise ValueError("Project package inventory changed; review the OHOS candidate")
    result = {}
    for name in PROJECT_PACKAGES:
        item = records[name]
        if item["path"] != "packages/" + name:
            raise ValueError("Unexpected project package path")
        root = ROOT / item["path"]
        version = re.findall(r"^version:[ \t]*([^\r\n]+)$", (root / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
        if version != [item["version"]]:
            raise ValueError("Project package version changed: " + name)
        result[name] = {"project_path": item["path"], "version": item["version"],
                        "prepared_sha256": project_tree_digest(root)}
    return result


def patch_once(text, original, replacement):
    if text.count(original) != 1:
        raise ValueError("Pinned dependency changed; review the OHOS patch")
    return text.replace(original, replacement)


def patch_so_loader(text):
    return patch_once(text, "if (Platform.isAndroid || Platform.isLinux) {",
                      "if (Platform.isAndroid || Platform.isLinux || "
                      "Platform.operatingSystem == 'ohos') {")


def patch_sqlite_loader(text):
    # sqlite3 3.8.0 loads through code_assets hooks; the old ffi
    # load_library.dart no longer exists. Resolve the NDK-built library
    # from the system loader on OHOS instead of the GitHub prebuilt.
    if "const LookupSystem('sqlite3')" in text:
        raise ValueError("SQLite OHOS loader must only be applied once")
    return patch_once(
        text,
        "    final targetOS = input.config.code.targetOS;\n\n    // `source` and `name` are either",
        "    final targetOS = input.config.code.targetOS;\n"
        "    // The OHOS SDK reports hook targets as Linux, so the prepared\n"
        "    // project opts this package into the system sqlite3 instead of\n"
        "    // guessing from targetOS.\n"
        "    if (input.userDefines['venera_harmonyos_system_sqlite'] == true) {\n"
        "      return const LookupSystem('sqlite3');\n"
        "    }\n\n"
        "    // `source` and `name` are either")


def patch_pdfium_hook(text):
    # This SDK deliberately labels OHOS hook inputs as Linux. An explicit,
    # isolated-project define prevents silently bundling Linux PDFium for OHOS.
    if "OS.ohos" in text:
        raise ValueError("PDFium's unsupported OHOS boundary must only be applied once")
    return patch_once(text, "if (!input.config.buildCodeAssets) return;",
                      "if (!input.config.buildCodeAssets) return;\n"
                      "    if (input.userDefines['venera_harmonyos_experiment'] == true) return;\n"
                      "    if (input.config.code.targetOS == OS.ohos) return;")


def patch_webview_native_profile(text):
    # The same pinned helper is compiled and hash-audited with the reader libs.
    return patch_once(text, '''  "buildOption": {
    "externalNativeOptions": {
      "path": "./src/main/cpp/CMakeLists.txt",
      "arguments": "",
      "cppFlags": "",
    }
  },''', '  "buildOption": {},')


def patch_webview_environment_api(destination, upstream):
    """Keep Windows-only source type-safe; never synthesize an exit event."""
    facade = "flutter_inappwebview/lib/src/webview_environment/webview_environment.dart"
    interface = "flutter_inappwebview_platform_interface/lib/src/webview_environment/platform_webview_environment.dart"
    patterns = {
        facade: (r"  ///\{@macro flutter_inappwebview_platform_interface\.PlatformWebViewEnvironment\.onBrowserProcessExited\}"
                 r".*?platform\.onBrowserProcessExited = value;"),
        interface: (r"  ///\{@template flutter_inappwebview_platform_interface\.PlatformWebViewEnvironment\.onBrowserProcessExited\}"
                    r".*?void Function\(BrowserProcessExitedDetail detail\)\? onBrowserProcessExited;"),
    }
    blocks = {}
    for name, pattern in patterns.items():
        matches = re.findall(pattern, (upstream / name).read_text(encoding="utf-8"), re.S)
        if len(matches) != 1:
            raise ValueError("Pinned WebView environment API changed; review the backport")
        blocks[name] = matches[0]
    for name in WEBVIEW_API_TYPES:
        target = destination / WEBVIEW_TYPES / name
        if target.exists():
            raise ValueError("WebView API backport must only be applied once")
        shutil.copy2(upstream / WEBVIEW_TYPES / name, target)
    for name, block in blocks.items():
        target = destination / name
        text = target.read_text(encoding="utf-8")
        if "onBrowserProcessExited" in text:
            raise ValueError("WebView API backport must only be applied once")
        if name == interface:
            text = patch_once(text, "import '../types/disposable.dart';",
                              "import '../types/disposable.dart';\nimport '../types/browser_process_exited_detail.dart';")
        anchor = ("  ///{@macro flutter_inappwebview_platform_interface.PlatformWebViewEnvironment.dispose}"
                  if name == facade else
                  "  ///{@template flutter_inappwebview_platform_interface.PlatformWebViewEnvironment.dispose}")
        target.write_text(patch_once(text, anchor, block + "\n\n" + anchor), encoding="utf-8")
    target = destination / WEBVIEW_TYPES / "main.dart"
    target.write_text(patch_once(target.read_text(encoding="utf-8"), "export 'disposable.dart';",
                                "export 'disposable.dart';\nexport 'browser_process_exit_kind.dart';\n"
                                "export 'browser_process_exited_detail.dart';\nexport 'enum_method.dart';"), encoding="utf-8")


def extract_checked(archive, destination):
    destination = require_within(destination, BASE)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        for item in package.getmembers():
            require_within(destination / item.name, destination)
            if not (item.isfile() or item.isdir()):
                raise ValueError("Unexpected dependency archive link or special file")
        package.extractall(destination, filter="data")


def export_git(name, spec):
    repository = require_within(BASE / "full-repositories" / name, BASE)
    if not (repository / ".git").exists():
        if repository.exists():
            raise ValueError("Refusing an unknown dependency checkout")
        command(["git", "clone", "--filter=blob:none", "--no-checkout", spec["repository"], repository])
        if os.name == "nt":
            command(["git", "-C", repository, "config", "--local", "core.longpaths", "true"])
        command(["git", "-C", repository, "fetch", "--depth", "1", "origin", spec["ref"]])
        command(["git", "-C", repository, "checkout", "--detach", "FETCH_HEAD"])
    head = subprocess.check_output(["git", "-C", repository, "rev-parse", "HEAD"], text=True).strip()
    if head != spec["revision"]:
        raise ValueError(f"Unexpected pinned {name} revision")
    command(["git", "-C", repository, "diff", "--exit-code", "HEAD"])
    archive = BASE / f"full-{name}.tar"
    command(["git", "-C", repository, "archive", "--format=tar", f"--output={archive}", head])
    destination = DEPS / name
    extract_checked(archive, destination)
    return destination


def check_hosted_baseline(name, spec, text):
    block = re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  \w+:|^sdks:)", text, re.M | re.S)
    if not block:
        raise ValueError(f"Missing main dependency {name}")
    version = re.search(r'    version: "([^"\n]+)"', block[1])
    checksum = re.search(r'      sha256: "?([0-9a-f]{64})"?', block[1])
    if not version or not checksum:
        raise ValueError(f"Main {name} lock changed; update the experiment explicitly")
    pinned = HAP_PINNED_HOSTED.get(name)
    if pinned is not None:
        # The HAP deliberately pins a dart-3.11-compatible version that differs
        # from the main lock. HAP_PINNED_HOSTED is the single source of truth and
        # export_hosted still enforces the archive checksum, so the mainline
        # record only has to exist.
        if pinned != spec["version"]:
            raise ValueError(f"HAP pin for {name} disagrees with the experiment pin")
        return
    if version[1] != spec["version"] or checksum[1] != spec["sha256"]:
        raise ValueError(f"Main {name} lock changed; update the experiment explicitly")


def export_hosted(name, spec):
    check_hosted_baseline(name, spec, (ROOT / "pubspec.lock").read_text(encoding="utf-8"))
    archive = BASE / f"full-{name}-{spec['version']}.tar.gz"
    if not archive.exists():
        download = archive.with_suffix(".download")
        command(["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
                 "--retry-all-errors", "--max-time", "300", "--output", download,
                 f"https://pub.dev/api/archives/{name}-{spec['version']}.tar.gz"])
        if digest(download) != spec["sha256"]:
            raise ValueError(f"Changed hosted archive for {name}")
        download.replace(archive)
    if digest(archive) != spec["sha256"]:
        raise ValueError(f"Changed hosted archive for {name}")
    destination = DEPS / name
    extract_checked(archive, destination)
    return destination


def prepare_dependencies(qjs_source):
    DEPS.mkdir(parents=True, exist_ok=True)
    previous = verify_dependencies() if (DEPS / "sources.json").exists() else {}
    if "webview_api" in previous:
        # Only remove known added files from a byte-verified owned export.
        # The original Git archive restores all other patched dependency files.
        for name in WEBVIEW_API_TYPES:
            require_within(DEPS / "webview" / WEBVIEW_TYPES / name, DEPS).unlink()
    records = {}
    for name in GIT_DEPENDENCIES:
        spec = FULL_CONFIG[name]
        root = export_git(name, spec)
        records[name] = {"revision": spec["revision"], "original_sha256": tree_digest(root)}
    for name, spec in FULL_CONFIG["hosted"].items():
        root = export_hosted(name, spec)
        records[name] = {**spec, "original_sha256": tree_digest(root)}
    export_qjs(qjs_source, BASE / "deps/flutter_qjs")
    patch_webview_environment_api(DEPS / "webview", DEPS / "webview_api")
    for name, loader in (("zip_flutter", "lib/src/zip_dart_base.dart"),):
        path = DEPS / name / loader
        path.write_text(patch_so_loader(path.read_text(encoding="utf-8")), encoding="utf-8")
    path = DEPS / "sqlite3/lib/src/hook/compile/description.dart"
    path.write_text(patch_sqlite_loader(path.read_text(encoding="utf-8")), encoding="utf-8")
    path = DEPS / "pdfium_dart/hook/build.dart"
    path.write_text(patch_pdfium_hook(path.read_text(encoding="utf-8")), encoding="utf-8")
    path = DEPS / "webview/flutter_inappwebview_ohos/ohos/build-profile.json5"
    path.write_text(patch_webview_native_profile(path.read_text(encoding="utf-8")), encoding="utf-8")
    for path in [DEPS / "pdfium_dart/pubspec.yaml", DEPS / "code_assets/pkgs/code_assets/pubspec.yaml"]:
        path.write_text(patch_once(path.read_text(encoding="utf-8"), "resolution: workspace\n", ""),
                        encoding="utf-8")
    for name in records:
        records[name]["prepared_sha256"] = tree_digest(DEPS / name)
    records["flutter_qjs"] = {"revision": CONFIG["quickjs"]["revision"],
                              "prepared_sha256": tree_digest(BASE / "deps/flutter_qjs")}
    records.update(project_packages())
    (DEPS / "sources.json").write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    return records


def verify_dependencies():
    records = json.loads((DEPS / "sources.json").read_text(encoding="utf-8"))
    expected = set(GIT_DEPENDENCIES) | set(FULL_CONFIG["hosted"]) | {"flutter_qjs"} | set(PROJECT_PACKAGES)
    if set(records) != expected:
        raise ValueError("Incomplete reviewed reader dependency manifest")
    projects = project_packages()
    for name, record in records.items():
        if name in projects:
            if record != projects[name]:
                raise ValueError("Prepared project package changed: " + name)
            continue
        root = BASE / "deps/flutter_qjs" if name == "flutter_qjs" else DEPS / name
        if tree_digest(root) != record["prepared_sha256"]:
            raise ValueError(f"Prepared dependency changed: {name}")
    return records


# The ohos SDK ships dart 3.11.5 / flutter 3.41: our main lock moved past
# it (pdfrx 2.11, material pair, app_links 7). Pin the newest compatible
# versions for the HAP build only; the main app is untouched. pdfium_dart is
# not here: it keeps a path override on the exported 0.2.5 copy (see
# HAP_PINNED_HOSTED). meta is pinned UP: the ohos flutter_test pins
# meta 1.17.0 exactly, but hooks 2.2.0 -> record_use needs ^1.19.0 (whose
# own floor is only dart 3.5, so 1.19.0 runs on 3.11).
VERSION_PINS = {
    "pdfrx": "2.4.7", "pdfrx_engine": "0.4.5",
    "pdfium_flutter": "0.2.3",
    "dynamic_color": "1.7.0",
    "app_links": "6.2.0", "app_links_linux": "1.0.2",
    "app_links_platform_interface": "2.0.1", "app_links_web": "1.0.4",
    "meta": "1.19.0",
    # flutter_file_dialog 3.x all need dart >=3.12; newest 3.11-era is 3.0.2
    # (API-verified: SaveFileDialogParams.sourceFilePath + saveFile exist).
    "flutter_file_dialog": "3.0.2",
}

# Hosted packages the HAP pins below the main lock and applies as a path
# override, so the exported copy (not the hosted package) carries our patch.
# pdfium_dart 0.4.1 needs dart ^3.13; the 0.2.5 hook is the one we patch to keep
# Linux PDFium out of the HAP.
HAP_PINNED_HOSTED = {"pdfium_dart": "0.2.5"}


def configure_pubspec(text, identity=None):
    identity = identity or build_inputs()
    text = re.sub(r"^version: .*?$", f"version: {identity['version_name']}+{identity['version_code']}",
                  text, count=1, flags=re.M)
    # The fork pins newer SDKs than the OHOS toolchain; the prepared project
    # must still resolve with flutter-ohos 3.41.9 and dart 3.11.5.
    text = patch_once(text, "  sdk: '>=3.12.0 <4.0.0'", "  sdk: '>=3.11.0 <4.0.0'")
    text = patch_once(text, "  flutter: 3.47.8", '  flutter: ">=3.41.4 <4.0.0"')
    for name in PROJECT_PACKAGES:
        text = patch_once(text, f"path: packages/{name}", f"path: ../../../packages/{name}")
    # sqlite3 3.8.0's hook needs the code_assets v2 API (and hooks ^2.2.0);
    # DEPS pins code_assets 1.0.0 (hooks ^1.0.0), which cannot solve together.
    # Hosted code_assets 1.2.1 (our lock, CI-proven with this hook) is used.
    overrides = {
        "flutter_qjs": "../deps/flutter_qjs",
        **{name: f"../full-deps/{name}" for name in ("sqlite3", "zip_flutter", "pdfium_dart")},
        **{name: f"../full-deps/webview/{name}" for name in WEBVIEW_PACKAGES},
    }
    # HAP-only pins live in VERSION_PINS (module level, single source of truth).
    # pdfium_dart stays a path override on the pinned 0.2.5 archive: only that
    # copy can be patched, and its hook would otherwise bundle Linux PDFium into
    # the HAP (the hosted 0.4.1 export cannot resolve on dart 3.11).
    section = re.search(r"^dependency_overrides:\n(.*?)(?=^\w|\Z)", text, re.M | re.S)
    if section is None:
        raise ValueError("Missing main dependency overrides; review the OHOS candidate")
    body = section[1]
    # The HAP uses one coordinated CPF platform group. Replace mainline Git and
    # Windows-local overrides before adding these paths, rather than duplicating
    # YAML keys or resolving incompatible mainline and OHOS interfaces together.
    for name in overrides:
        pattern = rf"^  {re.escape(name)}:[ \t]*\n(?:(?:    [^\n]*|[ \t]*)\n)*"
        body, count = re.subn(pattern, "", body, flags=re.M)
        if count > 1:
            raise ValueError("Duplicate main dependency override: " + name)
    text = patch_once(text, section[0], "dependency_overrides:\n" + body)
    lines = "".join(f"  {name}:\n    path: {path}\n" for name, path in overrides.items())
    lines += "".join(f"  {name}: {version}\n" for name, version in VERSION_PINS.items())
    text = patch_once(text, "dependency_overrides:\n", "dependency_overrides:\n" + lines)
    text = patch_once(text, "    - assets/translation.json\n",
                      "    - assets/translation.json\n    - assets/harmonyos-app-build.json\n"
                      f"    - {NATIVE_NOTICE_ASSET}\n")
    if re.search(r"^hooks:", text, re.M):
        raise ValueError("Main hook configuration changed; review the experiment")
    text += ("\nhooks:\n  user_defines:\n    pdfium_dart:\n"
             "      venera_harmonyos_experiment: true\n"
             "    sqlite3:\n"
             "      venera_harmonyos_system_sqlite: true\n")
    return text


def apply_analyze_excludes(text, excludes):
    marker = "\n  exclude:\n"
    if text.count(marker) != 1:
        raise ValueError("analysis_options.yaml must carry one analyzer exclude list")
    if not excludes:
        return text
    block = marker + "".join(
        "    # HAP-only: overrides a pdfrx member the pinned set lacks.\n"
        f"    - {name}\n" for name in excludes)
    return text.replace(marker, block, 1)


def app_source_manifest():
    require_committed_inputs("pubspec.yaml", "pubspec.lock", "CHANGELOG.md", "release.json",
                             "lib", "assets", "shaders", "packages")
    files = [ROOT / "pubspec.yaml", ROOT / "pubspec.lock", ROOT / "CHANGELOG.md", ROOT / "release.json"]
    files.extend(sorted((ROOT / "lib").rglob("*.dart")))
    files.extend(sorted(path for path in (ROOT / "assets").rglob("*") if path.is_file()))
    files.extend(sorted(path for path in (ROOT / "shaders").rglob("*") if path.is_file()))
    packages = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "--", "packages/"]).split(b"\0")
    files.extend(ROOT / name.decode("utf-8") for name in packages if name)
    return {path.relative_to(ROOT).as_posix():
        hashlib.sha256(git_input_bytes(path.relative_to(ROOT).as_posix())).hexdigest()
        for path in files}


def prepare_project(args):
    identity = build_inputs()
    sdk = args.flutter_sdk.resolve()
    head = subprocess.check_output(["git", "-C", sdk, "rev-parse", "HEAD"], text=True).strip()
    if head != CONFIG["flutter"]["revision"]:
        raise ValueError("Unexpected Flutter OH toolchain")
    project = require_within(PROJECT, BASE)
    flutter = sdk / ("bin/flutter.bat" if os.name == "nt" else "bin/flutter")
    if not (project / ".metadata").exists():
        if project.exists() and any(project.iterdir()):
            raise ValueError("Refusing to overwrite an unknown application directory")
        command([flutter, "create", "--platforms", "ohos", "--no-pub", "--org",
                 "io.github.venera", "--project-name", "venera_unified", project])
        (project / ".venera-harmonyos-owned").write_text("generated full app\n", encoding="utf-8")
    if not (project / ".venera-harmonyos-owned").exists():
        raise ValueError("Missing generated-project ownership marker")
    records = verify_dependencies()
    # integration_test is copied too: unit tests under test/ import shared
    # fixtures from it, and the analyze gate resolves those imports.
    for name in ("lib", "assets", "test", "integration_test"):
        destination = require_within(project / name, project)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(ROOT / name, destination)
    # pubspec declares shaders as a Flutter asset section; without the sources
    # the asset bundle step fails before any test runs.
    if (ROOT / "shaders").is_dir():
        destination = require_within(project / "shaders", project)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(ROOT / "shaders", destination)
    notice = require_within(project / NATIVE_NOTICE_ASSET, project)
    notice.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(NATIVE_NOTICE_SOURCE, notice)
    fixtures = require_within(project / "packages/venera_native/test/fixtures", project)
    shutil.copytree(ROOT / "packages/venera_native/test/fixtures", fixtures, dirs_exist_ok=True)
    # Only relocate repository-relative test imports; runtime source is unchanged.
    for name, original, source in (
        ("test/foundation/photo_view_controller_lifecycle_test.dart",
         "../../packages/photo_view/test/controller_lifecycle_test.dart",
         ROOT / "packages/photo_view/test/controller_lifecycle_test.dart"),
        ("test/tool/git_dependencies_test.dart", "../../tool/check_git_dependencies.dart",
         ROOT / "tool/check_git_dependencies.dart"),
    ):
        path = project / name
        relocated = os.path.relpath(source, path.parent).replace("\\", "/")
        path.write_text(patch_once(path.read_text(encoding="utf-8"), original, relocated), encoding="utf-8")
    (project / "pubspec.yaml").write_text(configure_pubspec((ROOT / "pubspec.yaml").read_text(encoding="utf-8"), identity), encoding="utf-8")
    (project / "CHANGELOG.md").write_text(identity["changelog"], encoding="utf-8")
    shutil.copy2(ROOT / "LICENSE", project / "LICENSE")
    options = project / "analysis_options.yaml"
    options.write_text(
        apply_analyze_excludes((ROOT / "analysis_options.yaml").read_text(encoding="utf-8"),
                               HAP_PDFRX_208_TESTS),
        encoding="utf-8")
    lock = Path(__file__).with_name("app") / "pubspec.lock.template"
    if lock.exists():
        shutil.copy2(lock, project / "pubspec.lock")
    elif not args.resolve_lock:
        raise ValueError("Missing reviewed full-app lock; only development may resolve it")
    else:
        shutil.copy2(ROOT / "pubspec.lock", project / "pubspec.lock")
    for template in Path(__file__).with_name("app").rglob("*.template"):
        if template.name == "pubspec.lock.template":
            continue
        destination = require_within(project / template.relative_to(Path(__file__).with_name("app")).with_suffix(""), project)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(template, destination)
    profile = project / "ohos/build-profile.json5"
    profile.write_text(configure_profile(profile.read_text(encoding="utf-8"), CONFIG["harmonyCiSdk"]["targetSdk"]), encoding="utf-8")
    module = project / "ohos/entry/src/main/module.json5"
    module.write_text(configure_device_types(module.read_text(encoding="utf-8")), encoding="utf-8")
    app_json = project / "ohos/AppScope/app.json5"
    app = json.loads(app_json.read_text(encoding="utf-8"))
    app["app"].update(bundleName=FULL_CONFIG["bundle_name"], versionName=identity["hap_version_name"],
                       versionCode=identity["version_code"], vendor="ACGNnsj")
    app_json.write_text(json.dumps(app, indent=2) + "\n", encoding="utf-8")
    entry_profile = project / "ohos/entry/build-profile.json5"
    entry_profile.write_text(json.dumps({"apiType": "stageMode", "buildOption": {
        "nativeLib": {"debugSymbol": {"strip": False, "exclude": []}}}, "targets": [
        {"name": "default", "runtimeOS": "HarmonyOS"}, {"name": "ohosTest"}]}, indent=2) + "\n", encoding="utf-8")
    for root in (project / "ohos/AppScope/resources/base", project / "ohos/entry/src/main/resources/base"):
        strings = root / "element/string.json"
        data = json.loads(strings.read_text(encoding="utf-8"))
        for item in data["string"]:
            if item["name"] in ("app_name", "EntryAbility_label"):
                item["value"] = "Venera Unified (HarmonyOS Beta)"
        strings.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        for name in ("app_icon.png", "icon.png"):
            if (root / "media" / name).exists():
                shutil.copy2(ROOT / "assets/app_icon.png", root / "media" / name)
    native = verify_native_report(args.native_dir / "native-build.json", args.native_dir / "arm64-v8a")
    extras = json.loads((args.extra_native_dir / "extra-native-build.json").read_text(encoding="utf-8"))
    if (extras.get("status") != "cross_compile_pass" or extras.get("dependencies") != records or
            extras.get("build_script_sha256") != digest(Path(__file__).with_name("full_native_build.py")) or
            any(extras.get(key) != native.get(key) for key in ("sdk_profile", "sdk_version", "sdk_api"))):
        raise ValueError("Full app needs matching, audited extra native libraries")
    destination = project / "ohos/entry/libs/arm64-v8a"
    destination.mkdir(parents=True, exist_ok=True)
    expected = {item["name"]: item["sha256"] for item in native["libraries"]}
    if set(item["name"] for item in extras["libraries"]) != set(EXTRA_LIBRARIES):
        raise ValueError("Missing complete reader native libraries")
    for item in extras["libraries"]:
        source = args.extra_native_dir / "arm64-v8a" / item["name"]
        if digest(source) != item["sha256"]:
            raise ValueError("Changed extra native library")
        shutil.copy2(source, destination / source.name)
        expected[source.name] = item["sha256"]
    for name in ("librhttp.so", "libqjs.so", "libsqlite3.so", "libc++_shared.so"):
        shutil.copy2(args.native_dir / "arm64-v8a" / name, destination / name)
    metadata = {
        "schema": 1, "purpose": "full_reader_experiment", "branch": "main",
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "bundle_name": FULL_CONFIG["bundle_name"], "version_name": identity["version_name"],
        "hap_version_name": identity["hap_version_name"],
        "version_code": identity["version_code"], "device_types": ["phone", "tablet"],
        "release": identity["release"],
        "minimum_sdk": "26.0.0", "entrypoint": "lib/main.dart", "reader_integrated": True,
        "runtime_verified": False, "signed": False, "unavailable": FULL_CONFIG["unavailable"],
        "source_files": app_source_manifest(), "dependencies": records, "native_libraries": expected,
        # Our pubspec lists the assets/opencc/ directory (upstream lists files
        # only); directories are skipped here and in verify (their contents stay
        # git-tracked in source_files and are still bundled by flutter).
        "bundled_assets": {
            name: digest(ROOT / name) for name in re.findall(
                r"^    - (assets/[^\r\n]+)$", (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
            if (ROOT / name).is_file()
        },
    }
    metadata["bundled_assets"][NATIVE_NOTICE_ASSET] = digest(NATIVE_NOTICE_SOURCE)
    (project / "assets/harmonyos-app-build.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    pub_args = ["pub", "get"] + ([] if args.resolve_lock else ["--enforce-lockfile"])
    if args.offline:
        pub_args.append("--offline")
    env = os.environ.copy()
    env["PUB_HOSTED_URL"] = "https://pub.dev"
    if args.dart_only:
        env["FLUTTER_ROOT"] = str(sdk)
        dart = sdk / ("bin/cache/dart-sdk/bin/dart.exe" if os.name == "nt" else "bin/cache/dart-sdk/bin/dart")
        command([dart, *pub_args], cwd=project, env=env)
        print("Dart-only preparation does not verify plugin registration or a HAP.")
    else:
        command([flutter, *pub_args], cwd=project, env=env)
    print(f"Prepared real entrypoint {project / 'lib/main.dart'}; no device runtime is claimed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("deps", "project"))
    parser.add_argument("--flutter-sdk", type=Path)
    parser.add_argument("--qjs-source", type=Path)
    parser.add_argument("--native-dir", type=Path, default=BASE / "native")
    parser.add_argument("--extra-native-dir", type=Path, default=BASE / "full-native")
    parser.add_argument("--dart-only", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--resolve-lock", action="store_true")
    args = parser.parse_args()
    if args.stage == "deps":
        if args.qjs_source is None:
            parser.error("deps requires --qjs-source")
        prepare_dependencies(args.qjs_source.resolve())
    else:
        if args.flutter_sdk is None:
            parser.error("project requires --flutter-sdk")
        prepare_project(args)


if __name__ == "__main__":
    main()
