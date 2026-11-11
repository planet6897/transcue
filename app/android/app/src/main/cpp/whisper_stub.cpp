// 64비트 ARM이 아닌 기기: 음성 인식 없음 (null 반환 → 앱은 소리 없음으로 처리)
#include <jni.h>

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_transcue_app_WhisperBridge_nativeTranscribe(
    JNIEnv *, jobject, jstring, jstring, jstring, jint, jfloatArray) {
  return nullptr;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_transcue_app_WhisperBridge_nativeSpeechSegments(
    JNIEnv *, jobject, jstring, jint, jfloatArray) {
  return nullptr;
}
