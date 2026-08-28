import SwiftUI
import AppKit

// MARK: - Add Skill Modal (Manual / URL / Presets)
public struct AddSkillModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var creationMode: String = "manual" // manual, url, preset
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var category: String = "Engineering"
    @State private var content: String = "# Skill Instructions\n\nWhen performing this task:\n1. Follow best practices\n2. Provide clean output"
    @State private var urlString: String = ""

    public init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Agent Skill")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Mode Selector - Scrollable Horizontal Ribbon
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    skillModeTabButton(id: "manual", title: "Create Custom", icon: "pencil.and.outline")
                    skillModeTabButton(id: "url", title: "Import from URL / GitHub", icon: "globe")
                    skillModeTabButton(id: "preset", title: "Skill Templates", icon: "sparkles")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(ThemeColors.sidebarBg(for: appState.settings.theme).opacity(0.5))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if creationMode == "manual" {
                        manualForm
                    } else if creationMode == "url" {
                        urlForm
                    } else {
                        presetList
                    }
                }
                .padding(16)
            }

            Divider()

            // Bottom Actions
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if creationMode == "manual" {
                    Button("Save Skill") {
                        guard !name.isEmpty else { return }
                        let skill = Skill(
                            name: name,
                            description: description,
                            category: category,
                            content: content,
                            source: .manual
                        )
                        appState.saveSkill(skill)
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
                } else if creationMode == "url" {
                    Button("Fetch & Import") {
                        guard !urlString.isEmpty else { return }
                        appState.importSkillFromUrl(urlString: urlString, name: name.isEmpty ? nil : name)
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlString.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(
            minWidth: 500,
            idealWidth: 580,
            maxWidth: 900,
            minHeight: 460,
            idealHeight: 580,
            maxHeight: 850
        )
        .background(ThemeColors.bg(for: appState.settings.theme))
    }

    private func skillModeTabButton(id: String, title: String, icon: String) -> some View {
        let isSelected = creationMode == id
        return Button {
            creationMode = id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.18) : ThemeColors.sidebarBg(for: appState.settings.theme))
            .foregroundColor(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textPrimary(for: appState.settings.theme))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.border(for: appState.settings.theme).opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // Manual Form
    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skill Name")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("e.g. Swift Concurrency Auditor", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Category")
                .font(.system(size: 11.5, weight: .semibold))
            Picker("", selection: $category) {
                Text("Engineering").tag("Engineering")
                Text("Security").tag("Security")
                Text("DevOps & Git").tag("DevOps")
                Text("Database & SQL").tag("Database")
                Text("Research & Docs").tag("Research")
                Text("Testing & QA").tag("Testing")
                Text("Custom").tag("Custom")
            }

            Text("Description")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("Brief summary of what this skill enables", text: $description)
                .textFieldStyle(.roundedBorder)

            Text("Instructions (Markdown / System Prompt Guidelines)")
                .font(.system(size: 11.5, weight: .semibold))
            TextEditor(text: $content)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 140)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
        }
    }

    // URL Form
    private var urlForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Raw Markdown / GitHub SKILL.md URL")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("https://raw.githubusercontent.com/.../SKILL.md", text: $urlString)
                .textFieldStyle(.roundedBorder)

            Text("Custom Display Name (Optional)")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("Leave blank to auto-detect from URL", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("OpenWork will fetch the remote markdown file and convert it into an active agent skill.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // Presets
    private var presetList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select a curated skill template to install:")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)

            presetCard(
                title: "Swift 6 Architecture & Concurrency Master",
                category: "Engineering",
                desc: "Strict actor isolation, sendable checking, task groups, and modern SwiftUI state.",
                content: """
                # Swift 6 Architecture Skill
                - Enforce strict concurrency checking with zero data races.
                - Use `actor`, `nonisolated`, `@Sendable`, and structured concurrency (`TaskGroup`, `async let`).
                - Design clean unidirectional SwiftUI state flows.
                """
            )

            presetCard(
                title: "Automated Unit & E2E Test Generator",
                category: "Testing",
                desc: "Generates thorough unit tests with edge cases, mocks, and failure assertions.",
                content: """
                # Test Generation Skill
                - Write comprehensive XCTest / Swift Testing test suites.
                - Cover boundary conditions, nil cases, empty inputs, network errors, and concurrency timeouts.
                """
            )

            presetCard(
                title: "Docker & Kubernetes Deployment Specialist",
                category: "DevOps",
                desc: "Creates multi-stage Dockerfiles, compose setups, and secure helm charts.",
                content: """
                # Container & Kubernetes Skill
                - Generate minimal, secure multi-stage container builds.
                - Ensure non-root execution, healthchecks, and resource quotas.
                """
            )

            presetCard(
                title: "Database Query Optimizer & Migration Builder",
                category: "Database",
                desc: "Indexes, SQL query performance tuning, and schema migration scripts.",
                content: """
                # Database Skill
                - Analyze EXPLAIN QUERY PLAN outputs for table scans.
                - Write safe, reversible schema migrations.
                """
            )
        }
    }

    private func presetCard(title: String, category: String, desc: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text(category)
                        .font(.system(size: 9.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(ThemeColors.border(for: appState.settings.theme))
                        .cornerRadius(4)
                }
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Button("Install") {
                let skill = Skill(
                    name: title,
                    description: desc,
                    category: category,
                    content: content,
                    source: .builtIn
                )
                appState.saveSkill(skill)
                isPresented = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .cornerRadius(8)
    }
}

// MARK: - Add / Edit MCP Server Modal
public struct McpServerEditModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var serverId: String
    @State private var name: String
    @State private var transportType: MCPTransportType
    @State private var command: String
    @State private var argsText: String
    @State private var workingDirectory: String
    @State private var url: String
    @State private var envList: [(id: UUID, key: String, value: String, isSecret: Bool)]
    @State private var newEnvKey: String = ""
    @State private var newEnvValue: String = ""
    @State private var newEnvSecret: Bool = false

    public init(appState: AppState, isPresented: Binding<Bool>, editingConfig: MCPServerConfig? = nil) {
        self.appState = appState
        self._isPresented = isPresented
        
        let initial = editingConfig ?? MCPServerConfig(name: "", transportType: .stdio, command: "npx", args: [])
        self._serverId = State(initialValue: initial.id)
        self._name = State(initialValue: initial.name)
        self._transportType = State(initialValue: initial.transportType)
        self._command = State(initialValue: initial.command)
        self._argsText = State(initialValue: initial.args.joined(separator: " "))
        self._workingDirectory = State(initialValue: initial.workingDirectory)
        self._url = State(initialValue: initial.url)

        var list: [(id: UUID, key: String, value: String, isSecret: Bool)] = []
        for (k, v) in initial.env {
            list.append((id: UUID(), key: k, value: v, isSecret: k.lowercased().contains("key") || k.lowercased().contains("token") || k.lowercased().contains("secret")))
        }
        self._envList = State(initialValue: list)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(name.isEmpty ? "Add MCP Server" : "Configure \(name)")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 1. Basic Info & Transport Type
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server Name")
                            .font(.system(size: 11.5, weight: .semibold))
                        TextField("e.g. Memory Server, GitHub MCP, PostgreSQL Explorer", text: $name)
                            .textFieldStyle(.roundedBorder)

                        Text("Transport Protocol Type")
                            .font(.system(size: 11.5, weight: .semibold))
                        Picker("", selection: $transportType) {
                            ForEach(MCPTransportType.allCases) { t in
                                HStack {
                                    Image(systemName: t.icon)
                                    Text(t.displayName)
                                }
                                .tag(t)
                            }
                        }
                    }

                    Divider()

                    // 2. Transport Configuration
                    if transportType == .stdio {
                        stdioFields
                    } else {
                        networkFields
                    }

                    Divider()

                    // 3. Environment Variables Manager
                    environmentVariablesSection
                }
                .padding(16)
            }

            Divider()

            // Bottom Actions
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save MCP Server") {
                    guard !name.isEmpty else { return }
                    var envDict: [String: String] = [:]
                    for item in envList {
                        if !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
                            envDict[item.key] = item.value
                        }
                    }

                    let config = MCPServerConfig(
                        id: serverId,
                        name: name,
                        transportType: transportType,
                        command: command,
                        args: argsText.components(separatedBy: " ").filter { !$0.isEmpty },
                        workingDirectory: workingDirectory,
                        url: url,
                        env: envDict
                    )

                    appState.saveMcpServer(config)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || (transportType == .stdio && command.isEmpty) || (transportType != .stdio && url.isEmpty))
            }
            .padding(16)
        }
        .frame(
            minWidth: 520,
            idealWidth: 580,
            maxWidth: 900,
            minHeight: 500,
            idealHeight: 620,
            maxHeight: 900
        )
        .background(ThemeColors.bg(for: appState.settings.theme))
    }

    // stdio Fields
    private var stdioFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Executable Command")
                .font(.system(size: 11.5, weight: .semibold))
            HStack {
                TextField("e.g. npx, uvx, docker, python3", text: $command)
                    .textFieldStyle(.roundedBorder)

                // Quick Command Presets
                Menu("Presets") {
                    Button("npx (Node)") { command = "npx" }
                    Button("uvx (Python)") { command = "uvx" }
                    Button("docker (Container)") { command = "docker" }
                    Button("python3") { command = "python3" }
                }
            }

            Text("Arguments (Space-Separated)")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("e.g. -y @modelcontextprotocol/server-filesystem /path/to/dir", text: $argsText)
                .textFieldStyle(.roundedBorder)

            Text("Working Directory (Optional)")
                .font(.system(size: 11.5, weight: .semibold))
            HStack {
                TextField("Path to execution root", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let u = panel.url {
                        workingDirectory = u.path
                    }
                }
            }
        }
    }

    // HTTP / WebSocket Fields
    private var networkFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(transportType == .httpSse ? "Server Endpoint URL (HTTP / SSE)" : "WebSocket Endpoint URL (ws / wss)")
                .font(.system(size: 11.5, weight: .semibold))
            TextField(transportType == .httpSse ? "http://127.0.0.1:8000/sse" : "ws://127.0.0.1:9000", text: $url)
                .textFieldStyle(.roundedBorder)
        }
    }

    // Environment Variables Table
    private var environmentVariablesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Environment Variables (ENV)")
                        .font(.system(size: 12, weight: .bold))
                    Text("Injected into this MCP server process execution context")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Quick Preset Environment Keys
                Menu("Add Common Key") {
                    Button("GITHUB_PERSONAL_ACCESS_TOKEN") { newEnvKey = "GITHUB_PERSONAL_ACCESS_TOKEN"; newEnvSecret = true }
                    Button("OPENAI_API_KEY") { newEnvKey = "OPENAI_API_KEY"; newEnvSecret = true }
                    Button("DATABASE_URL") { newEnvKey = "DATABASE_URL"; newEnvSecret = false }
                    Button("API_KEY") { newEnvKey = "API_KEY"; newEnvSecret = true }
                    Button("SLACK_BOT_TOKEN") { newEnvKey = "SLACK_BOT_TOKEN"; newEnvSecret = true }
                    Button("CUSTOM_PATH") { newEnvKey = "PATH"; newEnvSecret = false }
                }
                .font(.system(size: 11))
            }

            // List of Current Envs
            if envList.isEmpty {
                Text("No environment variables added for this MCP server.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(envList, id: \.id) { item in
                        HStack(spacing: 8) {
                            Text(item.key)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 160, alignment: .leading)
                                .lineLimit(1)

                            if item.isSecret {
                                Text("••••••••••••••••")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(item.value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                envList.removeAll(where: { $0.id == item.id })
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(6)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(6)
                    }
                }
            }

            // Add Env Input Row
            HStack(spacing: 6) {
                TextField("KEY (e.g. API_KEY)", text: $newEnvKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                if newEnvSecret {
                    SecureField("VALUE", text: $newEnvValue)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("VALUE", text: $newEnvValue)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    newEnvSecret.toggle()
                } label: {
                    Image(systemName: newEnvSecret ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(newEnvSecret ? "Masked Secret" : "Plain Text")

                Button("Add") {
                    guard !newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    envList.append((id: UUID(), key: newEnvKey.trimmingCharacters(in: .whitespaces), value: newEnvValue, isSecret: newEnvSecret))
                    newEnvKey = ""
                    newEnvValue = ""
                    newEnvSecret = false
                }
                .buttonStyle(.bordered)
                .disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - View / Edit Existing Skill Modal
public struct SkillDetailModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    @State var skill: Skill

    public init(appState: AppState, isPresented: Binding<Bool>, skill: Skill) {
        self.appState = appState
        self._isPresented = isPresented
        self._skill = State(initialValue: skill)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 14, weight: .bold))
                    Text("Source: \(skill.source.displayName) • Category: \(skill.category)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Skill Name")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("Name", text: $skill.name)
                        .textFieldStyle(.roundedBorder)

                    Text("Description")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("Description", text: $skill.description)
                        .textFieldStyle(.roundedBorder)

                    Text("Category")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("Category", text: $skill.category)
                        .textFieldStyle(.roundedBorder)

                    Text("Markdown Instructions & Knowledge")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextEditor(text: $skill.content)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(height: 200)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("Delete Skill", role: .destructive) {
                    appState.deleteSkill(skill)
                    isPresented = false
                }
                .foregroundColor(.red)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Changes") {
                    appState.saveSkill(skill)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(
            minWidth: 480,
            idealWidth: 540,
            maxWidth: 900,
            minHeight: 460,
            idealHeight: 540,
            maxHeight: 800
        )
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
