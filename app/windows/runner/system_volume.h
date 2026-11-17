#ifndef RUNNER_SYSTEM_VOLUME_H_
#define RUNNER_SYSTEM_VOLUME_H_

#include <optional>

// Windows 시스템 음량 (기본 출력 장치의 마스터 음량, 0~1).
// 앱 음량과 시스템 음량이 따로 놀지 않도록 휠·키로는 이 값을 바꾼다.
namespace system_volume {

std::optional<double> Get();

// 바꾼 뒤의 값을 돌려준다
std::optional<double> Set(double level);

std::optional<bool> GetMute();
bool SetMute(bool mute);

}  // namespace system_volume

#endif  // RUNNER_SYSTEM_VOLUME_H_
