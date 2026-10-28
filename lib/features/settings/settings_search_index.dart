import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/launcher_icon.dart';
import 'package:venera_unified/foundation/translations.dart';

/// Searchable index of unified settings (A12, mirrors VeneraX #10 behaviour).
///
/// IMPORTANT: this list mirrors the settings rendered by unified's category
/// pages (see [settingsSearchCategories] for the page order). When you add,
/// rename, or remove a setting on those pages, update the matching entry here
/// so it stays searchable.
///
/// Titles reuse the exact English source strings the pages pass to `.tl`, so a
/// single entry localizes automatically in every locale. Tapping a result opens
/// that category page.
const settingsSearchCategories = <String>[
  'Explore',
  'Reading',
  'Reading statistics',
  'Appearance',
  'Local Favorites',
  'APP',
  'Network',
  'About',
  'Debug',
];

class SettingsSearchEntry {
  const SettingsSearchEntry(
    this.title,
    this.category, {
    this.keywords = const [],
    this.visible,
  });

  /// English source string, identical to the one the page passes to `.tl`.
  final String title;

  /// Index into [settingsSearchCategories].
  final int category;

  /// Extra English match terms / synonyms beyond the localized title.
  final List<String> keywords;

  /// Optional availability guard, mirroring the page's own conditional so a
  /// result never points at a setting the current platform doesn't show.
  final bool Function()? visible;
}

