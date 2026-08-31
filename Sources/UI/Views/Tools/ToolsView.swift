import SwiftUI

public struct ToolsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedCategory: String = "all"
    @State private var searchText: String = ""

    public init(appState: AppState) {
        self.appState = appState
    }

    private var filteredTools: [Tool] {
        appState.tools.filter { tool in
            let matchesCategory = selectedCategory == "all" || tool.category.rawValue == selectedCategory
            let matchesSearch = searchText.isEmpty ||
                tool.displayName.localizedCaseInsensitiveContains(searchText) ||
                tool.name.localizedCaseInsensitiveContains(searchText) ||
                tool.description.localizedCaseInsensitiveContains(searchText)
            return matchesCategory && matchesSearch
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Tools & Extensions Inventory")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        Text("\(appState.tools.filter { $0.isEnabled }.count) Active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text("Built-in system tools, Vision/Media models, MCP servers, and installed extensions connected to OpenWork")
                        .font(.system(size: 11))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                }
                Spacer()

                // Open Terminal in Inspector
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.inspectorTab = .terminal
                        appState.isInspectorOpen = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                        Text("Open Terminal")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)

                Button {
                    appState.settingsTab = "extensions"
                    appState.navigationDestination = .settings
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "puzzlepiece.extension")
                        Text("Manage Extensions & Plugins")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ThemeColors.sidebarBg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            // Search & Category Filter Bar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    TextField("Filter tools by name, description, or schema...", text: $searchText)
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

                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories (\(appState.tools.count))").tag("all")
                    ForEach(ToolCategory.allCases, id: \.rawValue) { cat in
                        Label(cat.displayName, systemImage: cat.icon).tag(cat.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 210)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(ThemeColors.bg(for: appState.settings.theme))

            Divider()
                .background(ThemeColors.border(for: appState.settings.theme))

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(filteredTools) { tool in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: tool.category.icon)
                                .font(.system(size: 15))
                                .foregroundColor(tool.isEnabled ? ThemeColors.accent(for: appState.settings.accentColor) : .secondary)
                                .frame(width: 32, height: 32)
                                .background(ThemeColors.border(for: appState.settings.theme))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(tool.displayName)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                    Text(tool.name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                    Text(tool.category.displayName)
                                        .font(.system(size: 9.5))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(ThemeColors.border(for: appState.settings.theme))
                                        .cornerRadius(4)
                                }

                                Text(tool.description)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { tool.isEnabled },
                                set: { val in
                                    if let idx = appState.tools.firstIndex(where: { $0.id == tool.id }) {
                                        appState.tools[idx].isEnabled = val
                                        PersistenceManager.shared.saveTools(appState.tools)
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        .padding(12)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                        )
                        .cornerRadius(10)
                    }
                }
                .padding(16)
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}
