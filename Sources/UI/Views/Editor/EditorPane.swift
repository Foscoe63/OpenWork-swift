import SwiftUI
import AppKit

/// The code editor: open files as tabs, with the state a person needs to trust what they are
/// editing — unsaved marks, a banner when the agent changed the file underneath them, and a
/// status bar that says where the cursor is and how the file is encoded.
public struct EditorPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var editors: EditorWorkspace

    /// Hide the tab strip when the host shows its own file list (Artifacts & Files).
    var showsTabs: Bool

    @AppStorage("editorWrapLines") private var wrapLines = false
    @State private var cursor = (line: 1, column: 1)
    @State private var showingGoToLine = false
    @State private var goToLineText = ""
    @State private var showingQuickOpen = false
    @State private var comparing: EditorDocument?
    @State private var closeCandidate: EditorDocument?

    @MainActor
    public init(appState: AppState, editors: EditorWorkspace? = nil, showsTabs: Bool = true) {
        self.appState = appState
        self.editors = editors ?? .shared
        self.showsTabs = showsTabs
    }

    private var theme: AppTheme { appState.settings.theme }

    public var body: some View {
        VStack(spacing: 0) {
            if showsTabs {
                tabStrip
                Divider()
            }
            if let document = editors.activeDocument {
                DocumentChrome(
                    appState: appState,
                    document: document,
                    wrapLines: $wrapLines,
                    onSave: { save(document) },
                    onMention: { mention(document) },
                    onCompare: { comparing = document },
                    onQuickOpen: { showingQuickOpen = true }
                )
                CodeEditorView(
                    document: document,
                    theme: theme,
                    fontSize: CGFloat(max(9, min(28, appState.settings.editorFontSize))),
                    wrapLines: wrapLines,
                    workspaceSymbols: editors.workspaceSymbols,
                    onSave: { save(document) },
                    onGoToLine: { showingGoToLine = true },
                    onCommandClick: { goToDefinition($0) },
                    onCursorChange: { line, column in cursor = (line, column) }
                )
                .id(document.id)
                statusBar(document)
            } else {
                emptyState
            }
        }
        .background(ThemeColors.bg(for: theme))
        .popover(isPresented: $showingGoToLine, arrowEdge: .top) { goToLinePopover }
        .popover(isPresented: $showingQuickOpen, arrowEdge: .top) {
            QuickOpenList(appState: appState) { path in
                showingQuickOpen = false
                open(path)
            }
        }
        .sheet(item: $comparing) { document in
            VisualDiffInspectorView(
                appState: appState,
                filePath: document.path,
                originalText: document.conflictingDiskText ?? "",
                modifiedText: document.text,
                onAccept: {
                    document.resolveByKeepingMine()
                    comparing = nil
                },
                acceptTitle: "Keep My Version",
                onReject: {
                    document.resolveByReloading()
                    comparing = nil
                },
                rejectTitle: "Take the Version on Disk"
            )
            .frame(minWidth: 760, minHeight: 520)
        }
        .confirmationDialog(
            "Close \(closeCandidate?.fileName ?? "file") without saving?",
            isPresented: Binding(get: { closeCandidate != nil }, set: { if !$0 { closeCandidate = nil } }),
            presenting: closeCandidate
        ) { document in
            Button("Save and Close") {
                save(document)
                if !document.isDirty { editors.close(document.id) }
            }
            Button("Discard Changes", role: .destructive) { editors.close(document.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your unsaved edits will be lost.")
        }
    }

    // MARK: Tabs

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(editors.documents) { document in
                        EditorTab(
                            appState: appState,
                            document: document,
                            isActive: document.id == editors.activeDocumentId,
                            onSelect: { editors.activeDocumentId = document.id },
                            onClose: { requestClose(document) }
                        )
                        .contextMenu {
                            Button("Close") { requestClose(document) }
                            Button("Close Other Saved Tabs") { editors.closeOthers(keeping: document.id) }
                            Divider()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.path)])
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(document.path, forType: .string)
                            }
                            Button("Mention in Chat") { mention(document) }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            Button {
                showingQuickOpen = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.hitTestable)
            .help("Open a workspace file (⇧⌘O)")
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .frame(height: 32)
        .background(ThemeColors.sidebarBg(for: theme))
    }

    private func requestClose(_ document: EditorDocument) {
        if document.isDirty {
            closeCandidate = document
        } else {
            editors.close(document.id)
        }
    }

    // MARK: Status

    private func statusBar(_ document: EditorDocument) -> some View {
        HStack(spacing: 12) {
            Text("Ln \(cursor.line), Col \(cursor.column)")
            Text(document.language.displayName)
            Text(document.indentation.label)
            Text(document.lineEnding.rawValue)
            Text("UTF-8")
            Spacer()
            // A timeline, so the notice goes away on its own rather than at the next redraw.
            TimelineView(.periodic(from: .now, by: 2)) { context in
                if let reloaded = document.lastExternalReload, context.date.timeIntervalSince(reloaded) < 8 {
                    Label("Reloaded — changed on disk", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(.blue)
                }
            }
            SuggestionStatusMenu(appState: appState)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(ThemeColors.textSecondary(for: theme))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(ThemeColors.sidebarBg(for: theme))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("No file open")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ThemeColors.textPrimary(for: theme))
            Text("Open files from Artifacts & Files, a build error, or a diff on a tool card.")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button {
                showingQuickOpen = true
            } label: {
                Label("Open a File…", systemImage: "magnifyingglass")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var goToLinePopover: some View {
        HStack(spacing: 8) {
            Text("Line")
            TextField("1", text: $goToLineText)
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
                .onSubmit { goToLine() }
            Button("Go") { goToLine() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Actions

    private func goToLine() {
        showingGoToLine = false
        guard let line = Int(goToLineText.trimmingCharacters(in: .whitespaces)), line > 0,
              let document = editors.activeDocument else { return }
        document.pendingReveal = line
        goToLineText = ""
    }

    private func save(_ document: EditorDocument) {
        do {
            try document.save()
            appState.showToast("Saved \(document.fileName)")
        } catch {
            appState.showToast(error.localizedDescription)
        }
    }

    private func open(_ path: String, line: Int? = nil) {
        do {
            try editors.open(path: path, line: line, workspaceRoot: appState.currentWorkspace.folderPath)
        } catch {
            appState.showToast(error.localizedDescription)
        }
    }

    private func goToDefinition(_ name: String) {
        let root = appState.currentWorkspace.folderPath
        Task {
            if let found = await editors.definition(of: name, workspaceRoot: root) {
                open(found.path, line: found.line)
            } else {
                appState.showToast("No declaration of \(name) found in the workspace")
            }
        }
    }

    /// Put `@path:line` in the composer, which attaches the lines around it when sent.
    private func mention(_ document: EditorDocument) {
        let relative = EditorWorkspace.relativePath(document.path, root: appState.currentWorkspace.folderPath)
        let token = "@\(relative):\(cursor.line) "
        if appState.composerText.isEmpty {
            appState.composerText = token
        } else if !appState.composerText.contains(token.trimmingCharacters(in: .whitespaces)) {
            appState.composerText += (appState.composerText.hasSuffix(" ") ? "" : " ") + token
        }
        appState.showToast("Added \(relative):\(cursor.line) to the message")
    }
}

// MARK: - Pieces

private struct EditorTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject var document: EditorDocument
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(isActive ? ThemeColors.accent(for: appState.settings.accentColor) : .secondary)
            Text(document.fileName)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))
                .lineLimit(1)
            ZStack {
                if document.isDirty && !hovering {
                    Circle().fill(Color.primary.opacity(0.7)).frame(width: 7, height: 7)
                } else {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.hitTestable)
                    .opacity(hovering || isActive ? 1 : 0)
                    .help("Close")
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(isActive ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(document.path)
    }

    private var icon: String {
        switch document.language {
        case .swift: return "swift"
        case .json: return "curlybraces"
        case .markdown: return "doc.plaintext"
        case .html, .xml: return "chevron.left.slash.chevron.right"
        default: return "doc.text"
        }
    }
}

/// Banner and toolbar for the active document. Observes the document so its dirty and disk state
/// redraw without re-rendering the text view.
private struct DocumentChrome: View {
    @ObservedObject var appState: AppState
    @ObservedObject var document: EditorDocument
    @Binding var wrapLines: Bool
    let onSave: () -> Void
    let onMention: () -> Void
    let onCompare: () -> Void
    let onQuickOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(EditorWorkspace.relativePath(document.path, root: appState.currentWorkspace.folderPath))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(document.path)
                Spacer()
                Button(action: onMention) {
                    Image(systemName: "at")
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.hitTestable)
                .help("Mention this line in the chat composer")
                Toggle(isOn: $wrapLines) {
                    Image(systemName: "text.word.spacing")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Wrap long lines")
                Button("Save", action: onSave)
                    .controlSize(.small)
                    .disabled(!document.isDirty)
                    .help("Save (⌘S)")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)

            if document.diskState == .conflict {
                banner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "\(document.fileName) changed on disk while you have unsaved edits — probably the agent. Nothing has been overwritten."
                ) {
                    Button("Compare…", action: onCompare)
                    Button("Take Disk Version") { document.resolveByReloading() }
                    Button("Keep Mine") { document.resolveByKeepingMine() }
                }
            } else if document.diskState == .deleted {
                banner(
                    icon: "trash",
                    tint: .red,
                    text: "\(document.fileName) was deleted from disk. Save to write it back."
                ) {
                    EmptyView()
                }
            }
            Divider()
        }
        .background(ThemeColors.sidebarBg(for: appState.settings.theme).opacity(0.6))
    }

    private func banner<Actions: View>(
        icon: String,
        tint: Color,
        text: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(tint)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            actions()
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
    }
}

