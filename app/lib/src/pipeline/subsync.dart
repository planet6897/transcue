import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../subtitle/bilingual_cue.dart';
import 'tools.dart';

/// 자막 싱크 자동 보정.
///
/// 음성 구간(VAD)과 자막 구간이 가장 많이 겹치는 시간 변환 `t' = t × scale + offset`을 찾는다.
/// - offset: 앞뒤로 밀림 (광고/인트로 길이 차이 등)
/// - scale: 프레임레이트 차이 (23.976 ↔ 25fps 릴리스 등)
/// ffsubsync와 같은 아이디어를 의존성 없이 구현.
class SyncResult {
  const SyncResult({
    required this.offset,
    required this.scale,
    required this.score,
    required this.baseScore,
    required this.total,
  });

  final Duration offset;
  final double scale;

  /// 맞춘 뒤 / 맞추기 전 점수 (자막 시간 중 말소리와 겹친 정도, -total ~ +total)
  final double score;
  final double baseScore;
  final double total;

  /// 0.3초 미만은 측정 오차 수준이라 건드리지 않는다
  /// (실측: 이미 맞는 자막에서 VAD와 약 0.2초 차이)
  bool get isIdentity => scale == 1.0 && offset.inMilliseconds.abs() < 300;

  /// 의미 있게 좋아졌는지 (자막 전체 길이의 3% 이상 개선)
  bool get improves => !isIdentity && score - baseScore > total * 0.03;

  String describe() {
    final s = offset.inMilliseconds / 1000;
    final o = '${s >= 0 ? '+' : ''}${s.toStringAsFixed(1)}초';
    return scale == 1.0 ? o : '$o, 속도 ×${scale.toStringAsFixed(4)}';
  }
}

/// whisper-vad-speech-segments 출력 해석 (단위: 1/100초) → 밀리초 구간
List<(int, int)> parseVadSegments(String out) {
  final re = RegExp(r'start\s*=\s*([\d.]+),\s*end\s*=\s*([\d.]+)');
  return [
    for (final m in re.allMatches(out))
      ((double.parse(m[1]!) * 10).round(), (double.parse(m[2]!) * 10).round()),
  ];
}

/// 음성 구간 검출 (Silero VAD)
Future<List<(int, int)>> detectSpeech(String wavPath, File vadModel) async {
  final exe = await findTool(
    'whisper-vad-speech-segments',
    install: whisperInstallHint,
  );
  final r = await Process.run(exe, [
    '-f',
    wavPath,
    '-vm',
    vadModel.path,
    '-np',
  ], stdoutEncoding: lenientUtf8);
  if (r.exitCode != 0) {
    throw ProcessException(exe, [], '${r.stderr}'.trim(), r.exitCode);
  }
  return parseVadSegments('${r.stdout}\n${r.stderr}');
}

/// 프레임레이트 변환 후보: 자막 시간 × scale
const _scales = [
  1.0,
  25 / 23.976,
  23.976 / 25,
  24 / 23.976,
  23.976 / 24,
  25 / 24,
  24 / 25,
];

const _binMs = 10;

/// 가장 잘 맞는 변환을 찾는다.
SyncResult findBestSync(
  List<BilingualCue> cues,
  List<(int, int)> speech, {
  Duration maxOffset = const Duration(minutes: 2),
}) {
  final total = cues.fold<double>(
    0,
    (a, c) => a + (c.end - c.start).inMilliseconds,
  );
  if (cues.isEmpty || speech.isEmpty) {
    return SyncResult(
      offset: Duration.zero,
      scale: 1,
      score: 0,
      baseScore: 0,
      total: total,
    );
  }

  // 말소리 누적합 (10ms 단위): prefix[i] = 0..i 구간의 말소리 길이
  final endMs =
      math.max(speech.last.$2, cues.last.end.inMilliseconds) +
      maxOffset.inMilliseconds * 2 +
      60000;
  final n = endMs ~/ _binMs + 2;
  final on = Uint8List(n);
  for (final (s, e) in speech) {
    for (
      var i = (s ~/ _binMs).clamp(0, n - 1);
      i < (e ~/ _binMs).clamp(0, n - 1);
      i++
    ) {
      on[i] = 1;
    }
  }
  final prefix = Int32List(n + 1);
  for (var i = 0; i < n; i++) {
    prefix[i + 1] = prefix[i] + on[i];
  }
  int speechIn(int fromMs, int toMs) {
    final a = (fromMs ~/ _binMs).clamp(0, n);
    final b = (toMs ~/ _binMs).clamp(0, n);
    return b > a ? prefix[b] - prefix[a] : 0;
  }

  final starts = [for (final c in cues) c.start.inMilliseconds];
  final ends = [for (final c in cues) c.end.inMilliseconds];

  // 점수 = Σ(말소리와 겹친 자막 시간 − 말소리 없는 자막 시간)
  double score(double scale, int offsetMs) {
    var s = 0;
    for (var i = 0; i < starts.length; i++) {
      final a = (starts[i] * scale).round() + offsetMs;
      final b = (ends[i] * scale).round() + offsetMs;
      final len = (b - a) ~/ _binMs;
      s += 2 * speechIn(a, b) - len;
    }
    return s * _binMs.toDouble();
  }

  final base = score(1, 0);
  var best = (scale: 1.0, offset: 0, score: base);
  final maxOff = maxOffset.inMilliseconds;
  for (final sc in _scales) {
    // 1단계: 100ms 간격으로 넓게
    var local = (offset: 0, score: double.negativeInfinity);
    for (var off = -maxOff; off <= maxOff; off += 100) {
      final v = score(sc, off);
      if (v > local.score) local = (offset: off, score: v);
    }
    // 2단계: 주변 ±100ms를 10ms 간격으로
    for (var off = local.offset - 100; off <= local.offset + 100; off += 10) {
      final v = score(sc, off);
      if (v > local.score) local = (offset: off, score: v);
    }
    if (local.score > best.score) {
      best = (scale: sc, offset: local.offset, score: local.score);
    }
  }
  return SyncResult(
    offset: Duration(milliseconds: best.offset),
    scale: best.scale,
    score: best.score,
    baseScore: base,
    total: total,
  );
}

/// 자막 길이가 영상과 맞는지 (다른 작품/편집본 자막 걸러내기).
/// 자막이 영상 끝을 크게 넘거나, 긴 영상의 절반도 안 덮으면 false.
/// 실사례: 14분 영상에 105분짜리 자막.
bool fitsDuration(List<BilingualCue> cues, Duration video) {
  if (cues.isEmpty || video <= Duration.zero) return true;
  final last = cues.map((c) => c.end).reduce((a, b) => a > b ? a : b);
  if (last > video * 1.1 + const Duration(minutes: 1)) return false;
  if (video > const Duration(minutes: 10) && last < video * 0.5) return false;
  return true;
}

/// 변환 적용 (번역은 그대로 유지)
List<BilingualCue> applySync(List<BilingualCue> cues, SyncResult r) =>
    shiftCues(cues, r.offset, scale: r.scale);

List<BilingualCue> shiftCues(
  List<BilingualCue> cues,
  Duration offset, {
  double scale = 1.0,
}) {
  Duration f(Duration t) {
    final ms = (t.inMilliseconds * scale).round() + offset.inMilliseconds;
    return Duration(milliseconds: math.max(0, ms));
  }

  return [for (final c in cues) c.withTimes(f(c.start), f(c.end))];
}
