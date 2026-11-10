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
}

private enum Metrics {
    /// 아이콘 한 변의 길이. 나머지 치수는 모두 여기에 비례한다.
    static var iconSize: CGFloat = 24
    static var cell: CGFloat { round(iconSize * 1.5) }
    static var padding: CGFloat { max(3, round(iconSize * 0.2)) }
    static var gap: CGFloat { max(2, round(iconSize * 0.12)) }
    static var cellRadius: CGFloat { round(iconSize * 0.38) }
    static var barRadius: CGFloat { round(iconSize * 0.58) }
}

final class TabItemView: NSView {
    var onClick: (() -> Void)?

    init(frame: CGRect, icon: NSImage?, title: String, active: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cellRadius
        layer?.backgroundColor = active ? NSColor.white.withAlphaComponent(0.28).cgColor : NSColor.clear.cgColor
        toolTip = title

        let inset = (frame.width - Metrics.iconSize) / 2
        let iconView = NSImageView(frame: CGRect(x: inset, y: (frame.height - Metrics.iconSize) / 2,
                                                 width: Metrics.iconSize, height: Metrics.iconSize))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 아이콘이 클릭을 가져가지 않게 탭 전체가 직접 받는다.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
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

/// 영역 오른쪽에 떠 있는 세로형 플로팅 바. 평소에는 반투명하고 마우스를 올리면 선명해진다.
/// 클릭해도 ZoneTabs 자체가 활성화되지 않는 패널이다.
final class TabBarPanel: NSPanel {
    var onSelect: ((CGWindowID) -> Void)?
    /// 마우스가 올라와 있지 않을 때의 불투명도(0~1).
    var idleOpacity: CGFloat = 0.35 { didSet { updateAlpha(animated: false) } }

    private var current: TabBarState?
    private var hovering = false
    private let background = HoverBackgroundView()

    /// 아이콘 크기(pt). 바꾸면 다음에 그릴 때부터 적용된다.
    static var iconSize: CGFloat {
        get { Metrics.iconSize }
        set { Metrics.iconSize = newValue }
    }

    static func size(tabCount: Int, horizontal: Bool) -> CGSize {
        let count = CGFloat(tabCount)
        let short = Metrics.cell + Metrics.padding * 2
        let long = Metrics.cell * count + Metrics.gap * max(count - 1, 0) + Metrics.padding * 2
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
        let target: CGFloat = hovering ? 1 : idleOpacity
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
        orderOut(nil)
    }

    func apply(_ newState: TabBarState) {
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
                icon: icon, title: tab.label, active: tab.id == newState.activeID)
            let id = tab.id
            item.onClick = { [weak self] in self?.onSelect?(id) }
            background.addSubview(item)
            if newState.horizontal {
                x += Metrics.cell + Metrics.gap
            } else {
                y -= Metrics.cell + Metrics.gap
            }
        }

        if !wasVisible {
            // 새로 나타날 때는 마우스 위치를 직접 확인해 호버 상태를 맞춘다.
            hovering = newState.frame.contains(NSEvent.mouseLocation)
            updateAlpha(animated: false)
        }
        display()
        orderFrontRegardless()
    }
}
