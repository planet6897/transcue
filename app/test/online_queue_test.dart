import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/online_queue.dart';
import 'package:transcue/src/source/ted_catalog.dart';

TedVideo v(String id) => TedVideo(id: id.padRight(11, '_'), title: 'Talk $id');

void main() {
  final videos = [v('a'), v('b'), v('c')];

  test('다음·이전 영상, 목록 끝이면 없음', () {
    final q = OnlineQueue(videos, 1);
    expect(q.current.title, 'Talk b');
    expect(q.neighbor(1)?.title, 'Talk c');
    expect(q.neighbor(-1)?.title, 'Talk a');
    q.index = 2;
    expect(q.neighbor(1), isNull);
    q.index = 0;
    expect(q.neighbor(-1), isNull);
  });

  test('목록에 있는 영상을 다시 열면 그 자리로, 없으면 false', () {
    final q = OnlineQueue(videos, 0);
    expect(q.moveTo('c'.padRight(11, '_')), isTrue);
    expect(q.index, 2);
    expect(q.moveTo('zzzzzzzzzzz'), isFalse);
    expect(q.index, 2);
  });

  test('고른 뒤 원래 목록이 바뀌어도 순서는 그대로', () {
    final list = [v('a'), v('b')];
    final q = OnlineQueue(list, 0);
    list.insert(0, v('new'));
    expect(q.neighbor(1)?.title, 'Talk b');
    expect(() => OnlineQueue(list, 5), throwsRangeError);
  });
}
