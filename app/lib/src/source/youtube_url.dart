/// YouTube URL에서 11자리 동영상 ID를 추출한다. YouTube 링크가 아니면 null.
///
/// 지원: watch?v=, youtu.be/, shorts/, embed/, live/, m./music. 서브도메인, ID 단독 입력.
String? parseYoutubeId(String input) {
  final s = input.trim();
  final idRe = RegExp(r'^[A-Za-z0-9_-]{11}$');
  if (idRe.hasMatch(s)) return s;

  final uri = Uri.tryParse(s.contains('://') ? s : 'https://$s');
  if (uri == null) return null;
  final host = uri.host.toLowerCase().replaceFirst(
    RegExp(r'^(www|m|music)\.'),
    '',
  );

  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.firstOrNull;
  } else if (host == 'youtube.com' || host == 'youtube-nocookie.com') {
    final seg = uri.pathSegments;
    if (seg.firstOrNull == 'watch') {
      id = uri.queryParameters['v'];
    } else if (seg.length >= 2 &&
        const {'shorts', 'embed', 'live', 'v'}.contains(seg[0])) {
      id = seg[1];
    }
  }
  return (id != null && idRe.hasMatch(id)) ? id : null;
}

String youtubeWatchUrl(String id) => 'https://www.youtube.com/watch?v=$id';
