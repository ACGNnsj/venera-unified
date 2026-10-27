// The settings subtype names below are not re-exported by the public barrel,
// so they are imported from the vendored path-pinned package directly.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:rhttp/src/model/settings.dart'
    show
        CustomProxyList,
        DynamicDnsSettings,
        LimitedRedirects,
        NoProxy,
        NoRedirectSetting,
        StaticDnsSettings;

/// Owns shared Rust HTTP handles, one per settings fingerprint.
///
/// Every streaming request used to pass only `settings:` to the native call,
/// so Rust built a fresh reqwest client per request and dropped its connection
/// pool when the request ended (`keepAliveTimeout` never survived). Acquiring
/// a pooled [rhttp.RhttpClient] and passing its handle down keeps one
/// connection pool alive across requests.
///
/// `rhttp` is a path dependency (`packages/rhttp`, see `pubspec.yaml`), so
/// this pool always talks to the vendored copy, including its local patches.
///
/// Ownership: this singleton is the only owner of pooled handles. Dio,
/// [RHttpAdapter], image clients and [OwnedDioClient] close semantics must
/// never dispose a pooled handle: per-operation `close(force: true)` would
/// otherwise kill the pool or cancel other callers' in-flight streams.
/// Eviction and [reset] therefore dispose without cancelling by default; an
/// in-flight request holds its own clone of the native client, so dropping
/// the pooled handle is safe.
///
/// Cookies are unaffected by pooling: the adapter never sets `cookieSettings`
/// (so Rust keeps reqwest's default of no cookie store at all) and cookies
/// live in the Dart-side `CookieManagerSql` interceptor instead. There is no
/// native jar to share, fresh or otherwise.
class RhttpClientPool<H> {
  RhttpClientPool._(this._create, this._dispose);

  static final RhttpClientPool<rhttp.RhttpClient> _instance =
      RhttpClientPool<rhttp.RhttpClient>._(
        (settings) => rhttp.RhttpClient.create(settings: settings),
        (client, cancelRunningRequests) =>
            client.dispose(cancelRunningRequests: cancelRunningRequests),
      );

  /// The production pool. Never use `createSync` here: it crashes when the
  /// client is configured for HTTP/3.
  static RhttpClientPool<rhttp.RhttpClient> get instance => _instance;

  @visibleForTesting
  RhttpClientPool.forTesting(this._create, this._dispose);

  /// Steady state needs at most ~3 entries (default, no-redirect, HTTP/3
  /// fallback); 4 leaves headroom for one proxy/DNS/TLS settings change
  /// without churning the hot handles.
  @visibleForTesting
  static const int maxEntries = 4;

  final Future<H> Function(rhttp.ClientSettings settings) _create;
  final void Function(H handle, bool cancelRunningRequests) _dispose;

  /// Insertion-ordered (a map literal is a `LinkedHashMap`); every hit
  /// re-inserts so the first key is always the least recently used.
  /// Concurrent acquires of one fingerprint share a single in-flight creation.
  final _entries = <String, Future<H>>{};

