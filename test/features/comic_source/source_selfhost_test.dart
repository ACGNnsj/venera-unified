import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/source_repositories.dart';
import 'package:venera_unified/foundation/app.dart';
import 'package:venera_unified/foundation/appdata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dataDir;
  late Map<String, dynamic> previous;
  const keys = [
    'comicSourceListUrl',
    'comicSourceRepositories',
    'comicSourceOrigins',
    'comicSourceRepositoriesMigrated',
    'comicSourceSelfhostMigrated',
  ];
  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('venera-repositories-');
    App.dataPath = dataDir.path;
    previous = {for (final key in keys) key: appdata.settings[key]};
    appdata.settings['comicSourceListUrl'] = '';
    appdata.settings['comicSourceRepositories'] = <Map<String, dynamic>>[];
    appdata.settings['comicSourceOrigins'] = <String, dynamic>{};
    appdata.settings['comicSourceRepositoriesMigrated'] = false;
    appdata.settings['comicSourceSelfhostMigrated'] = false;
    await appdata.init();
  });
  tearDown(() {
    for (final key in keys) {
      appdata.settings[key] = previous[key];
    }
    dataDir.deleteSync(recursive: true);
  });

  test('fresh install never adds or binds a source repository', () async {
    await SourceRepositories.instance.migrate();
    await SourceRepositories.instance.migrate();
    expect(SourceRepositories.instance.all, isEmpty);
    expect(appdata.settings['comicSourceOrigins'], isEmpty);
    final saved =
        jsonDecode(File('${dataDir.path}/appdata.json').readAsStringSync())
            as Map;
    expect(saved['settings']['comicSourceRepositories'], isEmpty);
    expect(saved['settings']['comicSourceOrigins'], isEmpty);
  });

  test('migrates only the user configured legacy URL once', () async {
    appdata.settings['comicSourceListUrl'] =
        'https://personal.example/catalog.json';
    await SourceRepositories.instance.migrate();
    final first = SourceRepositories.instance.all.single;
    expect(first.url, 'https://personal.example/catalog.json');
    expect(appdata.settings['comicSourceOrigins'], isEmpty);
    await SourceRepositories.instance.migrate();
    expect(SourceRepositories.instance.all.single.id, first.id);
    appdata.settings['comicSourceRepositories'] = <Map<String, dynamic>>[];
    await SourceRepositories.instance.migrate();
    expect(SourceRepositories.instance.all, isEmpty);
  });

  test('preserves explicit repositories and every existing origin', () async {
    final repositories = [
      const SourceRepository(
        id: 'personal',
        name: 'Personal',
        url: 'https://personal.example/index.json',
      ).toJson(),
    ];
    final origins = {
      'jm': {'kind': 'url', 'url': 'https://personal.example/jm.js'},
      'baozi': {'kind': 'file', 'url': '/tmp/baozi.js'},
      'copy_manga': {'kind': 'repository', 'repositoryId': 'gone'},
      'custom': {'kind': 'repository', 'repositoryId': 'personal'},
    };
    appdata.settings['comicSourceRepositories'] = repositories;
    appdata.settings['comicSourceOrigins'] = origins;
    appdata.settings['comicSourceListUrl'] = 'https://old.example/index.json';
    await SourceRepositories.instance.migrate();
    expect(appdata.settings['comicSourceRepositories'], repositories);
    expect(appdata.settings['comicSourceOrigins'], origins);
  });

  test(
    'retains previously saved repository configuration without rebinding',
    () async {
      final repositories = [
        const SourceRepository(
          id: 'venera-selfhost',
          name: 'Saved',
          url: 'https://saved.example/catalog.json',
        ).toJson(),
      ];
      appdata.settings['comicSourceRepositories'] = repositories;
      appdata.settings['comicSourceSelfhostMigrated'] = true;
      await SourceRepositories.instance.migrate();
      expect(appdata.settings['comicSourceRepositories'], repositories);
      expect(appdata.settings['comicSourceOrigins'], isEmpty);
    },
  );
}
