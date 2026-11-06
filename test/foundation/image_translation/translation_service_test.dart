import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/image_translation/translation_service.dart';
import 'package:venera_unified/foundation/image_translation/translation_store.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';

void main() {
  group('ImageTranslationService keys', () {
    test('cacheKeyFor embeds scope, chapter and page ordinal', () {
      final key = ImageTranslationService.cacheKeyFor('local', 'cid1', 'e1', 3);
      expect(key, contains('cid1'));
      expect(key, endsWith('p3@'));
      final p1 = ImageTranslationService.cacheKeyFor('local', 'cid1', 'e1', 1);
      final p10 = ImageTranslationService.cacheKeyFor('local', 'cid1', 'e1', 10);
      expect(p10.startsWith(p1), isFalse);
    });

    test('renderedKey separates render modes on the same page', () {
      const page = 'prefix@local@cid1@e1@p1@';
      final smart =
          ImageTranslationService.renderedKey(page, InpaintMode.smart);
      final patch =
          ImageTranslationService.renderedKey(page, InpaintMode.patch);
      expect(smart, isNot(patch));
      expect(smart, startsWith(page));
    });

    test('scope prefixes nest comic < chapter', () {
      final comic = ImageTranslationService.comicScopePrefix('local', 'cid1');
      final chapter =
          ImageTranslationService.chapterScopePrefix('local', 'cid1', 'e1');
      expect(chapter, startsWith(comic));
    });
  });

  group('ImageTranslationService status machine', () {
    test('fresh service reports idle, marks translate, clears failure', () {
      final service = ImageTranslationService.instance;
      const key = 'test-status@local@cid9@e9@p9@';
      expect(service.statusOf(key, InpaintMode.smart),
          PageTranslationStatus.idle);
      expect(service.errorOf(key, InpaintMode.smart), isNull);
      service.markTranslated(key, InpaintMode.smart);
      expect(service.isTranslated(key, InpaintMode.smart), isTrue);
      expect(service.statusOf(key, InpaintMode.smart),
          PageTranslationStatus.translated);
      service.clearFailure(key, InpaintMode.smart);
      expect(service.isTranslated(key, InpaintMode.smart), isTrue);
    });
  });

  group('ImageTranslationService per-comic switch', () {
    late Directory directory;
    setUpAll(() {
      directory = Directory.systemTemp.createTempSync('translation-sw-');
      App.dataPath = directory.path;
    });
    tearDown(() {
      final stored = appdata.implicitData['imageTranslationEnabledComics'];
      if (stored is Map) stored.clear();
    });

    test('disabled by default, enabled after set', () {
      expect(ImageTranslationService.isEnabledForComic('cidA', 'local'),
          isFalse);
      ImageTranslationService.setEnabledForComic('cidA', 'local', true);
      expect(ImageTranslationService.isEnabledForComic('cidA', 'local'),
          isTrue);
      expect(ImageTranslationService.enabledComicKeys, contains('cidA@local'));
      ImageTranslationService.setEnabledForComic('cidA', 'local', false);
      expect(ImageTranslationService.isEnabledForComic('cidA', 'local'),
          isFalse);
    });
  });

  group('ImageTranslationService glossary', () {
    late Directory directory;
    setUpAll(() {
      directory = Directory.systemTemp.createTempSync('translation-gl-');
      App.dataPath = directory.path;
    });
    tearDown(() {
      appdata.implicitData.remove('imageTranslationComicGlossary');
      appdata.implicitData.remove('imageTranslationBlockedTerms');
    });

    test('set/get/remove round-trip with block', () {
      final service = ImageTranslationService.instance;
      expect(
          service.setGlossaryEntry('cidG', 'local', '史密斯', 'Smith'), isTrue);
      expect(service.glossaryOf('cidG', 'local'), {'史密斯': 'Smith'});
      service.removeGlossaryEntry('cidG', 'local', '史密斯', block: true);
      expect(service.glossaryOf('cidG', 'local'), isEmpty);
      expect(service.blockedTermsOf('cidG', 'local'), contains('史密斯'));
      service.unblockTerm('cidG', 'local', '史密斯');
      expect(service.blockedTermsOf('cidG', 'local'), isEmpty);
    });

    test('rejects junk terms', () {
      final service = ImageTranslationService.instance;
      expect(service.setGlossaryEntry('cidJ', 'local', '', 'x'), isFalse);
      expect(
          service.setGlossaryEntry(
              'cidJ', 'local', 'https://example.com/a', 'x'),
          isFalse);
    });
  });

  group('ImageTranslationService cache scope', () {
    late Directory directory;

    setUpAll(() async {
      directory = Directory.systemTemp.createTempSync('translation-svc-');
      App.dataPath = directory.path;
      App.cachePath = '${directory.path}/cache';
      await TranslationStore().init();
    });

    tearDownAll(() {
      TranslationStore().close();
      TranslationStore().dispose();
    });

    test('invalidateScope on empty scope removes nothing', () async {
      final service = ImageTranslationService.instance;
      final removed = await service.invalidateScope('pageTranslation@2@');
      expect(removed, 0);
    });

    test('clearAllTranslationCache on empty cache removes nothing', () async {
      final service = ImageTranslationService.instance;
      final removed = await service.clearAllTranslationCache();
      expect(removed, 0);
    });
  });
}
