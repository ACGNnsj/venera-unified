import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/routing/pending_app_links.dart';

void main() {
  group('comicLinkTarget', () {
    test('strips nhentai gallery page suffix', () {
      final result = comicLinkTarget(
        Uri.parse('https://nhentai.net/g/12345/3'),
      );
      expect(result.page, 3);
      expect(result.uri.toString(), 'https://nhentai.net/g/12345/');
    });

    test('strips e-hentai gallery page suffix', () {
      final result = comicLinkTarget(
        Uri.parse('https://e-hentai.org/g/12345/abcdef/2'),
      );
      expect(result.page, 2);
      expect(result.uri.toString(), 'https://e-hentai.org/g/12345/abcdef/');
    });

    test('keeps gallery url without page', () {
      final uri = Uri.parse('https://nhentai.net/g/12345/');
      final result = comicLinkTarget(uri);
      expect(result.page, isNull);
      expect(result.uri, uri);
    });

    test('never strips non-gallery numeric paths', () {
      final uri = Uri.parse('https://example.com/comic/12345');
      final result = comicLinkTarget(uri);
      expect(result.page, isNull);
      expect(result.uri, uri);
    });
  });

  group('PendingAppLinks', () {
    test('queues until ready and drains in order', () async {
      final opened = <Uri>[];
      final pending = PendingAppLinks((uri) async {
        opened.add(uri);
      }, (error, stack) {});
      final first = Uri.parse('https://example.com/a');
      final second = Uri.parse('https://example.com/b');
      pending.add(first);
      pending.add(second);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(opened, isEmpty);
      pending.setReady(true);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(opened, [first, second]);
    });
  });
}
