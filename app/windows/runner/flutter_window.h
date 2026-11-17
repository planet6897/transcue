#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "drop_target.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 창 위에 끌어다 놓은 링크·파일을 Dart로 알린다 (transcue/drop)
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      drop_channel_;
  DropTarget* drop_target_ = nullptr;

  // Windows 시스템 음량 (transcue/volume): get·set(0~1), getMute·setMute
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      volume_channel_;

  // 화면 밝기 (transcue/brightness): get·set(0~1). 안 되는 화면이면 오류
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      brightness_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
