import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/comic_source.dart';
import 'package:venera_unified/features/comic_source/source_repositories.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';
import 'package:venera_unified/foundation/comic_source_selfhost.dart';
import 'package:venera_unified/network/app_dio.dart';

// Embedded copies of venera-unified-configs@sources-v1 catalogs (byte-synced
// at authoring time; the "real files" test below re-parses the sibling
// checkout when present to catch drift before tagging).
const _defaultCatalogJson = '''
[
  {
    "name": "拷贝漫画",
    "key": "copy_manga",
    "fileName": "copy_manga.js",
    "version": "1.4.1",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/copy_manga.js"
  },
  {
    "name": "包子漫画",
    "key": "baozi",
    "fileName": "baozi.js",
    "version": "1.2.0",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/baozi.js"
  },
  {
    "name": "禁漫天堂",
    "key": "jm",
    "fileName": "jm.js",
    "version": "1.4.5",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/jm.js"
  },
  {
    "name": "hitomi.la",
    "key": "hitomi",
    "fileName": "hitomi.js",
    "version": "1.1.2",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/hitomi.js"
  }
]
''';

const _optionalCatalogJson = '''
[
  {
    "name": "漫蛙吧",
    "key": "manwaba",
    "fileName": "manwaba.js",
    "version": "1.4.0",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/manwaba.js"
  },
  {
    "name": "虫虫漫画",
    "key": "warchina",
    "fileName": "warchina.js",
    "version": "1.0.3",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/warchina.js"
  },
  {
    "name": "漫画柜",
    "key": "ManHuaGui",
    "fileName": "manhuagui.js",
    "version": "1.2.1",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/manhuagui.js"
  },
  {
    "name": "漫网",
    "key": "manwang",
    "fileName": "manwang.js",
    "version": "1.0.0",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/manwang.js"
  },
  {
    "name": "漫画屋",
    "key": "mhua5",
    "fileName": "mhua5.js",
    "version": "1.0.2",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/mhua5.js"
  },
  {
    "name": "酷笔漫画",
    "key": "kubb",
    "fileName": "kubb.js",
    "version": "1.0.2",
    "url": "https://cdn.jsdelivr.net/gh/ACGNnsj/venera-unified-configs@sources-v1/sources/kubb.js"
  }
]
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDir;
  late dynamic originalListUrl;
  late dynamic originalRepositories;
  late dynamic originalOrigins;
  late dynamic originalMigrated;
  late dynamic originalSelfhostMigrated;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('venera-selfhost-');
    App.dataPath = dataDir.path;
    originalListUrl = appdata.settings['comicSourceListUrl'];
    originalRepositories = appdata.settings['comicSourceRepositories'];
    originalOrigins = appdata.settings['comicSourceOrigins'];
    originalMigrated = appdata.settings['comicSourceRepositoriesMigrated'];
    originalSelfhostMigrated = appdata.settings['comicSourceSelfhostMigrated'];
    appdata.settings['comicSourceListUrl'] = '';
    appdata.settings['comicSourceRepositories'] = <Map<String, dynamic>>[];
    appdata.settings['comicSourceOrigins'] = <String, dynamic>{};
    appdata.settings['comicSourceRepositoriesMigrated'] = true;
    appdata.settings['comicSourceSelfhostMigrated'] = false;
    await appdata.init();
  });

  tearDown(() {
    appdata.settings['comicSourceListUrl'] = originalListUrl;
    appdata.settings['comicSourceRepositories'] = originalRepositories;
    appdata.settings['comicSourceOrigins'] = originalOrigins;
    appdata.settings['comicSourceRepositoriesMigrated'] = originalMigrated;
    appdata.settings['comicSourceSelfhostMigrated'] = originalSelfhostMigrated;
    if (dataDir.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
  });

  group('parseCatalog (selfhost)', () {
    test('parses the default catalog: 4 entries, none skipped', () {
      final catalog = SourceRepositories.parseCatalog(
        _defaultCatalogJson,
        baseUrl: kSelfhostCatalogUrl,
      );
      expect(catalog.skipped, isEmpty);
      expect(catalog.entries.map((e) => e.key), [
        'copy_manga',
        'baozi',
        'jm',
        'hitomi',
      ]);
      expect(catalog.entries.map((e) => e.version), [
        '1.4.1',
        '1.2.0',
        '1.4.5',
        '1.1.2',
      ]);
      for (final entry in catalog.entries) {
        expect(entry.url, contains('@$kSelfhostTag/'));
        expect(entry.url, selfhostEntryUrlForKey(entry.key));
      }
    });

    test('parses the optional catalog: 6 entries, none skipped', () {
      final catalog = SourceRepositories.parseCatalog(
        _optionalCatalogJson,
        baseUrl: kSelfhostOptionalCatalogUrl,
      );
      expect(catalog.skipped, isEmpty);
      expect(catalog.entries.map((e) => e.key), [
        'manwaba',
        'warchina',
        'ManHuaGui',
        'manwang',
        'mhua5',
        'kubb',
      ]);
      // The default catalog must not contain any optional key.
      final defaultCatalog = SourceRepositories.parseCatalog(
        _defaultCatalogJson,
        baseUrl: kSelfhostCatalogUrl,
      );
      final defaultKeys = defaultCatalog.entries.map((e) => e.key).toSet();
      for (final entry in catalog.entries) {
        expect(defaultKeys, isNot(contains(entry.key)));
        expect(entry.url, contains('@$kSelfhostTag/'));
      }
    });

    test('real configs checkout parses when present (local only)', () async {
      final defaultFile = File('../venera-unified-configs/catalog/index.json');
      final optionalFile = File(
        '../venera-unified-configs/catalog/optional.json',
      );
      if (!await defaultFile.exists() || !await optionalFile.exists()) {
        markTestSkipped('configs repo not checked out next to unified');
        return;
      }
      final defaultCatalog = SourceRepositories.parseCatalog(
        await defaultFile.readAsString(),
        baseUrl: kSelfhostCatalogUrl,
      );
      expect(defaultCatalog.entries, hasLength(4));
      expect(defaultCatalog.skipped, isEmpty);
      final optionalCatalog = SourceRepositories.parseCatalog(
        await optionalFile.readAsString(),
        baseUrl: kSelfhostOptionalCatalogUrl,
      );
      expect(optionalCatalog.entries, hasLength(6));
      expect(optionalCatalog.skipped, isEmpty);
    });
  });

  group('selfhost migration', () {
    test('fresh install gains the repository and default origins', () async {
      await SourceRepositories.instance.migrate();

      final repositories = SourceRepositories.instance.all;
      expect(repositories, hasLength(1));
      expect(repositories.single.id, kSelfhostRepositoryId);
      expect(repositories.single.url, kSelfhostCatalogUrl);
      for (final key in kSelfhostDefaultKeys) {
        final origin = SourceRepositories.instance.originFor(key)!;
        expect(origin.kind, 'repository');
        expect(origin.repositoryId, kSelfhostRepositoryId);
        expect(origin.url, selfhostEntryUrlForKey(key));
      }
      expect(appdata.settings['comicSourceSelfhostMigrated'], isTrue);
      final saved = _persistedSettings(dataDir);
      expect(saved['comicSourceSelfhostMigrated'], isTrue);
      expect(
        (saved['comicSourceRepositories'] as List).single['id'],
        kSelfhostRepositoryId,
      );
    });

    test('migration is idempotent and respects later removal', () async {
      await SourceRepositories.instance.migrate();
      final firstOrigins = Map<String, dynamic>.from(
        appdata.settings['comicSourceOrigins'] as Map,
      );

      await SourceRepositories.instance.migrate();
      expect(SourceRepositories.instance.all, hasLength(1));
      expect(appdata.settings['comicSourceOrigins'], equals(firstOrigins));

      // The user removes the repository; a later run must not recreate it.
      appdata.settings['comicSourceRepositories'] = <Map<String, dynamic>>[];
      await SourceRepositories.instance.migrate();
      expect(SourceRepositories.instance.all, isEmpty);
      expect(appdata.settings['comicSourceSelfhostMigrated'], isTrue);
    });

    test('keeps origins already linked to a live repository', () async {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap('official', 'Official', 'https://official.example/index.json'),
      ];
      appdata.settings['comicSourceOrigins'] = {
        'jm': {
          'kind': 'repository',
          'repositoryId': 'official',
          'repositoryName': 'Official',
          'url': 'https://official.example/jm.js',
        },
      };

      await SourceRepositories.instance.migrate();

      final repositories = SourceRepositories.instance.all;
      expect(repositories.map((r) => r.id), [
        'official',
        kSelfhostRepositoryId,
      ]);
      // Official link untouched: no official URL is rewritten.
      expect(
        SourceRepositories.instance.originFor('jm')?.repositoryId,
        'official',
      );
      expect(
        SourceRepositories.instance.originFor('jm')?.url,
        'https://official.example/jm.js',
      );
      // The other defaults still gain selfhost origins.
      for (final key in ['copy_manga', 'baozi', 'hitomi']) {
        expect(
          SourceRepositories.instance.originFor(key)?.repositoryId,
          kSelfhostRepositoryId,
        );
      }
    });

    test(
      'relinks url/file/orphaned origins, leaves optional keys alone',
      () async {
        appdata.settings['comicSourceOrigins'] = {
          'jm': {'kind': 'url', 'url': 'https://personal.example/jm.js'},
          'baozi': {'kind': 'file', 'url': '/tmp/baozi.js'},
          'copy_manga': {
            'kind': 'repository',
            'repositoryId': 'gone',
            'url': 'https://gone.example/copy_manga.js',
          },
          'manwaba': {'kind': 'url', 'url': 'https://personal.example/m.js'},
        };

        await SourceRepositories.instance.migrate();

        for (final key in ['jm', 'baozi', 'copy_manga']) {
          final origin = SourceRepositories.instance.originFor(key)!;
          expect(origin.kind, 'repository');
          expect(origin.repositoryId, kSelfhostRepositoryId);
        }
        // Optional-catalog keys are never auto-linked to the default catalog.
        expect(SourceRepositories.instance.originFor('manwaba')?.kind, 'url');
      },
    );
  });

  group('checkUpdates regression (selfhost)', () {
    test('linked source detects an update, unlinked counts skipped', () async {
      appdata.settings['comicSourceRepositories'] = [
        _repoMap(kSelfhostRepositoryId, 'Selfhost', kSelfhostCatalogUrl),
      ];
      appdata.settings['comicSourceOrigins'] = {
        'jm': {
          'kind': 'repository',
          'repositoryId': kSelfhostRepositoryId,
          'url': selfhostEntryUrlForKey('jm'),
        },
      };
      // Catalog advertises jm 9.9.9 while the installed source is 1.4.5.
      final catalog = (jsonDecode(_defaultCatalogJson) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      catalog.firstWhere((e) => e['key'] == 'jm')['version'] = '9.9.9';
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: jsonEncode(catalog),
              ),
            );
          },
        ),
      );
      final result = await SourceRepositories(client: dio).checkUpdates([
        _source('jm', version: '1.4.5'),
        _source('no_origin', version: '1.0.0'),
      ]);
      expect(result.updates, {'jm': '9.9.9'});
      expect(result.checked, 1);
      expect(result.skipped, 1);
      expect(result.failures, isEmpty);
    });
  });
}

Map<String, dynamic> _repoMap(String id, String name, String url) {
  return SourceRepository(id: id, name: name, url: url).toJson();
}

Map<String, dynamic> _persistedSettings(Directory dataDir) {
  final file = File('${dataDir.path}/appdata.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map;
  return Map<String, dynamic>.from(decoded['settings'] as Map);
}

ComicSource _source(
  String key, {
  String url = 'https://example.com/source.js',
  String version = '1.0.0',
}) {
  return ComicSource(
    'Source $key',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    '$key.js',
    url,
    version,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
