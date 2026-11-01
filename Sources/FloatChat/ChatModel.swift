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

/// One conversation. Claude and Codex each keep their own CLI session id under it.
struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title = ""
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    var sessionIDs: [String: String] = [:]  // BackendKind.rawValue -> CLI session id
}

/// One JSON file per conversation in ~/Library/Application Support/FloatChat/conversations/
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
    // Per-backend CLI session ids for the current conversation (--resume)
    private var sessionIDs: [BackendKind: String] = [:]
    private var settingsSink: AnyCancellable?

    init() {
        // Re-render when settings change
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
        var prompt = text.isEmpty ? "Please look at the attached image." : text
        let backend = settings.backend
        // Switched backends mid-conversation: hand the new one the transcript so far
        if sessionIDs[backend] == nil, let transcript = transcript() {
            prompt = "Here is the conversation so far (possibly with another AI assistant), for context:\n\n\(transcript)\n\n---\nThe user's new message:\n\(prompt)"
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

    /// Saves the current conversation and refreshes history; empty chats are skipped.
    /// touch=false (when switching chats) keeps its place in the list.
    private func persist(touch: Bool = false) {
        guard messages.contains(where: { $0.role == .user }) else { return }
        let firstUser = messages.first { $0.role == .user }?.text ?? ""
        let title = firstUser.isEmpty ? String(localized: "Image") : String(firstUser.prefix(40))
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
            case .user: return "User: \(m.text)"
            case .assistant: return "Assistant: \(m.text)"
            default: return nil
            }
        }
        guard !lines.isEmpty else { return nil }
        // Keep only the most recent part if it is long
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

    /// Attaches an image from the clipboard and returns true; text pastes go to the text field as usual.
    func attachFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        // Image files copied in Finder
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

    /// Hide the panel, run the interactive screenshot tool, attach the result.
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
