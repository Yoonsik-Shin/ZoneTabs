import AppKit
import ApplicationServices

// AX 요소에서 CGWindowID를 얻는 비공개 API. Rectangle, AltTab, yabai 등이 같은 방식을 쓴다.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 추적 중인 창 하나. frame은 화면 왼쪽 위가 원점인 좌표계(AX/CG 좌표계)다.
struct TrackedWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let appName: String
    let title: String
    var frame: CGRect
}

extension AXUIElement {
    func value(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? { value(name) as? String }
    func bool(_ name: String) -> Bool? { value(name) as? Bool }

    func point(_ name: String) -> CGPoint? {
        guard let v = value(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    func size(_ name: String) -> CGSize? {
        guard let v = value(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}

enum WindowScanner {
    /// 손쉬운 사용 API로 현재 Space의 일반 창을 모두 모은다. 느릴 수 있으므로 백그라운드에서 호출한다.
    static func scan(apps: [(pid: pid_t, name: String)]) -> [TrackedWindow] {
        var result: [TrackedWindow] = []
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.pid)
            // 응답 없는 앱 때문에 전체 스캔이 멈추지 않도록 한다.
            AXUIElementSetMessagingTimeout(appElement, 0.3)
            guard let windows = appElement.value(kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                guard window.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      window.bool(kAXMinimizedAttribute) != true,
                      window.bool("AXFullScreen") != true,
                      let origin = window.point(kAXPositionAttribute),
                      let size = window.size(kAXSizeAttribute),
                      size.width >= 100, size.height >= 100
                else { continue }
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { continue }
                result.append(TrackedWindow(
                    id: id,
                    pid: app.pid,
                    element: window,
                    appName: app.name,
                    title: window.string(kAXTitleAttribute) ?? "",
                    frame: CGRect(origin: origin, size: size)
                ))
            }
        }
        return result
    }

    /// 화면에 보이는 일반 레이어 창을 앞에서 뒤 순서로 돌려준다. 가볍기 때문에 폴링에 쓴다.
    static func onScreenWindows() -> [(id: CGWindowID, frame: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [(id: CGWindowID, frame: CGRect)] = []
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            result.append((id: id, frame: frame))
        }
        return result
    }

    static func focus(_ window: TrackedWindow) {
        AXUIElementSetMessagingTimeout(window.element, 1.0)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let appElement = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
    }
}
