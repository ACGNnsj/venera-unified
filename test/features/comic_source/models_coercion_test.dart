import 'package:flutter_test/flutter_test.dart';
import 'package:venera_unified/features/comic_source/models.dart';

void main() {
  group('Comment.fromJson', () {
    test('数字与字符串互转，不抛异常', () {
      final comment = Comment.fromJson({
        'userName': 123,
        'content': 45.6,
        'replyCount': '7',
        'id': null,
        'isLiked': '1',
        'voteStatus': '1',
      });

      expect(comment.userName, '123');
      expect(comment.content, '45.6');
      expect(comment.replyCount, 7);
      expect(comment.id, isNull);
      expect(comment.isLiked, isTrue);
      expect(comment.voteStatus, 1);
    });

    test('字段里塞回调函数时判为无效结果并抛', () {
      expect(
        () => Comment.fromJson({'userName': () => 1, 'content': 'x'}),
        throwsArgumentError,
      );
    });
  });

  group('Comic.fromJson', () {
    test('标签给字符串、评分与页数给字符串时仍然可用', () {
      final comic = Comic.fromJson({
        'title': 42,
        'tags': 'action, comedy',
        'stars': '4.5',
        'maxPage': '12',
        'id': 7,
      }, 'source');

      expect(comic.title, '42');
      expect(comic.tags, ['action', 'comedy']);
      expect(comic.stars, 4.5);
      expect(comic.maxPage, 12);
      expect(comic.id, '7');
    });

    test('标签给非列表非字符串时退化成空列表', () {
      final comic = Comic.fromJson({'title': 't', 'tags': 3}, 'source');
      expect(comic.tags, isEmpty);
    });

    test('标签给回调函数时判为无效结果并抛', () {
      expect(
        () => Comic.fromJson({'title': 't', 'tags': () => 1}, 'source'),
        throwsArgumentError,
      );
    });
  });

  group('ComicDetails.fromJson', () {
    test('标签、缩略图、推荐、评论类型写错时不崩', () {
      final details = ComicDetails.fromJson({
        'title': 't',
        'cover': 'c',
        'sourceKey': 's',
        'comicId': 7,
        'tags': {'tag': 'a,b'},
        'thumbnails': 'only.png',
        'recommend': 'not a list',
        'comments': [
          {'userName': 1, 'content': 'c'},
          'garbage',
        ],
      });

      expect(details.comicId, '7');
      expect(details.tags['tag'], ['a', 'b']);
      expect(details.thumbnails, ['only.png']);
      expect(details.recommend, isNull);
      expect(details.comments, hasLength(2));
      expect(details.comments![0].userName, '1');
      // 非 Map 的评论退化成空评论，而不是让整个详情页崩掉。
      expect(details.comments![1].userName, '');
    });
  });

  group('ComicChapters.fromJson', () {
    test('null 与标量返回空章节，回调这类非数据值算无效结果', () {
      expect(ComicChapters.fromJson(null).length, 0);
      expect(ComicChapters.fromJson('nope').length, 0);
      expect(() => ComicChapters.fromJson(() => 1), throwsArgumentError);
    });

    test('键与值类型不标准时按字符串归一', () {
      final chapters = ComicChapters.fromJson({1: 'first', '二': 2});
      expect(chapters.length, 2);
      expect(chapters.allChapters['1'], 'first');
      expect(chapters.allChapters['二'], '2');
    });

    test('分组里跳过空值', () {
      final chapters = ComicChapters.fromJson({
        'group': {'a': null, 'b': 'B'},
      });
      expect(chapters.isGrouped, isTrue);
      expect(chapters.allChapters.length, 1);
      expect(chapters.allChapters['b'], 'B');
    });
  });
}
