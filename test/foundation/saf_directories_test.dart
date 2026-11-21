import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/saf_directories.dart';

void main() {
  group('resolveComicDirectory', () {
    test('keeps absolute and generic SAF paths', () {
      expect(resolveComicDirectory('/abs/dir', '/lib'), '/abs/dir');
      expect(
        resolveComicDirectory('android://primary:root/comic', '/lib'),
        'android://primary:root/comic',
      );
    });

    test('joins relative names onto the library', () {
      expect(resolveComicDirectory('comic-a', '/lib'), '/lib/comic-a');
    });

    test('joins Windows library paths with Windows separators', () {
      final slash = String.fromCharCode(92);
      final library = ['C:', 'Users', 'reader', 'Library'].join(slash);
      expect(resolveComicDirectory('Book', library), '$library${slash}Book');
    });
  });

  group('generic SAF document ids', () {
    test('exposes document id only for SAF paths', () {
      expect(
        safDocumentId('android://primary:root/comic'),
        'primary:root/comic',
      );
      expect(safDocumentId('/local/comic'), isNull);
    });

    test('offline-keep only for SAF paths', () {
      expect(shouldKeepConfiguredPath('android://primary:root'), isTrue);
      expect(shouldKeepConfiguredPath('/local/root'), isFalse);
    });
  });
}
