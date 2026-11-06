import 'package:flutter/material.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/translations.dart';

import 'search_shortcut.dart';
import 'search_shortcut_manager.dart';

/// Pin toggle for a category page. Stored as a [SearchShortcut] of kind
/// category; the optional page param is encoded in the namespace as
/// `key@param` and restored on jump.
class CategoryShortcutPinButton extends StatelessWidget {
  const CategoryShortcutPinButton({
    required this.sourceKey,
    required this.categoryKey,
    required this.category,
    this.param,
    super.key,
  });

  final String sourceKey;
  final String categoryKey;
  final String category;
  final String? param;

  @override
  Widget build(BuildContext context) {
    final shortcut = SearchShortcut(
      kind: SearchShortcutKind.category,
      sourceKey: sourceKey,
      namespace: param == null ? categoryKey : '$categoryKey@$param',
      value: category,
    );
    return ListenableBuilder(
      listenable: SearchShortcutManager.instance,
      builder: (context, _) {
        final saved = SearchShortcutManager.instance.contains(shortcut);
        return IconButton(
          icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add_outlined),
          tooltip: (saved
                  ? 'Remove category shortcut'
                  : 'Save category shortcut')
              .tl,
          onPressed: () async {
            try {
              if (saved) {
                await SearchShortcutManager.instance.remove(shortcut);
              } else {
                await SearchShortcutManager.instance.add(shortcut);
              }
              if (context.mounted) {
                context.showMessage(
                  message: (saved
                          ? 'Search shortcut removed'
                          : 'Search shortcut saved')
                      .tl,
                );
              }
            } catch (e) {
              if (context.mounted) context.showMessage(message: e.toString());
            }
          },
        );
      },
    );
  }
}
