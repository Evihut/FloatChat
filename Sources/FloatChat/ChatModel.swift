import AppKit
import Combine
import UniformTypeIdentifiers

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant, tool, error }
    var id = UUID()
    var role: Role
    var text: String
    var images: [URL] = []
}

/// 一次对话。Claude 和 Codex 各自的会话 id 都挂在同一个对话下。
struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title = "新对话"
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    var sessionIDs: [String: String] = [:]  // BackendKind.rawValue -> CLI 会话 id
}

/// 每个对话存成一个 JSON：~/Library/Application Support/FloatChat/conversations/<id>.json
enum HistoryStore {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloatChat/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func loadAll() -> [Conversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ c: Conversation) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: dir.appendingPathComponent("\(c.id.uuidString).json"), options: .atomic)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
    }
}

enum BackendKind: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var backend: BackendKind { didSet { d.set(backend.rawValue, forKey: "backend") } }
    @Published var fullAccess: Bool { didSet { d.set(fullAccess, forKey: "fullAccess") } }
    @Published var workingDir: String { didSet { d.set(workingDir, forKey: "workingDir") } }
    @Published var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }
    @Published var codexModel: String { didSet { d.set(codexModel, forKey: "codexModel") } }
    @Published var alwaysOnTop: Bool { didSet { d.set(alwaysOnTop, forKey: "alwaysOnTop") } }

    init() {
        backend = BackendKind(rawValue: d.string(forKey: "backend") ?? "") ?? .claude
        fullAccess = d.bool(forKey: "fullAccess")
        workingDir = d.string(forKey: "workingDir") ?? FileManager.default.homeDirectoryForCurrentUser.path
        claudeModel = d.string(forKey: "claudeModel") ?? ""
        codexModel = d.string(forKey: "codexModel") ?? ""
        alwaysOnTop = d.object(forKey: "alwaysOnTop") as? Bool ?? true
    }
}

final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var pendingImages: [URL] = []
    @Published var isRunning = false
    @Published var focusInput = 0
    @Published var hotKeyLabel = ""
    @Published var history: [Conversation] = HistoryStore.loadAll()
    @Published private(set) var currentID = UUID()

    let settings = AppSettings()
    var hidePanel: () -> Void = {}
    var showPanel: () -> Void = {}
    var setPinned: (Bool) -> Void = { _ in }

    private var runner: CLIRunner?
    // 当前对话里每个后端各自的会话 id，用于多轮对话 (--resume)
    private var sessionIDs: [BackendKind: String] = [:]
    private var settingsSink: AnyCancellable?

    init() {
        // 设置里的变化需要刷新界面
        settingsSink = settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    static let attachmentsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloatChat/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Sending

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty || !pendingImages.isEmpty else { return }
        let images = pendingImages
        var prompt = text.isEmpty ? "请看这张图片。" : text
        let backend = settings.backend
        // 对话中途换了后端：新后端没有上下文，把之前的聊天记录带过去
        if sessionIDs[backend] == nil, let transcript = transcript() {
            prompt = "以下是本次对话之前的记录（可能来自另一个 AI 助手），供你参考：\n\n\(transcript)\n\n---\n用户的新消息：\n\(prompt)"
        }

        messages.append(ChatMessage(role: .user, text: text, images: images))
        input = ""
        pendingImages = []
        isRunning = true
        let config = CLIRunner.Config(
            backend: backend,
            prompt: prompt,
            images: images,
            sessionID: sessionIDs[backend],
            workingDir: settings.workingDir,
            fullAccess: settings.fullAccess,
            model: backend == .claude ? settings.claudeModel : settings.codexModel,
            attachmentsDir: Self.attachmentsDir
        )
        let runner = CLIRunner(config: config) { [weak self] event in
            self?.handle(event, backend: backend)
        }
        self.runner = runner
        runner.start()
    }

    func stop() {
        runner?.stop()
    }

    func newChat() {
        stop()
        persist()
        messages = []
        sessionIDs = [:]
        currentID = UUID()
        isRunning = false
    }

    func open(_ c: Conversation) {
        guard c.id != currentID else { return }
        stop()
        persist()
        currentID = c.id
        messages = c.messages
        sessionIDs = Dictionary(uniqueKeysWithValues: c.sessionIDs.compactMap { k, v in
            BackendKind(rawValue: k).map { ($0, v) }
        })
        isRunning = false
    }

    func delete(_ c: Conversation) {
        HistoryStore.delete(c.id)
        history.removeAll { $0.id == c.id }
        if c.id == currentID {
            messages = []
            sessionIDs = [:]
            currentID = UUID()
        }
    }

    /// 把当前对话写盘并刷新历史列表；空对话不保存。
    /// touch=false 用于切换对话时，不改动排序时间。
    private func persist(touch: Bool = false) {
        guard messages.contains(where: { $0.role == .user }) else { return }
        let firstUser = messages.first { $0.role == .user }?.text ?? ""
        let title = firstUser.isEmpty ? "图片" : String(firstUser.prefix(40))
        let c = Conversation(
            id: currentID,
            title: title,
            updatedAt: touch ? Date() : history.first { $0.id == currentID }?.updatedAt ?? Date(),
            messages: messages,
            sessionIDs: Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0.key.rawValue, $0.value) })
        )
        HistoryStore.save(c)
        history.removeAll { $0.id == currentID }
        history.append(c)
        history.sort { $0.updatedAt > $1.updatedAt }
    }

    private func transcript() -> String? {
        let lines = messages.compactMap { m -> String? in
            switch m.role {
            case .user: return "用户：\(m.text)"
            case .assistant: return "助手：\(m.text)"
            default: return nil
            }
        }
        guard !lines.isEmpty else { return nil }
        // 太长只保留最近的部分
        return String(lines.joined(separator: "\n\n").suffix(12000))
    }

    private func handle(_ event: AgentEvent, backend: BackendKind) {
        switch event {
        case .session(let id):
            sessionIDs[backend] = id
        case .textDelta(let s):
            if let last = messages.indices.last, messages[last].role == .assistant {
                messages[last].text += s
            } else {
                messages.append(ChatMessage(role: .assistant, text: s))
            }
        case .text(let s):
            messages.append(ChatMessage(role: .assistant, text: s))
        case .tool(let s):
            messages.append(ChatMessage(role: .tool, text: s))
        case .error(let s):
            messages.append(ChatMessage(role: .error, text: s))
        case .done:
            isRunning = false
            runner = nil
            persist(touch: true)
        }
    }

    // MARK: - Attachments

    func attach(urls: [URL]) {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
        for url in urls where imageExts.contains(url.pathExtension.lowercased()) {
            pendingImages.append(url)
        }
    }

    /// 剪贴板里有图片就存成附件并返回 true（文字粘贴照常走文本框）。
    func attachFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        // Finder 里复制的图片文件
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let before = pendingImages.count
            attach(urls: urls)
            if pendingImages.count > before { return true }
        }
        guard pb.availableType(from: [.png, .tiff]) != nil,
              pb.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pb),
              let url = savePNG(image) else { return false }
        pendingImages.append(url)
        return true
    }

    func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.level = .modalPanel
        if panel.runModal() == .OK { attach(urls: panel.urls) }
        showPanel()
    }

    /// 隐藏小窗 → 系统框选截图 → 作为附件加回来。
    func captureScreen() {
        hidePanel()
        let url = Self.attachmentsDir.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", url.path]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: url.path) { self.pendingImages.append(url) }
                self.showPanel()
            }
        }
    }

    private func savePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = Self.attachmentsDir.appendingPathComponent("paste-\(UUID().uuidString.prefix(8)).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
