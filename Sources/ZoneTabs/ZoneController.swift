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

final class ZoneController {
    var enabled = true { didSet { refresh(force: true) } }
    /// 마우스를 올리지 않았을 때 바의 불투명도(0~1).
    var idleOpacity: CGFloat = 0.35 { didSet { panels.forEach { $0.idleOpacity = idleOpacity } } }

    /// 바를 붙일 가장자리.
    var edge: BarEdge = .right { didSet { render() } }

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

    /// 바가 놓일 자리(왼쪽 위 원점 좌표계). 영역의 맨 앞 창이 화면에서 차지하는 범위 안쪽, 선택한 가장자리의 가운데다.
    /// 창이 화면 끝까지 닿아 있거나 밖으로 나가 있으면 Dock처럼 화면 가장자리에 붙는다.
    private func barFrame(for zone: Zone) -> CGRect {
        let size = TabBarPanel.size(tabCount: zone.windows.count, horizontal: edge.isHorizontal)
        let margin: CGFloat = 4
        // 맨 앞 창을 기준으로 붙인다. 묶음 전체 범위를 쓰면 뒤에 깔린 큰 창 쪽에 바가 떠서
        // 지금 보고 있는 창과 떨어져 보인다.
        let area = zone.rect
        // 영역을 벗어나지 않는 범위에서 가운데 정렬한다.
        let centerX = min(max(area.midX - size.width / 2, area.minX), max(area.maxX - size.width, area.minX))
        let centerY = min(max(area.midY - size.height / 2, area.minY), max(area.maxY - size.height, area.minY))
        let origin: CGPoint
        switch edge {
        case .right:
            origin = CGPoint(x: max(area.maxX - size.width - margin, area.minX), y: centerY)
        case .left:
            origin = CGPoint(x: min(area.minX + margin, max(area.maxX - size.width, area.minX)), y: centerY)
        case .top:
            origin = CGPoint(x: centerX, y: min(area.minY + margin, max(area.maxY - size.height, area.minY)))
        case .bottom:
            origin = CGPoint(x: centerX, y: max(area.maxY - size.height - margin, area.minY))
        }
        return CGRect(origin: origin, size: size)
    }

    private func render() {
        var states: [TabBarState] = []
        if enabled, let primaryHeight = NSScreen.screens.first?.frame.height {
            for zone in zones where zone.windows.count >= 2 && zone.bounds.width >= minZoneWidth {
                guard let front = zone.windows.first else { continue }
                let slot = barFrame(for: zone)

                // 영역 밖의 다른 창이 탭 바 자리를 덮고 있으면 그 위로 떠 보이지 않게 숨긴다.
                let frontIndex = ordered.firstIndex { $0.id == front.id } ?? 0
                let covered = ordered[..<frontIndex].contains { !zone.contains($0.id) && $0.frame.intersects(slot) }
                if covered { continue }

                let tabs = tabOrder(zone)
                var appCounts: [pid_t: Int] = [:]
                for window in tabs { appCounts[window.pid, default: 0] += 1 }
                let tabStates = tabs.map { window -> TabBarState.Tab in
                    // 같은 앱의 창이 여럿이면 앱 이름만으로 구분이 안 되므로 창 제목을 쓴다.
                    let useTitle = (appCounts[window.pid] ?? 0) > 1 && !window.title.isEmpty
                    let label = useTitle ? window.title : (window.appName.isEmpty ? window.title : window.appName)
                    return TabBarState.Tab(id: window.id, pid: window.pid, label: label)
                }
                let cocoaFrame = CGRect(x: slot.minX, y: primaryHeight - slot.maxY,
                                        width: slot.width, height: slot.height)
                states.append(TabBarState(tabs: tabStates, activeID: front.id, frame: cocoaFrame,
                                          horizontal: edge.isHorizontal))
            }
        }

        while panels.count < states.count {
            let panel = TabBarPanel()
            panel.idleOpacity = idleOpacity
            panel.onSelect = { [weak self] id in self?.select(id) }
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

    /// 지금 맨 앞에 있는 창이 속한 영역 안에서 다음/이전 창으로 넘어간다.
    func cycle(reverse: Bool) {
        guard enabled, let zone = zones.first, zone.windows.count >= 2,
              let front = zone.windows.first else { return }
        let tabs = tabOrder(zone)
        guard let current = tabs.firstIndex(where: { $0.id == front.id }) else { return }
        let next = (current + (reverse ? tabs.count - 1 : 1)) % tabs.count
        select(tabs[next].id)
    }
}
