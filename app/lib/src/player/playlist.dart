import 'dart:io';

/// 연속 재생: 같은 폴더(다음 시즌 폴더까지)의 앞/뒤 동영상을 찾는다.
const videoExtensions = {'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'};

bool isVideoFile(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || name.startsWith('.')) return false; // ._xxx 등 숨김 파일 제외
  return videoExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// 사람이 기대하는 순서로 비교 (E2 < E10, Season 9 < Season 10)
int naturalCompare(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final pa = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final pb = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final x = pa[i], y = pb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null)
        ? (nx != ny ? nx.compareTo(ny) : x.length.compareTo(y.length))
        : x.compareTo(y);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

/// [names] 중 [current] 다음(delta=1)/이전(delta=-1) 동영상 이름. 없으면 null.
String? neighborName(List<String> names, String current, int delta) {
  final videos = names.where(isVideoFile).toList()..sort(naturalCompare);
  final i = videos.indexOf(current);
  if (i < 0) return null;
  final j = i + delta;
  return j >= 0 && j < videos.length ? videos[j] : null;
}

String _sep() => Platform.pathSeparator;

/// 마지막 구분자 위치. Windows는 `\` 와 `/` 를 모두 쓸 수 있다.
int _lastSep(String path) {
  final a = path.lastIndexOf('/');
  final b = Platform.isWindows ? path.lastIndexOf(r'\') : -1;
  return a > b ? a : b;
}

String _name(String path) => path.substring(_lastSep(path) + 1);

String _parent(String path) {
  final i = _lastSep(path);
  return i < 0 ? '' : path.substring(0, i);
}

List<String> _list(String dir, {required bool dirs}) {
  try {
    return [
      for (final e in Directory(dir).listSync(followLinks: true))
        if ((e is Directory) == dirs) _name(e.path),
    ];
  } on FileSystemException {
    return const [];
  }
}

/// 다음/이전 동영상 경로.
/// 폴더 끝이면 옆 폴더(예: Season 1 → Season 2)의 첫(이전이면 마지막) 동영상.
String? neighborVideo(String path, {int delta = 1}) {
  final dir = _parent(path);
  final inDir = neighborName(_list(dir, dirs: false), _name(path), delta);
  if (inDir != null) return '$dir${_sep()}$inDir';

  // 옆 폴더로 넘어가기 (한 단계만)
  final parent = _parent(dir);
  if (parent.isEmpty) return null;
  final siblings = _list(parent, dirs: true)
    ..removeWhere((n) => n.startsWith('.'))
    ..sort(naturalCompare);
  final here = siblings.indexOf(_name(dir));
  if (here < 0) return null;
  for (var i = here + delta; i >= 0 && i < siblings.length; i += delta) {
    final d = '$parent${_sep()}${siblings[i]}';
    final videos = _list(d, dirs: false).where(isVideoFile).toList()
      ..sort(naturalCompare);
    if (videos.isNotEmpty) {
      return '$d${_sep()}${delta > 0 ? videos.first : videos.last}';
    }
  }
  return null;
}
