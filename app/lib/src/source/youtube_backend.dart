import 'dart:io';

import '../pipeline/tools.dart' show hasDesktopTools;
import 'yt_dlp.dart';

/// YouTube 영상·자막·목록을 받는 쪽. 데스크톱은 yt-dlp([YtDlp]),
/// Android는 순수 Dart 구현(DartYoutube)을 쓴다.
abstract interface class YoutubeBackend {
  /// 재생할 영상·소리 주소와 자막 트랙
  Future<YoutubeMedia> resolve(String url);

  /// 자막을 WebVTT 텍스트로
  Future<String> fetchCaption(YoutubeMedia media, CaptionTrack track);

  /// 채널·재생목록·검색 목록 (yt-dlp `--flat-playlist -J` 모양, [start]~[end] 1부터 끝 포함)
  Future<Map<String, dynamic>> listPlaylist(
    String url, {
    required int start,
    required int end,
  });
}

/// 이 기기에서 YouTube를 열 수 있는지 (데스크톱 yt-dlp, Android 순수 Dart)
final bool canUseYoutube = hasDesktopTools || Platform.isAndroid;
