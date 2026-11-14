import AppKit

/// 선택된 창이 화면의 어디에 있는지 보여 주는 테두리. 클릭은 그대로 아래 창으로 통과한다.
final class HighlightPanel: NSPanel {
    private let border = NSView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        border.wantsLayer = true
        border.layer?.borderWidth = 5
        border.layer?.cornerRadius = 12
        contentView = border
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// frame은 Cocoa 좌표계.
    func show(at frame: CGRect) {
        // 강조색은 시스템 설정에 따라 바뀔 수 있으므로 띄울 때마다 다시 읽는다.
        let accent = NSColor.controlAccentColor
        border.layer?.borderColor = accent.cgColor
        border.layer?.backgroundColor = accent.withAlphaComponent(0.10).cgColor
        if self.frame != frame { setFrame(frame, display: true) }
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}
