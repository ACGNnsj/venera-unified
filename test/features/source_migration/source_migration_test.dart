import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/comic_source_api.dart';
import 'package:venera_unified/features/favorites/favorites.dart';
import 'package:venera_unified/features/history/history.dart';
import 'package:venera_unified/features/source_migration/source_migration_tasks.dart';
import 'package:venera_unified/foundation/comic_type.dart';
import 'package:venera_unified/foundation/res.dart';

FavoriteItem _favorite({
  String id = 's1',
  String name = 'My Comic',
  String source = 'jm',
}) {
  return FavoriteItem(
    id: id,
    name: name,
    coverPath: 'cover',
    author: 'author',
    type: ComicType.fromKey(source),
    tags: const ['tag'],
  );
}

Comic _comic({
  String title = 'My Comic',
  String id = 't1',
  String sourceKey = 'picacg',
  String? subtitle = 'sub',
  List<String>? tags = const ['a'],
}) {
  return Comic(title, 'cover', id, subtitle, tags, '', sourceKey, null, null);
}

void main() {
  group('normalizeMigrationTitle', () {
    test('lowercases and strips whitespace and punctuation', () {
      expect(normalizeMigrationTitle('  My, Comic! '), 'mycomic');
      expect(normalizeMigrationTitle('MY　COMIC'), 'mycomic');
    });

    test('strips CJK brackets and symbols', () {
      expect(normalizeMigrationTitle('《我的漫画》'), '我的漫画');
      expect(normalizeMigrationTitle('【汉化】我的漫画'), '汉化我的漫画');
    });

    test('keeps distinct titles distinct', () {
      expect(
        normalizeMigrationTitle('Comic A'),
        isNot(normalizeMigrationTitle('Comic B')),
      );
    });
  });

  group('matchTitleInResults', () {
    test('returns the first normalized exact match', () {
      final results = [
        _comic(title: 'Other Title', id: 'x'),
        _comic(title: '  my, COMIC! ', id: 'hit'),
      ];
      final match = matchTitleInResults('My Comic', results);
      expect(match?.id, 'hit');
    });

    test('returns null when nothing matches exactly (no first fallback)', () {
      final results = [
        _comic(title: 'My Comic Extra Story', id: 'x'),
        _comic(title: 'My Comic 2', id: 'y'),
      ];
      expect(matchTitleInResults('My Comic', results), isNull);
    });

    test('returns null for empty results', () {
      expect(matchTitleInResults('My Comic', const []), isNull);
    });
  });

  group('findMigrationMatchInData', () {
    test('maps the matched comic to a favorite item', () async {
      final data = SearchPageData(null, (keyword, page, options) async {
        expect(keyword, 'My Comic');
        expect(page, 1);
        return Res([
          _comic(title: 'Unrelated', id: 'u'),
          _comic(title: 'My Comic', id: 't9'),
        ]);
      }, null);
      final target = await findMigrationMatchInData(_favorite(), data);
      expect(target, isNotNull);
      expect(target!.id, 't9');
      expect(target.name, 'My Comic');
      expect(target.coverPath, 'cover');
      expect(target.author, 'sub');
      expect(target.type.value, ComicType.fromKey('picacg').value);
      expect(target.tags, ['a']);
    });

    test('returns null when no exact match', () async {
      final data = SearchPageData(null, (keyword, page, options) async {
        return Res([_comic(title: 'Something Else', id: 'u')]);
      }, null);
      expect(await findMigrationMatchInData(_favorite(), data), isNull);
    });

    test('returns null for empty results', () async {
      final data = SearchPageData(null, (keyword, page, options) async {
        return const Res(<Comic>[]);
      }, null);
      expect(await findMigrationMatchInData(_favorite(), data), isNull);
    });

    test('supports loadNext-only sources', () async {
      final data = SearchPageData(null, null, (keyword, next, options) async {
        expect(next, isNull);
        return Res([_comic(title: 'My Comic', id: 'n1')]);
      });
      final target = await findMigrationMatchInData(_favorite(), data);
      expect(target?.id, 'n1');
    });
  });

  group('verifyMigrationTargetReadable', () {
    test('completes when details load', () async {
      await verifyMigrationTargetReadable(
        () async => const Res<ComicDetails>(null),
      );
    });

    test('throws the load error message', () async {
      await expectLater(
        verifyMigrationTargetReadable(
          () async => const Res<ComicDetails>.error('banned'),
        ),
        throwsA('banned'),
      );
    });
  });

  group('favoriteItemFromComic', () {
    test('maps fields with empty fallbacks', () {
      final item = favoriteItemFromComic(_comic(subtitle: null, tags: null));
      expect(item.id, 't1');
      expect(item.name, 'My Comic');
      expect(item.coverPath, 'cover');
      expect(item.author, '');
      expect(item.type.value, ComicType.fromKey('picacg').value);
      expect(item.tags, isEmpty);
    });
  });

  group('buildMigratedHistory', () {
    test('takes identity from target and progress from history', () {
      final source = _favorite(id: 's1', source: 'jm');
      final target = _favorite(id: 't2', name: 'Target Name', source: 'jm');
      final history = History(
        type: ComicType.fromKey('jm'),
        time: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        title: 'Old Title',
        subtitle: 'old sub',
        cover: 'old-cover',
        ep: 3,
        page: 12,
        id: 's1',
        readEpisode: {'1', '2'},
        maxPage: 40,
        readDurationMs: 5000,
        group: 2,
      );
      final migrated = buildMigratedHistory(
        source: source,
        target: target,
        history: history,
      );
      expect(migrated.id, 't2');
      expect(migrated.title, 'Target Name');
      expect(migrated.cover, 'cover');
      expect(migrated.ep, 3);
      expect(migrated.page, 12);
      expect(migrated.readEpisode, {'1', '2'});
      expect(migrated.maxPage, 40);
      expect(migrated.group, 2);
      expect(migrated.time.millisecondsSinceEpoch, 1700000000000);
    });
  });

  group('task JSON roundtrip', () {
    test('detail preserves target, status and error', () {
      final detail = SourceMigrationTaskDetail(
        source: _favorite(),
        target: _favorite(id: 't1'),
        status: 'matched',
        error: 'e',
      );
      final restored = SourceMigrationTaskDetail.fromJson(
        Map<String, dynamic>.from(detail.toJson()),
      );
      expect(restored.source.id, 's1');
      expect(restored.target?.id, 't1');
      expect(restored.status, 'matched');
      expect(restored.error, 'e');
    });

    test('Task preserves fields and counters', () {
      final task = SourceMigrationTask(
        id: 'task-1',
        folder: 'Default',
        targetSourceKeys: ['picacg'],
        targetSourceNames: ['Picacg'],
        createdAt: DateTime.utc(2026, 10, 29, 1, 2, 3),
        details: [
          SourceMigrationTaskDetail(source: _favorite(), status: 'migrated'),
        ],
        migrateHistory: true,
        replaceFavorite: false,
        confirmEach: true,
        status: SourceMigrationTaskStatus.waitingConfirmation,
        total: 4,
        checked: 2,
        migrated: 1,
        failed: 1,
        currentIndex: 2,
      );
      final restored = SourceMigrationTask.fromJson(
        Map<String, dynamic>.from(task.toJson()),
      );
      expect(restored.id, 'task-1');
      expect(restored.folder, 'Default');
      expect(restored.targetSourceKeys, ['picacg']);
      expect(restored.targetSourceNames, ['Picacg']);
      expect(restored.targetSourceName, 'Picacg');
      expect(restored.status, SourceMigrationTaskStatus.waitingConfirmation);
      expect(restored.isWaitingConfirmation, isTrue);
      expect(restored.isActive, isTrue);
      expect(restored.total, 4);
      expect(restored.checked, 2);
      expect(restored.migrated, 1);
      expect(restored.failed, 1);
      expect(restored.currentIndex, 2);
      expect(restored.progress, 0.5);
      expect(restored.details.single.status, 'migrated');
      expect(restored.migrateHistory, isTrue);
      expect(restored.replaceFavorite, isFalse);
      expect(restored.confirmEach, isTrue);
    });

    test('Task reads legacy single target keys', () {
      final restored = SourceMigrationTask.fromJson({
        'id': 'legacy',
        'folder': 'Default',
        'targetSourceKey': 'jm',
        'targetSourceName': 'JM',
        'createdAt': DateTime.utc(2026).toIso8601String(),
        'status': 'completed',
        'details': [],
      });
      expect(restored.targetSourceKeys, ['jm']);
      expect(restored.targetSourceNames, ['JM']);
      expect(restored.status, SourceMigrationTaskStatus.completed);
    });
  });
}
