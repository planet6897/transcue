import 'package:flutter/material.dart';

import '../app_version.dart';
import '../pipeline/tools.dart' show hasDesktopTools;
import 'app_settings.dart';

/// 설정 화면: Claude API 키, 번역 모델, 음성 인식 모델.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final _key = TextEditingController(text: widget.settings.claudeApiKey);
  late ClaudeModel _claude = widget.settings.claudeModel;
  late WhisperModel _whisper = widget.settings.whisperModel;
  late EnglishStt _english = widget.settings.englishStt;
  late VocabLevel _level = widget.settings.vocabLevel;
  late final _osKey = TextEditingController(text: widget.settings.osApiKey);
  late final _osUser = TextEditingController(text: widget.settings.osUsername);
  late final _osPass = TextEditingController(text: widget.settings.osPassword);
  bool _obscure = true;

  @override
  void dispose() {
    _key.dispose();
    _osKey.dispose();
    _osUser.dispose();
    _osPass.dispose();
    super.dispose();
  }

  void _save() {
    widget.settings
      ..claudeApiKey = _key.text.trim()
      ..claudeModel = _claude
      ..whisperModel = _whisper
      ..englishStt = _english
      ..vocabLevel = _level
      ..osApiKey = _osKey.text.trim()
      ..osUsername = _osUser.text.trim()
      ..osPassword = _osPass.text;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const Text('설정'),
          const Spacer(),
          // 문제를 알릴 때 어느 버전인지 알 수 있게
          Text('Transcue $appVersionLabel', style: hint),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _key,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Claude API 키',
                  hintText: 'sk-ant-...',
                  helperText: 'console.anthropic.com 에서 발급 · 번역에만 사용',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<ClaudeModel>(
                initialValue: _claude,
                decoration: const InputDecoration(labelText: '번역 모델'),
                items: [
                  for (final m in ClaudeModel.values)
                    DropdownMenuItem(
                      value: m,
                      child: Text('${m.label}  —  ${m.costHint}'),
                    ),
                ],
                onChanged: (m) => setState(() => _claude = m!),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<WhisperModel>(
                initialValue: _whisper,
                decoration: const InputDecoration(
                  labelText: '음성 인식 모델 (내 컴퓨터에서 실행 · 무료)',
                ),
                items: [
                  for (final m in WhisperModel.values)
                    DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (m) => setState(() => _whisper = m!),
              ),
              // Parakeet은 데스크톱(whisper.cpp의 parakeet-cli)에서만 실행된다
              if (hasDesktopTools) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<EnglishStt>(
                  initialValue: _english,
                  decoration: const InputDecoration(labelText: '영어 음성 인식'),
                  items: [
                    for (final m in EnglishStt.values)
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: (m) => setState(() => _english = m!),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                hasDesktopTools
                    ? '처음 사용할 때 모델을 한 번 내려받습니다. '
                          'Parakeet은 영어로 확인된 구간에만 쓰고, 다른 언어는 whisper로 인식합니다.'
                    : '처음 사용할 때 모델을 한 번 내려받습니다.',
                style: hint,
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<VocabLevel>(
                initialValue: _level,
                decoration: const InputDecoration(
                  labelText: '학습 단어 수준 (V 키로 켜기/끄기)',
                ),
                items: [
                  for (final l in VocabLevel.values)
                    DropdownMenuItem(
                      value: l,
                      child: Text('${l.label} (${l.cefr})'),
                    ),
                ],
                onChanged: (l) => setState(() => _level = l!),
              ),
              const Divider(height: 36),
              Text(
                '인터넷 자막 (OpenSubtitles.com)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '음성 인식 전에 사람이 만든 자막(원어·한국어)을 먼저 찾습니다. '
                'opensubtitles.com 가입 후 개발자 메뉴에서 API 키를 만드세요.',
                style: hint,
              ),
              TextField(
                controller: _osKey,
                obscureText: _obscure,
                decoration: const InputDecoration(labelText: 'API 키'),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _osUser,
                      decoration: const InputDecoration(labelText: '아이디 (선택)'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _osPass,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '비밀번호 (선택)'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('계정을 넣으면 계정의 하루 다운로드 한도를 사용합니다.', style: hint),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _save, child: const Text('저장')),
      ],
    );
  }
}
