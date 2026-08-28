import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Add / Install Extension Modal
public struct AddExtensionModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var installMode: String = "store" // store, manual, url, file
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var pluginType: PluginType = .mcpServer
    @State private var command: String = ""
    @State private var pathOrUrl: String = ""
    @State private var version: String = "1.0.0"
    @State private var author: String = ""
    @State private var selectedTemplateId: String = ""

    public struct ExtensionPreset: Identifiable {
        public let id: String
        public let name: String
        public let description: String
        public let type: PluginType
        public let command: String
        public let author: String
        public let version: String
        public let icon: String
        public let permissions: [String]
    }

    private let extensionPresets: [ExtensionPreset] = [
        ExtensionPreset(
            id: "preset-sqlite-mcp",
            name: "SQLite Database Explorer MCP",
            description: "Enables agents to introspect schemas, query tables, and summarize SQLite databases safely.",
            type: .mcpServer,
            command: "npx -y @modelcontextprotocol/server-sqlite --db-path ./workspace.db",
            author: "Model Context Protocol",
            version: "1.1.0",
            icon: "cylinder.split.1x2.fill",
            permissions: ["filesystem:read", "sqlite:query"]
        ),
        ExtensionPreset(
            id: "preset-github-mcp",
            name: "GitHub API & Repo Manager MCP",
            description: "Direct GitHub integration for issue management, pull requests, diff reviews, and CI runs.",
            type: .mcpServer,
            command: "npx -y @modelcontextprotocol/server-github",
            author: "GitHub / MCP",
            version: "2.0.1",
            icon: "chevron.left.forwardslash.chevron.right",
            permissions: ["network:outbound", "github:api"]
        ),
        ExtensionPreset(
            id: "preset-puppeteer-mcp",
            name: "Headless Browser Automation MCP",
            description: "Automates web navigation, screenshots, DOM extraction, and web form interactions via Puppeteer.",
            type: .mcpServer,
            command: "npx -y @modelcontextprotocol/server-puppeteer",
            author: "Puppeteer / MCP",
            version: "1.4.0",
            icon: "safari.fill",
            permissions: ["network:outbound", "browser:headless"]
        ),
        ExtensionPreset(
            id: "preset-wakatime",
            name: "WakaTime Coding Telemetry Plugin",
            description: "Automatic coding metrics, time tracking, and productivity stats for OpenWork sessions.",
            type: .customScript,
            command: "wakatime-cli --today",
            author: "WakaTime",
            version: "1.0.0",
            icon: "clock.badge.checkmark.fill",
            permissions: ["network:outbound"]
        ),
        ExtensionPreset(
            id: "preset-stable-diffusion",
            name: "Local Stable Diffusion / Flux Media",
            description: "Generate images locally using Apple Silicon MLX / Stable Diffusion CoreML pipelines.",
            type: .mediaVision,
            command: "python3 -m mlx_image.generate",
            author: "MLX Community",
            version: "1.2.0",
            icon: "paintpalette.fill",
            permissions: ["apple_silicon:npu", "filesystem:write"]
        ),
        ExtensionPreset(
            id: "preset-postgres-mcp",
            name: "PostgreSQL Database Engine MCP",
            description: "Query and manage remote and local PostgreSQL databases with schema auto-reflection.",
            type: .mcpServer,
            command: "npx -y @modelcontextprotocol/server-postgres postgresql://localhost/mydb",
            author: "Model Context Protocol",
            version: "1.0.2",
            icon: "server.rack",
            permissions: ["network:outbound", "postgres:query"]
        )
    ]

    public init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    .font(.system(size: 16))
                Text("Add Extension & Plugin")
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
                    modeTabButton(id: "store", title: "Catalog & Registry", icon: "square.grid.2x2.fill")
                    modeTabButton(id: "manual", title: "Custom Configuration", icon: "slider.horizontal.3")
                    modeTabButton(id: "url", title: "Import from URL / Git", icon: "globe")
                    modeTabButton(id: "file", title: "Local File / Script", icon: "doc.badge.plus")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(ThemeColors.sidebarBg(for: appState.settings.theme).opacity(0.5))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch installMode {
                    case "store":
                        storeCatalogView
                    case "manual":
                        manualFormView
                    case "url":
                        urlImportView
                    case "file":
                        fileImportView
                    default:
                        storeCatalogView
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if installMode == "manual" {
                    Button("Install Plugin") {
                        guard !name.isEmpty else { return }
                        let plugin = AppExtensionPlugin(
                            name: name,
                            description: description,
                            version: version.isEmpty ? "1.0.0" : version,
                            author: author.isEmpty ? "Custom" : author,
                            pluginType: pluginType,
                            source: .custom,
                            isEnabled: true,
                            pathOrUrl: pathOrUrl,
                            command: command
                        )
                        appState.savePlugin(plugin)
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
                } else if installMode == "url" {
                    Button("Fetch & Install") {
                        guard !pathOrUrl.isEmpty else { return }
                        appState.importPluginFromUrl(urlString: pathOrUrl, name: name.isEmpty ? nil : name)
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pathOrUrl.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(
            minWidth: 540,
            idealWidth: 640,
            maxWidth: 1000,
            minHeight: 480,
            idealHeight: 620,
            maxHeight: 900
        )
        .background(ThemeColors.bg(for: appState.settings.theme))
    }

    private func modeTabButton(id: String, title: String, icon: String) -> some View {
        let isSelected = installMode == id
        return Button {
            installMode = id
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

    // Catalog View
    private var storeCatalogView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Featured Extensions & MCP Plugins")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

            Text("One-click install pre-configured MCP tools, data connectors, and productivity extensions:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            VStack(spacing: 10) {
                ForEach(extensionPresets) { preset in
                    let isInstalled = appState.plugins.contains(where: { $0.name == preset.name || $0.command == preset.command })
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 16))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                            .frame(width: 32, height: 32)
                            .background(ThemeColors.border(for: appState.settings.theme))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(preset.name)
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                Text(preset.type.displayName)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(ThemeColors.border(for: appState.settings.theme))
                                    .cornerRadius(4)

                                Text("v\(preset.version)")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.secondary)
                            }

                            Text(preset.description)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            if !preset.command.isEmpty {
                                Text(preset.command)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .padding(4)
                                    .background(Color.black.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }

                        Spacer()

                        if isInstalled {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Installed")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.green)
                            }
                            .padding(.top, 4)
                        } else {
                            Button("Install") {
                                let newPlug = AppExtensionPlugin(
                                    name: preset.name,
                                    description: preset.description,
                                    version: preset.version,
                                    author: preset.author,
                                    pluginType: preset.type,
                                    source: .mcpRegistry,
                                    isEnabled: true,
                                    command: preset.command,
                                    permissions: preset.permissions
                                )
                                appState.savePlugin(newPlug)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                    .padding(10)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                    )
                }
            }
        }
    }

    // Manual Form View
    private var manualFormView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extension / Plugin Name")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("e.g. Docker Container Inspector, Local Redis Plugin", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Description")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("Brief summary of plugin capabilities", text: $description)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plugin Type")
                        .font(.system(size: 11.5, weight: .semibold))
                    Picker("", selection: $pluginType) {
                        ForEach(PluginType.allCases) { type in
                            Label(type.displayName, systemImage: type.icon).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Version")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("1.0.0", text: $version)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Author / Org")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("Developer Name", text: $author)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("Executable Command / Entry Point (CLI, Node, Python, Binary)")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("e.g. npx -y @modelcontextprotocol/server-docker or /usr/local/bin/my-plugin", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))

            Text("Local Working Directory or Source Path (Optional)")
                .font(.system(size: 11.5, weight: .semibold))
            TextField("e.g. /path/to/plugin/folder", text: $pathOrUrl)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
        }
    }

    // URL Import View
    private var urlImportView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Plugin Manifest from Remote URL / Git")
                .font(.system(size: 12, weight: .bold))

            Text("Enter the raw HTTPS URL to a plugin configuration manifest JSON or remote server package:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Manifest / Server URL")
                    .font(.system(size: 11.5, weight: .semibold))
                TextField("https://raw.githubusercontent.com/user/repo/main/plugin.json", text: $pathOrUrl)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Custom Plugin Alias (Optional)")
                    .font(.system(size: 11.5, weight: .semibold))
                TextField("Custom Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // Local File / Script Import View
    private var fileImportView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Local File or Script")
                .font(.system(size: 12, weight: .bold))

            Text("Select an existing JSON plugin manifest, shell script (.sh), or executable binary on your Mac:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [
                    .json,
                    .shellScript,
                    UTType(filenameExtension: "sh") ?? .plainText,
                    UTType(filenameExtension: "py") ?? .plainText,
                    UTType(filenameExtension: "js") ?? .plainText
                ]
                if panel.runModal() == .OK, let url = panel.url {
                    appState.importPluginFromFile(url: url)
                    isPresented = false
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                    Text("Select Plugin Manifest / Script File...")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Divider()

            Text("Or select a Plugin Directory folder:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    let plugin = AppExtensionPlugin(
                        name: url.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized,
                        description: "Folder plugin at \(url.path)",
                        pluginType: .customScript,
                        source: .directory,
                        pathOrUrl: url.path,
                        command: url.path
                    )
                    appState.savePlugin(plugin)
                    isPresented = false
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                    Text("Select Plugin Directory Folder...")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Edit Extension Detail Modal
public struct ExtensionDetailModalView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    @State var plugin: AppExtensionPlugin

    public init(appState: AppState, isPresented: Binding<Bool>, plugin: AppExtensionPlugin) {
        self.appState = appState
        self._isPresented = isPresented
        self._plugin = State(initialValue: plugin)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name)
                        .font(.system(size: 14, weight: .bold))
                    Text("Type: \(plugin.pluginType.displayName) • Source: \(plugin.source.displayName) • Version: \(plugin.version)")
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
                    Text("Plugin Name")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("Name", text: $plugin.name)
                        .textFieldStyle(.roundedBorder)

                    Text("Description")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("Description", text: $plugin.description)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Plugin Type")
                                .font(.system(size: 11.5, weight: .semibold))
                            Picker("", selection: $plugin.pluginType) {
                                ForEach(PluginType.allCases) { type in
                                    Label(type.displayName, systemImage: type.icon).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Version")
                                .font(.system(size: 11.5, weight: .semibold))
                            TextField("Version", text: $plugin.version)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Author")
                                .font(.system(size: 11.5, weight: .semibold))
                            TextField("Author", text: $plugin.author)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text("Execution Command / Binary Path")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("Command", text: $plugin.command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))

                    Text("Working Directory / Remote URL")
                        .font(.system(size: 11.5, weight: .semibold))
                    TextField("Path or URL", text: $plugin.pathOrUrl)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("Remove / Uninstall Plugin", role: .destructive) {
                    appState.deletePlugin(plugin)
                    isPresented = false
                }
                .foregroundColor(.red)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Changes") {
                    appState.savePlugin(plugin)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(
            minWidth: 500,
            idealWidth: 560,
            maxWidth: 900,
            minHeight: 460,
            idealHeight: 560,
            maxHeight: 800
        )
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
