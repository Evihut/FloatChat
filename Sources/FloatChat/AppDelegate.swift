import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var hotKeyLabel = ""
    private var pasteMonitor: Any?
    let chat = ChatModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        chat.hidePanel = { [weak self] in self?.panel.orderOut(nil) }
        chat.showPanel = { [weak self] in self?.showPanel() }
        chat.setPinned = { [weak self] pinned in self?.panel.level = pinned ? .floating : .normal }

        panel = FloatingPanel(rootView: ChatView(model: chat))
        panel.level = chat.settings.alwaysOnTop ? .floating : .normal

        if let out = ProcessInfo.processInfo.environment["FLOATCHAT_SNAPSHOT"] {
            Snapshot.render(panel: panel, chat: chat, to: URL(fileURLWithPath: out))
            return
        }

        setupStatusItem()
        registerHotKey()
        installPasteMonitor()
        showPanel()
    }

    // MARK: - Panel

    func togglePanel() {
        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        chat.focusInput &+= 1
    }

    // MARK: - Hotkey: ⌥Space, falling back to ⌃⌥Space when taken

    private func registerHotKey() {
        let space = UInt32(kVK_Space)
        if let hk = HotKey(keyCode: space, modifiers: UInt32(optionKey), action: { [weak self] in self?.togglePanel() }) {
            hotKey = hk
            hotKeyLabel = "⌥Space"
        } else if let hk = HotKey(keyCode: space, modifiers: UInt32(optionKey | controlKey), action: { [weak self] in self?.togglePanel() }) {
            hotKey = hk
            hotKeyLabel = "⌃⌥Space"
        } else {
            hotKeyLabel = String(localized: "unavailable")
        }
        chat.hotKeyLabel = hotKeyLabel
        rebuildStatusMenu()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "FloatChat")
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Show / Hide  (\(hotKeyLabel))"), action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "New Chat"), action: #selector(menuNewChat), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit FloatChat"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func menuToggle() { togglePanel() }
    @objc private func menuNewChat() { chat.newChat(); showPanel() }

    // Menu-bar-only apps have no main menu, so ⌘C/⌘V/⌘A would not work. Add a hidden Edit menu.
    private func installMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // ⌘V with an image on the clipboard attaches it instead of pasting text
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  event.window === self.panel else { return event }
            return self.chat.attachFromPasteboard() ? nil : event
        }
    }
}
