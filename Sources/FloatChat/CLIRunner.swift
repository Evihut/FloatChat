import Foundation

enum AgentEvent {
    case session(String)
    case textDelta(String)  // appended to the current reply
    case text(String)       // a complete reply
    case tool(String)       // a tool call notice
    case error(String)
    case done
}

/// Runs `claude -p`, `codex exec` or `agy -p` (Antigravity CLI, for Gemini) as a child process and parses its JSONL output, calling back on the main thread.
final class CLIRunner {
    struct Config {
        var backend: BackendKind
        var prompt: String
        var images: [URL]
        var sessionID: String?
        var workingDir: String
        var fullAccess: Bool
        var model: String
        var attachmentsDir: URL
    }

    private let config: Config
    private let emit: (AgentEvent) -> Void
    private let process = Process()
    private var buffer = Data()
    private var stderrText = ""
    private var receivedText = false
    private var finished = false
    private var stopped = false
    private var seenToolSteps = Set<Int>()
    private var lastTextStep: Int?

    init(config: Config, onEvent: @escaping (AgentEvent) -> Void) {
        self.config = config
        self.emit = { event in DispatchQueue.main.async { onEvent(event) } }
    }

    func start() {
        let name = config.backend.command
        guard let exe = ShellEnv.which(name) else {
            emit(.error(String(localized: "Could not find the `\(name)` command. Install it and sign in once from Terminal.")))
            emit(.done)
            return
        }

        process.executableURL = URL(fileURLWithPath: exe)
        switch config.backend {
        case .claude: process.arguments = claudeArgs()
        case .codex: process.arguments = codexArgs()
        case .gemini: process.arguments = geminiArgs()
        }
        process.environment = ShellEnv.environment
        var isDir: ObjCBool = false
        let cwd = FileManager.default.fileExists(atPath: config.workingDir, isDirectory: &isDir) && isDir.boolValue
            ? config.workingDir : NSHomeDirectory()
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self.stderrText += s
        }
        process.terminationHandler = { [weak self] p in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let rest = stdout.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { self.consume(rest) }
            self.finish(status: p.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            emit(.error(String(localized: "Failed to start \(name): \(error.localizedDescription)")))
            emit(.done)
            return
        }
        // Send the prompt on stdin so it never collides with variadic options (agy takes it as --prompt=)
        if config.backend != .gemini {
            stdin.fileHandleForWriting.write(fullPrompt().data(using: .utf8)!)
        }
        try? stdin.fileHandleForWriting.close()
    }

    func stop() {
        stopped = true
        if process.isRunning { process.terminate() }
    }

    // MARK: - Arguments

    private func fullPrompt() -> String {
        // Claude and agy have no image flag; list the paths and let the agent open them with its file tool
        guard config.backend != .codex, !config.images.isEmpty else { return config.prompt }
        let list = config.images.map { "- \($0.path)" }.joined(separator: "\n")
        return config.prompt + "\n\nAttached images (open them with your file reading tool):\n" + list
    }

    private func claudeArgs() -> [String] {
        var a = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        if let id = config.sessionID { a += ["--resume", id] }
        if !config.model.isEmpty { a += ["--model", config.model] }
        a += ["--add-dir", config.attachmentsDir.path]
        if config.fullAccess {
            a += ["--permission-mode", "bypassPermissions"]
        } else {
            a += ["--allowedTools", "Read,Glob,Grep,WebSearch,WebFetch"]
        }
        return a
    }

    private func codexArgs() -> [String] {
        var a = ["exec"]
        if config.sessionID != nil { a += ["resume"] }
        a += ["--json", "--skip-git-repo-check"]
        a += ["-c", "sandbox_mode=\"\(config.fullAccess ? "danger-full-access" : "read-only")\""]
        if !config.model.isEmpty { a += ["-m", config.model] }
        for img in config.images { a += ["-i", img.path] }
        if let id = config.sessionID { a += [id] }
        a += ["-"]  // read the prompt from stdin
        return a
    }

    private func geminiArgs() -> [String] {
        // "=" keeps a prompt that starts with "-" from being read as a flag
        var a = ["--prompt=" + fullPrompt(), "--output-format", "stream-json"]
        if let id = config.sessionID { a += ["--conversation", id] }
        if !config.model.isEmpty { a += ["--model", config.model] }
        a += ["--add-dir", config.attachmentsDir.path]
        // agy's default mode still runs commands and edits headlessly, so read-only needs plan mode
        a += config.fullAccess ? ["--dangerously-skip-permissions"] : ["--mode", "plan"]
        return a
    }

