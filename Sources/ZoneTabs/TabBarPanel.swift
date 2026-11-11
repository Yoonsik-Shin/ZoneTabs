import AppKit

/// 탭 바 하나에 그릴 내용. 바뀌지 않았으면 다시 그리지 않으려고 Equatable로 둔다.
struct TabBarState: Equatable {
    struct Tab: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let label: String
    }
    var tabs: [Tab]
    var activeID: CGWindowID
    /// 바의 위치와 크기(Cocoa 좌표계).
    var frame: CGRect
    /// true면 아이콘을 가로로, false면 세로로 늘어놓는다.
    var horizontal: Bool
    /// 바를 끌어서 옮길 수 있는 범위. 가로형이면 frame.origin.x, 세로형이면 frame.origin.y가 움직일 수 있는 최소·최대값이다.
    var slideMin: CGFloat
    var slideMax: CGFloat
}

private enum Metrics {
    /// 아이콘 한 변의 길이. 나머지 치수는 모두 여기에 비례한다.
    static var iconSize: CGFloat = 24
    static var cell: CGFloat { round(iconSize * 1.5) }
    static var padding: CGFloat { max(3, round(iconSize * 0.2)) }
    static var gap: CGFloat { max(2, round(iconSize * 0.12)) }
    static var cellRadius: CGFloat { round(iconSize * 0.38) }
    static var barRadius: CGFloat { round(iconSize * 0.58) }
    /// 설정 버튼이 바의 진행 방향으로 차지하는 길이.
    static var gearLength: CGFloat { max(16, round(iconSize * 0.9)) }
    static var gearIcon: CGFloat { max(11, round(iconSize * 0.55)) }
}

