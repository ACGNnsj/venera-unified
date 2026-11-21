import 'dart:async';

import 'package:venera_unified/foundation/event_subscription.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:app_links/app_links.dart';
import 'package:venera_unified/routing/app_link_uri.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/features/comic_details/comic_details.dart';
import 'package:venera_unified/features/search/search.dart';
import 'package:venera_unified/routing/pending_app_links.dart';

EventSubscription<Uri> createAppLinkSubscription() => EventSubscription(
  events: AppLinks().uriLinkStream,
  handle: (uri, isActive) async {
    await handleAppLink(uri, isActive: isActive);
  },
  onError: (error, stack) => Log.error('App links', error, stack),
);

/// Cold-start / unlock readiness gates (ported from prime `handleLinks`).
///
/// The `app_links` stream also delivers the initial Android intent, so links
/// are queued in [_pending] until sources, navigation, navigator mount and
/// the auth-page unlock all report ready, then drained in order.
Future<void> _sourcesReady = Future.value();
bool _sourcesInitialized = false;
bool _navigationReady = false;
bool _navigatorMounted = false;
bool _unlocked = true;
final _pending = PendingAppLinks((uri) async {
  await handleAppLink(uri);
}, (error, stack) => Log.error('App links', error, stack));

void setAppLinkNavigationReady(bool ready) {
  _navigationReady = ready;
  _updateReadiness();
}

void setAppLinkNavigatorMounted(bool mounted) {
  _navigatorMounted = mounted;
  _updateReadiness();
}

/// Auth-page unlock gate (unified-specific; prime has no lock screen).
/// Call with true on successful auth; defaults to true when no lock is set.
void setAppLinkUnlocked(bool unlocked) {
  _unlocked = unlocked;
  _updateReadiness();
}

void _updateReadiness() => _pending.setReady(
  _navigationReady && _navigatorMounted && _sourcesInitialized && _unlocked,
);

/// Start the cold-start chain: subscribe once, queue intents, and consume the
/// initial URI delivered via `getInitialUri` (missed when the app was killed).
void handleLinks(Future<void> sourcesReady, {Future<void>? unlocked}) {
  _sourcesReady = sourcesReady;
  _sourcesInitialized = false;
  _unlocked = unlocked == null;
  _pending.setReady(false);
  if (unlocked != null) {
    unawaited(
      unlocked.then(
        (_) {
          setAppLinkUnlocked(true);
        },
        onError: (Object error, StackTrace stack) {
          Log.error('App links unlock', error, stack);
        },
      ),
    );
  }
  _subscription ??= AppLinks().uriLinkStream.listen(
    _pending.add,
    onError: (Object error, StackTrace stack) =>
        Log.error('App links', error, stack),
  );
  unawaited(_consumeInitialUri());
  unawaited(
    sourcesReady.then(
      (_) {
        _sourcesInitialized = true;
        _updateReadiness();
      },
      onError: (Object error, StackTrace stack) {
        Log.error('App links source initialization', error, stack);
      },
    ),
  );
}

StreamSubscription<Uri>? _subscription;

Future<void> _consumeInitialUri() async {
  try {
    // Installed app_links 7.2.2 names it getInitialLink (prime's plugin
    // revision called it getInitialUri); the pending queue covers the rest.
    final uri = await AppLinks().getInitialLink();
    if (uri != null) _pending.add(uri);
  } catch (error, stack) {
    Log.error('App links initial URI', error, stack);
  }
}

Future<bool> handleAppLink(Uri uri, {bool Function()? isActive}) async {
  if (isActive?.call() == false || !await _waitForLinkSources()) return false;
  if (isActive?.call() == false) return false;
  if (uri.scheme == appLinkScheme) return _handleAppLinkScheme(uri, isActive);
  final comic = _matchWebComic(uri);
  return comic != null && await _openWebComic(comic, isActive);
}

Future<bool> _waitForLinkSources() async {
  try {
    await _sourcesReady;
    return true;
  } catch (error, stack) {
    Log.error('App links source initialization', error, stack);
    return false;
  }
}

({ComicSource source, String id, int? page})? _matchWebComic(Uri uri) {
  if ((uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  final target = comicLinkTarget(uri);
  for (final source in ComicSource.all()) {
    final handler = source.linkHandler;
    if (handler == null ||
        !handler.domains.any(
          (domain) => domain.toLowerCase() == uri.host.toLowerCase(),
        )) {
      continue;
    }
    try {
      final id = handler.linkToId(target.uri.toString());
      if (id != null && id.trim().isNotEmpty) {
        return (source: source, id: id, page: target.page);
      }
    } catch (error, stack) {
      Log.error('App links (${source.key})', error, stack);
    }
  }
  return null;
}

Future<bool> _openWebComic(
  ({ComicSource source, String id, int? page}) comic,
  bool Function()? isActive,
) async {
  if (appNavigation.mainNavigatorKey == null) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  if (isActive?.call() == false) return false;
  // Open above the visible reader or settings route, not behind it.
  (appNavigation.rootNavigatorKey.currentState?.canPop() == true
          ? appNavigation.rootNavigatorKey.currentContext
          : appNavigation.mainNavigatorKey?.currentContext)
      ?.to(
        () => ComicPage(
          id: comic.id,
          sourceKey: comic.source.key,
          initialPage: comic.page,
        ),
      );
  return true;
}

/// Synchronous match for WebView navigation delegates. Opens a matched link
/// after startup without calling the extension handler a second time.
bool tryHandleComicLink(Uri uri) {
  final comic = _matchWebComic(uri);
  if (comic == null) return false;
  unawaited(
    _waitForLinkSources().then<void>((ready) async {
      if (ready && ComicSource.all().contains(comic.source)) {
        await _openWebComic(comic, null);
      }
    }),
  );
  return true;
}

/// Custom `venera-unified://` branch. Returns true only when consumed.
///
/// A link whose source is not installed degrades to an aggregated search
/// on the link title (when present), mirroring venera upstream. No toast is
/// shown for the missing source: translations are frozen, so there is no
/// localized string to show.
Future<bool> _handleAppLinkScheme(Uri uri, bool Function()? isActive) async {
  if (uri.scheme != appLinkScheme) return false;
  final comic = parseComicFromUri(uri);
  if (comic == null) return false;
  if (appNavigation.mainNavigatorKey == null) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  if (isActive?.call() == false) return false;
  final source = ComicSource.find(comic.sourceKey);
  if (source != null) {
    (appNavigation.rootNavigatorKey.currentState?.canPop() == true
            ? appNavigation.rootNavigatorKey.currentContext
            : appNavigation.mainNavigatorKey?.currentContext)
        ?.to(() {
          return ComicPage(id: comic.id, sourceKey: comic.sourceKey);
        });
  } else if (comic.title != null && comic.title!.isNotEmpty) {
    appNavigation.mainNavigatorKey?.currentContext?.to(() {
      return AggregatedSearchPage(keyword: comic.title!);
    });
  }
  return true;
}
