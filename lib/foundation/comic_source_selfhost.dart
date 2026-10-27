/// Self-hosted source repository constants (B4).
///
/// The default catalog lives in https://github.com/ACGNnsj/venera-unified-configs
/// and every URL pins to a `sources-*` tag (jsDelivr), never a floating branch.
/// Entry file names match `sources/*.js`; versions must equal the `version`
/// field inside each script or update checks will false-positive.
library;

/// Tag this app release pins to. Bumping it requires publishing a new tag
/// in the configs repo and updating these constants (see PUBLISHING.md).
const String kSelfhostTag = 'sources-v1';

const String _selfhostBase =
    'https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@$kSelfhostTag';

/// Default repository catalog (stable sources only).
const String kSelfhostCatalogUrl = '$_selfhostBase/catalog/index.json';

/// Optional repository catalog (new/experimental sources, manual add).
const String kSelfhostOptionalCatalogUrl =
    '$_selfhostBase/catalog/optional.json';

/// Stable repository id. Fixed (not a UUID) so migration origins stay valid
/// across reinstalls and tag bumps only change URLs, never ids.
const String kSelfhostRepositoryId = 'venera-selfhost';

/// Display name stored in the repository record (data, not a UI string).
const String kSelfhostRepositoryName = 'Venera 自托管源库';

/// Keys shipped in the default catalog. Migration only links these;
/// optional-catalog keys stay manual so a missing entry never becomes
/// a `missingSource` failure against the default catalog.
const List<String> kSelfhostDefaultKeys = <String>[
  'copy_manga',
  'baozi',
  'jm',
  'hitomi',
];

/// Script file backing a catalog key. All default keys map to `<key>.js`;
/// the only exception repo-wide is `ManHuaGui` -> `manhuagui.js` (optional).
String selfhostFileNameForKey(String key) =>
    key == 'ManHuaGui' ? 'manhuagui.js' : '$key.js';

/// Pinned script URL for a catalog key (matches the catalog entry `url`).
String selfhostEntryUrlForKey(String key) =>
    '$_selfhostBase/sources/${selfhostFileNameForKey(key)}';