  /// Returns the shared handle for [settings], creating it on first use.
  ///
  /// The fingerprint must be taken from the per-request `configured` settings,
  /// not the adapter-wide ones: the image HTTP/3 fallback rewrites
  /// `httpVersionPref` per request and must land on its own handle.
  Future<H> acquire(rhttp.ClientSettings settings) {
    final key = fingerprintOf(settings);
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit;
      return hit;
    }
    late final Future<H> pending;
    pending = _create(settings).then<H>(
      (client) => client,
      onError: (Object error, StackTrace stack) {
        // A failed creation must not poison the pool; the next acquire
        // retries instead of replaying the cached error.
        if (identical(_entries[key], pending)) _entries.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _entries[key] = pending;
    while (_entries.length > maxEntries) {
      final oldest = _entries.keys.first;
      final evicted = _entries.remove(oldest)!;
      // Eviction must not cancel in-flight streams that borrowed the handle.
      unawaited(
        evicted.then<void>(
          (client) => _dispose(client, false),
          // Creation already failed; nothing to dispose.
          onError: (Object _, StackTrace _) {},
        ),
      );
    }
    return pending;
  }

  /// Disposes every pooled handle and clears the pool.
  ///
  /// [cancelRunningRequests] defaults to false: settings changes retire
  /// handles while already accepted requests finish against them.
  Future<void> reset({bool cancelRunningRequests = false}) async {
    final pending = _entries.values.toList();
    _entries.clear();
    for (final entry in pending) {
      try {
        _dispose(await entry, cancelRunningRequests);
      } catch (_) {
        // Creation failed; nothing to dispose.
      }
    }
  }

  /// Stable fingerprint of every field baked into the native client.
  ///
  /// `ClientSettings` has no `==`/`hashCode`, so the raw values are joined
  /// into a string (separated by U+001F to avoid ambiguity). This is
  /// deliberately a superset: anything reqwest bakes into the client at
  /// `build_client` time (proxy, cookies, redirects, timeouts incl. keep-alive,
  /// TLS incl. SNI/verify/certificates, HTTP version preference, DNS, user
  /// agent, throw-on-status) plus `baseUrl`, which only prefixes Dart-side URL
  /// construction today but must still split the pool if a future caller
  /// varies it. Dynamic DNS resolvers are closures and cannot be fingerprinted;
  /// they collapse to a single marker (the app only builds static DNS).
  static String fingerprintOf(rhttp.ClientSettings settings) {
    const sep = '\x1f';
    final out = StringBuffer()
      ..write(settings.baseUrl ?? '')
      ..write(sep)
      ..write(_cookieFingerprint(settings.cookieSettings))
      ..write(sep)
      ..write(settings.httpVersionPref.name)
      ..write(sep)
      ..write(_timeoutFingerprint(settings.timeoutSettings))
      ..write(sep)
      ..write(settings.throwOnStatusCode)
      ..write(sep)
      ..write(_proxyFingerprint(settings.proxySettings))
      ..write(sep)
      ..write(_redirectFingerprint(settings.redirectSettings))
      ..write(sep)
      ..write(_tlsFingerprint(settings.tlsSettings))
      ..write(sep)
      ..write(_dnsFingerprint(settings.dnsSettings))
      ..write(sep)
      ..write(settings.userAgent ?? '');
    return out.toString();
  }

  static String _cookieFingerprint(rhttp.CookieSettings? settings) =>
      settings == null ? 'null' : 'store=${settings.storeCookies}';

  static String _timeoutFingerprint(rhttp.TimeoutSettings? settings) {
    if (settings == null) return 'null';
    String micros(Duration? value) => value?.inMicroseconds.toString() ?? '';
    return 't=${micros(settings.timeout)}'
        ';c=${micros(settings.connectTimeout)}'
        ';k=${micros(settings.keepAliveTimeout)}'
        ';p=${micros(settings.keepAlivePing)}';
  }

  static String _proxyFingerprint(rhttp.ProxySettings? settings) {
    return switch (settings) {
      null => 'null',
      NoProxy() => 'none',
      rhttp.StaticProxy(condition: final condition, url: final url) =>
        'static:${condition.name}=$url',
      CustomProxyList(proxies: final proxies) =>
        'list:${[for (final proxy in proxies) switch (proxy) {
            rhttp.StaticProxy(condition: final condition, url: final url) => '${condition.name}=$url',
          }].join(',')}',
    };
  }

  static String _redirectFingerprint(rhttp.RedirectSettings? settings) {
    return switch (settings) {
      null => 'null',
      NoRedirectSetting() => 'none',
      LimitedRedirects(:final maxRedirects) => 'limited=$maxRedirects',
    };
  }

  static String _tlsFingerprint(rhttp.TlsSettings? settings) {
    if (settings == null) return 'null';
    final cert = settings.clientCertificate;
    return 'trust=${settings.trustRootCertificates}'
        ';roots=${settings.trustedRootCertificates.join(',')}'
        ';verify=${settings.verifyCertificates}'
        ';cert=${cert == null ? '' : '${cert.certificate}\x1f${cert.privateKey}'}'
        ';min=${settings.minTlsVersion?.name ?? ''}'
        ';max=${settings.maxTlsVersion?.name ?? ''}'
        ';sni=${settings.sni}';
  }

  static String _dnsFingerprint(rhttp.DnsSettings? settings) {
    return switch (settings) {
      null => 'null',
      StaticDnsSettings(:final overrides, :final fallback) => [
        'static;fallback=${fallback ?? ''}',
        // Sort so map iteration order cannot split the pool.
        for (final host in overrides.keys.toList()..sort())
          '$host=${overrides[host]!.join(',')}',
      ].join(';'),
      // A closure has no stable identity; the app only builds static DNS.
      DynamicDnsSettings() => 'dynamic',
    };
  }
}
