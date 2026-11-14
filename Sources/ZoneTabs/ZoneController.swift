import AppKit

/// 화면상 같은 자리를 차지하는 창들의 묶음. windows는 앞에 있는 창이 먼저다.
struct Zone {
    /// 맨 앞 창이 화면에서 차지하는 자리. 다른 창이 이 영역에 속하는지 판단하는 기준이다.
    var rect: CGRect
    /// 속한 창들이 화면에서 차지하는 자리를 모두 합친 범위. 바 위치를 정할 때 쓴다.
    var bounds: CGRect
    var windows: [TrackedWindow]

    func contains(_ id: CGWindowID) -> Bool { windows.contains { $0.id == id } }
}

/// 바를 영역의 어느 쪽 가장자리에 붙일지.
enum BarEdge: String, CaseIterable {
    case top, bottom, left, right

    var title: String {
        switch self {
        case .top: return "위"
        case .bottom: return "아래"
        case .left: return "왼쪽"
        case .right: return "오른쪽"
        }
    }

    /// 위·아래에 붙을 때는 아이콘을 가로로 늘어놓는다.
    var isHorizontal: Bool { self == .top || self == .bottom }
}

/// 단축키(또는 노브)를 눌렀을 때 어느 영역의 창을 넘길지.
enum CycleTarget: String, CaseIterable {
    /// 지금 키보드 입력을 받고 있는 창이 있는 영역.
    case focused
    /// 마우스 포인터가 올라가 있는 영역.
    case pointer
    /// 영역을 가리지 않고 화면의 모든 창을 차례로.
    case all

    var title: String {
        switch self {
        case .focused: return "지금 쓰고 있는 창의 영역"
        case .pointer: return "마우스가 있는 영역"
        case .all: return "모든 창 (영역 구분 없이)"
        }
    }
}

/// 바를 무엇에 붙일지.
enum BarAnchor: String, CaseIterable {
    /// 영역의 맨 앞 창 가장자리.
    case window
    /// 그 창이 있는 화면의 가장자리(Dock처럼).
    case screen

    var title: String {
        switch self {
        case .window: return "창에 붙이기"
        case .screen: return "화면 가장자리에 붙이기"
        }
    }
}

final class ZoneController {
    var enabled = true { didSet { refresh(force: true) } }
    /// 마우스를 올리지 않았을 때 바의 불투명도(0~1).
    var idleOpacity: CGFloat = 0.35 { didSet { panels.forEach { $0.idleOpacity = idleOpacity } } }

    /// 바를 붙일 가장자리.
    var edge: BarEdge = .right { didSet { render() } }

    /// true면 단축키가 바로 전환하지 않고 바에서 고르기만 하며, confirm()을 불러야 전환된다.
    var confirmMode = false { didSet { if !confirmMode { cancelSelection() } } }
    /// 고르는 중인지가 바뀔 때(단축키 탭에 알려 주기 위한 것).
    var onSelectingChanged: ((Bool) -> Void)?
    /// 고르는 중인 창. 확정하면 이 창으로 전환된다.
    private var pendingID: CGWindowID? {
        didSet { if (pendingID != nil) != (oldValue != nil) { onSelectingChanged?(pendingID != nil) } }
    }
    private var pendingToken = 0
    /// 이 시간 동안 입력이 없으면 고르기를 취소한다.
    private let selectionTimeout: TimeInterval = 5

    /// 단축키가 적용되는 영역을 고르는 기준.
    var cycleTarget: CycleTarget = .focused

    /// 바를 창에 붙일지 화면에 붙일지.
    var anchor: BarAnchor = .window { didSet { render() } }

    /// 가장자리를 따라 바가 놓이는 위치. 0은 왼쪽/위 끝, 0.5는 가운데, 1은 오른쪽/아래 끝.
    var slide: CGFloat = 0.5 { didSet { render() } }
    /// 바를 끌어서 옮겨 slide가 바뀌었을 때(저장용).
    var onSlideChanged: ((CGFloat) -> Void)?
    /// 바의 설정 버튼을 눌렀을 때. 인자는 메뉴를 띄울 기준 뷰.
    var onSettings: ((NSView) -> Void)?

