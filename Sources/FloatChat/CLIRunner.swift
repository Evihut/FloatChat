import Foundation

enum AgentEvent {
    case session(String)
    case textDelta(String)  // 追加到当前回复
    case text(String)       // 一条完整回复
    case tool(String)       // 工具调用提示
    case error(String)
    case done
}

/// 以子进程运行 `claude -p` 或 `codex exec`，逐行解析 JSONL 输出并回调到主线程。
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

    init(config: Config, onEvent: @escaping (AgentEvent) -> Void) {
        self.config = config
        self.emit = { event in DispatchQueue.main.async { onEvent(event) } }
    }

    func start() {
        let name = config.backend == .claude ? "claude" : "codex"
        guard let exe = ShellEnv.which(name) else {
            emit(.error("找不到 `\(name)` 命令。请先安装并在终端里登录一次。"))
            emit(.done)
            return
        }

        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = config.backend == .claude ? claudeArgs() : codexArgs()
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
            emit(.error("启动 \(name) 失败：\(error.localizedDescription)"))
            emit(.done)
            return
        }
        // prompt 走 stdin，避免和可变参数选项混在一起
        stdin.fileHandleForWriting.write(fullPrompt().data(using: .utf8)!)
        try? stdin.fileHandleForWriting.close()
    }

    func stop() {
        stopped = true
        if process.isRunning { process.terminate() }
    }

    // MARK: - Arguments

    private func fullPrompt() -> String {
        // Claude 没有图片参数，把图片路径写进 prompt，让它用 Read 工具看图
        guard config.backend == .claude, !config.images.isEmpty else { return config.prompt }
        let list = config.images.map { "- \($0.path)" }.joined(separator: "\n")
        return config.prompt + "\n\n（附图，请用 Read 工具查看）\n" + list
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
        a += ["-"]  // 从 stdin 读 prompt
        return a
    }

    // MARK: - Parsing

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if config.backend == .claude { parseClaude(obj) } else { parseCodex(obj) }
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
                emit(.error(result.isEmpty ? "Claude 返回错误" : result))
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
                emit(.tool("编辑 " + paths.map(abbreviated).joined(separator: ", ")))
            case "web_search":
                emit(.tool("搜索 " + (item["query"] as? String ?? "")))
            case "mcp_tool_call":
                emit(.tool("\(item["server"] as? String ?? "mcp").\(item["tool"] as? String ?? "")"))
            default:
                break
            }
        case "turn.failed":
            let msg = (o["error"] as? [String: Any])?["message"] as? String ?? "Codex 运行失败"
            emit(.error(Self.unwrapErrorMessage(msg)))
            receivedText = true
        case "error":
            // 和 turn.failed 内容重复，只在没有 turn.failed 时有用；记下来最后再判断
            if let msg = o["message"] as? String { stderrText += "\n" + Self.unwrapErrorMessage(msg) }
        default:
            break
        }
    }

    private func finish(status: Int32) {
        guard !finished else { return }
        finished = true
        if stopped {
            emit(.tool("已停止"))
        } else if status != 0 && !receivedText {
            let tail = stderrText.split(separator: "\n").suffix(6).joined(separator: "\n")
            emit(.error(tail.isEmpty ? "进程退出码 \(status)" : tail))
        }
        emit(.done)
    }

    // MARK: - Helpers

    static func describeTool(_ name: String, _ input: [String: Any]) -> String {
        let keys = ["command", "file_path", "path", "pattern", "query", "url", "description"]
        for k in keys {
            if let v = input[k] as? String { return "\(name): \(k == "file_path" || k == "path" ? abbreviated(v) : v)" }
        }
        return name
    }

    /// Codex 的错误常是一段嵌套 JSON，取出最里面的 message。
    static func unwrapErrorMessage(_ s: String) -> String {
        guard let data = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return s }
        if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return o["message"] as? String ?? s
    }
}

/// 从 Finder 启动的 App 拿不到终端里的 PATH，这里从登录 shell 取一次。
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
