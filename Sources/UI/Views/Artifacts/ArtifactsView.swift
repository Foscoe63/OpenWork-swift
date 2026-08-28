import SwiftUI
import AppKit

public struct ArtifactsView: View {
    @ObservedObject var appState: AppState
    @State private var files: [String] = []
    @State private var selectedFileName: String? = nil
    @State private var fileContent: String = ""
    @State private var isSaving: Bool = false
    @State private var newFileName: String = ""
    @State private var showingNewFileSheet: Bool = false

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
                    .buttonStyle(.plain)
                    .help("Create New File")

                    Button {
                        loadFiles()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .buttonStyle(.plain)
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
                            .buttonStyle(.plain)
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
                            .buttonStyle(.plain)
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
                                Text("No files found in workspace directory.")
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
                                        Text(file)
                                            .font(.system(size: 11.5))
                                            .foregroundColor(isSelected ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
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
                        Button("Reveal in Finder") {
                            guard let sel = selectedFileName else { return }
                            let path = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(sel)
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: appState.currentWorkspace.folderPath)
                        }
                        .font(.system(size: 11))

                        Button("Save Changes") {
                            saveCurrentFile()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(ThemeColors.sidebarBg(for: appState.settings.theme))

                Divider()

                if let sel = selectedFileName {
                    TabView {
                        // Tab 1: Live Interactive Canvas
                        LiveArtifactWorkbenchView(appState: appState, fileName: sel, content: fileContent)
                            .tabItem {
                                Label("Live Canvas", systemImage: "sparkles.tv")
                            }

                        // Tab 2: Raw Code Editor
                        TextEditor(text: $fileContent)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(12)
                            .background(ThemeColors.bg(for: appState.settings.theme))
                            .tabItem {
                                Label("Source Editor", systemImage: "doc.text")
                            }
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
        let path = appState.currentWorkspace.folderPath
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        files = items.filter { !$0.hasPrefix(".") }.sorted()
        if selectedFileName == nil, let first = files.first {
            selectFile(first)
        }
    }

    private func selectFile(_ name: String) {
        selectedFileName = name
        let fullPath = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(name)
        if let data = try? String(contentsOfFile: fullPath, encoding: .utf8) {
            fileContent = data
        } else {
            fileContent = "Binary or unreadable file format."
        }
    }

    private func saveCurrentFile() {
        guard let name = selectedFileName else { return }
        let fullPath = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(name)
        do {
            try fileContent.write(toFile: fullPath, atomically: true, encoding: .utf8)
            appState.showToast("Saved \(name)")
        } catch {
            appState.showToast("Error saving: \(error.localizedDescription)")
        }
    }

    private func createNewFile() {
        guard !newFileName.isEmpty else { return }
        let fullPath = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(newFileName)
        do {
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
