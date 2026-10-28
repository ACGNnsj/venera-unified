import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_unified/features/favorites/favorite_models.dart';
import 'package:venera_unified/features/favorites/favorites_repository.dart';
import 'package:venera_unified/foundation/comic_type.dart';

void main() {
  late Database db;
  late FavoritesRepository repository;

  FavoriteItem item() => FavoriteItem(
    id: 'c1',
    name: 'Title',
    coverPath: 'cover',
    author: 'author',
    type: const ComicType(1),
    tags: const ['a'],
  );

  Map<String, Object?> trackingRow() => Map<String, Object?>.from(
    db.select(
      'SELECT last_update_time, has_new_update, last_check_time, chapter_count FROM tracking WHERE id = ? AND type = ?;',
      ['c1', 1],
    ).first,
  );

  setUp(() {
    db = sqlite3.openInMemory();
    repository = FavoritesRepository(db);
    db.execute('''CREATE TABLE tracking (
      id TEXT, type INT, name TEXT, author TEXT, tags TEXT,
      cover_path TEXT, time TEXT, display_order INT,
      PRIMARY KEY (id, type)
    );''');
    db.execute(
      "INSERT INTO tracking VALUES ('c1', 1, 'Title', 'author', 'a', 'cover', 'old time', 0);",
    );
    repository.prepareForFollowUpdates('tracking', clearData: false);
  });
  tearDown(() => db.dispose());

  test('present updateTime keeps the original time-only logic', () {
    // Changed time flags, unchanged time does not — even with a bigger count.
    expect(
      repository.applyFollowUpdate(
        'tracking',
        item(),
        '2026-01-02',
        100,
        chapterCount: 5,
      ),
      isTrue,
    );
    expect(trackingRow()['has_new_update'], 1);
    expect(trackingRow()['last_update_time'], '2026-01-02');
    expect(
      repository.applyFollowUpdate(
        'tracking',
        item(),
        '2026-01-02',
        200,
        chapterCount: 9,
      ),
      isFalse,
    );
    // No dual-signal OR: a bigger count alone never flags when time is known.
    expect(trackingRow()['last_check_time'], 200);
  });

  test('missing updateTime with a bigger count flags and rebaselines', () {
    db.execute('UPDATE tracking SET chapter_count = 5;');
    expect(
      repository.applyFollowUpdate(
        'tracking',
        item(),
        null,
        100,
        chapterCount: 7,
      ),
      isTrue,
    );
    final row = trackingRow();
    expect(row['has_new_update'], 1);
    expect(row['chapter_count'], 7);
    expect(row['last_check_time'], 100);
    expect(row['last_update_time'], isNull);
  });

  test('missing updateTime with an unchanged count preserves the flag', () {
    db.execute(
      'UPDATE tracking SET chapter_count = 5, has_new_update = 1, last_check_time = 50;',
    );
    expect(
      repository.applyFollowUpdate(
        'tracking',
        item(),
        null,
        100,
        chapterCount: 5,
      ),
      isFalse,
    );
    final row = trackingRow();
    expect(row['has_new_update'], 1);
    expect(row['chapter_count'], 5);
    expect(row['last_check_time'], 100);
  });

  test('missing updateTime and count keeps the old silent behavior', () {
    expect(
      repository.applyFollowUpdate('tracking', item(), null, 100),
      isFalse,
    );
    expect(trackingRow()['has_new_update'], isNull);
    expect(trackingRow()['last_check_time'], 100);
  });

  test('first sighting without a stored count flags once like lll', () {
    expect(
      repository.applyFollowUpdate(
        'tracking',
        item(),
        null,
        100,
        chapterCount: 3,
      ),
      isTrue,
    );
    expect(trackingRow()['chapter_count'], 3);
    // The rebaselined count makes the next identical check silent.
    expect(
      repository.applyFollowUpdate(
        'tracking',
        item(),
        null,
        200,
        chapterCount: 3,
      ),
      isFalse,
    );
  });

  test('a shrinking count does not flag but still rebaselines', () {
    db.execute('UPDATE tracking SET chapter_count = 7;');
    expect(
      repository.applyFollowUpdate(
        'tracking',
        item(),
        null,
        100,
        chapterCount: 4,
      ),
      isFalse,
    );
    expect(trackingRow()['chapter_count'], 4);
    expect(trackingRow()['has_new_update'], isNull);
  });

  test('prepare adds chapter_count and old tables report unprepared', () {
    db.execute('''CREATE TABLE legacy (
      id TEXT, type INT, name TEXT, author TEXT, tags TEXT,
      cover_path TEXT, time TEXT, display_order INT,
      last_update_time TEXT, has_new_update INT, last_check_time INT,
      PRIMARY KEY (id, type)
    );''');
    // A table prepared before this feature lacks chapter_count.
    expect(repository.isPreparedForFollowUpdates('legacy'), isFalse);
    expect(repository.isPreparedForFollowUpdates('tracking'), isTrue);
    repository.prepareForFollowUpdates('legacy', clearData: false);
    expect(repository.isPreparedForFollowUpdates('legacy'), isTrue);
    final columns = db
        .select('PRAGMA table_info("legacy");')
        .map((row) => row['name'] as String)
        .toSet();
    expect(columns.contains('chapter_count'), isTrue);
    // Re-running prepare is idempotent.
    repository.prepareForFollowUpdates('legacy', clearData: false);
    expect(repository.isPreparedForFollowUpdates('legacy'), isTrue);
  });
}
