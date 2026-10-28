import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/settings/settings_search_index.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    AppTranslation.translations = const {};
  });

  setUp(() {
    appdata.settings['language'] = 'en-US';
  });

  tearDown(() {
    appdata.settings['language'] = 'system';
  });

  List<String> titlesOf(String query, {bool includeHidden = false}) =>
      matchSettingsSearch(
        query,
        includeHidden: includeHidden,
      ).map((e) => e.title).toList();

  group('matchSettingsSearch', () {
    test('empty or blank query returns nothing', () {
      expect(matchSettingsSearch(''), isEmpty);
      expect(matchSettingsSearch('   '), isEmpty);
    });

    test('matches titles case-insensitively', () {
      expect(titlesOf('proxy'), contains('Proxy'));
      expect(titlesOf('PROXY'), contains('Proxy'));
      expect(titlesOf('Theme Color'), contains('Theme Color'));
    });

    test('matches multi-word substrings', () {
      expect(titlesOf('page margin'), contains('Page margin'));
      expect(titlesOf('page margin'), contains('Page margin size'));
    });

    test('matches keywords and synonyms', () {
      expect(titlesOf('vpn'), contains('Proxy'));
      expect(titlesOf('block'), contains('Keyword blocking'));
      expect(titlesOf('block'), contains('Comment keyword blocking'));
      expect(titlesOf('e-ink'), contains('E-Ink display refresh'));
      expect(titlesOf('ghosting'), contains('Flash white screen on page turn'));
    });

    test('matches category names', () {
      final results = titlesOf('appearance');
      expect(results, contains('Theme Mode'));
      expect(results, contains('Theme Color'));
      expect(results, contains('Night Mode'));
    });

    test('unknown query returns nothing', () {
      expect(matchSettingsSearch('zzz-no-such-setting'), isEmpty);
    });
  });

  group('platform guards', () {
    test('volume-keys entry is visible only on Android', () {
      final results = titlesOf('volume keys', includeHidden: true);
      expect(results, contains('Turn page by volume keys'));

      final filtered = titlesOf('volume keys');
      expect(filtered.contains('Turn page by volume keys'), Platform.isAndroid);
    });

    test('window shortcut entry is visible only on Windows', () {
      final results = titlesOf('hide/restore', includeHidden: true);
      expect(results, contains('Global hide/restore shortcut'));

      final filtered = titlesOf('hide/restore');
      expect(
        filtered.contains('Global hide/restore shortcut'),
        Platform.isWindows,
      );
    });

    test('authorization entries are hidden on Linux', () {
      final results = titlesOf('authorization', includeHidden: true);
      expect(results, contains('Authorization Required'));

      final filtered = titlesOf('authorization');
      expect(filtered.contains('Authorization Required'), !Platform.isLinux);
      expect(
        titlesOf('unlock method').contains('Unlock method'),
        !Platform.isLinux,
      );
    });
  });

  group('index integrity (jump targets exist)', () {
    test('category list mirrors the settings page order', () {
      expect(settingsSearchCategories, [
        'Explore',
        'Reading',
        'Reading statistics',
        'Appearance',
        'Local Favorites',
        'APP',
        'Network',
        'About',
        'Debug',
      ]);
    });

    test('every entry points at an existing category', () {
      expect(settingsSearchIndex, isNotEmpty);
      for (final e in settingsSearchIndex) {
        expect(e.title, isNotEmpty, reason: 'entry title');
        expect(
          e.category,
          inInclusiveRange(0, settingsSearchCategories.length - 1),
          reason: 'category of "${e.title}"',
        );
      }
    });

    test('every category has at least one entry', () {
      final covered = settingsSearchIndex.map((e) => e.category).toSet();
      for (var i = 0; i < settingsSearchCategories.length; i++) {
        expect(covered, contains(i), reason: settingsSearchCategories[i]);
      }
    });

    test('titles are unique', () {
      final titles = settingsSearchIndex.map((e) => e.title).toList();
      expect(titles.toSet().length, titles.length);
    });
  });
}
