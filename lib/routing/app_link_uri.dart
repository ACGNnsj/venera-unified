/// Custom deep-link scheme owned by Venera Unified.
///
/// Deliberately distinct from the `venera://` scheme used by sibling forks,
/// so installs never fight over the same links. Only this scheme is
/// recognized; `venera://` links are left for the apps that own them.
const appLinkScheme = 'venera-unified';

/// Matches the first app link inside free text (clipboard, shares).
final appLinkRegex = RegExp('$appLinkScheme://\\S+');

/// Try to parse a `venera-unified://` link from [text].
/// Returns the parsed Uri if found, otherwise null.
Uri? parseAppLink(String text) {
  final match = appLinkRegex.firstMatch(text);
  if (match == null) return null;
  return Uri.tryParse(match.group(0)!);
}

/// Parse comic id, sourceKey, and optional title from an app-link URI.
/// Returns null if the URI is not a valid comic link.
///
/// Two shapes (mirrored from venera upstream):
/// - `venera-unified://comic?id=<id>&source=<key>&title=<optional>`
/// - `venera-unified://c/<sourceKey>/<id>`
({String id, String sourceKey, String? title})? parseComicFromUri(Uri uri) {
  if (uri.scheme != appLinkScheme) return null;
  if (uri.host == 'c' && uri.pathSegments.length >= 2) {
    return (
      id: uri.pathSegments[1],
      sourceKey: uri.pathSegments[0],
      title: null,
    );
  } else if (uri.host == 'comic') {
    final id = uri.queryParameters['id'];
    final sourceKey = uri.queryParameters['source'];
    if (id == null || sourceKey == null) return null;
    return (id: id, sourceKey: sourceKey, title: uri.queryParameters['title']);
  }
  return null;
}

/// Build the canonical shareable link for a comic.
///
/// Round-trips with [parseComicFromUri]: parsing the result returns the
/// same id/sourceKey/title.
Uri buildComicUri({
  required String id,
  required String sourceKey,
  String? title,
}) {
  return Uri(
    scheme: appLinkScheme,
    host: 'comic',
    queryParameters: {
      'id': id,
      'source': sourceKey,
      if (title != null && title.isNotEmpty) 'title': title,
    },
  );
}
