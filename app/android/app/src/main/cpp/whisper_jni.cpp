// whisper.cpp JNI: 16kHz 모노 PCM → 자막 줄 (데스크톱 whisper-cli와 같은 설정)
#include <jni.h>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

#include "audio_norm.h"
#include "parakeet.h"
#include "whisper.h"

namespace {
std::mutex g_mu;
whisper_context *g_ctx = nullptr;
std::string g_model;

// Parakeet (영어). 모델이 커서(670MB) 한 번 불러 두고 쓴다
std::mutex g_pk_mu;
parakeet_context *g_pk = nullptr;
std::string g_pk_model;

// 말소리 구간 검출(싱크 확인)은 음성 인식과 따로 돌도록 잠금과 모델을 분리한다
std::mutex g_vad_mu;
whisper_vad_context *g_vad = nullptr;
std::string g_vad_model;

std::string str(JNIEnv *env, jstring s) {
  if (s == nullptr) return {};
  const char *c = env->GetStringUTFChars(s, nullptr);
  std::string out(c);
  env->ReleaseStringUTFChars(s, c);
  return out;
}
}  // namespace

// 반환: UTF-8 바이트. 첫 줄 = 언어 코드, 이후 "시작ms\t끝ms\t문장" 줄들. 실패 시 null.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_transcue_app_WhisperBridge_nativeTranscribe(
    JNIEnv *env, jobject, jstring jmodel, jstring jvad, jstring jlang,
    jint threads, jfloatArray jpcm) {
  std::lock_guard<std::mutex> lock(g_mu);
  const std::string model = str(env, jmodel);
  const std::string vad = str(env, jvad);
  const std::string lang = str(env, jlang);

  if (g_ctx == nullptr || g_model != model) {
    if (g_ctx != nullptr) whisper_free(g_ctx);
    auto cp = whisper_context_default_params();
    g_ctx = whisper_init_from_file_with_params(model.c_str(), cp);
    g_model = g_ctx != nullptr ? model : "";
    if (g_ctx == nullptr) return nullptr;
  }

  const jsize n = env->GetArrayLength(jpcm);
  std::vector<float> pcm(n);
  env->GetFloatArrayRegion(jpcm, 0, n, pcm.data());
  // 작게 말한 구간도 인식되도록 소리 크기를 고른다 (데스크톱 ffmpeg dynaudnorm과 같은 설정)
  transcue::normalizeLoudness(pcm.data(), pcm.size());

  auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  p.n_threads = threads;
  p.print_progress = false;
  p.print_realtime = false;
  p.print_timestamps = false;
  p.print_special = false;
  // 앞 문장을 문맥으로 넘기지 않는다 (-mc 0: 긴 영상에서 문장이 끝없이 이어지는 현상 방지)
  p.no_context = true;
  p.n_max_text_ctx = 0;
  p.language = lang.empty() ? "auto" : lang.c_str();
  if (!vad.empty()) {
    p.vad = true;
    p.vad_model_path = vad.c_str();
    p.vad_params = whisper_vad_default_params();
    p.vad_params.max_speech_duration_s = 15.0f;  // -vmsd 15
  }
  if (whisper_full(g_ctx, p, pcm.data(), n) != 0) return nullptr;

  std::string out;
  const int lid = whisper_full_lang_id(g_ctx);
  out += lid >= 0 ? whisper_lang_str(lid) : "";
  out += '\n';
  const int ns = whisper_full_n_segments(g_ctx);
  for (int i = 0; i < ns; i++) {
    std::string text = whisper_full_get_segment_text(g_ctx, i);
    for (auto &c : text) {
      if (c == '\n' || c == '\t' || c == '\r') c = ' ';
    }
    out += std::to_string(whisper_full_get_segment_t0(g_ctx, i) * 10);
    out += '\t';
    out += std::to_string(whisper_full_get_segment_t1(g_ctx, i) * 10);
    out += '\t';
    out += text;
    out += '\n';
  }
  jbyteArray arr = env->NewByteArray(static_cast<jsize>(out.size()));
  env->SetByteArrayRegion(arr, 0, static_cast<jsize>(out.size()),
                          reinterpret_cast<const jbyte *>(out.data()));
  return arr;
}