    /// 바의 아이콘 크기(pt).
    var iconSize: CGFloat = 24 {
        didSet {
            TabBarPanel.iconSize = iconSize
            render()
        }
    }

    /// 두 창을 같은 영역으로 보는 기준. 화면에 보이는 부분끼리 비교해서
    /// 둘 중 작은 창의 70% 이상이 다른 창과 겹치면 같은 영역이다.
    /// 즉 한 창이 앞에 왔을 때 다른 창이 대부분 가려져 손이 닿지 않게 되는 사이면 묶는다.
    private let coverThreshold: CGFloat = 0.7
    private let minZoneWidth: CGFloat = 200

    private var known: [CGWindowID: TrackedWindow] = [:]
    /// 탭 순서를 고정하기 위한 "처음 본 순서". z-order로 정렬하면 전환할 때마다 탭이 뒤섞인다.
    private var firstSeen: [CGWindowID: Int] = [:]
    private var nextSeen = 0

    private var ordered: [TrackedWindow] = []
    private(set) var zones: [Zone] = []
    private var panels: [TabBarPanel] = []
    /// "모든 창" 대상으로 넘길 때 화면 가운데에 잠깐 뜨는 전체 창 목록.
    private var overviewPanel: TabBarPanel?
    private var overviewVisible = false
    private var overviewToken = 0