/// Type part of a path, pick a file.
struct QuickOpenList: View {
    @ObservedObject var appState: AppState
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var files: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Open file…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if let first = matches.first { pick(first) }
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(matches.prefix(60), id: \.self) { file in
                        Button {
                            pick(file)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((file as NSString).lastPathComponent)
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(file)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.hitTestable)
                    }
                }
            }
            .frame(height: 280)
        }
        .padding(10)
        .frame(width: 380)
        .onAppear {
            focused = true
            let root = appState.currentWorkspace.folderPath
            Task.detached(priority: .userInitiated) {
                let listed = WorkspaceFileScanner.listFiles(at: root)
                await MainActor.run { files = listed }
            }
        }
    }

    private var matches: [String] {
        QuickOpenMatcher.rank(files: files, query: query)
    }

    private func pick(_ relative: String) {
        onPick((appState.currentWorkspace.folderPath as NSString).appendingPathComponent(relative))
    }
}

/// Fuzzy file matching for Quick Open. Pure, for tests.
public enum QuickOpenMatcher {
    /// Files whose path contains the query's characters in order, best first: a match in the file
    /// name beats one spread across directories, and a contiguous match beats a scattered one.
    public static func rank(files: [String], query: String) -> [String] {
        let needle = query.lowercased().filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return files.sorted { $0.count < $1.count } }
        var scored: [(String, Int)] = []
        for file in files {
            guard let score = score(path: file, needle: needle) else { continue }
            scored.append((file, score))
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.count < $1.0.count : $0.1 > $1.1 }.map(\.0)
    }

    static func score(path: String, needle: String) -> Int? {
        let lowerPath = path.lowercased()
        let name = (lowerPath as NSString).lastPathComponent
        if name.hasPrefix(needle) { return 1_000 - name.count }
        if name.contains(needle) { return 800 - name.count }
        if lowerPath.contains(needle) { return 600 - lowerPath.count }
        // Subsequence.
        var index = lowerPath.startIndex
        var gaps = 0
        var last: String.Index?
        for character in needle {
            guard let found = lowerPath[index...].firstIndex(of: character) else { return nil }
            if let last, lowerPath.index(after: last) != found { gaps += 1 }
            last = found
            index = lowerPath.index(after: found)
        }
        return 300 - gaps * 10 - lowerPath.count / 4
    }
}


