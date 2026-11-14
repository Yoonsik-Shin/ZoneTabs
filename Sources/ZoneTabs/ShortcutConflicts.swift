import AppKit
import ApplicationServices
import Carbon

/// 지정하려는 단축키가 이미 쓰이고 있는지 찾아본다.
///
/// 확인할 수 있는 것: macOS 시스템 단축키(Spotlight, Mission Control, 입력 소스 전환 등)와
/// 실행 중인 앱들의 메뉴에 적힌 단축키.
/// 확인할 수 없는 것: 다른 유틸리티가 등록한 전역 단축키와, 메뉴에 나오지 않는 앱 내부 단축키.
/// macOS에 이런 단축키를 조회하는 방법이 없다.
enum ShortcutConflicts {
    struct Result {
        /// 겹치는 곳을 사람이 읽을 수 있게 적은 목록. 예: "Chrome — 탭 닫기"
        var hits: [String] = []
        /// 시간 안에 모든 앱을 확인했는지.
        var complete = true
    }

    private struct Combo {
        let keyCode: Int
        let command: Bool
        let option: Bool
        let control: Bool
        let shift: Bool
        /// 반대 방향(⇧ 추가) 조합인지.
        let isReverse: Bool
    }

    /// 지정한 조합과, 반대 방향으로 쓰이는 ⇧ 조합을 함께 본다.
    private static func combos(for hotkey: Hotkey) -> [Combo] {
        let flags = CGEventFlags(rawValue: hotkey.modifiers)
        let base = Combo(keyCode: hotkey.keyCode,
                         command: flags.contains(.maskCommand), option: flags.contains(.maskAlternate),
                         control: flags.contains(.maskControl), shift: flags.contains(.maskShift),
                         isReverse: false)
        guard hotkey.hasReverse else { return [base] }
        let reverse = Combo(keyCode: base.keyCode, command: base.command, option: base.option,
                            control: base.control, shift: true, isReverse: true)
        return [base, reverse]
    }

    private static func suffix(_ combo: Combo) -> String {
        combo.isReverse ? " (⇧를 더한 반대 방향)" : ""
    }

    /// macOS 시스템 단축키 중 켜져 있는 것과 겹치는지. 빠르므로 메인 스레드에서 불러도 된다.
    static func systemHits(for hotkey: Hotkey) -> [String] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        var hits: [String] = []
        for combo in combos(for: hotkey) {
            let taken = entries.contains { entry in
                guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                      let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                      let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int
                else { return false }
                return code == combo.keyCode
                    && (modifiers & cmdKey != 0) == combo.command
                    && (modifiers & optionKey != 0) == combo.option
                    && (modifiers & controlKey != 0) == combo.control
                    && (modifiers & shiftKey != 0) == combo.shift
            }
            if taken { hits.append("macOS 시스템 단축키" + suffix(combo)) }
        }
        return hits
    }

    /// 실행 중인 앱들의 메뉴에서 같은 단축키를 찾는다. 느릴 수 있으므로 백그라운드에서 부른다.
    static func menuHits(for hotkey: Hotkey, apps: [(pid: pid_t, name: String)], timeLimit: TimeInterval) -> Result {
        let deadline = Date().addingTimeInterval(timeLimit)
        let wanted = combos(for: hotkey)
        // 표기에서 수식 키 기호를 떼어 낸 키 이름. 예: "⌥Tab" → "TAB"
        let keyName = hotkey.label.trimmingCharacters(in: CharacterSet(charactersIn: "⌃⌥⇧⌘")).uppercased()
        var result = Result()

        for app in apps {
            if Date() > deadline { result.complete = false; break }
            let appElement = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            guard let menuBar = appElement.value(kAXMenuBarAttribute) else { continue }
            var budget = 2500
            visit(menuBar as! AXUIElement, depth: 0, appName: app.name, wanted: wanted, keyName: keyName,
                  deadline: deadline, budget: &budget, result: &result)
        }
        return result
    }

    private static func visit(_ element: AXUIElement, depth: Int, appName: String, wanted: [Combo], keyName: String,
                              deadline: Date, budget: inout Int, result: inout Result) {
        guard depth < 7, let children = element.value(kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            if budget <= 0 || Date() > deadline { result.complete = false; return }
            budget -= 1

            let names = [kAXTitleAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdModifiers"]
            var raw: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(child, names as CFArray,
                                                                AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
            if status == .success, let values = raw as? [Any], values.count == names.count {
                let title = values[0] as? String ?? ""
                let character = values[1] as? String ?? ""
                let virtualKey = values[2] as? Int
                let modifiers = values[3] as? Int
                if let modifiers = modifiers, !character.isEmpty || virtualKey != nil {
                    // 메뉴 단축키의 수식 키 표기: 1=⇧, 2=⌥, 4=⌃, 8=⌘ 없음.
                    for combo in wanted {
                        let sameModifiers = (modifiers & 1 != 0) == combo.shift
                            && (modifiers & 2 != 0) == combo.option
                            && (modifiers & 4 != 0) == combo.control
                            && (modifiers & 8 == 0) == combo.command
                        guard sameModifiers else { continue }
                        let sameKey = virtualKey == combo.keyCode
                            || (!character.isEmpty && normalized(character) == keyName)
                        if sameKey {
                            let name = title.isEmpty ? "메뉴 항목" : title
                            let hit = "\(appName) — \(name)" + suffix(combo)
                            if !result.hits.contains(hit) { result.hits.append(hit) }
                        }
                    }
                }
            }
            visit(child, depth: depth + 1, appName: appName, wanted: wanted, keyName: keyName,
                  deadline: deadline, budget: &budget, result: &result)
        }
    }

    /// 메뉴에 적힌 키 문자를 단축키 표기와 같은 이름으로 맞춘다.
    private static func normalized(_ character: String) -> String {
        switch character {
        case "\t": return "TAB"
        case " ": return "SPACE"
        case "\r": return "RETURN"
        case "\u{1B}": return "ESC"
        case "\u{08}", "\u{7F}": return "DELETE"
        default: return character.uppercased()
        }
    }
}