// 말소리 구간 (데스크톱 whisper-vad-speech-segments와 같은 기본 설정).
// 반환: [시작ms, 끝ms, 시작ms, 끝ms, ...]. 실패 시 null.
extern "C" JNIEXPORT jlongArray JNICALL
Java_com_transcue_app_WhisperBridge_nativeSpeechSegments(
    JNIEnv *env, jobject, jstring jvad, jint threads, jfloatArray jpcm) {
  std::lock_guard<std::mutex> lock(g_vad_mu);
  const std::string vad = str(env, jvad);
  if (g_vad == nullptr || g_vad_model != vad) {
    if (g_vad != nullptr) whisper_vad_free(g_vad);
    auto cp = whisper_vad_default_context_params();
    cp.n_threads = threads;
    g_vad = whisper_vad_init_from_file_with_params(vad.c_str(), cp);
    g_vad_model = g_vad != nullptr ? vad : "";
    if (g_vad == nullptr) return nullptr;
  }

  const jsize n = env->GetArrayLength(jpcm);
  std::vector<float> pcm(n);
  env->GetFloatArrayRegion(jpcm, 0, n, pcm.data());
  transcue::normalizeLoudness(pcm.data(), pcm.size());

  whisper_vad_segments *segs = whisper_vad_segments_from_samples(
      g_vad, whisper_vad_default_params(), pcm.data(), n);
  if (segs == nullptr) return nullptr;
  const int ns = whisper_vad_segments_n_segments(segs);
  std::vector<jlong> ms(ns * 2);
  for (int i = 0; i < ns; i++) {
    // 단위: 1/100초
    ms[i * 2] = static_cast<jlong>(whisper_vad_segments_get_segment_t0(segs, i) * 10);
    ms[i * 2 + 1] = static_cast<jlong>(whisper_vad_segments_get_segment_t1(segs, i) * 10);
  }
  whisper_vad_free_segments(segs);
  jlongArray arr = env->NewLongArray(static_cast<jsize>(ms.size()));
  env->SetLongArrayRegion(arr, 0, static_cast<jsize>(ms.size()), ms.data());
  return arr;
}

// Parakeet TDT (영어 등 유럽어). 데스크톱 parakeet-cli -ps와 같은 토큰 줄을 돌려준다:
//   "[j] t0=시작 t1=끝 word_start=true|false "토큰"" (시간 단위 10ms)
// 문장으로 묶는 일은 앱(parseParakeetTokens)이 데스크톱과 똑같이 한다. 실패 시 null.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_transcue_app_WhisperBridge_nativeParakeet(
    JNIEnv *env, jobject, jstring jmodel, jint threads, jfloatArray jpcm) {
  std::lock_guard<std::mutex> lock(g_pk_mu);
  const std::string model = str(env, jmodel);
  if (g_pk == nullptr || g_pk_model != model) {
    if (g_pk != nullptr) parakeet_free(g_pk);
    auto cp = parakeet_context_default_params();
    cp.use_gpu = false;
    g_pk = parakeet_init_from_file_with_params(model.c_str(), cp);
    g_pk_model = g_pk != nullptr ? model : "";
    if (g_pk == nullptr) return nullptr;
  }

  const jsize n = env->GetArrayLength(jpcm);
  std::vector<float> pcm(n);
  env->GetFloatArrayRegion(jpcm, 0, n, pcm.data());
  // 데스크톱은 ffmpeg dynaudnorm을 거친 소리를 넘기므로 같은 처리를 한다
  transcue::normalizeLoudness(pcm.data(), pcm.size());

  auto p = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
  p.n_threads = threads;
  if (parakeet_full(g_pk, p, pcm.data(), n) != 0) return nullptr;

  std::string out;
  char head[96];
  const int ns = parakeet_full_n_segments(g_pk);
  for (int i = 0; i < ns; i++) {
    const int nt = parakeet_full_n_tokens(g_pk, i);
    for (int j = 0; j < nt; j++) {
      const parakeet_token_data d = parakeet_full_get_token_data(g_pk, i, j);
      const char *tok = parakeet_token_to_str(g_pk, d.id);
      std::snprintf(head, sizeof(head), "[%d] t0=%lld t1=%lld word_start=%s \"",
                    j, (long long)d.t0, (long long)d.t1,
                    d.is_word_start ? "true" : "false");
      out += head;
      std::string t = tok != nullptr ? tok : "";
      for (auto &c : t) {
        if (c == '\n' || c == '\r') c = ' ';
      }
      out += t;
      out += "\"\n";
    }
  }
  jbyteArray arr = env->NewByteArray(static_cast<jsize>(out.size()));
  env->SetByteArrayRegion(arr, 0, static_cast<jsize>(out.size()),
                          reinterpret_cast<const jbyte *>(out.data()));
  return arr;
}
