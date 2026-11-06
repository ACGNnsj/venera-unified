import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/image_provider/reader_image.dart';
import 'package:venera_unified/foundation/image_translation/translation_service.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';

void main() {
  group('ReaderImageProvider.translationFor', () {
    late Directory directory;
    setUpAll(() {
      directory = Directory.systemTemp.createTempSync('reader-tr-');
      App.dataPath = directory.path;
    });
    tearDown(() {
      final stored = appdata.implicitData['imageTranslationEnabledComics'];
      if (stored is Map) stored.clear();
    });

    test('off switch yields an all-empty triple', () {
      final t = ReaderImageProvider.translationFor(
        sourceKey: 'local',
        cid: 'cid-off',
        eid: 'e1',
        page: 3,
      );
      expect(t.key, isNull);
      expect(t.config, isNull);
      expect(t.translated, isFalse);
    });

    test('enabled comic yields key, config and translated flip', () {
      ImageTranslationService.setEnabledForComic('cid-on', 'local', true);
      final before = ReaderImageProvider.translationFor(
        sourceKey: 'local',
        cid: 'cid-on',
        eid: 'e1',
        page: 3,
      );
      expect(before.key, contains('cid-on'));
      expect(before.config, isNotNull);
      expect(before.translated, isFalse);

      ImageTranslationService.instance.markTranslated(
        before.key!,
        before.config!.mode,
      );
      final after = ReaderImageProvider.translationFor(
        sourceKey: 'local',
        cid: 'cid-on',
        eid: 'e1',
        page: 3,
      );
      expect(after.translated, isTrue);
    });

    test('provider key changes once the page is translated', () {
      const plain = ReaderImageProvider('k', 'local', 'cid', 'e', 1);
      const pending = ReaderImageProvider(
        'k',
        'local',
        'cid',
        'e',
        1,
        translationKey: 'some-key',
      );
      const done = ReaderImageProvider(
        'k',
        'local',
        'cid',
        'e',
        1,
        translationKey: 'some-key',
        translated: true,
      );
      expect(plain.key, isNot(contains('@tr:')));
      expect(pending.key, contains('@tr:false'));
      expect(done.key, contains('@tr:true'));
    });
  });
}
