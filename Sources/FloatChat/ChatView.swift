import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var settings: AppSettings
    @FocusState private var inputFocused: Bool
    @State private var showSettings = false
    @State private var showHistory = false

    init(model: ChatModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            messageList
            if !model.pendingImages.isEmpty { attachmentStrip }
            inputBar
        }
        .background(VisualEffectBackground().ignoresSafeArea())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.attach(urls: [url]) } }
                }
            }
            return true
        }
        .onChange(of: model.focusInput) { inputFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 60)  // room for the close button
            Picker("", selection: $settings.backend) {
                ForEach(BackendKind.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(model.isRunning)

            Spacer()

            iconButton(settings.alwaysOnTop ? "pin.fill" : "pin", help: "Keep on top") {
                settings.alwaysOnTop.toggle()
                model.setPinned(settings.alwaysOnTop)
            }
            iconButton("clock.arrow.circlepath", help: "History") { showHistory.toggle() }
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    HistoryView(model: model) { showHistory = false }
                }
            iconButton("square.and.pencil", help: "New chat") { model.newChat() }
            iconButton("gearshape", help: "Settings") { showSettings.toggle() }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsView(settings: settings, hotKeyLabel: model.hotKeyLabel)
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty { emptyState }
                    ForEach(model.messages) { MessageRow(message: $0) }
                    if model.isRunning {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: model.messages) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.isRunning) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 34))
                .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Ask anything")
                .font(.title2.weight(.semibold))
            Text(verbatim: "\(settings.backend.title) · \(abbreviated(settings.workingDir))")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                suggestion(String(localized: "Explain this screenshot"), symbol: "camera.viewfinder") { model.captureScreen() }
                suggestion(String(localized: "What's in this folder?"), symbol: "folder")
                suggestion(String(localized: "Why is my build failing?"), symbol: "hammer")
            }
            .padding(.top, 6)

            Text("\(model.hotKeyLabel) to show or hide · Esc to hide · ⌘V pastes images")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    /// An example prompt; clicking it fills the input (or runs `action` when given).
    private func suggestion(_ text: String, symbol: String, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action {
                action()
            } else {
                model.input = text
                inputFocused = true
            }
        } label: {
            Label { Text(verbatim: text) } icon: { Image(systemName: symbol) }
                .frame(maxWidth: 260, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingImages, id: \.self) { url in
                    ZStack(alignment: .topTrailing) {
                        Thumbnail(url: url, size: 52)
                        Button {
                            model.pendingImages.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 6) {
            TextField("Ask \(settings.backend.title)…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { model.send() }

            HStack(spacing: 6) {
                iconButton("plus", help: "Add images") { model.pickImages() }
                iconButton("camera.viewfinder", help: "Take a screenshot") { model.captureScreen() }
                Toggle(isOn: $settings.fullAccess) {
                    Text(settings.fullAccess ? LocalizedStringKey("Full access") : "Read-only")
                        .font(.callout)
                        .foregroundStyle(settings.fullAccess ? .orange : .secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.leading, 6)
                .help("Read-only: read files and search. Full access: edit files and run commands.")
                Spacer()
                if model.isRunning {
                    Button(action: model.stop) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else {
                    Button(action: model.send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.input.isEmpty && model.pendingImages.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .padding(10)
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .foregroundStyle(.secondary)
        .help(help)
    }
}

func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.images.isEmpty {
                        HStack { ForEach(message.images, id: \.self) { Thumbnail(url: $0, size: 80) } }
                    }
                    if !message.text.isEmpty {
                        Text(verbatim: message.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.18)))
                    }
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(markdown(message.text))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copy")
            }
        case .tool:
            Label { Text(verbatim: message.text) } icon: { Image(systemName: "wrench.and.screwdriver") }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        case .error:
            Label { Text(verbatim: message.text) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct Thumbnail: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Group {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Shows a soft rounded highlight on hover so the clickable area is obvious.
struct HoverButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : hovering ? 0.08 : 0))
            )
            .onHover { hovering = $0 }
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var model: ChatModel
    let dismiss: () -> Void
    @State private var query = ""

    private var items: [Conversation] {
        guard !query.isEmpty else { return model.history }
        return model.history.filter { c in
            c.title.localizedCaseInsensitiveContains(query)
                || c.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search chats…", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
            if items.isEmpty {
                Text(model.history.isEmpty ? LocalizedStringKey("No chats yet") : "No matching chats")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { c in row(c) }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func row(_ c: Conversation) -> some View {
        HStack(spacing: 8) {
            Button {
                model.open(c)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: c.title).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(c.updatedAt, format: .relative(presentation: .named))
                        ForEach(c.sessionIDs.keys.sorted(), id: \.self) { k in
                            Text(verbatim: BackendKind(rawValue: k)?.title ?? k)
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(c.id == model.currentID ? 0.15 : 0))
            )

            Button {
                model.delete(c)
            } label: {
                Image(systemName: "trash").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .foregroundStyle(.secondary)
            .help("Delete")
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let hotKeyLabel: String

    var body: some View {
        Form {
            HStack {
                TextField("Working folder", text: $settings.workingDir)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.level = .modalPanel
                    if p.runModal() == .OK, let url = p.url { settings.workingDir = url.path }
                }
            }
            TextField("Claude model (blank = default)", text: $settings.claudeModel)
            TextField("Codex model (blank = default)", text: $settings.codexModel)
            Toggle("Full access (edit files and run commands)", isOn: $settings.fullAccess)
            Text("Hotkey: \(hotKeyLabel) · Window position is remembered")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360)
    }
}
