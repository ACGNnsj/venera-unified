import 'dart:async';
import 'dart:collection';

/// Retains launch intents until startup, source init and unlock finish.
///
/// Ported from venera-prime `lib/utils/pending_app_links.dart`: the
/// `app_links` plugin also delivers the initial Android intent through the
/// same stream, so intents are queued and drained once all gates are ready.
/// The unlock gate is unified-specific (prime waits source + navigation;
/// unified additionally waits for the auth-page unlock).
class PendingAppLinks {
  PendingAppLinks(this.open, this.onError);

  final Future<void> Function(Uri) open;
  final void Function(Object, StackTrace) onError;
  final Queue<Uri> _pending = Queue<Uri>();
  bool _ready = false;
  bool _opening = false;

  void add(Uri uri) {
    _pending.add(uri);
    unawaited(_drain());
  }

  void setReady(bool ready) {
    _ready = ready;
    if (ready) unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_opening) return;
    _opening = true;
    try {
      while (_ready && _pending.isNotEmpty) {
        final uri = _pending.removeFirst();
        try {
          await open(uri);
        } catch (error, stack) {
          onError(error, stack);
        }
      }
    } finally {
      _opening = false;
    }
  }
}

/// Only strip a page suffix for known gallery URL structures, never a comic ID.
///
/// Ported from venera-prime `comicLinkTarget`: nhentai gallery pages look
/// like `/g/<id>/<page>` and e-hentai/exhentai look like `/g/<id>/<token>/<page>`.
/// The page is returned separately; the URI is rewritten without it so
/// `linkToId` resolves the gallery id. Unified `ComicPage` has no reader-page
/// parameter, so callers use the stripped URI for navigation (page kept for
/// future use and covered by tests).
({Uri uri, int? page}) comicLinkTarget(Uri uri) {
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  final host = uri.host.toLowerCase();
  final gallery = parts.isNotEmpty && parts.first == 'g';
  final knownPage =
      gallery &&
      ((host == 'nhentai.net' && parts.length == 3) ||
          ((host == 'e-hentai.org' || host == 'exhentai.org') &&
              parts.length == 4));
  final page = knownPage ? int.tryParse(parts.last) : null;
  if (page == null || page < 1 || int.tryParse(parts[1]) == null) {
    return (uri: uri, page: null);
  }
  return (
    uri: uri.replace(pathSegments: [...parts.take(parts.length - 1), '']),
    page: page,
  );
}