/// The status bar's view of AI suggestions: whether they are on, which model writes them, what it
/// is doing, and how long the last one took.
struct SuggestionStatusMenu: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var engine = InlineSuggestionEngine.shared

    var body: some View {
        Menu {
            Toggle("Inline AI Suggestions", isOn: $appState.settings.inlineSuggestionsEnabled)
            Divider()
            Picker("Suggestion Model", selection: modelSelection) {
                Text("Automatic — chat model when it runs on this Mac").tag(SuggestionModelOption.automatic)
                ForEach(SuggestionModelOption.options(from: appState.providers), id: \.self) { option in
                    Text(option.label(in: appState.providers)).tag(option)
                }
            }
            .disabled(!appState.settings.inlineSuggestionsEnabled)
            Divider()
            Text("Suggestions appear when you pause typing. ⇥ accepts, esc dismisses.")
            Text("The local model is used only when it is idle; an agent turn never waits.")
        } label: {
            HStack(spacing: 4) {
                if engine.status == .thinking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon)
                }
                Text(label)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(help)
        .onAppear { engine.refreshStatus() }
        .onChange(of: appState.settings.inlineSuggestionsEnabled) { _, _ in engine.refreshStatus() }
        .onChange(of: appState.settings.inlineSuggestionModelId) { _, _ in engine.refreshStatus() }
        .onChange(of: appState.currentModel.id) { _, _ in engine.refreshStatus() }
    }

    private var modelSelection: Binding<SuggestionModelOption> {
        SuggestionModelOption.binding(appState)
    }

    private var icon: String {
        switch engine.status {
        case .off: return "sparkles.slash"
        case .unavailable: return "exclamationmark.triangle"
        case .ready, .thinking: return "sparkles"
        }
    }

    private var label: String {
        switch engine.status {
        case .off: return "AI off"
        case .thinking: return "AI…"
        case .unavailable: return "AI unavailable"
        case .ready(let model):
            let short = model.split(separator: "/").last.map(String.init) ?? model
            return engine.lastLatencyMs.map { "AI · \(short.prefix(18)) · \($0)ms" } ?? "AI · \(short.prefix(18))"
        }
    }

    private var help: String {
        switch engine.status {
        case .off: return "Inline AI suggestions are off"
        case .thinking: return "Writing a suggestion"
        case .unavailable(let why): return why
        case .ready(let model): return "Suggestions by \(model)"
        }
    }
}

