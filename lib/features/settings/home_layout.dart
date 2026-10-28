import 'package:flutter/material.dart';
import 'package:venera_unified/components/appbar.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/home_layout.dart';
import 'package:venera_unified/foundation/translations.dart';

/// Reorders and hides the home page sections.
///
/// Shares its data model — [normalizeHomeLayout] / [saveHomeLayout] — with
/// the home page, which re-reads the same `homeSections` setting.
class HomeLayoutSettings extends StatefulWidget {
  const HomeLayoutSettings({super.key});

  @override
  State<HomeLayoutSettings> createState() => _HomeLayoutSettingsState();
}

class _HomeLayoutSettingsState extends State<HomeLayoutSettings> {
  late List<HomeSectionConfig> layout = normalizeHomeLayout();

  void _persist() => saveHomeLayout(layout);

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      layout.insert(newIndex, layout.removeAt(oldIndex));
    });
    _persist();
  }

  void _toggle(String id, bool visible) {
    setState(() {
      layout = [
        for (var config in layout)
          if (config.id == id) config.copyWith(visible: visible) else config,
      ];
    });
    _persist();
  }

  void _reset() {
    setState(() => layout = defaultHomeLayout());
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Home Page Layout".tl),
        actions: [
          Tooltip(
            message: "Reset".tl,
            child: IconButton(
              icon: const Icon(Icons.restart_alt),
              onPressed: _reset,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              "Long press and drag to reorder.".tl,
              style: TextStyle(
                fontSize: 12,
                color: context.colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: layout.length,
              onReorderItem: _onReorder,
              itemBuilder: (context, index) {
                var config = layout[index];
                var meta = homeSectionMetaById[config.id]!;
                return _SectionTile(
                  key: ValueKey(config.id),
                  meta: meta,
                  visible: config.visible,
                  index: index,
                  onToggle: (visible) => _toggle(config.id, visible),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    super.key,
    required this.meta,
    required this.visible,
    required this.index,
    required this.onToggle,
  });

  final HomeSectionMeta meta;
  final bool visible;
  final int index;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(
          color: context.colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Opacity(
        opacity: visible ? 1 : 0.45,
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 8, 14),
                child: Icon(
                  Icons.drag_indicator,
                  size: 22,
                  color: context.colorScheme.outline,
                ),
              ),
            ),
            Icon(meta.icon, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                meta.titleKey.tl,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            Switch(value: visible, onChanged: onToggle),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
