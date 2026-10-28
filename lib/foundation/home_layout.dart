import 'package:flutter/material.dart';
import 'package:venera_unified/foundation/appdata.dart';

/// Metadata for one reorderable home page section.
///
/// Adding a section only requires appending a [HomeSectionMeta] to
/// [kHomeSections]: [normalizeHomeLayout] migrates stored layouts forward by
/// appending unknown-to-the-config sections as visible, and [saveHomeLayout]
/// preserves ids it does not know so a layout synced from a newer version
/// survives a round-trip through an older one.
class HomeSectionMeta {
  const HomeSectionMeta({
    required this.id,
    required this.titleKey,
    required this.icon,
  });

  /// Stable id persisted in the `homeSections` setting.
  final String id;

  /// Translation key shown in the layout settings page. Reuses the section
  /// widget's own title so existing translations apply.
  final String titleKey;

  final IconData icon;
}

/// Home sections in default display order. Must stay in sync with the home
/// page's section switch.
const List<HomeSectionMeta> kHomeSections = [
  HomeSectionMeta(id: 'search', titleKey: 'Search', icon: Icons.search),
  HomeSectionMeta(id: 'sync', titleKey: 'Sync Data', icon: Icons.sync),
  HomeSectionMeta(id: 'random', titleKey: 'Random Comic', icon: Icons.shuffle),
  HomeSectionMeta(id: 'history', titleKey: 'History', icon: Icons.history),
  HomeSectionMeta(
    id: 'readLater',
    titleKey: 'Read later',
    icon: Icons.watch_later_outlined,
  ),
  HomeSectionMeta(id: 'local', titleKey: 'Local', icon: Icons.folder_outlined),
  HomeSectionMeta(
    id: 'followUpdates',
    titleKey: 'Follow Updates',
    icon: Icons.notifications_outlined,
  ),
  HomeSectionMeta(
    id: 'comicSource',
    titleKey: 'Comic Source',
    icon: Icons.cloud_outlined,
  ),
  HomeSectionMeta(
    id: 'imageFavorites',
    titleKey: 'Image Favorites',
    icon: Icons.image_outlined,
  ),
];

final Map<String, HomeSectionMeta> homeSectionMetaById = {
  for (var meta in kHomeSections) meta.id: meta,
};

/// One persisted home section entry: stable [id] plus visibility.
class HomeSectionConfig {
  const HomeSectionConfig({required this.id, required this.visible});

  final String id;
  final bool visible;

  HomeSectionConfig copyWith({String? id, bool? visible}) =>
      HomeSectionConfig(id: id ?? this.id, visible: visible ?? this.visible);
}

/// Default layout: every known section, visible, in [kHomeSections] order.
List<HomeSectionConfig> defaultHomeLayout() => [
  for (var meta in kHomeSections) HomeSectionConfig(id: meta.id, visible: true),
];

/// Normalizes the stored `homeSections` setting into a renderable layout:
/// drops unknown ids and duplicates (first occurrence wins), keeps the stored
/// order and visibility, and appends known sections missing from the config
/// as visible so newly added sections appear without a migration.
List<HomeSectionConfig> normalizeHomeLayout() {
  var stored = appdata.settings['homeSections'];
  if (stored is! List) return defaultHomeLayout();
  var layout = <HomeSectionConfig>[];
  var seen = <String>{};
  for (var item in stored) {
    if (item is! Map) continue;
    var id = item['id'];
    if (id is! String || !homeSectionMetaById.containsKey(id)) continue;
    if (!seen.add(id)) continue;
    layout.add(HomeSectionConfig(id: id, visible: item['visible'] != false));
  }
  for (var meta in kHomeSections) {
    if (seen.add(meta.id)) {
      layout.add(HomeSectionConfig(id: meta.id, visible: true));
    }
  }
  return layout;
}

/// Persists [layout], preserving stored entries with unknown ids so a layout
/// synced from a newer version is not truncated by saving on this one.
void saveHomeLayout(List<HomeSectionConfig> layout) {
  var records = <Map<String, Object?>>[
    for (var config in layout) {'id': config.id, 'visible': config.visible},
  ];
  var stored = appdata.settings['homeSections'];
  if (stored is List) {
    for (var item in stored) {
      if (item is! Map) continue;
      var id = item['id'];
      if (id is! String || homeSectionMetaById.containsKey(id)) continue;
      if (records.any((record) => record['id'] == id)) continue;
      records.add({'id': id, 'visible': item['visible'] != false});
    }
  }
  appdata.settings['homeSections'] = records;
  appdata.saveData();
}
