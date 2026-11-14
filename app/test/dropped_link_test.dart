import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/dropped_link.dart';

void main() {
  const watch = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

  test('브라우저에서 끌어 온 YouTube 링크', () {
    expect(pickDropped(['$watch&t=30s']).youtube, watch);
    expect(pickDropped(['https://youtu.be/dQw4w9WgXcQ?si=abc']).youtube, watch);
    // 주소 뒤에 제목이 붙어 오는 브라우저
    expect(pickDropped(['$watch\nSome Video Title']).youtube, watch);
  });

  test('동영상 파일', () {
    expect(
      pickDropped(['/Users/me/Movies/a.mkv']).file,
      '/Users/me/Movies/a.mkv',
    );
    expect(pickDropped([r'C:\Videos\b.MP4']).file, r'C:\Videos\b.MP4');
    // 링크와 파일이 같이 오면 링크
    expect(pickDropped(['/a.mp4', watch]), (youtube: watch, file: null));
  });

  test('열 수 없는 것은 무시', () {
    const none = (youtube: null, file: null);
    expect(pickDropped(['https://example.com/watch?v=dQw4w9WgXcQ']), none);
    expect(pickDropped(['dQw4w9WgXcQ']), none); // 11자리 글자일 뿐
    expect(pickDropped(['/Users/me/notes.txt']), none);
    expect(pickDropped(['https://example.com/a.mp4']), none);
    expect(pickDropped([]), none);
  });
}
