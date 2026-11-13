import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../subtitle/bilingual_cue.dart';
import 'tools.dart';
import 'whisper.dart' show SttCue, SttEvent;

/// parakeet-cli `-ps` 출력의 토큰 줄
/// `[ 3] id= 7883 frame= 14 ... t0=  96 t1=  96 word_start=false "."`
final _tokenRe = RegExp(
  r't0=\s*(\d+)\s+t1=\s*(\d+)\s+word_start=(true|false)\s+"(.*)"\s*$',
);

/// 문장 사이가 이만큼 비면 줄을 나눈다
const _gapMs = 1200;

/// 쉼표에서 나눌 수 있는 길이, 어디서든 나누는 길이 (자막 한 줄이 너무 길지 않게)
const _commaSplitMs = 6000;
const _forceSplitMs = 10000;

/// 마지막 단어 뒤로 자막을 조금 더 보여 준다
const _tailMs = 300;

/// parakeet-cli 토큰 출력을 문장 단위 자막으로 묶는다. 시간 단위는 10ms.
List<BilingualCue> parseParakeetTokens(Iterable<String> lines) {
  final out = <BilingualCue>[];
  final text = StringBuffer();
  int? start;
  var end = 0;
  var prev = '';

  void flush() {
    final t = text.toString().trim();
    if (start != null && t.isNotEmpty) {
      out.add(
        BilingualCue(
          start: Duration(milliseconds: start!),
          end: Duration(milliseconds: end),
          original: t,
        ),
      );
    }
    text.clear();
    start = null;
  }

  for (final l in lines) {
    final m = _tokenRe.firstMatch(l);
    if (m == null) continue;
    final t0 = int.parse(m[1]!) * 10, t1 = int.parse(m[2]!) * 10;
    final wordStart = m[3] == 'true';
    final tok = m[4]!.replaceAll('▁', ' ');
    if (start != null && wordStart) {
      final len = t0 - start!;
      final sentenceEnd = RegExp(r'[.?!]["”’)]?$').hasMatch(prev);
      if (sentenceEnd ||
          t0 - end > _gapMs ||
          (len > _commaSplitMs && prev.endsWith(',')) ||
          len > _forceSplitMs) {
        flush();
      }
    }
    start ??= t0;
    text.write(tok);
    if (t1 > end) end = t1;
    prev = tok;
  }
  flush();

  // 끝을 조금 늘리되 다음 줄과 겹치지 않게
  return [
    for (var i = 0; i < out.length; i++)
      () {
        final c = out[i];
        var e = c.end + const Duration(milliseconds: _tailMs);
        if (i + 1 < out.length && e > out[i + 1].start) e = out[i + 1].start;
        if (e <= c.start) e = c.start + const Duration(milliseconds: 200);
        return BilingualCue(start: c.start, end: e, original: c.original);
      }(),
  ];
}

/// parakeet-cli가 실패했는지. 음성 파일을 못 읽어도 exit 0으로 끝나므로
/// (`error: failed to read audio file ...`) 종료 코드만으로는 알 수 없다.
/// 그냥 두면 말소리 없는 구간처럼 보여 자막 없이 인식 완료로 저장된다.
bool parakeetFailed(Iterable<String> stderrLines) =>
    stderrLines.any((l) => l.trimLeft().startsWith('error:'));

/// parakeet-cli로 음성 인식 (영어 등 유럽어). 큐 시간은 [wavPath] 기준.
/// 결과는 끝난 뒤 한꺼번에 나온다. 듣기를 그만두면 프로세스를 끝낸다.
Stream<SttEvent> transcribeParakeet({
  required String wavPath,
  required File model,
}) {
  final args = [
    '-m',
    model.path,
    '-f',
    wavPath,
    '-t',
    '${Platform.numberOfProcessors.clamp(2, 8)}',
    '-ps',
    '-np',
  ];
  Process? proc;
  var cancelled = false;
  late final StreamController<SttEvent> events;
  events = StreamController<SttEvent>(
    onListen: () async {
      try {
        final p = proc = await Process.start(await parakeetCli(), args);
        if (cancelled) p.kill();
        final err = <String>[];
        final done = [
          p.stdout.drain<void>(),
          p.stderr
              .transform(lenientUtf8.decoder)
              .transform(const LineSplitter())
              .forEach(err.add),
        ];
        await Future.wait(done);
        final code = await p.exitCode;
        if (cancelled) return;
        if (code != 0 || parakeetFailed(err)) {
          final tail = err.length > 5 ? err.sublist(err.length - 5) : err;
          throw ProcessException('parakeet-cli', args, tail.join('\n'), code);
        }
        for (final c in parseParakeetTokens(err)) {
          events.add(SttCue(c));
        }
      } catch (e, st) {
        if (!cancelled) events.addError(e, st);
      } finally {
        await events.close();
      }
    },
    // 끝날 때까지 기다려야 다음 조각이 같은 wav 파일을 덮어쓸 수 있다
    onCancel: () async {
      cancelled = true;
      final p = proc;
      if (p != null) {
        p.kill();
        await p.exitCode;
      }
    },
  );
  return events.stream;
}
