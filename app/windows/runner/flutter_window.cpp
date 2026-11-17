#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "system_brightness.h"
#include "system_volume.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 브라우저에서 끌어 온 링크(YouTube)나 동영상 파일을 창 위에 놓으면 연다
  drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "transcue/drop",
          &flutter::StandardMethodCodec::GetInstance());
  ::OleInitialize(nullptr);
  drop_target_ = new DropTarget([this](const std::vector<std::string>& items) {
    flutter::EncodableList list;
    for (const std::string& item : items) {
      list.push_back(flutter::EncodableValue(item));
    }
    drop_channel_->InvokeMethod(
        "drop", std::make_unique<flutter::EncodableValue>(list));
    ::SetForegroundWindow(GetHandle());
  });
  ::RegisterDragDrop(GetHandle(), drop_target_);

  // 휠·키로 바꾸는 음량은 Windows 시스템 음량이다 (앱 음량과 따로 놀지 않게)
  volume_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "transcue/volume",
          &flutter::StandardMethodCodec::GetInstance());
  volume_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& m = call.method_name();
        if (m == "get" || m == "set") {
          std::optional<double> v;
          if (m == "set") {
            const auto* arg = std::get_if<double>(call.arguments());
            v = arg != nullptr ? system_volume::Set(*arg) : std::nullopt;
          } else {
            v = system_volume::Get();
          }
          if (v) {
            result->Success(flutter::EncodableValue(*v));
          } else {
            result->Error("volume", "system volume unavailable");
          }
        } else if (m == "getMute") {
          std::optional<bool> mute = system_volume::GetMute();
          if (mute) {
            result->Success(flutter::EncodableValue(*mute));
          } else {
            result->Error("volume", "system volume unavailable");
          }
        } else if (m == "setMute") {
          const auto* arg = std::get_if<bool>(call.arguments());
          result->Success(flutter::EncodableValue(
              arg != nullptr && system_volume::SetMute(*arg)));
        } else {
          result->NotImplemented();
        }
      });

  // 휠로 바꾸는 밝기는 모니터의 실제 밝기다 (안 되면 앱이 영상 위를 어둡게 덮는다)
  brightness_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "transcue/brightness",
          &flutter::StandardMethodCodec::GetInstance());
  brightness_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& m = call.method_name();
        if (m != "get" && m != "set") {
          result->NotImplemented();
          return;
        }
        std::optional<double> v;
        if (m == "set") {
          const auto* arg = std::get_if<double>(call.arguments());
          v = arg != nullptr ? system_brightness::Set(GetHandle(), *arg)
                             : std::nullopt;
        } else {
          v = system_brightness::Get(GetHandle());
        }
        if (v) {
          result->Success(flutter::EncodableValue(*v));
        } else {
          result->Error("brightness", "this display does not support it");
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (drop_target_) {
    ::RevokeDragDrop(GetHandle());
    drop_target_->Release();
    drop_target_ = nullptr;
    ::OleUninitialize();
  }
  drop_channel_ = nullptr;
  volume_channel_ = nullptr;
  brightness_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
