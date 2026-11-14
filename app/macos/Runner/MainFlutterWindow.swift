import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 시스템의 "자연스러운 스크롤" 설정. 켜져 있으면 휠 방향이 뒤집혀 오므로
    // 재생 화면의 휠 음량·밝기 조절이 이 값을 보고 방향을 맞춘다.
    FlutterMethodChannel(
      name: "transcue/scroll",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { call, result in
      guard call.method == "natural" else { return result(FlutterMethodNotImplemented) }
      let value = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool
      result(value ?? true)
    }

    super.awakeFromNib()
  }
}
