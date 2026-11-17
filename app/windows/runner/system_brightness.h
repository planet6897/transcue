#ifndef RUNNER_SYSTEM_BRIGHTNESS_H_
#define RUNNER_SYSTEM_BRIGHTNESS_H_

#include <windows.h>

#include <optional>

// 앱 창이 있는 화면의 실제 밝기 (0~1).
// 외부 모니터는 DDC/CI, 노트북 내장 화면은 WMI로 바꾼다. 둘 다 안 되면 nullopt
// (그때 앱은 영상 위를 어둡게 덮는 방식으로 대신한다).
namespace system_brightness {

std::optional<double> Get(HWND window);

// 바꾼 뒤의 값을 돌려준다
std::optional<double> Set(HWND window, double level);

}  // namespace system_brightness

#endif  // RUNNER_SYSTEM_BRIGHTNESS_H_
