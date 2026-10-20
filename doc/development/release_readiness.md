# Patch release readiness

This checklist tracks the release preparation following v1.18.0. It does not
authorize publishing a tag or mark unresolved issue reports as fixed.

## Startup report 111

The report describes an Android startup failure after upgrading from v1.17.0
or importing old settings, and a Windows SQLite read-only error. The attached
log inspected on 2026-10-19 contains cancelled requests and JavaScript bridge
cleanup errors, but not the reported SQLite error or the primary startup stack.
These are insufficient to establish a settings-format incompatibility.

An isolated Windows smoke test using the v1.17.0 default settings structure
successfully starts the real core, preserves the old reader mode and search
history, and closes its native resources. This is a baseline only: it does not
reproduce the reporter's custom settings, existing databases, or Android device.
The missing details were requested in
[issue 111](https://github.com/CyrilPeng/Venera-Next/issues/111#issuecomment-6267054445).

The diagnostic improvements record the startup phase and original error before
rollback closes the log writer. Failures before the normal application is shown
use a standalone, scrollable diagnostic page with redacted clipboard export.
Desktop failure startup explicitly reveals a titled native window with working
system close controls, without reading or writing persisted window placement.
It does not retry partial startup, reset preferences, recreate databases, or
weaken storage ownership and rollback. Headless stdout remains unchanged.

Further acceptance requires the primary Android failure details and the Windows
SQLite stack, including which database and statement failed. Ask whether the
backup was an application-data export or a settings-only export, the exact
versions/builds, and the installation/data-directory location. Prefer redacted
diagnostics and a minimal synthetic settings reproduction over full private
backups. Do not recommend deleting user data or running as administrator as a
substitute for identifying the cause.

## Logging

Default masks cover credentials in request/response headers, common structured
payload fields, URL user information, signed query fields, and known credential
assignments in text. The final Log boundary masks before truncation, console
output, in-memory storage, startup replay, and file append. Custom header/body
masks still apply, and transport objects are not modified.

This is not a general personal-data anonymizer. Arbitrary source-script output,
unknown credential field names, personal paths, and private URLs still need
review before sharing. Existing exported or previously published logs are not
retroactively scrubbed; remove sensitive attachments and revoke exposed sessions
separately.

## Changelog and favorites

- The full CHANGELOG.md remains the release-note source. Its H2 sections become
  version labels in document order. Empty sections are skipped, and documents
  without version headings retain a fallback view.
- Version labels and selected-section lines use lazy lists. Inactive versions
  have no mounted body widgets. Switching versions starts at the top; theme and
  layout changes do not reread the asset.
- Favorites search refreshes only after an accepted folder query. Existing
  ownership/generation guards, read filters, and keyword blocks remain intact.
  The search defect is independently reproduced; issue 110 still needs reporter
  confirmation before treating its original report as resolved.

## Local verification (2026-10-20)

The unreleased changes were verified on Windows x64 with Flutter
3.41.6 and Dart 3.11.4. The repository's CI SDK target remains Flutter 3.41.4;
these local results do not replace final-state CI or device acceptance.

- Release metadata, structure imports, architecture dependencies, and pinned Git
  dependencies passed. All 19 changed/new Dart files passed formatting, strict
  Flutter analysis found no issues, and git diff --check passed.
- Python release-script tests: 127 run, four skips, no failures.
- Final full Flutter suite: 5,305 passed, two platform-conditional skips, zero
  failures, using flutter test --no-pub --concurrency=1 --machine. The earlier
  parallel sync-test timeouts are not counted as passes; this complete serial
  run passed without weakening assertions or increasing test timeouts.
- The additional desktop failure-window regression run passed all 38 tests,
  including native-call ordering, close interception disabled, awaited show
  completion, and native initialization failure propagation.
- Android ARM64 and Windows x64 release builds passed after the final code
  change. The APK is build/app/outputs/flutter-apk/app-release.apk; use the whole
  build/windows/x64/runner/Release directory for Windows, not the EXE alone.
- The independent code-audit package passed locked offline dependency resolution,
  its AST self-check, and its own strict analysis.

Local diagnostic evidence is retained in ignored build/release-final-quality.log,
build/release-final-flutter-tests.log, build/release-final-test-summary.json,
build/release-final-windows-build.log, build/release-final-android-build.log,
build/release-final-code-audit.log, and build/release-final-artifacts.json.
The window-control regressions use mocked platform channels, not a real native
failure-window launch. The full Windows startup smoke script requires a fresh
disposable CI runner; it was not run against a daily-use user profile.

No Android device was connected for this verification. Real upgrade/import,
screen-off download, reconnect, and notification-pause acceptance remains open.
Issues 110 and 111 have no additional reporter feedback as of this check. No
version/build increment, release tag, or issue closure was made during local
verification.

## Release gates

1. Establish the root cause or an actionable environmental diagnosis for #111.
2. Run formatter, structure/dependency checks, Python release tests, strict Flutter
   analysis, and the full Flutter suite on the final source state.
3. Build Android and Windows release artifacts locally where supported. Run the
   repository quality and complete-build workflows on the final committed state
   for the remaining platforms; an older green run is not final-state evidence.
4. Perform upgrade/data-import smoke tests with preserved test data, plus reader,
   changelog, and favorites smoke tests. Verify the diagnostic window's native
   visibility and close controls on a clean desktop profile. Follow
   android_downloads.md for Android device acceptance, especially screen-off,
   reconnect, and notification pause.
5. Only after acceptance, update version/build metadata and versioned release
   notes, then validate with .github/scripts/validate_release.py for the intended
   tag. Keep unresolved OEM-specific limitations explicit in the release notes.
