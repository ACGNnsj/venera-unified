import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/foundation/comic_type.dart';
import 'package:venera_unified/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera_unified/foundation/image_translation/translation_types.dart';

PreTranslationTask _task(List<PreTranslationChapter> chapters) {
  return PreTranslationTask(
    id: 'task-1',
    cid: 'cid-1',
    sourceKey: 'test-source',
    comicType: const ComicType(0),
    title: 'Test Comic',
    chapters: chapters,
    createdAt: DateTime(2024, 1, 1),
  );
}

void main() {
  group('PreTranslationChapter json', () {
    test('roundtrip keeps counters and failedPages', () {
      final chapter = PreTranslationChapter(
        eid: 'e1',
        title: 'Chapter 1',
        total: 10,
        done: 4,
        failed: 2,
        failedPages: {4, 5},
      );
      final restored = PreTranslationChapter.fromJson(
        Map<String, dynamic>.from(chapter.toJson()),
      );
      expect(restored.eid, 'e1');
      expect(restored.title, 'Chapter 1');
      expect(restored.total, 10);
      expect(restored.done, 4);
      expect(restored.failed, 2);
      expect(restored.failedPages, {4, 5});
    });

    test('fromJson tolerates missing fields', () {
      final restored = PreTranslationChapter.fromJson({});
      expect(restored.eid, '0');
      expect(restored.title, '');
      expect(restored.total, 0);
      expect(restored.failedPages, isEmpty);
    });
  });

  group('PreTranslationTask progress', () {
    test('weights chapters equally and ignores unresolved totals', () {
      final task = _task([
        PreTranslationChapter(eid: 'e1', title: 'c1', total: 10, done: 5),
        PreTranslationChapter(eid: 'e2', title: 'c2', total: 10, done: 10),
      ]);
      // (0.5 + 1.0) / 2 = 0.75
      expect(task.progress, closeTo(0.75, 1e-9));
      expect(task.total, 20);
      expect(task.done, 15);
      expect(task.comicKey, 'cid-1@test-source');
      expect(task.isRunning, isTrue);
    });

    test('empty chapters progress is zero', () {
      expect(_task([]).progress, 0);
    });

    test('hasFailures excludes canceled chapters', () {
      final withFailures = _task([
        PreTranslationChapter(eid: 'e1', title: 'c1', total: 4, failed: 1),
      ]);
      expect(withFailures.hasFailures, isTrue);
      final canceled = _task([
        PreTranslationChapter(
          eid: 'e1',
          title: 'c1',
          total: 4,
          failed: 1,
          canceled: true,
        ),
      ]);
      expect(canceled.hasFailures, isFalse);
    });

    test('task json roundtrip', () {
      final task = _task([
        PreTranslationChapter(
          eid: 'e1',
          title: 'c1',
          total: 3,
          done: 1,
          failed: 1,
          failedPages: {2},
        ),
      ]);
      final restored = PreTranslationTask.fromJson(
        Map<String, dynamic>.from(task.toJson()),
      );
      expect(restored.id, task.id);
      expect(restored.cid, task.cid);
      expect(restored.sourceKey, task.sourceKey);
      expect(restored.chapters.length, 1);
      expect(restored.chapters.single.failedPages, {2});
    });
  });

  group('PreTranslationActivity live counters', () {
    test('liveDone/liveFailed credit buffered pages', () {
      final task = _task([
        PreTranslationChapter(
          eid: 'e1',
          title: 'c1',
          total: 10,
          done: 3,
          failed: 1,
        ),
      ]);
      final activity = PreTranslationActivity()
        ..bufferedDone = 2
        ..bufferedFailed = 1;
      expect(activity.liveDone(task), 5);
      expect(activity.liveFailed(task), 2);
      expect(activity.liveProcessed(task), 7);
    });

    test('headStage picks lowest group index', () {
      final activity = PreTranslationActivity();
      activity.groups[1] = PreTranslationGroupActivity(index: 1, pageCount: 4)
        ..stage = TranslationStage.translating;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..stage = TranslationStage.fetching;
      expect(activity.headStage, TranslationStage.fetching);
      expect(activity.stageCounts[TranslationStage.fetching], 1);
      expect(activity.stageCounts[TranslationStage.translating], 1);
    });

    test('liveProgress adds uncommitted pages of running chapter', () {
      final task = _task([
        PreTranslationChapter(eid: 'e1', title: 'c1', total: 10, done: 2),
        PreTranslationChapter(eid: 'e2', title: 'c2', total: 10, done: 10),
      ]);
      // base = (0.2 + 1.0) / 2 = 0.6
      final activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = 'e1'
        ..bufferedDone = 2;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 1.0;
      final live = activity.liveProgress(task);
      // extra = (2 + 1.0) / 10 = 0.3 -> 0.6 + 0.3 / 2 = 0.75
      expect(live, closeTo(0.75, 1e-9));
      expect(live, greaterThanOrEqualTo(task.progress));
    });
  });

  group('PreTranslationTaskManager.livePagesFor', () {
    test('credits buffered pages only for matching chapter', () {
      final chapter = PreTranslationChapter(
        eid: 'e1',
        title: 'c1',
        total: 10,
        done: 3,
        failed: 1,
      );
      final matching = PreTranslationActivity()
        ..chapterEid = 'e1'
        ..bufferedDone = 2
        ..bufferedFailed = 1;
      expect(PreTranslationTaskManager.livePagesFor(chapter, matching), (
        done: 5,
        processed: 7,
      ));
      final other = PreTranslationActivity()
        ..chapterEid = 'e2'
        ..bufferedDone = 5;
      expect(PreTranslationTaskManager.livePagesFor(chapter, other), (
        done: 3,
        processed: 4,
      ));
      expect(PreTranslationTaskManager.livePagesFor(chapter, null), (
        done: 3,
        processed: 4,
      ));
    });
  });
}
