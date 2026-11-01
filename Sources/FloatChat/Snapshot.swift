import AppKit

/// Renders the panel with a sample conversation to a PNG, then quits.
/// Used to produce the README screenshots: `FLOATCHAT_SNAPSHOT=out.png FloatChat.app/Contents/MacOS/FloatChat`
enum Snapshot {
    static func render(panel: FloatingPanel, chat: ChatModel, to url: URL) {
        if ProcessInfo.processInfo.environment["FLOATCHAT_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        chat.messages = sampleConversation()
        chat.hotKeyLabel = "⌥Space"
        panel.setContentSize(NSSize(width: 440, height: 640))
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Vibrancy can't be captured offscreen; leave it transparent and let the framing script paint the backdrop.
            hideVibrancy(in: panel.contentView)
            guard let view = panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            exit(0)
        }
    }

    private static func hideVibrancy(in view: NSView?) {
        guard let view else { return }
        if view is NSVisualEffectView { view.isHidden = true }
        view.subviews.forEach { hideVibrancy(in: $0) }
    }

    private static func sampleConversation() -> [ChatMessage] {
        let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        if zh {
            return [
                ChatMessage(role: .user, text: "3000 端口被谁占了？如果是没关的开发服务器就关掉。"),
                ChatMessage(role: .tool, text: "Bash: lsof -i :3000"),
                ChatMessage(role: .tool, text: "Bash: kill 48211"),
                ChatMessage(role: .assistant, text: "占用 **3000** 端口的是 `node`（PID 48211），是两天前在 `~/Projects/blog` 启动的 `vite` 开发服务器，已经没在用了，我把它关掉了。\n\n现在端口已经空出来。"),
                ChatMessage(role: .user, text: "谢谢。再用三句话总结一下这个文件夹的 README。"),
                ChatMessage(role: .tool, text: "Read: ~/Projects/FloatChat/README.md"),
                ChatMessage(role: .assistant, text: "• 一个悬浮置顶的小窗，背后是 **Claude Code** 和 **Codex**\n• `⌥Space` 随时呼出，可以读文件、跑命令、看截图\n• 对话历史会保存，同一个对话里可以切换后端"),
            ]
        }
        return [
            ChatMessage(role: .user, text: "What's using port 3000? Kill it if it's a stale dev server."),
            ChatMessage(role: .tool, text: "Bash: lsof -i :3000"),
            ChatMessage(role: .tool, text: "Bash: kill 48211"),
            ChatMessage(role: .assistant, text: "Port **3000** was held by `node` (PID 48211), a `vite` dev server started two days ago in `~/Projects/blog`. It was idle, so I stopped it.\n\nThe port is free now."),
            ChatMessage(role: .user, text: "Thanks. Summarize the README in this folder in three bullets."),
            ChatMessage(role: .tool, text: "Read: ~/Projects/FloatChat/README.md"),
            ChatMessage(role: .assistant, text: "• A tiny always-on-top window for **Claude Code** and **Codex**\n• `⌥Space` from anywhere; it can read files, run commands and see screenshots\n• Conversations are saved, and one chat can switch between backends"),
        ]
    }
}
