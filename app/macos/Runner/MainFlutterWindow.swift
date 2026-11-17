import Cocoa
import CoreAudio
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

    // 휠·키로 바꾸는 음량은 시스템 음량이다 (앱 음량과 따로 놀지 않게): get·set(0~1), getMute·setMute
    FlutterMethodChannel(
      name: "transcue/volume",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "get":
        result(SystemAudio.volume().map { Double($0) as Any } ?? FlutterError(
          code: "volume", message: "system volume unavailable", details: nil))
      case "set":
        let v = Float((call.arguments as? Double) ?? 0)
        result(SystemAudio.setVolume(v).map { Double($0) as Any } ?? FlutterError(
          code: "volume", message: "system volume unavailable", details: nil))
      case "getMute":
        result(SystemAudio.isMuted() ?? false)
      case "setMute":
        result(SystemAudio.setMuted((call.arguments as? Bool) ?? false))
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // 휠로 바꾸는 밝기는 화면의 실제 밝기다 (내장 화면 등 지원하는 화면만. 안 되면 앱이 영상을 어둡게 덮는다)
    FlutterMethodChannel(
      name: "transcue/brightness",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { [weak self] call, result in
      let display = self?.displayID ?? CGMainDisplayID()
      let unsupported = FlutterError(
        code: "brightness", message: "this display does not support it", details: nil)
      switch call.method {
      case "get":
        result(SystemDisplay.brightness(display).map { Double($0) as Any } ?? unsupported)
      case "set":
        let v = Float((call.arguments as? Double) ?? 0)
        result(SystemDisplay.setBrightness(display, v).map { Double($0) as Any } ?? unsupported)
      default:
        result(FlutterMethodNotImplemented)
      }
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

  /// 이 창이 있는 화면
  private var displayID: CGDirectDisplayID? {
    (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
      .uint32Value
  }

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

/// 기본 출력 장치의 음량 (0~1)과 음소거 — 메뉴 막대의 소리 조절과 같은 값
enum SystemAudio {
  // kAudioHardwareServiceDeviceProperty_VirtualMainVolume ('vmvc'): 채널이 나뉜 장치도 한 값으로
  private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

  private static func defaultOutput() -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: 0)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return status == noErr ? id : nil
  }

  private static func address(_ selector: AudioObjectPropertySelector)
    -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
  }

  static func volume() -> Float? {
    guard let dev = defaultOutput() else { return nil }
    var addr = address(virtualMainVolume)
    var v = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
  }

  static func setVolume(_ level: Float) -> Float? {
    guard let dev = defaultOutput() else { return nil }
    var addr = address(virtualMainVolume)
    var v = Float32(min(max(level, 0), 1))
    let size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &v) == noErr else { return nil }
    if v > 0 { _ = setMuted(false) }  // 소리를 키우면 음소거도 푼다
    return volume()
  }

  static func isMuted() -> Bool? {
    guard let dev = defaultOutput() else { return nil }
    var addr = address(kAudioDevicePropertyMute)
    var m = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr ? m != 0 : nil
  }

  static func setMuted(_ mute: Bool) -> Bool {
    guard let dev = defaultOutput() else { return false }
    var addr = address(kAudioDevicePropertyMute)
    var m = UInt32(mute ? 1 : 0)
    let size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &m) == noErr
  }
}

/// 화면 밝기 (0~1). 공개 API가 없어 시스템의 DisplayServices를 불러 쓴다
/// (제어 센터의 밝기 막대와 같은 값). 외부 모니터 등 지원하지 않는 화면은 nil.
enum SystemDisplay {
  private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
  private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

  private static let handle = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

  private static let getFn: GetFn? = {
    guard let h = handle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetFn.self)
  }()

  private static let setFn: SetFn? = {
    guard let h = handle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: SetFn.self)
  }()

  static func brightness(_ display: CGDirectDisplayID) -> Float? {
    guard let get = getFn else { return nil }
    var v = Float(0)
    return get(display, &v) == 0 ? v : nil
  }

  static func setBrightness(_ display: CGDirectDisplayID, _ level: Float) -> Float? {
    guard let set = setFn else { return nil }
    let v = min(max(level, 0), 1)
    return set(display, v) == 0 ? brightness(display) ?? v : nil
  }
}
