# Release Readiness

The authoritative release identity is [release.json](../../release.json), the version in
[pubspec.yaml](../../pubspec.yaml), and the release tag. CI validates their agreement;
this page is not a second version source.

## Published baseline

The current published baseline is [Venera Unified v1.22.0](https://github.com/ACGNnsj/venera-unified/releases/tag/v1.22.0)
(`1.22.0+249`), published on 2026-11-14. It declares Flutter `3.47.8`.

- The GitHub Release metadata names target commit `6ce80711e9a67a93198089454df67fca0254531d`.
- [Release CI run 43550696740](https://github.com/ACGNnsj/venera-unified/actions/runs/43550696740)
  completed successfully and lists 25 downloadable assets, including Android, Windows,
  macOS, iOS, Linux and an unsigned HarmonyOS HAP.
- The currently fetched annotated tag object `ed4a5141ee1e1b4b2566ddd71c0faa470699b2d1`
  peels to commit `dc0af493dd70e03f979a3e106d2fb021a30615cb`. Both the Release target
  and successful CI head are instead `6ce80711e9a67a93198089454df67fca0254531d`.
  The current tag therefore does not identify the same source revision as the published
  CI/assets; do not describe them as one verified source SHA without resolving that mismatch.

A successful asset upload is packaging evidence, not proof that every artifact passed
runtime acceptance on a physical device.

## Check one candidate

Run the metadata, dependency, structure and CI contract checks before producing assets:

```sh
python .github/scripts/release_version.py --check
python .github/scripts/validate_release.py --build-only
python .github/scripts/check_structure_imports.py
python .github/scripts/check_architecture_dependencies.py
fvm dart tool/check_git_dependencies.dart
fvm flutter test test/tool/ci_workflow_contract_test.dart
fvm flutter test
```

For an actual tag, use `python .github/scripts/validate_release.py --tag vX.Y.Z`
instead of `--build-only`. Generate synchronized version files with
`python .github/scripts/release_version.py --write`, then review the diff rather than
hand-editing only one version location.

Dependency sources, reviewed local forks and platform bundling rules are recorded in
the [dependency policy](dependencies.en.md), [rhttp local patches](../../packages/rhttp/LOCAL_PATCHES.md)
and the [pdfium hook patch](../../.github/scripts/patch_pdfium_hook.py). Resolve Git packages
from the lockfile in a clean cache; a pre-existing modified shared pub-cache checkout is
not a successful inventory check.

## Platform evidence

### Android and Windows

Record the workflow run, job revision, artifact names, hashes and installer/package
metadata. Android phone, Android TV and Windows MSIX are separate surfaces. Keep their
signing, installation, launch, update and reader checks with the matching artifact.

### Apple

macOS and iOS evidence belongs to the Apple jobs that built those artifacts. Linux
analysis and bundling checks do not replace an Apple build, signature/notarization check,
installation or device smoke test. Record the Xcode/Flutter toolchain and the exact job
or local revision used for each result.

### HarmonyOS

The published HAP name explicitly says `unsigned`. Keep packaging, manifest, native
library, signing and device-installation results separate. An unsigned HAP is not a
release-signed installation claim, and an emulator or unit-test result is not physical
HarmonyOS acceptance.

## Publish and audit

Attach provenance, checksums, licenses and symbols produced by the same revision as the
artifacts. Do not copy an older release's acceptance table or asset list into a new
candidate. Before publishing, compare the Release target, tag object, CI head SHA and
artifact manifest; investigate any difference instead of hiding it in the notes.

The final release note should link the exact CI run and state any remaining platform
validation limits. Reader diagnostics use [schema 3](reader_diagnostics.md); keep its
bounded preview and explicit full-report export semantics intact when collecting
release evidence.
