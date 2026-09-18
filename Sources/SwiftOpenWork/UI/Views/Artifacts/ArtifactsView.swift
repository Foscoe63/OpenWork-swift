import SwiftUI
import AppKit
import SwiftOpenWorkCore

public struct ArtifactsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var editors = EditorWorkspace.shared
    @State private var files: [String] = []
    @State private var selectedFileName: String? = nil
    /// What the selected file actually is. Anything other than `.text` is shown as a notice, never
    /// opened in the editor, so nothing can save a placeholder over a binary file.
    @State private var selectedContent: WorkspaceFileScanner.Content = .text("")
    @State private var rightPaneMode: RightPaneMode = .editor

    private enum RightPaneMode: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case canvas = "Live Canvas"
        var id: String { rawValue }
    }
    @State private var newFileName: String = ""
    @State private var showingNewFileSheet: Bool = false

    /// How often the workspace is rescanned while this view is on screen.
    private static let rescanInterval: Duration = .seconds(2.5)

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HSplitView {
            // Left Workspace File Explorer
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WORKSPACE FILES")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        Text(appState.currentWorkspace.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    }

                    Spacer()

                    Button {
                        showingNewFileSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    }
                    .buttonStyle(.hitTestable)
                    .help("Create New File")

                    Button {
                        loadFiles()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .buttonStyle(.hitTestable)
                    .help("Refresh")
                }
                .padding(12)
                .background(ThemeColors.sidebarBg(for: appState.settings.theme))

                Divider()

                // Staged Pipeline Folders Quick Access (Cowork Input / Output pattern)
                if appState.currentWorkspace.isPipelineStagingEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PIPELINE STAGES")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            .padding(.horizontal, 10)
                            .padding(.top, 6)

                        HStack(spacing: 6) {
                            Button {
                                appState.ensurePipelineFoldersExist(for: appState.currentWorkspace)
                                let path = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(appState.currentWorkspace.inputFolderPath)
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: appState.currentWorkspace.folderPath)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "tray.and.arrow.down.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                    Text("📥 input/")
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(5)
                            }
                            .buttonStyle(.hitTestable)
                            .help("Drop raw invoices, receipts, and source drafts here")

                            Button {
                                appState.ensurePipelineFoldersExist(for: appState.currentWorkspace)
                                let path = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(appState.currentWorkspace.outputFolderPath)
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: appState.currentWorkspace.folderPath)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "tray.and.arrow.up.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.green)
                                    Text("📤 output/")
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.12))
                                .cornerRadius(5)
                            }
                            .buttonStyle(.hitTestable)
                            .help("Transformed PDFs, summaries, and generated reports appear here")
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)

                        Divider()
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if files.isEmpty {
                            VStack(spacing: 6) {
                                Text("No files in this workspace folder.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding(20)
                        } else {
                            ForEach(files, id: \.self) { file in
                                let isSelected = selectedFileName == file
                                Button {
                                    selectFile(file)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: fileIcon(for: file))
                                            .font(.system(size: 11))
                                            .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
                                        // Entries are workspace-relative paths now, so truncate
                                        // the directory rather than the filename.
                                        Text(file)
                                            .font(.system(size: 11.5))
                                            .foregroundColor(isSelected ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .help(file)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            // Right File Viewer / Editor / Live Canvas
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let selected = selectedFileName {
                        HStack(spacing: 6) {
                            Image(systemName: fileIcon(for: selected))
                                .font(.system(size: 12))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                            Text(selected)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        }
                    } else {
                        Text("No File Selected")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }

                    Spacer()

                    if selectedFileName != nil {
                        if selectedContent.isEditable {
                            Picker("", selection: $rightPaneMode) {
                                ForEach(RightPaneMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }

                        Button("Reveal in Finder") {
                            guard let sel = selectedFileName else { return }
                            let path = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(sel)
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: appState.currentWorkspace.folderPath)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(12)
                .background(ThemeColors.sidebarBg(for: appState.settings.theme))

                Divider()

                if let sel = selectedFileName {
                    if selectedContent.isEditable {
                        switch rightPaneMode {
                        case .editor:
                            // The same editor as the chat inspector: highlighting, undo, unsaved
                            // marks, and a banner when the agent rewrites the file you have open.
                            EditorPane(appState: appState, showsTabs: false)
                        case .canvas:
                            LiveArtifactWorkbenchView(
                                appState: appState,
                                fileName: sel,
                                content: editors.activeDocument?.text ?? ""
                            )
                        }
                    } else {
                        unopenableFileNotice(selectedContent)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("Select a file from the left sidebar to preview and edit workspace artifacts.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .onAppear {
            loadFiles()
        }
        .task {
            await rescanUntilCancelled()
        }
        .sheet(isPresented: $showingNewFileSheet) {
            VStack(spacing: 14) {
                Text("Create New File").font(.headline)
                TextField("filename.txt / main.swift", text: $newFileName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showingNewFileSheet = false; newFileName = "" }
                    Spacer()
                    Button("Create") {
                        createNewFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newFileName.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 340)
        }
    }

    private func loadFiles() {
        files = WorkspaceFileScanner.listFiles(at: appState.currentWorkspace.folderPath)
        selectActiveEditorFileIfListed()
    }

    /// Show what is already open in the editor rather than opening a tab for whichever file sorts
    /// first — visiting this page used to put `.gitignore` in front of you.
    private func selectActiveEditorFileIfListed() {
        guard selectedFileName == nil, let active = editors.activeDocument else { return }
        let relative = EditorWorkspace.relativePath(active.path, root: appState.currentWorkspace.folderPath)
        if files.contains(relative) {
            selectFile(relative)
        }
    }

    /// Agents write into the workspace while this view is open, so the list has to keep up
    /// without the user thinking to press refresh.
    ///
    /// Driven from `.task`, which starts when the view appears and is cancelled when it goes
    /// away. A `Timer.publish` stored on the struct would be rebuilt on every re-render — and
    /// `appState` publishes often enough that the interval could keep resetting before it fired.
    private func rescanUntilCancelled() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.rescanInterval)
            guard !Task.isCancelled else { return }

            let root = appState.currentWorkspace.folderPath
            // Off the main actor: walking a large tree should not stutter the UI.
            let found = await Task.detached(priority: .utility) {
                WorkspaceFileScanner.listFiles(at: root)
            }.value

            // A no-op unless the listing actually changed, so the open file and the current
            // selection survive the rescan.
            guard root == appState.currentWorkspace.folderPath, found != files else { continue }
            files = found
            if let selected = selectedFileName, !files.contains(selected) {
                // Deleted or moved underneath us. An open editor tab keeps its text and says the
                // file is gone, so unsaved work is not lost with the listing entry.
                selectedFileName = nil
                selectedContent = .text("")
            }
            selectActiveEditorFileIfListed()
        }
    }

    private func selectFile(_ name: String) {
        selectedFileName = name
        let fullPath = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(name)
        let content = WorkspaceFileScanner.read(path: fullPath)
        // Only real text reaches the editor. It used to be handed the error message for a binary
        // file, which Save Changes then wrote over the file.
        guard case .text = content else {
            selectedContent = content
            return
        }
        do {
            try editors.open(path: fullPath, workspaceRoot: appState.currentWorkspace.folderPath)
            selectedContent = content
        } catch {
            selectedContent = .unreadable(reason: error.localizedDescription)
        }
    }

    /// Shown in place of the editor for anything that must not be edited.
    @ViewBuilder
    private func unopenableFileNotice(_ content: WorkspaceFileScanner.Content) -> some View {
        let (symbol, headline, detail): (String, String, String) = {
            switch content {
            case .binary(let bytes):
                return ("doc.badge.gearshape",
                        "Binary file",
                        "\(WorkspaceFileScanner.humanReadableSize(bytes)) — not UTF-8 text. Editing is disabled so saving cannot overwrite it.")
            case .tooLarge(let bytes):
                return ("doc.badge.ellipsis",
                        "File too large to edit",
                        "\(WorkspaceFileScanner.humanReadableSize(bytes)) exceeds the \(WorkspaceFileScanner.humanReadableSize(WorkspaceFileScanner.maxEditableBytes)) editor limit. Open it in Finder instead.")
            case .unreadable(let reason):
                return ("exclamationmark.triangle", "Cannot read this file", reason)
            case .text:
                return ("doc.text", "", "")
            }
        }()

        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }

    private func createNewFile() {
        guard !newFileName.isEmpty else { return }
        let fullPath = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(newFileName)
        do {
            // The listing is recursive, so "notes/todo.md" is a reasonable thing to type here.
            let parent = (fullPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: fullPath) else {
                appState.showToast("\(newFileName) already exists")
                return
            }
            try "".write(toFile: fullPath, atomically: true, encoding: .utf8)
            showingNewFileSheet = false
            let created = newFileName
            newFileName = ""
            loadFiles()
            selectFile(created)
            appState.showToast("Created \(created)")
        } catch {
            appState.showToast("Error creating file: \(error.localizedDescription)")
        }
    }

    private func fileIcon(for file: String) -> String {
        if file.hasSuffix(".swift") { return "swift" }
        if file.hasSuffix(".json") { return "curlybraces" }
        if file.hasSuffix(".md") { return "doc.plaintext" }
        if file.hasSuffix(".yml") || file.hasSuffix(".yaml") { return "gearshape.2" }
        return "doc"
    }
}
