import 'package:venera_unified/foundation/event_subscription.dart';
import 'package:venera_unified/foundation/log.dart';
import 'package:app_links/app_links.dart';
import 'package:venera_unified/routing/app_link_uri.dart';
import 'package:venera_unified/routing/app_navigation.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/features/comic_details/comic_details.dart';
import 'package:venera_unified/features/search/search.dart';

EventSubscription<Uri> createAppLinkSubscription() => EventSubscription(
  events: AppLinks().uriLinkStream,
  handle: (uri, isActive) async {
    await handleAppLink(uri, isActive: isActive);
  },
  onError: (error, stack) => Log.error('App links', error, stack),
);

Future<bool> handleAppLink(Uri uri, {bool Function()? isActive}) async {
  if (isActive?.call() == false) return false;
  if (await _handleAppLinkScheme(uri, isActive)) return true;
  for (var source in ComicSource.all()) {
    if (source.linkHandler != null) {
      if (source.linkHandler!.domains.contains(uri.host)) {
        var id = source.linkHandler!.linkToId(uri.toString());
        if (id != null) {
          if (appNavigation.mainNavigatorKey == null) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          if (isActive?.call() == false) return false;
          appNavigation.mainNavigatorKey?.currentContext?.to(() {
            return ComicPage(id: id, sourceKey: source.key);
          });
          return true;
        }
        return false;
      }
    }
  }
  return false;
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
    appNavigation.mainNavigatorKey?.currentContext?.to(() {
      return ComicPage(id: comic.id, sourceKey: comic.sourceKey);
    });
  } else if (comic.title != null && comic.title!.isNotEmpty) {
    appNavigation.mainNavigatorKey?.currentContext?.to(() {
      return AggregatedSearchPage(keyword: comic.title!);
    });
  }
  return true;
}
