// whisper.cpp JNI: 16kHz 모노 PCM → 자막 줄 (데스크톱 whisper-cli와 같은 설정)
#include <jni.h>
#include <mutex>
#include <string>
#include <vector>

#include "whisper.h"

namespace {
std::mutex g_mu;
whisper_context *g_ctx = nullptr;
std::string g_model;

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
