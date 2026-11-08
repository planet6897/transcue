import 'package:flutter/material.dart';

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
  bool _obscure = true;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void _save() {
    widget.settings
      ..claudeApiKey = _key.text.trim()
      ..claudeModel = _claude
      ..whisperModel = _whisper;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: const Text('설정'),
      content: SizedBox(
        width: 460,
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
            const SizedBox(height: 8),
            Text('처음 사용할 때 모델을 한 번 내려받습니다.', style: hint),
          ],
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