/// 바 안의 버튼 하나(앱 아이콘 또는 설정 버튼). 클릭과 끌기를 구분해서 알려 준다.
final class TabItemView: NSView {
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    /// 끌기 시작 지점으로부터의 이동량(화면 좌표).
    var onDragMoved: ((CGFloat, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var pressLocation = NSPoint.zero
    private var dragging = false

    init(frame: CGRect, icon: NSImage?, iconSize: CGFloat, tint: NSColor?, title: String, active: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cellRadius
        layer?.backgroundColor = active ? NSColor.white.withAlphaComponent(0.28).cgColor : NSColor.clear.cgColor
        toolTip = title

        let iconView = NSImageView(frame: CGRect(x: (frame.width - iconSize) / 2, y: (frame.height - iconSize) / 2,
                                                 width: iconSize, height: iconSize))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let tint = tint { iconView.contentTintColor = tint }
        addSubview(iconView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 아이콘이 클릭을 가져가지 않게 버튼 전체가 직접 받는다.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - pressLocation.x
        let dy = now.y - pressLocation.y
        if !dragging {
            // 클릭하다 살짝 흔들린 것은 끌기로 보지 않는다.
            guard hypot(dx, dy) > 4 else { return }
            dragging = true
            onDragBegan?()
        }
        onDragMoved?(dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            onDragEnded?()
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

/// 마우스가 올라왔는지 알려 주는 배경 뷰.
final class HoverBackgroundView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea = hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// 영역 가장자리에 떠 있는 플로팅 바. 평소에는 반투명하고 마우스를 올리면 선명해진다.
/// 클릭해도 ZoneTabs 자체가 활성화되지 않는 패널이다.
final class TabBarPanel: NSPanel {
    var onSelect: ((CGWindowID) -> Void)?
    /// 설정 버튼을 눌렀을 때. 인자는 메뉴를 띄울 기준 뷰.
    var onSettings: ((NSView) -> Void)?
    /// 바를 끌어서 옮겼을 때. 인자는 가장자리를 따라 0(왼쪽/위)~1(오른쪽/아래) 사이의 위치.
    var onSlide: ((CGFloat) -> Void)?
    /// 마우스가 올라와 있지 않을 때의 불투명도(0~1).
    var idleOpacity: CGFloat = 0.35 { didSet { updateAlpha(animated: false) } }

    private var current: TabBarState?
    private var hovering = false
    private var dragOrigin: NSPoint?
    private let background = HoverBackgroundView()

    /// 아이콘 크기(pt). 바꾸면 다음에 그릴 때부터 적용된다.
    static var iconSize: CGFloat {
        get { Metrics.iconSize }
        set { Metrics.iconSize = newValue }
    }

    static func size(tabCount: Int, horizontal: Bool) -> CGSize {
        let count = CGFloat(tabCount)
        let short = Metrics.cell + Metrics.padding * 2
        let long = Metrics.cell * count + Metrics.gap * count + Metrics.gearLength + Metrics.padding * 2
        return horizontal ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        allowsToolTipsWhenApplicationIsInactive = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.updateAlpha(animated: true)
        }
        contentView = background
        alphaValue = idleOpacity
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func updateAlpha(animated: Bool) {
        let target: CGFloat = (hovering || dragOrigin != nil) ? 1 : idleOpacity
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = target
            }
        } else {
            alphaValue = target
        }
    }

    func hide() {
        current = nil
        hovering = false
        dragOrigin = nil
        orderOut(nil)
    }

    // MARK: - 끌어서 옮기기

    private func dragBegan() {
        dragOrigin = frame.origin
        updateAlpha(animated: false)
    }

    private func dragMoved(dx: CGFloat, dy: CGFloat) {
        guard let start = dragOrigin, let state = current else { return }
        var origin = start
        // 붙어 있는 가장자리를 따라서만 움직인다.
        if state.horizontal {
            origin.x = min(max(start.x + dx, state.slideMin), state.slideMax)
        } else {
            origin.y = min(max(start.y + dy, state.slideMin), state.slideMax)
        }
        setFrameOrigin(origin)
    }

    private func dragEnded() {
        guard dragOrigin != nil, let state = current else { return }
        dragOrigin = nil
        let span = state.slideMax - state.slideMin
        if span > 1 {
            // Cocoa 좌표는 아래가 0이므로 세로형은 뒤집어서 "위가 0"이 되게 한다.
            let position = state.horizontal
                ? (frame.origin.x - state.slideMin) / span
                : 1 - (frame.origin.y - state.slideMin) / span
            onSlide?(min(max(position, 0), 1))
        }
        hovering = frame.contains(NSEvent.mouseLocation)
        updateAlpha(animated: true)
    }

    private func attachDrag(to item: TabItemView) {
        item.onDragBegan = { [weak self] in self?.dragBegan() }
        item.onDragMoved = { [weak self] dx, dy in self?.dragMoved(dx: dx, dy: dy) }
        item.onDragEnded = { [weak self] in self?.dragEnded() }
    }

    // MARK: - 그리기

    func apply(_ newState: TabBarState) {
        // 끄는 도중에 다시 그리면 잡고 있던 버튼이 사라지므로 끝날 때까지 미룬다.
        if dragOrigin != nil { return }
        if newState == current, isVisible { return }
        let wasVisible = isVisible
        current = newState

        setFrame(newState.frame, display: false)
        background.layer?.cornerRadius = Metrics.barRadius

        background.subviews.forEach { $0.removeFromSuperview() }
        // 가로형은 왼쪽부터, 세로형은 위부터 배치한다(Cocoa 좌표는 아래가 0이라 위에서 내려간다).
        var x = Metrics.padding
        var y = newState.horizontal ? Metrics.padding : newState.frame.height - Metrics.padding - Metrics.cell
        for tab in newState.tabs {
            let icon = NSRunningApplication(processIdentifier: tab.pid)?.icon
            let item = TabItemView(
                frame: CGRect(x: x, y: y, width: Metrics.cell, height: Metrics.cell),
                icon: icon, iconSize: Metrics.iconSize, tint: nil,
                title: tab.label, active: tab.id == newState.activeID)
            let id = tab.id
            item.onClick = { [weak self] in self?.onSelect?(id) }
            attachDrag(to: item)
            background.addSubview(item)
            if newState.horizontal {
                x += Metrics.cell + Metrics.gap
            } else {
                y -= Metrics.cell + Metrics.gap
            }
        }

        // 맨 끝의 설정 버튼.
        let gearFrame = newState.horizontal
            ? CGRect(x: x, y: Metrics.padding, width: Metrics.gearLength, height: Metrics.cell)
            : CGRect(x: Metrics.padding, y: Metrics.padding, width: Metrics.cell, height: Metrics.gearLength)
        let gearImage = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "설정")
        let gear = TabItemView(frame: gearFrame, icon: gearImage, iconSize: Metrics.gearIcon,
                               tint: NSColor.white.withAlphaComponent(0.75),
                               title: "설정 (끌어서 바 옮기기)", active: false)
        gear.onClick = { [weak self, weak gear] in
            guard let self = self, let gear = gear else { return }
            self.onSettings?(gear)
        }
        attachDrag(to: gear)
        background.addSubview(gear)

        if !wasVisible {
            // 새로 나타날 때는 마우스 위치를 직접 확인해 호버 상태를 맞춘다.
            hovering = newState.frame.contains(NSEvent.mouseLocation)
            updateAlpha(animated: false)
        }
        display()
        orderFrontRegardless()
    }
}
