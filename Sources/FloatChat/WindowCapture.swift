import AppKit

/// A normal app window on screen that can be captured with `screencapture -l`.
struct CapturableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String

    var label: String { title.isEmpty || title == appName ? appName : "\(appName) — \(title)" }
    /// App icon at menu size
    var icon: NSImage? {
        guard let full = NSRunningApplication(processIdentifier: pid)?.icon,
              let small = full.copy() as? NSImage else { return nil }
        small.size = NSSize(width: 16, height: 16)
        return small
    }
}

struct CapturableDisplay: Identifiable, Hashable {
    let index: Int  // screencapture -D number
    let name: String
    var id: Int { index }
}

/// Finds windows to capture and remembers which app the user was last working in.
/// The panel never activates FloatChat, so that app is usually still frontmost, but menus and
/// file dialogs can activate us; tracking the last other app keeps "current window" right.
final class WindowCapture {
    private(set) var lastAppPID: pid_t?
    private var observer: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            lastAppPID = front.processIdentifier
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app != .current else { return }
            self?.lastAppPID = app.processIdentifier
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// On-screen app windows, front to back, excluding FloatChat, menus and tiny utility windows.
    func windows() -> [CapturableWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 80, (b["Height"] ?? 0) >= 80 else { return nil }
            let app = w[kCGWindowOwnerName as String] as? String ?? ""
            // titles are only visible with Screen Recording permission; the app name is enough without it
            let title = w[kCGWindowName as String] as? String ?? ""
            return CapturableWindow(id: id, pid: pid, appName: app, title: title)
        }
    }

    /// The front window of the app the user was last in, or else the frontmost window of any app.
    func currentWindow() -> CapturableWindow? {
        let all = windows()
        if let pid = lastAppPID, let w = all.first(where: { $0.pid == pid }) { return w }
        return all.first
    }

    /// Connected displays, numbered the way `screencapture -D` expects (1 = main display).
    static func displays() -> [CapturableDisplay] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.enumerated().map { i, id in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            return CapturableDisplay(index: i + 1, name: screen?.localizedName ?? String(localized: "Display \(i + 1)"))
        }
    }

    static func capture(_ display: CapturableDisplay, to url: URL) -> Bool {
        run(["-x", "-D", String(display.index), url.path], url: url)
    }

    /// Captures just that window (no shadow), even if other windows cover it.
    static func capture(_ window: CapturableWindow, to url: URL) -> Bool {
        run(["-x", "-o", "-l", String(window.id), url.path], url: url)
    }

    private static func run(_ args: [String], url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }
}
