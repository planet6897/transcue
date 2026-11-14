import '../source/ted_catalog.dart';

/// 채널 목록(TED 등)에서 고른 영상의 재생 순서.
/// 고를 때 화면에 보이던 순서(정렬·필터 적용)를 그대로 기억해, 연속 재생과
/// 이전/다음 영상(P/N)이 그 순서로 움직인다.
class OnlineQueue {
  OnlineQueue(List<TedVideo> videos, this.index)
    : videos = List.unmodifiable(videos) {
    RangeError.checkValidIndex(index, this.videos, 'index');
  }

  final List<TedVideo> videos;

  /// 지금 재생 중인 영상의 위치
  int index;

  TedVideo get current => videos[index];

  /// [delta]만큼 떨어진 영상 (1: 다음, -1: 이전). 목록 끝이면 null.
  TedVideo? neighbor(int delta) {
    final i = index + delta;
    return i >= 0 && i < videos.length ? videos[i] : null;
  }

  /// [id] 영상을 열 때: 목록에 있으면 그 위치로 옮기고 true, 없으면 false.
  bool moveTo(String id) {
    final i = videos.indexWhere((v) => v.id == id);
    if (i < 0) return false;
    index = i;
    return true;
  }
}
