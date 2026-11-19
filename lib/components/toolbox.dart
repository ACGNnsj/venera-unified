import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/routing/app_links.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/routing/webview.dart';

const _searchByImageBotUrl = 'https://soutubot.moe/';
const _sauceNaoUrl = 'https://saucenao.com/';

Future<void> showToolbox(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      // Keep an explicit full-screen dismiss target behind the sheet. This
      // makes taps in the upper blank area reliable even when the platform
      // modal barrier is affected by immersive system insets.
      return SizedBox.expand(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(sheetContext).pop(),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: MediaQuery.sizeOf(sheetContext).height * 0.5,
                child: Material(
                  color: Theme.of(sheetContext).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: const _ToolboxSheet(),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ToolboxSheet extends StatelessWidget {
  const _ToolboxSheet();

  @override
  Widget build(BuildContext context) {
    void closeThen(VoidCallback action) {
      Navigator.of(context).pop();
      Future.microtask(action);
    }

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(24, 8, 16, 4),
              title: Text(
                'Tools'.tl,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.image_search_outlined),
              title: Text('Image search [Search by Image Bot]'.tl),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => closeThen(
                () => _openToolWebsite(context, _searchByImageBotUrl),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.image_search),
              title: Text('Image search [SauceNAO]'.tl),
              trailing: const Icon(Icons.open_in_new),
              onTap: () =>
                  closeThen(() => _openToolWebsite(context, _sauceNaoUrl)),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openToolWebsite(BuildContext context, String url) async {
  if (App.isMobile || App.isMacOS) {
    appNavigation.mainNavigatorKey?.currentContext?.to(
      () => AppWebview(
        initialUrl: url,
        onNavigation: (navigationUrl, _) {
          final uri = Uri.tryParse(navigationUrl);
          if (uri == null) return false;
          return tryHandleComicLink(uri);
        },
      ),
    );
    return;
  }

  if (!await DesktopWebview.isAvailable()) {
    if (context.mounted) {
      context.showMessage(message: 'Webview is not available'.tl);
    }
    return;
  }
  final webview = DesktopWebview(
    initialUrl: url,
    onNavigation: (navigationUrl, webview) {
      final uri = Uri.tryParse(navigationUrl);
      if (uri != null && tryHandleComicLink(uri)) {
        unawaited(webview.close());
      }
    },
  );
  webview.open();
}
