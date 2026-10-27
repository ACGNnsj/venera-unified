import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_unified/network/rhttp_client_pool.dart';

class _FakeHandle {
  int disposeCalls = 0;
  final disposedCancelFlags = <bool>[];
}

void main() {
  rhttp.ClientSettings baseSettings() => const rhttp.ClientSettings(
    proxySettings: rhttp.ProxySettings.noProxy(),
    redirectSettings: rhttp.RedirectSettings.limited(5),
    timeoutSettings: rhttp.TimeoutSettings(
      connectTimeout: Duration(seconds: 15),
      keepAliveTimeout: Duration(seconds: 60),
      keepAlivePing: Duration(seconds: 30),
    ),
    throwOnStatusCode: false,
    dnsSettings: rhttp.DnsSettings.static(overrides: {}),
    tlsSettings: rhttp.TlsSettings(sni: true, verifyCertificates: true),
  );

  RhttpClientPool<_FakeHandle> pool({
    required List<rhttp.ClientSettings> createdWith,
    required List<_FakeHandle> disposed,
    Future<_FakeHandle> Function(rhttp.ClientSettings)? create,
  }) => RhttpClientPool<_FakeHandle>.forTesting(
    (settings) async {
      createdWith.add(settings);
      if (create != null) return create(settings);
      return _FakeHandle();
    },
    (handle, cancelRunningRequests) {
      handle.disposeCalls++;
      handle.disposedCancelFlags.add(cancelRunningRequests);
      disposed.add(handle);
    },
  );

  group('fingerprintOf', () {
    test('is stable for identical settings', () {
      expect(
        RhttpClientPool.fingerprintOf(baseSettings()),
        RhttpClientPool.fingerprintOf(baseSettings()),
      );
    });

    test('ignores DNS override map order', () {
      const withOrder = rhttp.DnsSettings.static(
        overrides: {
          'a.example': ['1.1.1.1'],
          'b.example': ['2.2.2.2'],
        },
      );
      const reversed = rhttp.DnsSettings.static(
        overrides: {
          'b.example': ['2.2.2.2'],
          'a.example': ['1.1.1.1'],
        },
      );
      expect(
        RhttpClientPool.fingerprintOf(
          baseSettings().copyWith(dnsSettings: withOrder),
        ),
        RhttpClientPool.fingerprintOf(
          baseSettings().copyWith(dnsSettings: reversed),
        ),
      );
    });

    test('splits on every baked field', () {
      final base = RhttpClientPool.fingerprintOf(baseSettings());
      final variants = <String, rhttp.ClientSettings>{
        'baseUrl': baseSettings().copyWith(baseUrl: 'https://x.example'),
        'cookie': baseSettings().copyWith(
          cookieSettings: const rhttp.CookieSettings(),
        ),
        'httpVersionPref': baseSettings().copyWith(
          httpVersionPref: rhttp.HttpVersionPref.http3,
        ),
        'connectTimeout': baseSettings().copyWith(
          timeoutSettings: const rhttp.TimeoutSettings(
            connectTimeout: Duration(seconds: 1),
            keepAliveTimeout: Duration(seconds: 60),
            keepAlivePing: Duration(seconds: 30),
          ),
        ),
        'keepAliveTimeout': baseSettings().copyWith(
          timeoutSettings: const rhttp.TimeoutSettings(
            connectTimeout: Duration(seconds: 15),
            keepAliveTimeout: Duration(seconds: 1),
            keepAlivePing: Duration(seconds: 30),
          ),
        ),
        'throwOnStatusCode': baseSettings().copyWith(throwOnStatusCode: true),
        'proxy': baseSettings().copyWith(
          proxySettings: const rhttp.ProxySettings.proxy(
            'http://127.0.0.1:8080',
          ),
        ),
        'redirect-none': baseSettings().copyWith(
          redirectSettings: const rhttp.RedirectSettings.none(),
        ),
        'redirect-n': baseSettings().copyWith(
          redirectSettings: const rhttp.RedirectSettings.limited(3),
        ),
        'sni': baseSettings().copyWith(
          tlsSettings: const rhttp.TlsSettings(
            sni: false,
            verifyCertificates: true,
          ),
        ),
        'verify': baseSettings().copyWith(
          tlsSettings: const rhttp.TlsSettings(
            sni: true,
            verifyCertificates: false,
          ),
        ),
        'dns-overrides': baseSettings().copyWith(
          dnsSettings: const rhttp.DnsSettings.static(
            overrides: {
              'a.example': ['1.1.1.1'],
            },
          ),
        ),
        'dns-fallback': baseSettings().copyWith(
          dnsSettings: const rhttp.DnsSettings.static(
            overrides: {},
            fallback: '8.8.8.8',
          ),
        ),
        'userAgent': baseSettings().copyWith(userAgent: 'ua'),
      };
      for (final entry in variants.entries) {
        expect(
          RhttpClientPool.fingerprintOf(entry.value),
          isNot(base),
          reason: entry.key,
        );
      }
      // Every variant must also differ from every other variant.
      final fingerprints = variants.values
          .map(RhttpClientPool.fingerprintOf)
          .toList();
      expect(fingerprints.toSet(), hasLength(fingerprints.length));
    });
  });

  group('acquire', () {
    test('reuses one handle per fingerprint', () async {
      final createdWith = <rhttp.ClientSettings>[];
      final disposed = <_FakeHandle>[];
      final underTest = pool(createdWith: createdWith, disposed: disposed);

      final first = await underTest.acquire(baseSettings());
      final second = await underTest.acquire(baseSettings());

      expect(identical(first, second), isTrue);
      expect(createdWith, hasLength(1));
      expect(disposed, isEmpty);
    });

    test('serializes concurrent creation', () async {
      final createdWith = <rhttp.ClientSettings>[];
      final disposed = <_FakeHandle>[];
      final underTest = pool(createdWith: createdWith, disposed: disposed);

      final handles = await Future.wait([
        underTest.acquire(baseSettings()),
        underTest.acquire(baseSettings()),
        underTest.acquire(baseSettings()),
      ]);

      expect(createdWith, hasLength(1));
      expect(identical(handles[0], handles[1]), isTrue);
      expect(identical(handles[1], handles[2]), isTrue);
    });

    test(
      'retries after a failed creation instead of caching the error',
      () async {
        final createdWith = <rhttp.ClientSettings>[];
        final disposed = <_FakeHandle>[];
        var attempts = 0;
        final underTest = pool(
          createdWith: createdWith,
          disposed: disposed,
          create: (_) async {
            attempts++;
            if (attempts == 1) throw StateError('native down');
            return _FakeHandle();
          },
        );

        await expectLater(underTest.acquire(baseSettings()), throwsStateError);
        final handle = await underTest.acquire(baseSettings());

        expect(handle, isA<_FakeHandle>());
        expect(attempts, 2);
        expect(disposed, isEmpty);
      },
    );

    test('evicts the least recently used handle without cancelling', () async {
      final createdWith = <rhttp.ClientSettings>[];
      final disposed = <_FakeHandle>[];
      final underTest = pool(createdWith: createdWith, disposed: disposed);

      rhttp.ClientSettings distinct(int i) => baseSettings().copyWith(
        proxySettings: rhttp.ProxySettings.proxy('http://127.0.0.1:808$i'),
      );

      final handles = <_FakeHandle>[];
      for (var i = 0; i < RhttpClientPool.maxEntries; i++) {
        handles.add(await underTest.acquire(distinct(i)));
      }
      expect(disposed, isEmpty);
      // Touch the eldest so the second-oldest becomes the eviction victim.
      expect(
        identical(await underTest.acquire(distinct(0)), handles[0]),
        isTrue,
      );
      await underTest.acquire(distinct(RhttpClientPool.maxEntries));
      // Eviction dispose is fire-and-forget so acquire never waits on it.
      await Future<void>.delayed(Duration.zero);

      expect(disposed, hasLength(1));
      expect(identical(disposed.single, handles[1]), isTrue);
      expect(handles[1].disposeCalls, 1);
      expect(handles[1].disposedCancelFlags, [false]);
      // The refreshed eldest and the newest handle survive.
      expect(
        identical(await underTest.acquire(distinct(0)), handles[0]),
        isTrue,
      );
      expect(createdWith, hasLength(RhttpClientPool.maxEntries + 1));
    });
  });

  group('reset', () {
    test('disposes every handle without cancelling by default', () async {
      final createdWith = <rhttp.ClientSettings>[];
      final disposed = <_FakeHandle>[];
      final underTest = pool(createdWith: createdWith, disposed: disposed);

      final first = await underTest.acquire(baseSettings());
      final second = await underTest.acquire(
        baseSettings().copyWith(httpVersionPref: rhttp.HttpVersionPref.http3),
      );
      await underTest.reset();

      expect(disposed, unorderedEquals([first, second]));
      for (final handle in [first, second]) {
        expect(handle.disposeCalls, 1);
        expect(handle.disposedCancelFlags, [false]);
      }
      // The pool is empty again: next acquire recreates.
      await underTest.acquire(baseSettings());
      expect(createdWith, hasLength(3));
    });

    test('forwards cancelRunningRequests when asked', () async {
      final createdWith = <rhttp.ClientSettings>[];
      final disposed = <_FakeHandle>[];
      final underTest = pool(createdWith: createdWith, disposed: disposed);

      final handle = await underTest.acquire(baseSettings());
      await underTest.reset(cancelRunningRequests: true);

      expect(handle.disposedCancelFlags, [true]);
    });

    test('tolerates failed creations', () async {
      final createdWith = <rhttp.ClientSettings>[];
      final disposed = <_FakeHandle>[];
      final underTest = pool(
        createdWith: createdWith,
        disposed: disposed,
        create: (_) => throw StateError('native down'),
      );

      await expectLater(underTest.acquire(baseSettings()), throwsStateError);
      await underTest.reset();

      expect(disposed, isEmpty);
    });
  });
}
