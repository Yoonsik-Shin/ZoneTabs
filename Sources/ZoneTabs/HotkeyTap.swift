import AppKit
import ApplicationServices

/// 영역 내 전환에 쓰는 단축키. 여기에 ⇧를 더하면 반대 방향이 된다.
struct Hotkey: Equatable {
    var keyCode: Int
    /// CGEventFlags 값(⌘⌥⌃⇧ 조합).
    var modifiers: UInt64
    /// 화면에 보여 줄 표기. 예: "⌥Tab"
    var label: String

    static let standard = Hotkey(keyCode: 48, modifiers: CGEventFlags.maskAlternate.rawValue, label: "⌥Tab")

    /// 반대 방향 단축키를 따로 둘 수 있는지. 이미 ⇧가 들어간 조합이면 둘 수 없다.
    var hasReverse: Bool { !CGEventFlags(rawValue: modifiers).contains(.maskShift) }
}

/// 전환 단축키를 가로채는 이벤트 탭. 손쉬운 사용 권한이 있어야 만들어진다.
///
/// 이벤트 탭은 잘못 다루면 시스템 전체 입력을 멈추게 할 수 있어서 두 가지를 지킨다.
/// - 콜백은 전용 스레드에서 돈다. 메인 스레드가 바빠도 키 입력이 밀리지 않는다.
/// - 권한이 사라지면 즉시 탭을 없앤다(AppDelegate가 감시하다가 stop()을 부른다).
final class HotkeyTap {
    enum Action {
        case next, previous
        /// 고른 창으로 전환을 확정 / 고르기를 취소. 고르는 중(selecting)일 때만 나온다.
        case confirm, cancel
    }

    /// 메인 스레드에서 호출된다.
    var handler: ((Action) -> Void)?
    /// 고르는 중인지. true인 동안에만 확정(같은 수식 키 + Return)과 취소(같은 수식 키 + Esc)를 가로챈다.
    var selecting = false
    /// false면 키 입력을 가로채지 않고 그대로 통과시킨다.
    var enabled = true
    /// 가로챌 단축키. 실행 중에 바꿔도 바로 적용된다.
    var hotkey = Hotkey.standard

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    private static let returnKeyCode: Int64 = 36
    private static let escapeKeyCode: Int64 = 53

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
            let hotkey = me.hotkey
            guard type == .keyDown, me.enabled else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.intersection([.maskAlternate, .maskShift, .maskCommand, .maskControl])
            let wanted = CGEventFlags(rawValue: hotkey.modifiers)

            var action: Action?
            if keyCode == Int64(hotkey.keyCode) {
                if flags == wanted {
                    action = .next
                } else if hotkey.hasReverse && flags == wanted.union(.maskShift) {
                    action = .previous
                }
            } else if me.selecting && flags == wanted {
                if keyCode == HotkeyTap.returnKeyCode {
                    action = .confirm
                } else if keyCode == HotkeyTap.escapeKeyCode {
                    action = .cancel
                }
            }
            guard let action = action else { return Unmanaged.passUnretained(event) }

            DispatchQueue.main.async { me.handler?(action) }
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
