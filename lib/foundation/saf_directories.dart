import 'package:venera_saf/venera_saf.dart' show isSafPath;

/// Shared generic-SAF directory helpers for the local-comics chain.
///
/// Unified stores external library locations as either plain filesystem paths
/// or generic document-provider paths (`android://...`, where the suffix after
/// the prefix is the real document ID served through persisted URI grants in
/// `SafDocuments`). Desktop/OHOS `directAccess` copies and the Windows/macOS
/// passthrough keep working: non-`android://` paths resolve exactly as before.
/// All download/read/export/migration entry points must resolve through here
/// so SAF and local paths share one chain (`overrideIO` + `SAFTaskWorker` +
/// `DirectorySelection.copy`).
String resolveComicDirectory(String directory, String libraryPath) {
  if (directory.contains('/') || directory.contains('\\')) {
    return directory;
  }
  final separator =
      libraryPath.startsWith(r'\\') ||
          RegExp(r'^[a-zA-Z]:\\').hasMatch(libraryPath)
      ? r'\'
      : '/';
  if (libraryPath.endsWith('/') || libraryPath.endsWith(separator)) {
    return '$libraryPath$directory';
  }
  return '$libraryPath$separator$directory';
}

/// True when [path] is a generic document-provider location whose suffix is a
/// real document ID (tree URI grant), not a local filesystem path.
bool isGenericSafDirectory(String path) => isSafPath(path);

/// The real document ID behind a generic `android://` directory path.
/// Returns null for local paths.
String? safDocumentId(String path) =>
    isSafPath(path) ? path.substring('android://'.length) : null;

/// Whether an unavailable path must be kept configured for offline reading
/// instead of reset to the default (ported from prime `_checkPathValidation`:
/// SAF storage unavailable keeps the configured `android://` path).
bool shouldKeepConfiguredPath(String path) => isSafPath(path);
