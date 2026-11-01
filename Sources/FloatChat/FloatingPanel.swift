import AppKit
import SwiftUI

/// 不抢焦点的悬浮小窗：点它不会让别的 App 失去激活状态，所有桌面/全屏 App 上都能显示。
final class FloatingPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        minSize = NSSize(width: 320, height: 300)
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: rootView)
        contentView = hosting

        if !setFrameUsingName("FloatChatPanel") {
            positionTopRight()
        }
        setFrameAutosaveName("FloatChatPanel")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Esc 隐藏
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    private func positionTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 24))
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
