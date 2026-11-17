#include "system_volume.h"

#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <windows.h>

namespace system_volume {
namespace {

// 기본 출력 장치의 음량 조절기. 장치가 바뀔 수 있어 쓸 때마다 새로 얻는다.
IAudioEndpointVolume* Endpoint() {
  IMMDeviceEnumerator* enumerator = nullptr;
  if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator)))) {
    return nullptr;
  }
  IMMDevice* device = nullptr;
  HRESULT hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  enumerator->Release();
  if (FAILED(hr)) return nullptr;
  IAudioEndpointVolume* volume = nullptr;
  hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&volume));
  device->Release();
  return SUCCEEDED(hr) ? volume : nullptr;
}

}  // namespace

std::optional<double> Get() {
  IAudioEndpointVolume* v = Endpoint();
  if (v == nullptr) return std::nullopt;
  float level = 0;
  HRESULT hr = v->GetMasterVolumeLevelScalar(&level);
  v->Release();
  if (FAILED(hr)) return std::nullopt;
  return static_cast<double>(level);
}

std::optional<double> Set(double level) {
  IAudioEndpointVolume* v = Endpoint();
  if (v == nullptr) return std::nullopt;
  if (level < 0) level = 0;
  if (level > 1) level = 1;
  v->SetMasterVolumeLevelScalar(static_cast<float>(level), nullptr);
  // 소리를 키우면 음소거도 푼다 (Windows 음량 버튼과 같은 동작)
  if (level > 0) v->SetMute(FALSE, nullptr);
  float now = 0;
  HRESULT hr = v->GetMasterVolumeLevelScalar(&now);
  v->Release();
  if (FAILED(hr)) return std::nullopt;
  return static_cast<double>(now);
}

std::optional<bool> GetMute() {
  IAudioEndpointVolume* v = Endpoint();
  if (v == nullptr) return std::nullopt;
  BOOL mute = FALSE;
  HRESULT hr = v->GetMute(&mute);
  v->Release();
  if (FAILED(hr)) return std::nullopt;
  return mute == TRUE;
}

bool SetMute(bool mute) {
  IAudioEndpointVolume* v = Endpoint();
  if (v == nullptr) return false;
  HRESULT hr = v->SetMute(mute ? TRUE : FALSE, nullptr);
  v->Release();
  return SUCCEEDED(hr);
}

}  // namespace system_volume