enum SuggestionModelOption: Hashable {
    case automatic
    case model(providerId: String, modelId: String)

    /// The choice as stored in settings, for pickers in the editor and in Settings.
    @MainActor
    static func binding(_ appState: AppState) -> Binding<SuggestionModelOption> {
        Binding(
            get: {
                appState.settings.inlineSuggestionProviderId.isEmpty
                    ? .automatic
                    : .model(providerId: appState.settings.inlineSuggestionProviderId, modelId: appState.settings.inlineSuggestionModelId)
            },
            set: { option in
                var settings = appState.settings
                switch option {
                case .automatic:
                    settings.inlineSuggestionProviderId = ""
                    settings.inlineSuggestionModelId = ""
                case .model(let providerId, let modelId):
                    settings.inlineSuggestionProviderId = providerId
                    settings.inlineSuggestionModelId = modelId
                }
                appState.settings = settings
            }
        )
    }

    static func options(from providers: [ModelProvider]) -> [SuggestionModelOption] {
        providers.filter(\.isEnabled).flatMap { provider in
            provider.models.map { SuggestionModelOption.model(providerId: provider.id, modelId: $0.id) }
        }
    }

    func label(in providers: [ModelProvider]) -> String {
        guard case .model(let providerId, let modelId) = self else { return "Automatic" }
        let provider = providers.first { $0.id == providerId }
        let name = provider?.models.first { $0.id == modelId }?.name ?? modelId
        let place = provider?.type == .cloud ? "cloud — sends code to \(provider?.name ?? "the provider")" : (provider?.name ?? "")
        return "\(name) (\(place))"
    }
}
