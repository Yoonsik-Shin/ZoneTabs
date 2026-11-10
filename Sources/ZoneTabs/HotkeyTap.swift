import AppKit
import ApplicationServices

/// ⌥Tab / ⌥⇧Tab 을 가로채는 이벤트 탭. 손쉬운 사용 권한이 있어야 만들어진다.
///
/// 이벤트 탭은 잘못 다루면 시스템 전체 입력을 멈추게 할 수 있어서 두 가지를 지킨다.
/// - 콜백은 전용 스레드에서 돈다. 메인 스레드가 바빠도 키 입력이 밀리지 않는다.
/// - 권한이 사라지면 즉시 탭을 없앤다(AppDelegate가 감시하다가 stop()을 부른다).
final class HotkeyTap {
    /// 인자는 역방향(⇧) 여부. 메인 스레드에서 호출된다.
    var handler: ((Bool) -> Void)?
    /// false면 키 입력을 가로채지 않고 그대로 통과시킨다.
    var enabled = true

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private static let tabKeyCode: Int64 = 48

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // 권한이 살아 있을 때만 다시 켠다. 권한 없이 켜 두면 입력이 멈출 수 있다.
                if AXIsProcessTrusted(), let tap = me.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, me.enabled,
                  event.getIntegerValueField(.keyboardEventKeycode) == HotkeyTap.tabKeyCode
            else { return Unmanaged.passUnretained(event) }

            let flags = event.flags.intersection([.maskAlternate, .maskShift, .maskCommand, .maskControl])
            let forward = flags == [.maskAlternate]
            let backward = flags == [.maskAlternate, .maskShift]
            guard forward || backward else { return Unmanaged.passUnretained(event) }

            DispatchQueue.main.async { me.handler?(backward) }
            return nil
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let thread = Thread { [weak self] in
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
            let current = CFRunLoopGetCurrent()
            self?.runLoop = current
            CFRunLoopAddSource(current, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "dev.zonetabs.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop = runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        self.runLoop = nil
    }
}
