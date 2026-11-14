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

    // 브라우저에서 끌어 온 링크(YouTube)나 동영상 파일을 창 위에 놓으면 연다.
    // 무엇을 열지는 Dart(pickDropped)가 고른다.
    dropChannel = FlutterMethodChannel(
      name: "transcue/drop",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    registerForDraggedTypes([.URL, .fileURL, .string])

    super.awakeFromNib()
  }

  private var dropChannel: FlutterMethodChannel?

  /// 끌어 온 것: 파일은 경로, 링크는 주소, 그 밖의 글은 그대로
  private func droppedItems(_ pasteboard: NSPasteboard) -> [String] {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    let items = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
    if !items.isEmpty { return items }
    return pasteboard.string(forType: .string).map { [$0] } ?? []
  }
}

extension MainFlutterWindow: NSDraggingDestination {
  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedItems(sender.draggingPasteboard).isEmpty ? [] : .copy
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let items = droppedItems(sender.draggingPasteboard)
    if items.isEmpty { return false }
    dropChannel?.invokeMethod("drop", arguments: items)
    NSApp.activate(ignoringOtherApps: true)
    return true
  }
}
