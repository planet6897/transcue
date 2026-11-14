import '../source/youtube_url.dart';
import 'playlist.dart';

/// 창 위에 끌어다 놓은 것에서 열 대상을 고른다.
///
/// [items]는 OS가 준 그대로: 파일은 경로, 브라우저에서 끌어 온 링크는 주소
/// (브라우저에 따라 "주소\n제목"처럼 글이 붙어 오기도 한다).
/// YouTube 링크가 있으면 그 주소, 없으면 첫 동영상 파일 경로를 돌려준다.
({String? youtube, String? file}) pickDropped(List<String> items) {
  for (final item in items) {
    for (final word in item.split(RegExp(r'\s+'))) {
      // 11자리 글자만으로도 ID로 읽히므로 주소 모양일 때만 본다
      if (!word.contains('youtu')) continue;
      final id = parseYoutubeId(word);
      if (id != null) return (youtube: youtubeWatchUrl(id), file: null);
    }
  }
  for (final item in items) {
    final path = item.trim();
    if (!path.contains('://') &&
        isVideoFile(path.split(RegExp(r'[/\\]')).last)) {
      return (youtube: null, file: path);
    }
  }
  return (youtube: null, file: null);
}
