import SwiftUI
import AppKit

public struct WatchFoldersView: View {
    @ObservedObject var appState: AppState
    @State private var showingCreateModal = false
    @State private var selectedWatchItemForEdit: WatchItem? = nil
    @State private var selectedArtifactForDetail: AutomationArtifact? = nil
    @State private var filterWatchType: String = "all"
    @State private var searchText: String = ""
    @State private var selectedTab: String = "targets" // "targets" or "artifacts"

    public init(appState: AppState) {
        self.appState = appState
    }

    private var filteredWatchItems: [WatchItem] {
        appState.watchItems.filter { item in
            let matchesType = filterWatchType == "all" || item.watchType.rawValue == filterWatchType
            let matchesSearch = searchText.isEmpty ||
                item.name.localizedCaseInsensitiveContains(searchText) ||
                item.description.localizedCaseInsensitiveContains(searchText) ||
                item.path.localizedCaseInsensitiveContains(searchText)
            return matchesType && matchesSearch
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Main Content Area
            if selectedTab == "targets" {
                watchTargetsContent
            } else {
                artifactsHistoryContent
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .sheet(isPresented: $showingCreateModal) {
            WatchItemEditModalView(
                appState: appState,
                isPresented: $showingCreateModal,
                watchItem: nil
            )
        }
        .sheet(item: $selectedWatchItemForEdit) { item in
            WatchItemEditModalView(
                appState: appState,
                isPresented: Binding(
                    get: { selectedWatchItemForEdit != nil },
                    set: { if !$0 { selectedWatchItemForEdit = nil } }
                ),
                watchItem: item
            )
        }
        .sheet(item: $selectedArtifactForDetail) { art in
            ArtifactDetailModalView(
                appState: appState,
                isPresented: Binding(
                    get: { selectedArtifactForDetail != nil },
                    set: { if !$0 { selectedArtifactForDetail = nil } }
                ),
                artifact: art
            )
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Watch Folders & Real-Time Triggers")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                    Text("\(appState.watchItems.filter { $0.isEnabled }.count) Active")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text("Monitor local workspace directories and files on disk to autonomously synthesize Morning Briefs, Daily Updates, and Reports.")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }

            Spacer()

            // View Switcher (Targets vs Generated Artifacts)
            Picker("", selection: $selectedTab) {
                Text("Monitored Targets (\(appState.watchItems.count))").tag("targets")
                Text("Generated Artifacts (\(appState.artifacts.count))").tag("artifacts")
            }
            .pickerStyle(.segmented)
            .frame(width: 310)

            // Scan All Button
            Button {
                for item in appState.watchItems where item.isEnabled {
                    appState.triggerWatchScan(item)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Scan All Targets")
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)

            // New Watch Target Button
            Button {
                showingCreateModal = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("New Watch Target...")
                }
                .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Watch Targets Content
    private var watchTargetsContent: some View {
        VStack(spacing: 12) {
            // Search and Filter Bar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    TextField("Filter watch folders, paths, or prompt templates...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(ThemeColors.cardBg(for: appState.settings.theme))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1))

                Picker("Type", selection: $filterWatchType) {
                    Text("All Types").tag("all")
                    Text("Folders / Directories").tag("folder")
                    Text("Single Files").tag("file")
                    Text("Extension Patterns").tag("pattern")
                    Text("Git Repositories").tag("gitRepository")
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // Watch Targets List / Grid
            if filteredWatchItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No watch folders or targets found")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("Create a watch target on any project folder to generate automated morning briefs, daily digests, and code reviews.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)

                    Button("Create Watch Target...") {
                        showingCreateModal = true
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredWatchItems) { item in
                            watchItemCard(item)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Watch Item Card
    private func watchItemCard(_ item: WatchItem) -> some View {
        let agent = appState.agents.first(where: { $0.id == item.targetAgentId }) ?? appState.currentAgent

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // Icon
                Image(systemName: item.watchType.icon)
                    .font(.system(size: 16))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    .frame(width: 32, height: 32)
                    .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Title & Details
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                        Text(item.watchType.displayName)
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ThemeColors.border(for: appState.settings.theme))
                            .cornerRadius(4)

                        // Status Badge
                        if item.isEnabled {
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("Watching")
                            }
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                        } else {
                            Text("Paused")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }

                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            .lineLimit(2)
                    }

                    // Monitored Path Row
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(item.path.isEmpty ? "(Default Workspace Folder)" : item.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                            .lineLimit(1)

                        Button {
                            let url = URL(fileURLWithPath: item.path.isEmpty ? appState.currentWorkspace.folderPath : item.path)
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    }

                    // Tags & Metadata Row
                    HStack(spacing: 8) {
                        // Assigned Agent
                        HStack(spacing: 4) {
                            Image(systemName: agent.avatar.isEmpty ? "person.fill" : agent.avatar)
                                .font(.system(size: 9.5))
                            Text(agent.name)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(4)

                        // Artifact Template
                        HStack(spacing: 4) {
                            Image(systemName: item.artifactTemplate.icon)
                                .font(.system(size: 9.5))
                            Text(item.artifactTemplate.displayName)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)

                        // Extensions Filter
                        Text("Filters: [\(item.fileExtensionsFilter.joined(separator: ", "))]")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(.secondary)

                        Spacer()

                        // Metrics
                        Text("\(item.eventsCount) events • \(item.createdArtifactsCount) artifacts")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }

                Spacer()

                // Actions Column
                VStack(spacing: 6) {
                    Button {
                        appState.triggerWatchScan(item)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                            Text("Generate Artifact")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    HStack(spacing: 6) {
                        Button("Configure") {
                            selectedWatchItemForEdit = item
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Toggle("", isOn: Binding(
                            get: { item.isEnabled },
                            set: { val in
                                var updated = item
                                updated.isEnabled = val
                                appState.saveWatchItem(updated)
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(14)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
    }

    // MARK: - Artifacts History Content
    private var artifactsHistoryContent: some View {
        VStack(spacing: 12) {
            if appState.artifacts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.image.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No generated artifacts yet")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("Artifacts like Morning Briefs, Daily Project Updates, and Code Reviews created by watch folders and automations will appear here.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appState.artifacts) { art in
                            artifactCard(art)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    // MARK: - Artifact Card
    private func artifactCard(_ art: AutomationArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: art.category.icon)
                    .font(.system(size: 14))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    .frame(width: 28, height: 28)
                    .background(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(art.title)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                        Text(art.category.displayName)
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(ThemeColors.border(for: appState.settings.theme))
                            .cornerRadius(4)

                        Text(art.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                    }

                    Text(art.sourceTrigger)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button("Open / Preview") {
                        selectedArtifactForDetail = art
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    if let path = art.filePath, !path.isEmpty {
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        } label: {
                            Image(systemName: "folder.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reveal File in Finder")
                    }

                    Button {
                        appState.deleteArtifact(art)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }

            // Preview Snippet
            Text(art.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(6)
        }
        .padding(12)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1))
    }
}

// MARK: - Watch Item Create / Edit Modal
public struct WatchItemEditModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    public var watchItem: WatchItem?

    @State private var name: String = ""
    @State private var descriptionText: String = ""
    @State private var path: String = ""
    @State private var watchType: WatchType = .folder
    @State private var extensionsFilterText: String = "*"
    @State private var targetAgentId: String = "lead-assistant"
    @State private var artifactTemplate: ArtifactOutputTemplate = .morningBrief
    @State private var customPrompt: String = ""
    @State private var outputDestination: String = "output"
    @State private var autoGenerateArtifact: Bool = true
    @State private var debounceIntervalSeconds: Double = 3.0

    public init(appState: AppState, isPresented: Binding<Bool>, watchItem: WatchItem? = nil) {
        self.appState = appState
        self._isPresented = isPresented
        self.watchItem = watchItem
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(watchItem == nil ? "Create New Watch Target" : "Configure Watch Target")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Form Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Target Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target Name")
                            .font(.system(size: 11, weight: .bold))
                        TextField("e.g. Workspace Daily Morning Brief, input/ Ingestion, Codebase Watcher", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(.system(size: 11, weight: .bold))
                        TextField("e.g. Monitored for file changes to synthesize morning updates", text: $descriptionText)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Watch Type Picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Watch Type")
                            .font(.system(size: 11, weight: .bold))
                        Picker("", selection: $watchType) {
                            ForEach(WatchType.allCases) { type in
                                Label(type.displayName, systemImage: type.icon).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Monitored Folder / File Path
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Monitored Directory / Path")
                            .font(.system(size: 11, weight: .bold))

                        HStack(spacing: 8) {
                            TextField("Path to directory or file...", text: $path)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))

                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false
                                panel.canChooseDirectories = watchType != .file
                                panel.canChooseFiles = watchType == .file || watchType == .pattern
                                panel.prompt = "Select Watch Target"
                                if panel.runModal() == .OK, let url = panel.url {
                                    path = url.path
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        // Quick Presets
                        HStack(spacing: 6) {
                            Text("Presets:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Button("Workspace Root") {
                                path = appState.currentWorkspace.folderPath
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("input/ Staging") {
                                path = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent("input")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("docs/ Notes") {
                                path = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent("docs")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }

                    // File Extensions Filter
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File Extensions Filter (comma-separated or '*' for all)")
                            .font(.system(size: 11, weight: .bold))
                        TextField("e.g. swift, md, json, txt or *", text: $extensionsFilterText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    // Assigned Agent & Artifact Template
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Assigned Processing Agent")
                                .font(.system(size: 11, weight: .bold))
                            Picker("", selection: $targetAgentId) {
                                ForEach(appState.agents) { ag in
                                    Text("\(ag.name) (\(ag.role))").tag(ag.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Artifact Template Mode")
                                .font(.system(size: 11, weight: .bold))
                            Picker("", selection: $artifactTemplate) {
                                ForEach(ArtifactOutputTemplate.allCases) { templ in
                                    Label(templ.displayName, systemImage: templ.icon).tag(templ)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: artifactTemplate) { newT in
                                customPrompt = newT.defaultPromptTemplate
                            }
                        }
                    }

                    // Custom Agent Prompt
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent Synthesis Prompt")
                            .font(.system(size: 11, weight: .bold))
                        TextEditor(text: $customPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 90)
                            .padding(4)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                    }

                    // Output Destination & Options
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Output & Automation Options")
                            .font(.system(size: 11, weight: .bold))

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Output Folder Name")
                                    .font(.system(size: 10, weight: .semibold))
                                TextField("output", text: $outputDestination)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 140)
                            }

                            Toggle("Auto-generate Artifact on change", isOn: $autoGenerateArtifact)
                                .font(.system(size: 11))

                            Spacer()
                        }
                    }
                }
                .padding(20)
            }

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Footer Actions
            HStack {
                if let item = watchItem {
                    Button(role: .destructive) {
                        appState.deleteWatchItem(item)
                        isPresented = false
                    } label: {
                        Text("Delete Target")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Button("Save Watch Target") {
                    saveTarget()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))
        }
        .frame(minWidth: 540, idealWidth: 600, maxWidth: 700, minHeight: 520, idealHeight: 600, maxHeight: 720)
        .onAppear {
            if let item = watchItem {
                name = item.name
                descriptionText = item.description
                path = item.path
                watchType = item.watchType
                extensionsFilterText = item.fileExtensionsFilter.joined(separator: ", ")
                targetAgentId = item.targetAgentId
                artifactTemplate = item.artifactTemplate
                customPrompt = item.customPrompt
                outputDestination = item.outputDestination
                autoGenerateArtifact = item.autoGenerateArtifact
                debounceIntervalSeconds = item.debounceIntervalSeconds
            } else {
                path = appState.currentWorkspace.folderPath
                customPrompt = artifactTemplate.defaultPromptTemplate
            }
        }
    }

    private func saveTarget() {
        let exts = extensionsFilterText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "").lowercased() }
            .filter { !$0.isEmpty }

        var item = watchItem ?? WatchItem(name: name)
        item.name = name
        item.description = descriptionText
        item.path = path.isEmpty ? appState.currentWorkspace.folderPath : path
        item.watchType = watchType
        item.fileExtensionsFilter = exts.isEmpty ? ["*"] : exts
        item.targetAgentId = targetAgentId
        item.artifactTemplate = artifactTemplate
        item.customPrompt = customPrompt
        item.outputDestination = outputDestination.isEmpty ? "output" : outputDestination
        item.autoGenerateArtifact = autoGenerateArtifact
        item.debounceIntervalSeconds = debounceIntervalSeconds
        item.updatedAt = Date()

        appState.saveWatchItem(item)
        isPresented = false
    }
}

// MARK: - Artifact Detail Preview Modal
public struct ArtifactDetailModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    public var artifact: AutomationArtifact

    public init(appState: AppState, isPresented: Binding<Bool>, artifact: AutomationArtifact) {
        self.appState = appState
        self._isPresented = isPresented
        self.artifact = artifact
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: artifact.category.icon)
                    .font(.system(size: 16))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))

                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Text("\(artifact.sourceTrigger) • Generated \(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Copy Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(artifact.content, forType: .string)
                    appState.showToast("Copied artifact markdown to clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let filePath = artifact.filePath {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: filePath)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Body
            ScrollView {
                MarkdownRichContentView(content: artifact.content, appState: appState)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(ThemeColors.bg(for: appState.settings.theme))
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 900, minHeight: 500, idealHeight: 600, maxHeight: 800)
    }
}