    // MARK: - Parsing

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch config.backend {
            case .claude: parseClaude(obj)
            case .codex: parseCodex(obj)
            case .gemini: parseGemini(obj)
            }
        }
    }

    private func parseClaude(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init", let id = o["session_id"] as? String { emit(.session(id)) }
        case "stream_event":
            guard let ev = o["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let t = delta["text"] as? String else { return }
            receivedText = true
            emit(.textDelta(t))
        case "assistant":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for c in content where c["type"] as? String == "tool_use" {
                emit(.tool(Self.describeTool(c["name"] as? String ?? "tool", c["input"] as? [String: Any] ?? [:])))
            }
        case "result":
            if let id = o["session_id"] as? String { emit(.session(id)) }
            let result = o["result"] as? String ?? ""
            if o["is_error"] as? Bool == true {
                emit(.error(result.isEmpty ? String(localized: "Claude returned an error") : result))
            } else if !receivedText, !result.isEmpty {
                emit(.text(result))
            }
            receivedText = true
        default:
            break
        }
    }

    private func parseCodex(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "thread.started":
            if let id = o["thread_id"] as? String { emit(.session(id)) }
        case "item.started":
            guard let item = o["item"] as? [String: Any] else { return }
            if item["type"] as? String == "command_execution", let cmd = item["command"] as? String {
                emit(.tool("$ " + cmd))
            }
        case "item.completed":
            guard let item = o["item"] as? [String: Any] else { return }
            switch item["type"] as? String {
            case "agent_message":
                if let t = item["text"] as? String { receivedText = true; emit(.text(t)) }
            case "file_change":
                let paths = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
                emit(.tool(String(localized: "Edit") + " " + paths.map(abbreviated).joined(separator: ", ")))
            case "web_search":
                emit(.tool(String(localized: "Search") + " " + (item["query"] as? String ?? "")))
            case "mcp_tool_call":
                emit(.tool("\(item["server"] as? String ?? "mcp").\(item["tool"] as? String ?? "")"))
            default:
                break
            }
        case "turn.failed":
            let msg = (o["error"] as? [String: Any])?["message"] as? String ?? String(localized: "Codex run failed")
            emit(.error(Self.unwrapErrorMessage(msg)))
            receivedText = true
        case "error":
            // Duplicates turn.failed; only useful when that never arrives, so keep it for the final check
            if let msg = o["message"] as? String { stderrText += "\n" + Self.unwrapErrorMessage(msg) }
        default:
            break
        }
    }

    private func parseGemini(_ o: [String: Any]) {
        switch o["event"] as? String {
        case "init":
            if let id = o["conversation_id"] as? String, !id.isEmpty { emit(.session(id)) }
        case "step_update":
            let s = o["step_update"] as? [String: Any] ?? [:]
            let step = s["step_index"] as? Int ?? -1
            switch s["step_type"] as? String {
            case "agent_response":
                guard let t = s["text_delta"] as? String, !t.isEmpty else { return }
                // a new response step after earlier text starts a new paragraph
                if let last = lastTextStep, last != step { emit(.textDelta("\n\n")) }
                lastTextStep = step
                receivedText = true
                emit(.textDelta(t))
            case "tool":
                guard !seenToolSteps.contains(step), let name = s["tool_name"] as? String else { return }
                seenToolSteps.insert(step)
                let params = (s["tool_info"] as? [String: Any])?["parameters"] as? [String: Any] ?? [:]
                // plan mode keeps its own notes under ~/.gemini; that's bookkeeping, not the user's files
                if let path = params["Path"] as? String, path.contains("/.gemini/antigravity-cli/") { return }
                lastTextStep = nil
                emit(.tool(Self.describeTool(name, params)))
            default:
                break
            }
        case "result":
            guard let r = o["result"] as? [String: Any] else { return }
            if let id = r["conversation_id"] as? String, !id.isEmpty { emit(.session(id)) }
            let response = r["response"] as? String ?? ""
            if let status = r["status"] as? String, status != "SUCCESS" {
                let err = r["error"] as? String ?? ""
                emit(.error(err.isEmpty ? String(localized: "Gemini run ended with status \(status)") : err))
            } else if !receivedText, !response.isEmpty {
                emit(.text(response))
            }
            receivedText = true
        default:
            break
        }
    }

    private func finish(status: Int32) {
        guard !finished else { return }
        finished = true
        if stopped {
            emit(.tool(String(localized: "Stopped")))
        } else if status != 0 && !receivedText {
            let tail = stderrText.split(separator: "\n").suffix(6).joined(separator: "\n")
            emit(.error(tail.isEmpty ? String(localized: "Process exited with code \(status)") : tail))
        }
        emit(.done)
    }

    // MARK: - Helpers

    static func describeTool(_ name: String, _ input: [String: Any]) -> String {
        // agy uses keys like "CommandLine" and "Path"; compare without case or underscores
        let normalized = Dictionary(input.map { ($0.key.lowercased().replacingOccurrences(of: "_", with: ""), $0.value) },
                                    uniquingKeysWith: { a, _ in a })
        let keys = ["command", "commandline", "filepath", "path", "absolutepath", "pattern", "query", "url", "description"]
        for k in keys {
            if let v = normalized[k] as? String { return "\(name): \(k.hasSuffix("path") ? abbreviated(v) : v)" }
        }
        return name
    }

    /// Codex errors are often nested JSON; pull out the innermost message.
    static func unwrapErrorMessage(_ s: String) -> String {
        guard let data = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return s }
        if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return o["message"] as? String ?? s
    }
}

/// Apps launched from Finder don't get the Terminal PATH, so read it once from a login shell.
enum ShellEnv {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var path = env["PATH"] ?? "/usr/bin:/bin"
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !s.isEmpty {
                path = s
            }
        }
        let home = NSHomeDirectory()
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin"]
        where !path.split(separator: ":").contains(Substring(extra)) {
            path += ":" + extra
        }
        env["PATH"] = path
        return env
    }()

    static func which(_ name: String) -> String? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let full = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}
