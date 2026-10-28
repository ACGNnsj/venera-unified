import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_unified/components/input_dialog.dart';
import 'package:venera_unified/components/menu.dart';
import 'package:venera_unified/features/comic_collection/comic_collection_store.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/foundation/translations.dart';

/// Long-press / right-click actions for one tab of a collection detail page.
///
/// For a collection each tab IS a member comic, so the tab is where renaming
/// and reordering it belongs. Every mutation is awaited and funnels through
/// [onEdited] so the caller can rebuild the collection source and reload the
/// detail; failures surface as a toast instead of failing silently.
Future<void> showCollectionTabMenu({
  required BuildContext context,
  required MenuRouteController menus,
  required Offset location,
  required String collectionId,
  required int tabIndex,
  required bool Function() isValid,
  required FutureOr<void> Function() onEdited,
}) async {
  final collection = ComicCollectionStore.find(collectionId);
  final members = collection?.members ?? const <CollectionMember>[];
  final member = tabIndex < members.length ? members[tabIndex] : null;
  if (collection == null || member == null) return;
  final count = members.length;

  Future<void> apply(void Function() mutation) async {
    try {
      mutation();
    } catch (error, stack) {
      Log.error('Collection', 'Tab edit failed: $error', stack);
      if (context.mounted) {
        context.showMessage(message: 'Failed to update collection'.tl);
      }
      return;
    }
    await onEdited();
  }

  menus.show(context, location, [
    MenuEntry(
      icon: Icons.label_outline,
      text: 'Display name'.tl,
      onClick: () {
        showInputDialog(
          context: context,
          title: 'Display name'.tl,
          initialValue: member.displayName,
          hintText: "Leave empty to use the comic's title".tl,
          onConfirm: (value) {
            unawaited(
              apply(() {
                member.displayName = value;
                ComicCollectionStore.update(
                  collectionId,
                  members: collection.members,
                );
              }),
            );
            return null;
          },
        );
      },
    ),
    if (tabIndex > 0)
      MenuEntry(
        icon: Icons.arrow_back,
        text: 'Move left'.tl,
        onClick: () {
          unawaited(
            apply(
              () => ComicCollectionStore.reorderMember(
                collectionId,
                tabIndex,
                tabIndex - 1,
              ),
            ),
          );
        },
      ),
    if (tabIndex < count - 1)
      MenuEntry(
        icon: Icons.arrow_forward,
        text: 'Move right'.tl,
        onClick: () {
          unawaited(
            apply(
              () => ComicCollectionStore.reorderMember(
                collectionId,
                tabIndex,
                tabIndex + 1,
              ),
            ),
          );
        },
      ),
    MenuEntry(
      icon: Icons.remove_circle_outline,
      text: 'Remove from collection'.tl,
      color: context.colorScheme.error,
      onClick: () {
        unawaited(
          apply(
            () => ComicCollectionStore.removeMember(
              collectionId,
              member.sourceKey,
              member.comicId,
            ),
          ),
        );
      },
    ),
  ], isValid: isValid);
}
