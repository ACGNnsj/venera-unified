import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera_unified/components/message.dart';
import 'package:venera_unified/features/comic_details/comic_details.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:venera_unified/foundation/translations.dart';
import 'package:venera_unified/routing/app_link_uri.dart';
import 'package:venera_unified/routing/app_links.dart';
import 'package:venera_unified/routing/app_navigation.dart';

/// Offers to open app links found in the clipboard when the app resumes.
///
/// Attach from the interactive boundary (single instance):
/// ```dart
/// final observer = ClipboardAppLinkObserver();
/// WidgetsBinding.instance.addObserver(observer);
/// ```
/// The boundary owns disposal via [detach]. A mobile-gated one-shot
/// [checkClipboardForAppLink] at startup is also the boundary's call.
class ClipboardAppLinkObserver with WidgetsBindingObserver {
  const ClipboardAppLinkObserver();

  void attach() => WidgetsBinding.instance.addObserver(this);

  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(checkClipboardForAppLink());
    }
  }
}

/// Check the clipboard once for an app link and confirm before opening.
///
/// Only links whose source is installed prompt; each distinct link prompts
/// at most once (deduped by `implicitData['lastHandledClipboard']`).
/// No prompt while already viewing the linked comic.
Future<void> checkClipboardForAppLink() async {
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;

    final uri = parseAppLink(text);
    if (uri == null) return;

    final lastHandled = appdata.implicitData['lastHandledClipboard'] as String?;
    if (uri.toString() == lastHandled) return;
    appdata.implicitData['lastHandledClipboard'] = uri.toString();
    await appdata.writeImplicitData();

    final comic = parseComicFromUri(uri);
    if (comic == null) return;

    if (_isViewingComic(comic.id, comic.sourceKey)) return;

    final source = ComicSource.find(comic.sourceKey);
    if (source == null) return;

    final context = appNavigation.rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    // Extract title from the text line before the URL.
    final uriMatch = appLinkRegex.firstMatch(text);
    final beforeUrl = text.substring(0, uriMatch?.start ?? 0).trim();
    final displayName = beforeUrl.isNotEmpty ? beforeUrl : comic.id;

    showConfirmDialog(
      context: context,
      title: 'Open comic'.tl,
      content: '${'Open comic'.tl}: $displayName',
      onConfirm: () => unawaited(handleAppLink(uri)),
    );
  } catch (e) {
    Log.warning('App links', 'Failed to handle clipboard link: $e');
  }
}

bool _isViewingComic(String id, String sourceKey) {
  final navContext = appNavigation.mainNavigatorKey?.currentContext;
  if (navContext == null) return false;
  ComicPage? found;
  void visitor(Element el) {
    if (found != null) return;
    if (el.widget is ComicPage) {
      found = el.widget as ComicPage;
      return;
    }
    el.visitChildren(visitor);
  }

  (navContext as Element).visitChildren(visitor);
  return found?.id == id && found?.sourceKey == sourceKey;
}