    private var lastSignature = ""
    private var scanning = false
    private var needsScan = false
    private var observing = false
    private var lastScan = Date.distantPast
    private var timer: Timer?
    private let scanQueue = DispatchQueue(label: "dev.zonetabs.scan", qos: .userInitiated)

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        guard !observing else { refresh(force: true); return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh(force: true)
            }
        }
        refresh(force: true)
    }

    // MARK: - 갱신

    private func tick() { refresh(force: false) }

    private func refresh(force: Bool) {
        // 시작 전이거나 권한이 사라져 멈춘 상태에서는 아무것도 하지 않는다.
        guard timer != nil else { return }
        let onScreen = WindowScanner.onScreenWindows()
        let signature = onScreen.map { "\($0.id):\($0.frame)" }.joined(separator: "|")
        if force || signature != lastSignature {
            lastSignature = signature
            regroup(onScreen)
            needsScan = true
        }
        // 손쉬운 사용 API 조회는 다른 앱에 부담을 주므로 간격을 둔다.
        // 변화가 있으면 0.5초에 한 번까지, 없어도 창 제목 등을 반영하려고 5초에 한 번 조회한다.
        let sinceScan = Date().timeIntervalSince(lastScan)
        if (needsScan && sinceScan > 0.5) || sinceScan > 5 {
            requestScan()
        }
    }

    /// 권한이 사라졌을 때 호출한다. 바를 모두 숨기고 폴링을 멈춘다.
    func stop() {
        timer?.invalidate()
        timer = nil
        zones = []
        ordered = []
        panels.forEach { $0.hide() }
        hideOverview()
    }

    private func requestScan() {
        guard !scanning else { return }
        scanning = true
        needsScan = false
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ownPID }
            .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "") }
        scanQueue.async { [weak self] in
            let windows = WindowScanner.scan(apps: apps)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.known = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                self.scanning = false
                self.lastScan = Date()
                self.regroup(WindowScanner.onScreenWindows())
            }
        }
    }

    private func regroup(_ onScreen: [(id: CGWindowID, frame: CGRect)]) {
        // 위치와 순서는 방금 읽은 CG 값이 가장 최신이므로 그것을 쓴다.
        ordered = onScreen.compactMap { entry in
            guard var window = known[entry.id] else { return nil }
            window.frame = entry.frame
            return window
        }
        for window in ordered where firstSeen[window.id] == nil {
            firstSeen[window.id] = nextSeen
            nextSeen += 1
        }

        // 화면 밖으로 나간 부분은 빼고, 실제로 보이는 자리끼리 비교한다.
        let visible = ordered.map { visiblePart(of: $0.frame) }

        // 서로 가리는 창끼리 이어 붙여 묶음을 만든다(A-B, B-C가 가리면 A·B·C가 한 영역).
        // 이렇게 하면 어느 창이 앞에 있든 묶음이 똑같아서, 전환해도 바가 사라지지 않는다.
        var group = Array(ordered.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while group[index] != index { index = group[index] }
            return index
        }
        for i in ordered.indices {
            for j in ordered.indices where j > i && covers(visible[i], visible[j]) {
                let a = root(i), b = root(j)
                if a != b { group[max(a, b)] = min(a, b) }
            }
        }

        // ordered가 앞→뒤 순서이므로, 영역도 창도 앞에 있는 것이 먼저 오게 된다.
        var result: [Zone] = []
        var zoneIndexForRoot: [Int: Int] = [:]
        for i in ordered.indices {
            let key = root(i)
            if let index = zoneIndexForRoot[key] {
                result[index].windows.append(ordered[i])
                result[index].bounds = result[index].bounds.union(visible[i])
            } else {
                zoneIndexForRoot[key] = result.count
                result.append(Zone(rect: visible[i], bounds: visible[i], windows: [ordered[i]]))
            }
        }
        zones = result
        render()
    }

    private func visiblePart(of frame: CGRect) -> CGRect {
        guard let screen = visibleScreenRect(for: frame) else { return frame }
        let clipped = frame.intersection(screen)
        return (clipped.isNull || clipped.isEmpty) ? frame : clipped
    }

    private func covers(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        if intersection.isNull { return false }
        let shared = intersection.width * intersection.height
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && shared / smaller >= coverThreshold
    }

    // MARK: - 탭 바 그리기

    private func tabOrder(_ zone: Zone) -> [TrackedWindow] {
        zone.windows.sorted { (firstSeen[$0.id] ?? 0) < (firstSeen[$1.id] ?? 0) }
    }

    /// 영역이 가장 많이 걸쳐 있는 화면의 사용 가능 영역(메뉴바·Dock 제외, 왼쪽 위 원점 좌표계).
    private func visibleScreenRect(for rect: CGRect) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        var best: CGRect?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let visible = screen.visibleFrame
            let flipped = CGRect(x: visible.minX, y: primaryHeight - visible.maxY,
                                 width: visible.width, height: visible.height)
            let overlap = flipped.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = flipped
            }
        }
        return best
    }

    /// 바가 놓일 자리와, 가장자리를 따라 움직일 수 있는 범위(모두 왼쪽 위 원점 좌표계).
    /// 영역의 맨 앞 창이 화면에서 차지하는 범위 안쪽, 선택한 가장자리에 붙는다.
    /// 창이 화면 끝까지 닿아 있거나 밖으로 나가 있으면 Dock처럼 화면 가장자리에 붙는다.
    private func barPlacement(for zone: Zone) -> (frame: CGRect, slideRange: ClosedRange<CGFloat>) {
        let size = TabBarPanel.size(tabCount: zone.windows.count, horizontal: edge.isHorizontal)
        let margin: CGFloat = 4
        // 맨 앞 창을 기준으로 붙인다. 묶음 전체 범위를 쓰면 뒤에 깔린 큰 창 쪽에 바가 떠서
        // 지금 보고 있는 창과 떨어져 보인다.
        let area = zone.rect
        let rangeX = area.minX...max(area.maxX - size.width, area.minX)
        let rangeY = area.minY...max(area.maxY - size.height, area.minY)
        // 가장자리를 따라서는 slide 비율만큼, 가장자리와 수직인 방향으로는 여백만큼 띄운다.
        let alongX = rangeX.lowerBound + (rangeX.upperBound - rangeX.lowerBound) * slide
        let alongY = rangeY.lowerBound + (rangeY.upperBound - rangeY.lowerBound) * slide
        let origin: CGPoint
        if anchor == .screen, let screen = visibleScreenRect(for: area) {
            // 화면 가장자리에 붙이되, 가장자리를 따라서는 자기 창 옆에 오게 해서 어느 영역의 바인지 알 수 있게 한다.
            switch edge {
            case .right: origin = CGPoint(x: screen.maxX - size.width - margin, y: alongY)
            case .left: origin = CGPoint(x: screen.minX + margin, y: alongY)
            case .top: origin = CGPoint(x: alongX, y: screen.minY + margin)
            case .bottom: origin = CGPoint(x: alongX, y: screen.maxY - size.height - margin)
            }
            return (CGRect(origin: origin, size: size), edge.isHorizontal ? rangeX : rangeY)
        }
        switch edge {
        case .right:
            origin = CGPoint(x: max(area.maxX - size.width - margin, area.minX), y: alongY)
        case .left:
            origin = CGPoint(x: min(area.minX + margin, rangeX.upperBound), y: alongY)
        case .top:
            origin = CGPoint(x: alongX, y: min(area.minY + margin, rangeY.upperBound))
        case .bottom:
            origin = CGPoint(x: alongX, y: max(area.maxY - size.height - margin, area.minY))
        }
        return (CGRect(origin: origin, size: size), edge.isHorizontal ? rangeX : rangeY)
    }

    private func tabItems(for windows: [TrackedWindow]) -> [TabBarState.Tab] {
        var appCounts: [pid_t: Int] = [:]
        for window in windows { appCounts[window.pid, default: 0] += 1 }
        return windows.map { window in
            // 같은 앱의 창이 여럿이면 앱 이름만으로 구분이 안 되므로 창 제목을 쓴다.
            let useTitle = (appCounts[window.pid] ?? 0) > 1 && !window.title.isEmpty
            let label = useTitle ? window.title : (window.appName.isEmpty ? window.title : window.appName)
            return TabBarState.Tab(id: window.id, pid: window.pid, label: label)
        }
    }

    /// 모든 창을 탭 순서(처음 본 순서)로 늘어놓은 것.
    private func allWindowsInTabOrder() -> [TrackedWindow] {
        ordered.sorted { (firstSeen[$0.id] ?? 0) < (firstSeen[$1.id] ?? 0) }
    }

    /// 지금 키보드 입력을 받고 있는 창. 알 수 없으면 맨 앞 창.
    private func focusedWindow() -> TrackedWindow? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let window = ordered.first(where: { $0.pid == pid }) {
            return window
        }
        return ordered.first
    }

    /// 전체 창 목록을 쓰고 있는 화면 가운데에 띄우거나 숨긴다.
    private func renderOverview() {
        let windows = allWindowsInTabOrder()
        guard enabled, overviewVisible, windows.count >= 2,
              let screen = NSScreen.main ?? NSScreen.screens.first, let front = focusedWindow()
        else {
            overviewPanel?.hide()
            return
        }
        let panel: TabBarPanel
        if let existing = overviewPanel {
            panel = existing
        } else {
            panel = TabBarPanel()
            panel.onSelect = { [weak self] id in
                self?.select(id)
                self?.hideOverview()
            }
            panel.onSettings = { [weak self] view in self?.onSettings?(view) }
            overviewPanel = panel
        }
        panel.idleOpacity = 1
        let size = TabBarPanel.size(tabCount: windows.count, horizontal: true)
        let visible = screen.visibleFrame
        let origin = CGPoint(x: max(visible.midX - size.width / 2, visible.minX), y: visible.midY - size.height / 2)
        panel.apply(TabBarState(tabs: tabItems(for: windows), activeID: front.id, pendingID: pendingID,
                                frame: CGRect(origin: origin, size: size), horizontal: true,
                                slideMin: origin.x, slideMax: origin.x))
    }

    private func hideOverview() {
        overviewToken += 1
        overviewVisible = false
        overviewPanel?.hide()
    }

    private func render() {
        renderOverview()
        var states: [TabBarState] = []
        var placed: [CGRect] = []
        if enabled, let primaryHeight = NSScreen.screens.first?.frame.height {
            for zone in zones where zone.windows.count >= 2 && zone.bounds.width >= minZoneWidth {
                guard let front = zone.windows.first else { continue }
                let placement = barPlacement(for: zone)
                var slot = placement.frame
                if anchor == .screen {
                    // 좌우로 나란한 두 영역처럼 같은 화면 가장자리의 같은 자리에 바가 겹치면, 가장자리를 따라 옆으로 비켜 놓는다.
                    var attempts = 0
                    while let hit = placed.first(where: { $0.intersects(slot) }), attempts < 16 {
                        if edge.isHorizontal {
                            slot.origin.x = hit.maxX + 6
                        } else {
                            slot.origin.y = hit.maxY + 6
                        }
                        attempts += 1
                    }
                }

                // 영역 밖의 다른 창이 탭 바 자리를 덮고 있으면 그 위로 떠 보이지 않게 숨긴다.
                let frontIndex = ordered.firstIndex { $0.id == front.id } ?? 0
                // 화면에 붙일 때는 바가 다른 영역의 창 위에 놓이는 것이 정상이므로 이 검사를 하지 않는다.
                let covered = anchor == .window
                    && ordered[..<frontIndex].contains { !zone.contains($0.id) && $0.frame.intersects(slot) }
                if covered { continue }
                placed.append(slot)

                let tabStates = tabItems(for: tabOrder(zone))
                let cocoaFrame = CGRect(x: slot.minX, y: primaryHeight - slot.maxY,
                                        width: slot.width, height: slot.height)
                // 움직일 수 있는 범위도 Cocoa 좌표로 바꾼다. 세로 방향은 위아래가 뒤집힌다.
                let range = placement.slideRange
                let slideMin = edge.isHorizontal ? range.lowerBound : primaryHeight - range.upperBound - slot.height
                let slideMax = edge.isHorizontal ? range.upperBound : primaryHeight - range.lowerBound - slot.height
                let pending = pendingID.flatMap { zone.contains($0) ? $0 : nil }
                states.append(TabBarState(tabs: tabStates, activeID: front.id, pendingID: pending, frame: cocoaFrame,
                                          horizontal: edge.isHorizontal, slideMin: slideMin, slideMax: slideMax))
            }
        }

        while panels.count < states.count {
            let panel = TabBarPanel()
            panel.idleOpacity = idleOpacity
            panel.onSelect = { [weak self] id in self?.select(id) }
            panel.onSettings = { [weak self] view in self?.onSettings?(view) }
            panel.onSlide = { [weak self] position in
                self?.slide = position
                self?.onSlideChanged?(position)
            }
            panels.append(panel)
        }
        for (index, panel) in panels.enumerated() {
            if index < states.count {
                panel.apply(states[index])
            } else {
                panel.hide()
            }
        }
    }

    // MARK: - 전환

    private func select(_ id: CGWindowID) {
        pendingID = nil
        guard let zoneIndex = zones.firstIndex(where: { $0.contains(id) }),
              let windowIndex = zones[zoneIndex].windows.firstIndex(where: { $0.id == id })
        else { return }
        let window = zones[zoneIndex].windows[windowIndex]
        // 대상 앱이 느리게 응답해도 메인 스레드가 멈추지 않도록 백그라운드에서 요청한다.
        scanQueue.async { WindowScanner.focus(window) }

        // 다음 폴링을 기다리지 않고 바로 반영한다. 연속 입력 시에도 다음 탭으로 넘어가게 된다.
        zones[zoneIndex].windows.remove(at: windowIndex)
        zones[zoneIndex].windows.insert(window, at: 0)
        if zoneIndex != 0 {
            let zone = zones.remove(at: zoneIndex)
            zones.insert(zone, at: 0)
        }
        if let orderedIndex = ordered.firstIndex(where: { $0.id == id }) {
            let moved = ordered.remove(at: orderedIndex)
            ordered.insert(moved, at: 0)
        }
        render()
    }

    /// 단축키를 적용할 영역을 고른다. 전환할 창이 2개 이상인 영역만 대상이다.
    private func targetZoneIndex() -> Int? {
        let candidates = zones.indices.filter { zones[$0].windows.count >= 2 }
        guard !candidates.isEmpty else { return nil }

        if cycleTarget == .pointer, let primaryHeight = NSScreen.screens.first?.frame.height {
            // 마우스 위치를 창 좌표계(왼쪽 위 원점)로 바꿔서, 그 지점을 덮고 있는 영역을 찾는다.
            let mouse = NSEvent.mouseLocation
            let point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
            if let index = candidates.first(where: { zones[$0].bounds.contains(point) }) {
                return index
            }
        }

        // 키보드 입력을 받는 앱의 창 중 맨 앞에 있는 것이 지금 쓰고 있는 창이다.
        // 그 창이 속한 영역을 고르므로, 모니터가 여러 대여도 실제로 쓰고 있는 쪽이 잡힌다.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let focused = ordered.first(where: { $0.pid == pid }),
           let index = candidates.first(where: { zones[$0].contains(focused.id) }) {
            return index
        }
        // 쓰고 있는 창이 어느 묶음에도 없으면 아무것도 하지 않는다. 엉뚱한 모니터의 창이 바뀌는 것보다 낫다.
        return nil
    }

    /// 대상 영역 안에서 다음/이전 창으로 넘어간다. confirmMode면 고르기만 한다.
    func cycle(reverse: Bool) {
        guard enabled else { return }
        if cycleTarget == .all {
            cycleAllWindows(reverse: reverse)
            return
        }

        // 이미 고르는 중이면 마우스나 포커스가 어디 있든 그 영역 안에서 계속 고른다.
        var index: Int?
        if let pending = pendingID {
            index = zones.firstIndex { $0.windows.count >= 2 && $0.contains(pending) }
        }
        if index == nil {
            pendingID = nil
            index = targetZoneIndex()
        }
        guard let zoneIndex = index, let front = zones[zoneIndex].windows.first else { return }

        let tabs = tabOrder(zones[zoneIndex])
        let from = pendingID ?? front.id
        guard let current = tabs.firstIndex(where: { $0.id == from }) else { return }
        let next = (current + (reverse ? tabs.count - 1 : 1)) % tabs.count

        if confirmMode {
            pendingID = tabs[next].id
            render()
            // 한동안 입력이 없으면 고르던 것을 취소한다.
            pendingToken += 1
            let token = pendingToken
            DispatchQueue.main.asyncAfter(deadline: .now() + selectionTimeout) { [weak self] in
                guard let self = self, self.pendingToken == token else { return }
                self.cancelSelection()
            }
        } else {
            select(tabs[next].id)
            // 전환한 영역은 맨 앞으로 오므로 그 바가 첫 번째 패널이다.
            panels.first?.flash()
        }
    }

    /// 영역 구분 없이 모든 창을 차례로 넘긴다. 어느 창이 선택되는지는 화면 가운데의 전체 목록으로 보여 준다.
    private func cycleAllWindows(reverse: Bool) {
        let windows = allWindowsInTabOrder()
        guard windows.count >= 2, let from = pendingID ?? focusedWindow()?.id else { return }
        let current = windows.firstIndex { $0.id == from } ?? 0
        let next = windows[(current + (reverse ? windows.count - 1 : 1)) % windows.count]

        overviewToken += 1
        let token = overviewToken
        overviewVisible = true
        if confirmMode {
            pendingID = next.id
            render()
            pendingToken += 1
            let pending = pendingToken
            DispatchQueue.main.asyncAfter(deadline: .now() + selectionTimeout) { [weak self] in
                guard let self = self, self.pendingToken == pending else { return }
                self.cancelSelection()
            }
        } else {
            select(next.id)
            // 바로 전환하는 방식에서는 목록을 잠깐만 보여 주고 치운다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, self.overviewToken == token else { return }
                self.hideOverview()
            }
        }
    }

    /// 고르던 창으로 전환한다.
    func confirmSelection() {
        guard let id = pendingID else { return }
        pendingToken += 1
        select(id)
        hideOverview()
    }

    /// 고르기를 그만두고 아무것도 바꾸지 않는다.
    func cancelSelection() {
        guard pendingID != nil else { return }
        pendingToken += 1
        pendingID = nil
        overviewVisible = false
        render()
    }
}
