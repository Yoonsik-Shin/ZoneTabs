import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = ZoneController()
    private let hotkeys = HotkeyTap()
    private let updater = Updater()
    private var updateItem: NSMenuItem!
    private var updateTimer: Timer?
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?
    private var tracking = false

    private var enabledItem: NSMenuItem!
    private var opacityLabel: NSTextField!
    private var sizeLabel: NSTextField!
    private var edgeItems: [BarEdge: NSMenuItem] = [:]
    private var anchorItems: [BarAnchor: NSMenuItem] = [:]
    private var targetItems: [CycleTarget: NSMenuItem] = [:]
    private var modeItems: [SwitchMode: NSMenuItem] = [:]
    private var dwellItems: [Double: NSMenuItem] = [:]
    private var loginItem: NSMenuItem!
    private var hotkeyHintItem: NSMenuItem!
    private var permissionItem: NSMenuItem!

    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["enabled": true, "idleOpacity": 0.35, "iconSize": 24.0, "slide": 0.5])
        controller.enabled = defaults.bool(forKey: "enabled")
        controller.idleOpacity = CGFloat(min(max(defaults.double(forKey: "idleOpacity"), 0.05), 1))

        controller.iconSize = CGFloat(min(max(defaults.double(forKey: "iconSize"), 14), 56))

        controller.edge = BarEdge(rawValue: defaults.string(forKey: "edge") ?? "") ?? .right
        controller.anchor = BarAnchor(rawValue: defaults.string(forKey: "anchor") ?? "") ?? .window
        controller.cycleTarget = CycleTarget(rawValue: defaults.string(forKey: "cycleTarget") ?? "") ?? .focused

        controller.slide = CGFloat(min(max(defaults.double(forKey: "slide"), 0), 1))
        controller.onSlideChanged = { [weak self] position in
            self?.defaults.set(Double(position), forKey: "slide")
        }
        // 바의 설정 버튼을 누르면 메뉴바 아이콘과 같은 메뉴를 그 자리에 띄운다.
        controller.onSettings = { [weak self] view in
            self?.statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }

        buildMenu()

        hotkeys.handler = { [weak self] action in
            switch action {
            case .next: self?.controller.cycle(reverse: false)
            case .previous: self?.controller.cycle(reverse: true)
            case .confirm: self?.controller.confirmSelection()
            case .cancel: self?.controller.cancelSelection()
            }
        }
        controller.onSelectingChanged = { [weak self] selecting in self?.hotkeys.selecting = selecting }
        // 예전 버전은 "고른 뒤 확정" 여부만 저장했다. 새 설정이 없으면 그 값을 이어받는다.
        let legacyMode: SwitchMode = defaults.bool(forKey: "confirmMode") ? .confirm : .immediate
        controller.switchMode = SwitchMode(rawValue: defaults.string(forKey: "switchMode") ?? "") ?? legacyMode
        if defaults.object(forKey: "dwellDelay") != nil {
            controller.dwellDelay = min(max(defaults.double(forKey: "dwellDelay"), 0.2), 5)
        }
        hotkeys.enabled = controller.enabled
        hotkeys.hotkey = loadHotkey()

        // 권한이 없으면 시스템 안내 창을 띄우고, 허용될 때까지 기다렸다가 시작한다.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        syncWithPermission()

        // 권한 상태를 계속 지켜본다. 실행 중에 권한이 사라졌는데 이벤트 탭이 남아 있으면
        // 시스템 전체 입력이 멈출 수 있으므로, 사라지는 즉시 탭을 없앤다.
        // 실행 직후와 하루에 한 번 새 버전을 확인한다.
        checkForUpdateSilently()
        let daily = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdateSilently()
        }
        RunLoop.main.add(daily, forMode: .common)
        updateTimer = daily

        // 대화상자가 떠 있는 동안에도 아래 타이머들이 돌도록, 등록을 마친 뒤 다음 차례에 띄운다.
        DispatchQueue.main.async { [weak self] in self?.reportFinishedUpdate() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.syncWithPermission() }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    private func syncWithPermission() {
        let trusted = AXIsProcessTrusted()
        if trusted && !tracking {
            tracking = true
            permissionItem.isHidden = true
            controller.start()
            if !hotkeys.start() {
                NSLog("ZoneTabs: 단축키 이벤트 탭을 만들지 못했습니다. 손쉬운 사용 권한을 확인하세요.")
            }
        } else if !trusted && tracking {
            tracking = false
            hotkeys.stop()
            controller.stop()
            permissionItem.isHidden = false
        } else if !trusted {
            permissionItem.isHidden = false
        }
    }

    /// 다른 도구(스트림 컨트롤러 등)에서 단축키 없이 전환을 시킬 수 있는 주소.
    /// zonetabs://next 는 다음 창, zonetabs://prev 는 이전 창,
    /// zonetabs://confirm 은 고른 창으로 전환, zonetabs://cancel 은 고르기 취소.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "zonetabs" {
            switch url.host {
            case "next": controller.cycle(reverse: false)
            case "prev", "previous": controller.cycle(reverse: true)
            case "confirm", "select": controller.confirmSelection()
            case "cancel": controller.cancelSelection()
            default: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "ZoneTabs") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "ZT"
        }

        let menu = NSMenu()

        permissionItem = NSMenuItem(title: "손쉬운 사용 권한 필요 — 설정 열기", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isHidden = true
        menu.addItem(permissionItem)

        enabledItem = NSMenuItem(title: "탭 바 사용", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = controller.enabled ? .on : .off
        menu.addItem(enabledItem)

        menu.addItem(.separator())
        menu.addItem(makeEdgeItem())
        let recenter = NSMenuItem(title: "바를 가운데로 되돌리기", action: #selector(recenterBar), keyEquivalent: "")
        recenter.target = self
        menu.addItem(recenter)
        menu.addItem(makeSizeItem())
        menu.addItem(makeOpacityItem())

        menu.addItem(.separator())
        hotkeyHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hotkeyHintItem.isEnabled = false
        menu.addItem(hotkeyHintItem)
        refreshHotkeyHint()
        let changeHotkey = NSMenuItem(title: "단축키 변경…", action: #selector(changeHotkey), keyEquivalent: "")
        changeHotkey.target = self
        menu.addItem(changeHotkey)

        let targetMenu = NSMenu()
        for target in CycleTarget.allCases {
            let item = NSMenuItem(title: target.title, action: #selector(targetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.rawValue
            item.state = target == controller.cycleTarget ? .on : .off
            targetMenu.addItem(item)
            targetItems[target] = item
        }
        let targetParent = NSMenuItem(title: "단축키 적용 대상", action: nil, keyEquivalent: "")
        targetParent.submenu = targetMenu
        menu.addItem(targetParent)

        let modeMenu = NSMenu()
        for mode in SwitchMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(modeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == controller.switchMode ? .on : .off
            modeMenu.addItem(item)
            modeItems[mode] = item
        }
        // "잠시 멈추면 전환"에서 얼마나 멈춰야 전환할지.
        modeMenu.addItem(.separator())
        let dwellHeader = NSMenuItem(title: "멈춘 뒤 전환까지", action: nil, keyEquivalent: "")
        dwellHeader.isEnabled = false
        modeMenu.addItem(dwellHeader)
        for delay in [0.4, 0.8, 1.2, 2.0] {
            let item = NSMenuItem(title: "\(delay)초", action: #selector(dwellSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = delay
            item.indentationLevel = 1
            item.state = abs(delay - controller.dwellDelay) < 0.01 ? .on : .off
            modeMenu.addItem(item)
            dwellItems[delay] = item
        }
        let modeParent = NSMenuItem(title: "전환 방식", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)
        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        updateItem = NSMenuItem(title: "", action: #selector(updateClicked), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        refreshUpdateItem()

        let quitItem = NSMenuItem(title: "ZoneTabs 종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        controller.enabled.toggle()
        hotkeys.enabled = controller.enabled
        hotkeys.hotkey = loadHotkey()
        enabledItem.state = controller.enabled ? .on : .off
        defaults.set(controller.enabled, forKey: "enabled")
    }

    // MARK: - 단축키

    @objc private func modeSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SwitchMode(rawValue: raw) else { return }
        controller.switchMode = mode
        defaults.set(raw, forKey: "switchMode")
        for (key, item) in modeItems { item.state = key == mode ? .on : .off }
        refreshHotkeyHint()
    }

    @objc private func dwellSelected(_ sender: NSMenuItem) {
        guard let delay = sender.representedObject as? Double else { return }
        controller.dwellDelay = delay
        defaults.set(delay, forKey: "dwellDelay")
        for (key, item) in dwellItems { item.state = key == delay ? .on : .off }
    }

    @objc private func targetSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let target = CycleTarget(rawValue: raw) else { return }
        controller.cycleTarget = target
        defaults.set(raw, forKey: "cycleTarget")
        for (key, item) in targetItems { item.state = key == target ? .on : .off }
    }

    private func loadHotkey() -> Hotkey {
        guard defaults.object(forKey: "hotkeyKeyCode") != nil,
              let label = defaults.string(forKey: "hotkeyLabel"), !label.isEmpty,
              let modifiers = defaults.object(forKey: "hotkeyModifiers") as? NSNumber
        else { return .standard }
        return Hotkey(keyCode: defaults.integer(forKey: "hotkeyKeyCode"),
                      modifiers: modifiers.uint64Value, label: label)
    }

    private func applyHotkey(_ hotkey: Hotkey) {
        hotkeys.hotkey = hotkey
        defaults.set(hotkey.keyCode, forKey: "hotkeyKeyCode")
        defaults.set(NSNumber(value: hotkey.modifiers), forKey: "hotkeyModifiers")
        defaults.set(hotkey.label, forKey: "hotkeyLabel")
        refreshHotkeyHint()
    }

    private func refreshHotkeyHint() {
        let hotkey = hotkeys.hotkey
        if controller.switchMode != .immediate {
            // 확정과 취소는 전환 단축키와 같은 수식 키에 Return / Esc를 누른다.
            let symbols = String(hotkey.label.prefix { "⌃⌥⇧⌘".contains($0) })
            let confirm = controller.switchMode == .dwell ? "바로 확정" : "확정"
            hotkeyHintItem.title = "고르기: \(hotkey.label) · \(confirm): \(symbols)Return · 취소: \(symbols)Esc"
        } else {
            hotkeyHintItem.title = hotkey.hasReverse
                ? "영역 내 전환: \(hotkey.label) (⇧를 더하면 반대 방향)"
                : "영역 내 전환: \(hotkey.label)"
        }
    }

    /// 키 입력 하나를 단축키로 바꾼다. ⌘, ⌥, ⌃ 중 하나도 없으면 단축키로 쓸 수 없으므로 nil.
    private func hotkey(from event: NSEvent) -> Hotkey? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }

        var modifiers = CGEventFlags()
        var symbols = ""
        if flags.contains(.control) { modifiers.insert(.maskControl); symbols += "⌃" }
        if flags.contains(.option) { modifiers.insert(.maskAlternate); symbols += "⌥" }
        if flags.contains(.shift) { modifiers.insert(.maskShift); symbols += "⇧" }
        if flags.contains(.command) { modifiers.insert(.maskCommand); symbols += "⌘" }

        let names: [UInt16: String] = [
            48: "Tab", 49: "Space", 36: "Return", 51: "Delete", 53: "Esc", 50: "`",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        var name = names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "Key\(event.keyCode)" }
        return Hotkey(keyCode: Int(event.keyCode), modifiers: modifiers.rawValue, label: symbols + name)
    }

    @objc private func changeHotkey() {
        // 녹화하는 동안에는 기존 단축키를 가로채지 않아야 같은 조합도 다시 입력할 수 있다.
        hotkeys.enabled = false
        defer { hotkeys.enabled = controller.enabled }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "전환 단축키 변경"
        alert.informativeText = "이 창이 떠 있는 동안 새 단축키를 누르세요. ⌘, ⌥, ⌃ 중 하나 이상을 포함해야 합니다.\n\n누르면 시스템과 실행 중인 앱 메뉴의 단축키와 겹치는지 확인합니다. 겹치는 단축키로 저장하면 그쪽 단축키는 동작하지 않게 됩니다."
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 112))
        let field = NSTextField(labelWithString: "현재: \(hotkeys.hotkey.label)")
        field.alignment = .center
        field.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        field.frame = CGRect(x: 0, y: 78, width: 300, height: 30)
        container.addSubview(field)
        // 겹치는 단축키를 찾은 결과를 보여 주는 자리.
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.frame = CGRect(x: 0, y: 0, width: 300, height: 72)
        container.addSubview(status)
        alert.accessoryView = container
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "기본값(⌥Tab)으로")

        var recorded: Hotkey?
        var checkToken = 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let hotkey = self?.hotkey(from: event) else { return event }
            recorded = hotkey
            field.stringValue = hotkey.label

            // 시스템 단축키는 바로, 앱 메뉴 단축키는 백그라운드에서 확인해 결과를 채운다.
            checkToken += 1
            let token = checkToken
            let systemHits = ShortcutConflicts.systemHits(for: hotkey)
            status.textColor = .secondaryLabelColor
            status.stringValue = "겹치는 단축키를 확인하는 중…"
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
                .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "앱") }
            DispatchQueue.global(qos: .userInitiated).async {
                let menus = ShortcutConflicts.menuHits(for: hotkey, apps: apps, timeLimit: 6)
                DispatchQueue.main.async {
                    // 그사이 다른 조합을 눌렀으면 이 결과는 버린다.
                    guard token == checkToken else { return }
                    let hits = systemHits + menus.hits
                    if hits.isEmpty {
                        status.textColor = .secondaryLabelColor
                        status.stringValue = menus.complete
                            ? "시스템과 실행 중인 앱 메뉴에서 겹치는 단축키를 찾지 못했습니다."
                            : "확인한 범위에서는 겹치지 않습니다(일부 앱은 시간 안에 확인하지 못했습니다)."
                    } else {
                        status.textColor = .systemOrange
                        let shown = hits.prefix(3).joined(separator: "\n")
                        let more = hits.count > 3 ? "\n외 \(hits.count - 3)곳" : ""
                        status.stringValue = "겹칩니다:\n" + shown + more
                    }
                }
            }
            return nil
        }
        let response = alert.runModal()
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }

        switch response {
        case .alertFirstButtonReturn:
            if let recorded = recorded { applyHotkey(recorded) }
        case .alertThirdButtonReturn:
            applyHotkey(.standard)
        default:
            break
        }
    }

    // MARK: - 업데이트

    private func refreshUpdateItem() {
        if let release = updater.available {
            updateItem.title = "새 버전 \(release.version) 설치…"
        } else {
            updateItem.title = "업데이트 확인… (현재 \(updater.currentVersion))"
        }
    }

    /// 결과를 분명히 알리는 대화상자. 첫 번째 버튼을 눌렀으면 true.
    @discardableResult
    private func showAlert(_ title: String, _ text: String, buttons: [String] = ["확인"]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 조용히 새 버전을 확인해 메뉴 항목만 바꿔 둔다(실행 직후와 하루 한 번).
    private func checkForUpdateSilently() {
        updater.check { [weak self] _ in self?.refreshUpdateItem() }
    }

    /// 메뉴에서 눌렀을 때. 결과를 항상 대화상자로 알려 준다.
    @objc private func updateClicked() {
        if let release = updater.available {
            offerInstall(release)
            return
        }
        updateItem.title = "업데이트 확인 중…"
        updater.check { [weak self] result in
            guard let self = self else { return }
            self.refreshUpdateItem()
            switch result {
            case .success(let release?):
                self.offerInstall(release)
            case .success(nil):
                self.showAlert("최신 버전입니다", "ZoneTabs \(self.updater.currentVersion)이(가) 가장 새로운 버전입니다.")
            case .failure(let error):
                self.showAlert("업데이트를 확인하지 못했습니다", error.localizedDescription)
            }
        }
    }

    private func offerInstall(_ release: Updater.Release) {
        let install = showAlert(
            "새 버전 \(release.version)이(가) 있습니다",
            "현재 버전은 \(updater.currentVersion)입니다. 설치하면 ZoneTabs가 잠깐 꺼졌다가 새 버전으로 다시 실행됩니다.",
            buttons: ["설치 후 다시 실행", "나중에"])
        guard install else { return }

        // 다시 실행됐을 때 성공 여부를 알려 주려고 목표 버전을 적어 둔다.
        defaults.set(release.version, forKey: "pendingUpdateVersion")
        updateItem.title = "새 버전 \(release.version) 받는 중…"
        updater.install(release) { [weak self] error in
            guard let self = self else { return }
            self.defaults.removeObject(forKey: "pendingUpdateVersion")
            self.refreshUpdateItem()
            self.showAlert("업데이트하지 못했습니다", error.localizedDescription)
        }
    }

    /// 업데이트로 다시 실행된 경우, 실제로 새 버전이 됐는지 알려 준다.
    private func reportFinishedUpdate() {
        guard let target = defaults.string(forKey: "pendingUpdateVersion") else { return }
        defaults.removeObject(forKey: "pendingUpdateVersion")
        if target == updater.currentVersion {
            showAlert("ZoneTabs \(target)(으)로 업데이트되었습니다", "새 버전이 실행 중입니다.")
        } else {
            showAlert("업데이트가 적용되지 않았습니다",
                      "\(target)을(를) 설치하려 했지만 지금 실행 중인 버전은 \(updater.currentVersion)입니다. 다시 시도해 주세요.")
        }
    }

    @objc private func recenterBar() {
        controller.slide = 0.5
        defaults.set(0.5, forKey: "slide")
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("ZoneTabs: 로그인 항목 변경 실패: \(error.localizedDescription)")
        }
        loginItem.state = service.status == .enabled ? .on : .off
    }

    /// 바 위치(위/아래/왼쪽/오른쪽)를 고르는 하위 메뉴.
    private func makeEdgeItem() -> NSMenuItem {
        let submenu = NSMenu()
        for edge in BarEdge.allCases {
            let item = NSMenuItem(title: edge.title, action: #selector(edgeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = edge.rawValue
            item.state = edge == controller.edge ? .on : .off
            submenu.addItem(item)
            edgeItems[edge] = item
        }
        submenu.addItem(.separator())
        for anchor in BarAnchor.allCases {
            let item = NSMenuItem(title: anchor.title, action: #selector(anchorSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = anchor.rawValue
            item.state = anchor == controller.anchor ? .on : .off
            submenu.addItem(item)
            anchorItems[anchor] = item
        }
        let parent = NSMenuItem(title: "바 위치", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc private func anchorSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let anchor = BarAnchor(rawValue: raw) else { return }
        controller.anchor = anchor
        defaults.set(raw, forKey: "anchor")
        for (key, item) in anchorItems { item.state = key == anchor ? .on : .off }
    }

    @objc private func edgeSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = BarEdge(rawValue: raw) else { return }
        controller.edge = edge
        defaults.set(raw, forKey: "edge")
        for (key, item) in edgeItems { item.state = key == edge ? .on : .off }
    }

    /// 제목 한 줄과 슬라이더로 이루어진 메뉴 항목을 만든다.
    private func makeSliderItem(value: Double, min: Double, max: Double, action: Selector) -> (NSMenuItem, NSTextField) {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 50))

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.menuFont(ofSize: 13)
        label.frame = CGRect(x: 16, y: 28, width: 208, height: 18)
        container.addSubview(label)

        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.frame = CGRect(x: 16, y: 4, width: 208, height: 22)
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return (item, label)
    }

    /// 바 크기(아이콘 크기)를 조절하는 슬라이더 메뉴 항목.
    private func makeSizeItem() -> NSMenuItem {
        let (item, label) = makeSliderItem(value: Double(controller.iconSize), min: 14, max: 56,
                                           action: #selector(sizeChanged(_:)))
        sizeLabel = label
        updateSizeLabel()
        return item
    }

    private func updateSizeLabel() {
        sizeLabel.stringValue = "바 크기: \(Int(controller.iconSize))"
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        let size = sender.doubleValue.rounded()
        guard CGFloat(size) != controller.iconSize else { return }
        controller.iconSize = CGFloat(size)
        defaults.set(size, forKey: "iconSize")
        updateSizeLabel()
    }

    /// 평소(마우스를 올리지 않았을 때) 불투명도를 조절하는 슬라이더 메뉴 항목.
    private func makeOpacityItem() -> NSMenuItem {
        let (item, label) = makeSliderItem(value: Double(controller.idleOpacity), min: 0.05, max: 1,
                                           action: #selector(opacityChanged(_:)))
        opacityLabel = label
        updateOpacityLabel()
        return item
    }

    private func updateOpacityLabel() {
        opacityLabel.stringValue = "평소 불투명도: \(Int((controller.idleOpacity * 100).rounded()))%"
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        controller.idleOpacity = CGFloat(sender.doubleValue)
        defaults.set(sender.doubleValue, forKey: "idleOpacity")
        updateOpacityLabel()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