/// The full index. `visible` guards are evaluated lazily at match time.
final settingsSearchIndex = <SettingsSearchEntry>[
  // --- 0: Explore (explore_settings.dart) ---
  const SettingsSearchEntry('Display mode of comic tile', 0),
  const SettingsSearchEntry('Size of comic tile', 0),
  const SettingsSearchEntry('Explore Pages', 0),
  const SettingsSearchEntry('Category Pages', 0),
  const SettingsSearchEntry('Network Favorite Pages', 0),
  const SettingsSearchEntry('Search Sources', 0, keywords: ['search']),
  const SettingsSearchEntry('Show favorite status on comic tile', 0),
  const SettingsSearchEntry('Show history on comic tile', 0),
  const SettingsSearchEntry(
    'Show detailed reading progress',
    0,
    keywords: ['chapter', 'progress'],
  ),
  const SettingsSearchEntry(
    'Show update status on comic tile',
    0,
    keywords: ['update'],
  ),
  const SettingsSearchEntry(
    'Reverse default chapter order',
    0,
    keywords: ['chapter'],
  ),
  const SettingsSearchEntry(
    'Keyword blocking',
    0,
    keywords: ['block', 'filter'],
  ),
  const SettingsSearchEntry(
    'Comment keyword blocking',
    0,
    keywords: ['block', 'filter', 'comment'],
  ),
  const SettingsSearchEntry('Default Search Target', 0, keywords: ['search']),
  const SettingsSearchEntry('Auto Language Filters', 0, keywords: ['language']),
  const SettingsSearchEntry('Initial Page', 0),
  const SettingsSearchEntry('Display mode of comic list', 0),

  // --- 1: Reading (reader.dart, reader_mode.dart, reader/brightness.dart) ---
  const SettingsSearchEntry(
    'Enable device specific settings',
    1,
    keywords: ['device'],
  ),
  const SettingsSearchEntry(
    'Choose reading mode automatically',
    1,
    keywords: ['auto', 'mode'],
  ),
  const SettingsSearchEntry('Paged comics', 1, keywords: ['mode']),
  const SettingsSearchEntry('Long-strip comics', 1, keywords: ['mode']),
  const SettingsSearchEntry('Default reading mode', 1, keywords: ['mode']),
  const SettingsSearchEntry(
    'When layout is unknown',
    1,
    keywords: ['mode', 'auto'],
  ),
  const SettingsSearchEntry(
    'Tap to turn Pages',
    1,
    keywords: ['tap', 'gesture'],
  ),
  const SettingsSearchEntry(
    'Reverse tap to turn Pages',
    1,
    keywords: ['tap', 'gesture'],
  ),
  const SettingsSearchEntry('Page animation', 1),
  const SettingsSearchEntry(
    'Night dimming',
    1,
    keywords: ['brightness', 'dark'],
  ),
  const SettingsSearchEntry('Reader brightness', 1, keywords: ['brightness']),
  const SettingsSearchEntry(
    'E-Ink display refresh',
    1,
    keywords: ['e-ink', 'ghosting'],
  ),
  const SettingsSearchEntry('Refresh flash duration', 1, keywords: ['e-ink']),
  const SettingsSearchEntry('Refresh interval', 1, keywords: ['e-ink']),
  const SettingsSearchEntry('Refresh flash style', 1, keywords: ['e-ink']),
  const SettingsSearchEntry(
    'Flash white screen on page turn',
    1,
    keywords: ['e-ink', 'ghosting'],
  ),
  const SettingsSearchEntry(
    'Auto page turning interval (gallery)',
    1,
    keywords: ['auto'],
  ),
  const SettingsSearchEntry(
    'Automatic scrolling (continuous and waterfall)',
    1,
    keywords: ['auto', 'scroll'],
  ),
  const SettingsSearchEntry(
    'Automatic scroll speed',
    1,
    keywords: ['auto', 'scroll'],
  ),
  const SettingsSearchEntry(
    'Scroll steps per second',
    1,
    keywords: ['auto', 'scroll'],
  ),
  const SettingsSearchEntry(
    'Distance per scroll step',
    1,
    keywords: ['auto', 'scroll'],
  ),
  const SettingsSearchEntry(
    'Continue automatically to the next chapter',
    1,
    keywords: ['auto'],
  ),
  const SettingsSearchEntry(
    'Skip unavailable images during automatic reading',
    1,
    keywords: ['auto'],
  ),
  const SettingsSearchEntry(
    'Wait for loading images (seconds)',
    1,
    keywords: ['auto'],
  ),
  SettingsSearchEntry(
    'Keep screen on during automatic reading',
    1,
    keywords: const ['auto', 'screen'],
    visible: () => App.isMobile,
  ),
  const SettingsSearchEntry(
    'The number of pic in screen for landscape (Only Gallery Mode)',
    1,
    keywords: ['gallery'],
  ),
  const SettingsSearchEntry(
    'The number of pic in screen for portrait (Only Gallery Mode)',
    1,
    keywords: ['gallery'],
  ),
  const SettingsSearchEntry(
    'Show single image on first page',
    1,
    keywords: ['gallery'],
  ),
  const SettingsSearchEntry('Mouse scroll speed', 1, keywords: ['scroll']),
  const SettingsSearchEntry(
    'Double tap to zoom',
    1,
    keywords: ['gesture', 'zoom'],
  ),
  const SettingsSearchEntry(
    'Long press action',
    1,
    keywords: ['gesture', 'zoom'],
  ),
  const SettingsSearchEntry(
    'Long press zoom position',
    1,
    keywords: ['zoom', 'gesture'],
  ),
  const SettingsSearchEntry('Limit image width', 1),
  const SettingsSearchEntry(
    'Shrink strip comics (margin per side)',
    1,
    keywords: ['margin'],
  ),
  const SettingsSearchEntry('Page margin', 1, keywords: ['margin']),
  const SettingsSearchEntry('Page margin size', 1, keywords: ['margin']),
  const SettingsSearchEntry('Split dual pages', 1),
  const SettingsSearchEntry('Swap split dual page order', 1),
  SettingsSearchEntry(
    'Turn page by volume keys',
    1,
    keywords: const ['volume', 'gesture'],
    visible: () => App.isAndroid,
  ),
  const SettingsSearchEntry('Display time & battery info in reader', 1),
  const SettingsSearchEntry('Show system status bar', 1),
  const SettingsSearchEntry('Quick collect image', 1),
  const SettingsSearchEntry('Custom Image Processing', 1, keywords: ['script']),
  SettingsSearchEntry(
    'Image Upscaling',
    1,
    keywords: const ['upscale'],
    visible: () => App.isAndroid,
  ),
  const SettingsSearchEntry(
    'Number of images preloaded',
    1,
    keywords: ['preload'],
  ),
  const SettingsSearchEntry('Show Page Number', 1),
  const SettingsSearchEntry('Show image pixel dimensions', 1),
  const SettingsSearchEntry('Show Chapter Comments', 1, keywords: ['comment']),
  const SettingsSearchEntry(
    'Show Comments at Chapter End',
    1,
    keywords: ['comment'],
  ),

  // --- 2: Reading statistics (history/reading_stats_page.dart) ---
  const SettingsSearchEntry(
    'Reading time by comic',
    2,
    keywords: ['stats', 'time', 'history'],
  ),

  // --- 3: Appearance (appearance.dart) ---
  const SettingsSearchEntry('Theme Mode', 3, keywords: ['dark', 'light']),
  const SettingsSearchEntry('Theme Color', 3, keywords: ['accent', 'color']),
  const SettingsSearchEntry(
    'Comment Font Size',
    3,
    keywords: ['font', 'comment'],
  ),
  const SettingsSearchEntry('Night Mode', 3, keywords: ['dark']),
  const SettingsSearchEntry(
    'Convert traditional to simplified',
    3,
    keywords: ['simplified', 'traditional', 'chinese'],
  ),
  const SettingsSearchEntry(
    'Home Page Layout',
    3,
    keywords: ['home', 'layout', 'reorder', 'sections'],
  ),

  // --- 4: Local Favorites (local_favorites.dart) ---
  const SettingsSearchEntry('Show local favorites before network favorites', 4),
  const SettingsSearchEntry('Auto close favorite panel after operation', 4),
  const SettingsSearchEntry('Add new favorite to', 4),
  const SettingsSearchEntry('Move favorite after reading', 4),
  const SettingsSearchEntry('Quick Favorite', 4),
  const SettingsSearchEntry('Delete all unavailable local favorite items', 4),
  const SettingsSearchEntry('Click favorite', 4),

  // --- 5: APP (app.dart, local_storage_settings.dart, app_controls.dart,
  // ---     window_hotkey_setting.dart) ---
  const SettingsSearchEntry(
    'Storage Path for local comics',
    5,
    keywords: ['path'],
  ),
  const SettingsSearchEntry('Set New Storage Path', 5, keywords: ['path']),
  const SettingsSearchEntry('Cache Size', 5, keywords: ['cache']),
  const SettingsSearchEntry('Clear Cache', 5, keywords: ['cache']),
  const SettingsSearchEntry('Cache Limit', 5, keywords: ['cache']),
  const SettingsSearchEntry('Keep unused cache', 5, keywords: ['cache']),
  const SettingsSearchEntry('Auto Clear History', 5, keywords: ['history']),
  const SettingsSearchEntry(
    'Export App Data',
    5,
    keywords: ['backup', 'export'],
  ),
  const SettingsSearchEntry(
    'Import App Data',
    5,
    keywords: ['restore', 'import'],
  ),
  const SettingsSearchEntry(
    'Data Sync',
    5,
    keywords: ['webdav', 'sync', 'cloud', 'backup'],
  ),
  const SettingsSearchEntry(
    'Comic Archive Backup',
    5,
    keywords: ['webdav', 'backup', 'cbz', 'sync'],
  ),
  const SettingsSearchEntry(
    'WebDAV Comic Library',
    5,
    keywords: ['webdav', 'library', 'remote', 'nas', 'cloud'],
  ),
  const SettingsSearchEntry('Language', 5, keywords: ['locale', 'language']),
  SettingsSearchEntry(
    'Authorization Required',
    5,
    keywords: const ['password', 'lock', 'biometric', 'fingerprint', 'privacy'],
    visible: () => !App.isLinux,
  ),
  SettingsSearchEntry(
    'Unlock method',
    5,
    keywords: const ['pin', 'password', 'pattern', 'lock'],
    visible: () => !App.isLinux,
  ),
  SettingsSearchEntry(
    'Global hide/restore shortcut',
    5,
    keywords: const ['hotkey', 'shortcut', 'window'],
    visible: () => App.isWindows,
  ),
  SettingsSearchEntry(
    'App Icon',
    5,
    keywords: const ['icon', 'launcher', 'logo'],
    visible: () => LauncherIconService.isSupported,
  ),

  // --- 6: Network (network.dart) ---
  const SettingsSearchEntry('Proxy', 6, keywords: ['vpn', 'socks', 'http']),
  const SettingsSearchEntry(
    'DNS Overrides',
    6,
    keywords: ['dns', 'hosts', 'sni'],
  ),
  const SettingsSearchEntry('Download Threads', 6, keywords: ['download']),

  // --- 7: About (about.dart) ---
  const SettingsSearchEntry(
    'Check for updates',
    7,
    keywords: ['update', 'version'],
  ),
  const SettingsSearchEntry(
    'Changelog',
    7,
    keywords: ['changelog', 'changes', 'version'],
  ),
  const SettingsSearchEntry(
    'Check for updates on startup',
    7,
    keywords: ['update'],
  ),
  const SettingsSearchEntry(
    'Github',
    7,
    keywords: ['github', 'repository', 'source'],
  ),
  const SettingsSearchEntry('Sponsors', 7, keywords: ['sponsor', 'donate']),

  // --- 8: Debug (debug.dart) ---
  const SettingsSearchEntry('Reload Configs', 8),
  const SettingsSearchEntry('Open Log', 8, keywords: ['log', 'logs']),
  const SettingsSearchEntry(
    'Ignore Certificate Errors',
    8,
    keywords: ['ssl', 'tls'],
  ),
  const SettingsSearchEntry(
    'JS Evaluator',
    8,
    keywords: ['javascript', 'js', 'eval'],
  ),
];

/// Returns the entries matching [query] (case-insensitive substring over the
/// localized title, the English source, the category name, and keywords).
///
/// Entries whose [SettingsSearchEntry.visible] guard returns false are skipped
/// unless [includeHidden] is true (used by tests to check matching logic
/// independently of the current platform).
List<SettingsSearchEntry> matchSettingsSearch(
  String query, {
  bool includeHidden = false,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final result = <SettingsSearchEntry>[];
  for (final e in settingsSearchIndex) {
    if (!includeHidden && e.visible != null && !e.visible!()) continue;
    if (_settingsEntryMatches(e, q)) result.add(e);
  }
  return result;
}

bool _settingsEntryMatches(SettingsSearchEntry e, String q) {
  if (e.title.toLowerCase().contains(q)) return true;
  if (e.title.tl.toLowerCase().contains(q)) return true;
  final catName = settingsSearchCategories[e.category];
  if (catName.toLowerCase().contains(q) ||
      catName.tl.toLowerCase().contains(q)) {
    return true;
  }
  for (final k in e.keywords) {
    if (k.toLowerCase().contains(q) || k.tl.toLowerCase().contains(q)) {
      return true;
    }
  }
  return false;
}
