import 'package:flutter/material.dart';

import '../app_version.dart';
import '../pipeline/stt_engine.dart' show canUseParakeet;
import '../pipeline/subtitle_job.dart'
    show clearSubtitleCache, subtitleCacheSize;
import '../update/update_dialog.dart';
import '../update/updater.dart' show checkForUpdate;
import 'app_settings.dart';

/// 설정 화면: 번역 공급자·API 키·모델, 음성 인식 모델.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.settings,
    this.onCacheCleared,
  });

  final AppSettings settings;

  /// 저장된 자막을 지운 뒤 (지금 영상의 자막을 다시 만들게)
  final VoidCallback? onCacheCleared;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  bool _checking = false;

  Future<void> _checkUpdate() async {
    setState(() => _checking = true);
    final r = await checkForUpdate(force: true);
    if (!mounted) return;
    setState(() => _checking = false);
    if (r == null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('최신 버전입니다')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => UpdateDialog(release: r),
    );
  }

  /// 저장된 자막 개수·크기 (읽는 중이면 null)
  ({int files, int bytes})? _cache;

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
  }

  Future<void> _loadCacheSize() async {
    final s = await subtitleCacheSize();
    if (mounted) setState(() => _cache = s);
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('저장된 자막 모두 지우기'),
        content: const Text(
          '지금까지 본 모든 영상의 자막·번역·싱크 결과를 지웁니다. '
          '다음에 열면 자막을 다시 가져오거나 음성 인식하고, 번역도 다시 하므로 API 비용이 다시 발생합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('모두 지우기'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = await clearSubtitleCache();
    widget.onCacheCleared?.call();
    await _loadCacheSize();
    if (mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('저장된 자막 $n개를 지웠습니다')));
    }
  }

  late TranslateProvider _provider = widget.settings.provider;
  // 공급자를 바꿔도 넣어 둔 키가 남도록 공급자마다 입력란을 따로 둔다
  late final _keys = {
    TranslateProvider.claude: TextEditingController(
      text: widget.settings.claudeApiKey,
    ),
    TranslateProvider.openai: TextEditingController(
      text: widget.settings.openaiApiKey,
    ),
    TranslateProvider.gemini: TextEditingController(
      text: widget.settings.geminiApiKey,
    ),
  };
  late ClaudeModel _claude = widget.settings.claudeModel;
  late OpenAiModel _openai = widget.settings.openaiModel;
  late GeminiModel _gemini = widget.settings.geminiModel;
  late WhisperModel _whisper = widget.settings.whisperModel;
  late EnglishStt _english = widget.settings.englishStt;
  late VocabLevel _level = widget.settings.vocabLevel;
  late final _osKey = TextEditingController(text: widget.settings.osApiKey);
  late final _osUser = TextEditingController(text: widget.settings.osUsername);
  late final _osPass = TextEditingController(text: widget.settings.osPassword);
  bool _obscure = true;

  @override
  void dispose() {
    for (final c in _keys.values) {
      c.dispose();
    }
    _osKey.dispose();
    _osUser.dispose();
    _osPass.dispose();
    super.dispose();
  }

  void _save() {
    widget.settings
      ..provider = _provider
      ..claudeApiKey = _keys[TranslateProvider.claude]!.text.trim()
      ..claudeModel = _claude
      ..openaiApiKey = _keys[TranslateProvider.openai]!.text.trim()
      ..openaiModel = _openai
      ..geminiApiKey = _keys[TranslateProvider.gemini]!.text.trim()
      ..geminiModel = _gemini
      ..whisperModel = _whisper
      ..englishStt = _english
      ..vocabLevel = _level
      ..osApiKey = _osKey.text.trim()
      ..osUsername = _osUser.text.trim()
      ..osPassword = _osPass.text;
    Navigator.pop(context, true);
  }

  DropdownButtonFormField<T> _modelField<T>(
    T value,
    List<T> values,
    String Function(T) text,
    ValueChanged<T> onChanged,
  ) => DropdownButtonFormField<T>(
    // 공급자를 바꾸면 모델 목록의 종류가 달라지므로 새로 만든다
    key: ValueKey('model-${_provider.name}'),
    initialValue: value,
    isExpanded: true,
    decoration: const InputDecoration(labelText: '번역 모델'),
    items: [
      for (final m in values)
        DropdownMenuItem(
          value: m,
          child: Text(text(m), overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (m) => setState(() => onChanged(m as T)),
  );

  Widget _translateModel() => switch (_provider) {
    TranslateProvider.claude => _modelField(
      _claude,
      ClaudeModel.values,
      (m) => '${m.label}  —  ${m.costHint}',
      (m) => _claude = m,
    ),
    TranslateProvider.openai => _modelField(
      _openai,
      OpenAiModel.values,
      (m) => '${m.label}  —  ${m.costHint}',
      (m) => _openai = m,
    ),
    TranslateProvider.gemini => _modelField(
      _gemini,
      GeminiModel.values,
      (m) => '${m.label}  —  ${m.costHint}',
      (m) => _gemini = m,
    ),
  };

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
          const SizedBox(width: 8),
          TextButton(
            onPressed: _checking ? null : _checkUpdate,
            child: Text(_checking ? '확인 중…' : '업데이트 확인'),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<TranslateProvider>(
                initialValue: _provider,
                decoration: const InputDecoration(labelText: '번역 공급자'),
                items: [
                  for (final p in TranslateProvider.values)
                    DropdownMenuItem(value: p, child: Text(p.label)),
                ],
                onChanged: (p) => setState(() => _provider = p!),
              ),
              const SizedBox(height: 12),
              TextField(
                key: ValueKey('key-${_provider.name}'),
                controller: _keys[_provider],
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: '${_provider.label} API 키',
                  hintText: _provider.keyHint,
                  helperText: '${_provider.keySite} 에서 발급 · 번역·학습 단어에만 사용',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _translateModel(),
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
              // Parakeet: 데스크톱은 parakeet-cli, Android는 앱에 함께 빌드된 whisper.cpp
              if (canUseParakeet) ...[
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
                canUseParakeet
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
              const Divider(height: 36),
              Text('저장된 자막', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('본 영상의 자막·번역·싱크 결과를 저장해 두고 다시 열 때 씁니다.', style: hint),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(switch (_cache) {
                      null => '확인 중…',
                      (files: 0, bytes: _) => '저장된 자막 없음',
                      (:final files, :final bytes) =>
                        '영상 $files개 · ${(bytes / 1024 / 1024).toStringAsFixed(1)}MB',
                    }),
                  ),
                  OutlinedButton.icon(
                    onPressed: (_cache?.files ?? 0) == 0 ? null : _clearCache,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('모두 지우기'),
                  ),
                ],
              ),
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
